import Foundation

public enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, gemini
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var symbol: String {
        switch self { case .claude: return "sun.max"; case .codex: return "terminal"; case .gemini: return "sparkles" }
    }
}

public struct Skill: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var agent: AgentKind
    public var name: String
    public var summary: String
    public var sourcePath: String?
    public var scope: String
    public var isDemo: Bool
    public var isAvailable: Bool
    public var lastDiskContent: String
    public var activeVersionID: UUID
    public var sourceProvenance: SourceProvenance?
    public var sourceObservation: SourceObservation?
    public var lastPublishedVersionID: UUID?
    public init(id: String, agent: AgentKind, name: String, summary: String, sourcePath: String?, scope: String,
                isDemo: Bool = false, isAvailable: Bool = true, lastDiskContent: String, activeVersionID: UUID) {
        self.id = id; self.agent = agent; self.name = name; self.summary = summary; self.sourcePath = sourcePath
        self.scope = scope; self.isDemo = isDemo; self.isAvailable = isAvailable
        self.lastDiskContent = lastDiskContent; self.activeVersionID = activeVersionID
    }
}

public struct SkillVersion: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var skillID: String
    public var number: Int
    public var createdAt: Date
    public var content: String
    public var note: String
    public var originRunID: UUID?
    public init(id: UUID = UUID(), skillID: String, number: Int, createdAt: Date = Date(), content: String,
                note: String, originRunID: UUID? = nil) {
        self.id = id; self.skillID = skillID; self.number = number; self.createdAt = createdAt
        self.content = content; self.note = note; self.originRunID = originRunID
    }
}

public enum RunRating: String, Codable, CaseIterable, Sendable {
    case unreviewed, good, needsWork
    public var label: String {
        switch self { case .unreviewed: return L("Unreviewed"); case .good: return L("Good output"); case .needsWork: return L("Needs work") }
    }
}

public struct Artifact: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String?
    public var mediaType: String
    public var byteCount: Int64?
    public init(id: UUID = UUID(), name: String, path: String? = nil, mediaType: String = "text/plain", byteCount: Int64? = nil) {
        self.id = id; self.name = name; self.path = path; self.mediaType = mediaType; self.byteCount = byteCount
    }
}

public struct SkillRun: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var skillID: String
    public var versionID: UUID?
    public var startedAt: Date
    public var durationSeconds: Double?
    public var prompt: String
    public var output: String
    public var model: String
    public var rating: RunRating
    public var feedback: String
    public var artifacts: [Artifact]
    public var isDemo: Bool
    public var capture: RunCaptureEvidence?
    public var versionAttribution: RunVersionAttribution?
    public var readEvidence: RunReadEvidence?
    /// Missing evidence in older data never implies manual confirmation or strict content matching.
    public var effectiveVersionAttribution: RunVersionAttribution {
        versionAttribution ?? (versionID == nil ? .unknown(.notSpecified) : .init(kind: .legacyUnverified))
    }
    public init(id: UUID = UUID(), skillID: String, versionID: UUID?, startedAt: Date = Date(), durationSeconds: Double? = nil,
                prompt: String, output: String, model: String = "Manual capture", rating: RunRating = .unreviewed,
                feedback: String = "", artifacts: [Artifact] = [], isDemo: Bool = false, capture: RunCaptureEvidence? = nil,
                versionAttribution: RunVersionAttribution? = nil, readEvidence: RunReadEvidence? = nil) {
        self.id = id; self.skillID = skillID; self.versionID = versionID; self.startedAt = startedAt
        self.durationSeconds = durationSeconds; self.prompt = prompt; self.output = output; self.model = model
        self.rating = rating; self.feedback = feedback; self.artifacts = artifacts; self.isDemo = isDemo; self.capture = capture
        self.versionAttribution = versionAttribution; self.readEvidence = readEvidence
    }
}

public struct LibrarySnapshot: Codable, Equatable, Sendable {
    public var skills: [Skill] = []
    public var versions: [SkillVersion] = []
    public var runs: [SkillRun] = []
    public var projectPaths: [String] = []
    public var improvements: [ImprovementRecord] = []
    public var historyPolicy = HistoryPolicy()
    public var deletedRunIDs: Set<UUID> = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case skills, versions, runs, projectPaths, improvements, historyPolicy, deletedRunIDs }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        skills = try values.decode([Skill].self, forKey: .skills)
        versions = try values.decode([SkillVersion].self, forKey: .versions)
        runs = try values.decode([SkillRun].self, forKey: .runs)
        projectPaths = try values.decode([String].self, forKey: .projectPaths)
        improvements = try values.decodeIfPresent([ImprovementRecord].self, forKey: .improvements) ?? []
        historyPolicy = try values.decodeIfPresent(HistoryPolicy.self, forKey: .historyPolicy) ?? HistoryPolicy()
        deletedRunIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .deletedRunIDs) ?? []
    }
}

public enum StudioError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let text): return L(text) } }
}

/// Last observation only; it does not guarantee the current disk or host invocation state.
public struct SourceObservation: Codable, Equatable, Sendable {
    public var checkedAt: Date
    public var externalChange: Bool
    public init(checkedAt: Date = Date(), externalChange: Bool = false) {
        self.checkedAt = checkedAt; self.externalChange = externalChange
    }
}
