import Foundation

public struct ImprovementRequest: Sendable {
    public let skill: Skill
    public let version: SkillVersion
    public let run: SkillRun?
    public let feedback: String
    public let selection: SelectionComment?
    public init(skill: Skill, version: SkillVersion, run: SkillRun?, feedback: String, selection: SelectionComment? = nil) {
        self.skill = skill; self.version = version; self.run = run; self.feedback = feedback; self.selection = selection
    }
}

extension ImprovementRequest {
    public init(skill: Skill, version: SkillVersion, referenceRun: SkillRun?, includeRun: Bool = false,
                feedback: String, selection: SelectionComment? = nil) {
        self.init(skill: skill, version: version, run: includeRun ? referenceRun : nil, feedback: feedback, selection: selection)
    }
}

public struct ImprovementProposal: Sendable {
    public let content: String
    public let explanation: String
    public let provider: String
    public init(content: String, explanation: String, provider: String) {
        self.content = content; self.explanation = explanation; self.provider = provider
    }
}

public protocol SkillImprovementService: Sendable {
    var displayName: String { get }
    func propose(_ request: ImprovementRequest) async throws -> ImprovementProposal
}

/// Offline demonstration. Does not call or pretend to be an LLM.
public struct LocalImprovementService: SkillImprovementService {
    public let displayName = "Local draft · no AI connected"
    public init() {}
    public func propose(_ request: ImprovementRequest) async throws -> ImprovementProposal {
        try Task.checkCancellation()
        let feedback = request.feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !feedback.isEmpty else { throw StudioError.message("Describe what you want to improve.") }
        let content = request.version.content + "\n\n## Output review checklist\n\n"
            + feedback.components(separatedBy: .newlines).filter { !$0.isEmpty }.map { "- " + $0 }.joined(separator: "\n")
            + "\n- Before delivery, verify that the output satisfies this checklist.\n"
        let context = request.run == nil ? "No run attached." : "Run context attached to the request and linked to the saved version."
        return ImprovementProposal(content: content,
            explanation: L("This offline template appends your feedback as a checklist. It does not analyze the prompt or output with AI. {0} Edit the proposal before saving.", L(context)),
            provider: displayName)
    }
}
