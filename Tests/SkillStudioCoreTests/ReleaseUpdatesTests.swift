import XCTest
@testable import SkillStudioCore

final class ReleaseUpdatesTests: XCTestCase {
    private let releaseURL = "https://github.com/maromocooo/Iterune/releases/tag/v1.2.3"
    private func release(_ url: String? = nil, tag: String = "v1.2.3", draft: Bool = false, prerelease: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": draft,
            "prerelease": prerelease, "html_url": url ?? releaseURL])
    }
    func testCanonicalRequestAndReleasesPageAgree() async throws {
        XCTAssertEqual(ReleaseUpdates.repository, "maromocooo/Iterune")
        XCTAssertEqual(ReleaseUpdates.releasesURL.absoluteString, "https://github.com/maromocooo/Iterune/releases")
        let transport = ReleaseFixtureTransport(status: 200, body: try release())
        let result = try await ReleaseUpdates.check(currentVersion: "1.2.2", transport: transport)
        XCTAssertEqual(result, .available("v1.2.3", URL(string: releaseURL)!))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/maromocooo/Iterune/releases/latest")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Iterune")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.httpBody)
    }
    func testOnlyExactCanonicalTagURLIsAccepted() throws {
        var credentialURL = URLComponents(string: releaseURL)!
        credentialURL.user = "fixture"
        credentialURL.password = "synthetic"
        let invalid = [
            "https://github.com/example-owner/Iterune/releases/tag/v1.2.3",
            "https://github.com/maromocooo/OtherProject/releases/tag/v1.2.3",
            "https://github.com/maromocooo/Iterune-extra/releases/tag/v1.2.3",
            "https://github.com/maromocooo/Iterune/releases/tag/",
            releaseURL + "/extra", releaseURL + "/../../elsewhere", releaseURL + "?redirect=elsewhere",
            releaseURL + "#fragment", releaseURL.replacingOccurrences(of: "v1.2.3", with: "v9.9.9"),
            releaseURL.replacingOccurrences(of: "v1.2.3", with: "%76%31.2.3"),
            releaseURL.replacingOccurrences(of: "/releases/", with: "/%2e%2e/releases/"),
            releaseURL.replacingOccurrences(of: "/tag/", with: "/tag%2fv1.2.3/"),
            releaseURL.replacingOccurrences(of: "github.com", with: "github.com.example.org"),
            releaseURL.replacingOccurrences(of: "https:", with: "http:"),
            releaseURL.replacingOccurrences(of: "github.com", with: "github.com:443"),
            credentialURL.string!,
            "not a URL", "https://[invalid", "//github.com/example-owner/OtherProject"
        ]
        for url in invalid {
            XCTAssertThrowsError(try ReleaseUpdates.parse(release(url), currentVersion: "1.0.0"), url)
        }
    }
    func testDraftPrereleaseAndVersionRulesRemainStrict() throws {
        XCTAssertThrowsError(try ReleaseUpdates.parse(release(draft: true), currentVersion: "1.0.0"))
        XCTAssertThrowsError(try ReleaseUpdates.parse(release(prerelease: true), currentVersion: "1.0.0"))
        XCTAssertThrowsError(try ReleaseUpdates.parse(release(tag: "v1.2.3-beta"), currentVersion: "1.0.0"))
        XCTAssertThrowsError(try ReleaseUpdates.parse(release(), currentVersion: "invalid"))
        XCTAssertThrowsError(try ReleaseUpdates.parse(Data("{}".utf8), currentVersion: "1.0.0"))
        XCTAssertEqual(try ReleaseUpdates.parse(release(), currentVersion: "1.2.3"), .current("v1.2.3"))
        XCTAssertEqual(try ReleaseUpdates.parse(release(), currentVersion: "2.0.0"), .current("v1.2.3"))
    }
    func testMissingReleaseAndFailuresNeverRetryAnotherRepository() async throws {
        let missing = ReleaseFixtureTransport(status: 404)
        let result = try await ReleaseUpdates.check(currentVersion: "1.0.0", transport: missing)
        XCTAssertEqual(result, .unavailable)
        let missingCount = await missing.requests.count
        XCTAssertEqual(missingCount, 1)
        for transport in [ReleaseFixtureTransport(status: 500), ReleaseFixtureTransport(fails: true),
                          ReleaseFixtureTransport(status: 200, body: Data("invalid JSON".utf8))] {
            do { _ = try await ReleaseUpdates.check(currentVersion: "1.0.0", transport: transport); XCTFail("Expected error") }
            catch { }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1)
        }
    }

}

private actor ReleaseFixtureTransport: TranslationHTTPTransport {
    let status: Int
    let body: Data
    let fails: Bool
    private(set) var requests: [URLRequest] = []
    init(status: Int = 200, body: Data = Data(), fails: Bool = false) {
        self.status = status; self.body = body; self.fails = fails
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if fails { throw URLError(.notConnectedToInternet) }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
