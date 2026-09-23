import Foundation

/// Improvement choices are independent of translation; authentication and executable paths are shared.
public struct ImprovementPreferences: Codable, Equatable, Sendable {
    public var provider: AIConnectionKind
    public var models: [String: String]
    public init(shared: AIConnectionSettings = AIConnectionSettings()) {
        provider = shared.provider; models = shared.models
    }
    public var model: String {
        get { models[provider.rawValue] ?? provider.defaultModel }
        set { models[provider.rawValue] = newValue }
    }
    public static func normalizedModel(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 200,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else { return nil }
        return trimmed
    }
    public func connection(using shared: AIConnectionSettings) throws -> AIConnectionSettings {
        guard let model = Self.normalizedModel(model) else { throw StudioError.message("Choose a model ID before generating an improvement.") }
        var result = shared
        result.provider = provider; result.model = model
        return result
    }
}

/// Optional suggestions only: no network request, login or automatic model selection.
public enum ImprovementModelCatalog {
    public static func codexModels(at url: URL? = nil) -> [String] {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let file = url ?? home.appendingPathComponent("models_cache.json")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2_000_001), data.count <= 2_000_000,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return models.compactMap { model in
            guard model["visibility"] as? String == "list", let raw = model["slug"] as? String,
                  let id = ImprovementPreferences.normalizedModel(raw), seen.insert(id).inserted else { return nil }
            return id
        }
    }
    public static func suggestions(for provider: AIConnectionKind, codexModels: [String], savedModel: String) -> [String] {
        let base: [String]
        switch provider {
        case .codexCLI: base = codexModels
        case .claudeCLI: base = ["sonnet", "opus", "haiku"]
        case .openAIAPI, .anthropicAPI: base = [provider.defaultModel]
        }
        var seen = Set<String>()
        return ([savedModel] + base).compactMap { value in
            guard let id = ImprovementPreferences.normalizedModel(value), seen.insert(id).inserted else { return nil }
            return id
        }
    }
}
