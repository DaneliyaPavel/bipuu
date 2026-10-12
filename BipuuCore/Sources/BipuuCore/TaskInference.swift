import Foundation

public struct InferencePolicy: Sendable, Equatable {
    /// A task whose latest activity is older than this is not joined; a new one starts.
    public var idleGap: TimeInterval
    /// Different branches of one project are different tasks.
    public var separateBranches: Bool
    /// Project roots that are too broad to be a project (the file system root, the home directory).
    /// A session working *inside* such a directory is grouped by its own directory instead.
    public var excludedRoots: Set<String>

    public init(idleGap: TimeInterval = 12 * 3600, separateBranches: Bool = true, excludedRoots: Set<String> = ["/"]) {
        self.idleGap = idleGap; self.separateBranches = separateBranches; self.excludedRoots = excludedRoots
    }
}

public enum Placement: Equatable, Sendable {
    case attached(task: TaskID, created: Bool)
    case skipped(Reason)

    public enum Reason: String, Equatable, Sendable {
        /// The session already has a task (the user's, or an earlier inference): never moved.
        case alreadyAssigned
        case noDirectory
        /// The directory does not exist.
        case noContext
        /// The session's directory is itself a root that is too broad to group by.
        case excludedRoot
    }
}

/// Proposes a task for a session that has none.
///
/// Rules (all documented in docs/TASK_INFERENCE.md):
/// 1. Runs for one session at a time and never touches a session that already has a task.
/// 2. The context is the session's working directory → (project root, branch).
/// 3. The session joins the open task with the same inference key whose latest activity is within the
///    idle gap (most recent first); otherwise a new task is proposed.
/// 4. Proposed tasks are `origin == .inferred`: provisional until `confirm`. A task the user created by
///    hand has no inference key and is never joined automatically.
/// 5. Inference is a proposal, not a decision. Reassigning or detaching a session is a plain `assign`; since
///    inference only runs once per session (when it is first seen), it never undoes what the user did.
public struct TaskInferrer: Sendable {
    public let domain: any DomainStore
    public let events: any EventStore
    public let locator: any WorkContextLocator
    public let policy: InferencePolicy

    /// Sessions of a task whose events are inspected when deciding whether the task is still active.
    static let recentSessionsConsidered = 5

    public init(domain: any DomainStore, events: any EventStore, locator: any WorkContextLocator,
                policy: InferencePolicy = InferencePolicy()) {
        self.domain = domain; self.events = events; self.locator = locator; self.policy = policy
    }

    public func place(session id: SessionID, at now: Date) async throws -> Placement {
        guard let session = try await domain.session(id) else {
            throw DomainStoreError.notFound(entity: "session", id: id.rawValue)
        }
        guard session.taskID == nil else { return .skipped(.alreadyAssigned) }
        guard let directory = session.workingDirectory, !directory.isEmpty else { return .skipped(.noDirectory) }
        guard var context = locator.context(forDirectory: directory) else { return .skipped(.noContext) }

        if policy.excludedRoots.contains(context.projectRoot) {
            // A repository (or a directory) too broad to be a project: group by the session's own directory.
            let own = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL.path
            guard own != context.projectRoot, !policy.excludedRoots.contains(own) else { return .skipped(.excludedRoot) }
            context = WorkContext(projectRoot: own, branch: nil)
        }

        let project = try await projectFor(root: context.projectRoot, at: now)
        let key = Self.key(for: context, separateBranches: policy.separateBranches)

        if var task = try await joinableTask(in: project, key: key, at: now) {
            task.updatedAt = now
            try await domain.save(task)
            try await domain.assign(session: id, to: task.id)
            return .attached(task: task.id, created: false)
        }
        let title = context.branch.map { "\(project.name) · \($0)" } ?? project.name
        let task = WorkTask(projectID: project.id, title: title, origin: .inferred, inferenceKey: key, createdAt: now)
        try await domain.save(task)
        try await domain.assign(session: id, to: task.id)
        return .attached(task: task.id, created: true)
    }

    /// The user accepts a proposed task (optionally renaming it). It keeps its inference key, so later
    /// sessions in the same context keep joining it.
    public func confirm(task id: TaskID, title: String? = nil, at now: Date) async throws {
        guard var task = try await domain.task(id) else { throw DomainStoreError.notFound(entity: "task", id: id.rawValue) }
        task.origin = .explicit
        if let title, !title.isEmpty { task.title = title }
        task.updatedAt = now
        try await domain.save(task)
    }

    // MARK: Helpers

    static func key(for context: WorkContext, separateBranches: Bool) -> String {
        separateBranches ? "\(context.projectRoot)\u{1F}\(context.branch ?? "")" : context.projectRoot
    }

    /// An existing project that lists the root, else the project for that directory (created once).
    private func projectFor(root: String, at now: Date) async throws -> Project {
        if let existing = try await domain.projects().first(where: { $0.roots.contains(root) }) { return existing }
        let id = ProjectID("dir:\(root)")
        if let existing = try await domain.project(id) { return existing }
        let name = URL(fileURLWithPath: root).lastPathComponent
        let project = Project(id: id, name: name.isEmpty ? root : name, roots: [root], createdAt: now)
        try await domain.save(project)
        return project
    }

    private func joinableTask(in project: Project, key: String, at now: Date) async throws -> WorkTask? {
        var best: (task: WorkTask, activity: Date)?
        for task in try await domain.tasks(inProject: project.id) where task.status == .open && task.inferenceKey == key {
            let activity = try await lastActivity(of: task)
            guard now.timeIntervalSince(activity) <= policy.idleGap else { continue }
            if best == nil || activity > best!.activity { best = (task, activity) }
        }
        return best?.task
    }

    /// Latest sign of life among the task's most recent sessions (their events, or their start).
    private func lastActivity(of task: WorkTask) async throws -> Date {
        var latest = task.updatedAt
        let recent = try await domain.sessions(forTask: task.id).suffix(Self.recentSessionsConsidered)
        for session in recent {
            latest = max(latest, session.endedAt ?? session.startedAt)
            if let last = try await events.events(forSession: session.id).last { latest = max(latest, last.occurredAt) }
        }
        return latest
    }
}
