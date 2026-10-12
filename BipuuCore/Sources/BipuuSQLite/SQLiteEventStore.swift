import Foundation
import SQLite3
import BipuuCore

/// Durable `EventStore` on the system sqlite3. See docs/STORAGE.md.
///
/// One connection, owned by the actor (all access is serialised by actor isolation). Statements are
/// prepared once and cached. Every append is a single immediate transaction.
public actor SQLiteEventStore: EventStore {
    /// Physical database schema version (`PRAGMA user_version`). Unrelated to `AgentEvent.schemaVersion`.
    public static let supportedDatabaseVersion = SQLiteConnection.currentVersion

    private let conn: SQLiteConnection

    private static let columns = """
        event_id, schema_version, occurred_at_us, received_at_us, project_id, task_id, session_id, \
        agent_id, host_id, environment_id, event_kind, source, raw_json
        """

    /// Opens (creating and migrating if needed) the database at `path`.
    public init(path: String) throws {
        conn = try SQLiteConnection.open(path: path)
    }

    /// Releases the connection. Idempotent. Further use throws `.closed`.
    public func close() { conn.close() }

    // MARK: EventStore

    public func append(_ event: AgentEvent) throws -> AppendResult {
        let raw = try BipuuCoding.encoder().encode(event)
        return try conn.transaction { try insert(event, raw: raw) }
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
        try conn.run("""
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
        try conn.query(sql, binds) { try Self.decodeRow($0) }
    }

    /// Decodes the stored envelope and cross-checks every indexed column against it. A mismatch is
    /// an error, never a silent choice between the two copies.
    private static func decodeRow(_ s: OpaquePointer) throws -> AgentEvent {
        typealias C = SQLiteConnection
        let id = C.text(s, 0) ?? ""
        func bad(_ why: String) -> SQLiteStoreError { .corruptedEvent(id: id, reason: why) }
        guard let raw = C.blob(s, 12) else { throw bad("raw_json is empty") }
        let event: AgentEvent
        do { event = try BipuuCoding.decoder().decode(AgentEvent.self, from: raw) }
        catch { throw bad("raw_json does not decode: \(error)") }

        func expect<T: Equatable>(_ name: String, _ column: T, _ envelope: T) throws {
            if column != envelope { throw bad("column \(name) = \(column) but envelope says \(envelope)") }
        }
        try expect("event_id", id, event.id.rawValue)
        try expect("schema_version", Int(C.int(s, 1)), event.schemaVersion)
        try expect("occurred_at_us", C.int(s, 2), event.occurredAt.epochMicroseconds)
        try expect("received_at_us", C.int(s, 3), event.receivedAt.epochMicroseconds)
        try expect("project_id", C.text(s, 4), event.projectID?.rawValue)
        try expect("task_id", C.text(s, 5), event.taskID?.rawValue)
        try expect("session_id", C.text(s, 6), event.sessionID.rawValue)
        try expect("agent_id", C.text(s, 7), event.agentID?.rawValue)
        try expect("host_id", C.text(s, 8), event.hostID?.rawValue)
        try expect("environment_id", C.text(s, 9), event.environmentID?.rawValue)
        try expect("event_kind", C.text(s, 10), event.kind.rawValue)
        try expect("source", C.text(s, 11), event.source.adapter)
        return event
    }
}
