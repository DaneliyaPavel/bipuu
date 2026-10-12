import Foundation

public enum AppendResult: Sendable, Equatable {
    case appended
    /// An event with this id is already stored; nothing changed (appends are idempotent).
    case duplicate
}

/// Append-only log of events. Implementations: `InMemoryEventStore` here; SQLite later.
///
/// Ordering contract: every query returns events in `AgentEvent.canonicalOrder` (ascending).
/// `recentEvents(limit:)` returns the *last* `limit` events of that order, still ascending.
/// Insertion order is not exposed and carries no meaning.
public protocol EventStore: Sendable {
    func append(_ event: AgentEvent) async throws -> AppendResult
    func events(forSession id: SessionID) async throws -> [AgentEvent]
    func events(forTask id: TaskID) async throws -> [AgentEvent]
    func recentEvents(limit: Int) async throws -> [AgentEvent]
}

/// Reference implementation. Also the executable specification for other stores.
public actor InMemoryEventStore: EventStore {
    private var byID: [EventID: AgentEvent] = [:]

    public init() {}

    public func append(_ event: AgentEvent) -> AppendResult {
        if byID[event.id] != nil { return .duplicate }
        byID[event.id] = event
        return .appended
    }

    public func events(forSession id: SessionID) -> [AgentEvent] {
        sorted(byID.values.filter { $0.sessionID == id })
    }

    public func events(forTask id: TaskID) -> [AgentEvent] {
        sorted(byID.values.filter { $0.taskID == id })
    }

    public func recentEvents(limit: Int) -> [AgentEvent] {
        guard limit > 0 else { return [] }
        return Array(sorted(Array(byID.values)).suffix(limit))
    }

    private func sorted(_ events: [AgentEvent]) -> [AgentEvent] {
        events.sorted(by: AgentEvent.canonicalOrder)
    }
}
