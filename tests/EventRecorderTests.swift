import Foundation
import SQLite3
import BipuuCore
import BipuuSQLite

@main
struct EventRecorderTests {
    nonisolated(unsafe) static var failures = 0
    static func check(_ ok: Bool, _ msg: String, line: Int = #line) {
        if !ok { failures += 1; print("FAIL line \(line): \(msg)") }
    }

    static func tempPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("bipuu-rec-\(UUID().uuidString)/events.sqlite").path
    }
    static func cleanup(_ path: String) { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
    static func mode(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? Int) ?? -1
    }
    static func userVersion(_ path: String) -> Int {
        var db: OpaquePointer?; sqlite3_open(path, &db); defer { sqlite3_close(db) }
        var s: OpaquePointer?; sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &s, nil); defer { sqlite3_finalize(s) }
        sqlite3_step(s); return Int(sqlite3_column_int64(s, 0))
    }

    static func hook(_ name: String, _ t: Double, session: String = "S1", agent: String? = nil, cwd: String = "/work/app",
                     extra: [String: Any] = [:]) -> RecordedHook {
        var p: [String: Any] = ["session_id": session, "cwd": cwd, "term_program": "Apple_Terminal", "tool_name": "Bash"]
        if let agent { p["bipuu_agent"] = agent }
        return HookEventAdapter.hook(name: name, payload: p.merging(extra) { $1 }, now: Date(timeIntervalSince1970: t))!
    }

    static func main() async throws {
        // 1. A whole session is recorded: events in order, entities created, session unattached.
        do {
            let path = tempPath(); defer { cleanup(path) }
            let rec = EventRecorder(databasePath: path)
            let names = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"]
            for (i, n) in names.enumerated() { rec.submit(hook(n, 1_000 + Double(i))) }
            await rec.flush()
            check(rec.recordedCount == 6 && rec.failedCount == 0 && rec.droppedCount == 0, "counters \(rec.recordedCount)/\(rec.failedCount)/\(rec.droppedCount)")
            await rec.stop()

            let events = try SQLiteEventStore(path: path), domain = try SQLiteDomainStore(path: path)
            let got = try await events.events(forSession: SessionID("claude:S1"))
            check(got.map(\.kind.rawValue) == ["session.started", "prompt.submitted", "tool.started", "tool.finished", "turn.finished", "session.ended"], "kinds in order \(got.map(\.kind.rawValue))")
            let session = try await domain.session(SessionID("claude:S1"))
            check(session?.taskID == nil && session?.agentID == AgentID("agent:claude") && session?.hostID == HostID("host:Apple_Terminal"), "session saved, unattached")
            check(session?.workingDirectory == "/work/app" && session?.externalRef == "S1", "session metadata")
            check(session?.startedAt == Date(timeIntervalSince1970: 1_000) && session?.endedAt == Date(timeIntervalSince1970: 1_005), "start and end times")
            check(try await domain.agent(AgentID("agent:claude"))?.kind.rawValue == "claude", "agent saved")
            check(try await domain.host(HostID("host:Apple_Terminal"))?.kind == .terminal, "host saved")
            check(try await domain.unattachedSessions().count == 1, "listed as unattached")
            let proj = Projections(events: events, domain: domain)
            check(try await proj.sessionSummary(SessionID("claude:S1")).phase == .ended, "projection sees the session ended")
            check(mode(path) == 0o600, "database file is owner-only (\(String(mode(path), radix: 8)))")
            check(mode((path as NSString).deletingLastPathComponent) == 0o700, "its directory is owner-only")
            await events.close(); await domain.close()
        }

        // 2. Later events never overwrite what happened to the session meanwhile (task assignment).
        do {
            let path = tempPath(); defer { cleanup(path) }
            let rec = EventRecorder(databasePath: path)
            rec.submit(hook("SessionStart", 1)); await rec.flush()
            let domain = try SQLiteDomainStore(path: path)
            try await domain.save(WorkTask(id: TaskID("t"), title: "T", createdAt: Date(timeIntervalSince1970: 1)))
            try await domain.assign(session: SessionID("claude:S1"), to: TaskID("t"))
            rec.submit(hook("PreToolUse", 2)); rec.submit(hook("SessionEnd", 3)); await rec.flush()
            let s = try await domain.session(SessionID("claude:S1"))
            check(s?.taskID == TaskID("t"), "task assignment survives later events")
            check(s?.endedAt == Date(timeIntervalSince1970: 3), "ended time recorded on top of it")
            await rec.stop(); await domain.close()
        }

        // 2b. After a restart (empty caches) an existing, assigned session is still left alone.
        do {
            let path = tempPath(); defer { cleanup(path) }
            let first = EventRecorder(databasePath: path)
            first.submit(hook("SessionStart", 1)); await first.stop()
            let domain = try SQLiteDomainStore(path: path)
            try await domain.save(WorkTask(id: TaskID("t"), title: "T", createdAt: Date(timeIntervalSince1970: 1)))
            try await domain.assign(session: SessionID("claude:S1"), to: TaskID("t"))
            let second = EventRecorder(databasePath: path)
            second.submit(hook("PostToolUse", 50)); second.submit(hook("SessionEnd", 60)); await second.stop()
            let s = try await domain.session(SessionID("claude:S1"))
            check(s?.taskID == TaskID("t") && s?.startedAt == Date(timeIntervalSince1970: 1) && s?.endedAt == Date(timeIntervalSince1970: 60),
                  "a restarted recorder keeps the assigned session and its original start")
            await domain.close()
        }

        // 3. Several sessions and agents stay separate.
        do {
            let path = tempPath(); defer { cleanup(path) }
            let rec = EventRecorder(databasePath: path)
            rec.submit(hook("SessionStart", 1, session: "A")); rec.submit(hook("SessionStart", 2, session: "B"))
            rec.submit(hook("SessionStart", 3, session: "A", agent: "codex"))
            await rec.stop()
            let domain = try SQLiteDomainStore(path: path)
            check(try await domain.unattachedSessions().map(\.id.rawValue) == ["claude:A", "claude:B", "codex:A"], "three distinct sessions")
            await domain.close()
        }

        // 4. Approvals: request and resolution pair up through the projection.
        do {
            let path = tempPath(); defer { cleanup(path) }
            let rec = EventRecorder(databasePath: path)
            let uuid = UUID()
            let payload: [String: Any] = ["session_id": "S1", "cwd": "/work/app", "tool_name": "Bash"]
            let req = HookEventAdapter.approvalRequested(payload: payload, approvalID: uuid, now: Date(timeIntervalSince1970: 5))
            rec.submit(req)
            await rec.flush()
            let events = try SQLiteEventStore(path: path), domain = try SQLiteDomainStore(path: path)
            let proj = Projections(events: events, domain: domain)
            check(try await proj.sessionSummary(SessionID("claude:S1")).needsAttention, "pending approval needs attention")
            rec.submit(HookEventAdapter.approvalResolved(identity: req.identity, approvalID: uuid, decision: "allow", now: Date(timeIntervalSince1970: 6)))
            await rec.flush()
            check(try await !proj.sessionSummary(SessionID("claude:S1")).needsAttention, "resolved approval no longer needs attention")
            await rec.stop(); await events.close(); await domain.close()
        }

        // 5. A database that cannot be used switches recording off without side effects.
        do {
            let path = tempPath(); defer { cleanup(path) }
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            var db: OpaquePointer?; sqlite3_open(path, &db); sqlite3_exec(db, "PRAGMA user_version = 99; CREATE TABLE marker(x);", nil, nil, nil); sqlite3_close(db)
            let logs = LogBox()
            let rec = EventRecorder(databasePath: path, log: { logs.add($0) })
            for i in 0..<10 { rec.submit(hook("PreToolUse", Double(i))) }
            await rec.flush()
            check(rec.recordedCount == 0 && rec.failedCount >= 1, "nothing recorded, failure counted")
            check(userVersion(path) == 99, "the newer database is untouched")
            check(logs.lines.count == 1 && logs.lines[0].contains("disabled") && logs.lines[0].contains("newer"), "one explicit log line: \(logs.lines)")
            check(!logs.lines.joined().contains("/work/app"), "logs carry no event content")
            await rec.stop()

            // A path that cannot be a database file (it is a directory) behaves the same.
            let dirPath = (path as NSString).deletingLastPathComponent
            let rec2 = EventRecorder(databasePath: dirPath)
            rec2.submit(hook("Stop", 1)); await rec2.flush()
            check(rec2.recordedCount == 0 && rec2.failedCount >= 1, "unusable path disables recording")
            await rec2.stop()
        }

        // 6. submit never blocks: a burst far past the queue limit returns fast, and nothing is lost silently.
        do {
            let path = tempPath(); defer { cleanup(path) }
            let rec = EventRecorder(databasePath: path)
            let items = (0..<5_000).map { hook("PostToolUse", 1_000 + Double($0), session: "burst") }
            let t0 = Date()
            for item in items { rec.submit(item) }
            let submitSeconds = Date().timeIntervalSince(t0)
            await rec.flush()
            check(submitSeconds < 1.0, "5000 submits took \(submitSeconds)s")
            check(rec.recordedCount + rec.droppedCount == 5_000 && rec.failedCount == 0, "every item recorded or counted as dropped: \(rec.recordedCount)+\(rec.droppedCount)")
            let events = try SQLiteEventStore(path: path)
            let stored = try await events.recentEvents(limit: 10_000)
            check(stored.count == rec.recordedCount, "stored \(stored.count) == recorded \(rec.recordedCount)")
            check(stored == stored.sorted(by: AgentEvent.canonicalOrder) && Set(stored.map(\.id)).count == stored.count, "stored events are ordered and unique")
            await rec.stop(); await events.close()
            print("  burst: 5000 submits in \(String(format: "%.1f", submitSeconds * 1000)) ms, recorded \(rec.recordedCount), dropped \(rec.droppedCount)")
        }

        // 6b. Waiters in flush() are never lost when a full queue pushes items out.
        do {
            let path = tempPath(); defer { cleanup(path) }
            let rec = EventRecorder(databasePath: path)
            await withTaskGroup(of: Void.self) { g in
                for t in 0..<8 {
                    g.addTask {
                        for i in 0..<600 { rec.submit(hook("PostToolUse", Double(i), session: "w\(t)")) }
                        await rec.flush()
                    }
                }
            }
            await rec.flush()
            check(rec.recordedCount + rec.droppedCount == 4_800 && rec.failedCount == 0, "accounted: \(rec.recordedCount)+\(rec.droppedCount)")
            await rec.stop()
            await rec.flush()   // after stop: returns immediately instead of hanging
            check(true, "flush after stop returns")
        }

        // 7. Order of submission is the order of the log.
        do {
            let path = tempPath(); defer { cleanup(path) }
            let rec = EventRecorder(databasePath: path)
            for i in 0..<300 { rec.submit(hook("PostToolUse", 5_000 + Double(i), session: "ordered")) }
            await rec.stop()
            let events = try SQLiteEventStore(path: path)
            let got = try await events.events(forSession: SessionID("claude:ordered"))
            check(got.count == 300 && got.map(\.occurredAt) == (0..<300).map { Date(timeIntervalSince1970: 5_000 + Double($0)) }, "300 events in submission order")
            await events.close()
        }

        // 7b. Task inference: a new session in a repository is proposed a task, and its events carry it.
        do {
            let path = tempPath(); defer { cleanup(path) }
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("bipuu-repo-\(UUID().uuidString)").resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: base) }
            try FileManager.default.createDirectory(at: base.appendingPathComponent("proj/.git"), withIntermediateDirectories: true)
            try "ref: refs/heads/feature/x\n".write(to: base.appendingPathComponent("proj/.git/HEAD"), atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: base.appendingPathComponent("proj/src"), withIntermediateDirectories: true)
            let dir = base.path + "/proj", sub = base.path + "/proj/src"

            let rec = EventRecorder(databasePath: path, inference: InferencePolicy(excludedRoots: ["/", base.path]))
            rec.submit(hook("SessionStart", 100, session: "A", cwd: dir))
            rec.submit(hook("PreToolUse", 101, session: "A", cwd: dir))
            rec.submit(hook("SessionStart", 102, session: "B", cwd: sub))            // another session, same repository
            rec.submit(hook("SessionStart", 103, session: "C", cwd: "/does/not/exist"))
            await rec.flush()
            let events = try SQLiteEventStore(path: path), domain = try SQLiteDomainStore(path: path)
            let a = try await domain.session(SessionID("claude:A")), b = try await domain.session(SessionID("claude:B"))
            check(a?.taskID != nil && a?.taskID == b?.taskID, "two sessions of one repository share a task")
            let task = try await domain.task(a!.taskID!)
            check(task?.origin == .inferred && task?.title == "proj · feature/x", "proposed, titled by project and branch: \(String(describing: task?.title))")
            let project = try await domain.projects()
            check(project.count == 1 && project[0].roots == [base.path + "/proj"] && task?.projectID == project[0].id, "project discovered from the repository root")
            check(try await domain.session(SessionID("claude:C"))?.taskID == nil, "a directory that does not exist is left unattached")
            let all = try await events.events(forSession: SessionID("claude:A"))
            check(all.count == 2 && all.allSatisfy { $0.taskID == task?.id && $0.projectID == project[0].id }, "events carry the task and project")
            check(try await events.events(forSession: SessionID("claude:C")).allSatisfy { $0.taskID == nil }, "events of an unattached session carry none")
            check(try await events.events(forTask: task!.id).count == 3, "events(forTask:) now finds them")
            let summary = try await Projections(events: events, domain: domain).taskSummary(task!.id)
            check(summary.sessionCount == 2 && summary.workingSessionCount == 1, "task projection \(summary)")

            // The user detaches session A. Later events follow the new attribution and nothing re-attaches it.
            try await domain.assign(session: SessionID("claude:A"), to: nil)
            rec.submit(hook("PostToolUse", 110, session: "A", cwd: dir))
            await rec.flush()
            check(try await domain.session(SessionID("claude:A"))?.taskID == nil, "a detached session stays detached")
            let after = try await events.events(forSession: SessionID("claude:A"))
            check(after.map(\.taskID) == [task?.id, task?.id, nil], "history keeps its attribution; new events follow the current one")
            await rec.stop()

            // After a restart (empty caches) an existing session is not proposed a task again.
            let again = EventRecorder(databasePath: path, inference: InferencePolicy(excludedRoots: ["/", base.path]))
            again.submit(hook("PostToolUse", 120, session: "A", cwd: dir)); await again.stop()
            check(try await domain.session(SessionID("claude:A"))?.taskID == nil, "a restart does not undo the user's detach")
            check(try await domain.unattachedSessions().map(\.id.rawValue).sorted() == ["claude:A", "claude:C"], "unattached: A (detached), C")
            await events.close(); await domain.close()
        }

        // 8. The default location honours the override and otherwise lives in the support directory.
        check(EventRecorder.defaultDatabasePath(supportDir: URL(fileURLWithPath: "/tmp/support")).hasSuffix(ProcessInfo.processInfo.environment["BIPUU_EVENT_DB"] ?? "/tmp/support/bipuu.sqlite"), "default path")

        if failures == 0 { print("Event recorder: all cases passed") } else { print("\(failures) failure(s)"); exit(1) }
    }
}

final class LogBox: @unchecked Sendable {
    private let lock = NSLock(); private var _lines: [String] = []
    func add(_ s: String) { lock.lock(); _lines.append(s); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
}
