import XCTest
@testable import SkillStudioCore

final class TranslationTests: XCTestCase {
    func testFourCompleteCatalogsAndPlaceholders() throws {
        let english = Localization.catalog(for: .english)
        XCTAssertGreaterThan(english.count, 190)
        let regex = try NSRegularExpression(pattern: #"\{\d+\}"#)
        func placeholders(_ text: String) -> [String] {
            let ns = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }.sorted()
        }
        for language in AppLanguage.allCases {
            let catalog = Localization.catalog(for: language)
            XCTAssertEqual(Set(catalog.keys), Set(english.keys), language.rawValue)
            for (key, value) in catalog {
                XCTAssertFalse(value.isEmpty, key)
                XCTAssertEqual(placeholders(value), placeholders(key), "\(language.rawValue): \(key)")
            }
        }
        XCTAssertNotEqual(Localization.catalog(for: .simplifiedChinese), Localization.catalog(for: .traditionalChinese))
        XCTAssertEqual(Localization.text("Improvement: {0}", language: .english, arguments: ["Keep {0} literal"]), "Improvement: Keep {0} literal")
    }

    func testLocaleResolutionAndTranslationVisibility() {
        for code in ["zh-Hant", "zh-Hant-TW", "zh-TW", "zh-HK", "zh-MO"] {
            XCTAssertEqual(AppLanguage.resolve(saved: nil, preferredLanguages: [code]), .traditionalChinese)
        }
        XCTAssertEqual(AppLanguage.resolve(saved: nil, preferredLanguages: ["zh-Hans-CN"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolve(saved: "ja", preferredLanguages: ["en-US"]), .japanese)
        XCTAssertEqual(AppLanguage.resolve(saved: "invalid", preferredLanguages: ["fr", "ja-JP"]), .japanese)
        XCTAssertEqual(AppLanguage.resolve(saved: nil, preferredLanguages: ["fr"]), .english)
        XCTAssertFalse(AppLanguage.english.offersSkillTranslation)
        XCTAssertTrue(AppLanguage.traditionalChinese.offersSkillTranslation)
    }

    func testConnectionPreferencesKeepPerProviderValues() throws {
        var settings = AIConnectionSettings()
        settings.executablePath = "/test/codex"; settings.model = "codex-model"
        settings.provider = .anthropicAPI; settings.model = "claude-model"
        settings.provider = .openAIAPI
        XCTAssertEqual(settings.model, "gpt-4.1-mini")
        let data = try JSONEncoder().encode(settings)
        var restored = try JSONDecoder().decode(AIConnectionSettings.self, from: data)
        XCTAssertEqual(restored, settings)
        restored.provider = .codexCLI
        XCTAssertEqual(restored.executablePath, "/test/codex")
        XCTAssertEqual(restored.model, "codex-model")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["provider", "executablePaths", "models"])
    }

    func testConcurrencyPreferencesMigrateAndPersist() throws {
        let legacy = Data(#"{"provider":"claudeCLI","executablePaths":{"claudeCLI":"/test/claude"},"models":{"claudeCLI":"saved-model"}}"#.utf8)
        var settings = try JSONDecoder().decode(AIConnectionSettings.self, from: legacy)
        XCTAssertEqual(settings.maxConcurrentTranslations, 18)
        XCTAssertEqual(settings.provider, .claudeCLI)
        XCTAssertEqual(settings.model, "saved-model")
        XCTAssertEqual(settings.executablePath, "/test/claude")
        settings.maxConcurrentTranslations = 4
        let restored = try JSONDecoder().decode(AIConnectionSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.maxConcurrentTranslations, 4)
        settings.maxConcurrentTranslations = 0
        XCTAssertEqual(settings.maxConcurrentTranslations, 1)
        settings.maxConcurrentTranslations = 100
        XCTAssertEqual(settings.maxConcurrentTranslations, 18)
    }

    func testRequestLimitsAndCacheIdentity() throws {
        let request = SkillTranslationRequest(content: "# Hello\n`echo hello`", language: .japanese)
        try request.validate()
        XCTAssertTrue(request.prompt.contains("UNTRUSTED DATA"))
        XCTAssertTrue(request.prompt.contains("Japanese"))
        XCTAssertNotEqual(request.cacheKey, SkillTranslationRequest(content: request.content, language: .traditionalChinese).cacheKey)
        XCTAssertNotEqual(request.cacheKey, SkillTranslationRequest(content: request.content + "!", language: .japanese).cacheKey)
        XCTAssertThrowsError(try SkillTranslationRequest(content: " ", language: .japanese).validate())
        XCTAssertThrowsError(try SkillTranslationRequest(content: String(repeating: "あ", count: 40_000), language: .japanese).validate())
    }

    func testAPIRequestsAndValidResponses() async throws {
        let document = SkillTranslationRequest(content: "# Hello", language: .traditionalChinese)
        for provider in [AIConnectionKind.openAIAPI, .anthropicAPI] {
            let body: [String: Any] = provider == .openAIAPI
                ? ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "{\"translation\":\"# 您好\"}"]]]]]
                : ["stop_reason": "end_turn", "content": [["type": "text", "text": "```json\n{\"translation\":\"# 您好\"}\n```"]]]
            let transport = StubTransport(data: try JSONSerialization.data(withJSONObject: body))
            let service = APITranslationService(provider: provider, model: "fixture-model", apiKey: "fixture-key", transport: transport)
            let translated = try await service.translate(document)
            XCTAssertEqual(translated, "# 您好")
            let request = try service.makeRequest(document)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("fixture-key"))
            XCTAssertEqual(json["model"] as? String, "fixture-model")
            XCTAssertNil(json["tools"])
            if provider == .openAIAPI {
                XCTAssertEqual(request.url?.host, "api.openai.com")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
                XCTAssertEqual(json["store"] as? Bool, false)
                XCTAssertNotNil(json["text"])
            } else {
                XCTAssertEqual(request.url?.host, "api.anthropic.com")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture-key")
                XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            }
        }
    }

    func testAPIRejectsTruncationMalformedAndAuthenticationErrors() async throws {
        let request = SkillTranslationRequest(content: "Hello", language: .japanese)
        let service = APITranslationService(provider: .openAIAPI, model: "fixture", apiKey: "fixture-key")
        XCTAssertThrowsError(try service.parse(Data(#"{"status":"incomplete","output":[]}"#.utf8))) { XCTAssertEqual($0 as? TranslationError, .incomplete) }
        XCTAssertThrowsError(try service.parse(Data("invalid".utf8)))
        XCTAssertThrowsError(try TranslationResponse.decode(#"{"translation":" "}"#)) { XCTAssertEqual($0 as? TranslationError, .empty) }
        let anthropic = APITranslationService(provider: .anthropicAPI, model: "fixture", apiKey: "fixture-key")
        XCTAssertThrowsError(try anthropic.parse(Data(#"{"stop_reason":"max_tokens","content":[]}"#.utf8)))
        for status in [401, 403, 429, 500] {
            let denied = APITranslationService(provider: .openAIAPI, model: "fixture", apiKey: "fixture-key",
                                              transport: StubTransport(data: Data("secret error body".utf8), status: status))
            do { _ = try await denied.translate(request); XCTFail("Should fail") }
            catch { XCTAssertFalse(error.localizedDescription.contains("secret error body")); XCTAssertFalse(error.localizedDescription.contains("fixture-key")) }
        }
        XCTAssertThrowsError(try APITranslationService(provider: .openAIAPI, model: "fixture", apiKey: "").makeRequest(request))
    }

    func testCLIExecutionWithIsolatedFixturesForBothProviders() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("SKILL.md")
        try "# Original".write(to: source, atomically: true, encoding: .utf8)
        let codex = try executable(folder, name: "codex", script: #"""
        #!/bin/sh
        output=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '--output-last-message' ]; then shift; output="$1"; fi
          shift
        done
        /bin/cat > received.txt
        /usr/bin/grep -q 'DOCUMENT_JSON_STRING:' received.txt || exit 8
        [ -f schema.json ] || exit 9
        printf '{"translation":"# 翻訳"}' > "$output"
        """#)
        let claude = try executable(folder, name: "claude", script: #"""
        #!/bin/sh
        /bin/cat > received.txt
        /usr/bin/grep -q 'Traditional Chinese' received.txt || exit 8
        printf '{"is_error":false,"structured_output":{"translation":"# 翻譯"}}'
        """#)
        XCTAssertEqual(CodexExecutable.resolve(override: codex.path), codex)
        XCTAssertNil(CodexExecutable.resolve(override: folder.path))
        XCTAssertNil(CodexExecutable.resolve(override: folder.appendingPathComponent("missing").path))
        let first = try await CLITranslationService(executable: codex).translate(.init(content: String(contentsOf: source), language: .japanese))
        let second = try await CLITranslationService(provider: .claudeCLI, executable: claude).translate(.init(content: String(contentsOf: source), language: .traditionalChinese))
        XCTAssertEqual(first, "# 翻訳"); XCTAssertEqual(second, "# 翻譯")
        XCTAssertEqual(try String(contentsOf: source), "# Original")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["SKILL.md", "claude", "codex"])
        let args = CLITranslationService.arguments(folder: folder, schema: folder, output: folder)
        for flag in ["--ephemeral", "--ignore-user-config", "read-only", "shell_tool", "hooks", "plugins", "skip_host_skill_discovery"] { XCTAssertTrue(args.contains(flag)) }
    }

    func testCLITimeoutAndCancellation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let command = try executable(folder, name: "slow", script: "#!/bin/sh\nexec /bin/sleep 20\n")
        let request = SkillTranslationRequest(content: "Hello", language: .japanese)
        do { _ = try await CLITranslationService(executable: command, timeout: 0.1).translate(request); XCTFail("Should time out") }
        catch { XCTAssertEqual(error as? TranslationError, .timedOut) }
        let task = Task { try await CLITranslationService(executable: command).translate(request) }
        try await Task.sleep(nanoseconds: 100_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("Should cancel") } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testClaudeRefusalIsReportedWithoutExposingProviderOutput() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let command = try executable(folder, name: "claude", script: #"""
        #!/bin/sh
        printf '{"is_error":true,"stop_reason":"refusal","result":"internal request details"}'
        exit 1
        """#)
        do {
            _ = try await CLITranslationService(provider: .claudeCLI, executable: command).translate(.init(content: "Hello", language: .japanese))
            XCTFail("Should reject a refused response")
        } catch { XCTAssertEqual(error as? TranslationError, .incomplete) }
    }

    @MainActor func testSessionCacheAndStaleResultIsolation() async throws {
        let session = TranslationSession(), service = ControlledTranslation()
        let request = SkillTranslationRequest(content: "Original", language: .japanese)
        session.translate(request, using: service, scope: "codex")
        await service.waitForRequests(1)
        session.reset()
        session.translate(.init(content: "New", language: .traditionalChinese), using: service, scope: "claude")
        await service.waitForRequests(2)
        await service.finish(index: 1, result: "新翻譯")
        for _ in 0..<50 where session.isTranslating { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(session.translation, "新翻譯")
        await service.finish(index: 0, result: "古い翻訳")
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(session.translation, "新翻譯")
        session.reset()
        session.translate(.init(content: "New", language: .traditionalChinese), using: service, scope: "claude")
        XCTAssertEqual(session.translation, "新翻譯"); XCTAssertFalse(session.isTranslating)
        session.translate(.init(content: "New", language: .traditionalChinese), using: service, scope: "other")
        await service.waitForRequests(3)
        session.cancel(); await service.finish(index: 2, result: "Cancelled")
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(session.translation); XCTAssertFalse(session.isTranslating)
    }

    func testLiveCLITranslationWhenExplicitlyEnabled() async throws {
        guard let value = ProcessInfo.processInfo.environment["SKILL_STUDIO_LIVE_TRANSLATION_TEST"], ["codex", "claude"].contains(value) else {
            throw XCTSkip("Opt-in network test: set SKILL_STUDIO_LIVE_TRANSLATION_TEST=codex or claude. Sends synthetic text only.")
        }
        let provider: AIConnectionKind = value == "codex" ? .codexCLI : .claudeCLI
        let executable = try XCTUnwrap(CodexExecutable.resolve(name: value))
        let result = try await CLITranslationService(provider: provider, executable: executable, model: provider == .claudeCLI ? "haiku" : "").translate(.init(content: "# Greeting\n\nHello world.\n\n`echo hello`\n", language: .japanese))
        XCTAssertTrue(result.contains("`echo hello`"))
        XCTAssertTrue(result.unicodeScalars.contains { (0x3040...0x30ff).contains($0.value) })
    }

    private func executable(_ folder: URL, name: String, script: String) throws -> URL {
        let file = folder.appendingPathComponent(name)
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
}

private struct StubTransport: TranslationHTTPTransport {
    let data: Data
    var status = 200
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private actor ControlledTranslation: SkillTranslationService {
    private var continuations: [CheckedContinuation<String, Error>] = []
    func translate(_ request: SkillTranslationRequest) async throws -> String {
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func waitForRequests(_ count: Int) async {
        for _ in 0..<200 {
            if continuations.count >= count { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Translation did not start")
    }
    func finish(index: Int, result: String) { continuations[index].resume(returning: result) }
}
