# Work view

The island's second answer, next to "what is my agent doing right now": **what work is going on across my projects, and where am I needed.**
Opened from the list icon in the island header (next to Settings), or **Work** in the menu-bar menu.

```
project
  ● task title  [Proposed]        Needs you · 1 approval · 2 sessions   now   ✓
  ● task title                    1 session · 1 working                 3m
  ○ task title                    3 sessions · finished                 2h
n sessions without a task
+k more tasks
```

## What it shows

- **Open tasks grouped by project** (tasks without a project under "No project"). Completed and abandoned tasks are not shown.
- Per task: a dot (amber = needs you, blue = something is working, grey = idle, dim = finished), the title, a **Proposed** badge
  while Bipuu's inference ([TASK_INFERENCE.md](TASK_INFERENCE.md)) has not been confirmed, the sessions' state, and how long ago it was active.
- **Order:** what needs the user comes first, then the most recently active; groups follow their first task.
- Sessions appear as counts and state (the island is 160 pt tall); `n sessions without a task` counts the unattached ones.
- At most 40 tasks are read; the rest are counted as `+k more tasks`.

## What you can do

- **Confirm** (check icon): the proposal becomes your task. Later sessions in the same project and branch keep joining it.
- **Rename** (click the title, Return): renaming a proposal also confirms it; Escape cancels. Names are trimmed; an empty name does nothing.

That is all it writes. It never changes a session, an event or the island's other views.

## How it stays cheap

- It reads when it is shown, and again (debounced 0.4 s) when the recorder stores something **while it is visible**. Hidden, it does not
  listen, schedule or read: no timers, no polling. Ages ("3m") are as of the last refresh.
- It has its own read connections to the database (WAL) and never creates the file: with nothing recorded it says so.
- Building the overview over 40 tasks and 8k events takes ~0.08 s.

## Code

`BipuuCore/WorkOverview.swift` (read model and builder, pure, tested) · `App/Work/WorkOverviewView.swift` (the list: stateless, fixtures can
render it) · `WorkModel.swift` (reading, refreshing, confirm and rename) · `WorkView.swift` (the island card) · `IslandView.work`.

## Checks

`scripts/test-work-overview.sh` (sentences; renders the list into PNGs and fails if they are blank, a check that itself tells blank from full),
`scripts/test-work-model.sh` (a real recorder fills a real database; the model reads, follows events, confirms, renames, stays idle while hidden,
reports a database from a newer Bipuu). Pass a directory to either to keep the pictures.
**Not covered by automation:** the island chrome around the card (header button, window sizing, the menu item) is only compiled and built in CI.

## Deferred

Per-session rows and drill-down · merging, splitting and completing tasks · keyboard navigation · localisation of the new strings (they have
English defaults) · live-updating ages while visible.
