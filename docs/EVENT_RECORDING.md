# Event recording

How hook messages become durable history. Domain types: [DOMAIN_MODEL.md](DOMAIN_MODEL.md). Storage: [STORAGE.md](STORAGE.md).

```
agent ── bipuu-hook (relay) ──BIPUU1──▶ HookServer ─┬─▶ island UI (unchanged)
                                                   └─▶ HookEventAdapter ─▶ EventRecorder ─▶ SQLite
                                                       (vendor → AgentEvent)  (bounded queue,   events + sessions
                                                                               one consumer)    agents, hosts
```

## Rules

- **Side channel, never on the hook path.** `HookServer` hands the normalised event to `EventRecorder.submit`, which
  only places it on a bounded queue (~3 µs) and returns. The reply to the agent, the approval card and the island do
  not wait for, or depend on, the database. If the database cannot be opened (for example it was written by a newer Bipuu),
  recording switches itself off for the run, logs one line, and everything else carries on.
- **Bounded.** The queue keeps the newest 1024 items; past that the oldest are dropped and counted. Hook traffic is
  human-paced, so this is a safety valve, not an expected state.
- **Adapter boundary.** `HookEventAdapter` is the only place that knows the relay's JSON, tool names and vendor names. It
  produces `AgentEvent`s of the vendor-neutral vocabulary plus the `Agent`, `Host` and `Session` they belong to.
- **Deterministic identities.** `agent:<kind>`, `host:<bundle id or terminal program>`, `<agent kind>:<agent's session id>`
  (or agent + working directory when the agent sends no session id). The same message always maps to the same ids.
- **Sessions.** The recorder creates a session on first sight, proposes a task for it ([TASK_INFERENCE.md](TASK_INFERENCE.md)), never
  overwrites an existing one (it may have been assigned a task meanwhile) and sets `endedAt` on `session.ended`.
- **Attribution.** Each event is stamped with its session's current task and project when it is written.
- **Times.** Hooks carry no timestamp; `occurredAt` and `receivedAt` are both the moment Bipuu received the message.

## Mapping

| Relay event | `AgentEvent.kind` | Payload |
|---|---|---|
| SessionStart / SessionEnd | `session.started` / `session.ended` | |
| UserPromptSubmit | `prompt.submitted` | |
| PreToolUse / PostToolUse / PostToolUseFailure | `tool.started` / `tool.finished` / `tool.failed` | `tool`, `category` |
| Stop / StopFailure / Interrupt | `turn.finished` / `turn.failed` / `turn.interrupted` | |
| SubagentStart / SubagentStop | `subagent.started` / `subagent.finished` | |
| Notification | `notice` | `category`: `rate-limit`, `question`, `other` |
| PermissionRequest (a card was queued) | `approval.requested` | `approvalId`, `tool`, `category` |
| the card's request ended | `approval.resolved` | `approvalId`, `decision`: `allow`, `allowAlways`, `deny`, `deferred`, `withdrawn` |
| `AskUserQuestion` | `question.requested` | |

Not recorded: unknown event names, status-line messages, `PreToolUse` of `AskUserQuestion` (it is the question), and
permission requests that never get a card (other agents' requests answered "ask" at once, or beyond the queue cap).
`category` is `read`, `edit`, `execute` or `other`.

## What is stored, and what never is

**Stored:** event kind, time, agent kind, host identity (bundle id or terminal program), session id, tool name (capped at
64 characters), tool category, approval decision, and per session its working directory and the agent's own session id.

**Never stored:** prompts, commands, file paths and contents, tool input or output, assistant messages, notification text.
A test feeds secrets through every event kind and fails if any of them appears in the stored JSON, and the end-to-end script
checks the real database. Capturing content would be a separate, explicit, opt-in decision.

The database is `~/Library/Application Support/Bipuu/bipuu.sqlite` (override: `BIPUU_EVENT_DB`), created owner-only (0600)
inside the 0700 support directory. Recording is on by default and can be turned off with the `recordEvents` default
(`defaults write app.bipuu.Bipuu recordEvents -bool false`) or `BIPUU_RECORD_EVENTS=0`. Task inference has its own switch (`inferTasks`, `BIPUU_INFER_TASKS=0`). Nothing leaves the machine.

## Controls and retention

Settings → **History** (the same switches work from the command line for scripts and tests):

| Choice | Default | Effect |
|---|---|---|
| Record agent activity (`recordEvents`, `BIPUU_RECORD_EVENTS=0`) | on | Off: the app still handles every hook as usual; nothing is built, queued or written, and no database is created. Takes effect with the next event. |
| Suggest tasks for new sessions (`inferTasks`, `BIPUU_INFER_TASKS=0`) | on | Needs recording. Applies to the next *new* session; existing sessions are never revisited. |
| Keep history for (`historyRetentionDays`: 30, 90, 365, 0 = no age limit) | 90 days | See below. Anything else stored falls back to 90. |

**Retention.** After the first event of a run and then every 500 stored events, the recorder prunes: events older than the chosen age go, then
the oldest events beyond 200 000 (that cap applies even with "as long as possible"). Pruning removes events only; projects, tasks, sessions,
agents and hosts stay. It is a transaction, followed by a WAL checkpoint. The file does not shrink below its peak (freed pages are reused),
so its size is bounded by the cap, not reduced by it. The log says how many events were removed, never which. A failure to prune is logged
and does not stop recording. No timers: pruning is driven by events.

**Crash safety.** Every event is committed before it is acknowledged; the database is in WAL mode. A real `kill -9` test (a child process
writing events and sessions, killed mid-write, four times) checks that every acknowledged write is present, the log has no gaps, at most the
one write in flight is extra, `integrity_check` is `ok`, and the store keeps working. A power cut or OS crash can lose the last few
transactions (`synchronous = NORMAL`) but cannot corrupt the database.

## Verification

`scripts/test-hook-event-adapter.sh`, `scripts/test-event-recorder.sh` (real SQLite in temp files; retention and switches), `scripts/test-history-settings.sh`, and section 2b/4 of
`scripts/e2e-hooks.sh` against the real app and relay.

## Deferred

Archiving what retention removes · an "erase all history" button · recording content (opt-in) · environments · restoring island state from the log. The [work view](WORK_VIEW.md) is the first reader of the log.
