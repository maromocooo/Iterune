import Foundation
import Darwin

public enum SourceOrigin: String, Codable, CaseIterable, Sendable {
    case localUser, localProject, localShared, pluginCache, synced, managed, bundled, extensionCache, unknown
    public var isLocal: Bool { [.localUser, .localProject, .localShared].contains(self) }
    var priority: Int {
        switch self {
        case .managed: return 90
        case .bundled: return 80
        case .pluginCache: return 70
        case .extensionCache: return 60
        case .synced: return 50
        case .unknown: return 40
        case .localProject: return 30
        case .localShared: return 20
        case .localUser: return 10
        }
    }
}

/// An observation from discovery, never a persisted permission to write.
public struct SourceProvenance: Codable, Equatable, Sendable {
    public var origin: SourceOrigin
    public var hasLinkedPath: Bool
    public init(origin: SourceOrigin, hasLinkedPath: Bool = false) {
        self.origin = origin; self.hasLinkedPath = hasLinkedPath
    }
}

public enum SourceRestriction: String, Codable, Sendable {
    case externalManagement, unknownOrigin, noSource, missingOrUnreadable, linkedPath, sharedFile, nonRegularFile, notWritable, changed, staleConfirmation
    public var message: String {
        switch self {
        case .externalManagement: return L("This skill is externally managed. Library improvements can be saved, but direct source publishing is blocked.")
        case .unknownOrigin: return L("Source ownership is unverified. Rescan; unclassified sources remain read-only.")
        case .noSource: return L("This skill has no publishable source file.")
        case .missingOrUnreadable: return L("Source missing or unreadable. Your saved history is still available.")
        case .linkedPath: return L("Publishing through a symbolic link is not supported. Library editing remains available.")
        case .sharedFile: return L("The source has multiple hard links. Direct publishing is blocked.")
        case .nonRegularFile: return L("The source must be a regular SKILL.md file.")
        case .notWritable: return L("The source or its directory is not writable. No permissions were changed.")
        case .changed: return L("SKILL.md changed outside the app. Rescan and review the source diff before publishing.")
        case .staleConfirmation: return L("The library version, source or safety conditions changed. Close this confirmation and review again.")
        }
    }
}

public enum PublishEligibility: Equatable, Sendable {
    case allowed
    case readOnly(SourceRestriction)
    case unavailable(SourceRestriction)
    public var reason: SourceRestriction? {
        switch self { case .allowed: return nil; case .readOnly(let reason), .unavailable(let reason): return reason }
    }
}

struct SourceLocation: Sendable {
    let agent: AgentKind
    let path: String
    let scope: String
    let provenance: SourceProvenance
}

public enum SourcePolicy {
    static let adapters: [any AgentAdapter] = [ClaudeAdapter(), CodexAdapter(), GeminiAdapter()]
    static func contains(_ child: URL, in root: URL) -> Bool {
        let a = child.standardizedFileURL.pathComponents, b = root.standardizedFileURL.pathComponents
        return a.count >= b.count && Array(a.prefix(b.count)) == b
    }
    static func linkedBelowAnchor(_ path: URL, anchor: URL) -> Bool {
        let anchor = anchor.standardizedFileURL
        guard contains(path, in: anchor) else { return true }
        let suffix = path.standardizedFileURL.pathComponents.dropFirst(anchor.pathComponents.count)
        var cursor = anchor.resolvingSymlinksInPath()
        for component in suffix {
            cursor.appendPathComponent(component)
            var info = stat()
            if lstat(cursor.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { return true }
        }
        return false
    }
    /// Enumerate metadata only. Preserve every root's evidence before physical-file deduplication.
    /// Protected origins from ANY adapter win, including aliases from protected caches into local roots.
    static func locations(context: DiscoveryContext, adapters: [any AgentAdapter] = adapters, warning: (String) -> Void = { _ in }) -> [SourceLocation] {
        let fm = FileManager.default
        let allRoots = Self.adapters.flatMap { $0.roots(in: context) }
        var entries: [SourceLocation] = []
        for adapter in adapters {
            for root in adapter.roots(in: context) {
                func walk(_ url: URL, depth: Int, ancestors: Set<String>) {
                    guard depth <= root.maxDepth else { return }
                    let canonical = url.resolvingSymlinksInPath().standardizedFileURL
                    guard !ancestors.contains(canonical.path) else { return }
                    var isDirectory: ObjCBool = false
                    guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
                    let file = url.appendingPathComponent("SKILL.md")
                    var info = stat()
                    if lstat(file.path, &info) == 0 {
                        let physical = file.resolvingSymlinksInPath().standardizedFileURL
                        let recordedPath = canonical.appendingPathComponent("SKILL.md").path
                        let containingOrigins = allRoots.filter {
                            contains(physical, in: $0.url.resolvingSymlinksInPath()) || contains(file, in: $0.url)
                        }.map(\.origin)
                        let origin = (containingOrigins + [root.origin]).max { $0.priority < $1.priority } ?? .unknown
                        entries.append(SourceLocation(agent: adapter.agent, path: recordedPath, scope: root.scope,
                            provenance: SourceProvenance(origin: origin, hasLinkedPath: linkedBelowAnchor(file, anchor: root.anchor))))
                        return
                    }
                    let children: [URL]
                    do { children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) }
                    catch { warning("\(url.path): \(error.localizedDescription)"); return }
                    var next = ancestors; next.insert(canonical.path)
                    for child in children.sorted(by: { $0.path < $1.path }) where ![".git", "node_modules", ".build", "assets", "references", "scripts"].contains(child.lastPathComponent) {
                        walk(child, depth: depth + 1, ancestors: next)
                    }
                }
                walk(root.url, depth: 0, ancestors: [])
            }
        }
        // Cross-agent aliases still refer to the same physical file and cannot weaken protection.
        let grouped = Dictionary(grouping: entries) { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }
        return entries.map { entry in
            let peers = grouped[URL(fileURLWithPath: entry.path).resolvingSymlinksInPath().path] ?? [entry]
            return SourceLocation(agent: entry.agent, path: entry.path, scope: entry.scope,
                provenance: SourceProvenance(origin: peers.map { $0.provenance.origin }.max { $0.priority < $1.priority } ?? .unknown,
                                             hasLinkedPath: peers.contains { $0.provenance.hasLinkedPath }))
        }
    }
    public static func eligibility(provenance: SourceProvenance?) -> PublishEligibility {
        guard let provenance else { return .readOnly(.unknownOrigin) }
        if !provenance.origin.isLocal {
            return .readOnly(provenance.origin == .unknown ? .unknownOrigin : .externalManagement)
        }
        if provenance.hasLinkedPath { return .readOnly(.linkedPath) }
        return .allowed
    }
    /// Re-discover current roots; never use a serialized provenance field as authorization.
    static func currentProvenance(skill: Skill, context: DiscoveryContext) throws -> SourceProvenance {
        guard !skill.isDemo, let path = skill.sourcePath else { throw SourcePublishError.blocked(.noSource) }
        let url = URL(fileURLWithPath: path)
        guard url.lastPathComponent == "SKILL.md", skill.id == skill.agent.rawValue + ":" + path else {
            throw SourcePublishError.blocked(.unknownOrigin)
        }
        // Inspect the supplied path BEFORE canonicalization, so final links cannot disappear.
        var info = stat()
        guard lstat(path, &info) == 0 else { throw SourcePublishError.blocked(.missingOrUnreadable) }
        guard info.st_mode & S_IFMT != S_IFLNK else { throw SourcePublishError.blocked(.linkedPath) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw SourcePublishError.blocked(.nonRegularFile) }
        guard let entry = locations(context: context).first(where: { $0.agent == skill.agent && $0.path == path }) else {
            throw SourcePublishError.blocked(.unknownOrigin)
        }
        if let reason = eligibility(provenance: entry.provenance).reason { throw SourcePublishError.blocked(reason) }
        return entry.provenance
    }
}

public enum SourcePublishError: LocalizedError {
    case blocked(SourceRestriction)
    public var errorDescription: String? { switch self { case .blocked(let reason): return reason.message } }
}
