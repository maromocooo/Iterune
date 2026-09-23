import XCTest
@testable import SkillStudioCore

final class RuntimeDataTests: XCTestCase {
    private var root: URL!
    private var production: URL { root.appendingPathComponent("production") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("isolation-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: production, withIntermediateDirectories: false)
        try Data("production sentinel, not a database".utf8).write(to: production.appendingPathComponent("studio.sqlite"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func configuration(_ url: URL) throws -> RuntimeDataConfiguration {
        try .init(mode: .isolatedDevelopment, isolatedPath: url.path, productionRoot: production)
    }
    func testProductionResolutionPreservesConfiguredStorage() throws {
        let runtime = try RuntimeDataConfiguration.resolve(environment: [:], developmentBuild: false, productionRoot: production)
        XCTAssertEqual(runtime.mode, .production); XCTAssertEqual(runtime.directory, production)
        XCTAssertEqual(RuntimeDataConfiguration.productionDirectory.lastPathComponent, "AgentSkillStudio")
    }
    func testDebugPreviewAndExplicitEnvironmentCannotFallBack() throws {
        for env in [[:], ["ITERUNE_RUNTIME_MODE":"production"]] {
            XCTAssertThrowsError(try RuntimeDataConfiguration.resolve(environment: env, developmentBuild: true, productionRoot: production))
        }
        XCTAssertThrowsError(try RuntimeDataConfiguration.resolve(environment: ["XCODE_RUNNING_FOR_PREVIEWS":"1"], developmentBuild: false, productionRoot: production))
        XCTAssertThrowsError(try RuntimeDataConfiguration.resolve(environment: ["ITERUNE_RUNTIME_MODE":"typo"], developmentBuild: false, productionRoot: production))
        XCTAssertEqual(try RuntimeDataMode.forLaunch(environment: ["SKILL_STUDIO_DATA_DIR":"/fixture/data"], developmentBuild: false), .isolatedDevelopment)
    }
    func testExplicitProductionCannotBypassDebugStoreGuard() throws {
        #if DEBUG
        let runtime = try RuntimeDataConfiguration(mode: .production, productionRoot: production)
        let file = production.appendingPathComponent("studio.sqlite")
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try runtime.prepare())
        XCTAssertThrowsError(try StudioDatabase(url: file, runtime: runtime))
        XCTAssertEqual(try Data(contentsOf: file), before)
        #endif
    }
    func testTrustedRootAliasCanCreateAndReopenAnIsolatedDatabase() throws {
        let physical = root.appendingPathComponent("fixture-root")
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let alias = root.appendingPathComponent("fixture-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        let runtime = try configuration(alias)
        try runtime.prepare()
        let path = alias.appendingPathComponent("studio.sqlite")
        let snapshot = LibrarySnapshot()
        do { let db = try StudioDatabase(url: path, runtime: runtime); try db.save(snapshot) }
        XCTAssertEqual(try StudioDatabase(url: path, runtime: runtime).load(), snapshot)
    }
    func testMissingEmptyAndRelativePathsAreRejected() {
        for path in [nil, "", "relative", "~/data"] as [String?] {
            XCTAssertThrowsError(try RuntimeDataConfiguration(mode:.isolatedDevelopment, isolatedPath:path, productionRoot:production))
        }
    }
    func testProductionItsChildrenAndAncestorsAreRejectedWithoutChanges() throws {
        let file = production.appendingPathComponent("studio.sqlite"), bytes = try Data(contentsOf:file)
        for path in [production, production.appendingPathComponent("child"), root!] {
            XCTAssertThrowsError(try configuration(path))
        }
        XCTAssertEqual(try Data(contentsOf:file),bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: production.appendingPathComponent(RuntimeDataConfiguration.markerName).path))
    }
    func testPhysicalAliasesAndAliasesBelowProductionAreRejected() throws {
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:production)
        XCTAssertThrowsError(try configuration(alias))
        XCTAssertThrowsError(try configuration(alias.appendingPathComponent("nested")))
    }
    func testCaseInsensitivePhysicalProductionAliasIsRejected() throws {
        let alias = root.appendingPathComponent("PRODUCTION")
        guard FileManager.default.fileExists(atPath: alias.path) else { throw XCTSkip("Requires a case-insensitive fixture volume") }
        XCTAssertThrowsError(try configuration(alias))
        XCTAssertThrowsError(try configuration(alias.appendingPathComponent("new-child")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: production.appendingPathComponent("new-child").path))
    }
    func testPathComponentBoundaryAllowsUnrelatedName() throws {
        let runtime = try configuration(root.appendingPathComponent("production-other"))
        try runtime.prepare(); try runtime.validate()
        XCTAssertTrue(runtime.isDevelopment)
    }
    func testUnmarkedExistingDatabaseAndNonemptyFolderRejected() throws {
        let dir = root.appendingPathComponent("unmarked")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let db = dir.appendingPathComponent("studio.sqlite"), before=Data("unmarked fixture".utf8)
        try before.write(to:db)
        let runtime = try configuration(dir)
        XCTAssertThrowsError(try runtime.prepare())
        XCTAssertThrowsError(try StudioDatabase(url:db,runtime:runtime))
        XCTAssertEqual(try Data(contentsOf:db),before)
    }
    func testIsolatedDatabaseReopenAndIndependentRuns() throws {
        let first = try configuration(root.appendingPathComponent(UUID().uuidString))
        let second = try configuration(root.appendingPathComponent(UUID().uuidString))
        try first.prepare();try second.prepare()
        XCTAssertNotEqual(first.directory,second.directory)
        var snapshot=LibrarySnapshot();DemoLibrary.seed(into:&snapshot)
        let path=first.directory.appendingPathComponent("studio.sqlite")
        do { let db=try StudioDatabase(url:path,runtime:first);try db.save(snapshot) }
        XCTAssertEqual(try StudioDatabase(url:path,runtime:first).load(),snapshot)
        XCTAssertTrue(try StudioDatabase(url:second.directory.appendingPathComponent("studio.sqlite"),runtime:second).load().skills.isEmpty)
    }
    func testCoreInitializerCannotEscapeMarkedRoot() throws {
        let runtime=try configuration(root.appendingPathComponent("safe"));try runtime.prepare()
        let file=production.appendingPathComponent("studio.sqlite"),before=try Data(contentsOf:file)
        XCTAssertThrowsError(try StudioDatabase(url:file,runtime:runtime))
        XCTAssertEqual(try Data(contentsOf:file),before)
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path+"-wal"))
    }
    func testDatabaseSymlinkHardlinkAndDirectorySymlinkAreRejected() throws {
        let runtime=try configuration(root.appendingPathComponent("safe"));try runtime.prepare()
        let target=production.appendingPathComponent("studio.sqlite")
        let symbolic=runtime.directory.appendingPathComponent("symbolic.sqlite")
        try FileManager.default.createSymbolicLink(at:symbolic,withDestinationURL:target)
        XCTAssertThrowsError(try StudioDatabase(url:symbolic,runtime:runtime))
        let hard=runtime.directory.appendingPathComponent("hard.sqlite")
        try FileManager.default.linkItem(at:target,to:hard)
        XCTAssertThrowsError(try StudioDatabase(url:hard,runtime:runtime))
        let folder=runtime.directory.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at:folder,withDestinationURL:production)
        XCTAssertThrowsError(try StudioDatabase(url:folder.appendingPathComponent("new.sqlite"),runtime:runtime))
        XCTAssertFalse(FileManager.default.fileExists(atPath:production.appendingPathComponent("new.sqlite").path))
    }
    func testMarkerCopyAndRootReplacementAreRejected() throws {
        let a=try configuration(root.appendingPathComponent("a"));try a.prepare()
        let b=try configuration(root.appendingPathComponent("b"))
        try FileManager.default.createDirectory(at:b.directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        try FileManager.default.copyItem(at:a.directory.appendingPathComponent(RuntimeDataConfiguration.markerName),to:b.directory.appendingPathComponent(RuntimeDataConfiguration.markerName))
        XCTAssertThrowsError(try b.prepare())
        let moved=root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at:a.directory,to:moved)
        try FileManager.default.createSymbolicLink(at:a.directory,withDestinationURL:production)
        XCTAssertThrowsError(try a.validate())
    }
    func testPreviewFixturesAndServicesStayIsolated() throws {
        let runtime=try RuntimeDataConfiguration.resolve(environment:["XCODE_RUNNING_FOR_PREVIEWS":"1", "SKILL_STUDIO_DATA_DIR":root.appendingPathComponent("preview").path],developmentBuild:false,productionRoot:production)
        try runtime.prepare()
        var snapshot=LibrarySnapshot();try DevelopmentFixtures.seed(into:&snapshot,runtime:runtime)
        let first=snapshot;try DevelopmentFixtures.seed(into:&snapshot,runtime:runtime)
        XCTAssertEqual(first,snapshot);XCTAssertTrue(snapshot.historyPolicy.enabledAgents.isEmpty)
        XCTAssertTrue(snapshot.skills.allSatisfy { $0.isDemo || $0.id.hasPrefix("development:") })
        XCTAssertTrue(snapshot.runs.allSatisfy { $0.isDemo || $0.model=="Offline fixture" })
        XCTAssertThrowsError(try runtime.requireExternalServices())
        let credentials=DevelopmentCredentialStore()
        XCTAssertNil(try credentials.read(for:.openAIAPI))
        XCTAssertThrowsError(try credentials.save("synthetic",for:.openAIAPI))
        let protected=try XCTUnwrap(snapshot.skills.first { $0.sourceProvenance?.origin == .synced })
        let context=DiscoveryContext(home:runtime.fixtureHome,environment:[:],systemDirectory:runtime.directory.appendingPathComponent("fixture-etc"))
        XCTAssertNotEqual(SourcePublisher.eligibility(skillID:protected.id,in:snapshot,context:context),.allowed)
        XCTAssertFalse(ImprovementRecord(skillID:protected.id,baseVersionID:protected.activeVersionID).includesRun)
    }
    func testDevelopmentPreferencesAreMemoryOnlyAndIndependent() {
        let a=StudioPreferences(production:false),b=StudioPreferences(production:false)
        a.set("fixture",forKey:"studio.aiConnection")
        XCTAssertEqual(a.string(forKey:"studio.aiConnection"),"fixture")
        XCTAssertNil(b.object(forKey:"studio.aiConnection"))
    }
}
