import Foundation

public enum AppendResult: Sendable, Equatable {
    case appended
    /// An identical event (same id, same content) is already stored; nothing changed.
    case duplicate
}

public enum EventStoreError: Error, Equatable, Sendable {
    /// An event with this id is already stored but with different content. Never silently ignored:
    /// it means an id was reused or an event was altered.
    case eventIDCollision(EventID)
}

/// Append-only log of events. Implementations: `InMemoryEventStore` here; durable stores live in their own targets.
///
/// `append` contract:
/// - id not present → stored, `.appended`
/// - id present and the stored event is identical (`==`) → no-op, `.duplicate`
/// - id present but content differs → throws `EventStoreError.eventIDCollision`, nothing changes
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
    var byID: [EventID: AgentEvent] = [:]

    public init() {}

    public func append(_ event: AgentEvent) throws -> AppendResult {
        if let existing = byID[event.id] {
            if existing == event { return .duplicate }
            throw EventStoreError.eventIDCollision(event.id)
        }
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
