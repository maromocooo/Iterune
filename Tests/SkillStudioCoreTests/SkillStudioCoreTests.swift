import XCTest
@testable import SkillStudioCore

final class SkillStudioCoreTests: XCTestCase {
    private var temporary: URL!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SkillStudioTests-" + UUID().uuidString)
        _ = try prepareTestRuntime(at: temporary)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }
    @discardableResult private func write(_ path: String, content: String = "---\nname: example\ndescription: A sample skill\n---\n\n# Instructions\nDo the work.\n") throws -> URL {
        let url = temporary.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    func testThreeAdaptersAndSharedSkillIdentity() throws {
        try write(".claude/skills/one/SKILL.md")
        try write(".codex/skills/two/SKILL.md")
        try write(".gemini/skills/three/SKILL.md")
        try write(".agents/skills/shared/SKILL.md")
        let report = SkillScanner().scan(context: DiscoveryContext(home: temporary, environment: [:]))
        let local = report.skills.filter { $0.path.hasPrefix(temporary.path) }
        XCTAssertEqual(local.count, 5)
        XCTAssertEqual(Set(local.map(\.id)).count, 5)
        XCTAssertEqual(local.filter { $0.agent == .claude }.count, 1)
        XCTAssertEqual(local.filter { $0.agent == .codex }.count, 2)
        XCTAssertEqual(local.filter { $0.agent == .gemini }.count, 2)
    }
    func testMissingDirectoriesProduceEmptyReport() {
        let report = SkillScanner(adapters: [ClaudeAdapter(), GeminiAdapter()]).scan(context: DiscoveryContext(home: temporary, environment: [:]))
        XCTAssertTrue(report.skills.isEmpty)
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertFalse(report.roots.isEmpty)
    }
    func testSymlinkCycleAndDuplicateRootsAreDeduplicated() throws {
        let source = try write(".claude/skills/one/SKILL.md")
        try FileManager.default.createSymbolicLink(at: temporary.appendingPathComponent(".claude/skills/alias"), withDestinationURL: source.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: temporary.appendingPathComponent(".claude/skills/cycle"), withDestinationURL: temporary.appendingPathComponent(".claude/skills"))
        let report = SkillScanner(adapters: [ClaudeAdapter()]).scan(context: DiscoveryContext(home: temporary, projects: [temporary], environment: [:]))
        XCTAssertEqual(report.skills.count, 1)
        XCTAssertTrue(report.warnings.isEmpty)
    }
    func testScannerHonorsGeminiDepthAndSkipsBundledReferences() throws {
        try write(".gemini/skills/one/SKILL.md")
        try write(".gemini/skills/deep/two/SKILL.md")
        try write(".gemini/skills/one/references/SKILL.md")
        let report = SkillScanner(adapters: [GeminiAdapter()]).scan(context: DiscoveryContext(home: temporary, environment: [:]))
        XCTAssertEqual(report.skills.count, 1)
    }
    func testEnvironmentOverridesAndProjectPaths() throws {
        try write("custom-claude/skills/one/SKILL.md")
        try write("custom-codex/skills/two/SKILL.md")
        try write("project/.gemini/skills/three/SKILL.md")
        let report = SkillScanner().scan(context: DiscoveryContext(home: temporary, projects: [temporary.appendingPathComponent("project")], environment: [
            "CLAUDE_CONFIG_DIR": temporary.appendingPathComponent("custom-claude").path,
            "CODEX_HOME": temporary.appendingPathComponent("custom-codex").path
        ]))
        XCTAssertEqual(report.skills.filter { $0.path.hasPrefix(temporary.path) }.count, 3)
    }
    func testCodexFindsRepositoryAncestors() throws {
        try FileManager.default.createDirectory(at: temporary.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
        try write("repo/.agents/skills/root/SKILL.md")
        try write("repo/sub/.agents/skills/child/SKILL.md")
        let report = SkillScanner(adapters: [CodexAdapter()]).scan(context: DiscoveryContext(home: temporary, projects: [temporary.appendingPathComponent("repo/sub")], environment: [:]))
        XCTAssertEqual(report.skills.filter { $0.path.hasPrefix(temporary.path) }.count, 2)
    }
    func testFrontmatterQuotesMultilineAndFallback() {
        let metadata = SkillMetadata.parse("---\r\nname: 'my-skill'\r\ndescription: >-\r\n  First line\r\n  second line\r\n---\r\nbody", fallback: "folder")
        XCTAssertEqual(metadata.name, "my-skill")
        XCTAssertEqual(metadata.summary, "First line second line")
        XCTAssertEqual(SkillMetadata.parse("# Just markdown", fallback: "folder").name, "folder")
    }
    func testInvalidUTF8IsReportedWithoutLosingOtherSkills() throws {
        try write(".claude/skills/good/SKILL.md")
        let invalid = try write(".claude/skills/bad/SKILL.md")
        try Data([0xff, 0xfe, 0xff]).write(to: invalid)
        let report = SkillScanner(adapters: [ClaudeAdapter()]).scan(context: DiscoveryContext(home: temporary, environment: [:]))
        XCTAssertEqual(report.skills.count, 1)
        XCTAssertEqual(report.warnings.count, 1)
    }
    func testRescanPreservesDraftAndImportsExternalChanges() throws {
        let file = try write(".claude/skills/one/SKILL.md")
        let scanner = SkillScanner(adapters: [ClaudeAdapter()])
        let context = DiscoveryContext(home: temporary, environment: [:])
        var state = LibrarySnapshot()
        try Versioning.merge(scanner.scan(context: context), into: &state)
        let id = try XCTUnwrap(state.skills.first?.id)
        let draft = try Versioning.append(to: &state, skillID: id, content: "draft", note: "Edit")
        try Versioning.merge(scanner.scan(context: context), into: &state)
        XCTAssertEqual(state.versions.count, 2)
        XCTAssertEqual(state.skills[0].activeVersionID, draft.id)
        try "changed outside app".write(to: file, atomically: true, encoding: .utf8)
        try Versioning.merge(scanner.scan(context: context), into: &state)
        XCTAssertEqual(state.versions.count, 3)
        XCTAssertEqual(state.versions.last?.content, "changed outside app")
        XCTAssertTrue(state.versions.contains(draft))
    }
    func testMissingSourceRetainsHistoryAndReappears() throws {
        let file = try write(".claude/skills/one/SKILL.md")
        let scanner = SkillScanner(adapters: [ClaudeAdapter()])
        let context = DiscoveryContext(home: temporary, environment: [:])
        var state = LibrarySnapshot()
        try Versioning.merge(scanner.scan(context: context), into: &state)
        let content = try String(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try Versioning.merge(scanner.scan(context: context), into: &state)
        XCTAssertFalse(state.skills[0].isAvailable)
        XCTAssertEqual(state.versions.count, 1)
        try content.write(to: file, atomically: true, encoding: .utf8)
        try Versioning.merge(scanner.scan(context: context), into: &state)
        XCTAssertTrue(state.skills[0].isAvailable)
        XCTAssertEqual(state.versions.count, 1)
    }
    func testRollbackCreatesMonotonicVersionAndKeepsRunLink() throws {
        var state = LibrarySnapshot(); DemoLibrary.seed(into: &state)
        let first = state.versions[0]
        let run = try XCTUnwrap(state.runs.first)
        let restored = try Versioning.rollback(first.id, in: &state)
        XCTAssertEqual(restored.number, 3)
        XCTAssertEqual(restored.content, first.content)
        XCTAssertEqual(state.runs.first?.versionID, run.versionID)
        XCTAssertTrue(state.versions.contains { $0.id == run.versionID })
        XCTAssertEqual(state.skills.first?.activeVersionID, restored.id)
    }
    func testSQLiteRoundTripAcrossReopen() throws {
        let url = temporary.appendingPathComponent("library.sqlite")
        var state = LibrarySnapshot(); DemoLibrary.seed(into: &state)
        state.projectPaths = ["/a/project"]
        state.runs[0].artifacts = [Artifact(name: "日本語.md", path: "/tmp/日本語.md", mediaType: "text/markdown", byteCount: 1024)]
        do { let database = try isolatedTestDatabase(url: url); try database.save(state) }
        let reopened = try isolatedTestDatabase(url: url)
        XCTAssertEqual(try reopened.load(), state)
        state.runs[0].feedback = "Clearer, please"
        try reopened.save(state)
        XCTAssertEqual(try reopened.load().runs[0].feedback, "Clearer, please")
        XCTAssertEqual(String(data: try Data(contentsOf: url).prefix(15), encoding: .utf8), "SQLite format 3")
    }
    func testDemoSeedingIsIdempotent() {
        var state = LibrarySnapshot(); DemoLibrary.seed(into: &state)
        let original = state
        DemoLibrary.seed(into: &state)
        XCTAssertEqual(state, original)
        XCTAssertEqual(state.skills.count, 9)
    }
    func testDiffCanReconstructBothInputsIncludingRepeatedLines() {
        for (old, new) in [("a\nb\nc\n", "a\nx\nc\nd\n"), ("a\na\nb", "a\nb\na"), ("", "new"), ("old", ""), ("same", "same"), ("日本語\n🍊", "日本語\n🍎")] {
            let diff = LineDiff.compare(old: old, new: new)
            XCTAssertEqual(diff.filter { $0.kind != .added }.map(\.text).joined(separator: "\n"), old)
            XCTAssertEqual(diff.filter { $0.kind != .removed }.map(\.text).joined(separator: "\n"), new)
        }
    }
    func testPublishBacksUpAndRejectsExternalConflict() throws {
        let file = try write(".claude/skills/one/SKILL.md")
        var state = LibrarySnapshot()
        try Versioning.merge(SkillScanner(adapters: [ClaudeAdapter()]).scan(context: DiscoveryContext(home: temporary, environment: [:])), into: &state)
        let skill = try XCTUnwrap(state.skills.first)
        try Versioning.append(to: &state, skillID: skill.id, content: "new content", note: "edit")
        let context = DiscoveryContext(home: temporary, environment: [:])
        let request = try SourcePublisher.prepare(skillID: skill.id, in: state, context: context)
        let backup = try SourcePublisher.publish(request, in: state, context: context, backupDirectory: temporary.appendingPathComponent("backups")).backupURL
        XCTAssertEqual(try String(contentsOf: file), "new content")
        XCTAssertEqual(try String(contentsOf: backup), skill.lastDiskContent)
        XCTAssertThrowsError(try SourcePublisher.publish(request, in: state, context: context, backupDirectory: temporary.appendingPathComponent("backups")))
        XCTAssertEqual(try String(contentsOf: file), "new content")
    }
    func testImprovementProviderProducesEditableOfflineProposal() async throws {
        var state = LibrarySnapshot(); DemoLibrary.seed(into: &state)
        let request = ImprovementRequest(skill: state.skills[0], version: state.versions[0], run: state.runs[0], feedback: "Use concrete examples")
        let proposal = try await LocalImprovementService().propose(request)
        XCTAssertTrue(proposal.content.hasPrefix(request.version.content))
        XCTAssertTrue(proposal.content.contains("- Use concrete examples"))
        XCTAssertTrue(proposal.provider.contains("no AI"))
        XCTAssertEqual(state.versions.count, 18)
    }
}
