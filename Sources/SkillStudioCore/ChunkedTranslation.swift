import Foundation

public struct TranslationProgress: Sendable, Equatable {
    public let completed: Int
    public let total: Int
    public init(completed: Int, total: Int) { self.completed = completed; self.total = total }
}

/// Split long documents into bounded requests. Assemble only after every request succeeds.
/// Fenced code and the whitespace between fragments stay byte-for-byte local.
public struct ChunkedTranslationService: SkillTranslationService {
    public static let maximumConcurrency = 18
    private let base: any SkillTranslationService
    private let maxConcurrentRequests: Int
    public init(base: any SkillTranslationService, maxConcurrentRequests: Int = maximumConcurrency) {
        self.base = base
        self.maxConcurrentRequests = min(Self.maximumConcurrency, max(1, maxConcurrentRequests))
    }

    public func translate(_ request: SkillTranslationRequest) async throws -> String {
        try await translate(request, progress: { _ in })
    }

    public func translate(_ request: SkillTranslationRequest, progress: @escaping @Sendable (TranslationProgress) async -> Void) async throws -> String {
        try request.validate()
        try Task.checkCancellation()
        let fragments = TranslationFragment.split(request.content)
        let jobs = fragments.indices.filter { fragments[$0].needsTranslation }
        var results = fragments.map(\.source)
        await progress(.init(completed: 0, total: jobs.count))
        // Fill the configured window immediately; completion order never changes document order.
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var next = 0, completed = 0
            func enqueue(_ index: Int) {
                let fragment = fragments[index]
                group.addTask {
                    try Task.checkCancellation()
                    let translated = try await base.translate(.init(content: fragment.body, language: request.language))
                    return (index, try fragment.restoringWhitespace(translated))
                }
            }
            while next < min(maxConcurrentRequests, jobs.count) { enqueue(jobs[next]); next += 1 }
            while let (index, value) = try await group.next() {
                try Task.checkCancellation()
                results[index] = value; completed += 1
                await progress(.init(completed: completed, total: jobs.count))
                if next < jobs.count { enqueue(jobs[next]); next += 1 }
            }
        }
        try Task.checkCancellation()
        return results.joined()
    }
}

struct TranslationFragment: Sendable {
    let source: String
    let needsTranslation: Bool
    var body: String { source.trimmingCharacters(in: .whitespacesAndNewlines) }
    func restoringWhitespace(_ result: String) throws -> String {
        let translated = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else { throw TranslationError.empty }
        let leading = source.prefix(while: \.isWhitespace)
        let trailing = source.reversed().prefix(while: \.isWhitespace).reversed()
        return String(leading) + translated + String(trailing)
    }

    static func split(_ source: String, targetBytes: Int = 5_000) -> [Self] {
        precondition(targetBytes > 0)
        var fragments: [Self] = [], prose = "", code = ""
        var fence: (character: Character, count: Int)?
        func flushProse() {
            guard !prose.isEmpty else { return }
            fragments.append(Self(source: prose, needsTranslation: !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            prose = ""
        }
        // Keep newlines (including CRLF) instead of reconstructing Markdown separators.
        var lines: [String] = [], start = source.startIndex
        for index in source.indices where source[index] == "\n" || source[index] == "\r\n" {
            let end = source.index(after: index)
            lines.append(String(source[start..<end])); start = end
        }
        if start < source.endIndex { lines.append(String(source[start...])) }
        for line in lines {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if let active = fence {
                code += line
                let prefix = trimmed.prefix(while: { $0 == active.character })
                if prefix.count >= active.count, trimmed.dropFirst(prefix.count).allSatisfy(\.isWhitespace) {
                    fragments.append(Self(source: code, needsTranslation: false)); code = ""; fence = nil
                }
            } else if let first = trimmed.first, first == "`" || first == "~", trimmed.prefix(while: { $0 == first }).count >= 3 {
                flushProse(); fence = (first, trimmed.prefix(while: { $0 == first }).count); code = line
            } else {
                if !prose.isEmpty, prose.utf8.count + line.utf8.count > targetBytes { flushProse() }
                // A single long line is kept intact to avoid cutting inline code, links or table cells.
                prose += line
            }
        }
        flushProse()
        if !code.isEmpty { fragments.append(Self(source: code, needsTranslation: false)) }
        return fragments
    }
}
