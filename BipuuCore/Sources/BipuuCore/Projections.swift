import Foundation

/// Payload keys the projections understand. Adapters put these in the payload of the matching kinds.
public enum PayloadKey {
    /// `approval.requested` / `approval.resolved`: ties the two events together.
    public static let approvalID = "approvalId"
}

public enum SessionPhase: String, Hashable, Sendable, Codable {
    /// No event so far says what the session is doing.
    case unknown
    /// The agent is acting (prompt received, tools or subagents running).
    case working
    /// The agent finished its turn or was interrupted and waits for the user.
    case idle
    case failed
    case ended
}

/// What a session looks like, derived only from its events. Never stored: recomputed from the
/// `EventStore`, so there is one source of truth.
public struct SessionSummary: Hashable, Sendable, Codable {
    public var sessionID: SessionID
    public var phase: SessionPhase
    public var eventCount: Int
    public var firstEventAt: Date?
    public var lastEventAt: Date?
    public var lastKind: EventKind?
    /// Approvals requested and not yet resolved, by approval id (sorted).
    public var pendingApprovals: [String]
    public var hasOpenQuestion: Bool

    /// The user is needed: an approval or a question is waiting.
    public var needsAttention: Bool { !pendingApprovals.isEmpty || hasOpenQuestion }

    /// Folds events (any order) into a summary using the canonical order.
    ///
    /// Phase: `session.started`, `turn.finished`, `turn.interrupted` → idle; `prompt.submitted`,
    /// `tool.*`, `subagent.*` → working; `turn.failed` → failed; `session.ended` → ended (final until
    /// a new `session.started`). `notice`, `approval.*`, `question.requested` do not change the phase.
    /// A question stays open until the next prompt, turn end or session end. Approvals are matched by
    /// `PayloadKey.approvalID`, falling back to the requesting event's id; a resolution without an id
    /// resolves nothing. `session.ended` drops pending approvals (the agent is gone).
    public static func fold(sessionID: SessionID, events: [AgentEvent]) -> SessionSummary {
        var s = SessionSummary(sessionID: sessionID, phase: .unknown, eventCount: 0, firstEventAt: nil,
                               lastEventAt: nil, lastKind: nil, pendingApprovals: [], hasOpenQuestion: false)
        var pending = Set<String>()
        for e in events.filter({ $0.sessionID == sessionID }).sorted(by: AgentEvent.canonicalOrder) {
            s.eventCount += 1
            s.firstEventAt = s.firstEventAt ?? e.occurredAt
            s.lastEventAt = e.occurredAt
            s.lastKind = e.kind
            switch e.kind {
            case .sessionStarted: s.phase = .idle
            case .promptSubmitted: if s.phase != .ended { s.phase = .working }; s.hasOpenQuestion = false
            case .toolStarted, .toolFinished, .toolFailed, .subagentStarted, .subagentFinished:
                if s.phase != .ended { s.phase = .working }
            case .turnFinished, .turnInterrupted:
                if s.phase != .ended { s.phase = .idle }; s.hasOpenQuestion = false
            case .turnFailed: if s.phase != .ended { s.phase = .failed }; s.hasOpenQuestion = false
            case .sessionEnded: s.phase = .ended; s.hasOpenQuestion = false; pending.removeAll()
            case .approvalRequested: pending.insert(e.payload[PayloadKey.approvalID]?.stringValue ?? e.id.rawValue)
            case .approvalResolved: if let id = e.payload[PayloadKey.approvalID]?.stringValue { pending.remove(id) }
            case .questionRequested: s.hasOpenQuestion = true
            default: break   // notice and unknown kinds: counted, no state change
            }
        }
        s.pendingApprovals = pending.sorted()
        return s
    }
}

/// A task seen through its sessions *as they are attributed now* (`Session.taskID`), not through
/// the `taskID` stamped on old events. Reassigning a session therefore moves its activity between
/// tasks without rewriting history.
public struct TaskSummary: Hashable, Sendable, Codable {
    public var taskID: TaskID
    public var sessionCount: Int
    public var workingSessionCount: Int
    /// Sessions that are not ended or failed.
    public var liveSessionCount: Int
    public var pendingApprovalCount: Int
    public var openQuestionCount: Int
    public var lastEventAt: Date?
    public var needsAttention: Bool { pendingApprovalCount > 0 || openQuestionCount > 0 }

    public static func rollup(taskID: TaskID, sessions: [SessionSummary]) -> TaskSummary {
        TaskSummary(
            taskID: taskID,
            sessionCount: sessions.count,
            workingSessionCount: sessions.filter { $0.phase == .working }.count,
            liveSessionCount: sessions.filter { $0.phase != .ended && $0.phase != .failed }.count,
            pendingApprovalCount: sessions.reduce(0) { $0 + $1.pendingApprovals.count },
            openQuestionCount: sessions.filter(\.hasOpenQuestion).count,
            lastEventAt: sessions.compactMap(\.lastEventAt).max())
    }
}

/// Reads projections from the two stores. Holds no state of its own.
public struct Projections: Sendable {
    public let events: any EventStore
    public let domain: any DomainStore

    public init(events: any EventStore, domain: any DomainStore) {
        self.events = events; self.domain = domain
    }

    public func sessionSummary(_ id: SessionID) async throws -> SessionSummary {
        SessionSummary.fold(sessionID: id, events: try await events.events(forSession: id))
    }

    public func taskSummary(_ id: TaskID) async throws -> TaskSummary {
        guard try await domain.task(id) != nil else { throw DomainStoreError.notFound(entity: "task", id: id.rawValue) }
        var summaries: [SessionSummary] = []
        for s in try await domain.sessions(forTask: id) { summaries.append(try await sessionSummary(s.id)) }
        return TaskSummary.rollup(taskID: id, sessions: summaries)
    }
}
