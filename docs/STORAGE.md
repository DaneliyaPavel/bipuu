# Storage

Durable event storage for Bipuu. Source of truth for the `EventStore` contract and the SQLite schema.
Domain concepts live in [DOMAIN_MODEL.md](DOMAIN_MODEL.md).

## Layers

| Piece | Where | Knows about |
|---|---|---|
| `EventStore` protocol, `InMemoryEventStore`, `AgentEvent` | `BipuuCore` | Foundation only |
| `SQLiteEventStore` | `BipuuSQLite` | `BipuuCore` + system `sqlite3` |
| Contract suite (`EventStoreContract`) | `BipuuChecking` | `BipuuCore` |

SQLite is the durable store. The abstraction belongs to the core; the physical implementation belongs
to `BipuuSQLite`. The core never imports a storage engine (a check enforces it), and the app talks to
the protocol, not to SQLite. No ORM and no third-party database library.

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

## SQLite schema (database version 1)

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

## Migrations

`user_version` 0 → 1 creates the table, the indexes and sets the version in a single transaction.
The version is checked **before** any pragma or write: a database whose `user_version` is newer than this build
supports throws `unsupportedDatabaseVersion(found:supported:)` and is left byte-for-byte untouched. There is no downgrade.
Each future version adds one forward step.

## Deferred (next slices)

Persistence of Project / WorkTask / Agent / Session / Host / Environment and projections over events ·
HookServer writing events · task inference · adapters · UI · retention and compaction · encryption at rest ·
database file location and permissions (decided with the app integration) · multi-process access policy.
