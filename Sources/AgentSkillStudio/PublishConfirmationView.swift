import SwiftUI
import SkillStudioCore

struct PublishConfirmationView: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    let request: PublishRequest
    @State private var reviewed = false
    @State private var submitted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Review source publishing")).font(.title2).bold()
            Text(L("Publish library version v{0}", String(request.versionNumber))).font(.headline)
            Text(request.targetPath).font(.caption.monospaced()).textSelection(.enabled)
            Text(L("The existing file will be backed up locally before replacement."))
            Text(L("This confirmation is fixed to the displayed version and source bytes. Changes require a new confirmation."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L("Source: {0} bytes → Library: {1} bytes", String(request.expectedSource.utf8.count), String(request.content.utf8.count)))
                .font(.caption.monospaced())
            ScrollView { DiffView(old: request.expectedSource, new: request.content) }
            Toggle(L("I reviewed this source-to-library diff and want to replace the source file."), isOn: $reviewed)
            HStack {
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Publish to source")) {
                    submitted = true
                    store.publish(request)
                    dismiss()
                }.buttonStyle(.borderedProminent)
                    .disabled(!reviewed || submitted || store.scanning || store.publishingPaths.contains(request.targetPath) || store.sourceNeedsRecheck.contains(request.targetPath))
            }
        }.padding(24).frame(width: 760, height: 650)
    }
}
