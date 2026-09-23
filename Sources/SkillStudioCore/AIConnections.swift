import Foundation
import Security

public enum AIConnectionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codexCLI, claudeCLI, openAIAPI, anthropicAPI
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .codexCLI: return "Codex CLI"
        case .claudeCLI: return "Claude CLI"
        case .openAIAPI: return "OpenAI API"
        case .anthropicAPI: return "Anthropic API"
        }
    }
    public var isCLI: Bool { self == .codexCLI || self == .claudeCLI }
    public var executableName: String { self == .claudeCLI ? "claude" : "codex" }
    public var defaultModel: String {
        switch self { case .openAIAPI: return "gpt-4.1-mini"; case .anthropicAPI: return "claude-haiku-4-5"; default: return "" }
    }
    public var destination: String {
        switch self { case .codexCLI, .openAIAPI: return "OpenAI"; case .claudeCLI, .anthropicAPI: return "Anthropic" }
    }
}

/// Reusable connection preferences. Credentials are deliberately excluded from Codable.
public struct AIConnectionSettings: Codable, Equatable, Sendable {
    public var provider: AIConnectionKind = .codexCLI
    public var executablePaths: [String: String] = [:]
    public var models: [String: String] = [:]
    // Optional storage preserves settings written before concurrency was configurable.
    private var translationConcurrency: Int?
    public var maxConcurrentTranslations: Int {
        get { min(ChunkedTranslationService.maximumConcurrency, max(1, translationConcurrency ?? ChunkedTranslationService.maximumConcurrency)) }
        set { translationConcurrency = min(ChunkedTranslationService.maximumConcurrency, max(1, newValue)) }
    }
    public init() {}
    public var executablePath: String {
        get { executablePaths[provider.rawValue] ?? "" }
        set { executablePaths[provider.rawValue] = newValue }
    }
    public var model: String {
        get { models[provider.rawValue] ?? provider.defaultModel }
        set { models[provider.rawValue] = newValue }
    }
    public var cacheScope: String { provider.rawValue + ":" + model + ":" + executablePath }
}

public protocol CredentialStore {
    func read(for provider: AIConnectionKind) throws -> String?
    func save(_ value: String, for provider: AIConnectionKind) throws
    func remove(for provider: AIConnectionKind) throws
}

public struct KeychainCredentialStore: CredentialStore {
    private let service = "dev.agentskillstudio.ai-credentials"
    public init() {}
    private func query(_ provider: AIConnectionKind) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue]
    }
    public func read(for provider: AIConnectionKind) throws -> String? {
        var query = query(provider)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw StudioError.message("Unable to access the API key in Keychain.")
        }
        return value
    }
    public func save(_ value: String, for provider: AIConnectionKind) throws {
        let data = Data(value.utf8), query = query(provider)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess else { throw StudioError.message("Unable to save the API key in Keychain.") }
        } else if status != errSecSuccess { throw StudioError.message("Unable to save the API key in Keychain.") }
    }
    public func remove(for provider: AIConnectionKind) throws {
        let status = SecItemDelete(query(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StudioError.message("Unable to remove the API key from Keychain.") }
    }
}

public protocol TranslationHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct TranslationURLSessionTransport: TranslationHTTPTransport {
    public init() {}
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 130
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw TranslationError.invalidResponse }
            return (data, response)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw TranslationError.timedOut }
            throw StudioError.message("Unable to connect to the translation API. Check your network and try again.")
        }
    }
}

// API credentials must never follow a redirect to a different endpoint.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct APITranslationService: SkillTranslationService, TextGenerationService {
    public let provider: AIConnectionKind
    public let model: String
    private let key: String
    private let transport: any TranslationHTTPTransport
    public init(provider: AIConnectionKind, model: String, apiKey: String, transport: any TranslationHTTPTransport = TranslationURLSessionTransport()) {
        self.provider = provider; self.model = model; self.key = apiKey; self.transport = transport
    }
    public func translate(_ document: SkillTranslationRequest) async throws -> String {
        try document.validate()
        return try await generate(.init(prompt: document.prompt, responseField: "translation"))
    }
    public func generate(_ document: TextGenerationRequest) async throws -> String {
        try document.validate()
        try Task.checkCancellation()
        let request = try makeRequest(document)
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw StudioError.message("The API key was rejected. Check your key and account access in settings.")
        case 400, 404: throw StudioError.message("The API rejected the model or request. Check the model ID and account access in settings.")
        case 429: throw StudioError.message("The API usage limit was reached. Check your allowance or retry later.")
        default: throw StudioError.message(L("Translation API returned HTTP {0}. Please retry later.", String(response.statusCode)))
        }
        return try parse(data, field: document.responseField)
    }
    func makeRequest(_ document: SkillTranslationRequest) throws -> URLRequest {
        try makeRequest(TextGenerationRequest(prompt: document.prompt, responseField: "translation"))
    }
    func makeRequest(_ document: TextGenerationRequest) throws -> URLRequest {
        guard !provider.isCLI else { throw TranslationError.invalidResponse }
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !key.contains("\n"), !key.contains("\r") else {
            throw StudioError.message("Save an API key in translation settings first.")
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StudioError.message("Enter a model ID in translation settings.") }
        let isOpenAI = provider == .openAIAPI
        var request = URLRequest(url: URL(string: isOpenAI ? "https://api.openai.com/v1/responses" : "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any]
        if isOpenAI {
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            body = ["model": model, "store": false, "max_output_tokens": 16384,
                    "input": [["role": "user", "content": document.prompt]],
                    "text": ["format": ["type": "json_schema", "name": "skill_" + document.responseField, "strict": true,
                                          "schema": document.schema]]]
        } else {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": model, "max_tokens": 8192, "messages": [["role": "user", "content": document.prompt]]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    func parse(_ data: Data, field: String = "translation") throws -> String {
        guard data.count <= 2_000_000, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TranslationError.invalidResponse }
        let text: String
        if provider == .openAIAPI {
            guard object["status"] as? String == "completed", let output = object["output"] as? [[String: Any]] else { throw TranslationError.incomplete }
            text = output.filter { $0["type"] as? String == "message" }.flatMap { $0["content"] as? [[String: Any]] ?? [] }
                .filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined()
        } else {
            guard object["stop_reason"] as? String == "end_turn", let content = object["content"] as? [[String: Any]] else { throw TranslationError.incomplete }
            text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        }
        return try TranslationResponse.decode(text, field: field)
    }
}

enum TranslationResponse {
    static var schema: [String: Any] {
        ["type": "object", "properties": ["translation": ["type": "string"]], "required": ["translation"], "additionalProperties": false]
    }
    static func decode(_ text: String, field: String = "translation") throws -> String {
        var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```json\n"), json.hasSuffix("```") { json = String(json.dropFirst(8).dropLast(3)) }
        guard let result = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)),
              let value = result[field] else { throw TranslationError.invalidResponse }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslationError.empty }
        return value
    }
}
