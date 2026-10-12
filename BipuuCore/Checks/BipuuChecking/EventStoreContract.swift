import Foundation
import BipuuCore

/// The behaviour every `EventStore` must have. Run it against each implementation with a factory
/// that returns a fresh, empty store.
public enum EventStoreContract {
    public typealias Make = @Sendable () async throws -> any EventStore

    public static func ev(_ id: String, occ: Double = 1, rec: Double? = nil, session: String = "s",
                          task: String? = nil, kind: EventKind = .notice, schema: Int = AgentEvent.currentSchemaVersion,
                          payload: JSONValue = .object([:])) -> AgentEvent {
        AgentEvent(id: EventID(id), schemaVersion: schema, occurredAt: Date(timeIntervalSince1970: occ),
                   receivedAt: Date(timeIntervalSince1970: rec ?? occ), taskID: task.map { TaskID($0) },
                   sessionID: SessionID(session), kind: kind, source: EventSource(adapter: "contract"),
                   payload: payload)
    }

    public static func runAll(_ label: String, make: @escaping Make) async {
        await run("\(label): empty store") {
            let s = try await make()
            try await check(try await s.events(forSession: SessionID("x")).isEmpty)
            try await check(try await s.events(forTask: TaskID("x")).isEmpty)
            try await check(try await s.recentEvents(limit: 5).isEmpty)
        }
        await run("\(label): append and read back every field") {
            let s = try await make()
            let e = AgentEvent(id: EventID("full"), occurredAt: Date(timeIntervalSince1970: 1_800_000_000.123456),
                               receivedAt: Date(timeIntervalSince1970: 1_800_000_001.5),
                               projectID: ProjectID("p"), taskID: TaskID("t"), sessionID: SessionID("s"),
                               agentID: AgentID("a"), hostID: HostID("h"), environmentID: EnvironmentID("e"),
                               kind: .toolFinished, source: EventSource(adapter: "x", adapterVersion: "2"),
                               payload: .object(["k": .array([.null, .bool(true), .number(1.5), .string("é✓")])]))
            try await check(try await s.append(e) == .appended)
            try await check(try await s.events(forSession: SessionID("s")) == [e])
            try await check(try await s.events(forTask: TaskID("t")) == [e])
        }
        await run("\(label): session and task queries") {
            let s = try await make()
            _ = try await s.append(ev("1", occ: 3, session: "A", task: "T"))
            _ = try await s.append(ev("2", occ: 1, session: "A"))
            _ = try await s.append(ev("3", occ: 2, session: "B", task: "T"))
            try await check(try await s.events(forSession: SessionID("A")).map(\.id.rawValue) == ["2", "1"])
            try await check(try await s.events(forTask: TaskID("T")).map(\.id.rawValue) == ["3", "1"])
            try await check(try await s.events(forSession: SessionID("none")).isEmpty)
        }
        await run("\(label): recent is the last N, ascending") {
            let s = try await make()
            for i in (0..<10).shuffled() { _ = try await s.append(ev("e\(i)", occ: Double(i))) }
            try await check(try await s.recentEvents(limit: 3).map(\.id.rawValue) == ["e7", "e8", "e9"])
            try await check(try await s.recentEvents(limit: 100).count == 10)
            try await check(try await s.recentEvents(limit: 0).isEmpty)
        }
        await run("\(label): canonical order (occurredAt, receivedAt, id; microsecond resolution)") {
            let s = try await make()
            let events = [
                ev("a", occ: 1, rec: 5), ev("b", occ: 1, rec: 5),      // tie on both: id decides
                ev("c", occ: 1, rec: 4), ev("d", occ: 0, rec: 9),      // earlier occurredAt wins
                ev("é", occ: 2, rec: 2), ev("z", occ: 2, rec: 2),      // UTF-8 byte order: z < é
                ev("m1", occ: 3.0000001, rec: 3), ev("m0", occ: 3.0, rec: 3), // < 1 µs apart: same position
            ]
            for e in events.shuffled() { _ = try await s.append(e) }
            let got = try await s.events(forSession: SessionID("s")).map(\.id.rawValue)
            try await check(got == ["d", "c", "a", "b", "z", "é", "m0", "m1"], "got \(got)")
            try await check(try await s.recentEvents(limit: 100).map(\.id.rawValue) == got)
        }
        await run("\(label): identical duplicate is an idempotent no-op") {
            let s = try await make()
            let e = ev("dup", payload: .object(["x": .number(1)]))
            try await check(try await s.append(e) == .appended)
            try await check(try await s.append(e) == .duplicate)
            try await check(try await s.recentEvents(limit: 10).count == 1)
        }
        await run("\(label): conflicting duplicate is rejected and changes nothing") {
            let s = try await make()
            let e = ev("c1", payload: .object(["x": .number(1)]))
            _ = try await s.append(e)
            for changed in [ev("c1", payload: .object(["x": .number(2)])),
                            ev("c1", occ: 1, rec: 2, payload: .object(["x": .number(1)])),
                            ev("c1", session: "other", payload: .object(["x": .number(1)]))] {
                try await checkThrows(EventStoreError.eventIDCollision(EventID("c1"))) { _ = try await s.append(changed) }
            }
            try await check(try await s.recentEvents(limit: 10) == [e])
            try await check(try await s.events(forSession: SessionID("other")).isEmpty)
        }
        await run("\(label): unknown event kind survives") {
            let s = try await make()
            let e = ev("k", kind: "hologram.projected")
            _ = try await s.append(e)
            let back = try await s.recentEvents(limit: 1)
            try await check(back == [e] && back[0].kind.rawValue == "hologram.projected")
            try await check(!EventKind.known.contains(back[0].kind))
        }
        await run("\(label): future-schema envelope survives (known fields)") {
            let s = try await make()
            let e = ev("f", schema: 99, payload: .object(["n": .number(1)]))
            _ = try await s.append(e)
            let back = try await s.recentEvents(limit: 1)
            try await check(back == [e] && back[0].schemaVersion == 99 && back[0].isFromFutureSchema)
        }
    }
}
