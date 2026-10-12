# Task inference

How Bipuu proposes a task for a session. Domain background: [DOMAIN_MODEL.md](DOMAIN_MODEL.md) (Task ≠ Session, explicit vs
inferred). Code: `BipuuCore/Sources/BipuuCore/TaskInference.swift`, `WorkContext.swift`.

**Principle: inference is a proposal, never a decision.** A proposed task is `origin == .inferred`: provisional until the
user confirms it. Nothing the user did is ever overridden.

## When it runs

Once per session, at the moment the recorder sees the session for the first time (see [EVENT_RECORDING.md](EVENT_RECORDING.md)).
Because it never runs again for that session:
- a session that already has a task is never moved;
- a session the user detached stays detached, also after Bipuu restarts;
- the context (branch) is read while the session has just begun, when it still matches the session.

## The rule

1. **Context** of a session = its working directory → *(project root, branch)*, found by `GitWorkContextLocator`:
   - the root is the nearest ancestor holding `.git` (symlinks resolved, so one project is one root);
   - linked **worktrees** share the main repository's root and keep their own branch; submodules are projects of their own;
   - outside a repository the directory itself is the root; a missing directory yields nothing (skipped).
   - only plain file reads (`.git`, `HEAD`): no process, no network, nothing written.
2. **Too-broad roots** (`/` and the home directory by default) are not projects. A session *inside* such a root (for example a
   dotfiles repository in `$HOME`) is grouped by its own directory; a session *in* it is skipped.
3. **Project**: an existing project that lists the root, else one is created for the directory (`dir:<root>`, named after it).
4. **Task**: the session joins the open task of that project with the same *inference key* (root + branch, or root alone when
   branches are not separated) whose latest activity is within the **idle gap** (12 h by default; most recent first).
   Latest activity = the newest event, end or start among the task's five most recent sessions, or the task's own `updatedAt`.
   Otherwise a new task `"<project> · <branch>"` is proposed.
5. **Never joined:** tasks the user created by hand (they have no inference key), completed or abandoned tasks.
6. **Confirming** (`TaskInferrer.confirm`) turns a proposal into an explicit task (optionally renamed). It keeps its inference
   key, so later sessions in the same context keep joining it.

Skipped, with a reason: already assigned, no working directory, directory missing, excluded root.

## What events carry

From then on the recorder stamps each new event with the session's *current* task and project. History keeps what was true when
it was recorded; reassigning a session later does not rewrite old events. `TaskSummary` follows the session's current
assignment, `events(forTask:)` follows the attribution at recording time.

## Switching it off

`inferTasks` default (`defaults write app.bipuu.Bipuu inferTasks -bool false`) or `BIPUU_INFER_TASKS=0`. Recording can run without it;
sessions then stay unattached.

## Known limits

- Heuristic: one repository + one branch + a 12 h gap. Two unrelated jobs on `main` within the gap become one task; one job
  across several branches becomes several. That is why proposals are provisional and cheap to change.
- Detached HEAD and non-repository directories group by directory only.
- Project creation, task creation and assignment are separate writes (no cross-store transaction): a crash in between can leave an
  empty proposed task or a project with no sessions. Harmless; the session stays unattached.
- Proposals are shown and confirmed in the [work view](WORK_VIEW.md). No merge or split of tasks.
