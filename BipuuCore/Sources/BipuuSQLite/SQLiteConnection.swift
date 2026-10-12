import Foundation
import SQLite3

public enum SQLiteStoreError: Error, Equatable, CustomStringConvertible {
    /// The database was written by a newer Bipuu. Never opened for writing, never modified, never downgraded.
    case unsupportedDatabaseVersion(found: Int, supported: Int)
    /// A stored event cannot be decoded, or its indexed columns disagree with its stored envelope.
    case corruptedEvent(id: String, reason: String)
    /// Same, for a Project / Task / Agent / Host / Environment / Session row.
    case corruptedRecord(kind: String, id: String, reason: String)
    case closed
    case database(code: Int32, message: String)

    public var description: String {
        switch self {
        case .unsupportedDatabaseVersion(let f, let s): "database schema version \(f) is newer than supported \(s)"
        case .corruptedEvent(let id, let r): "corrupted event \(id): \(r)"
        case .corruptedRecord(let k, let id, let r): "corrupted \(k) \(id): \(r)"
        case .closed: "store is closed"
        case .database(let c, let m): "sqlite error \(c): \(m)"
        }
    }
}
/// Name used in Slice 2; the same type now serves every SQLite store.
public typealias SQLiteEventStoreError = SQLiteStoreError

enum Bind { case text(String), optText(String?), int(Int64), blob(Data) }

/// One sqlite3 connection plus its prepared-statement cache. Not thread-safe by itself: each
/// store owns one and touches it only from inside its actor. Closed on `close()` or deinit.
final class SQLiteConnection: @unchecked Sendable {
    /// Physical database schema version (`PRAGMA user_version`) this build reads and writes.
    static let currentVersion = 2

    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    private init(db: OpaquePointer) { self.db = db }
    deinit { close() }

    func close() {
        for s in statements.values { sqlite3_finalize(s) }
        statements = [:]
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    // MARK: Statements

    private func handle() throws -> OpaquePointer {
        guard let db else { throw SQLiteStoreError.closed }
        return db
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let s = statements[sql] { return s }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(try handle(), sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw Self.error(rc, db) }
        statements[sql] = stmt
        return stmt
    }

    private func bind(_ binds: [Bind], to stmt: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch b {
            case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, transient)
            case .optText(let v): rc = v.map { sqlite3_bind_text(stmt, idx, $0, -1, transient) } ?? sqlite3_bind_null(stmt, idx)
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .blob(let d): rc = d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32($0.count), transient) }
            }
            guard rc == SQLITE_OK else { throw Self.error(rc, db) }
        }
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ binds: [Bind] = []) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        try bind(binds, to: stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw Self.error(rc, db) }
    }

    /// Rows changed by the most recent statement.
    func changes() throws -> Int { Int(sqlite3_changes(try handle())) }

    /// Merges the write-ahead log back into the database and truncates it. Best effort.
    func checkpointTruncate() { try? exec("PRAGMA wal_checkpoint(TRUNCATE)") }

    /// Runs a query and maps each row.
    func query<T>(_ sql: String, _ binds: [Bind] = [], _ row: (OpaquePointer) throws -> T) throws -> [T] {
        let stmt = try prepare(sql)
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        try bind(binds, to: stmt)
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return out }
            guard rc == SQLITE_ROW else { throw Self.error(rc, db) }
            out.append(try row(stmt))
        }
    }

    func exists(_ sql: String, _ binds: [Bind]) throws -> Bool {
        try !query(sql, binds) { _ in 1 }.isEmpty
    }

    /// One immediate transaction: commits if `body` returns, rolls back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func exec(_ sql: String) throws {
        let rc = sqlite3_exec(try handle(), sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw Self.error(rc, db) }
    }

    // MARK: Column readers

    static func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        guard sqlite3_column_type(s, i) != SQLITE_NULL, let p = sqlite3_column_text(s, i) else { return nil }
        return String(cString: p)
    }
    static func blob(_ s: OpaquePointer, _ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(s, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(s, i)))
    }
    static func int(_ s: OpaquePointer, _ i: Int32) -> Int64 { sqlite3_column_int64(s, i) }

    static func error(_ rc: Int32, _ db: OpaquePointer?) -> SQLiteStoreError {
        .database(code: rc, message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection")
    }

    // MARK: Open and migrate

    static func open(path: String) throws -> SQLiteConnection {
        var raw: OpaquePointer?
        let rc = sqlite3_open_v2(path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let db = raw else {
            let e = error(rc, raw); sqlite3_close_v2(raw); throw e
        }
        let conn = SQLiteConnection(db: db)   // owns the handle from here on, closes it on any failure
        sqlite3_busy_timeout(db, 5_000)
        // Version gate first: a database from a newer build is left completely untouched.
        let found = try userVersion(db)
        guard found <= currentVersion else {
            throw SQLiteStoreError.unsupportedDatabaseVersion(found: found, supported: currentVersion)
        }
        try conn.exec("PRAGMA journal_mode = WAL")
        try conn.exec("PRAGMA synchronous = NORMAL")
        try conn.exec("PRAGMA foreign_keys = ON")
        try conn.migrate()
        return conn
    }

    private static func userVersion(_ db: OpaquePointer) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else { throw error(sqlite3_errcode(db), db) }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw error(sqlite3_errcode(db), db) }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Each step runs inside one transaction together with the version bump: all of it or none of it.
    /// Re-reads the version under the write lock, since another process may have migrated meanwhile.
    private func migrate() throws {
        try transaction {
            let found = try Self.userVersion(try handle())
            guard found <= Self.currentVersion else {
                throw SQLiteStoreError.unsupportedDatabaseVersion(found: found, supported: Self.currentVersion)
            }
            for step in Self.migrations where found < step.to {
                for statement in step.statements { try exec(statement) }
                try exec("PRAGMA user_version = \(step.to)")
            }
        }
    }

    private static let migrations: [(to: Int, statements: [String])] = [
        (1, [
            """
            CREATE TABLE events (
                event_id        TEXT PRIMARY KEY NOT NULL,
                schema_version  INTEGER NOT NULL,
                occurred_at_us  INTEGER NOT NULL,
                received_at_us  INTEGER NOT NULL,
                project_id      TEXT,
                task_id         TEXT,
                session_id      TEXT NOT NULL,
                agent_id        TEXT,
                host_id         TEXT,
                environment_id  TEXT,
                event_kind      TEXT NOT NULL,
                source          TEXT NOT NULL,
                raw_json        BLOB NOT NULL
            )
            """,
            "CREATE INDEX idx_events_session ON events (session_id, occurred_at_us, received_at_us, event_id)",
            "CREATE INDEX idx_events_task ON events (task_id, occurred_at_us, received_at_us, event_id) WHERE task_id IS NOT NULL",
            "CREATE INDEX idx_events_recent ON events (occurred_at_us, received_at_us, event_id)",
        ]),
        (2, [
            "CREATE TABLE projects (project_id TEXT PRIMARY KEY NOT NULL, created_at_us INTEGER NOT NULL, raw_json BLOB NOT NULL)",
            "CREATE TABLE agents (agent_id TEXT PRIMARY KEY NOT NULL, raw_json BLOB NOT NULL)",
            "CREATE TABLE hosts (host_id TEXT PRIMARY KEY NOT NULL, raw_json BLOB NOT NULL)",
            "CREATE TABLE environments (environment_id TEXT PRIMARY KEY NOT NULL, raw_json BLOB NOT NULL)",
            """
            CREATE TABLE tasks (
                task_id        TEXT PRIMARY KEY NOT NULL,
                project_id     TEXT REFERENCES projects (project_id),
                status         TEXT NOT NULL,
                created_at_us  INTEGER NOT NULL,
                raw_json       BLOB NOT NULL
            )
            """,
            "CREATE INDEX idx_tasks_project ON tasks (project_id, created_at_us, task_id) WHERE project_id IS NOT NULL",
            """
            CREATE TABLE sessions (
                session_id      TEXT PRIMARY KEY NOT NULL,
                task_id         TEXT REFERENCES tasks (task_id),
                agent_id        TEXT NOT NULL REFERENCES agents (agent_id),
                host_id         TEXT REFERENCES hosts (host_id),
                environment_id  TEXT REFERENCES environments (environment_id),
                started_at_us   INTEGER NOT NULL,
                raw_json        BLOB NOT NULL
            )
            """,
            "CREATE INDEX idx_sessions_task ON sessions (task_id, started_at_us, session_id) WHERE task_id IS NOT NULL",
        ]),
    ]
}
