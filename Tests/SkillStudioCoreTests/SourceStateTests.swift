import XCTest
import CSQLite
@testable import SkillStudioCore

final class SourceStateTests: XCTestCase {
    private var root: URL!
    private var source: URL { root.appendingPathComponent(".claude/skills/fixture/SKILL.md") }
    private var context: DiscoveryContext { DiscoveryContext(home: root, environment: [:], systemDirectory: root.appendingPathComponent("synthetic-etc")) }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SourceState-" + UUID().uuidString).resolvingSymlinksInPath()
        _ = try prepareTestRuntime(at: root)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("A\n".utf8).write(to: source)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func scan(_ snapshot: inout LibrarySnapshot) throws { try Versioning.merge(SkillScanner().scan(context: context), into: &snapshot) }
    private func fixture() throws -> LibrarySnapshot {
        var snapshot = LibrarySnapshot(); try scan(&snapshot)
        let id = snapshot.skills[0].id
        let resolution = RunVersionResolver.resolve([.complete("A\n")], skillID: id, versions: snapshot.versions)
        let run = SkillRun(skillID: id, versionID: resolution.versionID, prompt: "Synthetic request", output: "Synthetic answer", rating: .needsWork, feedback: "Synthetic feedback",
                           versionAttribution: resolution.attribution, readEvidence: resolution.reads)
        snapshot.runs = [run]
        var improvement = ImprovementRecord(skillID: id, baseVersionID: snapshot.skills[0].activeVersionID)
        improvement.sourceRunID = run.id; improvement.draft = "B\n"; improvement.includesRun = false
        snapshot.improvements = [improvement]
        snapshot.deletedRunIDs.insert(UUID())
        snapshot.historyPolicy.enabledAgents = []
        return snapshot
    }
    func testUnpublishedEditSurvivesExternalChangeRescanAndRestart() throws {
        var snapshot = try fixture()
        let original = snapshot
        let id = snapshot.skills[0].id
        let edit = try Versioning.append(to: &snapshot, skillID: id, content: "B\n", note: "edit")
        XCTAssertEqual(try Data(contentsOf: source), Data("A\n".utf8))
        try Data("C\n".utf8).write(to: source)
        XCTAssertThrowsError(try SourcePublisher.prepare(skillID: id, in: snapshot, context: context))
        try scan(&snapshot)
        XCTAssertEqual(snapshot.skills[0].activeVersionID, edit.id)
        XCTAssertEqual(snapshot.skills[0].lastDiskContent, "C\n")
        XCTAssertTrue(snapshot.skills[0].sourceObservation?.externalChange == true)
        XCTAssertTrue(snapshot.versions.contains { $0.content == "C\n" })
        let count = snapshot.versions.count
        try scan(&snapshot); try scan(&snapshot)
        XCTAssertEqual(snapshot.versions.count, count)
        XCTAssertEqual(snapshot.runs, original.runs)
        XCTAssertEqual(snapshot.improvements, original.improvements)
        let databaseURL = root.appendingPathComponent("synthetic.sqlite")
        do { let database = try isolatedTestDatabase(url: databaseURL); try database.save(snapshot) }
        let reloaded = try isolatedTestDatabase(url: databaseURL).load()
        XCTAssertEqual(reloaded, snapshot)
        let request = try SourcePublisher.prepare(skillID: id, in: reloaded, context: context)
        XCTAssertEqual(request.expectedSource, "C\n"); XCTAssertEqual(request.content, "B\n")
        XCTAssertEqual(request.versionID, edit.id)
    }
    func testCleanEditingVersionFollowsExternalChangeButMatchingDraftDoesNotGrowRevisions() throws {
        var snapshot = try fixture()
        try Data("C\n".utf8).write(to: source); try scan(&snapshot)
        XCTAssertEqual(snapshot.skills[0].activeVersionID, snapshot.versions.last?.id)
        let id = snapshot.skills[0].id
        let edit = try Versioning.append(to: &snapshot, skillID: id, content: "B\n", note: "edit")
        let count = snapshot.versions.count
        try Data("B\n".utf8).write(to: source); try scan(&snapshot)
        XCTAssertEqual(snapshot.versions.count, count)
        XCTAssertEqual(snapshot.skills[0].activeVersionID, edit.id)
        XCTAssertFalse(SourceStatePresentation.differsFromObserved(snapshot.skills[0], versions: snapshot.versions))
        XCTAssertNil(snapshot.skills[0].lastPublishedVersionID, "An external edit is not a Studio publish receipt")
    }
    func testRollbackRemainsLibraryOnlyAndObservedTextCanMatchMultipleRevisions() throws {
        var snapshot = try fixture()
        let first = snapshot.versions[0], run = snapshot.runs[0]
        try Versioning.append(to: &snapshot, skillID: first.skillID, content: "B\n", note: "edit")
        let restored = try Versioning.rollback(first.id, in: &snapshot)
        XCTAssertEqual(try Data(contentsOf: source), Data("A\n".utf8))
        XCTAssertEqual(snapshot.skills[0].activeVersionID, restored.id)
        XCTAssertEqual(SourceStatePresentation.matchingObservedVersions(snapshot.skills[0], versions: snapshot.versions).map(\.id), [first.id, restored.id])
        XCTAssertEqual(snapshot.runs[0], run)
        XCTAssertNil(snapshot.skills[0].lastPublishedVersionID)
    }
    func testSourceWrittenDatabaseFailureIsPartialAndRescanDoesNotInventReceipt() throws {
        var snapshot = try fixture()
        let id = snapshot.skills[0].id
        let edit = try Versioning.append(to: &snapshot, skillID: id, content: "B\n", note: "edit")
        let before = snapshot
        let request = try SourcePublisher.prepare(skillID: id, in: snapshot, context: context)
        var attemptedSave = false
        let result = try PublishOperation.perform(request, snapshot: snapshot, context: context, backupDirectory: root.appendingPathComponent("backups")) { proposed in
            attemptedSave = true
            XCTAssertEqual(proposed.skills[0].lastPublishedVersionID, edit.id)
            throw StudioError.message("Synthetic database failure")
        }
        guard case .sourceWrittenLibrarySaveFailed(let receipt, _) = result else { return XCTFail("Expected partial success") }
        XCTAssertTrue(attemptedSave)
        XCTAssertEqual(snapshot, before)
        XCTAssertEqual(try Data(contentsOf: source), Data("B\n".utf8))
        XCTAssertEqual(try Data(contentsOf: receipt.backupURL), Data("A\n".utf8))
        XCTAssertThrowsError(try SourcePublisher.publish(request, in: snapshot, context: context, backupDirectory: root.appendingPathComponent("backups")))
        try scan(&snapshot)
        XCTAssertEqual(snapshot.skills[0].activeVersionID, edit.id)
        XCTAssertEqual(snapshot.skills[0].lastDiskContent, "B\n")
        XCTAssertNil(snapshot.skills[0].lastPublishedVersionID)
        XCTAssertEqual(snapshot.runs, before.runs); XCTAssertEqual(snapshot.improvements, before.improvements)
        XCTAssertEqual(snapshot.versions.count, before.versions.count)
    }
    func testSuccessfulPublishRecordsLibraryAndObservedStateSeparately() throws {
        var snapshot = try fixture()
        let id = snapshot.skills[0].id
        let edit = try Versioning.append(to: &snapshot, skillID: id, content: "B\n", note: "edit")
        let request = try SourcePublisher.prepare(skillID: id, in: snapshot, context: context)
        let result = try PublishOperation.perform(request, snapshot: snapshot, context: context, backupDirectory: root.appendingPathComponent("backups")) { snapshot = $0 }
        guard case .saved = result else { return XCTFail("Expected saved") }
        XCTAssertEqual(snapshot.skills[0].lastPublishedVersionID, edit.id)
        XCTAssertEqual(snapshot.skills[0].lastDiskContent, "B\n")
        XCTAssertFalse(SourceStatePresentation.differsFromObserved(snapshot.skills[0], versions: snapshot.versions))
        try Data("C\n".utf8).write(to: source); try scan(&snapshot)
        XCTAssertEqual(snapshot.skills[0].lastPublishedVersionID, edit.id)
        XCTAssertEqual(snapshot.skills[0].lastDiskContent, "C\n")
        XCTAssertFalse(SourceStatePresentation.matchingObservedVersions(snapshot.skills[0], versions: snapshot.versions).contains { $0.id == edit.id })
    }
    func testOldSQLiteAndBackupDecodeWithoutGrantingStoredWritePermission() throws {
        let snapshot = try fixture()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var skills = try XCTUnwrap(object["skills"] as? [[String: Any]])
        for index in skills.indices {
            for key in ["sourceProvenance", "sourceObservation", "lastPublishedVersionID"] { skills[index].removeValue(forKey: key) }
        }
        object["skills"] = skills
        let data = try JSONSerialization.data(withJSONObject: object)
        let url = root.appendingPathComponent("legacy.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE library (id INTEGER PRIMARY KEY, payload BLOB NOT NULL)", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO library VALUES(1, ?)", -1, &statement, nil), SQLITE_OK)
        data.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(statement, 1, buffer.baseAddress, Int32(buffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE); sqlite3_finalize(statement)
        var restored = try isolatedTestDatabase(url: url).load()
        XCTAssertNil(restored.skills[0].sourceProvenance); XCTAssertNil(restored.skills[0].sourceObservation)
        XCTAssertEqual(restored.runs, snapshot.runs); XCTAssertEqual(restored.improvements, snapshot.improvements)
        XCTAssertTrue(SourceStatePresentation.matchingObservedVersions(restored.skills[0], versions: restored.versions).isEmpty)
        try scan(&restored)
        XCTAssertEqual(restored.skills[0].sourceProvenance?.origin, .localUser)
        XCTAssertNoThrow(try SourcePublisher.prepare(skillID: restored.skills[0].id, in: restored, context: context))
        let backup = root.appendingPathComponent("synthetic.skillstudio")
        try LibraryBackup.write(restored, to: backup)
        let loaded = try LibraryBackup.read(from: backup)
        XCTAssertEqual(loaded, restored)
        XCTAssertEqual(try Data(contentsOf: source), Data("A\n".utf8))
        let otherContext = DiscoveryContext(home: root.appendingPathComponent("other-home"), environment: [:], systemDirectory: root.appendingPathComponent("other-etc"))
        XCTAssertThrowsError(try SourcePublisher.prepare(skillID: loaded.skills[0].id, in: loaded, context: otherContext))
    }
    func testBackupPreservesAttributionDraftsAndRejectsForeignPublishReference() throws {
        var snapshot = try fixture()
        let id = snapshot.skills[0].id
        let edit = try Versioning.append(to: &snapshot, skillID: id, content: "B\n", note: "edit")
        snapshot.skills[0].lastPublishedVersionID = snapshot.versions[0].id
        let beforeSource = try Data(contentsOf: source)
        let backup = root.appendingPathComponent("synthetic.skillstudio")
        try LibraryBackup.write(snapshot, to: backup)
        let restored = try LibraryBackup.read(from: backup)
        XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(restored.skills[0].activeVersionID, edit.id)
        XCTAssertTrue(SourceStatePresentation.differsFromObserved(restored.skills[0], versions: restored.versions))
        XCTAssertEqual(try Data(contentsOf: source), beforeSource)
        DemoLibrary.seed(into: &snapshot)
        snapshot.skills[0].lastPublishedVersionID = snapshot.versions.first { $0.skillID != id }?.id
        XCTAssertThrowsError(try LibraryBackup.validate(snapshot))
        XCTAssertThrowsError(try LibraryBackup.write(snapshot, to: backup))
    }
    func testDiffPreservesUnicodeNewlineAndWhitespaceBytes() {
        for (old, new) in [("é\n", "e\u{301}\n"), ("A\n", "A\r\n"), ("A\n", "A \n")] {
            let diff = LineDiff.compare(old: old, new: new)
            XCTAssertTrue(diff.contains { $0.kind == .removed })
            XCTAssertTrue(diff.contains { $0.kind == .added })
            XCTAssertEqual(Data(diff.filter { $0.kind != .added }.map(\.text).joined(separator: "\n").utf8), Data(old.utf8))
            XCTAssertEqual(Data(diff.filter { $0.kind != .removed }.map(\.text).joined(separator: "\n").utf8), Data(new.utf8))
        }
    }
}
