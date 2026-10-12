import Foundation
import BipuuCore

/// What every store that supports pruning must do. Run against each with a factory returning a fresh store.
public enum RetentionContract {
    public typealias Store = EventStore & EventRetention
    public typealias Make = @Sendable () async throws -> any Store

    static let day = 86_400.0
    static let now = Date(timeIntervalSince1970: 1_000 * 86_400)
    static func ev(_ id: String, age days: Double, session: String = "s", task: String? = nil, extraSeconds: Double = 0) -> AgentEvent {
        let t = Date(timeIntervalSince1970: now.timeIntervalSince1970 - days * day + extraSeconds)
        return AgentEvent(id: EventID(id), occurredAt: t, receivedAt: t, taskID: task.map { TaskID($0) },
                          sessionID: SessionID(session), kind: .notice, source: EventSource(adapter: "retention"))
    }
    static func ids(_ s: any Store) async throws -> [String] { try await s.recentEvents(limit: 10_000).map(\.id.rawValue) }

    public static func runAll(_ label: String, make: @escaping Make) async {
        await run("\(label) retention: an empty store and an unlimited policy remove nothing") {
            let s = try await make()
            try await check(try await s.prune(RetentionPolicy(), now: now) == RetentionResult())
            try await check(try await s.eventCount() == 0)
            for i in 0..<5 { _ = try await s.append(ev("e\(i)", age: Double(i) * 500)) }
            try await check(try await s.prune(RetentionPolicy(maxAge: nil, maxEvents: nil), now: now) == RetentionResult())
            try await check(try await s.eventCount() == 5)
        }
        await run("\(label) retention: by age (the cutoff itself is kept)") {
            let s = try await make()
            for (id, age) in [("fresh", 1.0), ("edge", 90.0), ("old", 91.0), ("ancient", 400.0)] { _ = try await s.append(ev(id, age: age)) }
            _ = try await s.append(ev("justOver", age: 90, extraSeconds: -1))     // one second older than the cutoff
            let r = try await s.prune(RetentionPolicy(maxAge: 90 * day, maxEvents: nil), now: now)
            try await check(r == RetentionResult(removedByAge: 3, removedByCount: 0), "\(r)")
            try await check(Set(try await ids(s)) == ["fresh", "edge"])
            try await check(try await s.prune(RetentionPolicy(maxAge: 90 * day, maxEvents: nil), now: now) == RetentionResult(), "idempotent")
        }
        await run("\(label) retention: by count keeps the newest in canonical order") {
            let s = try await make()
            for i in 0..<10 { _ = try await s.append(ev("e\(i)", age: Double(10 - i))) }       // e9 is the newest
            _ = try await s.append(ev("tieA", age: 0.5)); _ = try await s.append(ev("tieB", age: 0.5))   // same time: id decides
            let r = try await s.prune(RetentionPolicy(maxAge: nil, maxEvents: 4), now: now)
            try await check(r == RetentionResult(removedByAge: 0, removedByCount: 8), "\(r)")
            let kept = try await ids(s)
            try await check(Set(kept) == ["e8", "e9", "tieA", "tieB"] && kept.count == 4, "\(kept)")
            try await check(try await s.eventCount() == 4)
            try await check(try await s.prune(RetentionPolicy(maxAge: nil, maxEvents: 4), now: now) == RetentionResult(), "idempotent")
            try await check(try await s.prune(RetentionPolicy(maxAge: nil, maxEvents: 0), now: now).removed == 4, "zero keeps nothing")
            try await check(try await s.eventCount() == 0)
        }
        await run("\(label) retention: age first, then the cap on what is left; counts are reported separately") {
            let s = try await make()
            for i in 0..<6 { _ = try await s.append(ev("old\(i)", age: 100 + Double(i))) }
            for i in 0..<6 { _ = try await s.append(ev("new\(i)", age: Double(i + 1))) }
            let r = try await s.prune(RetentionPolicy(maxAge: 90 * day, maxEvents: 4), now: now)
            try await check(r == RetentionResult(removedByAge: 6, removedByCount: 2), "\(r)")
            try await check(Set(try await ids(s)) == ["new0", "new1", "new2", "new3"], "\(try await ids(s))")
        }
        await run("\(label) retention: queries stay consistent and the store keeps working") {
            let s = try await make()
            for i in 0..<6 { _ = try await s.append(ev("a\(i)", age: Double(60 - i * 10), session: "A", task: "T")) }
            for i in 0..<6 { _ = try await s.append(ev("b\(i)", age: Double(5 - i), session: "B")) }
            _ = try await s.prune(RetentionPolicy(maxAge: 30 * day, maxEvents: nil), now: now)
            let a = try await s.events(forSession: SessionID("A")).map(\.id.rawValue)
            try await check(a == ["a3", "a4", "a5"], "\(a)")
            try await check(try await s.events(forTask: TaskID("T")).count == 3)
            try await check(try await s.events(forSession: SessionID("B")).count == 6)
            // New events append as usual, a pruned id can be reused, an existing one still collides.
            try await check(try await s.append(ev("fresh", age: 0)) == .appended)
            try await check(try await s.append(ev("a0", age: 1, session: "A")) == .appended, "a pruned id is free again")
            try await checkThrows(EventStoreError.eventIDCollision(EventID("a5"))) { _ = try await s.append(ev("a5", age: 0, session: "A")) }
            try await check(try await s.eventCount() == 3 + 6 + 2)
        }
    }
}
