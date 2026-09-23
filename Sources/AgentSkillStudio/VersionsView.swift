import SwiftUI
import SkillStudioCore

struct VersionsView: View {
    @EnvironmentObject var store: StudioStore
    let skill: Skill
    @State private var fromID: UUID?
    @State private var toID: UUID?
    @State private var restoring: SkillVersion?
    private var versions: [SkillVersion] { store.versions(for: skill) }
    private var from: SkillVersion? { versions.first { $0.id == fromID } ?? versions.dropFirst().first ?? versions.first }
    private var to: SkillVersion? { versions.first { $0.id == toID } ?? versions.first }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Make progress. Keep the history.")).font(.system(size: 17, weight: .semibold))
                        Text(L("Restore any version as a new revision. Publish separately to update the agent’s file."))
                            .font(.system(size: 11)).foregroundStyle(StudioTheme.muted)
                    }
                    Spacer()
                }
                ForEach(versions) { version in
                    HStack(alignment: .top, spacing: 14) {
                        Text("v\(version.number)").font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundStyle(StudioTheme.accent)
                            .frame(width: 46, height: 40).background(StudioTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text(Localization.versionNote(version.note)).font(.system(size: 12, weight: .medium)); if version.id == skill.activeVersionID { Tag(text: "Library editing version", color: .green) } }
                            if SourceStatePresentation.matchingObservedVersions(skill, versions: versions).contains(where: { $0.id == version.id }) {
                                Text(L("Matches last observed source text")).font(.system(size: 10)).foregroundStyle(StudioTheme.muted)
                            }
                            if skill.lastPublishedVersionID == version.id {
                                Text(L("Last published by Studio (not a current disk guarantee)")).font(.system(size: 10)).foregroundStyle(StudioTheme.muted)
                            }
                            Text(Localization.date(version.createdAt)).font(.system(size: 10)).foregroundStyle(StudioTheme.muted)
                            if version.originRunID != nil { Label(L("Linked to run feedback"), systemImage: "link").font(.system(size: 10)).foregroundStyle(StudioTheme.muted) }
                        }
                        Spacer()
                        Button(L("Compare")) { toID = version.id; fromID = versions.first { $0.number == version.number - 1 }?.id ?? version.id }.font(.system(size: 11))
                        if version.id != skill.activeVersionID { Button(L("Restore…")) { restoring = version }.font(.system(size: 11)) }
                    }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 10))
                }
                if !skill.isDemo, let active = store.activeVersion(for: skill) {
                    SectionCaption(text: "Last observed source → library editing version")
                    Text(SourceStatePresentation.observedLabel(skill, versions: versions)).font(.caption).foregroundStyle(StudioTheme.muted)
                    DiffView(old: skill.lastDiskContent, new: active.content)
                }
                HStack(spacing: 12) {
                    SectionCaption(text: "Version diff")
                    Spacer()
                    Picker(L("From"), selection: Binding(get: { from?.id }, set: { fromID = $0 })) {
                        ForEach(versions) { Text("v\($0.number)").tag(Optional($0.id)) }
                    }.frame(width: 135)
                    Image(systemName: "arrow.right").foregroundStyle(StudioTheme.muted)
                    Picker(L("To"), selection: Binding(get: { to?.id }, set: { toID = $0 })) {
                        ForEach(versions) { Text("v\($0.number)").tag(Optional($0.id)) }
                    }.frame(width: 120)
                }
                if let from, let to { DiffView(old: from.content, new: to.content) }
            }.padding(26)
        }
        .confirmationDialog(L("Restore v{0}?", String(restoring?.number ?? 0)), isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }), titleVisibility: .visible) {
            Button(L("Restore as new version")) { if let restoring { store.rollback(restoring) }; restoring = nil; toID = nil }
        } message: { Text(L("Your current version remains in history. The source file changes only when you publish.")) }
    }
}

struct DiffView: View {
    @Environment(\.locale) private var locale
    let old: String
    let new: String
    var body: some View {
        let lines = LineDiff.compare(old: old, new: new)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text"); Text("SKILL.md").fontWeight(.medium)
                Spacer()
                Text("+\(lines.filter { $0.kind == .added }.count)").foregroundStyle(.green)
                Text("−\(lines.filter { $0.kind == .removed }.count)").foregroundStyle(.red)
            }.font(.system(size: 11, design: .monospaced)).padding(14).background(StudioTheme.background)
            if Data(old.utf8) == Data(new.utf8) {
                Text(Localization.text("No changes between these versions.", language: AppLanguage.resolve(saved: locale.identifier, preferredLanguages: [locale.identifier])))
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.muted).padding(20)
            }
            ScrollView(.horizontal) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(alignment: .top, spacing: 9) {
                            Text(line.oldNumber.map(String.init) ?? "").frame(width: 28, alignment: .trailing).foregroundStyle(StudioTheme.muted)
                            Text(line.newNumber.map(String.init) ?? "").frame(width: 28, alignment: .trailing).foregroundStyle(StudioTheme.muted)
                            Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ").frame(width: 12)
                            Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 16)
                        }.font(.system(size: 11, design: .monospaced)).padding(.vertical, 4).padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(line.kind == .added ? Color.green.opacity(0.08) : line.kind == .removed ? Color.red.opacity(0.08) : .clear)
                    }
                }.padding(.vertical, 8)
            }
        }.background(.white, in: RoundedRectangle(cornerRadius: 10)).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioTheme.border))
    }
}
