import Foundation
import Darwin

public struct ConnectionDiagnostic: Identifiable, Equatable, Sendable {
    public let id: String
    public let passed: Bool
    public let message: String
}

public enum ConnectionDiagnostics {
    /// Only version/help/auth-status commands. Never submits prompts or prints raw account output.
    public static func inspect(_ settings: AIConnectionSettings, hasAPIKey: Bool = false) async throws -> [ConnectionDiagnostic] {
        guard settings.provider.isCLI else {
            return [.init(id: "key", passed: hasAPIKey, message: hasAPIKey ? L("API key available. Use Test connection to verify account and model access.") : L("Save an API key in settings first."))]
        }
        guard let executable = CodexExecutable.resolve(override: settings.executablePath, name: settings.provider.executableName) else {
            return [.init(id: "executable", passed: false, message: L("CLI not found. Install it or choose its executable in settings."))]
        }
        let version = try await DiagnosticCommand.run(executable, ["--version"])
        var result = [ConnectionDiagnostic(id: "version", passed: version.status == 0,
            message: L("CLI version: {0}", versionNumber(version.text) ?? L("Unknown")))]
        let claude = settings.provider == .claudeCLI
        let help = try await DiagnosticCommand.run(executable, claude ? ["--help"] : ["exec", "--help"])
        let required = claude ? ["--safe-mode", "--no-session-persistence", "--json-schema", "--model"] : ["--ignore-user-config", "--ephemeral", "--output-schema", "--model"]
        let compatible = help.status == 0 && required.allSatisfy { help.text.contains($0) }
        result.append(.init(id: "compatibility", passed: compatible, message: L(compatible ? "Required CLI options are available." : "Update this CLI: required safety or output options are missing.")))
        let auth = try await DiagnosticCommand.run(executable, claude ? ["auth", "status", "--json"] : ["login", "status"])
        let loggedIn = authenticated(provider: settings.provider, status: auth.status, text: auth.text)
        result.append(.init(id: "login", passed: loggedIn, message: loggedIn ? L("CLI reports an active login. Model access is checked by Test connection.") : L("Sign in from Terminal using {0}, then diagnose again.", claude ? "claude auth login" : "codex login")))
        return result
    }
    static func versionNumber(_ text: String) -> String? {
        guard let range = text.range(of: #"\b[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}\b"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }
    static func authenticated(provider: AIConnectionKind, status: Int32, text: String) -> Bool {
        guard status == 0 else { return false }
        if provider == .claudeCLI {
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["loggedIn"] as? Bool == true
        }
        return text.lowercased().contains("logged in") && !text.lowercased().contains("not logged in")
    }
}

struct DiagnosticCommandResult: Sendable { let status: Int32; let text: String }

enum DiagnosticCommand {
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 10) async throws -> DiagnosticCommandResult {
        let cancellation = TranslationCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try execute(executable, arguments, timeout: timeout, cancellation: cancellation)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
    private static func execute(_ executable: URL, _ arguments: [String], timeout: TimeInterval, cancellation: TranslationCancellation) throws -> DiagnosticCommandResult {
        let fm = FileManager.default, folder = FileManager.default.temporaryDirectory.appendingPathComponent("SkillStudioDiagnostic-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: folder) }
        let url = folder.appendingPathComponent("result.txt")
        fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        process.currentDirectoryURL = folder; process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle; process.standardError = handle
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = executable.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        for key in ["CODEX_THREAD_ID", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"] { environment.removeValue(forKey: key) }
        process.environment = environment
        if cancellation.isCancelled { throw CancellationError() }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            let oversized = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 1_000_000
            if cancellation.isCancelled || Date() >= deadline || oversized {
                process.terminate()
                let stop = Date().addingTimeInterval(0.5)
                while process.isRunning && Date() < stop { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                if cancellation.isCancelled { throw CancellationError() }
                throw StudioError.message("CLI diagnostics timed out or exceeded the output limit. Check the executable in settings.")
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        process.waitUntilExit()
        if cancellation.isCancelled { throw CancellationError() }
        let reader = try FileHandle(forReadingFrom: url); defer { try? reader.close() }
        let data = try reader.read(upToCount: 1_000_001) ?? Data()
        guard data.count <= 1_000_000 else { throw StudioError.message("CLI diagnostic output exceeded the limit.") }
        return .init(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self))
    }
}
