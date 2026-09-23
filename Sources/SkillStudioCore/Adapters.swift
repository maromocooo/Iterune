import Foundation

public struct ScanRoot: Hashable, Sendable {
    public var url: URL
    public var scope: String
    public var maxDepth: Int
    public var origin: SourceOrigin
    /// Only this anchor's own OS alias is trusted. Links below it are not publishable.
    public var anchor: URL
    public init(_ url: URL, scope: String, maxDepth: Int = 3, origin: SourceOrigin = .unknown, anchor: URL? = nil) {
        self.url = url; self.scope = scope; self.maxDepth = maxDepth; self.origin = origin
        self.anchor = anchor ?? url
    }
}

public struct DiscoveryContext: Sendable {
    public var home: URL
    public var projects: [URL]
    public var environment: [String: String]
    public var systemDirectory: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, projects: [URL] = [],
                environment: [String: String] = ProcessInfo.processInfo.environment, systemDirectory: URL = URL(fileURLWithPath: "/etc")) {
        self.home = home; self.projects = projects; self.environment = environment; self.systemDirectory = systemDirectory
    }
}

public protocol AgentAdapter: Sendable {
    var agent: AgentKind { get }
    func roots(in context: DiscoveryContext) -> [ScanRoot]
}

public struct ClaudeAdapter: AgentAdapter {
    public let agent: AgentKind = .claude
    public init() {}
    public func roots(in context: DiscoveryContext) -> [ScanRoot] {
        let config = context.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? context.home.appendingPathComponent(".claude")
        return [ScanRoot(config.appendingPathComponent("skills"), scope: "User", origin: .localUser, anchor: context.environment["CLAUDE_CONFIG_DIR"] == nil ? context.home : config),
                ScanRoot(config.appendingPathComponent("skills/synced"), scope: "Synced", maxDepth: 2, origin: .synced, anchor: context.environment["CLAUDE_CONFIG_DIR"] == nil ? context.home : config),
                ScanRoot(config.appendingPathComponent("plugins/cache"), scope: "Plugin cache", maxDepth: 7, origin: .pluginCache, anchor: context.environment["CLAUDE_CONFIG_DIR"] == nil ? context.home : config)]
            + context.projects.map { ScanRoot($0.appendingPathComponent(".claude/skills"), scope: $0.lastPathComponent, origin: .localProject, anchor: $0) }
    }
}

public struct CodexAdapter: AgentAdapter {
    public let agent: AgentKind = .codex
    public init() {}
    public func roots(in context: DiscoveryContext) -> [ScanRoot] {
        let config = context.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? context.home.appendingPathComponent(".codex")
        var roots = [ScanRoot(context.home.appendingPathComponent(".agents/skills"), scope: "User", origin: .localUser, anchor: context.home),
                     // Legacy local and bundled content coexist here; do not grant blanket write access.
                     ScanRoot(config.appendingPathComponent("skills"), scope: "Local / bundled", anchor: context.environment["CODEX_HOME"] == nil ? context.home : config),
                     ScanRoot(config.appendingPathComponent("skills/.system"), scope: "Bundled", maxDepth: 2, origin: .bundled, anchor: context.environment["CODEX_HOME"] == nil ? context.home : config),
                     ScanRoot(config.appendingPathComponent("plugins/cache"), scope: "Plugin cache", maxDepth: 8, origin: .pluginCache, anchor: context.environment["CODEX_HOME"] == nil ? context.home : config),
                     ScanRoot(context.systemDirectory.appendingPathComponent("codex/skills"), scope: "Administrator", origin: .managed, anchor: context.systemDirectory)]
        for project in context.projects {
            var current = project.standardizedFileURL
            // Include ancestors only inside the nearest Git repository.
            var ancestors: [URL] = []
            while current.path != "/" {
                ancestors.append(current)
                if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) { break }
                current.deleteLastPathComponent()
            }
            let inRepo = ancestors.last.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(".git").path) } ?? false
            roots += (inRepo ? ancestors : [project]).map { ScanRoot($0.appendingPathComponent(".agents/skills"), scope: $0.lastPathComponent, origin: .localProject, anchor: $0) }
            roots.append(ScanRoot(project.appendingPathComponent(".codex/skills"), scope: project.lastPathComponent, origin: .localProject, anchor: project))
        }
        return roots
    }
}

public struct GeminiAdapter: AgentAdapter {
    public let agent: AgentKind = .gemini
    public init() {}
    public func roots(in context: DiscoveryContext) -> [ScanRoot] {
        [ScanRoot(context.home.appendingPathComponent(".gemini/skills"), scope: "User", maxDepth: 1, origin: .localUser, anchor: context.home),
         ScanRoot(context.home.appendingPathComponent(".agents/skills"), scope: "Shared", maxDepth: 1, origin: .localShared, anchor: context.home),
         ScanRoot(context.home.appendingPathComponent(".gemini/extensions"), scope: "Extension cache", maxDepth: 5, origin: .extensionCache, anchor: context.home)]
        + context.projects.flatMap { project in
            [ScanRoot(project.appendingPathComponent(".gemini/skills"), scope: project.lastPathComponent, maxDepth: 1, origin: .localProject, anchor: project),
             ScanRoot(project.appendingPathComponent(".agents/skills"), scope: project.lastPathComponent, maxDepth: 1, origin: .localProject, anchor: project)]
        }
    }
}

public struct DiscoveredSkill: Sendable {
    public let agent: AgentKind
    public let path: String
    public let scope: String
    public let content: String
    public var provenance: SourceProvenance? = nil
    public var id: String { agent.rawValue + ":" + path }
    public var metadata: SkillMetadata { SkillMetadata.parse(content, fallback: URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent) }
}

public struct ScanReport: Sendable {
    public var skills: [DiscoveredSkill] = []
    public var roots: [String] = []
    public var warnings: [String] = []
    public init() {}
}

public struct SkillScanner: Sendable {
    public var adapters: [any AgentAdapter]
    public init(adapters: [any AgentAdapter] = [ClaudeAdapter(), CodexAdapter(), GeminiAdapter()]) { self.adapters = adapters }
    public func scan(context: DiscoveryContext) -> ScanReport {
        var report = ScanReport()
        report.roots = adapters.flatMap { adapter in adapter.roots(in: context).map { "\(adapter.agent.title) · \($0.url.path)" } }
        var seen = Set<String>()
        let locations = SourcePolicy.locations(context: context, adapters: adapters) { report.warnings.append($0) }
        for location in locations {
            let id = location.agent.rawValue + ":" + location.path
            guard seen.insert(id).inserted else { continue }
            do {
                let data = try SourceFile.read(URL(fileURLWithPath: location.path), publishing: false).bytes
                guard let content = String(data: data, encoding: .utf8) else { throw StudioError.message("SKILL.md is not UTF-8") }
                report.skills.append(DiscoveredSkill(agent: location.agent, path: location.path, scope: location.scope,
                                                    content: content, provenance: location.provenance))
            } catch { report.warnings.append("\(location.path): \(error.localizedDescription)") }
        }
        return report
    }
}

/// A small frontmatter reader, not a general YAML parser. Raw markdown is always preserved.
public struct SkillMetadata: Sendable {
    public let name: String
    public let summary: String
    public static func parse(_ content: String, fallback: String) -> SkillMetadata {
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var fields: [String: String] = [:]
        if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            var key: String?
            for line in lines[1..<end] {
                if line.first?.isWhitespace == true, let key {
                    fields[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                } else if let colon = line.firstIndex(of: ":") {
                    let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                    var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    if [">", "|", ">-", "|-"].contains(value) { value = "" }
                    if value.count >= 2, (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") { value = String(value.dropFirst().dropLast()) }
                    fields[name] = value; key = name
                }
            }
        }
        let title = fields["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SkillMetadata(name: title?.isEmpty == false ? title! : fallback,
                             summary: fields["description"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Local agent skill")
    }
}
