import XCTest
import Darwin
@testable import SkillStudioCore

final class SourcePublishSafetyTests: XCTestCase {
    private var root: URL!
    private var context: DiscoveryContext { DiscoveryContext(home: root, environment: [:], systemDirectory: root.appendingPathComponent("synthetic-etc")) }
    private var backups: URL { root.appendingPathComponent("private-backups") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SourceSafety-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    @discardableResult private func file(_ relative: String = ".claude/skills/example/SKILL.md", _ content: String = "A\n") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return url
    }
    private func library(_ context: DiscoveryContext? = nil) throws -> LibrarySnapshot {
        var snapshot = LibrarySnapshot()
        try Versioning.merge(SkillScanner().scan(context: context ?? self.context), into: &snapshot)
        return snapshot
    }
    private func edited() throws -> (URL, LibrarySnapshot, PublishRequest) {
        let url = try file()
        var snapshot = try library()
        let skill = try XCTUnwrap(snapshot.skills.first { $0.sourcePath == url.path })
        try Versioning.append(to: &snapshot, skillID: skill.id, content: "B\n", note: "edit")
        return (url, snapshot, try SourcePublisher.prepare(skillID: skill.id, in: snapshot, context: context))
    }
    private func assertBlocked(_ snapshot: LibrarySnapshot, _ id: String, reason: SourceRestriction? = nil,
                               context: DiscoveryContext? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SourcePublisher.prepare(skillID: id, in: snapshot, context: context ?? self.context), file: file, line: line) { error in
            if let reason { guard case SourcePublishError.blocked(reason) = error else { return XCTFail("Unexpected error: \(error)", file: file, line: line) } }
        }
    }
    func testLocalUserProjectSharedAndManualOnlyAreWritable() throws {
        let paths = [".claude/skills/user/SKILL.md", ".agents/skills/shared/SKILL.md", ".gemini/skills/user/SKILL.md",
                     "my-plugin-project/.claude/skills/project/SKILL.md", "my-plugin-project/.codex/skills/project/SKILL.md", "my-plugin-project/.gemini/skills/project/SKILL.md"]
        for path in paths { try file(path, "---\nname: example\ndisable-model-invocation: true\n---\nA\n") }
        let context = DiscoveryContext(home: root, projects: [root.appendingPathComponent("my-plugin-project")], environment: [:], systemDirectory: root.appendingPathComponent("synthetic-etc"))
        let snapshot = try library(context)
        XCTAssertEqual(snapshot.skills.count, 7)
        for skill in snapshot.skills {
            XCTAssertTrue(try XCTUnwrap(skill.sourceProvenance).origin.isLocal)
            XCTAssertEqual(SourcePublisher.eligibility(skillID: skill.id, in: snapshot, context: context), .allowed)
        }
    }
    func testProtectedAndMixedRootsOverrideWritableLocalScope() throws {
        let cases: [(String, SourceOrigin)] = [(".claude/skills/synced/example/SKILL.md", .synced),
            (".claude/plugins/cache/example/SKILL.md", .pluginCache), (".codex/plugins/cache/example/SKILL.md", .pluginCache),
            (".codex/skills/.system/example/SKILL.md", .bundled), (".codex/skills/uncertain/SKILL.md", .unknown),
            (".gemini/extensions/example/SKILL.md", .extensionCache), ("synthetic-etc/codex/skills/example/SKILL.md", .managed)]
        for (path, _) in cases { try file(path, "---\nname: user\nscope: User\norigin: localUser\n---\nA") }
        var snapshot = try library()
        for (path, origin) in cases {
            let i = try XCTUnwrap(snapshot.skills.firstIndex { $0.sourcePath == root.appendingPathComponent(path).path })
            XCTAssertEqual(snapshot.skills[i].sourceProvenance?.origin, origin)
            // A forged persisted permission and scope are not authorization.
            snapshot.skills[i].scope = "User"
            snapshot.skills[i].sourceProvenance = SourceProvenance(origin: .localUser)
            assertBlocked(snapshot, snapshot.skills[i].id)
            let id = snapshot.skills[i].id
            XCTAssertNoThrow(try Versioning.append(to: &snapshot, skillID: id, content: "library edit", note: "edit"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
        XCTAssertEqual(SourcePolicy.eligibility(provenance: .init(origin: .managed)), .readOnly(.externalManagement))
        XCTAssertEqual(CodexAdapter().roots(in: context).first { $0.origin == .managed }?.url.path, root.appendingPathComponent("synthetic-etc/codex/skills").path)
    }
    func testCustomRootsAndComponentContainment() throws {
        try file("custom-claude/skills/user/SKILL.md")
        try file("custom-codex/plugins/cache/plugin/SKILL.md")
        try file(".claude/skills/synced-name/SKILL.md")
        let custom = DiscoveryContext(home: root, environment: ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("custom-claude").path,
            "CODEX_HOME": root.appendingPathComponent("custom-codex").path], systemDirectory: root.appendingPathComponent("synthetic-etc"))
        let snapshot = try library(custom)
        let local = try XCTUnwrap(snapshot.skills.first { $0.agent == .claude })
        XCTAssertNoThrow(try SourcePublisher.prepare(skillID: local.id, in: snapshot, context: custom))
        assertBlocked(snapshot, try XCTUnwrap(snapshot.skills.first { $0.agent == .codex }).id, context: custom)
        let standard = try library()
        XCTAssertEqual(standard.skills.first?.sourceProvenance?.origin, .localUser)
        XCTAssertFalse(SourcePolicy.contains(root.appendingPathComponent(".claude/skills-extra/a"), in: root.appendingPathComponent(".claude/skills")))
    }
    func testProtectedAliasesWinRegardlessOfRootOrderAndAgent() throws {
        let source = try file()
        let alias = root.appendingPathComponent(".gemini/extensions/alias")
        try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source.deletingLastPathComponent())
        let forward = SkillScanner().scan(context: context)
        let reverse = SkillScanner(adapters: [GeminiAdapter(), CodexAdapter(), ClaudeAdapter()]).scan(context: context)
        for report in [forward, reverse] {
            let entry = try XCTUnwrap(report.skills.first { $0.agent == .claude })
            XCTAssertEqual(entry.provenance?.origin, .extensionCache)
            XCTAssertTrue(entry.provenance?.hasLinkedPath == true)
        }
        var snapshot = try library()
        let skill = try XCTUnwrap(snapshot.skills.first { $0.agent == .claude })
        snapshot.skills[0].sourceProvenance = nil
        assertBlocked(snapshot, skill.id)
    }
    func testDirectoryFinalLinksHardlinksAndTrustedRootAlias() throws {
        let source = try file()
        var snapshot = try library()
        let id = snapshot.skills[0].id
        let external = try file("outside/SKILL.md")
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: external)
        assertBlocked(snapshot, id, reason: .linkedPath)
        XCTAssertEqual(try library().skills.first?.id, id, "A final link does not change existing IDs")
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(link(external.path, source.path), 0)
        assertBlocked(snapshot, id, reason: .sharedFile)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.removeItem(at: source.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: source.deletingLastPathComponent(), withDestinationURL: external.deletingLastPathComponent())
        snapshot = try library()
        assertBlocked(snapshot, snapshot.skills[0].id, reason: .linkedPath)
        // /tmp's known alias is accepted as a trusted HOME boundary, not a link below that boundary.
        let homeAlias = URL(fileURLWithPath: root.path.replacingOccurrences(of: "/private/var/", with: "/var/"))
        let other = try file(".gemini/skills/plain/SKILL.md")
        let aliased = DiscoveryContext(home: homeAlias, environment: [:], systemDirectory: root.appendingPathComponent("synthetic-etc"))
        let state = try library(aliased)
        let skill = try XCTUnwrap(state.skills.first { $0.sourcePath == other.path })
        XCTAssertNoThrow(try SourcePublisher.prepare(skillID: skill.id, in: state, context: aliased))
    }
    func testMissingDirectoryFIFOReadOnlyAndChangedPathAreRejected() throws {
        let (source, state, request) = try edited()
        var forged = state
        forged.skills[0].sourcePath = try file("outside/SKILL.md").path
        assertBlocked(forged, request.skillID, reason: .unknownOrigin)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: source.path)
        assertBlocked(state, request.skillID, reason: .notWritable)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? NSNumber)?.intValue, 0o400)
        try FileManager.default.removeItem(at: source)
        assertBlocked(state, request.skillID, reason: .missingOrUnreadable)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        assertBlocked(state, request.skillID, reason: .nonRegularFile)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(mkfifo(source.path, 0o600), 0)
        assertBlocked(state, request.skillID, reason: .nonRegularFile)
        XCTAssertTrue(SkillScanner().scan(context: context).skills.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }
    func testFrozenRequestWritesExactBytesAndPrivateUniqueBackup() throws {
        let (source, snapshot, request) = try edited()
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
        let refreshed = try SourcePublisher.prepare(skillID: request.skillID, in: snapshot, context: context)
        let receipt = try SourcePublisher.publish(refreshed, in: snapshot, context: context, backupDirectory: backups)
        XCTAssertEqual(try Data(contentsOf: source), Data("B\n".utf8))
        XCTAssertEqual(try Data(contentsOf: receipt.backupURL), Data("A\n".utf8))
        for (url, mode) in [(source, 0o640), (backups, 0o700), (receipt.backupURL, 0o600)] {
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, mode)
        }
        XCTAssertThrowsError(try SourcePublisher.publish(refreshed, in: snapshot, context: context, backupDirectory: backups))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path).count, 1)
        var next = snapshot
        try Versioning.merge(SkillScanner().scan(context: context), into: &next)
        try Versioning.append(to: &next, skillID: request.skillID, content: "C", note: "edit")
        let second = try SourcePublisher.prepare(skillID: request.skillID, in: next, context: context)
        let backup2 = try SourcePublisher.publish(second, in: next, context: context, backupDirectory: backups).backupURL
        XCTAssertNotEqual(backup2, receipt.backupURL)
        XCTAssertEqual(try Data(contentsOf: receipt.backupURL), Data("A\n".utf8))
        XCTAssertEqual(try Data(contentsOf: backup2), Data("B\n".utf8))
    }
    func testByteDifferencesAndLibraryChangesInvalidateConfirmation() throws {
        let (source, snapshot, request) = try edited()
        for changed in ["A\r\n", "A \n", "Á\n", "A\u{301}\n"] {
            try Data(changed.utf8).write(to: source)
            XCTAssertThrowsError(try SourcePublisher.publish(request, in: snapshot, context: context, backupDirectory: backups))
            XCTAssertEqual(try Data(contentsOf: source), Data(changed.utf8))
        }
        try Data("A\n".utf8).write(to: source)
        let fresh = try SourcePublisher.prepare(skillID: request.skillID, in: snapshot, context: context)
        var changedLibrary = snapshot
        try Versioning.append(to: &changedLibrary, skillID: request.skillID, content: "B\n", note: "same text, new ID")
        XCTAssertThrowsError(try SourcePublisher.publish(fresh, in: changedLibrary, context: context, backupDirectory: backups))
        var foreign = snapshot
        foreign.versions[1].skillID = "another skill"
        assertBlocked(foreign, request.skillID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }
    func testCanonicalUnicodeDifferenceIsAnExternalChange() throws {
        let source = try file(".claude/skills/example/SKILL.md", "é\n")
        let snapshot = try library()
        let request = try SourcePublisher.prepare(skillID: snapshot.skills[0].id, in: snapshot, context: context)
        try Data("e\u{301}\n".utf8).write(to: source)
        XCTAssertThrowsError(try SourcePublisher.publish(request, in: snapshot, context: context, backupDirectory: backups))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }
    func testInjectedBackupTempAndReplacementFailuresLeaveSourceIntact() throws {
        let (source, snapshot, request) = try edited()
        for stage in [SourcePublisher.Stage.beforeBackup, .beforeTemporaryWrite, .beforeReplacement] {
            XCTAssertThrowsError(try SourcePublisher.publish(request, in: snapshot, context: context, backupDirectory: backups) {
                if $0 == stage { throw StudioError.message("Synthetic filesystem failure") }
            })
            XCTAssertEqual(try Data(contentsOf: source), Data("A\n".utf8))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path).contains { $0.hasPrefix(".skillstudio-") })
        }
        let invalidBackup = try file("not-a-directory")
        XCTAssertThrowsError(try SourcePublisher.publish(request, in: snapshot, context: context, backupDirectory: invalidBackup))
        XCTAssertEqual(try Data(contentsOf: source), Data("A\n".utf8))
    }
    func testSourceSwapAndPolicyChangeImmediatelyBeforeReplacement() throws {
        let (source, snapshot, request) = try edited()
        XCTAssertThrowsError(try SourcePublisher.publish(request, in: snapshot, context: context, backupDirectory: backups) { stage in
            if stage == .beforeReplacement { try Data("external\n".utf8).write(to: source, options: .atomic) }
        })
        XCTAssertEqual(try Data(contentsOf: source), Data("external\n".utf8))
        var refreshed = snapshot
        try Versioning.merge(SkillScanner().scan(context: context), into: &refreshed)
        let next = try SourcePublisher.prepare(skillID: request.skillID, in: refreshed, context: context)
        XCTAssertThrowsError(try SourcePublisher.publish(next, in: refreshed, context: context, backupDirectory: backups) { stage in
            if stage == .beforeReplacement {
                let alias = root.appendingPathComponent(".claude/plugins/cache/alias")
                try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source.deletingLastPathComponent())
            }
        })
        XCTAssertEqual(try Data(contentsOf: source), Data("external\n".utf8))
    }
    func testPartialTempWriteAndRenameErrorsKeepOriginalAndCleanOnlyOwnTemporaryFile() throws {
        let (source, snapshot, request) = try edited()
        let unrelated = source.deletingLastPathComponent().appendingPathComponent(".skillstudio-user.tmp")
        try Data("keep".utf8).write(to: unrelated)
        XCTAssertThrowsError(try SourcePublisher.publish(request, in: snapshot, context: context, backupDirectory: backups,
            checkpoint: { _ in }, writeTemporary: { _, fd in
                _ = Data("partial".utf8).withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                throw StudioError.message("Synthetic partial write failure")
            }))
        XCTAssertEqual(try Data(contentsOf: source), Data("A\n".utf8))
        XCTAssertThrowsError(try SourcePublisher.publish(request, in: snapshot, context: context, backupDirectory: backups,
            checkpoint: { _ in }, replace: { _, _ in errno = EIO; return -1 }))
        XCTAssertEqual(try Data(contentsOf: source), Data("A\n".utf8))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path).sorted(), [".skillstudio-user.tmp", "SKILL.md"])
    }
    func testNewProtectionRejectsFrozenRequestBeforeBackupAndForgedBackupCannotAuthorize() throws {
        let (source, snapshot, request) = try edited()
        let alias = root.appendingPathComponent(".claude/plugins/cache/alias")
        try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source.deletingLastPathComponent())
        XCTAssertThrowsError(try SourcePublisher.publish(request, in: snapshot, context: context, backupDirectory: backups))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
        var forged = snapshot
        forged.skills[0].sourceProvenance = .init(origin: .localUser)
        let saved = root.appendingPathComponent("forged.skillstudio")
        try LibraryBackup.write(forged, to: saved)
        let restored = try LibraryBackup.read(from: saved)
        assertBlocked(restored, request.skillID, reason: .externalManagement)
        XCTAssertEqual(try Data(contentsOf: source), Data("A\n".utf8))
    }
    func testIdenticalContentReplacementStillInvalidatesFileIdentity() throws {
        let (source, snapshot, request) = try edited()
        try Data(request.expectedSource.utf8).write(to: source, options: .atomic)
        XCTAssertThrowsError(try SourcePublisher.publish(request, in: snapshot, context: context, backupDirectory: backups))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
        let refreshed = try SourcePublisher.prepare(skillID: request.skillID, in: snapshot, context: context)
        XCTAssertNoThrow(try SourcePublisher.publish(refreshed, in: snapshot, context: context, backupDirectory: backups))
    }
    func testCleanupDoesNotDeleteReplacedTemporaryPath() throws {
        let (source, snapshot, request) = try edited()
        var replacedTemporaryName: String?
        XCTAssertThrowsError(try SourcePublisher.publish(request, in: snapshot, context: context, backupDirectory: backups,
            checkpoint: { _ in }, replace: { directory, name in
                // Simulate another process replacing the temporary path during a failed rename.
                let moved = name + ".external-move"
                XCTAssertEqual(renameat(directory, name, directory, moved), 0)
                let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                XCTAssertGreaterThanOrEqual(fd, 0); close(fd)
                replacedTemporaryName = name
                errno = EIO; return -1
            }))
        let name = try XCTUnwrap(replacedTemporaryName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.deletingLastPathComponent().appendingPathComponent(name).path))
        XCTAssertEqual(try Data(contentsOf: source), Data("A\n".utf8))
    }
    func testEmptyRegularSourceCanStillBeDiscovered() throws {
        try file(".claude/skills/empty/SKILL.md", "")
        let state = try library()
        XCTAssertEqual(state.skills.count, 1)
        XCTAssertEqual(state.skills.first?.lastDiskContent, "")
    }
    func testDemoAndMissingSourceNeverPublish() throws {
        var state = LibrarySnapshot(); DemoLibrary.seed(into: &state)
        for skill in state.skills { assertBlocked(state, skill.id, reason: .noSource) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }
}
