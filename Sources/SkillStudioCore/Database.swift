import Foundation
import CSQLite

/// Access from one executor (StudioStore uses the main actor). Writes are atomic SQLite transactions.
public final class StudioDatabase {
    private var handle: OpaquePointer?
    public let url: URL
    private var lastPayload: Data?
    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
            if let handle { sqlite3_close(handle) }; handle = nil
            throw StudioError.message(message)
        }
        do {
            sqlite3_busy_timeout(handle, 5000)
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA foreign_keys = ON")
            let version = try schemaVersion()
            guard version <= 1 else { throw StudioError.message("This library was created by a newer app. Update Attune.") }
            try execute("CREATE TABLE IF NOT EXISTS library (id INTEGER PRIMARY KEY CHECK (id = 1), payload BLOB NOT NULL)")
            try execute("PRAGMA user_version = 1")
            lastPayload = try payload()
        } catch { sqlite3_close(handle); handle = nil; throw error }
    }
    deinit { sqlite3_close(handle) }
    private func schemaVersion() throws -> Int32 {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int(statement, 0)
    }
    private func failure() -> StudioError { .message(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Database closed") }
    private func check(_ result: Int32) throws { guard result == SQLITE_OK else { throw failure() } }
    private func execute(_ sql: String) throws { try check(sqlite3_exec(handle, sql, nil, nil, nil)) }
    public func load() throws -> LibrarySnapshot {
        let data = try payload()
        lastPayload = data
        let snapshot = try data.map { try JSONDecoder().decode(LibrarySnapshot.self, from: $0) } ?? LibrarySnapshot()
        try LibraryBackup.validate(snapshot)
        return snapshot
    }
    private func payload() throws -> Data? {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, "SELECT payload FROM library WHERE id = 1", -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        return data
    }
    public func save(_ snapshot: LibrarySnapshot) throws {
        try LibraryBackup.validate(snapshot)
        let data = try JSONEncoder().encode(snapshot)
        try execute("BEGIN IMMEDIATE")
        do {
            guard try payload() == lastPayload else { throw StudioError.message("The library changed in another process. Restart before saving.") }
            var statement: OpaquePointer?
            try check(sqlite3_prepare_v2(handle, "INSERT INTO library(id, payload) VALUES(1, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload", -1, &statement, nil))
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            try data.withUnsafeBytes { buffer in try check(sqlite3_bind_blob(statement, 1, buffer.baseAddress, Int32(buffer.count), transient)) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            try execute("COMMIT")
            lastPayload = data
        } catch { try? execute("ROLLBACK"); throw error }
    }
}
