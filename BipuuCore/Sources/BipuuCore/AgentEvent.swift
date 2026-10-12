import Foundation

public enum EventKindTag {}
public enum SourceTag {}

/// Vendor-independent meaning of an event, dotted `noun.verb`. Open: unknown kinds decode and
/// are stored unchanged, so a newer adapter never breaks an older reader.
///
/// The vocabulary is the minimum Phase 1 actually receives from agent hooks, normalised.
public typealias EventKind = Token<EventKindTag>
public extension Token where Tag == EventKindTag {
    static let sessionStarted: EventKind = "session.started"
    static let sessionEnded: EventKind = "session.ended"
    static let promptSubmitted: EventKind = "prompt.submitted"
    /// The agent finished its turn and is waiting for the user.
    static let turnFinished: EventKind = "turn.finished"
    static let turnFailed: EventKind = "turn.failed"
    static let turnInterrupted: EventKind = "turn.interrupted"
    static let toolStarted: EventKind = "tool.started"
    static let toolFinished: EventKind = "tool.finished"
    static let toolFailed: EventKind = "tool.failed"
    static let subagentStarted: EventKind = "subagent.started"
    static let subagentFinished: EventKind = "subagent.finished"
    static let approvalRequested: EventKind = "approval.requested"
    static let approvalResolved: EventKind = "approval.resolved"
    static let questionRequested: EventKind = "question.requested"
    /// Free-form notice from the agent that needs no decision.
    static let notice: EventKind = "notice"

    static let known: [EventKind] = [
        .sessionStarted, .sessionEnded, .promptSubmitted, .turnFinished, .turnFailed,
        .turnInterrupted, .toolStarted, .toolFinished, .toolFailed, .subagentStarted,
        .subagentFinished, .approvalRequested, .approvalResolved, .questionRequested, .notice,
    ]
}

/// Provenance: which adapter produced the event. Adapter ids are opaque to the core.
public struct EventSource: Hashable, Sendable, Codable {
    public var adapter: String
    public var adapterVersion: String?

    public init(adapter: String, adapterVersion: String? = nil) {
        self.adapter = adapter; self.adapterVersion = adapterVersion
    }
}

/// The single, versioned record every adapter emits. Vendor formats are translated into this
/// at the adapter boundary; nothing vendor-specific is a field here.
public struct AgentEvent: Hashable, Sendable, Codable, Identifiable {
    public static let currentSchemaVersion = 1

    public var id: EventID
    public var schemaVersion: Int
    /// When it happened, by the source's clock.
    public var occurredAt: Date
    /// When Bipuu accepted it, by this machine's clock.
    public var receivedAt: Date

    public var projectID: ProjectID?
    public var taskID: TaskID?
    public var sessionID: SessionID

    public var agentID: AgentID?
    public var hostID: HostID?
    public var environmentID: EnvironmentID?

    public var kind: EventKind
    public var source: EventSource
    public var payload: JSONValue

    /// True when written by a newer schema: known fields are still readable, but a store
    /// should keep the raw bytes if it must not lose anything.
    public var isFromFutureSchema: Bool { schemaVersion > Self.currentSchemaVersion }

    public init(id: EventID = .generate(), schemaVersion: Int = AgentEvent.currentSchemaVersion,
                occurredAt: Date, receivedAt: Date,
                projectID: ProjectID? = nil, taskID: TaskID? = nil, sessionID: SessionID,
                agentID: AgentID? = nil, hostID: HostID? = nil, environmentID: EnvironmentID? = nil,
                kind: EventKind, source: EventSource, payload: JSONValue = .object([:])) {
        self.id = id; self.schemaVersion = schemaVersion
        self.occurredAt = occurredAt; self.receivedAt = receivedAt
        self.projectID = projectID; self.taskID = taskID; self.sessionID = sessionID
        self.agentID = agentID; self.hostID = hostID; self.environmentID = environmentID
        self.kind = kind; self.source = source; self.payload = payload
    }

    /// Canonical ordering: `occurredAt`, then `receivedAt`, then event id (text order).
    /// Deterministic for any set of events, on any store. It is NOT a causal or global total
    /// order: `occurredAt` comes from independent clocks.
    public static func canonicalOrder(_ a: AgentEvent, _ b: AgentEvent) -> Bool {
        if a.occurredAt != b.occurredAt { return a.occurredAt < b.occurredAt }
        if a.receivedAt != b.receivedAt { return a.receivedAt < b.receivedAt }
        return a.id < b.id
    }
}

/// Shared JSON configuration so every store and wire format agrees: dates are exact epoch seconds
/// (round-trips without loss), keys sorted for stable bytes.
public enum BipuuCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
