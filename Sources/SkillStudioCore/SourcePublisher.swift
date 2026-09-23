import Foundation
import Darwin

struct SourceFile {
    struct Identity: Equatable, Sendable {
        let device: dev_t, inode: ino_t, mode: mode_t, links: nlink_t, owner: uid_t, group: gid_t
        let size: off_t, modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
        init(_ s: stat) {
            device = s.st_dev; inode = s.st_ino; mode = s.st_mode; links = s.st_nlink; owner = s.st_uid; group = s.st_gid
            size = s.st_size; modifiedSeconds = s.st_mtimespec.tv_sec; modifiedNanos = s.st_mtimespec.tv_nsec
            changedSeconds = s.st_ctimespec.tv_sec; changedNanos = s.st_ctimespec.tv_nsec
        }
    }
    let bytes: Data
    let identity: Identity
    static func read(_ url: URL, publishing: Bool) throws -> Self {
        // O_NONBLOCK prevents a raced-in FIFO from hanging before fstat rejects it.
        let fd = open(url.path, O_RDONLY | (publishing ? O_NOFOLLOW : 0) | O_NONBLOCK)
        guard fd >= 0 else { throw SourcePublishError.blocked(.missingOrUnreadable) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw SourcePublishError.blocked(.nonRegularFile) }
        if publishing {
            guard info.st_nlink == 1 else { throw SourcePublishError.blocked(.sharedFile) }
            guard info.st_uid == geteuid(), info.st_mode & 0o200 != 0,
                  access(url.path, W_OK) == 0, access(url.deletingLastPathComponent().path, W_OK | X_OK) == 0 else {
                throw SourcePublishError.blocked(.notWritable)
            }
        }
        guard info.st_size <= 2_000_000 else { throw StudioError.message("SKILL.md exceeds 2 MB") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let bytes = try handle.read(upToCount: 2_000_001) ?? Data()
        guard bytes.count <= 2_000_000 else { throw StudioError.message("SKILL.md exceeds 2 MB") }
        var after = stat()
        guard fstat(fd, &after) == 0, Identity(info) == Identity(after), bytes.count == info.st_size else { throw SourcePublishError.blocked(.changed) }
        return Self(bytes: bytes, identity: Identity(info))
    }
}

/// Created only by prepare: confirmation freezes both sides of the source diff.
public struct PublishRequest: Identifiable, Sendable {
    public let id = UUID()
    public let skillID: String
    public let targetPath: String
    public let versionID: UUID
    public let versionNumber: Int
    public let content: String
    public let expectedSource: String
    fileprivate let identity: SourceFile.Identity
    fileprivate let provenance: SourceProvenance
}

public struct PublishReceipt: Sendable {
    public let request: PublishRequest
    public let backupURL: URL
    public let writtenAt: Date
}

public enum SourcePublisher {
    public static func prepare(skillID: String, in snapshot: LibrarySnapshot, context: DiscoveryContext) throws -> PublishRequest {
        try LibraryBackup.validate(snapshot)
        guard let skill = snapshot.skills.first(where: { $0.id == skillID }),
              let version = snapshot.versions.first(where: { $0.id == skill.activeVersionID && $0.skillID == skillID }) else {
            throw SourcePublishError.blocked(.staleConfirmation)
        }
        guard version.content.utf8.count <= 2_000_000 else { throw StudioError.message("SKILL.md exceeds 2 MB") }
        let provenance = try SourcePolicy.currentProvenance(skill: skill, context: context)
        let path = skill.sourcePath!
        let actual = try SourceFile.read(URL(fileURLWithPath: path), publishing: true)
        guard actual.bytes == Data(skill.lastDiskContent.utf8) else { throw SourcePublishError.blocked(.changed) }
        return PublishRequest(skillID: skillID, targetPath: path, versionID: version.id, versionNumber: version.number,
                              content: version.content, expectedSource: skill.lastDiskContent, identity: actual.identity, provenance: provenance)
    }
    public static func eligibility(skillID: String, in snapshot: LibrarySnapshot, context: DiscoveryContext) -> PublishEligibility {
        do { _ = try prepare(skillID: skillID, in: snapshot, context: context); return .allowed }
        catch SourcePublishError.blocked(let reason) {
            return [.missingOrUnreadable, .nonRegularFile, .notWritable, .changed, .staleConfirmation, .noSource].contains(reason)
                ? .unavailable(reason) : .readOnly(reason)
        } catch { return .unavailable(.missingOrUnreadable) }
    }
    public static func publish(_ request: PublishRequest, in snapshot: LibrarySnapshot, context: DiscoveryContext, backupDirectory: URL) throws -> PublishReceipt {
        try publish(request, in: snapshot, context: context, backupDirectory: backupDirectory, checkpoint: { _ in })
    }
    enum Stage { case beforeBackup, beforeTemporaryWrite, beforeReplacement }
    /// Deterministic fault/race injection is internal to the testable core, not user configuration.
    static func publish(_ request: PublishRequest, in snapshot: LibrarySnapshot, context: DiscoveryContext, backupDirectory: URL,
                        checkpoint: (Stage) throws -> Void,
                        writeTemporary: (Data, Int32) throws -> Void = { try write($0, to: $1) },
                        replace: (Int32, String) -> Int32 = { renameat($0, $1, $0, "SKILL.md") }) throws -> PublishReceipt {
        func verify() throws {
            let current = try prepare(skillID: request.skillID, in: snapshot, context: context)
            guard current.targetPath == request.targetPath, current.versionID == request.versionID,
                  Data(current.content.utf8) == Data(request.content.utf8), Data(current.expectedSource.utf8) == Data(request.expectedSource.utf8),
                  current.identity == request.identity, current.provenance == request.provenance else {
                throw SourcePublishError.blocked(.staleConfirmation)
            }
        }
        try verify() // Rejection precedes backup/temp creation.
        let target = URL(fileURLWithPath: request.targetPath)
        let parent = target.deletingLastPathComponent()
        let directoryFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw SourcePublishError.blocked(.linkedPath) }
        defer { close(directoryFD) }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0 else { throw SourcePublishError.blocked(.missingOrUnreadable) }
        func verifyDirectory() throws {
            var current = stat()
            guard lstat(parent.path, &current) == 0, current.st_dev == directoryInfo.st_dev, current.st_ino == directoryInfo.st_ino else {
                throw SourcePublishError.blocked(.staleConfirmation)
            }
        }
        try checkpoint(.beforeBackup)
        try verify(); try verifyDirectory()
        let fm = FileManager.default
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backupDirectoryFD = open(backupDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard backupDirectoryFD >= 0 else { throw StudioError.message("The private source backup directory is unavailable.") }
        defer { close(backupDirectoryFD) }
        var backupInfo = stat()
        guard fstat(backupDirectoryFD, &backupInfo) == 0, backupInfo.st_uid == geteuid(),
              fchmod(backupDirectoryFD, 0o700) == 0 else { throw StudioError.message("The private source backup directory is unavailable.") }
        let backup = backupDirectory.appendingPathComponent(UUID().uuidString + "-SKILL.md")
        let backupFD = openat(backupDirectoryFD, backup.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard backupFD >= 0 else { throw StudioError.message("Unable to create a private source backup.") }
        do { try write(Data(request.expectedSource.utf8), to: backupFD); guard fsync(backupFD) == 0 else { throw posixFailure() }; close(backupFD) }
        catch { close(backupFD); throw error }
        // Backup is retained even if the remaining operation fails.
        try checkpoint(.beforeTemporaryWrite)
        let temporaryName = ".skillstudio-" + UUID().uuidString + ".tmp"
        let temporaryFD = openat(directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard temporaryFD >= 0 else { throw posixFailure() }
        var replaced = false
        func ownsTemporaryPath() -> Bool {
            var descriptorInfo = stat(), pathInfo = stat()
            return fstat(temporaryFD, &descriptorInfo) == 0 && fstatat(directoryFD, temporaryName, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0 &&
                descriptorInfo.st_dev == pathInfo.st_dev && descriptorInfo.st_ino == pathInfo.st_ino && pathInfo.st_mode & S_IFMT == S_IFREG
        }
        defer {
            if !replaced, ownsTemporaryPath() { unlinkat(directoryFD, temporaryName, 0) }
            close(temporaryFD)
        }
        let sourceFD = openat(directoryFD, "SKILL.md", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard sourceFD >= 0 else { throw SourcePublishError.blocked(.changed) }
        defer { close(sourceFD) }
        var currentInfo = stat()
        guard fstat(sourceFD, &currentInfo) == 0, SourceFile.Identity(currentInfo) == request.identity else { throw SourcePublishError.blocked(.changed) }
        try writeTemporary(Data(request.content.utf8), temporaryFD)
        // Preserve source mode/ACL/xattrs on OUR temporary file; never chmod/chown the source.
        guard fcopyfile(sourceFD, temporaryFD, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0,
              fsync(temporaryFD) == 0 else { throw posixFailure() }
        try checkpoint(.beforeReplacement)
        try verify(); try verifyDirectory()
        // The external editor race between verification and rename is small, but not eliminated.
        guard ownsTemporaryPath() else { throw SourcePublishError.blocked(.staleConfirmation) }
        guard replace(directoryFD, temporaryName) == 0 else { throw posixFailure() }
        replaced = true
        return PublishReceipt(request: request, backupURL: backup, writtenAt: Date())
    }
    private static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixFailure() }
                offset += count
            }
        }
    }
    private static func posixFailure() -> Error { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

/// File replacement and SQLite cannot be one transaction. A failed save never rolls back the source.
public enum PublishOutcome {
    case saved(PublishReceipt)
    case sourceWrittenLibrarySaveFailed(PublishReceipt, String)
}
public enum PublishOperation {
    public static func perform(_ request: PublishRequest, snapshot: LibrarySnapshot, context: DiscoveryContext, backupDirectory: URL,
                               save: (LibrarySnapshot) throws -> Void) throws -> PublishOutcome {
        let receipt = try SourcePublisher.publish(request, in: snapshot, context: context, backupDirectory: backupDirectory)
        var updated = snapshot
        if let i = updated.skills.firstIndex(where: { $0.id == request.skillID }) {
            updated.skills[i].lastDiskContent = request.content
            updated.skills[i].sourceObservation = SourceObservation(checkedAt: receipt.writtenAt, externalChange: false)
            updated.skills[i].sourceProvenance = request.provenance
            updated.skills[i].lastPublishedVersionID = request.versionID
        }
        do { try save(updated); return .saved(receipt) }
        catch { return .sourceWrittenLibrarySaveFailed(receipt, error.localizedDescription) }
    }
}
