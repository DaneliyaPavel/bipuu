import Foundation

/// One task as the overview shows it: the task, what its sessions are doing, and where it lives.
public struct TaskRow: Hashable, Sendable {
    public var task: WorkTask
    public var summary: TaskSummary
    public init(task: WorkTask, summary: TaskSummary) { self.task = task; self.summary = summary }
    /// Proposed by Bipuu and not yet confirmed by the user.
    public var isProposed: Bool { task.origin == .inferred }
    public var needsAttention: Bool { summary.needsAttention }
    /// Newest sign of life: the task's sessions' events, else the task's own last update.
    public var lastActivity: Date { summary.lastEventAt ?? task.updatedAt }
}

/// Tasks of one project. `project == nil` collects tasks that belong to no project.
public struct ProjectGroup: Hashable, Sendable {
    public var project: Project?
    public var tasks: [TaskRow]
    public init(project: Project?, tasks: [TaskRow]) { self.project = project; self.tasks = tasks }
    public var needsAttention: Bool { tasks.contains(where: \.needsAttention) }
    public var lastActivity: Date { tasks.map(\.lastActivity).max() ?? .distantPast }
}

/// What the island's work view shows: projects → open tasks → what their sessions are doing.
public struct WorkOverview: Hashable, Sendable {
    public var groups: [ProjectGroup]
    /// Sessions that belong to no task.
    public var unattachedSessionCount: Int
    /// Open tasks that did not fit under the row limit.
    public var hiddenTaskCount: Int
    public init(groups: [ProjectGroup], unattachedSessionCount: Int, hiddenTaskCount: Int) {
        self.groups = groups; self.unattachedSessionCount = unattachedSessionCount; self.hiddenTaskCount = hiddenTaskCount
    }

    public var taskCount: Int { groups.reduce(0) { $0 + $1.tasks.count } }
    public var needsAttentionCount: Int { groups.reduce(0) { $0 + $1.tasks.filter(\.needsAttention).count } }
    public var isEmpty: Bool { groups.isEmpty && unattachedSessionCount == 0 }
}

/// Builds the overview by reading the two stores. Read-only: it never writes.
///
/// Order: tasks that need the user first, then the most recently active; groups follow their
/// first task, so what needs attention rises to the top at both levels. Only open tasks are shown.
public struct WorkOverviewBuilder: Sendable {
    public let domain: any DomainStore
    public let events: any EventStore

    public init(domain: any DomainStore, events: any EventStore) {
        self.domain = domain; self.events = events
    }

    /// `limit` caps the number of tasks read and shown (the most recently updated ones are kept).
    public func build(limit: Int = 40) async throws -> WorkOverview {
        let projections = Projections(events: events, domain: domain)
        let projects = try await domain.projects()
        var candidates: [WorkTask] = try await domain.unassignedTasks()
        for p in projects { candidates += try await domain.tasks(inProject: p.id) }
        let open = candidates.filter { $0.status == .open }
            .sorted { ($0.updatedAt, $1.id) > ($1.updatedAt, $0.id) }
        let shown = Array(open.prefix(max(0, limit)))

        var rows: [TaskRow] = []
        for task in shown { rows.append(TaskRow(task: task, summary: try await projections.taskSummary(task.id))) }
        rows.sort { a, b in
            if a.needsAttention != b.needsAttention { return a.needsAttention }
            if a.lastActivity != b.lastActivity { return a.lastActivity > b.lastActivity }
            return a.task.id < b.task.id
        }

        let byProject = Dictionary(grouping: rows) { $0.task.projectID }
        var groups: [ProjectGroup] = byProject.map { id, tasks in
            ProjectGroup(project: projects.first { $0.id == id }, tasks: tasks)
        }
        groups.sort { a, b in
            if a.needsAttention != b.needsAttention { return a.needsAttention }
            if a.lastActivity != b.lastActivity { return a.lastActivity > b.lastActivity }
            return (a.project?.name ?? "") < (b.project?.name ?? "")
        }
        return WorkOverview(groups: groups, unattachedSessionCount: try await domain.unattachedSessions().count,
                            hiddenTaskCount: open.count - shown.count)
    }
}
