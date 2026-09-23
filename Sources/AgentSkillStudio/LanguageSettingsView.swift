import SwiftUI
import AppKit
import SkillStudioCore

struct LanguageSettingsView: View {
    @EnvironmentObject var store: StudioStore
    @State private var diagnostics: [ConnectionDiagnostic] = []
    @State private var apiKey = ""
    @State private var hasSavedKey = false
    @State private var status: String?
    @State private var error: String?
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?
    var body: some View {
        Form {
            Section {
                Picker(L("App language"), selection: $store.language) {
                    ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0) }
                }
            }
            Section(L("AI connection")) {
                Picker(L("Connection method"), selection: $store.connection.provider) {
                    ForEach(AIConnectionKind.allCases) { Text($0.title).tag($0) }
                }
                if store.connection.provider.isCLI {
                    Text(L("Uses the CLI's existing login. Update and sign in to the CLI before translating."))
                        .font(.callout).foregroundStyle(.secondary)
                    TextField(L("CLI executable"), text: $store.connection.executablePath, prompt: Text(L("Automatic detection")))
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button(L("Choose executable…")) {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url { store.connection.executablePath = url.path }
                        }
                        if !store.connection.executablePath.isEmpty { Button(L("Automatic detection")) { store.connection.executablePath = "" } }
                    }
                    Text(CodexExecutable.resolve(override: store.connection.executablePath, name: store.connection.provider.executableName)?.path ?? L("Not found"))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    SecureField(L("API key"), text: $apiKey).textFieldStyle(.roundedBorder)
                    HStack {
                        Button(L("Save key")) {
                            do {
                                try store.credentials.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: store.connection.provider)
                                apiKey = ""; hasSavedKey = true; status = L("API key saved in Keychain."); error = nil
                                store.translationSession.reset(clearCache: true)
                            } catch { self.error = error.localizedDescription }
                        }.disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if hasSavedKey {
                            Label(L("Saved in Keychain"), systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(L("Remove key")) {
                                do {
                                    try store.credentials.remove(for: store.connection.provider)
                                    hasSavedKey = false; apiKey = ""; status = nil; error = nil
                                    store.translationSession.reset(clearCache: true)
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
                TextField(L("Model ID"), text: $store.connection.model, prompt: Text(store.connection.provider.isCLI ? L("CLI default") : store.connection.provider.defaultModel))
                    .textFieldStyle(.roundedBorder)
                Text(L("Used for SKILL.md translation. Local skill discovery does not require an AI connection."))
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: $store.connection.maxConcurrentTranslations, in: 1...ChunkedTranslationService.maximumConcurrency) {
                    Text(L("Parallel translations: {0}", String(store.connection.maxConcurrentTranslations)))
                }
                Text(L("Up to 18 sections can run at once. Reduce this number if your provider rejects concurrent requests."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L("Diagnose setup")) { diagnose() }.disabled(testing)
                    Button(L("Test connection")) { testConnection() }.disabled(testing)
                    if testing { ProgressView().controlSize(.small); Button(L("Cancel")) { cancelTest() } }
                }
                Text(L("The test sends a short sample text only. Translation and connection tests may consume your AI usage allowance."))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(diagnostics) { item in
                    Label(item.message, systemImage: item.passed ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(item.passed ? Color.secondary : .orange)
                }
                if let status { Label(status, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green) }
                if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            }
        }.formStyle(.grouped).padding(12).frame(width: 640, height: 650)
            .navigationTitle(L("Language and translation"))
            .onAppear { refreshKeyStatus() }
            .onChange(of: store.connection) { old, new in
                cancelTest(); status = nil; error = nil; diagnostics = []
                if old.provider != new.provider { apiKey = ""; refreshKeyStatus() }
            }
            .onDisappear { cancelTest(); apiKey = "" }
    }
    private func refreshKeyStatus() {
        hasSavedKey = false
        guard !store.connection.provider.isCLI else { return }
        do { hasSavedKey = try store.credentials.read(for: store.connection.provider) != nil }
        catch { self.error = error.localizedDescription }
    }
    private func cancelTest() { testTask?.cancel(); testTask = nil; testing = false }
    private func diagnose() {
        status = nil; error = nil; diagnostics = []; testing = true
        let settings = store.connection
        testTask = Task {
            defer { if !Task.isCancelled { testing = false } }
            do {
                let hasKey = settings.provider.isCLI ? false : try store.credentials.read(for: settings.provider) != nil
                let report = try await ConnectionDiagnostics.inspect(settings, hasAPIKey: hasKey)
                try Task.checkCancellation(); diagnostics = report
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func testConnection() {
        status = nil; error = nil
        do {
            let service = try store.translationService()
            let request = SkillTranslationRequest(content: "# Greeting\n\nHello, welcome to Iterune.\n", language: store.language)
            testing = true
            testTask = Task {
                do {
                    _ = try await service.translate(request)
                    try Task.checkCancellation()
                    status = L("Connection successful."); testing = false
                } catch is CancellationError { }
                catch { if !Task.isCancelled { self.error = error.localizedDescription; testing = false } }
            }
        } catch { self.error = error.localizedDescription }
    }
}
