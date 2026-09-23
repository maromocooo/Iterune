import Foundation
import CryptoKit

public enum RunVersionKind: String, Codable, Sendable {
    case matchingContent = "matching-content"
    case manualAssociation = "manual-association"
    case unknown
    case legacyUnverified = "legacy-unverified"
}

public enum RunVersionUnknownReason: String, Codable, Sendable {
    case incompleteRead = "incomplete-read"
    case unsupportedReadFormat = "unsupported-read-format"
    case noMatchingVersion = "no-matching-version"
    case ambiguousMatchingVersions = "ambiguous-matching-versions"
    case conflictingReadEvidence = "conflicting-read-evidence"
    case notSpecified = "not-specified"
}

/// A frozen association with the library at import time, not an observed execution-time revision ID.
public struct RunVersionAttribution: Codable, Equatable, Sendable {
    public var kind: RunVersionKind
    public var candidateVersionIDs: [UUID]
    public var reason: RunVersionUnknownReason?
    public init(kind: RunVersionKind, candidateVersionIDs: [UUID] = [], reason: RunVersionUnknownReason? = nil) {
        self.kind = kind
        self.candidateVersionIDs = Array(Set(candidateVersionIDs)).sorted { $0.uuidString < $1.uuidString }
        self.reason = reason
    }
    public static func unknown(_ reason: RunVersionUnknownReason) -> Self { .init(kind: .unknown, reason: reason) }
}

/// Only digests/completeness are retained; no additional transcript or historical Skill body is stored.
public struct RunReadEvidence: Codable, Equatable, Sendable {
    public var completeBodySHA256: [String] = []
    public var sawIncompleteRead = false
    public var sawUnsupportedRead = false
    public init() {}
    public func union(_ other: Self) -> Self {
        var result = self
        result.completeBodySHA256 = Array(Set(completeBodySHA256 + other.completeBodySHA256)).sorted()
        result.sawIncompleteRead = sawIncompleteRead || other.sawIncompleteRead
        result.sawUnsupportedRead = sawUnsupportedRead || other.sawUnsupportedRead
        return result
    }
}

/// Transient adapter result. Only adapters may assert that a body is complete.
enum HistoricalSkillRead {
    case complete(String), incomplete, unsupported
}

struct ResolvedRunVersion {
    let versionID: UUID?
    let attribution: RunVersionAttribution
    let reads: RunReadEvidence
}

enum RunVersionResolver {
    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func resolve(_ reads: [HistoricalSkillRead], skillID: String, versions: [SkillVersion]) -> ResolvedRunVersion {
        var evidence = RunReadEvidence()
        var bodies: [Data] = []
        for read in reads {
            switch read {
            case .complete(let body):
                guard !body.isEmpty else { evidence.sawIncompleteRead = true; continue }
                let bytes = Data(body.utf8)
                if !bodies.contains(bytes) { bodies.append(bytes); evidence.completeBodySHA256.append(digest(body)) }
            case .incomplete: evidence.sawIncompleteRead = true
            case .unsupported: evidence.sawUnsupportedRead = true
            }
        }
        evidence.completeBodySHA256.sort()
        func unknown(_ reason: RunVersionUnknownReason) -> ResolvedRunVersion {
            .init(versionID: nil, attribution: .unknown(reason), reads: evidence)
        }
        guard bodies.count <= 1 else { return unknown(.conflictingReadEvidence) }
        guard let bytes = bodies.first else { return unknown(evidence.sawIncompleteRead ? .incompleteRead : .unsupportedReadFormat) }
        let ids = versions.filter { $0.skillID == skillID && !$0.content.isEmpty && Data($0.content.utf8) == bytes }.map(\.id)
        guard !ids.isEmpty else { return unknown(.noMatchingVersion) }
        return .init(versionID: ids.count == 1 ? ids[0] : nil,
                     attribution: .init(kind: .matchingContent, candidateVersionIDs: ids,
                                        reason: ids.count > 1 ? .ambiguousMatchingVersions : nil), reads: evidence)
    }
}

/// No shell evaluation, recursive wrapper guessing, trimming, or Unicode/newline normalization.
enum HistoryReadExtraction {
    static func hasRange(_ input: [String: Any]) -> Bool {
        ["offset", "limit", "start_line", "end_line", "startLine", "endLine", "line_range", "range", "pages"].contains { input[$0] != nil }
    }
    static func truncated(_ metadata: [String: Any], text: String) -> Bool {
        ["truncated", "is_truncated", "output_truncated"].contains { metadata[$0] as? Bool == true }
        || text.contains("[truncated]") || text.contains("[Output truncated") || text.contains("[output truncated")
        || text.contains("Output is truncated") || text.contains("… tokens truncated") || text.contains("... tokens truncated")
        || text.contains("Warning: truncated output") || text.contains("(truncated)")
        || text.contains("Showing lines ") || text.contains("Showing first ")
    }
    static func plainBody(_ text: String, metadata: [String: Any]) -> HistoricalSkillRead {
        if truncated(metadata, text: text) || text.isEmpty { return .incomplete }
        // Numbered Read output is not reversible byte-for-byte (notably final newlines).
        if text.range(of: #"(?m)^\s*\d+(?:→|\t|\|)"#, options: .regularExpression) != nil
            || text.hasPrefix("<") || text.hasPrefix("{") || text.hasPrefix("Chunk ID:") || text.hasPrefix("File:")
            || text.hasPrefix("--- ") || text.hasPrefix("=== ") { return .unsupported }
        return .complete(text)
    }
    static func claude(input: [String: Any], result: [String: Any]) -> HistoricalSkillRead {
        if hasRange(input) { return .incomplete }
        let text: String
        if let raw = result["content"] as? String { text = raw }
        else if let blocks = result["content"] as? [[String: Any]], blocks.count == 1,
                blocks[0]["type"] as? String == "text", let raw = blocks[0]["text"] as? String { text = raw }
        else { return .unsupported }
        return plainBody(text, metadata: result)
    }
    static func gemini(args: [String: Any], call: [String: Any]) -> HistoricalSkillRead {
        if hasRange(args) { return .incomplete }
        let text: String
        if let raw = call["result"] as? String { text = raw }
        else if let parts = call["result"] as? [[String: Any]], parts.count == 1,
                let function = parts[0]["functionResponse"] as? [String: Any],
                let response = function["response"] as? [String: Any],
                Set(response.keys) == ["output"], let raw = response["output"] as? String { text = raw }
        else { return .unsupported }
        return plainBody(text, metadata: call)
    }
    static func codex(item: [String: Any], read: [String: Any], target: String, cwd: String) -> HistoricalSkillRead {
        if hasRange(read) || hasRange(item) { return .incomplete }
        guard let parsed = item["parsed_cmd"] as? [[String: Any]], parsed.count == 1,
              let command = item["command"] as? String ?? read["cmd"] as? String else { return .unsupported }
        // Accept only literal cat with exactly one operand. No switches except --, expansion, pipelines, or shell wrappers.
        let pattern = #"^(?:cat|/bin/cat)\s+(?:--\s+)?(?:'([^'\n]+)'|"([^"\n]+)"|([^\s'";|&<>`$\\]+))$"#
        guard !command.contains("\n"), !command.contains("\r"),
              let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              match.range.length == (command as NSString).length else {
            return command.range(of: #"\b(head|tail|sed)\b"#, options: .regularExpression) != nil ? .incomplete : .unsupported
        }
        let operand = (1...3).compactMap { index -> String? in
            guard let range = Range(match.range(at: index), in: command) else { return nil }
            return String(command[range])
        }.first ?? ""
        guard !operand.contains("$"), !operand.contains("`"), !operand.contains("\\"), !operand.contains("*"), !operand.contains("?"),
              !operand.contains("["), !operand.contains("]"), !operand.contains("{"), !operand.contains("}"), !operand.hasPrefix("~"),
              HistoryParsing.canonical(operand, cwd: cwd) == target else { return .unsupported }
        // aggregated_output can mix stderr, explanatory wrappers, and stdout; it is never a complete body here.
        guard let stdout = item["stdout"] as? String, !stdout.isEmpty else { return .unsupported }
        guard (item["stderr"] as? String ?? "").isEmpty else { return .unsupported }
        return plainBody(stdout, metadata: item)
    }
}

public enum RunVersionIntegrity {
    public static func validate(_ run: SkillRun, versions: [SkillVersion]) -> Bool {
        let owned = versions.filter { $0.skillID == run.skillID }
        guard run.versionID == nil || owned.contains(where: { $0.id == run.versionID }) else { return false }
        let value = run.effectiveVersionAttribution
        guard Set(value.candidateVersionIDs).count == value.candidateVersionIDs.count,
              value.candidateVersionIDs.allSatisfy({ id in owned.contains { $0.id == id } }) else { return false }
        if let reads = run.readEvidence {
            guard Set(reads.completeBodySHA256).count == reads.completeBodySHA256.count,
                  reads.completeBodySHA256.allSatisfy({ $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }) else { return false }
        }
        switch value.kind {
        case .matchingContent:
            guard let reads = run.readEvidence, reads.completeBodySHA256.count == 1,
                  !value.candidateVersionIDs.isEmpty else { return false }
            let digest = reads.completeBodySHA256[0]
            guard value.candidateVersionIDs.allSatisfy({ id in
                owned.contains { $0.id == id && !$0.content.isEmpty && RunVersionResolver.digest($0.content) == digest }
            }) else { return false }
            return value.candidateVersionIDs.count == 1
                ? run.versionID == value.candidateVersionIDs[0] && value.reason == nil
                : run.versionID == nil && value.reason == .ambiguousMatchingVersions
        case .manualAssociation:
            return run.versionID != nil && value.candidateVersionIDs.isEmpty && value.reason == nil
        case .legacyUnverified:
            return value.candidateVersionIDs.isEmpty && value.reason == nil
        case .unknown:
            return run.versionID == nil && value.candidateVersionIDs.isEmpty && value.reason != nil
        }
    }

    /// Explicit UI registration is the only path that labels an association as user-selected.
    public static func recordManual(_ run: SkillRun, into snapshot: inout LibrarySnapshot) throws {
        guard let skill = snapshot.skills.first(where: { $0.id == run.skillID }),
              run.capture == nil, !snapshot.runs.contains(where: { $0.id == run.id }),
              !snapshot.deletedRunIDs.contains(run.id) else { throw StudioError.message("Run version does not belong to this skill.") }
        var manual = run
        manual.isDemo = skill.isDemo
        manual.versionAttribution = run.versionID == nil ? .unknown(.notSpecified) : .init(kind: .manualAssociation)
        manual.readEvidence = nil
        guard validate(manual, versions: snapshot.versions) else { throw StudioError.message("Run version does not belong to this skill.") }
        snapshot.runs.append(manual)
    }

    /// Update observation facts independently of the frozen association. Never rematch unchanged body evidence.
    static func merge(previous: SkillRun, incoming: SkillRun) -> SkillRun {
        var updated = incoming
        updated.rating = previous.rating; updated.feedback = previous.feedback
        let oldReads = previous.readEvidence ?? RunReadEvidence()
        let incomingReads = incoming.readEvidence ?? RunReadEvidence()
        let combined = oldReads.union(incomingReads)
        updated.readEvidence = previous.readEvidence == nil && incoming.readEvidence == nil ? nil : combined
        let kind = previous.effectiveVersionAttribution.kind
        if kind == .manualAssociation || kind == .legacyUnverified || previous.versionAttribution == nil {
            updated.versionID = previous.versionID; updated.versionAttribution = previous.versionAttribution
        } else if combined.completeBodySHA256.count > 1 {
            updated.versionID = nil; updated.versionAttribution = .unknown(.conflictingReadEvidence)
        } else if !oldReads.completeBodySHA256.isEmpty || incomingReads.completeBodySHA256.isEmpty {
            // Includes no-match and ambiguous results: library additions alone are not new read evidence.
            updated.versionID = previous.versionID; updated.versionAttribution = previous.versionAttribution
        }
        return updated
    }
}
