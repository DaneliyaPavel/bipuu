import Foundation
import SQLite3
import BipuuCore

public enum SQLiteEventStoreError: Error, Equatable, CustomStringConvertible {
    /// The database was written by a newer Bipuu. Never opened, never modified, never downgraded.
    case unsupportedDatabaseVersion(found: Int, supported: Int)
    /// A stored row cannot be decoded, or its indexed columns disagree with its stored envelope.
    case corruptedEvent(id: String, reason: String)
    case closed
    case database(code: Int32, message: String)

    public var description: String {
        switch self {
        case .unsupportedDatabaseVersion(let f, let s): "database schema version \(f) is newer than supported \(s)"
        case .corruptedEvent(let id, let r): "corrupted event \(id): \(r)"
        case .closed: "store is closed"
        case .database(let c, let m): "sqlite error \(c): \(m)"
        }
    }
}

/// Durable `EventStore` on the system sqlite3. See docs/STORAGE.md.
///
/// One connection, owned by the actor (all access is serialised by actor isolation). Statements are
/// prepared once and cached. Every append is a single immediate transaction.
public actor SQLiteEventStore: EventStore {
    /// Physical database schema version (`PRAGMA user_version`). Unrelated to `AgentEvent.schemaVersion`.
    public static let supportedDatabaseVersion = 1

    /// Owns the raw connection so it is released even if the store is dropped without `close()`.
    /// Only ever touched from inside the actor.
    private final class Handle: @unchecked Sendable {
        var db: OpaquePointer?
        var statements: [String: OpaquePointer] = [:]
        init(db: OpaquePointer) { self.db = db }
        func close() {
            for s in statements.values { sqlite3_finalize(s) }
            statements = [:]
            if let db { sqlite3_close_v2(db) }
            db = nil
        }
        deinit { close() }
    }

    private let handle: Handle

    private static let columns = """
        event_id, schema_version, occurred_at_us, received_at_us, project_id, task_id, session_id, \
        agent_id, host_id, environment_id, event_kind, source, raw_json
        """

    /// Opens (creating and migrating if needed) the database at `path`.
    public init(path: String) throws {
        handle = Handle(db: try Self.open(path: path))
    }

    /// Releases the connection. Idempotent. Further use throws `.closed`.
    public func close() { handle.close() }

    // MARK: EventStore

    public func append(_ event: AgentEvent) throws -> AppendResult {
        let raw = try BipuuCoding.encoder().encode(event)
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try insert(event, raw: raw)
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public func events(forSession id: SessionID) throws -> [AgentEvent] {
        try select("SELECT \(Self.columns) FROM events WHERE session_id = ?1 ORDER BY occurred_at_us, received_at_us, event_id",
                   [.text(id.rawValue)])
    }

    public func events(forTask id: TaskID) throws -> [AgentEvent] {
        try select("SELECT \(Self.columns) FROM events WHERE task_id = ?1 ORDER BY occurred_at_us, received_at_us, event_id",
                   [.text(id.rawValue)])
    }

    public func recentEvents(limit: Int) throws -> [AgentEvent] {
        guard limit > 0 else { return [] }
        let newestFirst = try select("SELECT \(Self.columns) FROM events ORDER BY occurred_at_us DESC, received_at_us DESC, event_id DESC LIMIT ?1",
                                     [.int(Int64(limit))])
        return newestFirst.reversed()
    }

    // MARK: Insert

    private func insert(_ event: AgentEvent, raw: Data) throws -> AppendResult {
        let existing = try select("SELECT \(Self.columns) FROM events WHERE event_id = ?1", [.text(event.id.rawValue)])
        if let stored = existing.first {
            if stored == event { return .duplicate }
            throw EventStoreError.eventIDCollision(event.id)
        }
        _ = try step("""
            INSERT INTO events (\(Self.columns)) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
            """, [.text(event.id.rawValue), .int(Int64(event.schemaVersion)),
                  .int(event.occurredAt.epochMicroseconds), .int(event.receivedAt.epochMicroseconds),
                  .optText(event.projectID?.rawValue), .optText(event.taskID?.rawValue),
                  .text(event.sessionID.rawValue), .optText(event.agentID?.rawValue),
                  .optText(event.hostID?.rawValue), .optText(event.environmentID?.rawValue),
                  .text(event.kind.rawValue), .text(event.source.adapter), .blob(raw)])
        return .appended
    }

    // MARK: Reading rows

    private func select(_ sql: String, _ binds: [Bind]) throws -> [AgentEvent] {
        let stmt = try prepare(sql)
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        try bind(binds, to: stmt)
        var out: [AgentEvent] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return out }
            guard rc == SQLITE_ROW else { throw lastError(rc) }
            out.append(try Self.decodeRow(stmt))
        }
    }

    /// Decodes the stored envelope and cross-checks every indexed column against it. A mismatch is
    /// an error, never a silent choice between the two copies.
    private static func decodeRow(_ s: OpaquePointer) throws -> AgentEvent {
        let id = text(s, 0) ?? ""
        func bad(_ why: String) -> SQLiteEventStoreError { .corruptedEvent(id: id, reason: why) }
        guard let n = sqlite3_column_blob(s, 12) else { throw bad("raw_json is empty") }
        let raw = Data(bytes: n, count: Int(sqlite3_column_bytes(s, 12)))
        let event: AgentEvent
        do { event = try BipuuCoding.decoder().decode(AgentEvent.self, from: raw) }
        catch { throw bad("raw_json does not decode: \(error)") }

        func expect<T: Equatable>(_ name: String, _ column: T, _ envelope: T) throws {
            if column != envelope { throw bad("column \(name) = \(column) but envelope says \(envelope)") }
        }
        try expect("event_id", id, event.id.rawValue)
        try expect("schema_version", Int(sqlite3_column_int64(s, 1)), event.schemaVersion)
        try expect("occurred_at_us", sqlite3_column_int64(s, 2), event.occurredAt.epochMicroseconds)
        try expect("received_at_us", sqlite3_column_int64(s, 3), event.receivedAt.epochMicroseconds)
        try expect("project_id", text(s, 4), event.projectID?.rawValue)
        try expect("task_id", text(s, 5), event.taskID?.rawValue)
        try expect("session_id", text(s, 6), event.sessionID.rawValue)
        try expect("agent_id", text(s, 7), event.agentID?.rawValue)
        try expect("host_id", text(s, 8), event.hostID?.rawValue)
        try expect("environment_id", text(s, 9), event.environmentID?.rawValue)
        try expect("event_kind", text(s, 10), event.kind.rawValue)
        try expect("source", text(s, 11), event.source.adapter)
        return event
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        guard sqlite3_column_type(s, i) != SQLITE_NULL, let p = sqlite3_column_text(s, i) else { return nil }
        return String(cString: p)
    }

    // MARK: SQLite plumbing

    private enum Bind { case text(String), optText(String?), int(Int64), blob(Data) }

    private func connection() throws -> OpaquePointer {
        guard let db = handle.db else { throw SQLiteEventStoreError.closed }
        return db
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let s = handle.statements[sql] { return s }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(try connection(), sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw lastError(rc) }
        handle.statements[sql] = stmt
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
            guard rc == SQLITE_OK else { throw lastError(rc) }
        }
    }

    private func step(_ sql: String, _ binds: [Bind]) throws -> Int32 {
        let stmt = try prepare(sql)
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        try bind(binds, to: stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw lastError(rc) }
        return rc
    }

    private func exec(_ sql: String) throws {
        let rc = sqlite3_exec(try connection(), sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw lastError(rc) }
    }

    private func lastError(_ rc: Int32) -> SQLiteEventStoreError {
        Self.error(rc, handle.db)
    }

    private static func error(_ rc: Int32, _ db: OpaquePointer?) -> SQLiteEventStoreError {
        .database(code: rc, message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection")
    }

    // MARK: Open and migrate

    private static func open(path: String) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let db = handle else {
            let e = error(rc, handle); sqlite3_close_v2(handle); throw e
        }
        do {
            sqlite3_busy_timeout(db, 5_000)
            // Version gate first: a database from a newer build is left completely untouched.
            let found = try userVersion(db)
            guard found <= supportedDatabaseVersion else {
                throw SQLiteEventStoreError.unsupportedDatabaseVersion(found: found, supported: supportedDatabaseVersion)
            }
            try run(db, "PRAGMA journal_mode = WAL")
            try run(db, "PRAGMA synchronous = NORMAL")
            try run(db, "PRAGMA foreign_keys = ON")
            try migrate(db)
        } catch {
            sqlite3_close_v2(db)
            throw error
        }
        return db
    }

    private static func run(_ db: OpaquePointer, _ sql: String) throws {
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw error(rc, db) }
    }

    private static func userVersion(_ db: OpaquePointer) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else { throw error(sqlite3_errcode(db), db) }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw error(sqlite3_errcode(db), db) }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// v0 → v1 in one transaction: the tables, the indexes and the version bump commit together or not at all.
    private static func migrate(_ db: OpaquePointer) throws {
        try run(db, "BEGIN IMMEDIATE")
        do {
            let found = try userVersion(db)   // re-read under the write lock: another process may have migrated
            guard found <= supportedDatabaseVersion else {
                throw SQLiteEventStoreError.unsupportedDatabaseVersion(found: found, supported: supportedDatabaseVersion)
            }
            if found < 1 {
                try run(db, """
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
                    """)
                try run(db, "CREATE INDEX idx_events_session ON events (session_id, occurred_at_us, received_at_us, event_id)")
                try run(db, "CREATE INDEX idx_events_task ON events (task_id, occurred_at_us, received_at_us, event_id) WHERE task_id IS NOT NULL")
                try run(db, "CREATE INDEX idx_events_recent ON events (occurred_at_us, received_at_us, event_id)")
                try run(db, "PRAGMA user_version = 1")
            }
            try run(db, "COMMIT")
        } catch {
            try? run(db, "ROLLBACK")
            throw error
        }
    }
}
