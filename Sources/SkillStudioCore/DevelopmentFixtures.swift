import Foundation

/// Synthetic catalog only. It never discovers a user's host roots or imports history.
public enum DevelopmentFixtures {
    public static func seed(into snapshot: inout LibrarySnapshot, runtime: RuntimeDataConfiguration) throws {
        guard runtime.isDevelopment else { throw RuntimeDataError.unsafeRoot }
        try runtime.validate()
        guard snapshot.skills.isEmpty else { return }
        snapshot.historyPolicy.enabledAgents = []
        let entries: [(String, SourceOrigin, String)] = [
            ("development-example", .localUser, ".claude/skills/development-example/SKILL.md"),
            ("protected-example", .synced, ".claude/skills/synced/protected-example/SKILL.md")
        ]
        for (name, origin, relative) in entries {
            let url = runtime.fixtureHome.appendingPathComponent(relative)
            let text = "# \(name)\n\nUse clear examples and acceptance criteria.\n"
            // A fresh marked directory owns these fixtures; never overwrite a pre-existing file.
            try runtime.validateDatabase(url)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try runtime.validateDatabase(url)
            guard !FileManager.default.fileExists(atPath: url.path) else { throw RuntimeDataError.isolationChanged }
            try Data(text.utf8).write(to: url, options: .withoutOverwriting)
            let id = "development:\(name)"
            let version = SkillVersion(skillID: id, number: 1, content: text, note: "Synthetic development fixture")
            var skill = Skill(id: id, agent: .claude, name: name, summary: "Synthetic development fixture", sourcePath: url.path,
                              scope: "Development fixtures", lastDiskContent: text, activeVersionID: version.id)
            skill.sourceProvenance = SourceProvenance(origin: origin)
            skill.sourceObservation = .init(externalChange: false)
            snapshot.skills.append(skill); snapshot.versions.append(version)
            snapshot.runs.append(SkillRun(skillID: id, versionID: version.id, prompt: "Explain a synthetic change.",
                output: "A synthetic answer to review.", model: "Offline fixture", rating: .needsWork,
                feedback: "Add a concrete example.", versionAttribution: .init(kind: .manualAssociation)))
        }
        DemoLibrary.seed(into: &snapshot)
        try LibraryBackup.validate(snapshot)
    }
}

public struct DevelopmentCredentialStore: CredentialStore {
    public init() {}
    public func read(for provider: AIConnectionKind) throws -> String? { nil }
    public func save(_ value: String, for provider: AIConnectionKind) throws { throw RuntimeDataError.externalServicesDisabled }
    public func remove(for provider: AIConnectionKind) throws { throw RuntimeDataError.externalServicesDisabled }
}
