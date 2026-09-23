import Foundation

public enum ReleaseUpdates {
    public static let repository = "maromocooo/Iterune"
    public static let releasesURL = URL(string: "https://github.com/" + repository + "/releases")!
    public enum Result: Equatable, Sendable {
        case current(String), available(String, URL), unavailable
    }
    /// Manual opt-in request; no GitHub tokens, local paths, or library content are sent.
    public static func check(currentVersion: String, transport: any TranslationHTTPTransport = TranslationURLSessionTransport()) async throws -> Result {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/" + repository + "/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Iterune", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        if response.statusCode == 404 { return .unavailable }
        guard response.statusCode == 200, data.count <= 1_000_000 else { throw StudioError.message("Unable to check releases. Open the releases page or try again later.") }
        return try parse(data, currentVersion: currentVersion)
    }
    static func parse(_ data: Data, currentVersion: String) throws -> Result {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["draft"] as? Bool == false, object["prerelease"] as? Bool == false,
              let tag = object["tag_name"] as? String, let version = numericVersion(tag),
              let current = numericVersion(currentVersion), let raw = object["html_url"] as? String,
              let url = URL(string: raw), url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil,
              raw == "https://github.com/" + repository + "/releases/tag/" + tag else {
            throw StudioError.message("The release response is not supported. Open the releases page to check manually.")
        }
        return current.lexicographicallyPrecedes(version) ? .available(tag, url) : .current(tag)
    }
    static func numericVersion(_ value: String) -> [Int]? {
        let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
        guard normalized.range(of: #"^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$"#, options: .regularExpression) != nil else { return nil }
        return normalized.split(separator: ".").compactMap { Int($0) }
    }
}
