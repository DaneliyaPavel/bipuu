# Storage

Durable event storage for Bipuu. Source of truth for the `EventStore` contract and the SQLite schema.
Domain concepts live in [DOMAIN_MODEL.md](DOMAIN_MODEL.md).

## Layers

| Piece | Where | Knows about |
|---|---|---|
| `EventStore`, `DomainStore` protocols, in-memory implementations, `AgentEvent`, projections | `BipuuCore` | Foundation only |
| `SQLiteEventStore`, `SQLiteDomainStore` | `BipuuSQLite` | `BipuuCore` + system `sqlite3` |
| Contract suites (`EventStoreContract`, `DomainStoreContract`) | `BipuuChecking` | `BipuuCore` |

SQLite is the durable store. The abstraction belongs to the core; the physical implementation belongs
to `BipuuSQLite`. The core never imports a storage engine (a check enforces it), and the app talks to
the protocol, not to SQLite. No ORM and no third-party database library.

## Events are history, the domain store is the present

- `EventStore`: append-only history of what happened.
- `DomainStore`: current state of Project, WorkTask, Agent, Host, Environment, Session and how they connect.
- Projections (`SessionSummary`, `TaskSummary`) are **derived** from the two and never stored: one source of truth.
  Both stores may live in the same database file (separate connections, WAL).

## Two different versions

- `AgentEvent.schemaVersion`: version of the **event envelope** (what an event means). Lives inside every event.
- `PRAGMA user_version`: version of the **physical database schema** (tables, indexes). Currently `1`.

They change independently. A database upgrade never rewrites envelopes; an envelope bump needs no table change.

## `EventStore` contract

`append(event)`:

| Situation | Result |
|---|---|
| id not present | stored, `.appended` |
| id present, stored event identical (`==`) | no-op, `.duplicate` |
| id present, content differs in any field | throws `EventStoreError.eventIDCollision`, nothing changes |

A collision is never hidden (no blanket `INSERT OR IGNORE`): it means an id was reused or an event was altered.
"Identical" is judged on the whole decoded envelope, including payload and both timestamps.

Queries (`events(forSession:)`, `events(forTask:)`, `recentEvents(limit:)`) return events in canonical order,
ascending; `recentEvents` is the last `limit` of that order. Events with no `taskID` never appear in task queries
(an event carries the task it was attributed to when recorded; see DOMAIN_MODEL §6).

## Ordering

Canonical order: `occurredAt`, then `receivedAt`, then `eventID`.
- Times are compared as **whole Unix microseconds** (`Int64`, rounded). Floating point is never used for ordering
  or indexing; sub-microsecond differences are ignored on every store.
- `eventID` compares in UTF-8 byte order (equal to SQLite's BINARY collation).
- This is a **deterministic presentation order, not a causal ordering guarantee**: `occurredAt` comes from independent
  clocks. If a source sequence number appears later, it arrives in a new envelope schema version.

## SQLite schema, database version 1 (`EventStore`)

Table `events`, one row per event, append-only:

| Column | Type | Notes |
|---|---|---|
| `event_id` | TEXT PK | |
| `schema_version` | INTEGER | envelope version |
| `occurred_at_us`, `received_at_us` | INTEGER | Unix microseconds |
| `project_id`, `task_id`, `agent_id`, `host_id`, `environment_id` | TEXT NULL | |
| `session_id` | TEXT NOT NULL | the envelope always has a session, so the column is not nullable |
| `event_kind`, `source` | TEXT NOT NULL | `source` = adapter id |
| `raw_json` | BLOB NOT NULL | the full envelope as encoded by `BipuuCoding` |

Indexes (only these): `(session_id, occurred_at_us, received_at_us, event_id)`,
`(task_id, …)` partial `WHERE task_id IS NOT NULL`, `(occurred_at_us, received_at_us, event_id)`.
A check asserts the three queries use them without a temp sort.

Indexed columns exist for querying; `raw_json` is the record of truth for reconstruction, future migrations and
debugging. On every read both are compared: any disagreement, an undecodable envelope, or an empty one throws
`SQLiteEventStoreError.corruptedEvent`. Nothing is skipped silently.
`raw_json` is the encoding of the `AgentEvent` value the store was given: unknown *fields* of a future envelope
that the decoder dropped before append are not preserved; unknown kinds and future `schemaVersion` values are.

## Operation

- WAL journal, `synchronous = NORMAL`, `busy_timeout` 5 s, `foreign_keys = ON` (no foreign keys yet).
- One connection per store, owned by the actor; statements prepared once and cached; no pool.
- Each append is one `BEGIN IMMEDIATE … COMMIT`; any error rolls back.
- `close()` is explicit and idempotent; later calls throw `.closed`. Dropping the store also closes the connection.
- Committed events survive an abrupt exit (WAL); a second connection sees them.

## SQLite schema, database version 2 (`DomainStore`)

| Table | Key | Relations (real foreign keys) | Other columns |
|---|---|---|---|
| `projects` | `project_id` | | `created_at_us`, `raw_json` |
| `agents`, `hosts`, `environments` | own id | | `raw_json` |
| `tasks` | `task_id` | `project_id` → projects (nullable) | `status`, `created_at_us`, `raw_json` |
| `sessions` | `session_id` | `task_id` → tasks (nullable), `agent_id` → agents, `host_id` → hosts (nullable), `environment_id` → environments (nullable) | `started_at_us`, `raw_json` |

- Same pattern as events: full JSON plus the columns needed for relations and ordering, cross-checked on every read
  (`corruptedRecord` on any disagreement).
- Relations live on the child. No table lists its children, and `events` has **no** foreign keys: history may mention
  entities that are not (or no longer) stored, and it is never rewritten when work is moved.
- Two partial indexes only: `tasks(project_id, created_at_us, task_id)` and `sessions(task_id, started_at_us, session_id)`.
  The "unassigned" and "unattached" lists scan their table; they are small and not worth an index yet.
- `save` is an upsert. References are verified before writing (clear `missingReference` error naming the entity) and again
  by the database. A rejected write changes nothing. There are no deletes yet.
- `assign(session:to:)` and `move(task:to:at:)` are single transactions that touch one row.
- Dates are stored as microsecond integers in the indexed columns and as exact epoch seconds inside the JSON.
- Because the Swift standard `Foundation` on macOS also has a `Host` class, code that imports both must write
  `BipuuCore.Host`.

## Projections

Computed on read by folding events in canonical order (rules in `SessionSummary.fold`):
phase (`unknown/working/idle/failed/ended`), pending approvals (matched by payload `approvalId`), open question, counts and
last activity. A `TaskSummary` is the roll-up of the sessions **currently** attached to the task (`Session.taskID`), not of
the `taskID` stamped on old events, so reassigning a session moves its activity without rewriting history.

## Migrations

`user_version` 0 → 1 (events) and 1 → 2 (domain tables) each run in one transaction with their version bump; the steps are listed in `SQLiteConnection.migrations`, so a database from Slice 2 upgrades in place and keeps its events.
The version is checked **before** any pragma or write: a database whose `user_version` is newer than this build
supports throws `unsupportedDatabaseVersion(found:supported:)` and is left byte-for-byte untouched. There is no downgrade.
Each future version adds one forward step.

## Deferred (next slices)

Deleting entities · merging and splitting tasks · materialised or cached projections · HookServer writing events and entities · task inference · adapters · UI · retention and compaction · encryption at rest ·
database file location and permissions (decided with the app integration) · multi-process access policy.
