// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Attune",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Attune", targets: ["AgentSkillStudio"]),
        .library(name: "SkillStudioCore", targets: ["SkillStudioCore"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "SkillStudioCore", dependencies: ["CSQLite"], resources: [.process("Resources")]),
        .executableTarget(name: "AgentSkillStudio", dependencies: ["SkillStudioCore"]),
        .testTarget(name: "SkillStudioCoreTests", dependencies: ["SkillStudioCore"])
    ]
)
