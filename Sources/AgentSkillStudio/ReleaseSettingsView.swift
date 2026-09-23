import SwiftUI
import SkillStudioCore

struct ReleaseSettingsView: View {
    @State private var status: String?
    @State private var update: URL?
    @State private var checking = false
    @State private var task: Task<Void, Never>?
    var body: some View {
        Form {
            Section(L("Releases and updates")) {
                LabeledContent(L("Installed version"), value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                Link(L("Open GitHub Releases"), destination: ReleaseUpdates.releasesURL)
                Text(L("While the repository is private, sign in to GitHub in your browser with an account that has access. Public update checks do not use your GitHub credentials."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L("Check for public updates")) { check() }.disabled(checking)
                if checking { HStack { ProgressView().controlSize(.small); Button(L("Cancel")) { task?.cancel(); checking = false } } }
                if let status { Text(status).font(.callout).textSelection(.enabled) }
                if let update { Link(L("View new release"), destination: update) }
                Text(L("Checks run only when requested and send no library data. Updates are downloaded and installed manually."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("About agent badges")) {
                Text(L("Agent names and original text badges identify products without bundled vendor logos. Trademarks belong to their respective owners; no endorsement is implied."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding(12).frame(width: 680, height: 640)
            .onDisappear { task?.cancel(); checking = false }
    }
    private func check() {
        checking = true; status = nil; update = nil
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        task = Task {
            defer { if !Task.isCancelled { checking = false } }
            do {
                let result = try await ReleaseUpdates.check(currentVersion: version)
                try Task.checkCancellation()
                switch result {
                case .current(let tag): status = L("No newer public release found. Latest: {0}", tag)
                case .available(let tag, let url): status = L("New release available: {0}", tag); update = url
                case .unavailable: status = L("No public release is available, or the repository is private. Check GitHub Releases in your browser.")
                }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { status = error.localizedDescription } }
        }
    }
}
