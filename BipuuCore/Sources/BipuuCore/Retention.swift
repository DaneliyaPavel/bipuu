import Foundation

/// How much history to keep. Either limit may be absent (`nil` = unlimited on that axis).
public struct RetentionPolicy: Sendable, Equatable {
    /// Events whose `occurredAt` is older than this are removed.
    public var maxAge: TimeInterval?
    /// Only this many events are kept: the newest in canonical order.
    public var maxEvents: Int?

    public static let defaultMaxAge: TimeInterval = 90 * 86_400
    public static let defaultMaxEvents = 200_000

    public init(maxAge: TimeInterval? = RetentionPolicy.defaultMaxAge, maxEvents: Int? = RetentionPolicy.defaultMaxEvents) {
        self.maxAge = maxAge; self.maxEvents = maxEvents
    }
}

public struct RetentionResult: Sendable, Equatable {
    public var removedByAge: Int
    public var removedByCount: Int
    public var removed: Int { removedByAge + removedByCount }
    public init(removedByAge: Int = 0, removedByCount: Int = 0) {
        self.removedByAge = removedByAge; self.removedByCount = removedByCount
    }
}

/// History cannot grow without bound. This is the one sanctioned exception to "events are never
/// removed": a policy-driven prune of the oldest events. Entities (projects, tasks, sessions) are
/// never touched. Order of work: age first, then the count cap on what is left.
public protocol EventRetention: Sendable {
    /// Removes events older than `now - maxAge`, then the oldest beyond `maxEvents` (canonical order).
    /// An event exactly at the cutoff is kept. Idempotent.
    func prune(_ policy: RetentionPolicy, now: Date) async throws -> RetentionResult
    func eventCount() async throws -> Int
}

extension InMemoryEventStore: EventRetention {
    public func prune(_ policy: RetentionPolicy, now: Date) -> RetentionResult {
        var result = RetentionResult()
        if let maxAge = policy.maxAge {
            let cutoff = now.addingTimeInterval(-maxAge).epochMicroseconds
            let old = byID.values.filter { $0.occurredAt.epochMicroseconds < cutoff }.map(\.id)
            for id in old { byID[id] = nil }
            result.removedByAge = old.count
        }
        if let maxEvents = policy.maxEvents, byID.count > max(0, maxEvents) {
            let surplus = byID.count - max(0, maxEvents)
            let oldest = byID.values.sorted(by: AgentEvent.canonicalOrder).prefix(surplus).map(\.id)
            for id in oldest { byID[id] = nil }
            result.removedByCount = oldest.count
        }
        return result
    }

    public func eventCount() -> Int { byID.count }
}
