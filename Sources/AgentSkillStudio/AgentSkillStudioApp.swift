import SwiftUI
import AppKit
import SkillStudioCore

@main
struct AgentSkillStudioApp: App {
    @StateObject private var store: StudioStore
    init() {
        if ProcessInfo.processInfo.arguments.contains("--verify-installation") {
            let catalogsOK = AppLanguage.allCases.allSatisfy { !Localization.catalog(for: $0).isEmpty }
            print("Language resources: \(catalogsOK ? "OK" : "FAILED"); agent badges: native text (no image resources)")
            exit(catalogsOK ? 0 : 1)
        }
        if ProcessInfo.processInfo.arguments.contains("--scan-report") {
            let report = SkillScanner().scan(context: DiscoveryContext())
            for agent in AgentKind.allCases { print("\(agent.title): \(report.skills.filter { $0.agent == agent }.count) skills") }
            print("Scanned \(report.roots.count) candidate roots; \(report.warnings.count) warnings")
            for warning in report.warnings { print(warning) }
            exit(0)
        }
        _store = StateObject(wrappedValue: StudioStore())
        NSApplication.shared.setActivationPolicy(.regular)
    }
    var body: some Scene {
        WindowGroup("Iterune") {
            ContentView().environmentObject(store)
                .environment(\.locale, store.language.locale)
                .frame(minWidth: 1080, minHeight: 720)
                .preferredColorScheme(.light)
                .task { await store.scan(); NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1370, height: 880)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("Add Project Folder…")) { store.addProject() }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button(L("Rescan Skills")) { Task { await store.scan() } }.keyboardShortcut("r")
            }
        }
        Settings {
            TabView {
                LanguageSettingsView().tabItem { Label(L("AI connection"), systemImage: "network") }
                ReleaseSettingsView().tabItem { Label(L("Releases and updates"), systemImage: "arrow.down.circle") }
                LibrarySettingsView().tabItem { Label(L("Library and privacy"), systemImage: "externaldrive") }
            }.environmentObject(store).environment(\.locale, store.language.locale)
        }
    }
}
