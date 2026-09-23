import Foundation

public enum SourceStatePresentation {
    public static func origin(_ origin: SourceOrigin) -> String {
        switch origin {
        case .localUser: return L("User-managed local source")
        case .localProject: return L("Project-managed local source")
        case .localShared: return L("Shared local source")
        case .pluginCache: return L("Plugin cache")
        case .synced: return L("Synced source")
        case .managed: return L("Administrator-managed source")
        case .bundled: return L("Bundled source")
        case .extensionCache: return L("Extension cache")
        case .unknown: return L("Unverified source origin")
        }
    }
    public static func differsFromObserved(_ skill: Skill, versions: [SkillVersion]) -> Bool {
        guard let active = versions.first(where: { $0.id == skill.activeVersionID && $0.skillID == skill.id }) else { return false }
        return Data(active.content.utf8) != Data(skill.lastDiskContent.utf8)
    }
    public static func matchingObservedVersions(_ skill: Skill, versions: [SkillVersion]) -> [SkillVersion] {
        guard skill.sourceObservation != nil else { return [] }
        return versions.filter { $0.skillID == skill.id && Data($0.content.utf8) == Data(skill.lastDiskContent.utf8) }.sorted { $0.number < $1.number }
    }
    public static func observedLabel(_ skill: Skill, versions: [SkillVersion]) -> String {
        guard let observation = skill.sourceObservation else { return L("Source needs a fresh check.") }
        let matches = matchingObservedVersions(skill, versions: versions).map { "v\($0.number)" }.joined(separator: ", ")
        return L("Last checked {0} · text matches {1}", Localization.date(observation.checkedAt), matches.isEmpty ? L("No saved version") : matches)
    }
}
