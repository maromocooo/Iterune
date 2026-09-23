import Foundation
import CryptoKit

public struct RunCaptureEvidence: Codable, Equatable, Sendable {
    public let kind: String
    public let sessionID: String
    public let turnID: String
    public let sourceLog: String
    public let command: String
    public init(sessionID: String, turnID: String, sourceLog: String, command: String, kind: String = "codex.skill_read") {
        self.kind = kind; self.sessionID = sessionID; self.turnID = turnID
        self.sourceLog = sourceLog; self.command = command
    }
}

public struct RunHistoryReport: Sendable {
    public var runs: [SkillRun] = []
    public var filesRead = 0
    public var skippedFiles = 0
    public var diagnostics: [String: Int] = [:]
    public init() {}
}

public protocol RunHistoryAdapter: Sendable {
    func scan(skill: Skill, versions: [SkillVersion], since: Date, excludedPaths: [String]) async throws -> RunHistoryReport
}

/// Read-only adapter for Codex's local item_completed JSONL format (verified against CLI 0.155).
/// A successful parsed read is evidence of reading a skill, not proof it influenced the answer.
public actor CodexRunHistoryAdapter: RunHistoryAdapter {
    private let root: URL
    private struct Cached {
        let size: Int
        let modified: Date
        let signature: String
        let runs: [SkillRun]
    }
    private var cache: [URL: Cached] = [:]
    public init(root: URL? = nil) {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        self.root = root ?? home.appendingPathComponent("sessions")
    }
    public func scan(skill: Skill, versions: [SkillVersion], since: Date, excludedPaths: [String] = []) async throws -> RunHistoryReport {
        guard skill.agent == .codex, !skill.isDemo, skill.sourcePath != nil else { return RunHistoryReport() }
        let fm = FileManager.default
        var report = RunHistoryReport()
        guard fm.fileExists(atPath: root.path) else { report.diagnostics["History folder not found"] = 1; return report }
        var policy = HistoryPolicy(); policy.excludedPaths = excludedPaths
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else {
            throw StudioError.message("Unable to read local Codex history.")
        }
        var files: [(URL, Date, Int)] = []
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard url.pathExtension == "jsonl" else { continue }
            guard policy.allows(url.path) else { report.diagnostics["Excluded files", default: 0] += 1; continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, let date = values.contentModificationDate, date >= since else { continue }
            let size = values.fileSize ?? 0
            guard size <= 32_000_000 else { report.skippedFiles += 1; continue }
            files.append((url, date, size))
        }
        files.sort { $0.1 > $1.1 }
        if files.count > 100 { report.skippedFiles += files.count - 100 }
        let signature = skill.id + ":" + (skill.sourcePath ?? "") + ":" + versions.map { $0.id.uuidString }.sorted().joined(separator: ",")
        var readBytes = 0
        for (url, date, size) in files.prefix(100) {
            try Task.checkCancellation()
            if let saved = cache[url], saved.size == size, saved.modified == date, saved.signature == signature {
                report.runs += saved.runs.filter { $0.startedAt >= since }; continue
            }
            guard readBytes + size <= 128_000_000 else { report.skippedFiles += 1; continue }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 32_000_000 else { report.skippedFiles += 1; continue }
                readBytes += data.count; report.filesRead += 1
                let runs = try Self.parse(data, sourceLog: url.path, skill: skill, versions: versions)
                cache[url] = Cached(size: size, modified: date, signature: signature, runs: runs)
                report.runs += runs.filter { $0.startedAt >= since }
            } catch is CancellationError { throw CancellationError() }
            catch { report.skippedFiles += 1 }
        }
        let retained = Set(files.prefix(100).map(\.0))
        cache = cache.filter { retained.contains($0.key) }
        report.runs.sort { $0.startedAt > $1.startedAt }
        if report.runs.isEmpty { report.diagnostics["No eligible skill-read turns found"] = 1 }
        if report.skippedFiles > 0 { report.diagnostics["Unreadable files or scan limits", default: 0] += report.skippedFiles }
        return report
    }

    public static func parse(_ data: Data, sourceLog: String, skill: Skill, versions: [SkillVersion]) throws -> [SkillRun] {
        guard skill.agent == .codex, !skill.isDemo, let path = skill.sourcePath else { return [] }
        let target = canonical(path, cwd: "/")
        struct Turn {
            var prompts: [String] = []
            var output = ""
            var model = "Codex"
            var started: Date?
            var duration: Double?
            var command: String?
            var reads: [HistoricalSkillRead] = []
            var artifacts: [String] = []
            var completed = false
            var aborted = false
            var seenItems = Set<String>()
        }
        var sessionID: String?, turns: [String: Turn] = [:]
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()
        func date(_ value: Any?) -> Date? {
            guard let value = value as? String else { return nil }
            return formatter.date(from: value) ?? plainFormatter.date(from: value)
        }
        func texts(_ item: [String: Any]) -> String {
            (item["content"] as? [[String: Any]] ?? []).filter { ["text", "Text"].contains($0["type"] as? String ?? "") }
                .compactMap { $0["text"] as? String }.joined(separator: "\n\n")
        }
        for (index, line) in data.split(separator: 10).enumerated() {
            if index % 100 == 0 { try Task.checkCancellation() }
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let payload = record["payload"] as? [String: Any] else { continue }
            if record["type"] as? String == "session_meta" {
                let next = payload["id"] as? String ?? payload["session_id"] as? String
                if let sessionID, next != sessionID { turns = [:] }
                sessionID = next; continue
            }
            guard let turnID = payload["turn_id"] as? String else { continue }
            var turn = turns[turnID] ?? Turn()
            if record["type"] as? String == "turn_context" { turn.model = payload["model"] as? String ?? turn.model }
            switch payload["type"] as? String {
            case "task_started": turn.started = date(payload["started_at"]) ?? date(record["timestamp"])
            case "task_complete":
                turn.completed = true
                turn.started = turn.started ?? date(payload["started_at"])
                turn.duration = (payload["duration_ms"] as? Double).map { $0 / 1000 }
                if turn.output.isEmpty { turn.output = payload["last_agent_message"] as? String ?? "" }
            case "turn_aborted": turn.aborted = true
            case "item_completed":
                if let threadID = payload["thread_id"] as? String, let sessionID, threadID != sessionID { continue }
                guard let item = payload["item"] as? [String: Any], let itemID = item["id"] as? String else { continue }
                guard turn.seenItems.insert(itemID).inserted else { continue }
                switch item["type"] as? String {
                case "UserMessage":
                    let text = texts(item)
                    if !text.isEmpty { turn.prompts.append(text) }
                case "AgentMessage":
                    if item["phase"] as? String == "final_answer" { turn.output = texts(item) }
                case "CommandExecution":
                    guard item["status"] as? String == "completed", item["exit_code"] as? Int == 0 else { break }
                    let reads = (item["parsed_cmd"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "read" }
                    let cwd = item["cwd"] as? String ?? "/"
                    guard let read = reads.first(where: { ($0["path"] as? String).map { canonical($0, cwd: cwd) == target } ?? false }) else { break }
                    turn.command = read["cmd"] as? String ?? "SKILL.md read"
                    turn.reads.append(HistoryReadExtraction.codex(item: item, read: read, target: target, cwd: cwd))
                case "FileChange":
                    if item["status"] as? String == "completed" {
                        for (path, change) in item["changes"] as? [String: [String: Any]] ?? [:] {
                            if path.hasPrefix("/"), (change["type"] as? String)?.lowercased() != "delete", !turn.artifacts.contains(path) { turn.artifacts.append(path) }
                        }
                    }
                default: break
                }
            default: break
            }
            turns[turnID] = turn
        }
        guard let sessionID else { return [] }
        return turns.compactMap { turnID, turn in
            guard turn.completed, !turn.aborted, let command = turn.command, let started = turn.started,
                  !turn.prompts.isEmpty, !turn.output.isEmpty else { return nil }
            let prompt = turn.prompts.joined(separator: "\n\n")
            guard prompt.utf8.count <= 250_000, turn.output.utf8.count <= 500_000 else { return nil }
            let resolved = RunVersionResolver.resolve(turn.reads, skillID: skill.id, versions: versions)
            return SkillRun(id: stableID(sessionID + ":" + turnID + ":" + skill.id), skillID: skill.id, versionID: resolved.versionID,
                startedAt: started, durationSeconds: turn.duration, prompt: prompt, output: turn.output, model: turn.model,
                artifacts: turn.artifacts.map { HistoryParsing.artifact($0, runID: sessionID + turnID) },
                capture: RunCaptureEvidence(sessionID: sessionID, turnID: turnID, sourceLog: sourceLog, command: command),
                versionAttribution: resolved.attribution, readEvidence: resolved.reads)
        }.sorted { $0.startedAt > $1.startedAt }
    }
    private static func canonical(_ path: String, cwd: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : URL(fileURLWithPath: cwd).appendingPathComponent(expanded)
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }
    private static func stableID(_ value: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

public enum RunHistoryMerge {
    /// Refresh captured content without overwriting the user's rating or feedback.
    @discardableResult public static func merge(_ runs: [SkillRun], into snapshot: inout LibrarySnapshot) -> Int {
        var inserted = 0
        for run in runs where run.capture != nil && snapshot.skills.contains(where: { $0.id == run.skillID && !$0.isDemo }) {
            guard !snapshot.deletedRunIDs.contains(run.id), snapshot.historyPolicy.allows(run.capture?.sourceLog),
                  RunVersionIntegrity.validate(run, versions: snapshot.versions) else { continue }
            if let index = snapshot.runs.firstIndex(where: { $0.id == run.id }) {
                let previous = snapshot.runs[index]
                guard previous.skillID == run.skillID, let oldCapture = previous.capture, let newCapture = run.capture,
                      oldCapture.kind == newCapture.kind, oldCapture.sessionID == newCapture.sessionID,
                      oldCapture.turnID == newCapture.turnID else { continue }
                snapshot.runs[index] = RunVersionIntegrity.merge(previous: previous, incoming: run)
            } else { snapshot.runs.append(run); inserted += 1 }
        }
        return inserted
    }
}
