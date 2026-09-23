import SwiftUI
import AppKit
import SkillStudioCore

@MainActor
private final class ApplicationLaunch: ObservableObject {
    let store: StudioStore?
    let failure: String?
    init() {
        do {
            let runtime = try RuntimeDataConfiguration.resolve()
            store = try StudioStore(runtime: runtime)
            failure = nil
        } catch {
            store = nil
            failure = (error as? RuntimeDataError)?.localizedDescription ?? RuntimeDataError.isolationChanged.localizedDescription
        }
    }
}

@main
struct AgentSkillStudioApp: App {
    @StateObject private var launch: ApplicationLaunch
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        // Inspection exits before any store, preferences, discovery, or SQLite initialization.
        if arguments.contains("--verify-installation") {
            let catalogsOK = AppLanguage.allCases.allSatisfy { !Localization.catalog(for: $0).isEmpty }
            print("Language resources: \(catalogsOK ? "OK" : "FAILED"); agent badges: native text (no image resources)")
            exit(catalogsOK ? 0 : 1)
        }
        if arguments.contains("--runtime-identity") {
            print("iterune-isolation-v1:\(RuntimeDataMode.developmentBuild ? "development" : "production")")
            exit(0)
        }
        if arguments.contains("--scan-report") || arguments.contains("--check-data-isolation") {
            do {
                let runtime = try RuntimeDataConfiguration.resolve()
                if arguments.contains("--check-data-isolation") {
                    guard runtime.isDevelopment else { throw RuntimeDataError.isolationRequired }
                    let store = try StudioStore(runtime: runtime)
                    guard store.ready, store.library.historyPolicy.enabledAgents.isEmpty,
                          store.library.skills.allSatisfy({ $0.isDemo || $0.id.hasPrefix("development:") }),
                          store.library.runs.allSatisfy({ $0.isDemo || $0.model == "Offline fixture" }),
                          store.library.skills.contains(where: { $0.sourceProvenance?.origin == .synced }),
                          store.credentials is DevelopmentCredentialStore else { throw RuntimeDataError.isolationChanged }
                    print("Development isolation: OK; fixture catalog/history only; host import, AI, credentials and Publish disabled; run sharing default OFF")
                } else if runtime.isDevelopment {
                    let store = try StudioStore(runtime: runtime)
                    guard store.ready else { throw RuntimeDataError.isolationChanged }
                    print("Development fixtures: \(store.realCount)")
                } else {
                    let report = SkillScanner().scan(context: DiscoveryContext())
                    for agent in AgentKind.allCases { print("\(agent.title): \(report.skills.filter { $0.agent == agent }.count) skills") }
                    print("Scanned \(report.roots.count) candidate roots; \(report.warnings.count) warnings")
                }
                exit(0)
            } catch {
                print((error as? RuntimeDataError)?.localizedDescription ?? RuntimeDataError.isolationChanged.localizedDescription)
                exit(1)
            }
        }
        _launch = StateObject(wrappedValue: ApplicationLaunch())
        NSApplication.shared.setActivationPolicy(.regular)
    }
    var body: some Scene {
        WindowGroup(launch.store?.isDevelopment == true ? L("Iterune — Development") : "Iterune") {
            if let store = launch.store {
                ContentView().environmentObject(store)
                    .environment(\.locale, store.language.locale)
                    .frame(minWidth: 1080, minHeight: 720)
                    .preferredColorScheme(.light)
                    .task { await store.scan(); NSApplication.shared.activate(ignoringOtherApps: true) }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Label(L("Development startup blocked"), systemImage: "lock.shield").font(.title2)
                    Text(launch.failure ?? RuntimeDataError.isolationRequired.localizedDescription)
                    Button(L("Quit")) { NSApplication.shared.terminate(nil) }
                }.padding(30).frame(width: 600)
            }
        }
        .defaultSize(width: 1370, height: 880)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("Add Project Folder…")) { launch.store?.addProject() }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button(L("Rescan Skills")) { Task { await launch.store?.scan() } }.keyboardShortcut("r")
            }
        }
        Settings {
            if let store = launch.store {
                TabView {
                    LanguageSettingsView().tabItem { Label(L("AI connection"), systemImage: "network") }
                    ReleaseSettingsView().tabItem { Label(L("Releases and updates"), systemImage: "arrow.down.circle") }
                    LibrarySettingsView().tabItem { Label(L("Library and privacy"), systemImage: "externaldrive") }
                }.environmentObject(store).environment(\.locale, store.language.locale)
            }
        }
    }
}
