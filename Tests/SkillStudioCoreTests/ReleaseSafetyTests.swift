import XCTest
@testable import SkillStudioCore

final class ReleaseSafetyTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = try prepareTestRuntime(at: url); return url
    }
    func testLibraryLeaseAndConcurrentWriterProtection() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        var lease: LibraryLease? = try LibraryLease(directory: root)
        XCTAssertNotNil(lease); XCTAssertThrowsError(try LibraryLease(directory: root))
        lease = nil
        let replacement = try LibraryLease(directory: root); XCTAssertNotNil(replacement)
        let url = root.appendingPathComponent("test.sqlite")
        let first = try isolatedTestDatabase(url: url), stale = try isolatedTestDatabase(url: url)
        var snapshot = LibrarySnapshot(); DemoLibrary.seed(into: &snapshot)
        try first.save(snapshot)
        XCTAssertThrowsError(try stale.save(LibrarySnapshot()))
        XCTAssertEqual(try first.load(), snapshot)
    }
    func testBackupRoundTripIntegrityAndLegacyMigration() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        var snapshot = LibrarySnapshot(); DemoLibrary.seed(into: &snapshot)
        var record = ImprovementRecord(skillID: snapshot.skills[0].id, baseVersionID: snapshot.skills[0].activeVersionID)
        record.instruction = "日本語 fixture"; record.model = "fixture-model"
        record.selection = SelectionComment(quote: "quoted", context: "context", isTranslation: true)
        record.draft = "# Draft"; snapshot.improvements = [record]
        snapshot.deletedRunIDs = [UUID()]
        let url = root.appendingPathComponent("backup.skillstudio")
        try LibraryBackup.write(snapshot, to: url)
        XCTAssertEqual(try LibraryBackup.read(from: url), snapshot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["checksum"] = "corrupted"
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try LibraryBackup.read(from: url))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        for key in ["improvements", "historyPolicy", "deletedRunIDs"] { legacy.removeValue(forKey: key) }
        let restored = try JSONDecoder().decode(LibrarySnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(restored.improvements.isEmpty); XCTAssertEqual(restored.skills, snapshot.skills)
        snapshot.skills[0].activeVersionID = UUID()
        XCTAssertThrowsError(try LibraryBackup.validate(snapshot))
    }
    func testCorruptDatabaseRecoveryPreservesOriginal() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let lease = try LibraryLease(directory: root); XCTAssertNotNil(lease)
        let target = root.appendingPathComponent("studio.sqlite"), corrupt = Data("synthetic broken SQLite".utf8)
        try corrupt.write(to: target)
        XCTAssertThrowsError(try isolatedTestDatabase(url: target))
        var snapshot = LibrarySnapshot(); DemoLibrary.seed(into: &snapshot)
        let db = try LibraryRecovery.replaceUnreadableDatabase(at: target, with: snapshot, runtime: prepareTestRuntime(at: root))
        XCTAssertEqual(try db.load(), snapshot)
        let directory = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys:nil).first { $0.lastPathComponent.hasPrefix("Recovery-") })
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("original.sqlite")), corrupt)
    }
    func testDeletedRunsAndExclusionsSurviveReimport() throws {
        var snapshot = LibrarySnapshot(); DemoLibrary.seed(into: &snapshot)
        snapshot.skills[0].isDemo = false
        var run = snapshot.runs.first { $0.skillID == snapshot.skills[0].id }!
        run.id = UUID(); run.isDemo = false
        run.capture = RunCaptureEvidence(sessionID: "fixture", turnID: "fixture", sourceLog: "/fixture/private/run.jsonl", command: "Read")
        snapshot.deletedRunIDs.insert(run.id)
        XCTAssertEqual(RunHistoryMerge.merge([run], into: &snapshot), 0)
        run.id = UUID(); snapshot.historyPolicy.excludedPaths = ["/fixture/private"]
        XCTAssertEqual(RunHistoryMerge.merge([run], into: &snapshot), 0)
        XCTAssertTrue(snapshot.historyPolicy.allows("/fixture/private-other/run.jsonl"))
    }
}
