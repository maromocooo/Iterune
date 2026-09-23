import Foundation

public struct GeminiRunHistoryAdapter: RunHistoryAdapter {
    private let files: LocalHistoryFiles
    public init(root: URL? = nil) {
        files = LocalHistoryFiles(root: root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/tmp"))
    }
    public func scan(skill: Skill, versions: [SkillVersion], since: Date, excludedPaths: [String] = []) async throws -> RunHistoryReport {
        guard skill.agent == .gemini, !skill.isDemo else { return RunHistoryReport() }
        return try await files.scan(skill: skill, versions: versions, since: since, excludedPaths: excludedPaths, parse: Self.parse)
    }
    public static func parse(_ data: Data, sourceLog: String, skill: Skill, versions: [SkillVersion]) throws -> [SkillRun] {
        guard skill.agent == .gemini, !skill.isDemo, let path = skill.sourcePath else { return [] }
        var metadata: [String: Any] = [:], messages: [[String: Any]] = []
        func mergeMessage(_ message: [String: Any]) {
            guard let id = message["id"] as? String else { return }
            if let i = messages.firstIndex(where: { $0["id"] as? String == id }) { messages[i] = message } else { messages.append(message) }
        }
        let whole = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rows = whole.map { [$0] } ?? data.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        for (index, row) in rows.enumerated() {
            if index % 100 == 0 { try Task.checkCancellation() }
            if let rewind = row["$rewindTo"] as? String {
                if let i = messages.firstIndex(where: { $0["id"] as? String == rewind }) { messages.removeSubrange(i...) } else { messages = [] }
            } else if let update = row["$set"] as? [String: Any] {
                if let next = update["sessionId"] as? String, let old = metadata["sessionId"] as? String, next != old { messages = []; metadata = [:] }
                metadata.merge(update, uniquingKeysWith: { _, new in new })
                if let replacement = update["messages"] as? [[String: Any]] { messages = replacement }
            } else if row["sessionId"] != nil {
                if let next = row["sessionId"] as? String, let old = metadata["sessionId"] as? String, next != old { messages = []; metadata = [:] }
                metadata.merge(row, uniquingKeysWith: { _, new in new })
                for message in row["messages"] as? [[String: Any]] ?? [] { mergeMessage(message) }
            } else if row["id"] != nil { mergeMessage(row) }
        }
        guard let session = metadata["sessionId"] as? String else { throw HistoryParseError.unsupported }
        guard metadata["kind"] as? String != "subagent" else { return [] }
        let target = HistoryParsing.canonical(path)
        var prompt = "", turn = "", started: Date?, evidence: String?, artifacts: [String] = []
        var reads: [HistoricalSkillRead] = []
        var runs: [UUID: SkillRun] = [:]
        for message in messages {
            try Task.checkCancellation()
            switch message["type"] as? String {
            case "user":
                prompt = HistoryParsing.text(message["content"]); turn = message["id"] as? String ?? ""
                started = HistoryParsing.date(message["timestamp"]); evidence = nil; reads = []; artifacts = []
            case "error":
                runs.removeValue(forKey: HistoryParsing.id("gemini:" + session + ":" + turn + ":" + skill.id)); evidence = nil
            case "gemini":
                let calls = message["toolCalls"] as? [[String: Any]] ?? []
                for call in calls where call["status"] as? String == "success" && call["agentId"] == nil {
                    guard let name = call["name"] as? String, let args = call["args"] as? [String: Any] else { continue }
                    let rawPath = args["file_path"] as? String ?? args["absolute_path"] as? String
                    if let rawPath, rawPath.hasPrefix("/") {
                        let file = HistoryParsing.canonical(rawPath)
                        if name == "read_file", file == target {
                            evidence = "read_file " + file
                            reads.append(HistoryReadExtraction.gemini(args: args, call: call))
                        }
                        if ["write_file", "replace"].contains(name), !artifacts.contains(file) { artifacts.append(file) }
                    }
                    // Name-only activation cannot distinguish duplicate skills; require the source path in its result.
                    if name == "activate_skill", let result = call["result"], HistoryParsing.toolResult(result).contains(path) { evidence = "activate_skill " + path; reads.append(.unsupported) }
                }
                let output = HistoryParsing.text(message["content"])
                guard calls.isEmpty, message["tokens"] is [String: Any], let evidence, let started, !turn.isEmpty,
                      !prompt.isEmpty, !output.isEmpty, prompt.utf8.count <= 250_000, output.utf8.count <= 500_000 else { continue }
                let id = HistoryParsing.id("gemini:" + session + ":" + turn + ":" + skill.id)
                let resolved = RunVersionResolver.resolve(reads, skillID: skill.id, versions: versions)
                runs[id] = SkillRun(id: id, skillID: skill.id, versionID: resolved.versionID, startedAt: started,
                    durationSeconds: HistoryParsing.date(message["timestamp"]).map { max(0, $0.timeIntervalSince(started)) }, prompt: prompt, output: output,
                    model: message["model"] as? String ?? "Gemini", artifacts: artifacts.map { HistoryParsing.artifact($0, runID: id.uuidString) },
                    capture: RunCaptureEvidence(sessionID: session, turnID: turn, sourceLog: sourceLog, command: evidence, kind: "gemini.skill_read"),
                    versionAttribution: resolved.attribution, readEvidence: resolved.reads)
            default: break
            }
        }
        return Array(runs.values)
    }
}
