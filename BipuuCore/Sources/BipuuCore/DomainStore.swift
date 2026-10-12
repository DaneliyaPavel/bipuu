import Foundation

public enum DomainStoreError: Error, Equatable, Sendable {
    /// The entity to operate on does not exist.
    case notFound(entity: String, id: String)
    /// A reference points at an entity that is not stored. Nothing was written.
    case missingReference(entity: String, id: String)
}

/// Current state of the durable entities. Events are the history (`EventStore`); this is the
/// present: which projects, tasks and sessions exist and how they are connected.
///
/// Rules every implementation follows:
/// - `save` is an upsert of the whole entity.
/// - References are checked on write. A `Task.projectID`, `Session.taskID`, `.agentID`, `.hostID`
///   or `.environmentID` that names a missing entity throws `missingReference` and writes nothing.
/// - Parents hold no child lists: relations live on the child, so moving work is one field update.
/// - Lists are ordered by creation/start time (whole microseconds), then id (UTF-8 byte order).
/// - No deletes yet: nothing is removed by this slice.
public protocol DomainStore: Sendable {
    func save(_ project: Project) async throws
    func save(_ task: WorkTask) async throws
    func save(_ agent: Agent) async throws
    func save(_ host: Host) async throws
    func save(_ environment: Environment) async throws
    func save(_ session: Session) async throws

    func project(_ id: ProjectID) async throws -> Project?
    func task(_ id: TaskID) async throws -> WorkTask?
    func agent(_ id: AgentID) async throws -> Agent?
    func host(_ id: HostID) async throws -> Host?
    func environment(_ id: EnvironmentID) async throws -> Environment?
    func session(_ id: SessionID) async throws -> Session?

    func projects() async throws -> [Project]
    func tasks(inProject id: ProjectID) async throws -> [WorkTask]
    /// Tasks that belong to no project yet.
    func unassignedTasks() async throws -> [WorkTask]
    func sessions(forTask id: TaskID) async throws -> [Session]
    /// Sessions that belong to no task (yet).
    func unattachedSessions() async throws -> [Session]

    /// Points the session at `task`, or detaches it with `nil`. History is untouched.
    func assign(session id: SessionID, to task: TaskID?) async throws
    /// Moves the task to `project` (or out of any project with `nil`) and stamps `updatedAt`.
    func move(task id: TaskID, to project: ProjectID?, at: Date) async throws
}

/// Reference implementation and executable spec for `DomainStore`.
public actor InMemoryDomainStore: DomainStore {
    private var projectsByID: [ProjectID: Project] = [:]
    private var tasksByID: [TaskID: WorkTask] = [:]
    private var agentsByID: [AgentID: Agent] = [:]
    private var hostsByID: [HostID: Host] = [:]
    private var environmentsByID: [EnvironmentID: Environment] = [:]
    private var sessionsByID: [SessionID: Session] = [:]

    public init() {}

    public func save(_ project: Project) { projectsByID[project.id] = project }
    public func save(_ agent: Agent) { agentsByID[agent.id] = agent }
    public func save(_ host: Host) { hostsByID[host.id] = host }
    public func save(_ environment: Environment) { environmentsByID[environment.id] = environment }

    public func save(_ task: WorkTask) throws {
        try requireProject(task.projectID)
        tasksByID[task.id] = task
    }

    public func save(_ session: Session) throws {
        try requireTask(session.taskID)
        guard agentsByID[session.agentID] != nil else {
            throw DomainStoreError.missingReference(entity: "agent", id: session.agentID.rawValue)
        }
        if let h = session.hostID, hostsByID[h] == nil {
            throw DomainStoreError.missingReference(entity: "host", id: h.rawValue)
        }
        if let e = session.environmentID, environmentsByID[e] == nil {
            throw DomainStoreError.missingReference(entity: "environment", id: e.rawValue)
        }
        sessionsByID[session.id] = session
    }

    public func project(_ id: ProjectID) -> Project? { projectsByID[id] }
    public func task(_ id: TaskID) -> WorkTask? { tasksByID[id] }
    public func agent(_ id: AgentID) -> Agent? { agentsByID[id] }
    public func host(_ id: HostID) -> Host? { hostsByID[id] }
    public func environment(_ id: EnvironmentID) -> Environment? { environmentsByID[id] }
    public func session(_ id: SessionID) -> Session? { sessionsByID[id] }

    public func projects() -> [Project] {
        projectsByID.values.sorted { order($0.createdAt, $0.id, $1.createdAt, $1.id) }
    }
    public func tasks(inProject id: ProjectID) -> [WorkTask] {
        tasksByID.values.filter { $0.projectID == id }.sorted { order($0.createdAt, $0.id, $1.createdAt, $1.id) }
    }
    public func unassignedTasks() -> [WorkTask] {
        tasksByID.values.filter { $0.projectID == nil }.sorted { order($0.createdAt, $0.id, $1.createdAt, $1.id) }
    }
    public func sessions(forTask id: TaskID) -> [Session] {
        sessionsByID.values.filter { $0.taskID == id }.sorted { order($0.startedAt, $0.id, $1.startedAt, $1.id) }
    }
    public func unattachedSessions() -> [Session] {
        sessionsByID.values.filter { $0.taskID == nil }.sorted { order($0.startedAt, $0.id, $1.startedAt, $1.id) }
    }

    public func assign(session id: SessionID, to task: TaskID?) throws {
        guard var s = sessionsByID[id] else { throw DomainStoreError.notFound(entity: "session", id: id.rawValue) }
        try requireTask(task)
        s.taskID = task
        sessionsByID[id] = s
    }

    public func move(task id: TaskID, to project: ProjectID?, at: Date) throws {
        guard var t = tasksByID[id] else { throw DomainStoreError.notFound(entity: "task", id: id.rawValue) }
        try requireProject(project)
        t.projectID = project
        t.updatedAt = at
        tasksByID[id] = t
    }

    private func requireProject(_ id: ProjectID?) throws {
        if let id, projectsByID[id] == nil { throw DomainStoreError.missingReference(entity: "project", id: id.rawValue) }
    }
    private func requireTask(_ id: TaskID?) throws {
        if let id, tasksByID[id] == nil { throw DomainStoreError.missingReference(entity: "task", id: id.rawValue) }
    }
    private func order<I: Comparable>(_ at: Date, _ ai: I, _ bt: Date, _ bi: I) -> Bool {
        let (a, b) = (at.epochMicroseconds, bt.epochMicroseconds)
        return a != b ? a < b : ai < bi
    }
}
