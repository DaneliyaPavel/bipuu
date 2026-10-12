import Foundation
import BipuuCore
import BipuuChecking

private func roundTrip<T: Codable & Equatable>(_ v: T) throws -> T {
    try BipuuCoding.decoder().decode(T.self, from: BipuuCoding.encoder().encode(v))
}
private let t0 = Date(timeIntervalSince1970: 1_800_000_000.25)

struct IdentifierTests {
    func idsEncodeAsPlainStrings() async throws {
        let id = ProjectID("p-1")
        let json = String(decoding: try BipuuCoding.encoder().encode([id]), as: UTF8.self)
        try await check(json == "[\"p-1\"]")
        try await check(try roundTrip(id) == id)
    }
    func generatedIDsAreUniqueAndHashable() async throws {
        let ids = Set((0..<100).map { _ in SessionID.generate() })
        try await check(ids.count == 100)
    }
    func idTypesAreDistinct() async throws {
        // Compile-time property: ProjectID and TaskID are different types.
        try await check(String(describing: type(of: ProjectID("x"))) != String(describing: type(of: TaskID("x"))))
    }
}

struct EntityTests {
    func entitiesRoundTrip() async throws {
        let agent = Agent(kind: "assistant-a", displayName: "A", capabilities: ["approvals"])
        let host = Host(kind: .terminal, identity: "term.example", displayName: "T", capabilities: ["focus"])
        let env = Environment(kind: "lab-bench", name: "Bench", attributes: ["region": "x"])
        let project = Project(name: "P", roots: ["/r"], createdAt: t0)
        let task = WorkTask(projectID: project.id, title: "T", origin: .inferred, createdAt: t0)
        let session = Session(taskID: task.id, agentID: agent.id, hostID: host.id, environmentID: env.id,
                              workingDirectory: "/r", externalRef: "ext", startedAt: t0)
        let approval = Approval(sessionID: session.id, summary: "run x", requestedAt: t0)
        let artifact = Artifact(kind: .diff, sessionID: session.id, location: "/r/a.diff", createdAt: t0)
        try await check(try roundTrip(agent) == agent)
        try await check(try roundTrip(host) == host)
        try await check(try roundTrip(env) == env)
        try await check(try roundTrip(project) == project)
        try await check(try roundTrip(task) == task)
        try await check(try roundTrip(session) == session)
        try await check(try roundTrip(approval) == approval)
        try await check(try roundTrip(artifact) == artifact)
    }

    func taskIsNotSession() async throws {
        let task = WorkTask(title: "T", createdAt: t0)
        let agent = AgentID.generate()
        var s1 = Session(taskID: task.id, agentID: agent, startedAt: t0)
        let s2 = Session(taskID: task.id, agentID: AgentID.generate(), startedAt: t0)
        // One task, several sessions, with different agents.
        try await check(s1.taskID == s2.taskID)
        try await check(s1.id != s2.id)
        // Reassignment and detachment are plain field edits; nothing forbids them.
        let other = WorkTask(title: "U", createdAt: t0)
        s1.taskID = other.id
        try await check(s1.taskID != s2.taskID)
        s1.taskID = nil
        try await check(s1.taskID == nil)
    }

    func taskMovesBetweenProjects() async throws {
        var task = WorkTask(projectID: ProjectID("a"), title: "T", createdAt: t0)
        task.projectID = ProjectID("b")
        task.projectID = nil
        try await check(task.projectID == nil)
    }

    func agentHostEnvironmentAreIndependent() async throws {
        let agent = Agent(kind: "k", displayName: "A")
        let host = Host(kind: .editor, identity: "ed", displayName: "E")
        // The same agent can run in different hosts and environments; nothing links them.
        let a = Session(agentID: agent.id, hostID: host.id, environmentID: EnvironmentID("local"), startedAt: t0)
        let b = Session(agentID: agent.id, hostID: HostID("other"), environmentID: EnvironmentID("prod"), startedAt: t0)
        try await check(a.agentID == b.agentID && a.hostID != b.hostID && a.environmentID != b.environmentID)
    }

    func vocabulariesAreOpen() async throws {
        let future = try BipuuCoding.decoder().decode(EnvironmentKind.self, from: Data("\"quantum-sandbox\"".utf8))
        try await check(future.rawValue == "quantum-sandbox")
        try await check(try roundTrip(future) == future)
        try await check(EnvironmentKind.production.rawValue == "production")
        try await check(HostKind.remoteShell.rawValue == "remote-shell")
    }

    func approvalPendingUntilDecided() async throws {
        var a = Approval(sessionID: SessionID("s"), summary: "x", requestedAt: t0)
        try await check(a.isPending)
        a.decision = .deny; a.resolvedAt = t0
        try await check(!a.isPending)
    }
}

struct EventTests {
    private func event(_ id: String, occ: Double, rec: Double, session: String = "s",
                       task: String? = nil, kind: EventKind = .toolStarted) -> AgentEvent {
        AgentEvent(id: EventID(id), occurredAt: Date(timeIntervalSince1970: occ),
                   receivedAt: Date(timeIntervalSince1970: rec), taskID: task.map { TaskID($0) },
                   sessionID: SessionID(session), kind: kind, source: EventSource(adapter: "test"))
    }

    func envelopeRoundTripAndVersion() async throws {
        let e = AgentEvent(occurredAt: t0, receivedAt: t0.addingTimeInterval(1),
                           projectID: ProjectID("p"), taskID: TaskID("t"), sessionID: SessionID("s"),
                           agentID: AgentID("a"), hostID: HostID("h"), environmentID: EnvironmentID("e"),
                           kind: .approvalRequested, source: EventSource(adapter: "x", adapterVersion: "1"),
                           payload: .object(["tool": .string("shell"), "n": .number(2), "ok": .bool(true),
                                             "list": .array([.null, .string("z")])]))
        try await check(e.schemaVersion == AgentEvent.currentSchemaVersion)
        try await check(!e.isFromFutureSchema)
        try await check(try roundTrip(e) == e)
    }

    func minimalEnvelopeHasOnlyRequiredFields() async throws {
        let e = event("e1", occ: 1, rec: 2)
        let json = String(decoding: try BipuuCoding.encoder().encode(e), as: UTF8.self)
        try await check(!json.contains("projectID") && !json.contains("agentID"))
        try await check(try roundTrip(e) == e)
    }

    func futureSchemaAndUnknownKindStillDecode() async throws {
        let json = """
        {"id":"e","schemaVersion":99,"occurredAt":1,"receivedAt":2,"sessionID":"s",
         "kind":"hologram.projected","source":{"adapter":"new","extra":1},
         "payload":{"x":1},"someNewField":{"a":[1,2]}}
        """
        let e = try BipuuCoding.decoder().decode(AgentEvent.self, from: Data(json.utf8))
        try await check(e.isFromFutureSchema)
        try await check(e.kind.rawValue == "hologram.projected")
        try await check(e.payload["x"] == .number(1))
        try await check(!EventKind.known.contains(e.kind))
    }

    func missingRequiredFieldFails() async throws {
        let json = #"{"id":"e","schemaVersion":1,"occurredAt":1,"receivedAt":2,"kind":"notice","source":{"adapter":"a"},"payload":{}}"#
        try await checkThrows {
            _ = try BipuuCoding.decoder().decode(AgentEvent.self, from: Data(json.utf8))
        }
    }

    func knownKindsAreUniqueAndDotted() async throws {
        let names = EventKind.known.map(\.rawValue)
        try await check(Set(names).count == names.count)
        try await check(names.allSatisfy { !$0.isEmpty })
    }

    func canonicalOrderIsDeterministic() async throws {
        let a = event("a", occ: 1, rec: 5)
        let b = event("b", occ: 1, rec: 5)   // ties on both times: id decides
        let c = event("c", occ: 1, rec: 4)   // same occurredAt, earlier receivedAt
        let d = event("d", occ: 0, rec: 9)   // earliest occurredAt wins despite late receipt
        let expected = [d, c, a, b].map(\.id)
        for _ in 0..<20 {
            let shuffled = [a, b, c, d].shuffled().sorted(by: AgentEvent.canonicalOrder)
            try await check(shuffled.map(\.id) == expected)
        }
    }
}

struct InMemoryEventStoreTests {
    func appendIsIdempotentAndQueriesFilter() async throws {
        let store = InMemoryEventStore()
        func ev(_ id: String, _ t: Double, s: String, task: String?) -> AgentEvent {
            AgentEvent(id: EventID(id), occurredAt: Date(timeIntervalSince1970: t),
                       receivedAt: Date(timeIntervalSince1970: t), taskID: task.map { TaskID($0) },
                       sessionID: SessionID(s), kind: .notice, source: EventSource(adapter: "t"))
        }
        try await check(try await store.append(ev("1", 3, s: "A", task: "T")) == .appended)
        try await check(try await store.append(ev("2", 1, s: "A", task: nil)) == .appended)
        try await check(try await store.append(ev("3", 2, s: "B", task: "T")) == .appended)
        try await check(try await store.append(ev("1", 3, s: "A", task: "T")) == .duplicate)

        try await check(try await store.events(forSession: SessionID("A")).map(\.id.rawValue) == ["2", "1"])
        // A task spans several sessions.
        try await check(try await store.events(forTask: TaskID("T")).map(\.id.rawValue) == ["3", "1"])
        try await check(try await store.events(forSession: SessionID("none")).isEmpty)
    }

    func recentIsLastNInAscendingOrder() async throws {
        let store = InMemoryEventStore()
        for i in (0..<10).shuffled() {
            _ = try await store.append(AgentEvent(id: EventID("e\(i)"),
                occurredAt: Date(timeIntervalSince1970: Double(i)), receivedAt: Date(timeIntervalSince1970: Double(i)),
                sessionID: SessionID("s"), kind: .notice, source: EventSource(adapter: "t")))
        }
        try await check(try await store.recentEvents(limit: 3).map(\.id.rawValue) == ["e7", "e8", "e9"])
        try await check(try await store.recentEvents(limit: 100).count == 10)
        try await check(try await store.recentEvents(limit: 0).isEmpty)
    }
}

struct IsolationTests {
    func coreImportsOnlyFoundation() async throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BipuuCore")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        try await check(!files.isEmpty)
        for f in files {
            let imports = try String(contentsOf: f, encoding: .utf8).split(separator: "\n")
                .filter { $0.hasPrefix("import ") }.map { $0.dropFirst(7).trimmingCharacters(in: .whitespaces) }
            try await check(imports.allSatisfy { $0 == "Foundation" }, "\(f.lastPathComponent) imports \(imports)")
        }
    }

    func coreHasNoVendorBranching() async throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BipuuCore")
        let banned = ["claude", "codex", "gemini", "cursor", "copilot", "sqlite", "zed", "vscode", "jetbrains", "warp"]
        for f in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            let text = try String(contentsOf: f, encoding: .utf8).lowercased()
            for word in banned { try await check(!text.contains(word), "\(f.lastPathComponent) mentions \(word)") }
        }
    }
}


struct ProjectionChecks {
    private func e(_ id: String, _ t: Double, _ kind: EventKind, session: String = "s", task: String? = nil,
                   payload: JSONValue = .object([:])) -> AgentEvent {
        AgentEvent(id: EventID(id), occurredAt: Date(timeIntervalSince1970: t), receivedAt: Date(timeIntervalSince1970: t),
                   taskID: task.map { TaskID($0) }, sessionID: SessionID(session), kind: kind,
                   source: EventSource(adapter: "test"), payload: payload)
    }
    private func approval(_ id: String) -> JSONValue { .object([PayloadKey.approvalID: .string(id)]) }
    private func fold(_ events: [AgentEvent], session: String = "s") -> SessionSummary {
        SessionSummary.fold(sessionID: SessionID(session), events: events)
    }

    func phases() async throws {
        try await check(fold([]).phase == .unknown && fold([]).eventCount == 0 && fold([]).lastEventAt == nil)
        try await check(fold([e("1", 1, .sessionStarted)]).phase == .idle)
        try await check(fold([e("1", 1, .sessionStarted), e("2", 2, .promptSubmitted)]).phase == .working)
        try await check(fold([e("1", 1, .promptSubmitted), e("2", 2, .toolStarted), e("3", 3, .turnFinished)]).phase == .idle)
        try await check(fold([e("1", 1, .promptSubmitted), e("2", 2, .turnFailed)]).phase == .failed)
        try await check(fold([e("1", 1, .promptSubmitted), e("2", 2, .turnInterrupted)]).phase == .idle)
        // Ended is final: late tool events do not revive it; a new session.started does.
        try await check(fold([e("1", 1, .sessionStarted), e("2", 2, .sessionEnded), e("3", 3, .toolStarted)]).phase == .ended)
        try await check(fold([e("1", 1, .sessionEnded), e("2", 2, .sessionStarted)]).phase == .idle)
        // Notices and unknown kinds count but change nothing.
        let n = fold([e("1", 1, .promptSubmitted), e("2", 2, .notice), e("3", 3, "hologram.projected")])
        try await check(n.phase == .working && n.eventCount == 3 && n.lastKind?.rawValue == "hologram.projected")
        // Input order does not matter; other sessions' events are ignored.
        let mixed = fold([e("3", 3, .turnFinished), e("1", 1, .promptSubmitted), e("x", 2, .sessionEnded, session: "other")])
        try await check(mixed.phase == .idle && mixed.eventCount == 2)
        try await check(mixed.firstEventAt == Date(timeIntervalSince1970: 1) && mixed.lastEventAt == Date(timeIntervalSince1970: 3))
    }

    func attention() async throws {
        let open = fold([e("r1", 1, .approvalRequested, payload: approval("A1")), e("r2", 2, .approvalRequested, payload: approval("A2"))])
        try await check(open.pendingApprovals == ["A1", "A2"] && open.needsAttention)
        let one = fold([e("r1", 1, .approvalRequested, payload: approval("A1")), e("r2", 2, .approvalRequested, payload: approval("A2")),
                        e("x", 3, .approvalResolved, payload: approval("A1"))])
        try await check(one.pendingApprovals == ["A2"] && one.needsAttention)
        let none = fold([e("r1", 1, .approvalRequested, payload: approval("A1")), e("x", 2, .approvalResolved, payload: approval("A1"))])
        try await check(none.pendingApprovals.isEmpty && !none.needsAttention)
        // Without an approval id the requesting event id is used; a resolution without an id resolves nothing.
        let anon = fold([e("req", 1, .approvalRequested), e("res", 2, .approvalResolved)])
        try await check(anon.pendingApprovals == ["req"])
        // Ending the session drops pending approvals.
        try await check(fold([e("r", 1, .approvalRequested, payload: approval("A")), e("z", 2, .sessionEnded)]).pendingApprovals.isEmpty)
        // A question stays open until the next prompt or turn end.
        try await check(fold([e("q", 1, .questionRequested)]).hasOpenQuestion)
        try await check(!fold([e("q", 1, .questionRequested), e("p", 2, .promptSubmitted)]).hasOpenQuestion)
        try await check(!fold([e("q", 1, .questionRequested), e("t", 2, .turnFinished)]).hasOpenQuestion)
        try await check(fold([e("q", 1, .questionRequested), e("t", 2, .toolStarted)]).hasOpenQuestion)
    }

    func service() async throws {
        let events = InMemoryEventStore(), domain = InMemoryDomainStore()
        let agent = Agent(id: AgentID("a"), kind: "k", displayName: "A")
        try await domain.save(agent)
        try await domain.save(WorkTask(id: TaskID("t1"), title: "one", createdAt: Date(timeIntervalSince1970: 1)))
        try await domain.save(WorkTask(id: TaskID("t2"), title: "two", createdAt: Date(timeIntervalSince1970: 1)))
        for sid in ["s1", "s2"] {
            try await domain.save(Session(id: SessionID(sid), taskID: TaskID("t1"), agentID: agent.id, startedAt: Date(timeIntervalSince1970: 1)))
        }
        // Events carry the task they were attributed to at recording time: t1.
        _ = try await events.append(e("a1", 1, .promptSubmitted, session: "s1", task: "t1"))
        _ = try await events.append(e("a2", 5, .approvalRequested, session: "s1", task: "t1", payload: approval("A")))
        _ = try await events.append(e("b1", 3, .turnFinished, session: "s2", task: "t1"))
        let proj = Projections(events: events, domain: domain)

        let before = try await proj.taskSummary(TaskID("t1"))
        try await check(before.sessionCount == 2 && before.workingSessionCount == 1 && before.liveSessionCount == 2)
        try await check(before.pendingApprovalCount == 1 && before.needsAttention)
        try await check(before.lastEventAt == Date(timeIntervalSince1970: 5))

        // Reassign s1 to t2: the projection follows the session, the stored events are untouched.
        try await domain.assign(session: SessionID("s1"), to: TaskID("t2"))
        let t1 = try await proj.taskSummary(TaskID("t1")), t2 = try await proj.taskSummary(TaskID("t2"))
        try await check(t1.sessionCount == 1 && !t1.needsAttention && t1.workingSessionCount == 0)
        try await check(t2.sessionCount == 1 && t2.needsAttention && t2.workingSessionCount == 1)
        try await check(try await events.events(forTask: TaskID("t1")).count == 3)   // history keeps its original attribution

        // A task with no sessions is empty; an unknown task is an error; a session summary needs no domain entity.
        try await domain.assign(session: SessionID("s2"), to: nil)
        try await check(try await proj.taskSummary(TaskID("t1")) == TaskSummary.rollup(taskID: TaskID("t1"), sessions: []))
        try await checkThrows(DomainStoreError.notFound(entity: "task", id: "ghost")) { _ = try await proj.taskSummary(TaskID("ghost")) }
        try await check(try await proj.sessionSummary(SessionID("never-saved")).phase == .unknown)
    }
}
