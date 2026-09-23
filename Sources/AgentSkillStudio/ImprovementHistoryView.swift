import SwiftUI
import SkillStudioCore

struct ImprovementHistoryView: View {
    @EnvironmentObject var store: StudioStore
    let skill: Skill
    @State private var resume: ImprovementRecord?
    @State private var deleting: UUID?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text(L("Instructions and proposals are saved locally. Resume a draft or inspect the model and changes behind a version."))
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(store.library.improvements.filter { $0.skillID == skill.id }.sorted { $0.updatedAt > $1.updatedAt }) { record in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(Localization.date(record.updatedAt)).font(.caption)
                            Text(L(record.status)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if record.savedVersionID == nil { Button(L("Resume draft")) { resume = record } }
                            Button(L("Delete…")) { deleting = record.id }
                        }
                        Text(L(record.provider) + (record.model.isEmpty ? "" : " · " + record.model)).font(.caption).foregroundStyle(StudioTheme.accent)
                        if let base = store.library.versions.first(where: { $0.id == record.baseVersionID }) {
                            Text(L("Editing base: v{0} — {1}", String(base.number), L("Fixed draft base"))).font(.caption)
                        }
                        Text(record.instruction).textSelection(.enabled)
                        if let selection = record.selection {
                            DisclosureGroup(L(selection.isTranslation ? "Selected translated passage" : "Selected original passage")) { Text(selection.quote).textSelection(.enabled) }
                        }
                        if let base = store.library.versions.first(where: { $0.id == record.baseVersionID }), let draft = record.draft {
                            DisclosureGroup(L("Review diff")) { DiffView(old: base.content, new: draft) }
                        }
                        if let id = record.savedVersionID, let version = store.library.versions.first(where: { $0.id == id }) {
                            Text(L("Saved as v{0}", String(version.number))).font(.caption)
                        }
                    }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 10))
                }
            }.padding(26)
        }
        .sheet(item: $resume) { record in
            if let base = store.library.versions.first(where: { $0.id == record.baseVersionID }) {
                ImproveSkillView(skill: skill, version: base, run: store.library.runs.first { $0.id == record.sourceRunID }, selection: record.selection, resumeRecord: record)
            }
        }
        .confirmationDialog(L("Delete this saved improvement?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(L("Delete"), role: .destructive) { if let deleting { store.deleteImprovement(deleting) }; deleting = nil }
        } message: { Text(L("Saved skill versions remain available.")) }
    }
}
