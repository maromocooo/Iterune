import XCTest
@testable import SkillStudioCore

final class ConnectionReadinessTests: XCTestCase {
    func testDiagnosticsOnlyExposeVersionAndAuthenticationState() throws {
        XCTAssertEqual(ConnectionDiagnostics.versionNumber("cli 1.20.3 (fixture@example.com)"), "1.20.3")
        XCTAssertNil(ConnectionDiagnostics.versionNumber("unexpected sensitive output"))
        XCTAssertTrue(ConnectionDiagnostics.authenticated(provider: .codexCLI, status: 0, text: "Logged in using ChatGPT"))
        XCTAssertFalse(ConnectionDiagnostics.authenticated(provider: .codexCLI, status: 1, text: "Logged in"))
        XCTAssertFalse(ConnectionDiagnostics.authenticated(provider: .codexCLI, status: 0, text: "Not logged in"))
        XCTAssertTrue(ConnectionDiagnostics.authenticated(provider: .claudeCLI, status: 0, text: #"{"loggedIn":true,"email":"fixture@example.com"}"#))
        XCTAssertFalse(ConnectionDiagnostics.authenticated(provider: .claudeCLI, status: 0, text: #"{"loggedIn":false}"#))
    }
    func testDiagnosticRunnerTimesOutAndCancelsWithoutHanging() async throws {
        do {
            _ = try await DiagnosticCommand.run(URL(fileURLWithPath: "/bin/sleep"), ["5"], timeout: 0.05)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("CLI")) }
        let task = Task { try await DiagnosticCommand.run(URL(fileURLWithPath: "/bin/sleep"), ["5"]) }
        try await Task.sleep(nanoseconds: 50_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }
    func testPublicReleaseValidationAndNumericVersions() throws {
        var release: [String: Any] = ["tag_name":"v0.10.0", "draft":false, "prerelease":false,
                                    "html_url":ReleaseUpdates.releasesURL.absoluteString + "/tag/v0.10.0"]
        let data = try JSONSerialization.data(withJSONObject: release)
        XCTAssertEqual(try ReleaseUpdates.parse(data, currentVersion: "0.9.9"), .available("v0.10.0", URL(string: release["html_url"] as! String)!))
        XCTAssertEqual(try ReleaseUpdates.parse(data, currentVersion: "0.10.0"), .current("v0.10.0"))
        release["html_url"] = "https://example.com/untrusted"
        XCTAssertThrowsError(try ReleaseUpdates.parse(JSONSerialization.data(withJSONObject: release), currentVersion:"0.9.9"))
        XCTAssertNil(ReleaseUpdates.numericVersion("v1.0.0-beta"))
    }
    func testPrivateReleasesDoNotRequireOrSendGitHubCredentials() async throws {
        let result = try await ReleaseUpdates.check(currentVersion:"0.4.0", transport: PrivateReleaseTransport())
        XCTAssertEqual(result, .unavailable)
    }
    func testInstalledCLIDiagnosticsWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["SKILL_STUDIO_CLI_DIAGNOSTICS_TEST"] == "1" else { throw XCTSkip("Opt-in local CLI auth-status check. No prompts are submitted.") }
        for provider in [AIConnectionKind.codexCLI, .claudeCLI] {
            var settings = AIConnectionSettings(); settings.provider = provider
            let report = try await ConnectionDiagnostics.inspect(settings)
            XCTAssertEqual(report.map(\.id), ["version", "compatibility", "login"])
            XCTAssertTrue(report.allSatisfy(\.passed), "Diagnostic did not pass for \(provider.title)")
        }
    }
}

private struct PrivateReleaseTransport: TranslationHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.url?.host, "api.github.com")
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
    }
}
