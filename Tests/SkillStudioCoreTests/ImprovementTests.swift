import XCTest
@testable import SkillStudioCore

final class ImprovementTests: XCTestCase {
    private func request(content: String = "# Example\n\nKeep it brief.\n", selection: SelectionComment? = nil) -> ImprovementRequest {
        var snapshot = LibrarySnapshot(); DemoLibrary.seed(into: &snapshot)
        let skill = snapshot.skills[0]
        let version = SkillVersion(skillID: skill.id, number: 1, content: content, note: "fixture")
        return ImprovementRequest(skill: skill, version: version, run: nil, feedback: "Give concrete examples.", selection: selection)
    }
    func testPatchesPreserveUnrelatedTextAndRejectUnsafeMatches() throws {
        let source = "# Hello 👨‍👩‍👧‍👦\r\n\r\n同じ。\r\n同じ。\r\nEnd.\r\n"
        XCTAssertThrowsError(try ReviewedSkillEdits.apply([.init(find: "同じ。", replace: "変更。")], to: source))
        let ns = source as NSString, second = ns.range(of: "同じ。", options: .backwards)
        let edited = try ReviewedSkillEdits.apply([.init(find: "同じ。", replace: "変更。")], to: source, within: second)
        XCTAssertEqual(edited, "# Hello 👨‍👩‍👧‍👦\r\n\r\n同じ。\r\n変更。\r\nEnd.\r\n")
        XCTAssertThrowsError(try ReviewedSkillEdits.apply([.init(find: "End.", replace: "Gone.")], to: source, within: second))
        XCTAssertThrowsError(try ReviewedSkillEdits.apply([.init(find: "missing", replace: "new")], to: source))
        XCTAssertThrowsError(try ReviewedSkillEdits.apply([.init(find: "", replace: "new")], to: source))
        XCTAssertThrowsError(try ReviewedSkillEdits.apply([.init(find: "End.", replace: "End.")], to: source))
        XCTAssertThrowsError(try ReviewedSkillEdits.apply([.init(find: "End.", replace: "A"), .init(find: "End", replace: "B")], to: source))
        XCTAssertThrowsError(try ReviewedSkillEdits.apply([.init(find: "End.", replace: "X")], to: source, within: NSRange(location: Int.max, length: 1)))
    }
    func testMultipleEditsUseOriginalOffsets() throws {
        let result = try ReviewedSkillEdits.apply([.init(find: "first", replace: "a much longer first"), .init(find: "last", replace: "")], to: "first middle last")
        XCTAssertEqual(result, "a much longer first middle ")
    }
    func testTranslatedQuoteDoesNotBecomeOriginalOffsets() async throws {
        let selection = SelectionComment(quote: "簡潔に。", context: "簡潔に。", isTranslation: true, sourceRange: NSRange(location: 0, length: 4))
        XCTAssertNil(selection.sourceRange)
        let generator = FixtureGenerator(result: #"{"explanation":"具体例を追加","edits":[{"find":"Keep it brief.","replace":"Keep it brief and give concrete examples."}]}"#)
        let service = AIImprovementService(generator: generator, displayName: "Fixture", language: .japanese)
        let proposal = try await service.propose(request(selection: selection))
        XCTAssertEqual(proposal.content, "# Example\n\nKeep it brief and give concrete examples.\n")
        let sent = await generator.last!
        XCTAssertTrue(sent.prompt.contains("簡潔に。"))
        XCTAssertTrue(sent.prompt.contains("UNTRUSTED DATA"))
        XCTAssertFalse(sent.prompt.contains("sourcePath"))
        XCTAssertFalse(sent.prompt.contains("artifacts"))
        XCTAssertEqual(sent.responseField, "result")
    }
    func testAIRejectsWrongRegionMalformedAndNoChanges() async throws {
        let source = "First paragraph.\nSecond paragraph."
        let selected = SelectionComment(quote: "First", context: "First paragraph.", isTranslation: false, sourceRange: (source as NSString).range(of: "First paragraph."))
        for result in ["not json", #"{"explanation":"none","edits":[]}"#,
                       #"{"explanation":"wrong","edits":[{"find":"Second paragraph.","replace":"Wrong region."}]}"#] {
            let service = AIImprovementService(generator: FixtureGenerator(result: result), displayName: "Fixture", language: .english)
            do { _ = try await service.propose(request(content: source, selection: selected)); XCTFail("Must reject") }
            catch { XCTAssertTrue(error is ImprovementError) }
        }
    }
    func testGenericAPIRequestKeepsCredentialsOutOfPayload() throws {
        for provider in [AIConnectionKind.openAIAPI, .anthropicAPI] {
            let service = APITranslationService(provider: provider, model: "fixture", apiKey: "fixture-key")
            let req = try service.makeRequest(TextGenerationRequest(prompt: "Return result JSON", responseField: "result"))
            let body = String(decoding: req.httpBody!, as: UTF8.self)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any])
            XCTAssertEqual(object["model"] as? String, "fixture")
            XCTAssertTrue(body.contains("Return result JSON")); XCTAssertFalse(body.contains("fixture-key"))
            let response: [String: Any] = provider == .openAIAPI
                ? ["status":"completed", "output":[["type":"message", "content":[["type":"output_text","text":"{\"result\":\"fixture\"}"]]]]]
                : ["stop_reason":"end_turn", "content":[["type":"text","text":"{\"result\":\"fixture\"}"]]]
            XCTAssertEqual(try service.parse(JSONSerialization.data(withJSONObject: response), field: "result"), "fixture")
        }
    }
    func testImprovementModelPreferencesAreIndependentAndRequireExplicitModel() throws {
        var shared = AIConnectionSettings()
        shared.model = "translation-fixture"; shared.executablePath = "/fixture/codex"
        var preferences = ImprovementPreferences(shared: shared)
        preferences.model = " review-fixture "
        let frozen = try preferences.connection(using: shared)
        shared.model = "changed-translation"
        preferences.provider = .claudeCLI; preferences.model = "claude-review"
        shared.provider = .claudeCLI; shared.executablePath = "/fixture/claude"
        XCTAssertEqual(try preferences.connection(using: shared).executablePath, "/fixture/claude")
        preferences.provider = .codexCLI
        XCTAssertEqual(try preferences.connection(using: shared).model, "review-fixture")
        XCTAssertEqual(frozen.model, "review-fixture")
        XCTAssertEqual(frozen.executablePath, "/fixture/codex")
        let restored = try JSONDecoder().decode(ImprovementPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored, preferences)
        for invalid in ["", "  ", "model\nname", "model name", String(repeating: "x", count: 201)] {
            preferences.model = invalid
            XCTAssertThrowsError(try preferences.connection(using: shared))
        }
        XCTAssertEqual(shared.models[AIConnectionKind.codexCLI.rawValue], "changed-translation")
    }
    func testModelCatalogUsesOnlyVisibleValidIDsAndHandlesMissingCache() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(ImprovementModelCatalog.codexModels(at: file).isEmpty)
        try Data(#"{"models":[{"slug":"review-a","visibility":"list"},{"slug":"internal","visibility":"hide"},{"slug":"review-a","visibility":"list"},{"slug":"bad\nname","visibility":"list"},{"slug":"review-b","visibility":"list"}]}"#.utf8).write(to: file)
        XCTAssertEqual(ImprovementModelCatalog.codexModels(at: file), ["review-a", "review-b"])
        XCTAssertEqual(ImprovementModelCatalog.suggestions(for: .codexCLI, codexModels: ["review-a"], savedModel: "review-a"), ["review-a"])
        try Data("invalid".utf8).write(to: file)
        XCTAssertTrue(ImprovementModelCatalog.codexModels(at: file).isEmpty)
    }
    func testExplicitModelReachesBothCLIProviders() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for provider in [AIConnectionKind.codexCLI, .claudeCLI] {
            let file = folder.appendingPathComponent(provider.executableName)
            let script = #"""
            #!/bin/sh
            model=''
            output=''
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --model) shift; model="$1" ;;
                --output-last-message) shift; output="$1" ;;
              esac
              shift
            done
            /bin/cat > /dev/null
            [ "$model" = 'review-fixture' ] || exit 9
            if [ -n "$output" ]; then
              printf '%s' '{"result":"{\"explanation\":\"Updated\",\"edits\":[{\"find\":\"Keep it brief.\",\"replace\":\"Give examples.\"}]}"}' > "$output"
            else
              printf '%s' '{"is_error":false,"structured_output":{"result":"{\"explanation\":\"Updated\",\"edits\":[{\"find\":\"Keep it brief.\",\"replace\":\"Give examples.\"}]}"}}'
            fi
            """#
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            var shared = AIConnectionSettings(); shared.provider = provider; shared.executablePath = file.path; shared.model = "translation-fixture"
            var preferences = ImprovementPreferences(shared: shared); preferences.model = "review-fixture"
            let connection = try preferences.connection(using: shared)
            let generator = CLITranslationService(provider: connection.provider, executable: file, model: connection.model)
            let service = AIImprovementService(generator: generator, displayName: provider.title, language: .english)
            let proposal = try await service.propose(request())
            XCTAssertEqual(proposal.content, "# Example\n\nGive examples.\n")
        }
    }
    func testLiveImprovementWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["SKILL_STUDIO_LIVE_IMPROVEMENT"] == "codex" else { throw XCTSkip("Opt-in synthetic CLI improvement test") }
        let generator = CLITranslationService(executable: CodexExecutable.resolve())
        let service = AIImprovementService(generator: generator, displayName: "Codex CLI", language: .japanese)
        let selection = SelectionComment(quote: "簡潔に。", context: "簡潔に。", isTranslation: true)
        let result = try await service.propose(request(selection: selection))
        XCTAssertTrue(result.content.hasPrefix("# Example\n\n"))
        XCTAssertNotEqual(result.content, request().version.content)
        XCTAssertFalse(result.content.contains("簡潔に。"))
    }
}

private actor FixtureGenerator: TextGenerationService {
    let result: String
    var last: TextGenerationRequest?
    init(result: String) { self.result = result }
    func generate(_ request: TextGenerationRequest) async throws -> String { last = request; return result }
}
