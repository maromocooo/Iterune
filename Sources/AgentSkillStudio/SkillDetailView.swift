import SwiftUI
import AppKit
import SkillStudioCore

private enum DetailTab: String, CaseIterable { case runs = "Run history", markdown = "SKILL.md", versions = "Versions", improvements = "Improvements" }

struct SkillDetailView: View {
    @EnvironmentObject var store: StudioStore
    let skill: Skill
    @State private var tab: DetailTab = .runs
    @State private var selectedRunID: UUID?
    @State private var improvement: ImprovementSheetContext?
    @State private var recording = false
    @State private var publishRequest: PublishRequest?
    @State private var sourceEligibility: PublishEligibility = .unavailable(.unknownOrigin)
    @State private var historySearch = ""
    @State private var ratingFilter: RunRating?
    @State private var deletingRun: UUID?
    private var runs: [SkillRun] {
        store.runs(for: skill).filter { run in
            (ratingFilter == nil || run.rating == ratingFilter) &&
            (historySearch.isEmpty || (run.prompt + " " + run.output + " " + run.feedback + " " + run.model).localizedCaseInsensitiveContains(historySearch))
        }
    }
    private var selectedRun: SkillRun? { runs.first { $0.id == selectedRunID } ?? runs.first }
    private var active: SkillVersion? { store.activeVersion(for: skill) }
    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 27) {
                ForEach(DetailTab.allCases, id: \.self) { item in
                    Button { tab = item } label: {
                        HStack(spacing: 7) {
                            Text(L(item.rawValue))
                            if item == .runs { Text("\(runs.count)").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2).background(StudioTheme.border, in: Capsule()) }
                        }.font(.system(size: 12, weight: tab == item ? .semibold : .regular))
                            .foregroundStyle(tab == item ? StudioTheme.accent : StudioTheme.muted)
                            .frame(height: 44)
                            .overlay(alignment: .bottom) { Rectangle().fill(tab == item ? StudioTheme.accent : .clear).frame(height: 2) }
                    }.buttonStyle(.plain)
                }
                Spacer()
                if skill.isDemo { Tag(text: "DEMO", color: StudioTheme.accent) }
            }.padding(.horizontal, 30).background(.white)
            Divider()
            Group {
                switch tab {
                case .runs: runHistory
                case .markdown:
                    if let active { MarkdownView(content: active.content, sourcePath: skill.sourcePath, session: store.translationSession) { selection, feedback in
                        improvement = ImprovementSheetContext(version: active, run: nil, selection: selection, feedback: feedback)
                    }.id(active.id) }
                case .versions: VersionsView(skill: skill)
                case .improvements: ImprovementHistoryView(skill: skill)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(StudioTheme.background)
        }
        .task(id: skill.id) {
            guard !skill.isDemo else { return }
            while !Task.isCancelled {
                await store.importHistory(for: skill)
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            }
        }
        .sheet(item: $improvement) { context in
            ImproveSkillView(skill: skill, version: context.version, run: context.run, selection: context.selection, initialFeedback: context.feedback)
        }
        .sheet(isPresented: $recording) { RecordRunView(skill: skill) }
        .confirmationDialog(L("Delete this run?"), isPresented: Binding(get: { deletingRun != nil }, set: { if !$0 { deletingRun = nil } }), titleVisibility: .visible) {
            Button(L("Delete"), role: .destructive) { if let deletingRun { store.deleteRun(deletingRun) }; deletingRun = nil }
        } message: { Text(L("The source transcript is kept. This run will not be imported again.")) }
        .sheet(item: $publishRequest) { request in PublishConfirmationView(request: request) }
        .task(id: skill) {
            let value = await store.checkSourceEligibility(skill)
            guard !Task.isCancelled else { return }
            sourceEligibility = value
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack(spacing: 7) {
                AgentIconView(agent: skill.agent, size: 19)
                Text(skill.agent.title).fontWeight(.medium)
                Image(systemName: "chevron.right").font(.system(size: 8))
                Text(L(skill.scope)).lineLimit(1)
                Spacer()
                Image(systemName: "internaldrive"); Text(L("LOCAL FIRST")).font(.system(size: 9, weight: .semibold)).tracking(1)
            }.font(.system(size: 11)).foregroundStyle(StudioTheme.muted)
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "number").font(.system(size: 25, weight: .medium)).foregroundStyle(StudioTheme.accent)
                    .frame(width: 52, height: 52).background(StudioTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text(skill.name).font(.system(size: 25, weight: .bold, design: .rounded)).lineLimit(1); Tag(text: "v\(active?.number ?? 1)", color: StudioTheme.accent) }
                    Text(skill.summary).font(.system(size: 12)).foregroundStyle(StudioTheme.muted).lineLimit(2)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 7) {
                    Text(store.improvementPreferences.provider.title + " · " +
                         (ImprovementPreferences.normalizedModel(store.improvementPreferences.model) ?? L("No model selected")))
                        .font(.system(size: 10)).foregroundStyle(StudioTheme.muted).lineLimit(2)
                        .frame(maxWidth: 240, alignment: .trailing).textSelection(.enabled)
                    Button { if let active { improvement = ImprovementSheetContext(version: active, run: selectedRun) } } label: { Label(L("Improve Skill"), systemImage: "sparkles").font(.system(size: 12, weight: .semibold)).padding(.vertical, 5) }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(active == nil)
                }
            }
            if !skill.isDemo { sourceStatus }

        }.padding(.horizontal, 30).padding(.top, 42).padding(.bottom, 20).background(.white)
    }
    private var sourceStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(SourceStatePresentation.origin(skill.sourceProvenance?.origin ?? .unknown)).fontWeight(.medium)
            Text(L("Library editing version: v{0}", String(active?.number ?? 0)))
            Text(SourceStatePresentation.observedLabel(skill, versions: store.library.versions))
            Text(L("Last observed source text is not a guarantee of the current file or the version used by an agent."))
                .foregroundStyle(StudioTheme.muted)
            if skill.sourceObservation?.externalChange == true {
                Text(L("An external source change was observed. Review the source-to-library diff before publishing.")).foregroundStyle(.orange)
            }
            if store.sourceNeedsRecheck.contains(skill.sourcePath ?? "") {
                Text(L("Source needs a fresh check.")).foregroundStyle(.orange)
            }
            if let reason = sourceEligibility.reason { Text(reason.message).foregroundStyle(StudioTheme.muted) }
            HStack {
                Text(L(SourceStatePresentation.differsFromObserved(skill, versions: store.library.versions)
                       ? "Library edits differ from the last observed source; they are not applied by saving."
                       : "Library text matches the last observed source."))
                Spacer()
                Button(L("Rescan")) { Task { await store.scan() } }.disabled(store.scanning)
                Button(L("Publish to source…")) {
                    do { publishRequest = try store.preparePublish(skill) }
                    catch { store.error = error.localizedDescription; Task { sourceEligibility = await store.checkSourceEligibility(skill) } }
                }.disabled(sourceEligibility != .allowed || store.scanning || store.sourceNeedsRecheck.contains(skill.sourcePath ?? "") ||
                           store.publishingPaths.contains(skill.sourcePath ?? "") || !SourceStatePresentation.differsFromObserved(skill, versions: store.library.versions))
            }
        }.font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
    }
    private var runHistory: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("Every output tells a story.")).font(.system(size: 17, weight: .semibold))
                    Text(L(skill.isDemo ? "Explore sample runs, review an output, and make the next version better." : "Capture a run to connect your prompts, outputs, and improvements."))
                        .font(.system(size: 11)).foregroundStyle(StudioTheme.muted)
                }
                Spacer()
                Button { recording = true } label: { Label(L("Add run"), systemImage: "plus").font(.system(size: 11)) }.buttonStyle(.bordered)
            }.padding(26)
            if !skill.isDemo {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle(L("Import local agent history"), isOn: Binding(get: { store.library.historyPolicy.enabledAgents.contains(skill.agent) }, set: { enabled in
                            var policy = store.library.historyPolicy
                            if enabled { policy.enabledAgents.insert(skill.agent) } else { policy.enabledAgents.remove(skill.agent) }
                            store.setHistoryPolicy(policy)
                            if enabled { Task { await store.importHistory(for: skill) } }
                        })).toggleStyle(.switch)
                        Spacer()
                        if store.importingHistory { ProgressView().controlSize(.small) }
                        Button(L("Sync history")) { Task { await store.importHistory(for: skill) } }
                            .disabled(store.importingHistory || !store.library.historyPolicy.enabledAgents.contains(skill.agent))
                    }
                    Text(L("Imports locally recorded answers with skill-read evidence. Nothing is sent to AI. Manage retention and excluded folders in settings."))
                        .font(.caption).foregroundStyle(.secondary)
                    if let status = store.historyStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
                    if !store.library.historyPolicy.allows(skill.sourcePath) { Text(L("This skill is excluded from history import.")).font(.caption) }
                    ForEach(store.historyDiagnostics.keys.sorted(), id: \.self) { key in Text(L(key) + ": \(store.historyDiagnostics[key] ?? 0)").font(.caption).foregroundStyle(.secondary) }
                }.padding(.horizontal, 26).padding(.bottom, 16)
            }
            HStack {
                TextField(L("Search prompt, output, feedback or model"), text: $historySearch).textFieldStyle(.roundedBorder)
                Picker(L("Rating"), selection: $ratingFilter) {
                    Text(L("All")).tag(Optional<RunRating>.none)
                    ForEach(RunRating.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }.frame(width: 180)
                if let selectedRun { Button(L("Delete…")) { deletingRun = selectedRun.id } }
            }.padding(.horizontal, 26).padding(.bottom, 12)
            if runs.isEmpty {
                EmptyState(symbol: "text.bubble", title: "No matching runs", detail: "Try another filter, sync local history, or add a run manually. Older or unsupported logs may not be imported.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 12) {
                            stat(value: "\(runs.count)", label: "RECORDED RUNS", symbol: "play.rectangle")
                            stat(value: "\(runs.filter { $0.rating == .good }.count)", label: "GOOD OUTPUTS", symbol: "checkmark.seal")
                            stat(value: "\(store.versions(for: skill).count)", label: "SKILL VERSIONS", symbol: "clock.arrow.circlepath")
                        }
                        HStack {
                            SectionCaption(text: "Run timeline")
                            Spacer()
                            Picker(L("Selected run"), selection: Binding(get: { selectedRun?.id ?? runs[0].id }, set: { selectedRunID = $0 })) {
                                ForEach(runs) { run in Text("\(Localization.date(run.startedAt)) · \(run.rating.label)").tag(run.id) }
                            }.labelsHidden().frame(maxWidth: 300)
                        }.padding(.top, 8)
                        if let run = selectedRun { RunDetailView(run: run).id(run.id) }
                        ForEach(runs.filter { $0.id != selectedRun?.id }) { run in
                            Button { selectedRunID = run.id } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "clock").foregroundStyle(StudioTheme.muted)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(run.prompt).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(Localization.date(run.startedAt)).font(.system(size: 10)).foregroundStyle(StudioTheme.muted)
                                    }
                                    Spacer(); Tag(text: run.rating.label, color: run.rating == .needsWork ? .orange : StudioTheme.muted)
                                    Image(systemName: "chevron.right").font(.system(size: 10))
                                }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 26).padding(.bottom, 30)
                }
            }
        }
    }
    private func stat(value: String, label: String, symbol: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(StudioTheme.accent.opacity(0.7))
            VStack(alignment: .leading, spacing: 5) { Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)); Text(L(label)).font(.system(size: 8, weight: .semibold)).tracking(0.8).foregroundStyle(StudioTheme.muted) }
            Spacer(minLength: 0)
        }.padding(17).frame(maxWidth: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioTheme.border))
    }
}

struct RunDetailView: View {
    @EnvironmentObject var store: StudioStore
    let run: SkillRun
    @State private var feedback = ""
    var body: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "play.fill").font(.system(size: 11)).foregroundStyle(StudioTheme.accent).frame(width: 30, height: 30).background(StudioTheme.accent.opacity(0.08), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Localization.date(run.startedAt)).font(.system(size: 12, weight: .semibold))
                        Text(L(run.model) + (run.durationSeconds.map { String(format: " · %.1fs", $0) } ?? "") + " · " + store.runVersionLabel(run))
                            .font(.system(size: 10)).foregroundStyle(StudioTheme.muted)
                    }
                    Spacer(); Tag(text: run.rating.label, color: run.rating == .good ? .green : run.rating == .needsWork ? .orange : StudioTheme.muted)
                }
                Text(RunVersionPresentation.explanation(run, versions: store.library.versions))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let capture = run.capture {
                    DisclosureGroup(L("Imported history · file access recorded")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("A local file-access event was recorded in this turn. It does not prove skill invocation, adherence, or output quality."))
                            Text(capture.command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            Button(L("Reveal local transcript")) {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: capture.sourceLog)])
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 9) {
                    SectionCaption(text: "Prompt")
                    Text(run.prompt).font(.system(size: 12)).lineSpacing(5).textSelection(.enabled)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(StudioTheme.background, in: RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack { SectionCaption(text: "Output"); Spacer(); Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(run.output, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help(L("Copy output")).accessibilityLabel(L("Copy output")) }
                    MarkdownBody(content: run.output)
                }
                if !run.artifacts.isEmpty {
                    Divider()
                    ForEach(run.artifacts) { artifact in
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text").foregroundStyle(StudioTheme.accent).font(.system(size: 21))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(artifact.name).font(.system(size: 12, weight: .medium))
                                Text(artifact.mediaType + (artifact.byteCount.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "") + (artifact.path == nil ? " · " + L("metadata only") : ""))
                                    .font(.system(size: 10)).foregroundStyle(StudioTheme.muted)
                                if let path = artifact.path { Text(path).font(.system(size: 9)).foregroundStyle(StudioTheme.muted).lineLimit(1).truncationMode(.middle).help(path) }
                            }
                            Spacer()
                            if let path = artifact.path {
                                Button(L("Reveal")) {
                                    if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                    else { store.error = L("Artifact not found at {0}.", path) }
                                }.font(.system(size: 11))
                            }
                        }.padding(12).background(StudioTheme.background, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Divider()
                HStack {
                    Text(L("How did this run do?")).font(.system(size: 11)).foregroundStyle(StudioTheme.muted)
                    Spacer()
                    ForEach(RunRating.allCases, id: \.self) { rating in
                        Button(rating.label) { store.reviewRun(run, rating: rating, feedback: feedback) }
                            .font(.system(size: 10)).buttonStyle(.bordered).tint(run.rating == rating ? StudioTheme.accent : .gray)
                    }
                }
                HStack {
                    TextField(L("Feedback for the next version…"), text: $feedback).textFieldStyle(.roundedBorder).font(.system(size: 11))
                    Button(L("Save feedback")) { store.reviewRun(run, rating: run.rating, feedback: feedback) }.font(.system(size: 11))
                }
            }
        }.onAppear { feedback = run.feedback }
    }
}

struct MarkdownBody: View {
    let content: String
    private struct Block: Identifiable {
        let id: Int
        let text: String
        let heading: Int
        let code: Bool
    }
    private var blocks: [Block] {
        var result: [Block] = [], buffer: [String] = []
        var inCode = false
        func flush() {
            if !buffer.isEmpty {
                result.append(Block(id: result.count, text: buffer.joined(separator: "\n"), heading: 0, code: inCode))
                buffer = []
            }
        }
        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("```") { flush(); inCode.toggle(); continue }
            if inCode { buffer.append(line); continue }
            let level = line.prefix(while: { $0 == "#" }).count
            if (1...6).contains(level), line.dropFirst(level).first == " " {
                flush()
                result.append(Block(id: result.count, text: String(line.dropFirst(level + 1)), heading: level, code: false))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() }
            else { buffer.append(line) }
        }
        flush()
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                if block.heading > 0 {
                    Text(block.text).font(.system(size: block.heading == 1 ? 19 : 14, weight: .semibold))
                } else if block.code {
                    Text(block.text).font(.system(size: 11, design: .monospaced)).padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading).background(StudioTheme.background, in: RoundedRectangle(cornerRadius: 7))
                } else {
                    Text((try? AttributedString(markdown: block.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block.text))
                        .font(.system(size: 12)).lineSpacing(5)
                }
            }
        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownView: View {
    @EnvironmentObject var store: StudioStore
    let content: String
    let sourcePath: String?
    @ObservedObject var session: TranslationSession
    let onComment: (SelectionComment, String) -> Void
    @State private var raw = false
    @State private var showTranslation = false
    @State private var confirmTranslation = false
    @State private var connectionError: String?
    private var displayedContent: String { showTranslation ? session.translation ?? content : content }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("SKILL.md", systemImage: "doc.text").font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker(L("View"), selection: $raw) { Text(L("Preview")).tag(false); Text(L("Source")).tag(true) }.labelsHidden().pickerStyle(.segmented).frame(width: 170)
                if let sourcePath { Button(L("Reveal file")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: sourcePath)]) } }
            }
            if store.language.offersSkillTranslation {
                HStack(spacing: 12) {
                    if session.isTranslating {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 4) {
                            if let progress = session.progress {
                                Text(L("Translating… {0} / {1} sections complete", String(progress.completed), String(progress.total)))
                            } else { Text(L("Translating…")) }
                            if let started = session.startedAt {
                                TimelineView(.periodic(from: started, by: 1)) { context in
                                    Text(L("Elapsed: {0}s · Long documents are translated in sections.", String(max(0, Int(context.date.timeIntervalSince(started))))))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.font(.callout)
                        Button(L("Cancel")) { session.cancel(); showTranslation = false }
                    } else if session.translation != nil {
                        Picker(L("View"), selection: $showTranslation) {
                            Text(L("Original")).tag(false)
                            Text(L("AI translation")).tag(true)
                        }.pickerStyle(.segmented).frame(width: 220)
                        Button(L("Translate again")) { startTranslation(refresh: true) }
                    } else {
                        Button { requestTranslation() } label: {
                            Label(L("Translate to {0}", store.language.nativeName), systemImage: "character.bubble")
                        }.buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    SettingsLink { Label(L("Translation settings"), systemImage: "gearshape") }.font(.caption)
                }
                if showTranslation, session.translation != nil {
                    Label(L("Translation is for reading only. The original file and version history are unchanged."), systemImage: "eye")
                        .font(.caption).foregroundStyle(StudioTheme.accent)
                }
                if let error = connectionError ?? session.error {
                    HStack(alignment: .top) {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                        Spacer()
                        Button(L("Retry")) { requestTranslation() }
                    }
                }
            }
            Text(L("Select text to request a change.")).font(.caption).foregroundStyle(.secondary)
            AnnotatableDocumentView(content: displayedContent, raw: raw,
                isTranslation: showTranslation && session.translation != nil, onComment: onComment)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }.padding(26)
            .onAppear { resetTranslation() }
            .onDisappear { resetTranslation() }
            .onChange(of: content) { _, _ in resetTranslation() }
            .onChange(of: store.language) { _, _ in resetTranslation() }
            .onChange(of: store.connection.cacheScope) { _, _ in resetTranslation() }
            .onChange(of: session.translation) { _, value in if value != nil { showTranslation = true } }
            .confirmationDialog(L("Translate this SKILL.md?"), isPresented: $confirmTranslation, titleVisibility: .visible) {
                Button(L("Translate")) { store.translationConsent = true; startTranslation() }
            } message: {
                Text(store.connection.provider.title + " · " + store.connection.provider.destination + "\n\n"
                     + L("Only the displayed SKILL.md text is sent to your translation provider. Prompts, run outputs, and other files are not included.")
                     + "\n\n" + L("Translation may consume your AI usage allowance."))
            }
    }
    private func requestTranslation() {
        if store.translationConsent { startTranslation() } else { confirmTranslation = true }
    }
    private func startTranslation(refresh: Bool = false) {
        guard store.language.offersSkillTranslation else { return }
        showTranslation = false; connectionError = nil
        do {
            let service = try store.translationService()
            session.translate(SkillTranslationRequest(content: content, language: store.language),
                              using: service, scope: store.connection.cacheScope, refresh: refresh)
        } catch { connectionError = error.localizedDescription }
    }
    private func resetTranslation() {
        session.reset(); showTranslation = false; confirmTranslation = false; connectionError = nil
    }
}

private struct ImprovementSheetContext: Identifiable {
    let id = UUID()
    let version: SkillVersion
    let run: SkillRun?
    var selection: SelectionComment? = nil
    var feedback = ""
}
