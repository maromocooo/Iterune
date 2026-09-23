import Foundation

public struct ClaudeRunHistoryAdapter: RunHistoryAdapter {
    private let files: LocalHistoryFiles
    public init(root: URL? = nil) {
        let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        files = LocalHistoryFiles(root: root ?? home.appendingPathComponent("projects"))
    }
    public func scan(skill: Skill, versions: [SkillVersion], since: Date, excludedPaths: [String] = []) async throws -> RunHistoryReport {
        guard skill.agent == .claude, !skill.isDemo else { return RunHistoryReport() }
        return try await files.scan(skill: skill, versions: versions, since: since, excludedPaths: excludedPaths, parse: Self.parse)
    }
    public static func parse(_ data: Data, sourceLog: String, skill: Skill, versions: [SkillVersion]) throws -> [SkillRun] {
        guard skill.agent == .claude, !skill.isDemo, let source = skill.sourcePath else { return [] }
        let target = HistoryParsing.canonical(source)
        var session = "", promptID = "", prompt = "", started: Date?, model = "Claude"
        var reads: [HistoricalSkillRead] = []
        var evidence: String?, artifacts: [String] = [], recognized = false
        var pending: [String: (String, String, [String: Any])] = [:], runs: [UUID: SkillRun] = [:], seen = Set<String>()
        for (index, line) in data.split(separator: 10).enumerated() {
            if index % 100 == 0 { try Task.checkCancellation() }
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], row["isSidechain"] as? Bool != true,
                  let message = row["message"] as? [String: Any], let type = row["type"] as? String,
                  ["user", "assistant"].contains(type), let id = row["uuid"] as? String, seen.insert(id).inserted else { continue }
            recognized = true
            if let value = row["sessionId"] as? String {
                if !session.isEmpty && value != session {
                    promptID = ""; prompt = ""; started = nil; evidence = nil; reads = []; pending = [:]; artifacts = []
                }
                session = value
            }
            let blocks = message["content"] as? [[String: Any]] ?? []
            if type == "user", !blocks.contains(where: { $0["type"] as? String == "tool_result" }), row["isMeta"] as? Bool != true {
                prompt = HistoryParsing.text(message["content"]); promptID = id; started = HistoryParsing.date(row["timestamp"])
                evidence = nil; reads = []; artifacts = []; pending = [:]
            }
            if type == "assistant" {
                model = message["model"] as? String ?? model
                for block in blocks where block["type"] as? String == "tool_use" {
                    guard let callID = block["id"] as? String, let name = block["name"] as? String,
                          let input = block["input"] as? [String: Any], let path = input["file_path"] as? String,
                          ["Read", "Write", "Edit"].contains(name) else { continue }
                    pending[callID] = (name, HistoryParsing.canonical(path, cwd: row["cwd"] as? String ?? "/"), input)
                }
            }
            for block in blocks where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String, let (name, path, input) = pending.removeValue(forKey: id), block["is_error"] as? Bool != true else { continue }
                if name == "Read", path == target {
                    evidence = "Read " + path
                    reads.append(HistoryReadExtraction.claude(input: input, result: block))
                } else if ["Write", "Edit"].contains(name), !artifacts.contains(path) { artifacts.append(path) }
            }
            if type == "assistant", message["stop_reason"] as? String == "end_turn", let evidence, let started, !prompt.isEmpty, !session.isEmpty {
                let output = HistoryParsing.text(message["content"])
                guard !output.isEmpty, output.utf8.count <= 500_000, prompt.utf8.count <= 250_000 else { continue }
                let runID = HistoryParsing.id("claude:" + session + ":" + promptID + ":" + skill.id)
                let resolved = RunVersionResolver.resolve(reads, skillID: skill.id, versions: versions)
                runs[runID] = SkillRun(id: runID, skillID: skill.id, versionID: resolved.versionID, startedAt: started,
                    durationSeconds: HistoryParsing.date(row["timestamp"]).map { max(0, $0.timeIntervalSince(started)) }, prompt: prompt, output: output, model: model,
                    artifacts: artifacts.map { HistoryParsing.artifact($0, runID: runID.uuidString) },
                    capture: RunCaptureEvidence(sessionID: session, turnID: promptID, sourceLog: sourceLog, command: evidence, kind: "claude.skill_read"),
                    versionAttribution: resolved.attribution, readEvidence: resolved.reads)
            }
        }
        guard recognized else { throw HistoryParseError.unsupported }
        return Array(runs.values)
    }
}
