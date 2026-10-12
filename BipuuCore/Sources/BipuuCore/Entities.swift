import Foundation

// MARK: - Open vocabularies (extensible; unknown values are preserved)

public enum CapabilityTag {}
public enum HostKindTag {}
public enum EnvironmentKindTag {}
public enum ArtifactKindTag {}
public enum AgentKindTag {}

/// A named thing an agent or host can do ("approvals", "focus-window"…). The UI adapts to these,
/// never to product names.
public typealias Capability = Token<CapabilityTag>
/// Opaque logical agent type chosen by an adapter. Core code must not branch on its value.
public typealias AgentKind = Token<AgentKindTag>

public typealias HostKind = Token<HostKindTag>
public extension Token where Tag == HostKindTag {
    static let editor: HostKind = "editor"
    static let terminal: HostKind = "terminal"
    static let desktopApp: HostKind = "desktop-app"
    static let remoteShell: HostKind = "remote-shell"
    static let other: HostKind = "other"
}

public typealias EnvironmentKind = Token<EnvironmentKindTag>
public extension Token where Tag == EnvironmentKindTag {
    static let local: EnvironmentKind = "local"
    static let remote: EnvironmentKind = "remote"
    static let dev: EnvironmentKind = "dev"
    static let preview: EnvironmentKind = "preview"
    static let staging: EnvironmentKind = "staging"
    static let production: EnvironmentKind = "production"
}

public typealias ArtifactKind = Token<ArtifactKindTag>
public extension Token where Tag == ArtifactKindTag {
    static let file: ArtifactKind = "file"
    static let diff: ArtifactKind = "diff"
}

// MARK: - Entities

/// A body of work rooted in one or more locations (usually a repository).
public struct Project: Hashable, Sendable, Codable, Identifiable {
    public var id: ProjectID
    public var name: String
    /// Filesystem roots, in the namespace of the host machine. May be empty.
    public var roots: [String]
    public var createdAt: Date

    public init(id: ProjectID = .generate(), name: String, roots: [String] = [], createdAt: Date) {
        self.id = id; self.name = name; self.roots = roots; self.createdAt = createdAt
    }
}

public enum TaskOrigin: String, Hashable, Sendable, Codable {
    /// Created or confirmed by the user.
    case explicit
    /// Proposed by Bipuu from session activity; provisional until confirmed.
    case inferred
}

public enum TaskStatus: String, Hashable, Sendable, Codable {
    case open, completed, abandoned
}

/// A unit of work the user cares about. Named `WorkTask` (not `Task`) so it never shadows
/// Swift Concurrency's `Task` in files that import BipuuCore. It owns no sessions: sessions
/// point at a task, which keeps reassignment, merging and splitting possible.
public struct WorkTask: Hashable, Sendable, Codable, Identifiable {
    public var id: TaskID
    /// Optional so a task can exist before it is placed in a project, and move between projects.
    public var projectID: ProjectID?
    public var title: String
    public var origin: TaskOrigin
    public var status: TaskStatus
    /// Set on tasks Bipuu proposed: the context (project root, branch) new sessions are matched
    /// against. It stays after the user confirms the task, so later sessions keep joining it.
    /// Tasks created by hand have none and are never joined automatically. Absent in older data.
    public var inferenceKey: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: TaskID = .generate(), projectID: ProjectID? = nil, title: String,
                origin: TaskOrigin = .explicit, status: TaskStatus = .open, inferenceKey: String? = nil,
                createdAt: Date, updatedAt: Date? = nil) {
        self.id = id; self.projectID = projectID; self.title = title; self.origin = origin
        self.status = status; self.inferenceKey = inferenceKey
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }
}

/// Logical agent identity and what it can do. Says nothing about where it runs (that is `Host`).
public struct Agent: Hashable, Sendable, Codable, Identifiable {
    public var id: AgentID
    public var kind: AgentKind
    public var displayName: String
    public var capabilities: Set<Capability>

    public init(id: AgentID = .generate(), kind: AgentKind, displayName: String,
                capabilities: Set<Capability> = []) {
        self.id = id; self.kind = kind; self.displayName = displayName; self.capabilities = capabilities
    }
}

/// Where the interaction happens: an editor, a terminal, a desktop app, a remote shell.
/// `identity` is a stable adapter-chosen key (e.g. a bundle id); the core only compares it.
public struct Host: Hashable, Sendable, Codable, Identifiable {
    public var id: HostID
    public var kind: HostKind
    public var identity: String
    public var displayName: String
    public var capabilities: Set<Capability>

    public init(id: HostID = .generate(), kind: HostKind, identity: String, displayName: String,
                capabilities: Set<Capability> = []) {
        self.id = id; self.kind = kind; self.identity = identity; self.displayName = displayName
        self.capabilities = capabilities
    }
}

/// Where the work runs or lands (local checkout, remote machine, preview, production…).
/// Independent of `Host`: a terminal host may drive a remote environment.
public struct Environment: Hashable, Sendable, Codable, Identifiable {
    public var id: EnvironmentID
    public var kind: EnvironmentKind
    public var name: String
    public var attributes: [String: String]

    public init(id: EnvironmentID = .generate(), kind: EnvironmentKind, name: String,
                attributes: [String: String] = [:]) {
        self.id = id; self.kind = kind; self.name = name; self.attributes = attributes
    }
}

/// One run of one agent, in one host and environment. Many sessions may serve one task.
public struct Session: Hashable, Sendable, Codable, Identifiable {
    public var id: SessionID
    /// Mutable on purpose: unattached sessions are allowed and can be reassigned.
    public var taskID: TaskID?
    public var agentID: AgentID
    public var hostID: HostID?
    public var environmentID: EnvironmentID?
    public var workingDirectory: String?
    /// The agent's own session identifier, as reported by its adapter.
    public var externalRef: String?
    public var startedAt: Date
    public var endedAt: Date?

    public init(id: SessionID = .generate(), taskID: TaskID? = nil, agentID: AgentID,
                hostID: HostID? = nil, environmentID: EnvironmentID? = nil,
                workingDirectory: String? = nil, externalRef: String? = nil,
                startedAt: Date, endedAt: Date? = nil) {
        self.id = id; self.taskID = taskID; self.agentID = agentID; self.hostID = hostID
        self.environmentID = environmentID; self.workingDirectory = workingDirectory
        self.externalRef = externalRef; self.startedAt = startedAt; self.endedAt = endedAt
    }
}

public enum ApprovalDecision: String, Hashable, Sendable, Codable {
    case allow
    /// Allow, and remember the exact scope the card showed.
    case allowAlways
    case deny
    /// The agent moved on before the user answered.
    case withdrawn
}

/// A request for the user's judgement. Never resolved without an explicit user action,
/// except `withdrawn`, which records that the agent gave up waiting.
public struct Approval: Hashable, Sendable, Codable, Identifiable {
    public var id: ApprovalID
    public var sessionID: SessionID
    /// Short, human-readable description of the operation. Full detail lives in the event payload.
    public var summary: String
    public var requestedAt: Date
    public var decision: ApprovalDecision?
    public var resolvedAt: Date?

    public var isPending: Bool { decision == nil }

    public init(id: ApprovalID = .generate(), sessionID: SessionID, summary: String,
                requestedAt: Date, decision: ApprovalDecision? = nil, resolvedAt: Date? = nil) {
        self.id = id; self.sessionID = sessionID; self.summary = summary
        self.requestedAt = requestedAt; self.decision = decision; self.resolvedAt = resolvedAt
    }
}

/// Something a session or task produced that the user may want to look at (a file, a diff…).
public struct Artifact: Hashable, Sendable, Codable, Identifiable {
    public var id: ArtifactID
    public var kind: ArtifactKind
    public var sessionID: SessionID?
    public var taskID: TaskID?
    /// Where it lives (path or URL), meaningful to the adapter that produced it.
    public var location: String
    public var createdAt: Date

    public init(id: ArtifactID = .generate(), kind: ArtifactKind, sessionID: SessionID? = nil,
                taskID: TaskID? = nil, location: String, createdAt: Date) {
        self.id = id; self.kind = kind; self.sessionID = sessionID; self.taskID = taskID
        self.location = location; self.createdAt = createdAt
    }
}
