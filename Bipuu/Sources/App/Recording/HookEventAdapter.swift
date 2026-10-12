import Foundation
import BipuuCore

/// Who a hook message is about, in domain terms. Built from the relay's JSON; the rest of the
/// recording code never sees the vendor format.
struct HookIdentity: Sendable, Equatable {
    var agent: Agent
    var host: BipuuCore.Host?
    var sessionID: SessionID
    /// The agent's own session id, when it sent one.
    var externalRef: String?
    var workingDirectory: String?
}

/// A normalised event together with the identity it belongs to.
struct RecordedHook: Sendable {
    var event: AgentEvent
    var identity: HookIdentity
}

/// The adapter between the hook relay's messages and the vendor-neutral `AgentEvent`.
///
/// This is where product and vendor names are allowed to exist; nothing downstream compares them.
///
/// Privacy rule: payloads carry **names and categories only** (tool name, category, decision).
/// Prompts, commands, file paths, file contents, notification text and assistant messages are
/// never copied into an event. The one path kept is the session's working directory, as session
/// metadata (needed later to group sessions into projects).
enum HookEventAdapter {
    static let source = EventSource(adapter: "bipuu-hook", adapterVersion: "1")

    // MARK: Identity

    static func identity(from payload: [String: Any]) -> HookIdentity {
        let bundleId = payload["bundle_id"] as? String ?? ""
        let termProgram = payload["term_program"] as? String ?? ""
        let cwd = payload["cwd"] as? String ?? ""

        let kind = agentKind(bipuuAgent: payload["bipuu_agent"] as? String ?? "", bundleId: bundleId)
        let agent = Agent(id: AgentID("agent:\(kind)"), kind: AgentKind(kind), displayName: kind)

        let rawSession = (payload["session_id"] as? String) ?? (payload["conversation_id"] as? String) ?? ""
        let hasSession = !rawSession.isEmpty && rawSession != "unknown"
        // Sessions that carry no id are told apart by agent + directory, like the island does.
        let key = hasSession ? rawSession : "\(kind)+\(cwd)"
        return HookIdentity(agent: agent,
                            host: host(termProgram: termProgram, bundleId: bundleId),
                            sessionID: SessionID("\(kind):\(key)"),
                            externalRef: hasSession ? rawSession : nil,
                            workingDirectory: cwd.isEmpty ? nil : cwd)
    }

    /// `bipuu_agent` when it is a valid name, the editor's agent when its bundle id says so, else the default.
    private static func agentKind(bipuuAgent: String, bundleId: String) -> String {
        let valid = !bipuuAgent.isEmpty && bipuuAgent.count <= 24 && bipuuAgent.unicodeScalars.allSatisfy {
            ($0.value >= 0x61 && $0.value <= 0x7A) || ($0.value >= 0x30 && $0.value <= 0x39) || $0.value == 0x2D
        }
        if valid { return bipuuAgent }
        if bundleId.lowercased() == "com.todesktop.230313mzl4w4u92" { return "cursor" }
        return "claude"
    }

    private static func host(termProgram: String, bundleId: String) -> BipuuCore.Host? {
        let identity = !bundleId.isEmpty ? bundleId : termProgram
        guard !identity.isEmpty else { return nil }
        let lower = identity.lowercased()
        let kind: HostKind = (lower.contains("vscode") || lower == "com.todesktop.230313mzl4w4u92") ? .editor
            : (!termProgram.isEmpty ? .terminal : .other)
        return BipuuCore.Host(id: HostID("host:\(identity)"), kind: kind, identity: identity, displayName: identity)
    }

    // MARK: Events

    /// The event for a hook message, or `nil` when it is not one of the normalised kinds.
    static func hook(name: String, payload: [String: Any], now: Date = Date()) -> RecordedHook? {
        let tool = payload["tool_name"] as? String ?? ""
        let kind: EventKind
        var body: [String: JSONValue] = [:]
        switch name {
        case "SessionStart": kind = .sessionStarted
        case "SessionEnd": kind = .sessionEnded
        case "UserPromptSubmit": kind = .promptSubmitted
        case "PreToolUse":
            guard tool != "AskUserQuestion" else { return nil }   // recorded as question.requested instead
            kind = .toolStarted; body = toolBody(tool)
        case "PostToolUse": kind = .toolFinished; body = toolBody(tool)
        case "PostToolUseFailure": kind = .toolFailed; body = toolBody(tool)
        case "Stop": kind = .turnFinished
        case "StopFailure": kind = .turnFailed
        case "Interrupt": kind = .turnInterrupted
        case "SubagentStart": kind = .subagentStarted
        case "SubagentStop": kind = .subagentFinished
        case "Notification":
            kind = .notice
            body = ["category": .string(noticeCategory(payload["message"] as? String ?? ""))]
        default: return nil
        }
        return make(kind, payload: payload, body: body, now: now)
    }

    /// A permission card was queued for the user.
    static func approvalRequested(payload: [String: Any], approvalID: UUID, now: Date = Date()) -> RecordedHook {
        var body = toolBody(payload["tool_name"] as? String ?? "")
        body[PayloadKey.approvalID] = .string(approvalID.uuidString)
        return make(.approvalRequested, payload: payload, body: body, now: now)
    }

    /// The card's request ended. `decision` is the wire answer (`allow`/`always`/`deny`/`ask`) or
    /// `nil` when nothing was answered (handled in the agent's own UI, timed out, hung up).
    static func approvalResolved(identity: HookIdentity, approvalID: UUID, decision: String?, now: Date = Date()) -> RecordedHook {
        let outcome: String
        switch decision {
        case "allow": outcome = "allow"
        case "always": outcome = "allowAlways"
        case "deny": outcome = "deny"
        case "ask": outcome = "deferred"
        default: outcome = "withdrawn"
        }
        let event = AgentEvent(occurredAt: now, receivedAt: now, sessionID: identity.sessionID,
                               agentID: identity.agent.id, hostID: identity.host?.id,
                               kind: .approvalResolved, source: source,
                               payload: .object([PayloadKey.approvalID: .string(approvalID.uuidString),
                                                 "decision": .string(outcome)]))
        return RecordedHook(event: event, identity: identity)
    }

    static func questionRequested(payload: [String: Any], now: Date = Date()) -> RecordedHook {
        make(.questionRequested, payload: payload, body: [:], now: now)
    }

    // MARK: Helpers

    private static func make(_ kind: EventKind, payload: [String: Any], body: [String: JSONValue], now: Date) -> RecordedHook {
        let id = identity(from: payload)
        // Hooks carry no timestamp: the moment Bipuu received the message is the best time we have.
        let event = AgentEvent(occurredAt: now, receivedAt: now, sessionID: id.sessionID,
                               agentID: id.agent.id, hostID: id.host?.id,
                               kind: kind, source: source, payload: .object(body))
        return RecordedHook(event: event, identity: id)
    }

    private static func toolBody(_ tool: String) -> [String: JSONValue] {
        ["tool": .string(String(tool.prefix(64))), "category": .string(toolCategory(tool))]
    }

    static func toolCategory(_ tool: String) -> String {
        switch tool.lowercased() {
        case "read", "grep", "glob", "ls", "notebookread", "read_file", "search", "list_dir": return "read"
        case "edit", "multiedit", "write", "notebookedit", "apply_patch", "write_file", "replace": return "edit"
        case "bash", "shell", "local_shell", "run_shell_command", "terminal", "execute": return "execute"
        default: return "other"
        }
    }

    private static func noticeCategory(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("rate limit") || lower.contains("limite d") { return "rate-limit" }
        if message.hasSuffix("?") { return "question" }
        return "other"
    }
}
