import Foundation
import SwiftUI
import AppKit
import SQLite3
import BipuuCore
import BipuuSQLite

@main @MainActor
struct WorkModelTests {
    static var failures = 0
    static func check(_ ok: Bool, _ msg: String, line: Int = #line) {
        if !ok { failures += 1; print("FAIL line \(line): \(msg)") }
    }

    /// Waits (letting the main run loop run) until `condition` holds or `seconds` pass.
    static func wait(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    static func hook(_ name: String, _ t: Double, session: String, cwd: String, extra: [String: Any] = [:]) -> RecordedHook {
        let p: [String: Any] = ["session_id": session, "cwd": cwd, "term_program": "Apple_Terminal", "tool_name": "Bash"]
        return HookEventAdapter.hook(name: name, payload: p.merging(extra) { $1 }, now: Date(timeIntervalSince1970: t))!
    }

    static func main() async {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("bipuu-wm-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: base) }
        try! fm.createDirectory(at: base.appendingPathComponent("proj/.git"), withIntermediateDirectories: true)
        try! "ref: refs/heads/feature/work\n".write(to: base.appendingPathComponent("proj/.git/HEAD"), atomically: true, encoding: .utf8)
        let repo = base.path + "/proj"
        let dbPath = base.path + "/data/bipuu.sqlite"
        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : base.path

        // 1. No database: the model says so and does not create one.
        let model = WorkModel(databasePath: { dbPath })
        model.viewDidAppear()
        check(await wait { model.status == .noDatabase }, "status without a database: \(model.status)")
        check(!fm.fileExists(atPath: dbPath), "reading never creates the database")
        model.viewDidDisappear()

        // 2. A real recorder fills the database; the model sees a proposed task.
        let recorder = EventRecorder(databasePath: dbPath, inference: InferencePolicy(excludedRoots: ["/", base.path]),
                                     onWrite: { NotificationCenter.default.post(name: .workDataChanged, object: nil) })
        recorder.submit(hook("SessionStart", 1_000, session: "A", cwd: repo))
        recorder.submit(hook("UserPromptSubmit", 1_001, session: "A", cwd: repo))
        recorder.submit(hook("PreToolUse", 1_002, session: "A", cwd: repo))
        recorder.submit(hook("SessionStart", 1_003, session: "Loose", cwd: "/does/not/exist"))
        await recorder.flush()

        model.viewDidAppear()
        check(await wait { model.status == .ready && model.overview.taskCount == 1 }, "model reads the recorded work: \(model.status) \(model.overview.taskCount)")
        let row = model.overview.groups.first?.tasks.first
        check(row?.isProposed == true && row?.task.title == "proj · feature/work", "proposed task: \(String(describing: row?.task.title))")
        check(row?.summary.workingSessionCount == 1 && model.overview.unattachedSessionCount == 1, "working session and one unattached")
        check(model.overview.groups.first?.project?.name == "proj", "project name")
        _ = render(model, to: out + "/work-model-live.png")

        // 3. A new event refreshes the visible view by itself (notification, debounced), without polling.
        let before = model.now
        recorder.submit(hook("PreToolUse", 1_010, session: "B", cwd: repo))
        await recorder.flush()
        check(await wait { (model.overview.groups.first?.tasks.first?.summary.sessionCount ?? 0) == 2 }, "an event updates the visible list")
        check(model.now > before, "refresh timestamp moved")

        // 4. Confirming from the view: the proposal becomes the user's task; later sessions still join it.
        let taskID = model.overview.groups[0].tasks[0].task.id
        model.confirm(taskID)
        check(await wait { model.overview.groups.first?.tasks.first?.isProposed == false }, "confirm turns the proposal into a task")
        recorder.submit(hook("SessionStart", 1_020, session: "C", cwd: repo)); await recorder.flush()
        check(await wait { (model.overview.groups.first?.tasks.first?.summary.sessionCount ?? 0) == 3 && model.overview.taskCount == 1 },
              "a later session joins the confirmed task")

        // 5. Renaming (also of a task the user owns).
        model.rename(taskID, to: "  Ship the work view  ")
        check(await wait { model.overview.groups.first?.tasks.first?.task.title == "Ship the work view" }, "rename trims and applies: \(String(describing: model.overview.groups.first?.tasks.first?.task.title))")
        model.rename(taskID, to: "   ")
        try? await Task.sleep(for: .milliseconds(600))
        check(model.overview.groups.first?.tasks.first?.task.title == "Ship the work view", "an empty name changes nothing")
        _ = render(model, to: out + "/work-model-confirmed.png")

        // 6. Hidden means idle: no refresh, no reads while the view is not shown.
        model.viewDidDisappear()
        let frozen = model.overview
        recorder.submit(hook("SessionStart", 1_030, session: "D", cwd: repo)); await recorder.flush()
        try? await Task.sleep(for: .milliseconds(900))
        check(model.overview == frozen, "a hidden view does not follow events")
        model.viewDidAppear()
        check(await wait { (model.overview.groups.first?.tasks.first?.summary.sessionCount ?? 0) == 4 }, "showing it again catches up")
        model.viewDidDisappear()
        await recorder.stop()

        // 7. A database from a newer Bipuu is reported, never touched.
        let newer = base.path + "/newer.sqlite"
        var db: OpaquePointer?; sqlite3_open(newer, &db); sqlite3_exec(db, "PRAGMA user_version = 99; CREATE TABLE marker(x);", nil, nil, nil); sqlite3_close(db)
        let failing = WorkModel(databasePath: { newer })
        failing.viewDidAppear()
        check(await wait { if case .failed = failing.status { return true } else { return false } }, "unsupported database is a failure state, not a crash")
        failing.viewDidDisappear()
        sqlite3_open(newer, &db); var st: OpaquePointer?; sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &st, nil); sqlite3_step(st)
        check(sqlite3_column_int(st, 0) == 99, "…and left untouched"); sqlite3_finalize(st); sqlite3_close(db)

        if failures == 0 { print("Work model: all cases passed") } else { print("\(failures) failure(s)"); exit(1) }
    }

    /// The list as the island draws it, from the model's real data.
    static func render(_ model: WorkModel, to path: String) -> Bool {
        _ = NSApplication.shared
        let view = ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 22).fill(Color(hex: "#0B0C0F"))
            RoundedRectangle(cornerRadius: 16).fill(Color(hex: "#15171B")).padding(.horizontal, 8).padding(.top, 36).padding(.bottom, 8)
            WorkOverviewList(overview: model.overview, now: model.now)
                .padding(.leading, 98).padding(.trailing, 16).padding(.top, 42).padding(.bottom, 14)
        }
        .frame(width: 640, height: 160).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 160)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
