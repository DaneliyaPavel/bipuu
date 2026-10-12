# Bipuu domain model

Source of truth for the types in `BipuuCore/` (Swift package, Foundation only). If code and this
document disagree, fix one of them in the same commit.

## 1. Entities

| Entity | Is | Key fields |
|---|---|---|
| `Project` | A body of work rooted in locations | name, roots |
| `WorkTask` (`TaskID`) | A unit of work the user cares about | projectID?, title, origin, status, inferenceKey? |
| `Agent` | Logical agent identity + capabilities | kind (opaque), capabilities |
| `Session` | One run of one agent | taskID?, agentID, hostID?, environmentID?, externalRef? |
| `Host` | Where interaction happens | kind, identity (adapter key), capabilities |
| `Environment` | Where work runs or lands | kind (open), name, attributes |
| `Approval` | A request for the user's judgement | sessionID, summary, decision? |
| `Artifact` | Something produced worth viewing | kind, sessionID?, taskID?, location |

`Task` is named `WorkTask` in Swift so it never shadows Swift Concurrency's `Task`; the ID is `TaskID`.
`Result` is **not** modelled yet: no real producer exists (see §9).

All IDs are `Identifier<Entity>`: distinct types (`ProjectID` ≠ `TaskID`), `Codable` as a plain JSON
string, `Hashable`, `Sendable`, stored as TEXT.

## 2. Ownership and relationships

```
Project 1 ── * WorkTask 1 ── * Session ── 1 Agent
                                   ├── 0..1 Host
                                   └── 0..1 Environment
Session 1 ── * AgentEvent      Session/Task 1 ── * Artifact      Session 1 ── * Approval
```

References point **down from the child**: a `Session` holds `taskID`, a `WorkTask` holds `projectID`.
Parents hold no child lists, so moving or merging work is a field update, never a structural change.

## 3. Invariants

- Every entity and event has a stable ID, never reused.
- `Session.taskID` and `WorkTask.projectID` are optional and mutable: unattached work is legal.
- `Session.agentID` is required; host and environment may be unknown.
- An `Approval` is pending until `decision` is set; only an explicit user action sets
  `allow/allowAlways/deny`. `withdrawn` records that the agent stopped waiting.
- An inferred task (`origin == .inferred`) is provisional until the user confirms it.
- Events are append-only and immutable; appending an identical event twice is a no-op, appending a *different* event under a used ID is an error
  (`eventIDCollision`). See [STORAGE.md](STORAGE.md).

## 4. Agent vs Host vs Environment

- **Agent**: *who* works (logical identity, capabilities). Knows nothing about editors or terminals.
- **Host**: *where the user meets it* (editor, terminal, desktop app, remote shell, other).
  Product names (Zed, Terminal.app…) exist only as adapter-chosen `identity` strings.
- **Environment**: *where the work runs or lands* (local, remote, dev, preview, staging, production…).

They are independent: one agent can run in many hosts; a terminal host can drive a remote environment.
`HostKind`, `EnvironmentKind`, `AgentKind`, `Capability`, `ArtifactKind` are open `Token`s (string
wrappers with well-known constants), not enums. Core code compares them but never branches on a
product name; UI adapts to `capabilities`.

## 5. Task vs Session

A session is a run; a task is the work. Never 1:1 by construction. One task can have many sessions
(different agents, hosts, days). Allowed by the schema without further changes: reassign a session,
merge tasks (repoint sessions), split work, attach several agents, move a task between projects.
None of these operations are implemented yet.

Inferred tasks (`origin == .inferred`) are proposed by Bipuu from session activity and are provisional until the user confirms them;
`inferenceKey` is the context new sessions are matched against. See [TASK_INFERENCE.md](TASK_INFERENCE.md).

## 6. AgentEvent envelope (schema version 1)

`id, schemaVersion, occurredAt, receivedAt, projectID?, taskID?, sessionID, agentID?, hostID?,
environmentID?, kind, source{adapter, adapterVersion?}, payload`.

- `payload` is `JSONValue`, owned by the adapter's normalisation; no vendor field is part of the
  envelope and vendor hook JSON is never copied in.
- `kind` is an open, dotted, vendor-independent token. Vocabulary derived from the events Phase 1
  actually receives (hook events + the approval/question flows):

  `session.started` `session.ended` `prompt.submitted` `turn.finished` `turn.failed`
  `turn.interrupted` `tool.started` `tool.finished` `tool.failed` `subagent.started`
  `subagent.finished` `approval.requested` `approval.resolved` `question.requested` `notice`

  Deliberately absent until a real source produces them: `file.changed`, `command.*`, `test.*`,
  `agent.thinking/reading/working` (derivable from `tool.*` payload category), `task.completed`.
- Recommended payload keys for `tool.*`: `tool` (name), `category` (`read|edit|execute|other`),
  `summary`. Other kinds define theirs when an adapter needs them.
- Dates are encoded as exact epoch seconds, keys sorted (`BipuuCoding`).

`taskID` and `projectID` on an event are the values known **when it was recorded**. Reassigning a
session later does not rewrite history; queries by task return what was attributed at the time.

## 6b. State and projections

Current state is held by `DomainStore` (rules: [STORAGE.md](STORAGE.md)); history by `EventStore`.
`SessionSummary` and `TaskSummary` are derived from them on read. Recommended payload key:
`approvalId` on `approval.requested` / `approval.resolved`, which ties a request to its resolution.
`WorkOverview` is a read model built from both stores for the [work view](WORK_VIEW.md).

## 7. Ordering

Canonical order, used by every `EventStore` query: `occurredAt`, then `receivedAt` (both compared as whole
Unix microseconds), then `id` (UTF-8 byte order). It is a deterministic presentation order for any event set
on any store.

It is **not** a causal or global total order: `occurredAt` comes from independent clocks (agents,
remote hosts). Within one session from one adapter it normally matches reality; across sources it
is best-effort. Insertion order is not exposed. `recentEvents(limit:)` returns the last `limit`
events of the canonical order, ascending.

## 8. Extension strategy

- New vendor/host/environment: an adapter picks tokens and a payload shape; the core is unchanged.
- New event kind: just use it; old readers keep it as an unknown token.
- Envelope change: bump `schemaVersion`. Additive fields are optional. A reader accepts a *newer*
  version, reads the fields it knows and ignores the rest (`isFromFutureSchema`); a store that must not
  lose data keeps the raw payload bytes. Removing or retyping a field needs a new major handling path.
- Storage: implement `EventStore` (async, `Sendable`) and pass `EventStoreContract`. `InMemoryEventStore` and
  `SQLiteEventStore` (see [STORAGE.md](STORAGE.md)) are the implementations.

## 9. Deferred on purpose

Deleting entities, merging/splitting tasks · UI for confirming proposed tasks · `Result` entity · task inference · project discovery ·
AgentAdapter / HostAdapter protocols · HookServer producing `AgentEvent` · cost tracking ·
CI/deploy models · compaction or archiving of pruned history · cross-source clock correction · sync between machines.
