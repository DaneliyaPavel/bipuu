import Foundation
import SQLite3
import BipuuCore

/// Durable `DomainStore` on the same database file as `SQLiteEventStore` (its own connection).
/// Each entity is stored as its full encoded JSON plus the columns needed for relations and
/// ordering; reads cross-check the two and throw `corruptedRecord` on any disagreement.
/// Relations are real foreign keys, and also checked before writing so errors name the missing entity.
public actor SQLiteDomainStore: DomainStore {
    private let conn: SQLiteConnection

    public init(path: String) throws { conn = try SQLiteConnection.open(path: path) }

    /// Releases the connection. Idempotent. Further use throws `.closed`.
    public func close() { conn.close() }

    // MARK: Save

    public func save(_ project: Project) throws {
        try upsert("INSERT INTO projects (project_id, created_at_us, raw_json) VALUES (?1, ?2, ?3) "
                   + "ON CONFLICT (project_id) DO UPDATE SET created_at_us = excluded.created_at_us, raw_json = excluded.raw_json",
                   [.text(project.id.rawValue), .int(project.createdAt.epochMicroseconds), try encode(project)])
    }

    public func save(_ agent: Agent) throws {
        try upsert("INSERT INTO agents (agent_id, raw_json) VALUES (?1, ?2) ON CONFLICT (agent_id) DO UPDATE SET raw_json = excluded.raw_json",
                   [.text(agent.id.rawValue), try encode(agent)])
    }

    public func save(_ host: BipuuCore.Host) throws {
        try upsert("INSERT INTO hosts (host_id, raw_json) VALUES (?1, ?2) ON CONFLICT (host_id) DO UPDATE SET raw_json = excluded.raw_json",
                   [.text(host.id.rawValue), try encode(host)])
    }

    public func save(_ environment: Environment) throws {
        try upsert("INSERT INTO environments (environment_id, raw_json) VALUES (?1, ?2) ON CONFLICT (environment_id) DO UPDATE SET raw_json = excluded.raw_json",
                   [.text(environment.id.rawValue), try encode(environment)])
    }

    public func save(_ task: WorkTask) throws {
        let raw = try encode(task)
        try conn.transaction {
            try require("projects", "project_id", task.projectID?.rawValue, entity: "project")
            try writeTask(task, raw: raw)
        }
    }

    public func save(_ session: Session) throws {
        let raw = try encode(session)
        try conn.transaction {
            try require("tasks", "task_id", session.taskID?.rawValue, entity: "task")
            try require("agents", "agent_id", session.agentID.rawValue, entity: "agent")
            try require("hosts", "host_id", session.hostID?.rawValue, entity: "host")
            try require("environments", "environment_id", session.environmentID?.rawValue, entity: "environment")
            try writeSession(session, raw: raw)
        }
    }

    // MARK: Get

    public func project(_ id: ProjectID) throws -> Project? {
        try conn.query("SELECT project_id, created_at_us, raw_json FROM projects WHERE project_id = ?1", [.text(id.rawValue)], Self.readProject).first
    }
    public func task(_ id: TaskID) throws -> WorkTask? {
        try conn.query("SELECT \(Self.taskColumns) FROM tasks WHERE task_id = ?1", [.text(id.rawValue)], Self.readTask).first
    }
    public func agent(_ id: AgentID) throws -> Agent? {
        try conn.query("SELECT agent_id, raw_json FROM agents WHERE agent_id = ?1", [.text(id.rawValue)]) { s in
            let a: Agent = try Self.decode(s, 1, kind: "agent", id: SQLiteConnection.text(s, 0))
            try Self.expect("agent", a.id.rawValue, "agent_id", SQLiteConnection.text(s, 0), a.id.rawValue)
            return a
        }.first
    }
    public func host(_ id: HostID) throws -> BipuuCore.Host? {
        try conn.query("SELECT host_id, raw_json FROM hosts WHERE host_id = ?1", [.text(id.rawValue)]) { s in
            let h: BipuuCore.Host = try Self.decode(s, 1, kind: "host", id: SQLiteConnection.text(s, 0))
            try Self.expect("host", h.id.rawValue, "host_id", SQLiteConnection.text(s, 0), h.id.rawValue)
            return h
        }.first
    }
    public func environment(_ id: EnvironmentID) throws -> Environment? {
        try conn.query("SELECT environment_id, raw_json FROM environments WHERE environment_id = ?1", [.text(id.rawValue)]) { s in
            let e: Environment = try Self.decode(s, 1, kind: "environment", id: SQLiteConnection.text(s, 0))
            try Self.expect("environment", e.id.rawValue, "environment_id", SQLiteConnection.text(s, 0), e.id.rawValue)
            return e
        }.first
    }
    public func session(_ id: SessionID) throws -> Session? {
        try conn.query("SELECT \(Self.sessionColumns) FROM sessions WHERE session_id = ?1", [.text(id.rawValue)], Self.readSession).first
    }

    // MARK: Lists

    public func projects() throws -> [Project] {
        try conn.query("SELECT project_id, created_at_us, raw_json FROM projects ORDER BY created_at_us, project_id", [], Self.readProject)
    }
    public func tasks(inProject id: ProjectID) throws -> [WorkTask] {
        try conn.query("SELECT \(Self.taskColumns) FROM tasks WHERE project_id = ?1 ORDER BY created_at_us, task_id", [.text(id.rawValue)], Self.readTask)
    }
    public func unassignedTasks() throws -> [WorkTask] {
        try conn.query("SELECT \(Self.taskColumns) FROM tasks WHERE project_id IS NULL ORDER BY created_at_us, task_id", [], Self.readTask)
    }
    public func sessions(forTask id: TaskID) throws -> [Session] {
        try conn.query("SELECT \(Self.sessionColumns) FROM sessions WHERE task_id = ?1 ORDER BY started_at_us, session_id", [.text(id.rawValue)], Self.readSession)
    }
    public func unattachedSessions() throws -> [Session] {
        try conn.query("SELECT \(Self.sessionColumns) FROM sessions WHERE task_id IS NULL ORDER BY started_at_us, session_id", [], Self.readSession)
    }

    // MARK: Operations

    public func assign(session id: SessionID, to task: TaskID?) throws {
        try conn.transaction {
            guard var s = try conn.query("SELECT \(Self.sessionColumns) FROM sessions WHERE session_id = ?1", [.text(id.rawValue)], Self.readSession).first else {
                throw DomainStoreError.notFound(entity: "session", id: id.rawValue)
            }
            try require("tasks", "task_id", task?.rawValue, entity: "task")
            s.taskID = task
            try writeSession(s, raw: try encode(s))
        }
    }

    public func move(task id: TaskID, to project: ProjectID?, at: Date) throws {
        try conn.transaction {
            guard var t = try conn.query("SELECT \(Self.taskColumns) FROM tasks WHERE task_id = ?1", [.text(id.rawValue)], Self.readTask).first else {
                throw DomainStoreError.notFound(entity: "task", id: id.rawValue)
            }
            try require("projects", "project_id", project?.rawValue, entity: "project")
            t.projectID = project
            t.updatedAt = at
            try writeTask(t, raw: try encode(t))
        }
    }

    // MARK: Writing

    private func upsert(_ sql: String, _ binds: [Bind]) throws {
        try conn.transaction { try conn.run(sql, binds) }
    }

    private func writeTask(_ t: WorkTask, raw: Bind) throws {
        try conn.run("INSERT INTO tasks (task_id, project_id, status, created_at_us, raw_json) VALUES (?1, ?2, ?3, ?4, ?5) "
                     + "ON CONFLICT (task_id) DO UPDATE SET project_id = excluded.project_id, status = excluded.status, "
                     + "created_at_us = excluded.created_at_us, raw_json = excluded.raw_json",
                     [.text(t.id.rawValue), .optText(t.projectID?.rawValue), .text(t.status.rawValue),
                      .int(t.createdAt.epochMicroseconds), raw])
    }

    private func writeSession(_ s: Session, raw: Bind) throws {
        try conn.run("INSERT INTO sessions (session_id, task_id, agent_id, host_id, environment_id, started_at_us, raw_json) "
                     + "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) ON CONFLICT (session_id) DO UPDATE SET task_id = excluded.task_id, "
                     + "agent_id = excluded.agent_id, host_id = excluded.host_id, environment_id = excluded.environment_id, "
                     + "started_at_us = excluded.started_at_us, raw_json = excluded.raw_json",
                     [.text(s.id.rawValue), .optText(s.taskID?.rawValue), .text(s.agentID.rawValue),
                      .optText(s.hostID?.rawValue), .optText(s.environmentID?.rawValue),
                      .int(s.startedAt.epochMicroseconds), raw])
    }

    /// Throws `missingReference` if `id` is non-nil and not present in `table`.
    private func require(_ table: String, _ column: String, _ id: String?, entity: String) throws {
        guard let id else { return }
        guard try conn.exists("SELECT 1 FROM \(table) WHERE \(column) = ?1", [.text(id)]) else {
            throw DomainStoreError.missingReference(entity: entity, id: id)
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Bind { .blob(try BipuuCoding.encoder().encode(value)) }

    // MARK: Reading

    private static let taskColumns = "task_id, project_id, status, created_at_us, raw_json"
    private static let sessionColumns = "session_id, task_id, agent_id, host_id, environment_id, started_at_us, raw_json"

    private static func decode<T: Decodable>(_ s: OpaquePointer, _ rawColumn: Int32, kind: String, id: String?) throws -> T {
        guard let raw = SQLiteConnection.blob(s, rawColumn) else {
            throw SQLiteStoreError.corruptedRecord(kind: kind, id: id ?? "?", reason: "raw_json is empty")
        }
        do { return try BipuuCoding.decoder().decode(T.self, from: raw) }
        catch { throw SQLiteStoreError.corruptedRecord(kind: kind, id: id ?? "?", reason: "raw_json does not decode: \(error)") }
    }

    private static func expect<T: Equatable>(_ kind: String, _ id: String, _ column: String, _ stored: T, _ envelope: T) throws {
        if stored != envelope {
            throw SQLiteStoreError.corruptedRecord(kind: kind, id: id, reason: "column \(column) = \(stored) but stored record says \(envelope)")
        }
    }

    private static func readProject(_ s: OpaquePointer) throws -> Project {
        let id = SQLiteConnection.text(s, 0)
        let p: Project = try decode(s, 2, kind: "project", id: id)
        try expect("project", p.id.rawValue, "project_id", id, p.id.rawValue)
        try expect("project", p.id.rawValue, "created_at_us", SQLiteConnection.int(s, 1), p.createdAt.epochMicroseconds)
        return p
    }

    private static func readTask(_ s: OpaquePointer) throws -> WorkTask {
        let id = SQLiteConnection.text(s, 0)
        let t: WorkTask = try decode(s, 4, kind: "task", id: id)
        let k = t.id.rawValue
        try expect("task", k, "task_id", id, k)
        try expect("task", k, "project_id", SQLiteConnection.text(s, 1), t.projectID?.rawValue)
        try expect("task", k, "status", SQLiteConnection.text(s, 2), t.status.rawValue)
        try expect("task", k, "created_at_us", SQLiteConnection.int(s, 3), t.createdAt.epochMicroseconds)
        return t
    }

    private static func readSession(_ s: OpaquePointer) throws -> Session {
        let id = SQLiteConnection.text(s, 0)
        let v: Session = try decode(s, 6, kind: "session", id: id)
        let k = v.id.rawValue
        try expect("session", k, "session_id", id, k)
        try expect("session", k, "task_id", SQLiteConnection.text(s, 1), v.taskID?.rawValue)
        try expect("session", k, "agent_id", SQLiteConnection.text(s, 2), v.agentID.rawValue)
        try expect("session", k, "host_id", SQLiteConnection.text(s, 3), v.hostID?.rawValue)
        try expect("session", k, "environment_id", SQLiteConnection.text(s, 4), v.environmentID?.rawValue)
        try expect("session", k, "started_at_us", SQLiteConnection.int(s, 5), v.startedAt.epochMicroseconds)
        return v
    }
}
