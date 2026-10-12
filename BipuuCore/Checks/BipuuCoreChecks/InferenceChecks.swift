import Foundation
import BipuuCore
import BipuuChecking

/// Answers from a table, so inference rules are tested without touching a disk.
struct FakeLocator: WorkContextLocator {
    var table: [String: WorkContext]
    func context(forDirectory path: String) -> WorkContext? { table[path] }
}

struct InferenceChecks {
    private func at(_ s: Double) -> Date { Date(timeIntervalSince1970: s) }
    private let hour = 3600.0

    private struct Rig {
        let domain = InMemoryDomainStore()
        let events = InMemoryEventStore()
        var inferrer: TaskInferrer
        init(_ table: [String: WorkContext], policy: InferencePolicy = InferencePolicy()) {
            inferrer = TaskInferrer(domain: domain, events: events, locator: FakeLocator(table: table), policy: policy)
        }
        func session(_ id: String, dir: String?, start: Double, task: TaskID? = nil) async throws {
            try await domain.save(Agent(id: AgentID("a"), kind: "k", displayName: "A"))
            if let task { _ = task }
            try await domain.save(Session(id: SessionID(id), taskID: task, agentID: AgentID("a"), workingDirectory: dir,
                                          startedAt: Date(timeIntervalSince1970: start)))
        }
        func activity(_ session: String, at t: Double) async throws {
            _ = try await events.append(AgentEvent(occurredAt: Date(timeIntervalSince1970: t), receivedAt: Date(timeIntervalSince1970: t),
                                                   sessionID: SessionID(session), kind: .toolFinished, source: EventSource(adapter: "t")))
        }
    }

    private let repo = WorkContext(projectRoot: "/code/app", branch: "main")

    func newSessionGetsAProposedTask() async throws {
        let r = Rig(["/code/app": repo])
        try await r.session("s1", dir: "/code/app", start: 100)
        let p = try await r.inferrer.place(session: SessionID("s1"), at: at(100))
        guard case .attached(let taskID, let created) = p else { try await check(false, "expected attach, got \(p)"); return }
        try await check(created)
        let task = try await r.domain.task(taskID)
        try await check(task?.origin == .inferred && task?.status == .open && task?.title == "app · main", "title/origin \(String(describing: task))")
        try await check(task?.inferenceKey?.hasPrefix("/code/app") == true)
        try await check(try await r.domain.session(SessionID("s1"))?.taskID == taskID)
        // The project was discovered from the root, once.
        let project = try await r.domain.projects()
        try await check(project.count == 1 && project[0].roots == ["/code/app"] && project[0].name == "app" && task?.projectID == project[0].id)
        try await check(try await r.domain.unattachedSessions().isEmpty)
    }

    func sessionsInTheSameContextShareATask() async throws {
        let r = Rig(["/code/app": repo, "/code/app/sub": repo])
        try await r.session("s1", dir: "/code/app", start: 0)
        try await r.session("s2", dir: "/code/app/sub", start: 2 * hour)     // a subdirectory of the same repo
        let a = try await r.inferrer.place(session: SessionID("s1"), at: at(0))
        let b = try await r.inferrer.place(session: SessionID("s2"), at: at(2 * hour))
        guard case .attached(let t1, true) = a, case .attached(let t2, false) = b else { try await check(false, "\(a) \(b)"); return }
        try await check(t1 == t2)
        try await check(try await r.domain.sessions(forTask: t1).count == 2)
        try await check(try await r.domain.projects().count == 1)
        try await check(try await r.domain.task(t1)?.updatedAt == at(2 * hour), "joining bumps updatedAt")
    }

    func idleGapStartsANewTask() async throws {
        let r = Rig(["/code/app": repo])
        try await r.session("s1", dir: "/code/app", start: 0)
        guard case .attached(let t1, _) = try await r.inferrer.place(session: SessionID("s1"), at: at(0)) else { return }
        // Long-running work keeps the task alive: the session's events count, not only its start.
        try await r.activity("s1", at: 20 * hour)
        try await r.session("s2", dir: "/code/app", start: 25 * hour)
        guard case .attached(let t2, let created2) = try await r.inferrer.place(session: SessionID("s2"), at: at(25 * hour)) else { return }
        try await check(t2 == t1 && !created2, "5 h after its last event the task is still the same")
        try await r.session("s3", dir: "/code/app", start: 60 * hour)
        guard case .attached(let t3, let created3) = try await r.inferrer.place(session: SessionID("s3"), at: at(60 * hour)) else { return }
        try await check(t3 != t1 && created3, "35 h later a new task starts")
        let only = try await r.domain.projects()
        try await check(only.count == 1)
        try await check(try await r.domain.tasks(inProject: only[0].id).count == 2)
    }

    func branchesAreSeparateUnlessAskedOtherwise() async throws {
        let table = ["/code/app": repo, "/code/app-wt": WorkContext(projectRoot: "/code/app", branch: "feature/x")]
        for (separate, sameTask) in [(true, false), (false, true)] {
            let r = Rig(table, policy: InferencePolicy(separateBranches: separate))
            try await r.session("s1", dir: "/code/app", start: 0)
            try await r.session("s2", dir: "/code/app-wt", start: hour)
            guard case .attached(let a, _) = try await r.inferrer.place(session: SessionID("s1"), at: at(0)),
                  case .attached(let b, _) = try await r.inferrer.place(session: SessionID("s2"), at: at(hour)) else { return }
            try await check((a == b) == sameTask, "separateBranches=\(separate)")
            try await check(try await r.domain.projects().count == 1, "worktrees of one repository are one project")
        }
        let r = Rig(["/code/app": repo, "/code/app-wt": WorkContext(projectRoot: "/code/app", branch: "feature/x")])
        try await r.session("s1", dir: "/code/app-wt", start: 0)
        guard case .attached(let t, _) = try await r.inferrer.place(session: SessionID("s1"), at: at(0)) else { return }
        try await check(try await r.domain.task(t)?.title == "app · feature/x")
    }

    func existingAssignmentsAreNeverTouched() async throws {
        let r = Rig(["/code/app": repo])
        try await r.domain.save(WorkTask(id: TaskID("mine"), title: "Mine", createdAt: at(0)))
        try await r.session("s1", dir: "/code/app", start: 0, task: TaskID("mine"))
        try await check(try await r.inferrer.place(session: SessionID("s1"), at: at(1)) == .skipped(.alreadyAssigned))
        try await check(try await r.domain.session(SessionID("s1"))?.taskID == TaskID("mine"))
        try await check(try await r.domain.tasks(inProject: ProjectID("dir:/code/app")).isEmpty)
        try await check(try await r.domain.projects().isEmpty)
    }

    func handMadeTasksAreNotJoined() async throws {
        let r = Rig(["/code/app": repo])
        // Same project, open, recently active, but no inference key: the user's own, left alone.
        let p = Project(id: ProjectID("p"), name: "App", roots: ["/code/app"], createdAt: at(0))
        try await r.domain.save(p)
        try await r.domain.save(WorkTask(id: TaskID("mine"), projectID: p.id, title: "Mine", createdAt: at(0)))
        try await r.session("s1", dir: "/code/app", start: 10)
        guard case .attached(let t, let created) = try await r.inferrer.place(session: SessionID("s1"), at: at(10)) else { return }
        try await check(t != TaskID("mine") && created)
        try await check(try await r.domain.projects().count == 1, "the user's project that lists the root is reused, none invented")
        try await check(try await r.domain.task(t)?.projectID == p.id)
    }

    func confirmKeepsGroupingAndNeverOthers() async throws {
        let r = Rig(["/code/app": repo])
        try await r.session("s1", dir: "/code/app", start: 0)
        guard case .attached(let t, _) = try await r.inferrer.place(session: SessionID("s1"), at: at(0)) else { return }
        try await r.inferrer.confirm(task: t, title: "Ship the importer", at: at(5))
        let confirmed = try await r.domain.task(t)
        try await check(confirmed?.origin == .explicit && confirmed?.title == "Ship the importer" && confirmed?.inferenceKey != nil)
        try await r.session("s2", dir: "/code/app", start: hour)
        guard case .attached(let t2, false) = try await r.inferrer.place(session: SessionID("s2"), at: at(hour)) else { try await check(false, "later session should join the confirmed task"); return }
        try await check(t2 == t)
        try await checkThrows(DomainStoreError.notFound(entity: "task", id: "ghost")) { try await r.inferrer.confirm(task: TaskID("ghost"), at: at(1)) }
    }

    func closedTasksAreNotReopened() async throws {
        let r = Rig(["/code/app": repo])
        try await r.session("s1", dir: "/code/app", start: 0)
        guard case .attached(let t, _) = try await r.inferrer.place(session: SessionID("s1"), at: at(0)) else { return }
        var task = try await r.domain.task(t)!; task.status = .completed; try await r.domain.save(task)
        try await r.session("s2", dir: "/code/app", start: hour)
        guard case .attached(let t2, true) = try await r.inferrer.place(session: SessionID("s2"), at: at(hour)) else { try await check(false, "expected a new task"); return }
        try await check(t2 != t)
    }

    func skipsWhatCannotBePlaced() async throws {
        let r = Rig(["/": WorkContext(projectRoot: "/", branch: nil), "/home/u": WorkContext(projectRoot: "/home/u", branch: nil),
                     "/home/u/proj": WorkContext(projectRoot: "/home/u", branch: "dots")],
                    policy: InferencePolicy(excludedRoots: ["/", "/home/u"]))
        try await r.session("none", dir: nil, start: 0)
        try await r.session("empty", dir: "", start: 0)
        try await r.session("gone", dir: "/does/not/exist", start: 0)
        try await r.session("root", dir: "/", start: 0)
        try await r.session("home", dir: "/home/u", start: 0)
        try await check(try await r.inferrer.place(session: SessionID("none"), at: at(1)) == .skipped(.noDirectory))
        try await check(try await r.inferrer.place(session: SessionID("empty"), at: at(1)) == .skipped(.noDirectory))
        try await check(try await r.inferrer.place(session: SessionID("gone"), at: at(1)) == .skipped(.noContext))
        try await check(try await r.inferrer.place(session: SessionID("root"), at: at(1)) == .skipped(.excludedRoot))
        try await check(try await r.inferrer.place(session: SessionID("home"), at: at(1)) == .skipped(.excludedRoot))
        try await check(try await r.domain.projects().isEmpty)
        try await check(try await r.domain.unattachedSessions().count == 5)
        try await checkThrows(DomainStoreError.notFound(entity: "session", id: "ghost")) { _ = try await r.inferrer.place(session: SessionID("ghost"), at: at(1)) }
        // A session inside a too-broad repository (a dotfiles repo in $HOME) is grouped by its own directory.
        try await r.session("deep", dir: "/home/u/proj", start: 0)
        guard case .attached(let t, true) = try await r.inferrer.place(session: SessionID("deep"), at: at(1)) else { try await check(false, "deep session should be grouped by its own directory"); return }
        let project = try await r.domain.projects()
        try await check(project.map(\.roots) == [["/home/u/proj"]] && project[0].name == "proj", "own directory became the project")
        try await check(try await r.domain.task(t)?.title == "proj")
    }

    func inferenceKeyPersistsAndOldDataStillDecodes() async throws {
        let t = WorkTask(id: TaskID("t"), title: "T", origin: .inferred, inferenceKey: "k", createdAt: at(1))
        try await check(try BipuuCoding.decoder().decode(WorkTask.self, from: BipuuCoding.encoder().encode(t)) == t)
        let old = #"{"id":"t","title":"T","origin":"explicit","status":"open","createdAt":1,"updatedAt":1}"#
        let decoded = try BipuuCoding.decoder().decode(WorkTask.self, from: Data(old.utf8))
        try await check(decoded.inferenceKey == nil && decoded.title == "T", "tasks stored before this field existed still decode")
    }

    // MARK: the real locator, on real directories

    func gitLocatorFindsRepositoriesWorktreesAndPlainDirectories() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("bipuu-loc-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: base) }
        func mkdir(_ p: String) -> String { let u = base.appendingPathComponent(p); try? fm.createDirectory(at: u, withIntermediateDirectories: true); return u.path }
        func write(_ p: String, _ s: String) { try? s.write(to: base.appendingPathComponent(p), atomically: true, encoding: .utf8) }
        let loc = GitWorkContextLocator()

        // A repository on a branch with a slash in its name; a subdirectory resolves to the same root.
        _ = mkdir("repo/.git"); write("repo/.git/HEAD", "ref: refs/heads/feature/login\n")
        let deep = mkdir("repo/src/deep")
        try await check(loc.context(forDirectory: deep) == WorkContext(projectRoot: base.path + "/repo", branch: "feature/login"))
        try await check(loc.context(forDirectory: base.path + "/repo")?.projectRoot == base.path + "/repo")
        // A symlink to the repository is the same project.
        try fm.createSymbolicLink(at: base.appendingPathComponent("link"), withDestinationURL: base.appendingPathComponent("repo"))
        try await check(loc.context(forDirectory: base.path + "/link/src")?.projectRoot == base.path + "/repo")
        // Detached HEAD: a root, no branch.
        _ = mkdir("det/.git"); write("det/.git/HEAD", "3f2a9c1d0e8b7a6f5e4d3c2b1a09f8e7d6c5b4a3\n")
        try await check(loc.context(forDirectory: base.path + "/det") == WorkContext(projectRoot: base.path + "/det", branch: nil))
        // A linked worktree: its own branch, the main repository's root.
        _ = mkdir("repo/.git/worktrees/wt"); write("repo/.git/worktrees/wt/HEAD", "ref: refs/heads/fix/bug\n")
        _ = mkdir("wt"); write("wt/.git", "gitdir: \(base.path)/repo/.git/worktrees/wt\n")
        try await check(loc.context(forDirectory: base.path + "/wt") == WorkContext(projectRoot: base.path + "/repo", branch: "fix/bug"), "worktree")
        // A relative gitdir works too.
        _ = mkdir("wt2"); write("wt2/.git", "gitdir: ../repo/.git/worktrees/wt\n")
        try await check(loc.context(forDirectory: base.path + "/wt2")?.projectRoot == base.path + "/repo")
        // A submodule is a project of its own.
        _ = mkdir("repo/.git/modules/sub"); write("repo/.git/modules/sub/HEAD", "ref: refs/heads/main\n")
        _ = mkdir("repo/sub"); write("repo/sub/.git", "gitdir: ../.git/modules/sub\n")
        try await check(loc.context(forDirectory: base.path + "/repo/sub") == WorkContext(projectRoot: base.path + "/repo/sub", branch: "main"))
        // Outside any repository the directory is its own root; a broken .git file does not crash.
        let plain = mkdir("plain/inner")
        try await check(loc.context(forDirectory: plain) == WorkContext(projectRoot: plain, branch: nil))
        _ = mkdir("broken"); write("broken/.git", "garbage")
        try await check(loc.context(forDirectory: base.path + "/broken")?.branch == nil)
        // Missing paths and files are not directories.
        try await check(loc.context(forDirectory: base.path + "/nope") == nil && loc.context(forDirectory: "") == nil)
        write("afile", "x"); try await check(loc.context(forDirectory: base.path + "/afile") == nil)
    }

    func inferenceWorksEndToEndWithTheRealLocator() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("bipuu-inf-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: base.appendingPathComponent("r/.git"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: base.appendingPathComponent("r/.git/HEAD"), atomically: true, encoding: .utf8)
        let domain = InMemoryDomainStore(), events = InMemoryEventStore()
        let inferrer = TaskInferrer(domain: domain, events: events, locator: GitWorkContextLocator())
        try await domain.save(Agent(id: AgentID("a"), kind: "k", displayName: "A"))
        try await domain.save(Session(id: SessionID("s"), agentID: AgentID("a"), workingDirectory: base.path + "/r", startedAt: at(1)))
        guard case .attached(let t, true) = try await inferrer.place(session: SessionID("s"), at: at(1)) else { try await check(false, "no attach"); return }
        try await check(try await domain.task(t)?.title == "r · main")
        try await check(try await Projections(events: events, domain: domain).taskSummary(t).sessionCount == 1)
    }
}
