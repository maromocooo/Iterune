import Foundation

/// Shared, tool-free transport used by translation and reviewed skill improvement.
public struct TextGenerationRequest: Sendable {
    public let prompt: String
    public let responseField: String
    public init(prompt: String, responseField: String = "result") {
        self.prompt = prompt; self.responseField = responseField
    }
    var schema: [String: Any] {
        ["type": "object", "properties": [responseField: ["type": "string"]],
         "required": [responseField], "additionalProperties": false]
    }
    func validate() throws {
        guard !prompt.isEmpty, prompt.utf8.count <= 400_000,
              ["result", "translation"].contains(responseField) else { throw TranslationError.invalidResponse }
    }
}

public protocol TextGenerationService: Sendable {
    func generate(_ request: TextGenerationRequest) async throws -> String
}
