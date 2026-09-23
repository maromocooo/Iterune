import Foundation
@testable import SkillStudioCore

/// Only callers' freshly generated test roots. Never discovers normal application data.
func prepareTestRuntime(at root: URL) throws -> RuntimeDataConfiguration {
    let runtime = try RuntimeDataConfiguration(mode: .isolatedDevelopment, isolatedPath: root.path,
        productionRoot: root.deletingLastPathComponent().appendingPathComponent("synthetic-production"))
    try runtime.prepare()
    return runtime
}
func isolatedTestDatabase(url: URL) throws -> StudioDatabase {
    let runtime = try prepareTestRuntime(at: url.deletingLastPathComponent())
    return try StudioDatabase(url: url, runtime: runtime)
}
