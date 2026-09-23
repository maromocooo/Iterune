import Foundation

public enum DemoLibrary {
    public static func seed(into snapshot: inout LibrarySnapshot) {
        for agent in AgentKind.allCases {
            for (index, entry) in [
                ("release-notes", "Turn shipped work into clear, useful release notes."),
                ("design-review", "Review product interfaces for clarity and consistency."),
                ("research-brief", "Transform source material into a focused research brief.")
            ].enumerated() {
                let id = "demo:\(agent.rawValue):\(entry.0)"
                guard !snapshot.skills.contains(where: { $0.id == id }) else { continue }
                let content = "---\nname: \(entry.0)\ndescription: \(entry.1)\n---\n\n# \(entry.0.replacingOccurrences(of: "-", with: " ").capitalized)\n\n## Workflow\n\n1. Read the user’s request and the supplied source material.\n2. Identify the audience and the most important outcome.\n3. Write a concise draft with concrete examples.\n4. Check facts against the supplied sources.\n\n## Deliverable\n\nLead with the outcome. Use short paragraphs and specific language.\n"
                let first = SkillVersion(skillID: id, number: 1, createdAt: Date().addingTimeInterval(-172800), content: content, note: "Initial skill · demo")
                let second = SkillVersion(skillID: id, number: 2, createdAt: Date().addingTimeInterval(-86400),
                    content: content + "\n## Quality checks\n\n- Group changes by user benefit.\n- Include a clear next step.\n- Omit internal implementation details.\n", note: "Make the output more useful · demo")
                snapshot.versions += [first, second]
                snapshot.skills.append(Skill(id: id, agent: agent, name: entry.0, summary: entry.1, sourcePath: nil,
                    scope: "Demo workspace", isDemo: true, lastDiskContent: "", activeVersionID: second.id))
                if index == 0 {
                    snapshot.runs += [
                        SkillRun(skillID: id, versionID: second.id, startedAt: Date().addingTimeInterval(-3600), durationSeconds: 18.4,
                            prompt: "Write release notes for Studio 0.2. We added skill version history, a side-by-side review workflow, and local backups. Keep it useful for people who use agents every day.",
                            output: "# A little more confidence in every skill\n\nStudio 0.2 makes it easier to improve your skills without losing what worked.\n\n## See what changed\nEvery revision now has a place in your skill’s history. Review the changes and keep the version that works best.\n\n## Experiment, then decide\nReview a proposed improvement before applying it. Your original skill stays available in a local backup.\n\nOpen a skill and explore its Versions tab to get started.",
                            model: "Demo agent", rating: .good, artifacts: [Artifact(name: "release-notes.md", mediaType: "text/markdown", byteCount: 481)], isDemo: true),
                        SkillRun(skillID: id, versionID: first.id, startedAt: Date().addingTimeInterval(-100000), durationSeconds: 12.7,
                            prompt: "Summarize the Studio 0.2 changes for our users.",
                            output: "Changelog: added version records, diff rendering, and file backup logic. Updated the persistence layer and view models.",
                            model: "Demo agent", rating: .needsWork, feedback: "Focus on user benefits. Avoid internal implementation details. End with a clear next step.", isDemo: true)
                    ]
                }
            }
        }
    }
}
