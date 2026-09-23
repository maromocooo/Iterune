import Foundation
import CryptoKit
import Darwin

/// Advisory lock shared by all new Studio processes using the same library directory.
public final class LibraryLease {
    private let descriptor: Int32
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        descriptor = open(directory.appendingPathComponent(".studio.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw StudioError.message("Unable to lock the library.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw StudioError.message("This library is open in another app. Close that app and restart.")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

public enum LibraryBackup {
    private struct Envelope: Codable {
        let format: Int
        let createdAt: Date
        let checksum: String
        let payload: Data
    }
    public static func write(_ snapshot: LibrarySnapshot, to url: URL) throws {
        try validate(snapshot)
        let payload = try JSONEncoder().encode(snapshot)
        let envelope = Envelope(format: 1, createdAt: Date(), checksum: digest(payload), payload: payload)
        try JSONEncoder().encode(envelope).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func read(from url: URL) throws -> LibrarySnapshot {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 256_000_001), data.count <= 256_000_000 else { throw StudioError.message("Backup is too large.") }
        let value = try JSONDecoder().decode(Envelope.self, from: data)
        guard value.format == 1, value.checksum == digest(value.payload) else { throw StudioError.message("Backup format or checksum is invalid.") }
        let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: value.payload)
        try validate(snapshot)
        return snapshot
    }
    public static func validate(_ snapshot: LibrarySnapshot) throws {
        let skills = Set(snapshot.skills.map(\.id)), versions = Set(snapshot.versions.map(\.id))
        guard skills.count == snapshot.skills.count, versions.count == snapshot.versions.count,
              Set(snapshot.runs.map(\.id)).count == snapshot.runs.count,
              Set(snapshot.improvements.map(\.id)).count == snapshot.improvements.count,
              snapshot.versions.allSatisfy({ skills.contains($0.skillID) }),
              snapshot.skills.allSatisfy({ skill in
                  snapshot.versions.contains { $0.id == skill.activeVersionID && $0.skillID == skill.id } &&
                  (skill.lastPublishedVersionID == nil || snapshot.versions.contains { $0.id == skill.lastPublishedVersionID && $0.skillID == skill.id })
              }),
              snapshot.runs.allSatisfy({ run in skills.contains(run.skillID) && RunVersionIntegrity.validate(run, versions: snapshot.versions) }),
              snapshot.historyPolicy.retentionDays >= 0, snapshot.historyPolicy.retentionDays <= 36500,
              snapshot.improvements.allSatisfy({ item in
                  skills.contains(item.skillID) && snapshot.versions.contains { $0.id == item.baseVersionID && $0.skillID == item.skillID } &&
                  (item.savedVersionID == nil || snapshot.versions.contains { $0.id == item.savedVersionID && $0.skillID == item.skillID }) &&
                  (item.sourceRunID.map { id in
                      if let run = snapshot.runs.first(where: { $0.id == id }) { return run.skillID == item.skillID }
                      return snapshot.deletedRunIDs.contains(id)
                  } ?? true)
              }) else {
            throw StudioError.message("Backup contains inconsistent library records.")
        }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

public struct ImprovementRecord: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var skillID: String
    public var baseVersionID: UUID
    public var createdAt = Date()
    public var updatedAt = Date()
    public var instruction = ""
    public var selection: SelectionComment?
    public var provider = ""
    public var model = ""
    public var includesRun = false
    public var referenceAcknowledged: Bool?
    public var sourceRunID: UUID?
    public var draft: String?
    public var explanation = ""
    public var status = "draft"
    public var savedVersionID: UUID?
    public init(skillID: String, baseVersionID: UUID) { self.skillID = skillID; self.baseVersionID = baseVersionID }
}

public struct HistoryPolicy: Codable, Equatable, Sendable {
    public var enabledAgents: Set<AgentKind> = Set(AgentKind.allCases)
    public var retentionDays = 90
    public var excludedPaths: [String] = []
    public init() {}
    public func allows(_ path: String?) -> Bool {
        guard let path else { return true }
        let full = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
        return !excludedPaths.contains { raw in
            let root = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
            return full == root || full.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }
}

/// Caller must hold LibraryLease and close any existing database before invoking recovery.
public enum LibraryRecovery {
    public static func replaceUnreadableDatabase(at target: URL, with snapshot: LibrarySnapshot) throws -> StudioDatabase {
        try LibraryBackup.validate(snapshot)
        let fm = FileManager.default
        let recovery = target.deletingLastPathComponent().appendingPathComponent("Recovery-" + UUID().uuidString)
        try fm.createDirectory(at: recovery, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staged = recovery.appendingPathComponent("replacement.sqlite")
        do { let db = try StudioDatabase(url: staged); try db.save(snapshot) }
        var moved: [(URL, URL)] = []
        var installed = false
        do {
            for suffix in ["", "-wal", "-shm"] {
                let original = URL(fileURLWithPath: target.path + suffix)
                if fm.fileExists(atPath: original.path) {
                    let saved = recovery.appendingPathComponent("original.sqlite" + suffix)
                    try fm.moveItem(at: original, to: saved); moved.append((original, saved))
                }
            }
            try fm.moveItem(at: staged, to: target); installed = true
            let db = try StudioDatabase(url: target)
            guard try db.load() == snapshot else { throw StudioError.message("Recovered library could not be verified.") }
            return db
        } catch {
            if installed {
                for suffix in ["", "-wal", "-shm"] {
                    let file = URL(fileURLWithPath: target.path + suffix)
                    if fm.fileExists(atPath: file.path) { try? fm.moveItem(at: file, to: recovery.appendingPathComponent("failed-replacement.sqlite" + suffix)) }
                }
            }
            for (original, saved) in moved.reversed() { try? fm.moveItem(at: saved, to: original) }
            throw error
        }
    }
}
