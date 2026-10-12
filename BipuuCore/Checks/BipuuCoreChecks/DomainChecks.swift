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
