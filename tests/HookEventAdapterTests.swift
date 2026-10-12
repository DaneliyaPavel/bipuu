import Foundation
import BipuuCore

@main
struct HookEventAdapterTests {
    nonisolated(unsafe) static var failures = 0
    static func check(_ ok: Bool, _ msg: String, line: Int = #line) {
        if !ok { failures += 1; print("FAIL line \(line): \(msg)") }
    }

    static func main() {
        let base: [String: Any] = ["session_id": "sess-1", "cwd": "/work/app", "term_program": "Apple_Terminal"]
        func with(_ extra: [String: Any]) -> [String: Any] { base.merging(extra) { $1 } }

        // Every normalised hook name maps to its vendor-neutral kind.
        let table: [(String, EventKind)] = [
            ("SessionStart", .sessionStarted), ("SessionEnd", .sessionEnded), ("UserPromptSubmit", .promptSubmitted),
            ("PreToolUse", .toolStarted), ("PostToolUse", .toolFinished), ("PostToolUseFailure", .toolFailed),
            ("Stop", .turnFinished), ("StopFailure", .turnFailed), ("Interrupt", .turnInterrupted),
            ("SubagentStart", .subagentStarted), ("SubagentStop", .subagentFinished), ("Notification", .notice),
        ]
        for (name, kind) in table {
            let h = HookEventAdapter.hook(name: name, payload: with(["tool_name": "Bash"]))
            check(h?.event.kind == kind, "\(name) -> \(kind)")
            check(h.map { EventKind.known.contains($0.event.kind) } == true, "\(name) maps into the known vocabulary")
        }
        check(HookEventAdapter.hook(name: "Surprise", payload: base) == nil, "unknown hook names are not recorded")
        check(HookEventAdapter.hook(name: "PreToolUse", payload: with(["tool_name": "AskUserQuestion"])) == nil,
              "AskUserQuestion is recorded as a question, not a tool")
        check(HookEventAdapter.hook(name: "", payload: base) == nil, "empty name")

        // Identity: agent, host and session.
        let id = HookEventAdapter.identity(from: base)
        check(id.agent.kind.rawValue == "claude" && id.agent.id == AgentID("agent:claude"), "default agent")
        check(id.sessionID == SessionID("claude:sess-1") && id.externalRef == "sess-1" && id.workingDirectory == "/work/app", "session identity")
        check(id.host?.kind == .terminal && id.host?.identity == "Apple_Terminal", "terminal host")
        check(HookEventAdapter.identity(from: with(["bipuu_agent": "codex"])).agent.kind.rawValue == "codex", "bipuu_agent names the agent")
        check(HookEventAdapter.identity(from: with(["bipuu_agent": "Not Valid!"])).agent.kind.rawValue == "claude", "invalid bipuu_agent falls back")
        check(HookEventAdapter.identity(from: with(["bipuu_agent": String(repeating: "a", count: 25)])).agent.kind.rawValue == "claude", "too long")
        check(HookEventAdapter.identity(from: with(["bundle_id": "com.todesktop.230313mzl4w4u92"])).agent.kind.rawValue == "cursor", "Cursor bundle id")
        check(HookEventAdapter.identity(from: with(["bundle_id": "com.todesktop.230313mzl4w4u92"])).host?.kind == .editor, "Cursor is an editor host")
        check(HookEventAdapter.identity(from: ["term_program": "vscode"]).host?.kind == .editor, "VS Code is an editor host")
        check(HookEventAdapter.identity(from: ["cwd": "/x"]).host == nil, "no host information, no host")
        check(HookEventAdapter.identity(from: ["bundle_id": "com.example.app"]).host?.kind == .other, "unknown bundle is 'other'")
        // The same message always yields the same ids (deterministic), different sessions differ.
        check(HookEventAdapter.identity(from: base) == id, "deterministic identity")
        check(HookEventAdapter.identity(from: with(["session_id": "sess-2"])).sessionID != id.sessionID, "other session, other id")
        // A session without an id is told apart by agent + directory.
        for missing: [String: Any] in [["cwd": "/a"], ["cwd": "/a", "session_id": "unknown"], ["cwd": "/a", "session_id": ""]] {
            let m = HookEventAdapter.identity(from: missing)
            check(m.sessionID == SessionID("claude:claude+/a") && m.externalRef == nil, "anonymous session \(missing)")
        }
        check(HookEventAdapter.identity(from: ["cwd": "/b"]).sessionID != HookEventAdapter.identity(from: ["cwd": "/a"]).sessionID, "anonymous sessions in different directories")
        check(HookEventAdapter.identity(from: ["conversation_id": "conv"]).sessionID == SessionID("claude:conv"), "conversation_id is accepted")

        // Envelope: neutral, stamped, source set; no vendor field leaks.
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let h = HookEventAdapter.hook(name: "PostToolUse", payload: with(["tool_name": "Edit"]), now: when)!
        check(h.event.occurredAt == when && h.event.receivedAt == when, "times come from the receive moment")
        check(h.event.source == HookEventAdapter.source && h.event.projectID == nil && h.event.taskID == nil, "source set, no project/task")
        check(h.event.agentID == AgentID("agent:claude") && h.event.hostID == HostID("host:Apple_Terminal") && h.event.sessionID == id.sessionID, "ids")
        check(h.event.payload["tool"]?.stringValue == "Edit" && h.event.payload["category"]?.stringValue == "edit", "tool payload")

        // Privacy: content never reaches an event.
        let secrets = ["sk-SECRET-prompt", "rm -rf /secret/path", "/Users/me/.ssh/id_rsa", "password=hunter2", "assistant said secret", "notice text secret"]
        let loaded = with(["prompt": secrets[0], "tool_name": "Bash", "last_assistant_message": secrets[4], "message": secrets[5],
                           "tool_input": ["command": secrets[1], "file_path": secrets[2], "content": secrets[3]] as [String: Any],
                           "hook_event_name": "PostToolUse", "permission_suggestions": [["type": "addRules"]]])
        var events: [AgentEvent] = []
        for name in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop", "Notification", "SessionStart", "SubagentStop"] {
            events.append(HookEventAdapter.hook(name: name, payload: loaded)!.event)
        }
        events.append(HookEventAdapter.approvalRequested(payload: loaded, approvalID: UUID()).event)
        events.append(HookEventAdapter.questionRequested(payload: loaded).event)
        let json = events.map { String(decoding: (try? BipuuCoding.encoder().encode($0)) ?? Data(), as: UTF8.self) }.joined()
        check(!json.isEmpty, "events encode")
        for s in secrets { check(!json.contains(s), "event JSON must not contain \"\(s)\"") }
        check(!json.contains("hook_event_name") && !json.contains("permission_suggestions"), "no vendor field names in events")

        // Approvals.
        let uuid = UUID()
        let req = HookEventAdapter.approvalRequested(payload: with(["tool_name": "Bash"]), approvalID: uuid)
        check(req.event.kind == .approvalRequested && req.event.payload[PayloadKey.approvalID]?.stringValue == uuid.uuidString, "approval requested")
        check(req.event.payload["category"]?.stringValue == "execute" && req.identity.sessionID == id.sessionID, "approval category and session")
        for (wire, outcome) in [("allow", "allow"), ("always", "allowAlways"), ("deny", "deny"), ("ask", "deferred")] as [(String?, String)] + [(nil, "withdrawn")] {
            let r = HookEventAdapter.approvalResolved(identity: id, approvalID: uuid, decision: wire)
            check(r.event.kind == .approvalResolved && r.event.payload["decision"]?.stringValue == outcome
                  && r.event.payload[PayloadKey.approvalID]?.stringValue == uuid.uuidString, "resolved \(wire ?? "nil") -> \(outcome)")
        }
        // The projection pairs request and resolution through the approval id.
        let open = SessionSummary.fold(sessionID: id.sessionID, events: [req.event])
        let done = SessionSummary.fold(sessionID: id.sessionID, events: [req.event, HookEventAdapter.approvalResolved(identity: id, approvalID: uuid, decision: "allow").event])
        check(open.pendingApprovals == [uuid.uuidString] && done.pendingApprovals.isEmpty, "projection pairs request and resolution")

        // Categories and notices.
        for (tool, cat) in [("Read", "read"), ("Grep", "read"), ("Edit", "edit"), ("Write", "edit"), ("apply_patch", "edit"),
                            ("Bash", "execute"), ("shell", "execute"), ("WebFetch", "other"), ("", "other"), ("mcp__x__y", "other")] {
            check(HookEventAdapter.toolCategory(tool) == cat, "\(tool) -> \(cat)")
        }
        func notice(_ m: String) -> String? { HookEventAdapter.hook(name: "Notification", payload: with(["message": m]))?.event.payload["category"]?.stringValue }
        check(notice("Rate limit reached") == "rate-limit" && notice("Proceed?") == "question" && notice("Done") == "other" && notice("") == "other", "notice categories")
        let long = HookEventAdapter.hook(name: "PreToolUse", payload: with(["tool_name": String(repeating: "t", count: 500)]))!
        check(long.event.payload["tool"]?.stringValue?.count == 64, "tool names are capped")

        if failures == 0 { print("Hook event adapter: all cases passed") } else { print("\(failures) failure(s)"); exit(1) }
    }
}
