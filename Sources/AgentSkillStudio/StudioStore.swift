import SwiftUI
import AppKit
import SkillStudioCore

@MainActor
final class StudioStore: ObservableObject {
    @Published var language = Localization.language {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Localization.preferenceKey); notice = nil }
    }
    @Published var connection: AIConnectionSettings = {
        guard let data = UserDefaults.standard.data(forKey: "studio.aiConnection"),
              let saved = try? JSONDecoder().decode(AIConnectionSettings.self, from: data) else { return AIConnectionSettings() }
        return saved
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(connection) { UserDefaults.standard.set(data, forKey: "studio.aiConnection") }
            // Concurrency changes apply to the next translation; preserve current work and cache.
            if oldValue.cacheScope != connection.cacheScope {
                translationSession.reset(clearCache: true); translationConsent = false
            }
        }
    }
    let translationSession = TranslationSession()
    var translationConsent = false
    let credentials: any CredentialStore = KeychainCredentialStore()
    func translationService() throws -> any SkillTranslationService {
        let provider = connection.provider
        if provider.isCLI {
            return ChunkedTranslationService(base: CLITranslationService(provider: provider,
                executable: CodexExecutable.resolve(override: connection.executablePath, name: provider.executableName), model: connection.model),
                maxConcurrentRequests: connection.maxConcurrentTranslations)
        }
        guard let key = try credentials.read(for: provider) else { throw StudioError.message("Save an API key in translation settings first.") }
        return ChunkedTranslationService(base: APITranslationService(provider: provider, model: connection.model, apiKey: key),
            maxConcurrentRequests: connection.maxConcurrentTranslations)
    }
    @Published var improvementPreferences: ImprovementPreferences = {
        if let data = UserDefaults.standard.data(forKey: "studio.improvementPreferences"),
           let saved = try? JSONDecoder().decode(ImprovementPreferences.self, from: data) { return saved }
        let shared = UserDefaults.standard.data(forKey: "studio.aiConnection")
            .flatMap { try? JSONDecoder().decode(AIConnectionSettings.self, from: $0) } ?? AIConnectionSettings()
        return ImprovementPreferences(shared: shared)
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(improvementPreferences) {
                UserDefaults.standard.set(data, forKey: "studio.improvementPreferences")
            }
        }
    }
    func aiImprovementService(connection: AIConnectionSettings) throws -> any SkillImprovementService {
        guard ImprovementPreferences.normalizedModel(connection.model) != nil else {
            throw StudioError.message("Choose a model ID before generating an improvement.")
        }
        let provider = connection.provider
        let generator: any TextGenerationService
        if provider.isCLI {
            generator = CLITranslationService(provider: provider,
                executable: CodexExecutable.resolve(override: connection.executablePath, name: provider.executableName),
                model: connection.model)
        } else {
            guard let key = try credentials.read(for: provider) else { throw StudioError.message("Save an API key in translation settings first.") }
            generator = APITranslationService(provider: provider, model: connection.model, apiKey: key)
        }
        return AIImprovementService(generator: generator, displayName: provider.title, language: language)
    }
    @Published private(set) var importingHistory = false
    @Published private(set) var historyStatus: String?
    @Published private(set) var historyDiagnostics: [String: Int] = [:]
    private let runHistoryAdapters: [AgentKind: any RunHistoryAdapter] = [.codex: CodexRunHistoryAdapter(), .claude: ClaudeRunHistoryAdapter(), .gemini: GeminiRunHistoryAdapter()]
    func importHistory(for skill: Skill) async {
        guard !importingHistory, !skill.isDemo, ready, library.historyPolicy.enabledAgents.contains(skill.agent),
              library.historyPolicy.allows(skill.sourcePath), let adapter = runHistoryAdapters[skill.agent] else { return }
        importingHistory = true; historyStatus = nil; historyDiagnostics = [:]
        defer { importingHistory = false }
        do {
            let epoch = libraryEpoch, policy = library.historyPolicy
            let since = policy.retentionDays > 0 ? Date().addingTimeInterval(-Double(policy.retentionDays) * 86_400) : .distantPast
            let result = try await adapter.scan(skill: skill, versions: versions(for: skill), since: since, excludedPaths: policy.excludedPaths)
            try Task.checkCancellation()
            guard epoch == libraryEpoch, policy == library.historyPolicy else { return }
            var updated = library
            let added = RunHistoryMerge.merge(result.runs, into: &updated)
            if updated != library { try commit { $0 = updated } }
            guard selectedSkillID == skill.id else { return }
            historyStatus = L("Local history synced · {0} added · {1} files skipped", String(added), String(result.skippedFiles))
            historyDiagnostics = result.diagnostics
        } catch is CancellationError { }
        catch { historyStatus = L("Unable to read local agent history.") }
    }
    func runVersionLabel(_ run: SkillRun) -> String {
        RunVersionPresentation.label(run, versions: library.versions)
    }
    @Published private(set) var library = LibrarySnapshot()
    @Published var selectedAgent: AgentKind? = nil
    @Published var selectedSkillID: String? {
        didSet { if oldValue != selectedSkillID { historyStatus = nil; historyDiagnostics = [:] } }
    }
    @Published var search = ""
    @Published var showDemo = false
    @Published var scanning = false
    @Published var error: String?
    @Published var notice: String?
    @Published var report = ScanReport()
    private var database: StudioDatabase?
    private var libraryLease: LibraryLease?
    private var libraryEpoch = UUID()
    let dataDirectory: URL
    let improvementService: any SkillImprovementService

    init(service: any SkillImprovementService = LocalImprovementService()) {
        improvementService = service
        let env = ProcessInfo.processInfo.environment
        dataDirectory = env["SKILL_STUDIO_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AgentSkillStudio")
        do {
            libraryLease = try LibraryLease(directory: dataDirectory)
            let db = try StudioDatabase(url: dataDirectory.appendingPathComponent("studio.sqlite"))
            var snapshot = try db.load()
            if !snapshot.skills.isEmpty { try automaticBackup(snapshot) }
            if UserDefaults.standard.object(forKey: "studio.historyPolicyMigrated") == nil,
               UserDefaults.standard.object(forKey: "studio.importsCodexHistory") as? Bool == false {
                snapshot.historyPolicy.enabledAgents.remove(.codex)
            }
            for index in snapshot.improvements.indices where snapshot.improvements[index].status == "generating" {
                snapshot.improvements[index].status = "interrupted"
            }
            DemoLibrary.seed(into: &snapshot)
            try db.save(snapshot)
            database = db; library = snapshot
            UserDefaults.standard.set(true, forKey: "studio.historyPolicyMigrated")
            showDemo = ProcessInfo.processInfo.arguments.contains("--demo") || !snapshot.skills.contains(where: { !$0.isDemo })
            selectFirst()
        } catch { self.error = L("Unable to open the library: {0}", error.localizedDescription) }
    }
    var ready: Bool { database != nil }
    var skills: [Skill] {
        library.skills.filter { $0.isDemo == showDemo && (selectedAgent == nil || $0.agent == selectedAgent)
            && (search.isEmpty || ($0.name + " " + $0.summary).localizedCaseInsensitiveContains(search)) }
            .sorted { ($0.name, $0.agent.rawValue, $0.id) < ($1.name, $1.agent.rawValue, $1.id) }
    }
    var selectedSkill: Skill? { skills.first { $0.id == selectedSkillID } }
    var realCount: Int { library.skills.filter { !$0.isDemo }.count }
    func count(for agent: AgentKind) -> Int { library.skills.filter { $0.agent == agent && $0.isDemo == showDemo }.count }
    func selectFirst() {
        if !skills.contains(where: { $0.id == selectedSkillID }) {
            selectedSkillID = skills.first(where: { $0.name == "release-notes" })?.id ?? skills.first?.id
        }
    }
    func versions(for skill: Skill) -> [SkillVersion] { library.versions.filter { $0.skillID == skill.id }.sorted { $0.number > $1.number } }
    func activeVersion(for skill: Skill) -> SkillVersion? { library.versions.first { $0.id == skill.activeVersionID } }
    func runs(for skill: Skill) -> [SkillRun] { library.runs.filter { $0.skillID == skill.id }.sorted { $0.startedAt > $1.startedAt } }
    func versionNumber(_ id: UUID) -> Int { library.versions.first { $0.id == id }?.number ?? 0 }

    private func commit(_ change: (inout LibrarySnapshot) throws -> Void) throws {
        guard let database else { throw StudioError.message("The library is unavailable. Restart after fixing the storage error.") }
        var updated = library
        try change(&updated)
        try automaticBackup(library)
        try database.save(updated)
        library = updated
    }
    func scan() async {
        guard !scanning, ready else { return }
        scanning = true
        defer { scanning = false }
        let context = DiscoveryContext(projects: library.projectPaths.map { URL(fileURLWithPath: $0) })
        let epoch = libraryEpoch
        let result = await Task.detached(priority: .userInitiated) { SkillScanner().scan(context: context) }.value
        guard epoch == libraryEpoch else { return }
        do {
            try commit { try Versioning.merge(result, into: &$0) }
            sourceNeedsRecheck.subtract(result.skills.map(\.path))
            report = result
            if realCount == 0 { showDemo = true }
            else if !ProcessInfo.processInfo.arguments.contains("--demo"), selectedSkillID?.hasPrefix("demo:") == true, report.roots.count > 0, !hasScanned {
                showDemo = false
            }
            hasScanned = true
            selectFirst()
            notice = L("Found {0} local skills · {1} scan warnings", String(result.skills.count), String(result.warnings.count))
        } catch { self.error = error.localizedDescription }
    }
    private var hasScanned = false
    func addProject() {
        let panel = NSOpenPanel()
        panel.title = L("Choose a project to scan")
        panel.message = L("Scan .claude/skills, .agents/skills, .codex/skills, and .gemini/skills in this project.")
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try commit { if !$0.projectPaths.contains(url.path) { $0.projectPaths.append(url.path) } }
            Task { await scan() }
        } catch { self.error = error.localizedDescription }
    }
    func removeProject(_ path: String) {
        do { try commit { $0.projectPaths.removeAll { $0 == path } }; Task { await scan() } }
        catch { self.error = error.localizedDescription }
    }
    func saveVersion(skill: Skill, content: String, note: String, runID: UUID?, expectedVersionID: UUID, improvementID: UUID? = nil) throws {
        try commit { snapshot in
            let version = try Versioning.append(to: &snapshot, skillID: skill.id, content: content, note: note, runID: runID, expectedVersionID: expectedVersionID)
            if let index = snapshot.improvements.firstIndex(where: { $0.id == improvementID }) {
                snapshot.improvements[index].savedVersionID = version.id
                snapshot.improvements[index].status = "saved"
                snapshot.improvements[index].draft = content
                snapshot.improvements[index].updatedAt = Date()
            }
        }
        notice = L("New version saved in your library.")
    }
    func rollback(_ version: SkillVersion) {
        do { try commit { try Versioning.rollback(version.id, in: &$0) }; notice = L("Restored v{0} as a new library version.", String(version.number)) }
        catch { self.error = error.localizedDescription }
    }
    private var discoveryContext: DiscoveryContext { DiscoveryContext(projects: library.projectPaths.map { URL(fileURLWithPath: $0) }) }
    @Published private(set) var publishingPaths = Set<String>()
    @Published private(set) var sourceNeedsRecheck = Set<String>()
    func checkSourceEligibility(_ skill: Skill) async -> PublishEligibility {
        let snapshot = library, context = discoveryContext
        return await Task.detached(priority: .userInitiated) {
            SourcePublisher.eligibility(skillID: skill.id, in: snapshot, context: context)
        }.value
    }
    func preparePublish(_ skill: Skill) throws -> PublishRequest {
        guard let path = skill.sourcePath, !publishingPaths.contains(path), !sourceNeedsRecheck.contains(path), !scanning else {
            throw SourcePublishError.blocked(.staleConfirmation)
        }
        return try SourcePublisher.prepare(skillID: skill.id, in: library, context: discoveryContext)
    }
    func publish(_ request: PublishRequest) {
        guard !publishingPaths.contains(request.targetPath), !sourceNeedsRecheck.contains(request.targetPath), !scanning else { return }
        publishingPaths.insert(request.targetPath)
        defer { publishingPaths.remove(request.targetPath) }
        do {
            // Do the library backup before the file write. SQLite save can still fail afterwards.
            try automaticBackup(library)
            let result = try PublishOperation.perform(request, snapshot: library, context: discoveryContext,
                                                     backupDirectory: dataDirectory.appendingPathComponent("Backups")) { updated in
                try self.commit { $0 = updated }
            }
            switch result {
            case .saved(let receipt): notice = L("Published to SKILL.md. Backup: {0}", receipt.backupURL.lastPathComponent)
            case .sourceWrittenLibrarySaveFailed(let receipt, _):
                sourceNeedsRecheck.insert(request.targetPath)
                error = L("Source was replaced, but the library save failed. Backup: {0}. Rescan before publishing again; the source was not rolled back.", receipt.backupURL.lastPathComponent)
            }
        } catch {
            sourceNeedsRecheck.insert(request.targetPath)
            self.error = L("Source replacement did not complete. Rescan and review before retrying. {0}", error.localizedDescription)
        }
    }
    func recordRun(_ run: SkillRun) throws {
        try commit { snapshot in
            try RunVersionIntegrity.recordManual(run, into: &snapshot)
        }
    }
    func reviewRun(_ run: SkillRun, rating: RunRating, feedback: String) {
        do {
            try commit { snapshot in
                if let i = snapshot.runs.firstIndex(where: { $0.id == run.id }) { snapshot.runs[i].rating = rating; snapshot.runs[i].feedback = feedback }
            }
        } catch { self.error = error.localizedDescription }
    }
    var canRestoreLibrary: Bool { libraryLease != nil }
    var backupDirectory: URL { dataDirectory.appendingPathComponent("LibraryBackups") }
    private func automaticBackup(_ snapshot: LibrarySnapshot) throws {
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let existing = (try? FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let recent = existing.filter { $0.lastPathComponent.hasPrefix("auto-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        if let newest = recent.first, let date = try? newest.resourceValues(forKeys: [.creationDateKey]).creationDate, Date().timeIntervalSince(date) < 3600 { return }
        let name = "auto-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).skillstudio"
        try LibraryBackup.write(snapshot, to: backupDirectory.appendingPathComponent(name))
        for old in recent.dropFirst(9) { try? FileManager.default.removeItem(at: old) }
    }
    func exportLibrary() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Attune-backup.skillstudio"
        panel.message = L("Backups contain private skill and conversation text, but no API keys. Store them securely.")
        guard ready, panel.runModal() == .OK, let url = panel.url else { return }
        do { try LibraryBackup.write(library, to: url); notice = L("Library backup saved.") }
        catch { self.error = error.localizedDescription }
    }
    func restoreLibrary(from url: URL) throws {
        guard canRestoreLibrary else { throw StudioError.message("Close the other app before restoring this library.") }
        let restored = try LibraryBackup.read(from: url)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        if let database {
            try LibraryBackup.write(library, to: backupDirectory.appendingPathComponent("before-restore-\(UUID().uuidString).skillstudio"))
            try database.save(restored)
        } else {
            database = try LibraryRecovery.replaceUnreadableDatabase(at: dataDirectory.appendingPathComponent("studio.sqlite"), with: restored)
        }
        libraryEpoch = UUID(); library = restored; translationSession.reset(clearCache: true)
        sourceNeedsRecheck = Set(restored.skills.compactMap(\.sourcePath))
        selectFirst(); error = nil; notice = L("Library restored. Source skill files were not changed.")
    }
    func saveImprovement(_ record: ImprovementRecord) throws {
        try commit { snapshot in
            guard snapshot.versions.contains(where: { $0.id == record.baseVersionID && $0.skillID == record.skillID }) else { throw StudioError.message("The original version is no longer available.") }
            if let index = snapshot.improvements.firstIndex(where: { $0.id == record.id }) {
                guard snapshot.improvements[index].baseVersionID == record.baseVersionID,
                      snapshot.improvements[index].skillID == record.skillID else { throw StudioError.message("The original version is no longer available.") }
                snapshot.improvements[index] = record
            }
            else { snapshot.improvements.append(record) }
        }
    }
    func deleteImprovement(_ id: UUID) {
        do { try commit { $0.improvements.removeAll { $0.id == id } } } catch { self.error = error.localizedDescription }
    }
    func setHistoryPolicy(_ policy: HistoryPolicy) {
        do { try commit { $0.historyPolicy = policy } } catch { self.error = error.localizedDescription }
    }
    func deleteRun(_ id: UUID) {
        do { try commit { snapshot in snapshot.deletedRunIDs.insert(id); snapshot.runs.removeAll { $0.id == id } } }
        catch { self.error = error.localizedDescription }
    }
    func applyRetention() {
        guard library.historyPolicy.retentionDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(library.historyPolicy.retentionDays) * 86_400)
        do { try commit { snapshot in
            let ids = snapshot.runs.filter { !$0.isDemo && $0.capture != nil && $0.startedAt < cutoff }.map(\.id)
            snapshot.deletedRunIDs.formUnion(ids); snapshot.runs.removeAll { ids.contains($0.id) }
        } } catch { self.error = error.localizedDescription }
    }
}
