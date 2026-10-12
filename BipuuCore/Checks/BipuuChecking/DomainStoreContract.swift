import Foundation
import BipuuCore

/// The behaviour every `DomainStore` must have. Run against each implementation with a factory
/// that returns a fresh, empty store.
public enum DomainStoreContract {
    public typealias Make = @Sendable () async throws -> any DomainStore

    static func at(_ s: Double) -> Date { Date(timeIntervalSince1970: s) }

    /// A project, an agent, a host and an environment, saved. Sessions need the last three.
    static func base(_ store: any DomainStore) async throws -> (Project, Agent, BipuuCore.Host, Environment) {
        let p = Project(id: ProjectID("p1"), name: "P", roots: ["/r"], createdAt: at(1))
        let a = Agent(id: AgentID("a1"), kind: "assistant-a", displayName: "A", capabilities: ["approvals"])
        let h = BipuuCore.Host(id: HostID("h1"), kind: .terminal, identity: "term.example", displayName: "T")
        let e = Environment(id: EnvironmentID("e1"), kind: "lab-bench", name: "Bench", attributes: ["k": "v"])
        try await store.save(p); try await store.save(a); try await store.save(h); try await store.save(e)
        return (p, a, h, e)
    }

    public static func runAll(_ label: String, make: @escaping Make) async {
        await run("\(label): empty store") {
            let s = try await make()
            try await check(try await s.project(ProjectID("x")) == nil)
            try await check(try await s.task(TaskID("x")) == nil)
            try await check(try await s.session(SessionID("x")) == nil)
            try await check(try await s.agent(AgentID("x")) == nil)
            try await check(try await s.host(HostID("x")) == nil)
            try await check(try await s.environment(EnvironmentID("x")) == nil)
            try await check(try await s.projects().isEmpty)
            try await check(try await s.unassignedTasks().isEmpty)
            try await check(try await s.unattachedSessions().isEmpty)
        }
        await run("\(label): every entity round-trips with all fields") {
            let s = try await make()
            let (p, a, h, e) = try await base(s)
            let t = WorkTask(id: TaskID("t1"), projectID: p.id, title: "T é✓", origin: .inferred, status: .completed,
                             createdAt: at(2.123456), updatedAt: at(3))
            try await s.save(t)
            let sess = Session(id: SessionID("s1"), taskID: t.id, agentID: a.id, hostID: h.id, environmentID: e.id,
                               workingDirectory: "/r", externalRef: "ext", startedAt: at(4), endedAt: at(5))
            try await s.save(sess)
            try await check(try await s.project(p.id) == p)
            try await check(try await s.agent(a.id) == a)
            try await check(try await s.host(h.id) == h)
            try await check(try await s.environment(e.id) == e)
            try await check(try await s.task(t.id) == t)
            try await check(try await s.session(sess.id) == sess)
        }
        await run("\(label): save is an upsert of the whole entity") {
            let s = try await make()
            let (p, a, _, _) = try await base(s)
            var renamed = p; renamed.name = "Renamed"; renamed.roots = []
            try await s.save(renamed)
            try await check(try await s.project(p.id) == renamed)
            try await check(try await s.projects().count == 1)
            var sess = Session(id: SessionID("s"), agentID: a.id, startedAt: at(1))
            try await s.save(sess)
            sess.endedAt = at(9); sess.externalRef = "later"
            try await s.save(sess)
            try await check(try await s.session(sess.id) == sess)
        }
        await run("\(label): references are checked; a rejected write changes nothing") {
            let s = try await make()
            let (p, a, h, e) = try await base(s)
            let t = WorkTask(id: TaskID("t"), projectID: p.id, title: "T", createdAt: at(1))
            try await s.save(t)
            try await checkThrows(DomainStoreError.missingReference(entity: "project", id: "nope")) {
                try await s.save(WorkTask(id: TaskID("bad"), projectID: ProjectID("nope"), title: "x", createdAt: at(1)))
            }
            try await check(try await s.task(TaskID("bad")) == nil)
            func session(_ id: String, task: String? = nil, agent: AgentID? = nil, host: String? = nil, env: String? = nil) -> Session {
                Session(id: SessionID(id), taskID: task.map { TaskID($0) }, agentID: agent ?? a.id,
                        hostID: host.map { HostID($0) }, environmentID: env.map { EnvironmentID($0) }, startedAt: at(1))
            }
            try await checkThrows(DomainStoreError.missingReference(entity: "task", id: "nope")) { try await s.save(session("s1", task: "nope")) }
            try await checkThrows(DomainStoreError.missingReference(entity: "agent", id: "nope")) { try await s.save(session("s2", agent: AgentID("nope"))) }
            try await checkThrows(DomainStoreError.missingReference(entity: "host", id: "nope")) { try await s.save(session("s3", host: "nope")) }
            try await checkThrows(DomainStoreError.missingReference(entity: "environment", id: "nope")) { try await s.save(session("s4", env: "nope")) }
            for id in ["s1", "s2", "s3", "s4"] { try await check(try await s.session(SessionID(id)) == nil) }
            // A valid reference to each kind is accepted.
            try await s.save(session("ok", task: t.id.rawValue, host: h.id.rawValue, env: e.id.rawValue))
            try await check(try await s.session(SessionID("ok")) != nil)
            // A rejected update of an existing entity leaves the stored version intact.
            var moved = t; moved.projectID = ProjectID("nope"); moved.title = "changed"
            try await checkThrows(DomainStoreError.missingReference(entity: "project", id: "nope")) { try await s.save(moved) }
            try await check(try await s.task(t.id) == t)
        }
        await run("\(label): Project -> Task -> many Sessions; Task and Session are different things") {
            let s = try await make()
            let (p, a, h, e) = try await base(s)
            let a2 = Agent(id: AgentID("a2"), kind: "assistant-b", displayName: "B")
            try await s.save(a2)
            let t = WorkTask(id: TaskID("same"), projectID: p.id, title: "T", createdAt: at(1))
            try await s.save(t)
            // A session may share its id text with a task: they are separate namespaces.
            let s1 = Session(id: SessionID("same"), taskID: t.id, agentID: a.id, hostID: h.id, environmentID: e.id, startedAt: at(2))
            let s2 = Session(id: SessionID("s2"), taskID: t.id, agentID: a2.id, startedAt: at(3))
            try await s.save(s1); try await s.save(s2)
            try await check(try await s.sessions(forTask: t.id) == [s1, s2])
            try await check(try await s.task(TaskID("same"))?.title == "T")
            try await check(try await s.session(SessionID("same"))?.agentID == a.id)
            // The same agent works in different hosts/environments without any link between them.
            try await check(s1.agentID != s2.agentID && s1.hostID != s2.hostID)
        }
        await run("\(label): lists are filtered and ordered (time in microseconds, then id)") {
            let s = try await make()
            let (p, a, _, _) = try await base(s)
            let p2 = Project(id: ProjectID("p0"), name: "Q", createdAt: at(1))   // same time as p1: id decides
            try await s.save(p2)
            try await check(try await s.projects().map(\.id.rawValue) == ["p0", "p1"])
            for (id, time, project) in [("b", 5.0, "p1"), ("a", 5.0, "p1"), ("c", 1.0, "p1"), ("u2", 9.0, ""), ("u1", 2.0, ""), ("x", 3.0, "p0")] {
                try await s.save(WorkTask(id: TaskID(id), projectID: project.isEmpty ? nil : ProjectID(project), title: id, createdAt: at(time)))
            }
            try await check(try await s.tasks(inProject: p.id).map(\.id.rawValue) == ["c", "a", "b"])
            try await check(try await s.tasks(inProject: ProjectID("p0")).map(\.id.rawValue) == ["x"])
            try await check(try await s.unassignedTasks().map(\.id.rawValue) == ["u1", "u2"])
            for (id, time, task) in [("s3", 3.0, "a"), ("s1", 1.0, "a"), ("s2", 1.0, "a"), ("lone2", 8.0, ""), ("lone1", 4.0, "")] {
                try await s.save(Session(id: SessionID(id), taskID: task.isEmpty ? nil : TaskID(task), agentID: a.id, startedAt: at(time)))
            }
            try await check(try await s.sessions(forTask: TaskID("a")).map(\.id.rawValue) == ["s1", "s2", "s3"])
            try await check(try await s.unattachedSessions().map(\.id.rawValue) == ["lone1", "lone2"])
            try await check(try await s.sessions(forTask: TaskID("none")).isEmpty)
        }
        await run("\(label): a session can be reassigned and detached; history is not involved") {
            let s = try await make()
            let (p, a, _, _) = try await base(s)
            for id in ["t1", "t2"] { try await s.save(WorkTask(id: TaskID(id), projectID: p.id, title: id, createdAt: at(1))) }
            try await s.save(Session(id: SessionID("s"), taskID: TaskID("t1"), agentID: a.id, workingDirectory: "/w", startedAt: at(1)))
            try await s.assign(session: SessionID("s"), to: TaskID("t2"))
            try await check(try await s.sessions(forTask: TaskID("t1")).isEmpty)
            try await check(try await s.sessions(forTask: TaskID("t2")).map(\.id.rawValue) == ["s"])
            try await check(try await s.session(SessionID("s"))?.workingDirectory == "/w")   // other fields untouched
            try await s.assign(session: SessionID("s"), to: nil)
            try await check(try await s.unattachedSessions().map(\.id.rawValue) == ["s"])
            try await checkThrows(DomainStoreError.notFound(entity: "session", id: "ghost")) { try await s.assign(session: SessionID("ghost"), to: TaskID("t1")) }
            try await checkThrows(DomainStoreError.missingReference(entity: "task", id: "ghost")) { try await s.assign(session: SessionID("s"), to: TaskID("ghost")) }
            try await check(try await s.session(SessionID("s"))?.taskID == nil)   // unchanged by the failed call
        }
        await run("\(label): a task can move between projects; its sessions stay attached") {
            let s = try await make()
            let (p, a, _, _) = try await base(s)
            try await s.save(Project(id: ProjectID("p2"), name: "Two", createdAt: at(2)))
            try await s.save(WorkTask(id: TaskID("t"), projectID: p.id, title: "T", createdAt: at(1), updatedAt: at(1)))
            try await s.save(Session(id: SessionID("s"), taskID: TaskID("t"), agentID: a.id, startedAt: at(1)))
            try await s.move(task: TaskID("t"), to: ProjectID("p2"), at: at(50))
            try await check(try await s.tasks(inProject: p.id).isEmpty)
            let moved = try await s.task(TaskID("t"))
            try await check(moved?.projectID == ProjectID("p2") && moved?.updatedAt == at(50) && moved?.createdAt == at(1))
            try await check(try await s.sessions(forTask: TaskID("t")).count == 1)
            try await s.move(task: TaskID("t"), to: nil, at: at(60))
            try await check(try await s.unassignedTasks().map(\.id.rawValue) == ["t"])
            try await checkThrows(DomainStoreError.notFound(entity: "task", id: "ghost")) { try await s.move(task: TaskID("ghost"), to: nil, at: at(1)) }
            try await checkThrows(DomainStoreError.missingReference(entity: "project", id: "ghost")) { try await s.move(task: TaskID("t"), to: ProjectID("ghost"), at: at(70)) }
            try await check(try await s.task(TaskID("t"))?.updatedAt == at(60))
        }
    }
}
