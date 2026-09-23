import Foundation
import CryptoKit

enum HistoryParseError: Error { case unsupported }

enum HistoryParsing {
    static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func text(_ content: Any?) -> String {
        if let string = content as? String { return string }
        return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    static func toolResult(_ content: Any?) -> String {
        if let string = content as? String { return string }
        if let parts = content as? [Any] { return parts.map(toolResult).joined(separator: "\n") }
        guard let object = content as? [String: Any] else { return "" }
        if let text = object["text"] as? String { return text }
        for key in ["functionResponse", "response", "output", "content", "result"] {
            if let child = object[key] { return toolResult(child) }
        }
        return ""
    }
    static func canonical(_ path: String, cwd: String = "/") -> String {
        let path = (path as NSString).expandingTildeInPath
        return (path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: cwd).appendingPathComponent(path))
            .standardizedFileURL.resolvingSymlinksInPath().path
    }
    static func id(_ text: String) -> UUID {
        var b = Array(SHA256.hash(data: Data(text.utf8)).prefix(16)); b[6] = b[6] & 15 | 128; b[8] = b[8] & 63 | 128
        return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }
    static func artifact(_ path: String, runID: String) -> Artifact {
        Artifact(id: id(runID + ":" + path), name: URL(fileURLWithPath: path).lastPathComponent, path: path, mediaType: "application/octet-stream")
    }
}

/// Bounded, cached file reads. Parsing code never executes transcript commands.
actor LocalHistoryFiles {
    private let root: URL
    private struct Cached { let size: Int; let date: Date; let signature: String; let runs: [SkillRun] }
    private var cache: [URL: Cached] = [:]
    init(root: URL) { self.root = root }
    func scan(skill: Skill, versions: [SkillVersion], since: Date, excludedPaths: [String],
              parse: (Data, String, Skill, [SkillVersion]) throws -> [SkillRun]) throws -> RunHistoryReport {
        var report = RunHistoryReport(), policy = HistoryPolicy(); policy.excludedPaths = excludedPaths
        guard FileManager.default.fileExists(atPath: root.path) else { report.diagnostics["History folder not found"] = 1; return report }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { throw HistoryParseError.unsupported }
        var files: [(URL, Int, Date)] = []
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard ["jsonl", "json"].contains(url.pathExtension) else { continue }
            guard policy.allows(url.path) else { report.diagnostics["Excluded files", default: 0] += 1; continue }
            guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]), info.isRegularFile == true, info.isSymbolicLink != true,
                  let date = info.contentModificationDate, date >= since else { continue }
            files.append((url, info.fileSize ?? 0, date))
        }
        files.sort { $0.2 > $1.2 }
        report.skippedFiles = max(0, files.count - 100)
        let signature = skill.id + versions.map { $0.id.uuidString }.joined()
        var bytes = 0
        for (url, size, date) in files.prefix(100) {
            try Task.checkCancellation()
            if let cached = cache[url], cached.size == size, cached.date == date, cached.signature == signature { report.runs += cached.runs; continue }
            guard size <= 32_000_000, bytes + size <= 128_000_000 else { report.skippedFiles += 1; continue }
            do {
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                guard let data = try handle.read(upToCount: 32_000_001), data.count <= 32_000_000 else { report.skippedFiles += 1; continue }
                bytes += data.count; report.filesRead += 1
                let runs = try parse(data, url.path, skill, versions)
                cache[url] = Cached(size: size, date: date, signature: signature, runs: runs)
                report.runs += runs
            } catch is CancellationError { throw CancellationError() }
            catch HistoryParseError.unsupported { report.diagnostics["Unsupported history format", default: 0] += 1 }
            catch { report.skippedFiles += 1 }
        }
        let retained = Set(files.prefix(100).map(\.0)); cache = cache.filter { retained.contains($0.key) }
        report.runs = report.runs.filter { $0.startedAt >= since }.sorted { $0.startedAt > $1.startedAt }
        if report.runs.isEmpty { report.diagnostics["No eligible skill-read turns found"] = 1 }
        if report.skippedFiles > 0 { report.diagnostics["Unreadable files or scan limits"] = report.skippedFiles }
        return report
    }
}
