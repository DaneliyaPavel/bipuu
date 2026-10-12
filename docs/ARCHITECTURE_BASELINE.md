# Bipuu — Architecture Baseline (audit of Coucou)

Audited: `louis-cfm/coucou` @ `0dffbaf` (464 commits, 855 tracked files), MIT + separate asset licence.
Method: read-only code reading by six parallel audits. **Nothing was built, run or measured.** Claims marked *(unverified)* were not confirmed in code. Companion docs: [IP_MIGRATION](IP_MIGRATION.md), [SECURITY_BASELINE](SECURITY_BASELINE.md), [ROADMAP](ROADMAP.md), [PRODUCT_VISION](PRODUCT_VISION.md).

## 0. Verdict in five lines

1. Coucou is a **multi-platform product with four independent implementations** of the same protocol (Swift/macOS, Rust+TS/Windows+Linux, Kotlin/Android, Swift/iOS). There is **no shared schema**; "the protocol" is Claude Code's hook JSON plus an informal `coucou_agent` field.
2. The valuable asset is **not the UI**; it is the hook/approval plumbing and the config installers. That is ~15% of the code.
3. The macOS **core is a 3,790-line `HookServer.swift`** that mixes socket server, routing, state mutation, installers for 10 agents and two embedded Python scripts. There is **no Task or Session model** — the unit is a "pill" (one per client).
4. About **30% of the Swift code is non-core** (voice, Mochi, service pollers, music, crypto, mail, recap, phone link).
5. The legally riskiest part is MIT-licensed *code that draws the reserved Mochi character*. It cannot be kept.

## 1. Repository architecture map

| Path | What | Lang | ~Size | Bipuu |
|---|---|---|---|---|
| `NotchBuddy/Sources/App` | macOS app (island, hooks, state, settings, pollers, voice) | Swift | 27.2k + 6.8k voice + 2.9k PhoneLink | adapt core, drop the rest |
| `NotchBuddy/Sources/CoucouKit` | shared models (pills, diff, turn snapshot, Mochi engine) | Swift | 4.7k | partly reusable |
| `NotchBuddy/Sources/Phone`, `Widgets`, `NotificationContent` | iPhone app | Swift | ~6.7k | drop (v1) |
| `windows/` | Tauri app (Win+Linux): `src-tauri` Rust, `src` TS, `hook` relay | Rust/TS | ~27k Rust, ~30k TS | relay crate + pure logic reusable |
| `android/` (+ `android/relay`) | Android app + CF Worker relay, © Rhytam Biswas | Kotlin/TS | ~13k + tests | drop |
| `relay/` | CF Worker, APNs Live Activity push | TS | 182 lines | drop |
| `linux/arch` | PKGBUILD (community) | sh | small | drop |
| `docs/` | spec (FR), agent integration docs, GitHub Pages site | md/html | | rewrite |
| `design/` | prototype, captures, outfits | html/png | | **protected — remove** |
| `scripts/`, `tests/` | 40 shell test runners + 40 test files, release scripts | sh/Swift | | keep pattern, migrate to SwiftPM |

## 2. macOS architecture

- XcodeGen (`project.yml`), macOS 15, Swift 6 strict concurrency. Targets: `NotchBuddy` (Developer ID, **not sandboxed**), `CoucouAppStore` (sandboxed, `APPSTORE` flag, no hooks installer/AppleScript/AX), `CoucouPhone` + 2 extensions. Configs `Debug/DebugCloud/Release/ReleaseCloud`; `PHONE_LINK` flag gates CloudKit.
- `NotchBuddy.xcodeproj` is committed although CLAUDE.md says never edit it.
- Window: borderless `NSPanel` 720×320 anchored top-centre; click-through by toggling `ignoresMouseEvents` from a mouse-poll `Timer` (not CADisplayLink; SPEC.md "60 Hz" is outdated — it is adaptive 8/20/60 Hz). Notch geometry from `safeAreaInsets`/auxiliary areas; falls back to a bar on non-notch screens (`IslandDisplayChoice`, `IslandScreenGeometry` — pure, tested).
- `IslandStateMachine.swift` (247 lines) is **only the island open/close FSM** (hidden/peek/compact/expanded). It does not model agent sessions.
- Agent state = `BotState` enum (idle, working, thinking, searching, approval, question, error, finished, ratelimit, sleeping, dizzy), set imperatively inside `HookServer`.
- Heaviest files: `IslandViewContent` 5,059 (every card in one view), `HookServer` 3,790, `SettingsView` 2,359, `IslandWindowController` 2,041, `BotEngine` 1,868, `MochiOutfitDrawing` 1,464, `AppState` 896 (referenced by 47/98 App files; mixes agent state with Stripe/Vercel/Spotify/Voice state).

## 3. Windows / Linux architecture

- Tauri 2. Three webviews: `island` (always), `settings` (created hidden at launch), `mochi` (desktop pet). Rust owns OS work (relay server `pipe.rs`, config editing, secrets, pollers, geometry, cursor poll, phone link); TS (hand-rolled DOM/canvas, no framework) owns view/state.
- ~95 `invoke` commands; events `hook`, `cursor`, `screen-changed`, `integration`, `settings-changed`, `shortcut`, `chat-delta`. Capabilities minimal (`core:default`, `autostart`).
- `src/core/*.ts` are **deliberate ports of Swift** (`fsm.ts`←IslandStateMachine, `state.ts`←AppState, `pills.ts`←PillCatalog, `diff.ts`, `plan.ts`). Pure & portable: `fsm.ts`, `diff.ts`, `plan.ts`, `layout.ts`, `pills.ts`. Not portable: `bridge.ts` (Tauri), `state.ts` (i18n/mochi coupling).
- Linux: gtk-layer-shell top-edge surface on COSMIC/KDE/wlroots; GNOME forced to XWayland (`GDK_BACKEND=x11`); global shortcuts via XDG portal; tray via ayatana. Packaging AppImage/deb/rpm. **No updater. Windows not code-signed.**
- No macOS code in Tauri; the Mac app is wholly separate Swift → two codebases per behaviour.

## 4. Mobile components

iPhone: CloudKit private DB (`iCloud.<author-domain>.Coucou`) + Cloudflare APNs relay; same-Apple-ID "pairing"; Face ID for Allow. Android/Windows: LAN TLS (cert-pinned) or user-deployed CF relay with E2E AES-256-GCM (HKDF, counter, padding; test vectors shared across Rust/Kotlin/TS). **Deferred for Bipuu v1.** Ideas worth keeping for a later phase: fingerprint-bound single-use approvals, capability negotiation with off-by-default features, keyless dumb-pipe relay. Details and red flags in SECURITY_BASELINE.

## 5. Agent event / hook flow (macOS)

```
agent hook ──► nb-hook (sh) ──► xcode-select -p ──► /usr/bin/python3 nb-hook.py
   (per event)                                      normalise names/fields, add coucou_agent,
                                                    term_program / bundle_id env context
                                                       │ unix socket nb.sock (0600, dir 0700, getpeereid)
                                                       ▼
HookServer.serverThread (thread per connection, max 32, 1 MB, 5 s rcv timeout)
   ├─ statusline            → ClaudePlanGauge
   ├─ ask_user_question     → processQuestionRequest (fd held ≤120 s)
   ├─ PermissionRequest     → ApprovalQueue (fd held ≤115 s) → card → reply on fd
   └─ everything else       → processEvent → {"ok":true} immediately
                                  routing ladder → pill id → PillSessionRegistry → AppState.tasks
                                  side effects: DiffEngine, RecapStore, SoundEngine, TurnRecorder
```

- Events handled: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure, Notification, Stop, StopFailure, Interrupt (Codex), SessionEnd, SubagentStart/Stop; plus PermissionRequest and AskUserQuestion paths.
- Fields used: `session_id|conversation_id`, `cwd`, `coucou_agent`, `term_program`, `bundle_id`, `prompt` (60 chars shown), `tool_name`, `tool_input` {command,file_path,path,query,old_string,new_string,edits,content}, `message`, `last_assistant_message`, `permission_suggestions`, `rate_limits`.
- Non-blocking: fire-and-forget events use 0.3 s connect timeout; if the app is closed the relay exits 0. Permission replies: no output ⇒ agent asks in its own UI (fail-safe).
- **Cost:** `sh` + `xcode-select` + `python3` shim **per event** (including every PreToolUse/PostToolUse). Not measured. The Windows/Linux relay (`windows/hook`, Rust, LTO, 300 ms connect budget) already shows the native alternative.
- **Duplication:** event normalisation exists 4× (Python relay, Rust relay, Swift consumer, TS consumer). `windows/hook/src/normalize.rs` + `reply.rs` are the best seed for a shared `AgentEvent` normaliser (pure, tested: 34 hook tests).

## 6. Agent integrations (maturity)

| Agent | Install target | Approvals | Maturity |
|---|---|---|---|
| Claude Code | `~/.claude/settings.json` (12 events + AskUserQuestion matcher + statusLine) via `ClaudeSettingsFile` | yes + questions | mature, tested |
| Codex | `~/.codex/hooks.json` (10 events incl. PermissionRequest, Interrupt) | yes | real (GitHub build only) |
| Copilot CLI | `~/.copilot/hooks/coucou.json` | yes, fail-closed | real |
| Muse Code | `~/.config/muse/settings.json` | yes | real |
| Hermes | plugin dir + `config.yaml` merge + `hermes plugins enable` | opt-in | elaborate, fragile |
| Gemini CLI | `~/.gemini/settings.json` | no | events only |
| Antigravity | `~/.gemini/config/hooks.json` | no (`ask`) | events only |
| OpenCode / Amp | generated JS/TS plugins | not wired | thin |
| Cursor | none — rides Claude hooks, detected by bundle id | yes | implicit |
| Claude Desktop | none — relay tags via `CLAUDE_CODE_ENTRYPOINT` | no | display only |

No adapter protocol: each agent is a copy-pasted `previewX/writeX/removeX` triple plus `if agent ==` branches in the relay, `processPermissionRequest`, notes and `openAgentTarget`. `docs/AGENTS.md` is stale (claims no third-party approvals). A suspected key mismatch (`bash` vs `command`) in Copilot hook removal was seen and **not traced**.

## 7. Host / editor / terminal detection

- `ClaudeHost.swift` (~80 lines): two hardcoded dictionaries (bundle id→name; `TERM_PROGRAM`→bundle id) covering Warp, Terminal, iTerm, Ghostty, kitty, Alacritty, WezTerm, Hyper, Zed, cmux, Orca. VS Code/Cursor are string-matched in 3 `HookServer` methods and in `IslandViewContent` (lines ~213-300, 2175-2215, 2327) and `InstructionRunner:153`.
- Focus is **app-level only** (`NSWorkspace.activate`); iTerm session id is captured but unused; no per-window/tab/pane focus, no AppleScript jump, no `vscode://`.
- Windows/Linux: process-tree walk to the ancestor owning a window (Toolhelp / `/proc` + KWin/EWMH/kitty); best-effort; conhost/tmux/ssh fall back to opening VS Code.
- **Agent ≠ host is only partly modelled**: `AgentTask.hostApp`/`sessionBundleId` are separate fields, but the pill id conflates them (`integration_claude` = "VS Code" **and** the catch-all for every terminal).

## 8. Permissions architecture

`ApprovalQueue` (pure FIFO, max 5, auto-drops requests answered in the agent's own UI by matching PostToolUse tool+inputKey), `AskQuestion` (1–4 questions, 2–4 options, multi-select). **No policy engine**: "Always" returns the agent's own `permission_suggestions` as `updatedPermissions`. No auto-allow exists anywhere (good). Remote path via CloudKit `ApprovalRelay` (allow/deny only, fingerprint-matched). Windows allows exactly one pending card (second is declined to the terminal); macOS queues.

## 9. Storage & state

- UserDefaults: ~51 un-prefixed keys (partial inventory). Keychain service `<author-domain>.NotchBuddy`, `WhenUnlockedThisDeviceOnly`, legacy login keychain; 11 service keys.
- Files under `~/Library/Application Support/NotchBuddy/` (`nb.sock`, `nb-hook`, `nb-hook.py`, `recap.json`, `statusline-previous.json`, `Sounds/`), logs `~/Library/Logs/NotchBuddy/nb.log` (1 MB rotation, 0600), config backups `*.bak-<ts>` next to agent configs (no retention).
- **No persistence of tasks/sessions/events on Mac** — live state is in memory and lost on restart. No SwiftData/CoreData. `RecapStore` keeps aggregates (rewrites whole file on every event). This is the single biggest gap for a task-centric product.

## 10. Secrets

Keychain on Mac, OS keystore with a `KNOWN_KEYS` allow-list on Windows/Linux. No tokens found in UserDefaults. Android uses AndroidKeystore AES-GCM, `allowBackup=false`. Details in SECURITY_BASELINE.

## 11. Test architecture

~40 standalone test files (`tests/`, 4.9k lines) each run by `scripts/test-*.sh` = `swiftc <specific sources> tests/X.swift && run` (no XCTest, no SwiftPM). Covers pure units (ApprovalQueue, PillSessionRegistry, AskQuestion, ClaudeSettingsFile, ClaudeHost, TerminalTarget, DiffEngine, plan gauges, island geometry/FSMs, voice parsing). **Not covered:** `HookServer` (socket, relay scripts), non-Claude installers, `AppState`. One outlier (`NotchBuddy/Tests/HermesConfigMergerTests.swift`) tests a hand-synced *copy* of the code. Four scripts are not wired into CI. Windows: 27 TS test files (Node 22.18+ runner) + ~370 Rust tests (phone link ≈190). CI: `build.yml` (macOS, unsigned builds of 5 targets), `windows-ci.yml`, `linux.yml`, `phone-link.yml`, android workflows. Notarisation is local (`scripts/release.sh`).

## 12. Background / runtime behaviour & performance risks (unmeasured)

Ranked:
1. **Character redraws at full display rate in `compact` while idle** (`BotCanvasView` `TimelineView(.animation)`, paused only for `.hidden`; no dirty tracking; per-frame `Path`/`GraphicsContext` allocation and `NSScreen` lookups).
2. **Hook = 3 processes per event** (sh, xcode-select, python3).
3. **9 pollers start at launch even when unconfigured** (n8n 15 s, Vercel/Stripe 30 s, Resend 60 s, GitHub/Notion/Cal.com 300 s, …) ≈ 10 wakeups/min, **no backoff**.
4. Mouse poll never stops when hidden (8 Hz) + global `mouseMoved`/`keyDown` monitors that are never removed.
5. Desktop pet never pauses when idle.
6. Per-frame allocations in the Canvas closure.
7. Unbounded `AppState.chatHistory`; `RecapStore` full rewrite per event.
8. Voice: always-on mic tap (~47 callbacks/s) + 20 s recogniser restarts when enabled.

Good patterns to keep: Tauri cursor thread parks on a `Condvar` when collapsed; TS island stops `requestAnimationFrame` when settled; Mail/Crypto pollers gated by pill activity; Music is event-driven.

## 13. Security-sensitive areas

See [SECURITY_BASELINE](SECURITY_BASELINE.md). Headline: the **approval card does not show the full `tool_input`**, the **relay does not authenticate the server** (macOS), phone-link opens remote-influence channels, the push relay is unauthenticated, other agents' config writers are weaker than `ClaudeSettingsFile`.

## 14. Coucou/Mochi product coupling

Mochi code ≈ 4.5k Swift (+ ~5k TS, ~2k Kotlin ports), outfits, greeting, upload sequence, desktop pet, sounds, recap, voice (6.8k), pollers, music, crypto, mail, demo mode (756). Entangled via `IslandViewContent`, `IslandWindowController`, `AppState`, `AppDelegate`, `SettingsView`. Full table in IP_MIGRATION.md §F.

## 15. Reusable / remove / abstract / rewrite

**Reuse (adapt):** `ClaudeSettingsFile` (backup+merge+diff+atomic), `ApprovalQueue`, `AskQuestion`, `PillSessionRegistry` (session-scope semantics), `DiffEngine`, `TurnSnapshot`, `ClaudeHookDetection`, `TerminalTarget`, island geometry/display choice, `IslandStateMachine`, `windows/hook` (Rust relay + `normalize.rs`/`reply.rs`), `config_file.rs`, `session_window.rs`, `phone_link/relay_crypto.rs` (later), TS `fsm/diff/plan/layout`.
**Remove:** Mochi engine/outfits/greeting/upload/desktop pet/Live Activity art, sounds, voice, Spotify/Music/Crypto/Mail, Stripe/Resend/n8n/Vercel/Notion/Cal.com pollers, recap, demo mode, iPhone/Android/phone_link/relays, `design/`, `docs/media`, site HTML.
**Abstract:** agent integrations → `AgentAdapter`; host detection → `HostAdapter`; `BotEngine` → `CharacterRenderer` protocol; `AppState` → split into domain store + UI state; sound → no-op sink.
**Rewrite eventually:** `HookServer` (split), `IslandViewContent` (5k-line view), the relay (native), persistence (new), main workspace (new), character renderer (new, original).

## 16. Proposed Bipuu target architecture (incremental)

```
          ┌────────────────────────── BipuuCore (Swift package, no AppKit) ──────────────────────────┐
          │ Domain: Project · Task · Agent · Session · Host · Environment · Artifact · Approval      │
          │ AgentEvent (normalised, versioned) · EventBus (ordered, bounded) · Policy · Store        │
          └───────▲───────────────────────▲───────────────────────────────▲──────────────────────────┘
                  │                       │                               │
        AgentAdapter(s)            HostAdapter(s)                  Surfaces (platform)
  Claude/Codex/Copilot/…     VSCode/Cursor/Zed/JetBrains/        Workspace window · Ambient (notch /
  install + translate        iTerm/Terminal/Warp/… capability-   menu bar / tray) · CharacterRenderer
                             based, no brand branching
                  ▲
        bipuu-hook (native, tiny, cross-platform; fail-open; authenticated channel)
```

Pragmatic boundaries (no purity rewrite): Core as a SwiftPM package with unit tests (replaces the `swiftc`-per-script harness); macOS app keeps SwiftUI/AppKit; the Rust relay is shared by all OSes; the TS/Tauri app is parked until a Windows/Linux phase.

### AgentAdapter boundary (proposed)

```swift
protocol AgentAdapter {
  var id: AgentID { get }                       // "claude-code", "codex", …
  var capabilities: AgentCapabilities { get }   // approvals, questions, subagents, diffs, usage, resume
  func detectInstalled() -> InstallState
  func previewInstall() throws -> ConfigChange   // diff shown to user
  func install(_ change: ConfigChange) throws    // backup + atomic + fingerprint check
  func uninstall() throws                        // removes only Bipuu-marked entries
  func translate(_ raw: RawHookPayload) -> [AgentEvent]   // pure
  func encode(_ decision: Decision, for: ApprovalRequest) -> Data?  // pure; nil == let agent ask
}
```
`translate`/`encode` are the pure functions already present in `normalize.rs`/`reply.rs`.

### HostAdapter boundary (proposed)

```swift
protocol HostAdapter {
  var id: HostID { get }
  var capabilities: Set<HostCapability> { get } // openProject, openFile, navigateToLine, focusSession, openTerminal, showDiff, revealWorkspace
  func identify(_ ctx: RawHostContext) -> HostMatch?       // env/bundle id/process tree → host instance
  func perform(_ action: HostAction, in: HostInstance) async throws
}
```
UI asks `host.capabilities.contains(.navigateToLine)` instead of `if host == "zed"`.

### Core domain (minimum)

```
Project  { id, name, rootPath, repo?, branch? }
Task     { id, projectId, title, state(planned…completed|failed), startedAt, participants:[SessionRef] }
Agent    { id, kind(AgentID), displayName }
Session  { id, agentId, taskId?, hostId?, environmentId, cwd, startedAt, lastEventAt, state }
Host     { id, kind(HostID), instance (bundle/pid/window) }
Environment { id, kind(local|remote|container|ci), label }
AgentEvent { eventId, ts, seq, projectId?, taskId?, agentId, sessionId, type, payload, schema:1 }
Approval { id, sessionId, tool, input(full), fingerprint, policyDecision, expiresAt }
Artifact { id, taskId, kind(diff|test|build|ci|…), data }
```
Mapping from Coucou: pill ≈ (Agent, Host) conflated; `PillSessionRegistry` session ≈ Session; `AgentTask` ≈ a UI row; **Task and Project do not exist** and must be *inferred* from `cwd` (project) and from user/agent signals (task) — a product decision, see ROADMAP open questions.

## 17. Migration risks

1. Splitting `HookServer` without tests on it (zero coverage) → add characterisation tests on the relay-reply contract first.
2. Removing `AppState` features that are referenced in 47 files → do it by compile-driven deletion in small commits.
3. Task inference from raw hook events is lossy; do not promise accurate "tasks" in v1 UI.
4. App Store target conflicts with hook installation (sandbox) → decide early: **no App Store for v1**; drop the `APPSTORE` target.
5. Upstream sync becomes impossible once `HookServer` is split → treat upstream as read-only reference for new-agent hook formats and security fixes, not a merge source.
6. Rust relay on macOS needs signing/notarisation as a helper binary.
7. Notch-specific geometry assumptions in `IslandWindowController` (2k lines) leak into any new ambient surface.

## 18. What to change first

See [ROADMAP](ROADMAP.md) §"First change".
