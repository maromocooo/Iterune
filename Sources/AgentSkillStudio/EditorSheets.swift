import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SkillStudioCore

struct ImproveSkillView: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) var dismiss
    let skill: Skill
    let version: SkillVersion
    let run: SkillRun?
    var selection: SelectionComment? = nil
    var initialFeedback = ""
    var resumeRecord: ImprovementRecord? = nil
    @State private var frozenVersion: SkillVersion?
    @State private var referenceAcknowledged = false
    private var base: SkillVersion { frozenVersion ?? version }
    private var needsReferenceAcknowledgement: Bool {
        RunVersionPresentation.requiresReferenceAcknowledgement(run: run, base: base)
    }
    private var referenceReady: Bool { !needsReferenceAcknowledgement || referenceAcknowledged }
    private var baseIsCurrent: Bool {
        store.library.skills.first { $0.id == skill.id }?.activeVersionID == base.id
    }
    @State private var recordID = UUID()
    @State private var submittedProvider = ""
    @State private var submittedModel = ""
    @State private var draftStatus = "draft"
    @State private var autosave: Task<Void, Never>?
    @State private var initialized = false
    @State private var saved = false
    @State private var useAI = true
    @State private var includeRun = false
    @State private var feedback = ""
    @State private var draft = ""
    @State private var explanation = ""
    @State private var proposed = false
    @State private var generating = false
    @State private var showDiff = false
    @State private var error: String?
    @State private var proposalTask: Task<Void, Never>?
    @State private var codexModels: [String] = []
    @State private var proposalModelLabel: String?
    private var modelLabel: String {
        store.improvementPreferences.provider.title + " · " +
            (ImprovementPreferences.normalizedModel(store.improvementPreferences.model) ?? L("No model selected"))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(StudioTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Improve {0}", skill.name)).font(.title2.bold())
                    Text((generating || proposed ? proposalModelLabel : nil) ?? (useAI ? modelLabel : L(store.improvementService.displayName))).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(); Button(L("Close and keep draft")) { proposalTask?.cancel(); if persistDraft(status: generating ? "interrupted" : nil) { dismiss() } }.keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Reference history")).font(.caption.bold())
                Text(run.map { store.runVersionLabel($0) } ?? L(resumeRecord?.sourceRunID == nil ? "No run attached." : "The reference run was deleted.")).font(.callout)
                Text(L("Editing base: v{0} — {1}", String(base.number), L(baseIsCurrent ? "Current library version" : "Fixed draft base"))).font(.callout.bold())
                if !baseIsCurrent {
                    Text(L("The active version changed. Close this draft and review the latest version.")).font(.caption).foregroundStyle(.orange)
                }
                if needsReferenceAcknowledgement {
                    Text(L("The reference run is associated with a different version, or its version is uncertain. Changes will apply to the editing base above.")).font(.caption).foregroundStyle(.secondary)
                    Toggle(L("Use this historical result as a reference for the editing base"), isOn: $referenceAcknowledged).font(.caption).disabled(generating)
                }
            }
            if let selection {
                DisclosureGroup(L(selection.isTranslation ? "Selected translated passage" : "Selected original passage")) {
                    Text(selection.quote).font(.callout).lineLimit(4).textSelection(.enabled)
                }
                if selection.isTranslation { Text(L("This quote is translated. Your instruction will revise the original language.")).font(.caption).foregroundStyle(.secondary) }
            }
            if let run {
                DisclosureGroup(L("Context: selected run · {0}", store.runVersionLabel(run))) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionCaption(text: "Prompt"); Text(run.prompt)
                            SectionCaption(text: "Output"); Text(run.output)
                        }.font(.system(size: 11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }.frame(maxHeight: 130)
                }.font(.system(size: 12))
            }
            if !proposed {
                Picker(L("Improvement method"), selection: $useAI) {
                    Text(L("AI proposal")).tag(true)
                    Text(L("Local template")).tag(false)
                }.pickerStyle(.segmented).disabled(generating)
                Text(L("What should be better?")).font(.headline)
                if useAI {
                    Text(L("Sends the original SKILL.md, selected quote and your instruction to {0}. Review the changes before saving.", store.improvementPreferences.provider.title))
                        .font(.caption).foregroundStyle(.secondary)
                    if run != nil { Toggle(L("Include this run's prompt, output and feedback"), isOn: $includeRun).disabled(generating) }
                } else {
                    Text(L("The local template appends a checklist without contacting AI.")).font(.caption).foregroundStyle(.secondary)
                }
                TextEditor(text: $feedback).font(.system(size: 13)).padding(8).frame(minHeight: 95)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioTheme.border)).disabled(generating)
                if useAI { modelSelection }
                HStack {
                    Button(L("Edit current skill directly")) { draft = base.content; submittedProvider = "Manual edit"; submittedModel = ""; proposalModelLabel = L("Manual edit"); explanation = L("Manual edit based on v{0}.", String(base.number)); proposed = true }.disabled(generating || !referenceReady)
                    Spacer()
                    if generating { ProgressView().controlSize(.small); Button(L("Stop generating")) { proposalTask?.cancel() } }
                    Button(L(useAI ? "Generate AI proposal" : "Create local draft")) { generate() }.buttonStyle(.borderedProminent)
                        .disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || generating || !referenceReady || (useAI && ImprovementPreferences.normalizedModel(store.improvementPreferences.model) == nil))
                }
            } else {
                Text(explanation).font(.system(size: 12)).foregroundStyle(.secondary)
                Picker(L("Review"), selection: $showDiff) { Text(L("Edit proposal")).tag(false); Text(L("Review diff")).tag(true) }
                    .pickerStyle(.segmented).frame(width: 260)
                if showDiff {
                    ScrollView { DiffView(old: base.content, new: draft) }.frame(minHeight: 270)
                } else {
                    TextEditor(text: $draft).font(.system(size: 12, design: .monospaced)).padding(8).frame(minHeight: 270)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioTheme.border))
                }
                HStack {
                    Text(L("Saved to the library. Publish separately to update SKILL.md.")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Save new version")) {
                        do {
                            guard persistDraft() else { return }
                            try store.saveVersion(skill: skill, content: draft, note: feedback.isEmpty ? "Manual edit" : "Improvement: " + String(feedback.prefix(120)),
                                                  runID: run?.id, expectedVersionID: base.id, improvementID: recordID)
                            saved = true
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).disabled(!referenceReady || !baseIsCurrent || !showDiff || draft == base.content || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(28).frame(width: 780, height: 740).tint(StudioTheme.accent)
            .onAppear {
                guard !initialized else { return }
                frozenVersion = version
                if let record = resumeRecord {
                    recordID = record.id; feedback = record.instruction; includeRun = record.includesRun
                    referenceAcknowledged = record.referenceAcknowledged ?? false
                    draft = record.draft ?? ""; explanation = record.explanation; proposed = record.draft != nil
                    submittedProvider = record.provider; submittedModel = record.model
                    draftStatus = record.status == "generating" ? "interrupted" : record.status
                    proposalModelLabel = L(record.provider) + (record.model.isEmpty ? "" : " · " + record.model)
                    useAI = AIConnectionKind.allCases.contains { $0.title == record.provider }
                    if let provider = AIConnectionKind.allCases.first(where: { $0.title == record.provider }), !proposed {
                        store.improvementPreferences.provider = provider; store.improvementPreferences.model = record.model
                    }
                    showDiff = proposed
                } else { feedback = initialFeedback.isEmpty ? run?.feedback ?? "" : initialFeedback }
                initialized = true
                if !feedback.isEmpty { _ = persistDraft() }
            }
            .onChange(of: feedback) { _, _ in scheduleSave() }
            .onChange(of: draft) { _, _ in scheduleSave() }
            .onChange(of: referenceAcknowledged) { _, _ in scheduleSave() }
            .onChange(of: includeRun) { _, _ in scheduleSave() }
            .onChange(of: useAI) { _, _ in if !proposed && !generating { scheduleSave() } }
            .onChange(of: store.improvementPreferences) { _, _ in if !proposed && !generating { scheduleSave() } }
            .task { guard !store.isDevelopment else { return }; codexModels = await Task.detached(priority: .utility) { ImprovementModelCatalog.codexModels() }.value }
            .onDisappear { autosave?.cancel(); proposalTask?.cancel(); if !saved { _ = persistDraft(status: generating ? "interrupted" : nil) } }
    }
    private func scheduleSave() {
        guard initialized, !saved else { return }
        if !proposed && !generating { draftStatus = "draft"; submittedProvider = ""; submittedModel = "" }
        autosave?.cancel()
        autosave = Task { do { try await Task.sleep(nanoseconds: 350_000_000); _ = persistDraft() } catch { } }
    }
    @discardableResult private func persistDraft(status: String? = nil) -> Bool {
        guard initialized, !saved, !feedback.isEmpty || proposed else { return true }
        var record = store.library.improvements.first { $0.id == recordID } ?? ImprovementRecord(skillID: skill.id, baseVersionID: base.id)
        record.id = recordID; record.instruction = feedback; record.selection = selection
        record.provider = submittedProvider.isEmpty ? (useAI ? store.improvementPreferences.provider.title : store.improvementService.displayName) : submittedProvider
        record.model = submittedProvider.isEmpty ? (useAI ? store.improvementPreferences.model : "") : submittedModel
        record.includesRun = includeRun; record.sourceRunID = run?.id ?? resumeRecord?.sourceRunID
        record.referenceAcknowledged = referenceAcknowledged
        record.draft = proposed ? draft : nil; record.explanation = explanation; record.updatedAt = Date()
        if let status { draftStatus = status }
        record.status = proposed ? "proposal" : draftStatus
        do { try store.saveImprovement(record); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    private var modelSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker(L("Connection method"), selection: $store.improvementPreferences.provider) {
                    ForEach(AIConnectionKind.allCases) { Text($0.title).tag($0) }
                }.frame(width: 230)
                TextField(L("Improvement model ID"), text: $store.improvementPreferences.model)
                    .textFieldStyle(.roundedBorder)
                Menu(L("Choose model…")) {
                    let provider = store.improvementPreferences.provider
                    let saved = store.connection.models[provider.rawValue] ?? provider.defaultModel
                    ForEach(ImprovementModelCatalog.suggestions(for: provider, codexModels: codexModels, savedModel: saved), id: \.self) { id in
                        Button(id) { store.improvementPreferences.model = id }
                    }
                }.fixedSize()
            }.disabled(generating)
            Text(L("Improvement models are saved separately from translation. You can also enter a model ID."))
                .font(.caption).foregroundStyle(.secondary)
            Label(L("Selected model: {0}", modelLabel), systemImage: "cpu")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioTheme.accent)
        }
    }
    private func generate() {
        guard referenceReady else { return }
        error = nil
        let service: any SkillImprovementService
        do {
            if useAI {
                let connection = try store.improvementPreferences.connection(using: store.connection)
                service = try store.aiImprovementService(connection: connection)
                proposalModelLabel = connection.provider.title + " · " + connection.model
                submittedProvider = connection.provider.title; submittedModel = connection.model
            } else { service = store.improvementService; proposalModelLabel = nil; submittedProvider = service.displayName; submittedModel = "" }
        } catch { self.error = error.localizedDescription; return }
        guard persistDraft(status: "generating") else { return }
        generating = true
        let request = ImprovementRequest(skill: skill, version: base, referenceRun: run, includeRun: !useAI || includeRun, feedback: feedback, selection: selection)
        proposalTask = Task {
            defer { generating = false }
            do {
                let proposal = try await service.propose(request)
                try Task.checkCancellation()
                draft = proposal.content; explanation = proposal.explanation; proposed = true; showDiff = true
                _ = persistDraft(status: "proposal")
            } catch is CancellationError { _ = persistDraft(status: "interrupted") }
            catch { self.error = error.localizedDescription; _ = persistDraft(status: "failed") }
        }
    }
}

struct RecordRunView: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) var dismiss
    let skill: Skill
    @State private var prompt = ""
    @State private var output = ""
    @State private var model = "Manual capture"
    @State private var versionID: UUID?
    @State private var artifacts: [Artifact] = []
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Text(L("Add a run")).font(.title2.bold()); Spacer(); Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction) }
            Text(L("Record an existing result. This does not execute the skill or contact an AI service.")).font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField(L("Agent / model"), text: $model).textFieldStyle(.roundedBorder)
                Picker(L("Skill version"), selection: $versionID) {
                    Text(L("Version unknown")).tag(Optional<UUID>.none)
                    ForEach(store.versions(for: skill)) { Text("v\($0.number)").tag(Optional($0.id)) }
                }.frame(width: 240)
            }
            Text(L("Selecting a version records your association, not execution-time evidence.")).font(.caption).foregroundStyle(.secondary)
            SectionCaption(text: "Prompt")
            TextEditor(text: $prompt).font(.system(size: 12)).padding(6).frame(height: 110).overlay(RoundedRectangle(cornerRadius: 7).stroke(StudioTheme.border))
            SectionCaption(text: "Output")
            TextEditor(text: $output).font(.system(size: 12)).padding(6).frame(minHeight: 170).overlay(RoundedRectangle(cornerRadius: 7).stroke(StudioTheme.border))
            HStack {
                Button { attachArtifacts() } label: { Label(L("Attach files…"), systemImage: "paperclip") }
                Text(L("References only; files stay where they are.")).font(.caption).foregroundStyle(.secondary)
            }
            if !artifacts.isEmpty {
                ScrollView {
                    ForEach(artifacts) { artifact in
                        HStack { Text(artifact.name).font(.caption); Spacer(); Button { artifacts.removeAll { $0.id == artifact.id } } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                    }
                }.frame(maxHeight: 60)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L("Save run")) {
                    do {
                        try store.recordRun(SkillRun(skillID: skill.id, versionID: versionID, prompt: prompt, output: output,
                                                     model: model.isEmpty ? "Manual capture" : model, artifacts: artifacts, isDemo: skill.isDemo))
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 700, height: 660).tint(StudioTheme.accent)

    }
    private func attachArtifacts() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !artifacts.contains(where: { $0.path == url.path }) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            artifacts.append(Artifact(name: url.lastPathComponent, path: url.path,
                mediaType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", byteCount: size.map(Int64.init)))
        }
    }
}
