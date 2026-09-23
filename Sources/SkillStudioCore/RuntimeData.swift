import Foundation
import Darwin

public enum RuntimeDataMode: String, Codable, Sendable {
    case production, isolatedDevelopment

    public static var developmentBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    public static func forLaunch(environment: [String: String], developmentBuild: Bool = developmentBuild) throws -> Self {
        let requested = environment["ITERUNE_RUNTIME_MODE"]
        guard requested == nil || requested == production.rawValue || requested == isolatedDevelopment.rawValue else {
            throw RuntimeDataError.isolationRequired
        }
        // A debug binary or Xcode Preview cannot opt back into production with an environment flag.
        if developmentBuild || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" ||
            requested == isolatedDevelopment.rawValue || environment["SKILL_STUDIO_DATA_DIR"] != nil {
            return .isolatedDevelopment
        }
        return .production
    }
}

public enum RuntimeDataError: LocalizedError {
    case isolationRequired, unsafeRoot, unmarkedData, isolationChanged, externalServicesDisabled
    public var errorDescription: String? {
        switch self {
        case .isolationRequired:
            return L("Development requires an explicit, absolute SKILL_STUDIO_DATA_DIR. Production data was not opened. Use scripts/run-gui-smoke.sh to create an isolated run.")
        case .unsafeRoot:
            return L("This development data directory is not safe. Choose a new private directory outside production storage. Production data was not opened.")
        case .unmarkedData:
            return L("Development data must start in an empty directory or an existing marked fixture directory. Existing data was not opened.")
        case .isolationChanged:
            return L("The isolated directory changed or contains an unsafe link. Stop and create a new isolated run.")
        case .externalServicesDisabled:
            return L("Isolated development uses fixtures only. AI, Keychain, host history and source publishing are disabled.")
        }
    }
}

/// Checked again at the database boundary. A marker is an accidental-use guard, not a security
/// credential against another process owned by the same user. No production file is opened here.
public struct RuntimeDataConfiguration: Sendable {
    public static let markerName = ".iterune-development.json"
    public let mode: RuntimeDataMode
    public let directory: URL
    private let productionPath: URL
    private let requestedRoot: URL

    /// Account home is independent of HOME/CFFIXED_USER_HOME supplied to a preview process.
    public static var productionDirectory: URL {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/AgentSkillStudio")
    }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               developmentBuild: Bool = RuntimeDataMode.developmentBuild,
                               productionRoot: URL = productionDirectory) throws -> Self {
        try Self(mode: RuntimeDataMode.forLaunch(environment: environment, developmentBuild: developmentBuild),
                 isolatedPath: environment["SKILL_STUDIO_DATA_DIR"], productionRoot: productionRoot)
    }

    public init(mode: RuntimeDataMode, isolatedPath: String? = nil, productionRoot: URL = productionDirectory) throws {
        self.mode = mode
        self.productionPath = productionRoot
        _ = try Self.canonical(productionRoot)
        if mode == .production {
            directory = productionRoot; requestedRoot = productionRoot
        } else {
            guard let path = isolatedPath, path.hasPrefix("/"), !path.contains("\0"),
                  !path.split(separator: "/").contains("..") else { throw RuntimeDataError.isolationRequired }
            requestedRoot = URL(fileURLWithPath: path).standardizedFileURL
            directory = try Self.canonical(requestedRoot)
            try checkRoot()
        }
    }

    private static func contains(_ parent: URL, _ child: URL) -> Bool {
        let p = parent.pathComponents, c = child.pathComponents
        return c.starts(with: p)
    }
    private static func physicallyContains(_ parent: URL, _ child: URL) -> Bool {
        if contains(parent, child) { return true }
        var root = stat()
        if stat(parent.path, &root) == 0 {
            var cursor = child
            while true {
                var value = stat()
                if stat(cursor.path, &value) == 0, root.st_dev == value.st_dev, root.st_ino == value.st_ino { return true }
                if cursor.path == "/" { return false }
                cursor.deleteLastPathComponent()
            }
        }
        // For not-yet-created roots, conservatively reject case variants as well. Once present,
        // device/inode checks handle case-insensitive volumes and filesystem aliases precisely.
        return child.pathComponents.map { $0.lowercased() }.starts(with: parent.pathComponents.map { $0.lowercased() })
    }
    /// Foundation may leave an ancestor alias unresolved when the final component does not exist.
    /// Resolve the existing prefix physically, then append only the missing directory components.
    private static func canonical(_ url: URL) throws -> URL {
        var prefix = url.standardizedFileURL
        var missing: [String] = []
        var info = stat()
        while lstat(prefix.path, &info) != 0 {
            guard errno == ENOENT, prefix.path != "/" else { throw RuntimeDataError.unsafeRoot }
            missing.insert(prefix.lastPathComponent, at: 0)
            prefix.deleteLastPathComponent()
        }
        guard let resolved = realpath(prefix.path, nil) else { throw RuntimeDataError.unsafeRoot }
        defer { free(resolved) }
        return missing.reduce(URL(fileURLWithPath: String(cString: resolved))) { $0.appendingPathComponent($1) }
    }
    private func checkRoot() throws {
        guard mode == .isolatedDevelopment else { return }
        let actual = try Self.canonical(requestedRoot)
        guard actual.path == directory.path, actual.path != "/", actual.pathComponents.count > 2 else {
            throw RuntimeDataError.unsafeRoot
        }
        // Injection adds a synthetic protected root for tests; it cannot unprotect the account's
        // real production directory if a future caller supplies the wrong context.
        for path in [productionPath, Self.productionDirectory] {
            let productionRoot = try Self.canonical(path)
            guard !Self.physicallyContains(productionRoot, actual), !Self.physicallyContains(actual, productionRoot) else {
                throw RuntimeDataError.unsafeRoot
            }
        }
    }
    private struct Marker: Codable {
        let format: Int
        let root: String
        let device: UInt64
        let inode: UInt64
    }
    private func attributes(_ url: URL, directory: Bool) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0,
              value.st_uid == getuid(),
              (value.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG),
              directory || value.st_nlink == 1 else { throw RuntimeDataError.isolationChanged }
        return value
    }

    private func validateProcessMode() throws {
        // Explicitly passing a production configuration must not bypass Preview/Debug guards.
        if mode == .production, try RuntimeDataMode.forLaunch(environment: ProcessInfo.processInfo.environment) != .production {
            throw RuntimeDataError.isolationRequired
        }
    }

    public func prepare() throws {
        try validateProcessMode()
        guard mode == .isolatedDevelopment else { return }
        try checkRoot()
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            // Do not create or chmod arbitrary ancestors. The caller chooses an existing parent.
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let info = try attributes(directory, directory: true)
        guard info.st_mode & 0o077 == 0 else { throw RuntimeDataError.unsafeRoot }
        let marker = directory.appendingPathComponent(Self.markerName)
        if !fm.fileExists(atPath: marker.path) {
            guard try fm.contentsOfDirectory(atPath: directory.path).isEmpty else { throw RuntimeDataError.unmarkedData }
            let data = try JSONEncoder().encode(Marker(format: 1, root: directory.path, device: UInt64(info.st_dev), inode: info.st_ino))
            let fd = open(marker.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw RuntimeDataError.isolationChanged }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try file.write(contentsOf: data); try file.close()
        }
        try validate()
    }

    public func validate() throws {
        try validateProcessMode()
        guard mode == .isolatedDevelopment else { return }
        try checkRoot()
        let rootInfo = try attributes(directory, directory: true)
        guard rootInfo.st_mode & 0o077 == 0 else { throw RuntimeDataError.unsafeRoot }
        let marker = directory.appendingPathComponent(Self.markerName)
        let info = try attributes(marker, directory: false)
        guard info.st_size <= 4096, info.st_mode & 0o077 == 0 else { throw RuntimeDataError.isolationChanged }
        let fd = open(marker.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw RuntimeDataError.isolationChanged }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = try file.readToEnd() ?? Data(); try file.close()
        let value = try JSONDecoder().decode(Marker.self, from: data)
        guard value.format == 1, value.root == directory.path,
              value.device == UInt64(rootInfo.st_dev), value.inode == rootInfo.st_ino else { throw RuntimeDataError.isolationChanged }
    }

    public func validateDatabase(_ url: URL) throws {
        try validateProcessMode()
        guard mode == .isolatedDevelopment else { return }
        try validate()
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.split(separator: "/").contains("..") else {
            throw RuntimeDataError.unsafeRoot
        }
        // Resolve trusted ancestor aliases (for example /var -> /private/var), but never
        // resolve the final file: its own lstat must still reject a symlink or hardlink.
        let parent = try Self.canonical(url.deletingLastPathComponent())
        guard Self.contains(directory, parent) else { throw RuntimeDataError.unsafeRoot }
        let full = parent.appendingPathComponent(url.lastPathComponent)
        var cursor = url.deletingLastPathComponent()
        while try Self.canonical(cursor).path != directory.path {
            guard cursor.path != "/" else { throw RuntimeDataError.unsafeRoot }
            var info = stat()
            if lstat(cursor.path, &info) == 0 { _ = try attributes(cursor, directory: true) }
            else if errno != ENOENT { throw RuntimeDataError.isolationChanged }
            cursor.deleteLastPathComponent()
        }
        // Existing database and sidecars must be ordinary, singly linked fixture files.
        for suffix in ["", "-wal", "-shm"] {
            let path = URL(fileURLWithPath: full.path + suffix)
            var info = stat()
            if lstat(path.path, &info) == 0 { _ = try attributes(path, directory: false) }
            else if errno != ENOENT { throw RuntimeDataError.isolationChanged }
        }
    }

    public var isDevelopment: Bool { mode == .isolatedDevelopment }
    public var fixtureHome: URL { directory.appendingPathComponent("fixture-home") }
    public func requireExternalServices() throws {
        guard !isDevelopment else { throw RuntimeDataError.externalServicesDisabled }
    }
}

/// Development preferences stay in memory, without touching a real UserDefaults domain.
public final class StudioPreferences {
    private let defaults: UserDefaults?
    private var memory: [String: Any] = [:]
    public init(production: Bool) { defaults = production ? .standard : nil }
    public func data(forKey key: String) -> Data? { defaults?.data(forKey: key) ?? memory[key] as? Data }
    public func string(forKey key: String) -> String? { defaults?.string(forKey: key) ?? memory[key] as? String }
    public func object(forKey key: String) -> Any? { defaults?.object(forKey: key) ?? memory[key] }
    public func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    public func set(_ value: Any?, forKey key: String) {
        if let defaults { defaults.set(value, forKey: key) } else { memory[key] = value }
    }
}
