import XCTest
import CryptoKit
@testable import SkillStudioCore

final class RunAttributionPersistenceTests: XCTestCase {
    private func fixture() -> LibrarySnapshot {
        var snapshot = LibrarySnapshot()
        let v1 = SkillVersion(skillID:"fixture", number:1, content:"A", note:"fixture")
        snapshot.versions = [v1]
        snapshot.skills = [.init(id:"fixture", agent:.codex, name:"Fixture", summary:"", sourcePath:"/fixture/SKILL.md", scope:"fixture", lastDiskContent:"A", activeVersionID:v1.id)]
        return snapshot
    }
    private func imported(_ snapshot: LibrarySnapshot, reads: [HistoricalSkillRead] = [.complete("A")], id: UUID = UUID()) -> SkillRun {
        let result = RunVersionResolver.resolve(reads, skillID:"fixture", versions:snapshot.versions)
        return .init(id:id, skillID:"fixture", versionID:result.versionID, prompt:"Synthetic request", output:"Synthetic answer",
                     capture:.init(sessionID:"session", turnID:"turn", sourceLog:"/fixture/log", command:"cat /fixture/SKILL.md"),
                     versionAttribution:result.attribution, readEvidence:result.reads)
    }
    func testReimportFreezesAssociationButRefreshesAnswerAndPreservesReview() throws {
        var snapshot = fixture()
        var original = imported(snapshot); original.rating = .needsWork; original.feedback = "More detail"
        XCTAssertEqual(RunHistoryMerge.merge([original, original], into:&snapshot), 1)
        let association = snapshot.runs[0].versionAttribution
        let originalVersion = snapshot.versions[0]
        _ = try Versioning.append(to:&snapshot, skillID:"fixture", content:"B", note:"fixture")
        _ = try Versioning.rollback(originalVersion.id, in:&snapshot)
        snapshot.versions.reverse()
        var incoming = imported(snapshot, id:original.id); incoming.output = "Updated final answer"
        XCTAssertNil(incoming.versionID) // New lookup would now be ambiguous; the previous frozen result stays intact.
        XCTAssertEqual(RunHistoryMerge.merge([incoming], into:&snapshot), 0)
        XCTAssertEqual(snapshot.runs[0].versionID, original.versionID)
        XCTAssertEqual(snapshot.runs[0].versionAttribution, association)
        XCTAssertEqual(snapshot.runs[0].rating, .needsWork); XCTAssertEqual(snapshot.runs[0].feedback, "More detail")
        XCTAssertEqual(snapshot.runs[0].output, "Updated final answer")
        let partial = imported(snapshot, reads:[.incomplete], id:original.id)
        RunHistoryMerge.merge([partial], into:&snapshot)
        XCTAssertEqual(snapshot.runs[0].versionID, original.versionID)
        XCTAssertEqual(snapshot.runs[0].readEvidence?.completeBodySHA256.count, 1)
        XCTAssertTrue(snapshot.runs[0].readEvidence?.sawIncompleteRead == true)
        try LibraryBackup.validate(snapshot)
        snapshot.deletedRunIDs.insert(original.id); snapshot.runs = []
        XCTAssertEqual(RunHistoryMerge.merge([incoming], into:&snapshot), 0)
    }
    func testManualLegacyAndNoMatchNeverSilentlyPromote() throws {
        for kind in [RunVersionKind.manualAssociation, .legacyUnverified] {
            var snapshot = fixture()
            var previous = imported(snapshot)
            previous.versionAttribution = kind == .legacyUnverified ? nil : .init(kind:kind)
            previous.readEvidence = nil
            snapshot.runs = [previous]
            _ = try Versioning.append(to:&snapshot, skillID:"fixture", content:"B", note:"fixture")
            var incoming = imported(snapshot, reads:[.complete("B")], id:previous.id); incoming.output = "New answer"
            RunHistoryMerge.merge([incoming], into:&snapshot)
            XCTAssertEqual(snapshot.runs[0].versionID, previous.versionID)
            XCTAssertEqual(snapshot.runs[0].effectiveVersionAttribution.kind, kind)
            XCTAssertEqual(snapshot.runs[0].output, "New answer")
        }
        var snapshot = fixture()
        let noMatch = imported(snapshot, reads:[.complete("B")])
        RunHistoryMerge.merge([noMatch], into:&snapshot)
        _ = try Versioning.append(to:&snapshot, skillID:"fixture", content:"B", note:"fixture")
        RunHistoryMerge.merge([imported(snapshot, reads:[.complete("B")], id:noMatch.id)], into:&snapshot)
        XCTAssertEqual(snapshot.runs[0].effectiveVersionAttribution.reason, .noMatchingVersion)
    }
    func testNewEvidenceCanCompleteAnUnknownOrConflictButNeverCrossIdentity() {
        var snapshot = fixture()
        let partial = imported(snapshot, reads:[.incomplete])
        RunHistoryMerge.merge([partial], into:&snapshot)
        RunHistoryMerge.merge([imported(snapshot, id:partial.id)], into:&snapshot)
        XCTAssertEqual(snapshot.runs[0].effectiveVersionAttribution.kind, .matchingContent)
        RunHistoryMerge.merge([imported(snapshot, reads:[.complete("B")], id:partial.id)], into:&snapshot)
        XCTAssertNil(snapshot.runs[0].versionID)
        XCTAssertEqual(snapshot.runs[0].effectiveVersionAttribution.reason, .conflictingReadEvidence)
        RunHistoryMerge.merge([imported(snapshot, id:partial.id)], into:&snapshot)
        XCTAssertEqual(snapshot.runs[0].effectiveVersionAttribution.reason, .conflictingReadEvidence)
        let before = snapshot
        for capture in [RunCaptureEvidence(sessionID:"another",turnID:"turn",sourceLog:"/fixture/log",command:"read"),
                        RunCaptureEvidence(sessionID:"session",turnID:"another",sourceLog:"/fixture/log",command:"read")] {
            var incoming = imported(snapshot, id:partial.id); incoming.capture = capture
            RunHistoryMerge.merge([incoming], into:&snapshot); XCTAssertEqual(snapshot,before)
        }
        var wrong = imported(snapshot, id:partial.id); wrong.skillID = "other"
        RunHistoryMerge.merge([wrong], into:&snapshot); XCTAssertEqual(snapshot,before)
    }
    func testManualUnknownAndForeignReferenceRejection() throws {
        var snapshot = fixture()
        try RunVersionIntegrity.recordManual(.init(skillID:"fixture",versionID:nil,prompt:"Prompt",output:"Output"), into:&snapshot)
        XCTAssertEqual(snapshot.runs[0].effectiveVersionAttribution, .unknown(.notSpecified))
        try RunVersionIntegrity.recordManual(.init(skillID:"fixture",versionID:snapshot.versions[0].id,prompt:"Prompt",output:"Output"), into:&snapshot)
        XCTAssertEqual(snapshot.runs[1].effectiveVersionAttribution.kind, .manualAssociation)
        let foreign = SkillVersion(skillID:"other",number:1,content:"A",note:"fixture")
        snapshot.versions.append(foreign)
        XCTAssertThrowsError(try RunVersionIntegrity.recordManual(.init(skillID:"fixture",versionID:foreign.id,prompt:"P",output:"O"), into:&snapshot))
        XCTAssertThrowsError(try RunVersionIntegrity.recordManual(.init(skillID:"missing",versionID:nil,prompt:"P",output:"O"), into:&snapshot))
        snapshot.versions.removeLast()
        snapshot.runs[1].versionAttribution = .init(kind:.matchingContent,candidateVersionIDs:[foreign.id])
        XCTAssertThrowsError(try LibraryBackup.validate(snapshot))
    }
    func testImprovementRejectsForeignRunEvenIfMarkedDeleted() throws {
        var snapshot = fixture()
        let foreignVersion = SkillVersion(skillID:"other",number:1,content:"B",note:"fixture")
        snapshot.versions.append(foreignVersion)
        snapshot.skills.append(.init(id:"other",agent:.claude,name:"Other",summary:"",sourcePath:nil,scope:"fixture",lastDiskContent:"B",activeVersionID:foreignVersion.id))
        let foreignRun = SkillRun(skillID:"other",versionID:nil,prompt:"P",output:"O")
        snapshot.runs = [foreignRun]; snapshot.deletedRunIDs.insert(foreignRun.id)
        var record = ImprovementRecord(skillID:"fixture",baseVersionID:snapshot.versions[0].id)
        record.sourceRunID = foreignRun.id; snapshot.improvements = [record]
        XCTAssertThrowsError(try LibraryBackup.validate(snapshot))
        snapshot.runs = [] // A genuinely deleted run's ID remains a valid historical reference.
        XCTAssertNoThrow(try LibraryBackup.validate(snapshot))
    }
    func testLegacySnapshotSQLiteAndBackupPreserveAllFields() throws {
        var original = fixture()
        var captured = imported(original); captured.rating = .good; captured.feedback = "Keep this"
        captured.artifacts = [.init(name:"synthetic.md",path:"/fixture/synthetic.md")]
        original.runs = [captured, .init(skillID:"fixture",versionID:original.versions[0].id,prompt:"Manual",output:"Result")]
        var demo = original.runs[1]; demo.id = UUID(); demo.isDemo = true; original.runs.append(demo)
        original.projectPaths = ["/fixture/project"]; original.deletedRunIDs = [UUID()]; original.historyPolicy.retentionDays = 21
        var record = ImprovementRecord(skillID:"fixture",baseVersionID:original.versions[0].id)
        record.sourceRunID = captured.id; record.savedVersionID = original.versions[0].id; record.instruction = "More detail"; record.draft = "Draft"
        original.improvements = [record]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(original)) as? [String:Any])
        var runs = object["runs"] as! [[String:Any]]
        for i in runs.indices { runs[i].removeValue(forKey:"versionAttribution"); runs[i].removeValue(forKey:"readEvidence") }
        object["runs"] = runs
        let payload = try JSONSerialization.data(withJSONObject:object)
        let legacy = try JSONDecoder().decode(LibrarySnapshot.self, from:payload)
        for run in legacy.runs { XCTAssertEqual(run.effectiveVersionAttribution.kind, .legacyUnverified) }
        XCTAssertEqual(legacy.runs.map(\.versionID), original.runs.map(\.versionID))
        XCTAssertEqual(legacy.improvements,original.improvements)
        XCTAssertEqual(legacy.runs[0].artifacts,captured.artifacts)
        XCTAssertEqual(legacy.deletedRunIDs,original.deletedRunIDs); XCTAssertEqual(legacy.historyPolicy,original.historyPolicy)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = try prepareTestRuntime(at: root)
        defer { try? FileManager.default.removeItem(at:root) }
        // Existing format-1 backup, including a legacy payload and its original checksum.
        let oldURL = root.appendingPathComponent("old.skillstudio")
        let checksum = SHA256.hash(data:payload).map { String(format:"%02x",$0) }.joined()
        try JSONSerialization.data(withJSONObject:["format":1,"createdAt":0,"payload":payload.base64EncodedString(),"checksum":checksum]).write(to:oldURL)
        XCTAssertEqual(try LibraryBackup.read(from:oldURL),legacy)
        var snapshot = legacy
        try RunVersionIntegrity.recordManual(.init(skillID:"fixture",versionID:nil,prompt:"Unknown",output:"Result"),into:&snapshot)
        var new = imported(snapshot); new.id = UUID(); snapshot.runs.append(new)
        let ambiguousVersion = try Versioning.rollback(snapshot.versions[0].id,in:&snapshot)
        XCTAssertEqual(ambiguousVersion.content,"A")
        snapshot.runs.append(imported(snapshot))
        let dbURL = root.appendingPathComponent("test.sqlite")
        do { let db = try isolatedTestDatabase(url:dbURL); try db.save(snapshot) }
        XCTAssertEqual(try isolatedTestDatabase(url:dbURL).load(),snapshot)
        let backup = root.appendingPathComponent("test.skillstudio")
        try LibraryBackup.write(snapshot,to:backup)
        XCTAssertEqual(try LibraryBackup.read(from:backup),snapshot)
        snapshot.runs[0].versionID = UUID()
        XCTAssertThrowsError(try LibraryBackup.validate(snapshot))
        XCTAssertThrowsError(try isolatedTestDatabase(url:dbURL).save(snapshot))
    }
}
