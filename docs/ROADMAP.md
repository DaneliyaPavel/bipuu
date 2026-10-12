# Bipuu — Roadmap

Status: **Phase 0 (audit) complete.** No source imported, no repo initialised yet.

## Repository / upstream strategy
- `origin` → `https://github.com/DaneliyaPavel/bipuu` (currently empty). `upstream` → `https://github.com/louis-cfm/coucou`.
- Proposal: import Coucou **with history** (authorship provenance for the MIT obligations and the "who wrote this retained file" checks in IP_MIGRATION §8), then do the purge in reviewable commits. *Open decision.*
- Upstream = **read-only reference** after Phase 3: sync candidates are (a) new agent hook formats, (b) relay/security fixes. Components expected to stay mergeable for a while: `ClaudeSettingsFile`, `ApprovalQueue`, `AskQuestion`, `windows/hook` normaliser. Intentionally diverging: `HookServer` (split), island UI, persistence, everything character-related (fully replaced), pollers/voice/phone (removed). Evaluate upstream security fixes by watching releases; port by hand.

## Phases

### Phase 1 — Clean Bipuu foundation  *(gating, mostly mechanical)*
Exit criteria: builds; existing tests pass; Claude Code hook flow works end-to-end (SessionStart → tool use → permission card → Stop); **zero** hits for the forbidden-string CI grep; no protected assets; neutral placeholder icon; `LICENSE` + `THIRD_PARTY_NOTICES` correct.
1. Import with history, set remotes, tag baseline.
2. Replace Mochi: introduce `CharacterRenderer` protocol + `NullCharacterRenderer` (a plain status dot/ring), delete BotEngine/outfits/greeting/upload/desktop pet/Live Activity art.
3. Delete protected assets and non-core features (IP_MIGRATION §3, §9); drop iPhone/Android/phone-link/relays and the App Store target.
4. Rename identifiers (IP_MIGRATION §5) under a Bipuu-owned, documented stable-ID contract (bundle id, keychain service, socket path, `bipuu_agent`, marker for hook entries).
5. Add characterisation tests around the relay↔server reply contract **before** touching `HookServer` (currently zero coverage).
6. Migrate the `swiftc`-per-script tests into a SwiftPM test target (keep scripts as thin wrappers during transition); wire all tests in CI.
Risk: compile-driven deletion through `AppState`/`IslandViewContent`; do in small commits.

### Phase 2 — Domain foundation
`BipuuCore` SwiftPM package (no AppKit): Project, Task, Agent, Session, Host, Environment, AgentEvent (versioned schema), Approval; ordered bounded in-process EventBus; minimal persistence (SQLite/GRDB-free `sqlite3` or flat log — decide) so sessions/tasks survive restart. Project inferred from `cwd` (git root); Task initially = *session-derived* with explicit user/agent naming hooks later. Adapter shims map the existing `HookServer.processEvent` output onto `AgentEvent` without behaviour change.
Exit: `Project → Task → Agent → Session` representable and persisted; existing UI fed from the domain store; Host distinct from Agent in the data model.

### Phase 3 — Adapter boundaries
- `AgentAdapter` (install/preview/uninstall/translate/encode; pure translate/encode) — port Claude, Codex, Copilot, Muse first (real approvals); Gemini/Antigravity/OpenCode/Amp events-only; generic hook adapter.
- `HostAdapter` capabilities model; first adapters: Terminal.app/iTerm, VS Code/Cursor, Zed, Warp/Ghostty; the existing dictionaries become adapter data.
- Native `bipuu-hook` (Rust, from `windows/hook`): replaces sh+xcode-select+python; authenticated channel (SECURITY H2); one binary for macOS/Linux/Windows.
- Shared config-writer library for all adapters (SECURITY M4/M5).
Exit: no `if agent ==`/`if host ==` in core; hook p95 <10 ms measured; security tests green.

### Phase 4 — Task-centric workspace
UX architecture + wireframes + data requirements + state model first (doc), then incremental SwiftUI: *Today / Needs you / Recent*, task workspace (plan, changes, tests, git, quality signals, environments, actions). Git/test signals from local `git`/test-run events; CI/deploy as later adapters. Approvals show full `tool_input` and rule scope.

### Phase 5 — Ambient experience
Re-base the island on Project/Task/Agent/Session; split `IslandViewContent`; surface abstraction (notch / menu bar / tray); replace 8 Hz polling with event-driven hover where possible; idle budget verified with Instruments/`powermetrics`.

### Phase 6 — Original character system
Design brief from owner's reference sheet → vector/Metal-or-Canvas renderer behind `CharacterRenderer`; state-driven (idle…tired); animation suspended when invisible; no tracing of Mochi. Then agent-specific silhouettes.

### Later
Policy engine (auto-allow/ask/confirm tiers), usage/cost signals, quality signals store, remote environments, Windows/Linux surface (reuse Tauri/TS pure logic), mobile ambient (reuse the Android E2E relay ideas, own infra).

## First change (answer to "what should we change first?")

**Do the clean-room cut, in this order, as a single reviewable sequence:**
1. Import + remotes + baseline tag.
2. **Replace the character renderer with a `CharacterRenderer` protocol + null implementation and delete all Mochi drawing code and reserved assets.**
3. Delete the author's default relay URL and personal data.

Why this first: (a) it is the **only gating legal risk** — nothing can be shipped, shown or even published to the public Bipuu repo while MIT code that renders the reserved character is in it; (b) it creates the exact seam Phase 6 needs (replaceable renderer); (c) it removes the two biggest steady-state CPU costs found (idle full-rate redraw, desktop pet) and the unsolicited third-party data flow; (d) it shrinks the codebase by roughly a third before we refactor, which lowers the cost of every later step; (e) it is mechanical and testable (build + existing tests + forbidden-string grep), so it does not need product decisions.
**Immediately after (still Phase 1):** characterisation tests for the hook contract, because the next real engineering step — splitting `HookServer` into core + adapters + native relay — has zero test coverage today.

## Open decisions (defaults proposed; confirm when convenient)
1. Import Coucou **with history** (default) vs squash.
2. **Drop App Store build** for v1 (default: yes — sandbox conflicts with installing hooks into other tools' dotfiles).
3. Keep `windows/` in tree? Default: keep `windows/hook` (Rust relay) in the repo as the seed of `bipuu-hook`; park the Tauri UI directory outside the macOS build until a Windows/Linux phase.
4. Persistence tech for Phase 2 (SQLite vs append-only event log + snapshots).
5. Task inference policy (what creates a Task: first prompt in a session? explicit command? agent-declared?).
6. Distribution: Developer ID + notarisation (matches Coucou's pipeline) and own update mechanism.
7. Legal review of this migration before public release.
