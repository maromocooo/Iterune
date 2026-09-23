import XCTest
@testable import SkillStudioCore

final class ImprovementAttributionTests: XCTestCase {
    private func fixture() -> LibrarySnapshot {
        var snapshot = LibrarySnapshot()
        let old = SkillVersion(skillID:"fixture",number:1,content:"# Older\n",note:"fixture")
        let current = SkillVersion(skillID:"fixture",number:2,content:"# Current\n",note:"fixture")
        snapshot.versions = [old,current]
        snapshot.skills = [.init(id:"fixture",agent:.codex,name:"Fixture",summary:"",sourcePath:nil,scope:"fixture",lastDiskContent:old.content,activeVersionID:current.id)]
        return snapshot
    }
    func testHistoricalReferenceNeverReplacesEditingBaseAndRequiresAcknowledgement() throws {
        var snapshot = fixture()
        let base = snapshot.versions[1]
        let old = SkillRun(skillID:"fixture",versionID:snapshot.versions[0].id,prompt:"Historical prompt",output:"Historical output")
        let unknown = SkillRun(skillID:"fixture",versionID:nil,prompt:"Unknown prompt",output:"Unknown output",versionAttribution:.unknown(.incompleteRead))
        for run in [old,unknown] {
            XCTAssertTrue(RunVersionPresentation.requiresReferenceAcknowledgement(run:run,base:base))
            let request = ImprovementRequest(skill:snapshot.skills[0],version:base,referenceRun:run,feedback:"Improve")
            XCTAssertEqual(request.version.id,base.id); XCTAssertNil(request.run)
        }
        let manual = SkillRun(skillID:"fixture",versionID:base.id,prompt:"P",output:"O",versionAttribution:.init(kind:.manualAssociation))
        XCTAssertFalse(RunVersionPresentation.requiresReferenceAcknowledgement(run:manual,base:base))
        XCTAssertFalse(RunVersionPresentation.requiresReferenceAcknowledgement(run:nil,base:base))
        let prior = snapshot
        XCTAssertThrowsError(try Versioning.append(to:&snapshot,skillID:"fixture",content:"Unsafe",note:"fixture",expectedVersionID:snapshot.versions[0].id))
        XCTAssertEqual(snapshot,prior)
        let saved = try Versioning.append(to:&snapshot,skillID:"fixture",content:"# Improved",note:"fixture",expectedVersionID:base.id)
        XCTAssertEqual(saved.number,3)
        let afterSave = snapshot
        XCTAssertThrowsError(try Versioning.append(to:&snapshot,skillID:"fixture",content:"Stale proposal",note:"fixture",expectedVersionID:base.id))
        XCTAssertEqual(snapshot,afterSave)
    }
    func testRequestOptInAndDraftRoundTripKeepRunAndBaseSeparate() throws {
        var snapshot = fixture()
        let old = SkillRun(skillID:"fixture",versionID:nil,prompt:"PRIVATE_SYNTHETIC_PROMPT",output:"PRIVATE_SYNTHETIC_OUTPUT",feedback:"PRIVATE_SYNTHETIC_FEEDBACK",versionAttribution:.unknown(.unsupportedReadFormat))
        snapshot.runs = [old]
        let base = snapshot.versions[1]
        let service = AIImprovementService(generator:NeverCalledGenerator(),displayName:"Fixture",language:.english)
        let excluded = ImprovementRequest(skill:snapshot.skills[0],version:base,referenceRun:old,feedback:"Improve")
        let excludedPrompt = try service.makePrompt(excluded)
        XCTAssertFalse(excludedPrompt.contains("PRIVATE_SYNTHETIC"))
        XCTAssertTrue(excludedPrompt.contains("# Current"))
        let included = ImprovementRequest(skill:snapshot.skills[0],version:base,referenceRun:old,includeRun:true,feedback:"Improve")
        let includedPrompt = try service.makePrompt(included)
        XCTAssertTrue(includedPrompt.contains(old.prompt)); XCTAssertTrue(includedPrompt.contains(old.output))
        XCTAssertTrue(includedPrompt.contains("Historical reference only"))
        XCTAssertTrue(includedPrompt.contains("run_version_attribution"))
        XCTAssertFalse(excludedPrompt.contains("run_version_attribution"))
        var record = ImprovementRecord(skillID:"fixture",baseVersionID:base.id)
        record.sourceRunID = old.id; record.instruction = "Improve"; record.referenceAcknowledged = true; record.draft = "# Draft"
        snapshot.improvements = [record]
        let restored = try JSONDecoder().decode(LibrarySnapshot.self,from:JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored.improvements[0].baseVersionID,base.id)
        XCTAssertEqual(restored.improvements[0].sourceRunID,old.id)
        XCTAssertFalse(restored.improvements[0].includesRun)
        XCTAssertEqual(restored.improvements[0].referenceAcknowledged,true)
        try LibraryBackup.validate(restored)
    }
    func testEvidenceLabelsDistinguishManualLegacyMatchingAndUncertainty() {
        let snapshot = fixture(), v1 = snapshot.versions[0]
        let result = RunVersionResolver.resolve([.complete(v1.content)],skillID:"fixture",versions:snapshot.versions)
        var run = SkillRun(skillID:"fixture",versionID:v1.id,prompt:"P",output:"O",versionAttribution:result.attribution,readEvidence:result.reads)
        let matching = RunVersionPresentation.label(run,versions:snapshot.versions)
        run.versionAttribution = .init(kind:.manualAssociation)
        let manual = RunVersionPresentation.label(run,versions:snapshot.versions)
        run.versionAttribution = nil
        let legacy = RunVersionPresentation.label(run,versions:snapshot.versions)
        run.versionID = nil; run.versionAttribution = .unknown(.incompleteRead)
        let partial = RunVersionPresentation.label(run,versions:snapshot.versions)
        run.versionAttribution = .unknown(.noMatchingVersion)
        let noMatch = RunVersionPresentation.label(run,versions:snapshot.versions)
        XCTAssertEqual(Set([matching,manual,legacy,partial,noMatch]).count,5)
        XCTAssertTrue(matching.contains("v1")); XCTAssertTrue(manual.contains("v1")); XCTAssertTrue(legacy.contains("v1"))
    }
}

private struct NeverCalledGenerator: TextGenerationService {
    func generate(_ request: TextGenerationRequest) async throws -> String { XCTFail("No real AI calls are permitted"); return "" }
}
