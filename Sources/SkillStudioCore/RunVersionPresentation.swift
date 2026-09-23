import Foundation

public enum RunVersionPresentation {
    public static func label(_ run: SkillRun, versions: [SkillVersion]) -> String {
        let value = run.effectiveVersionAttribution
        let version = versions.first { $0.id == run.versionID && $0.skillID == run.skillID }
        switch value.kind {
        case .matchingContent:
            if let version { return L("Matching saved text: v{0}", String(version.number)) }
            return L("Matching saved text: multiple revisions")
        case .manualAssociation:
            if let version { return L("User association: v{0}", String(version.number)) }
        case .legacyUnverified:
            if let version { return L("Legacy association: v{0} (unverified)", String(version.number)) }
        case .unknown: break
        }
        return L("Version unknown: {0}", reason(value.reason ?? .notSpecified))
    }
    public static func reason(_ value: RunVersionUnknownReason) -> String {
        switch value {
        case .incompleteRead: return L("Incomplete or truncated read")
        case .unsupportedReadFormat: return L("Read format cannot establish a complete body")
        case .noMatchingVersion: return L("No saved version matches the complete body")
        case .ambiguousMatchingVersions: return L("The same text belongs to multiple revisions")
        case .conflictingReadEvidence: return L("Different complete bodies were read in this turn")
        case .notSpecified: return L("No verified version association")
        }
    }
    public static func explanation(_ run: SkillRun, versions: [SkillVersion]) -> String {
        switch run.effectiveVersionAttribution.kind {
        case .matchingContent:
            let ids = Set(run.effectiveVersionAttribution.candidateVersionIDs)
            let candidates = versions.filter { $0.skillID == run.skillID && ids.contains($0.id) }.sorted { $0.number < $1.number }.map { "v\($0.number)" }.joined(separator: ", ")
            return L("Complete read text matches {0}. This does not identify the revision used at execution time or prove skill invocation or adherence.", candidates)
        case .manualAssociation: return L("This version was selected by a user, not observed during execution.")
        case .legacyUnverified: return L("The original association is retained. Older imports did not verify complete read text.")
        case .unknown: return reason(run.effectiveVersionAttribution.reason ?? .notSpecified)
        }
    }
    public static func requiresReferenceAcknowledgement(run: SkillRun?, base: SkillVersion) -> Bool {
        guard let run else { return false }
        let kind = run.effectiveVersionAttribution.kind
        return run.skillID != base.skillID || run.versionID != base.id || ![.matchingContent, .manualAssociation].contains(kind)
    }
}
