import SwiftUI
import AppKit
import SkillStudioCore

struct LibrarySettingsView: View {
    @EnvironmentObject var store: StudioStore
    @State private var pendingRestore: URL?
    @State private var confirmRetention = false
    private var policy: Binding<HistoryPolicy> {
        Binding(get: { store.library.historyPolicy }, set: { store.setHistoryPolicy($0) })
    }
    var body: some View {
        Form {
            if let error = store.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            Section(L("Backup and recovery")) {
                Text(L("Backups contain private skill and conversation text, but no API keys. Store them securely."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L("Export library backup…")) { store.exportLibrary() }.disabled(!store.ready)
                Button(L("Restore library backup…")) {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false
                    if panel.runModal() == .OK { pendingRestore = panel.url }
                }.disabled(!store.canRestoreLibrary)
                Button(L("Show automatic backups")) { NSWorkspace.shared.open(store.backupDirectory) }
                Text(L("Backups are made on startup and before changes, at most once per hour, retaining the latest 10. Restore saves the current library first. Source files and API keys are not restored."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("History collection")) {
                ForEach(AgentKind.allCases) { agent in
                    Toggle(agent.title, isOn: Binding(get: { policy.wrappedValue.enabledAgents.contains(agent) }, set: { value in
                        var changed = policy.wrappedValue
                        if value { changed.enabledAgents.insert(agent) } else { changed.enabledAgents.remove(agent) }
                        policy.wrappedValue = changed
                    }))
                }
                Picker(L("Imported history retention"), selection: policy.retentionDays) {
                    Text(L("Keep forever")).tag(0)
                    ForEach([14, 30, 90, 365], id: \.self) { Text(L("{0} days", String($0))).tag($0) }
                }
                Text(L("This limits future imports. Remove older imported runs explicitly with the button below; manual runs are kept.")).font(.caption).foregroundStyle(.secondary)
                Button(L("Remove expired imported runs…")) { confirmRetention = true }
                Text(L("Exclude folders from history import"))
                ForEach(store.library.historyPolicy.excludedPaths, id: \.self) { path in
                    HStack { Text(path).font(.caption); Spacer(); Button(L("Remove")) { var value = policy.wrappedValue; value.excludedPaths.removeAll { $0 == path }; policy.wrappedValue = value } }
                }
                Button(L("Exclude folder…")) {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url {
                        var value = policy.wrappedValue
                        if !value.excludedPaths.contains(url.path) { value.excludedPaths.append(url.path); policy.wrappedValue = value }
                    }
                }
                Text(L("Deleted runs will not be imported again. Existing backups and saved improvement drafts may still contain their text. Exclusions affect future imports only."))
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(!store.ready)
        }.formStyle(.grouped).padding(12).frame(width: 680, height: 640)
            .confirmationDialog(L("Replace the library with this backup?"), isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }), titleVisibility: .visible) {
                Button(L("Restore backup")) {
                    if let url = pendingRestore { do { try store.restoreLibrary(from: url) } catch { store.error = error.localizedDescription } }
                    pendingRestore = nil
                }
            } message: { Text(L("The current library will be backed up first. Skill files on disk will not change.")) }
            .confirmationDialog(L("Delete expired imported history?"), isPresented: $confirmRetention, titleVisibility: .visible) {
                Button(L("Delete"), role: .destructive) { store.applyRetention() }
            }
    }
}
