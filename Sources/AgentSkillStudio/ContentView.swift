import SwiftUI
import AppKit
import SkillStudioCore

struct ContentView: View {
    @EnvironmentObject private var store: StudioStore
    @State private var showSources = false
    @AppStorage("studio.dismissedSetup") private var dismissedSetup = false
    var body: some View {
        HStack(spacing: 0) {
            rail
            sidebar
            VStack(spacing: 0) {
                if !dismissedSetup { setupBanner }
                if let skill = store.selectedSkill {
                    SkillDetailView(skill: skill).id(skill.id)
                } else {
                    EmptyState(symbol: "square.stack.3d.up", title: store.ready ? "Your skills belong here" : "Library unavailable",
                               detail: store.ready ? "Add a project folder, rescan your local skills, or switch to the demo library." : "Check the storage error and restart the app.")
                        .background(StudioTheme.background)
                }
            }
        }
        .tint(StudioTheme.accent).foregroundStyle(StudioTheme.ink)
        .onChange(of: store.selectedAgent) { _, _ in store.selectFirst() }
        .onChange(of: store.showDemo) { _, _ in store.selectFirst() }
        .onChange(of: store.search) { _, _ in store.selectFirst() }
        .alert(L("Something needs attention"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button(L("OK")) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .sheet(isPresented: $showSources) { SourcesView() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(store.ready ? Color.green : Color.orange).frame(width: 5, height: 5)
                Text(store.scanning ? L("Scanning local skill folders…") : store.notice ?? L("Local library · Your work stays on this Mac"))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")).foregroundStyle(StudioTheme.muted)
            }.font(.system(size: 10)).padding(.horizontal, 16).frame(height: 27).background(.white)
                .overlay(alignment: .top) { Rectangle().fill(StudioTheme.border).frame(height: 1) }
        }
    }
    private var setupBanner: some View {
        HStack(alignment: .center, spacing: 16) {
            Label(L("Start with local skills or the demo. Configure AI when you want to translate or improve."), systemImage: "sparkles")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                SettingsLink { Text(L("Connection settings")) }
                Button(L("Dismiss")) { dismissedSetup = true }.buttonStyle(.plain)
            }.fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 24).padding(.bottom, 14).padding(.top, 30)
        .foregroundStyle(StudioTheme.ink).background(StudioTheme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(StudioTheme.border).frame(height: 1) }
    }
    private var rail: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.stack.3d.up.fill").font(.system(size: 24)).foregroundStyle(Color.white).padding(.top, 40).padding(.bottom, 15)
            railButton(symbol: "square.grid.2x2.fill", title: "All agents", selected: store.selectedAgent == nil, color: StudioTheme.accent) { store.selectedAgent = nil }
            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 26, height: 1)
            ForEach(AgentKind.allCases) { agent in
                railButton(symbol: agent.symbol, agent: agent, title: agent.title, selected: store.selectedAgent == agent, color: StudioTheme.agent(agent)) { store.selectedAgent = agent }
            }
            Spacer()
            Button { showSources = true } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 19)).foregroundStyle(.white.opacity(0.65)).frame(width: 48, height: 48) }
                .buttonStyle(.plain).help(L("Skill sources and scan status")).accessibilityLabel(L("Skill sources"))
            Text("A").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                .frame(width: 32, height: 32).background(.white.opacity(0.12), in: Circle()).padding(.bottom, 18)
        }.frame(width: 76).background(StudioTheme.rail)
    }
    private func railButton(symbol: String, agent: AgentKind? = nil, title: String, selected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Group {
                    if let agent { AgentIconView(agent: agent, size: 37, foreground: .white) }
                    else { Image(systemName: symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(selected ? .white : color) }
                }
                    .frame(width: 45, height: 43).background(selected ? color : .white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(selected ? 0.35 : 0), lineWidth: 2))
                Text(title == "All agents" ? L("All") : title).font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(selected ? 1 : 0.55))
            }
        }.buttonStyle(.plain).help(L(title)).accessibilityLabel(L(title))
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Attune").font(.system(size: 22, weight: .bold, design: .rounded))
                    Spacer()
                    Button { Task { await store.scan() } } label: { Image(systemName: "arrow.clockwise").font(.system(size: 13)) }
                        .buttonStyle(.plain).disabled(store.scanning).help(L("Rescan skills · ⌘R")).accessibilityLabel(L("Rescan skills"))
                }
                Text(L("A workspace for better agents.")).font(.system(size: 11)).foregroundStyle(StudioTheme.muted)
            }.padding(.top, 44).padding(.horizontal, 21).padding(.bottom, 24)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(StudioTheme.muted)
                TextField(L("Find a skill…"), text: $store.search).textFieldStyle(.plain).font(.system(size: 12))
                if !store.search.isEmpty { Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }.padding(10).background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioTheme.border)).padding(.horizontal, 16)
            Picker(L("Library"), selection: $store.showDemo) {
                Text(L("Local skills")).tag(false)
                Text(L("Demo library")).tag(true)
            }.pickerStyle(.segmented).labelsHidden().padding(16)
            HStack {
                SectionCaption(text: store.selectedAgent?.title ?? "All skills")
                Spacer()
                Text("\(store.skills.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(StudioTheme.muted)
            }.padding(.horizontal, 22).padding(.bottom, 12)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(store.skills) { skill in
                        Button { store.selectedSkillID = skill.id } label: {
                            HStack(alignment: .top, spacing: 11) {
                                Image(systemName: "number").font(.system(size: 15, weight: .medium)).foregroundStyle(store.selectedSkillID == skill.id ? StudioTheme.accent : StudioTheme.muted).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(skill.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    Text(skill.summary).font(.system(size: 11)).foregroundStyle(StudioTheme.muted).lineLimit(2).multilineTextAlignment(.leading)
                                    HStack(spacing: 5) {
                                        Circle().fill(StudioTheme.agent(skill.agent)).frame(width: 5, height: 5)
                                        Text(skill.agent.title + " · " + L(skill.isAvailable ? skill.scope : "Missing source")).font(.system(size: 9)).foregroundStyle(StudioTheme.muted).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(store.selectedSkillID == skill.id ? StudioTheme.accent.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(store.selectedSkillID == skill.id ? StudioTheme.accent.opacity(0.16) : .clear))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if store.skills.isEmpty { Text(L("No matching skills")).font(.system(size: 12)).foregroundStyle(StudioTheme.muted).padding(24) }
                }.padding(.horizontal, 11)
            }
            VStack(alignment: .leading, spacing: 12) {
                Picker(selection: $store.language) {
                    ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0) }
                } label: { Label(L("App language"), systemImage: "globe") }
                    .font(.system(size: 11)).accessibilityLabel(L("App language"))
                if store.showDemo {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "play.rectangle").foregroundStyle(StudioTheme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("Explore the workflow")).font(.system(size: 11, weight: .semibold))
                            Text(L("Sample runs. Real version controls.")).font(.system(size: 10)).foregroundStyle(StudioTheme.muted)
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 9))
                }
                Button { store.addProject() } label: { Label(L("Add project folder"), systemImage: "plus").font(.system(size: 12)).frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
            }.padding(16)
        }.frame(width: 280).background(Color(red: 0.955, green: 0.955, blue: 0.97))
            .overlay(alignment: .trailing) { Rectangle().fill(StudioTheme.border).frame(width: 1) }
    }
}

struct SourcesView: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(L("Skill sources")).font(.title2.bold()); Spacer(); Button(L("Done")) { dismiss() }.keyboardShortcut(.cancelAction) }
            SettingsLink { Label(L("Language and translation"), systemImage: "globe") }
            Text(L("Discovery reads SKILL.md files. Cache entries are candidates; their presence does not mean the agent has enabled them."))
                .font(.callout).foregroundStyle(.secondary)
            HStack { Button(L("Add project folder…")) { store.addProject() }; Button(L("Rescan")) { Task { await store.scan() } }.disabled(store.scanning) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SectionCaption(text: "Projects")
                    if store.library.projectPaths.isEmpty { Text(L("No project folders added yet.")).foregroundStyle(.secondary) }
                    ForEach(store.library.projectPaths, id: \.self) { path in
                        HStack { Text(path).textSelection(.enabled); Spacer(); Button(L("Remove")) { store.removeProject(path) } }
                    }
                    Divider()
                    SectionCaption(text: "Candidate roots")
                    ForEach(store.report.roots, id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                    if !store.report.warnings.isEmpty {
                        Divider(); SectionCaption(text: "Scan warnings")
                        ForEach(Array(store.report.warnings.enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    }
                    Divider(); SectionCaption(text: "Storage")
                    Text(store.dataDirectory.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Button(L("Show library in Finder")) { NSWorkspace.shared.open(store.dataDirectory) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(26).frame(width: 690, height: 600)
    }
}
