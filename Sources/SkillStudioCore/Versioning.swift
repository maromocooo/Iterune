import Foundation

public enum Versioning {
    @discardableResult
    public static func append(to snapshot: inout LibrarySnapshot, skillID: String, content: String, note: String,
                              runID: UUID? = nil, expectedVersionID: UUID? = nil) throws -> SkillVersion {
        guard let index = snapshot.skills.firstIndex(where: { $0.id == skillID }) else { throw StudioError.message("Skill no longer exists.") }
        if let expectedVersionID, snapshot.skills[index].activeVersionID != expectedVersionID {
            throw StudioError.message("The active version changed. Close this draft and review the latest version.")
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StudioError.message("A skill cannot be empty.") }
        let next = (snapshot.versions.filter { $0.skillID == skillID }.map(\.number).max() ?? 0) + 1
        let version = SkillVersion(skillID: skillID, number: next, content: content, note: note, originRunID: runID)
        snapshot.versions.append(version)
        snapshot.skills[index].activeVersionID = version.id
        let metadata = SkillMetadata.parse(content, fallback: snapshot.skills[index].name)
        snapshot.skills[index].name = metadata.name
        snapshot.skills[index].summary = metadata.summary
        return version
    }
    @discardableResult
    public static func rollback(_ versionID: UUID, in snapshot: inout LibrarySnapshot) throws -> SkillVersion {
        guard let original = snapshot.versions.first(where: { $0.id == versionID }) else { throw StudioError.message("Version not found.") }
        return try append(to: &snapshot, skillID: original.skillID, content: original.content, note: "Restored from v\(original.number)")
    }
    public static func merge(_ report: ScanReport, into snapshot: inout LibrarySnapshot) throws {
        let found = Set(report.skills.map(\.id))
        for i in snapshot.skills.indices where !snapshot.skills[i].isDemo { snapshot.skills[i].isAvailable = found.contains(snapshot.skills[i].id) }
        for discovered in report.skills {
            if let i = snapshot.skills.firstIndex(where: { $0.id == discovered.id }) {
                let previous = snapshot.skills[i]
                let active = snapshot.versions.first { $0.id == previous.activeVersionID && $0.skillID == previous.id }
                let hasLocalEdits = active.map { Data($0.content.utf8) != Data(previous.lastDiskContent.utf8) } ?? true
                let changed = Data(previous.lastDiskContent.utf8) != Data(discovered.content.utf8)
                if changed {
                    let observed = snapshot.versions.first { $0.skillID == discovered.id && Data($0.content.utf8) == Data(discovered.content.utf8) }
                    if let observed {
                        if !hasLocalEdits { snapshot.skills[i].activeVersionID = observed.id }
                    } else {
                        try append(to: &snapshot, skillID: discovered.id, content: discovered.content, note: "Change detected on disk")
                    }
                    if hasLocalEdits {
                        snapshot.skills[i].activeVersionID = previous.activeVersionID
                        snapshot.skills[i].name = previous.name
                        snapshot.skills[i].summary = previous.summary
                    } else {
                        snapshot.skills[i].name = discovered.metadata.name
                        snapshot.skills[i].summary = discovered.metadata.summary
                    }
                    snapshot.skills[i].lastDiskContent = discovered.content
                }
                snapshot.skills[i].sourceProvenance = discovered.provenance
                snapshot.skills[i].sourceObservation = SourceObservation(externalChange: changed || (hasLocalEdits && previous.sourceObservation?.externalChange == true))
                snapshot.skills[i].isAvailable = true
            } else {
                let version = SkillVersion(skillID: discovered.id, number: 1, content: discovered.content, note: "Imported from disk")
                snapshot.versions.append(version)
                snapshot.skills.append(Skill(id: discovered.id, agent: discovered.agent, name: discovered.metadata.name,
                                             summary: discovered.metadata.summary, sourcePath: discovered.path, scope: discovered.scope,
                                             lastDiskContent: discovered.content, activeVersionID: version.id))
                snapshot.skills[snapshot.skills.count - 1].sourceProvenance = discovered.provenance
                snapshot.skills[snapshot.skills.count - 1].sourceObservation = SourceObservation()
            }
        }
    }
}

public struct DiffLine: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case context, added, removed }
    public let id: Int
    public let kind: Kind
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?
}

public enum LineDiff {
    public static func compare(old: String, new: String) -> [DiffLine] {
        let before = old.components(separatedBy: "\n"), after = new.components(separatedBy: "\n")
        // Bound worst-case cost for large or unrelated documents.
        if before.count * after.count > 4_000_000 {
            return before.enumerated().map { DiffLine(id: $0.offset, kind: .removed, text: $0.element, oldNumber: $0.offset + 1, newNumber: nil) }
                + after.enumerated().map { DiffLine(id: before.count + $0.offset, kind: .added, text: $0.element, oldNumber: nil, newNumber: $0.offset + 1) }
        }
        let changes = after.difference(from: before, by: { Data($0.utf8) == Data($1.utf8) })
        var removed = Set<Int>(), added = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        var result: [DiffLine] = [], i = 0, j = 0
        while i < before.count || j < after.count {
            if i < before.count, removed.contains(i) {
                result.append(DiffLine(id: result.count, kind: .removed, text: before[i], oldNumber: i + 1, newNumber: nil)); i += 1
            } else if j < after.count, added.contains(j) {
                result.append(DiffLine(id: result.count, kind: .added, text: after[j], oldNumber: nil, newNumber: j + 1)); j += 1
            } else if i < before.count, j < after.count {
                result.append(DiffLine(id: result.count, kind: .context, text: before[i], oldNumber: i + 1, newNumber: j + 1)); i += 1; j += 1
            } else { break }
        }
        return result
    }
}
