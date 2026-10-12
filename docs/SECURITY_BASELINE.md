# Bipuu — Security Baseline (audit of Coucou @ `0dffbaf`)

Read-only source audit; nothing built or run. Severity is for Bipuu's threat model (local-first developer tool that can approve agent actions).

## Findings

### High
**H1 — Approval card does not show what is being approved.** `HookServer.processPermissionRequest` displays `toolInput["command"] ?? tool`. For Edit/Write/WebFetch/MCP tools the card shows only the tool name: no path, content, or URL. `CodeBlock` (`IslandViewContent.swift:4720`) is a plain `Text` with no limit/truncation flag *(clipping not verified visually)*. **"Always" forwards the agent's `permission_suggestions` verbatim as `updatedPermissions`** (`nb-hook.py`, ~`HookServer.swift:3424`); the user never sees the rule scope.
→ Bipuu: render full `tool_input` with truncation indicators; diff/path for file tools; preview the exact rule "Always" creates; show an `Approval.fingerprint`.

**H2 — macOS relay does not authenticate the server.** `nb-hook.py` connects to `…/NotchBuddy/nb.sock` and trusts any reply; `{"permissionDecision":"allow"|"always"}` becomes `behavior: allow`. The server does `removeItem(path)` then `bind`, so a same-user process (or a less-trusted process able to reach that directory) can replace the socket and auto-approve everything. No nonce/HMAC/peer check client-side. (Windows/Linux relay is better: server SID / `SO_PEERCRED` check, `first_pipe_instance(true)`.)
→ Bipuu: per-install random secret in a `0600` file, challenge–response; relay verifies server pid/uid (and code signature on macOS); refuse to run if the socket dir is group/world accessible; never silently replace a live socket.

### Medium
**M1 — Local socket server weaknesses.** Good: dir `0700`, socket `0600`, `getpeereid`, 1 MB cap, 5 s `SO_RCVTIMEO`, ≤32 connections. Gaps: chmod after bind (relies on parent dir); no schema validation beyond `as? [String:Any]`; same-user process can **forge PermissionRequest cards**, fill `ApprovalQueue.maxPending` (forcing terminal fallback), push fake Stop events; forged `file_path` reaches `NSWorkspace.open`/`code <path>` (`IslandViewContent.swift:770-784`, needs a click, `-`-prefixed paths unhandled). Windows `pipe.rs`: no read timeout, no connection cap, **default pipe DACL, no client-SID check** *(not verified how tokio defaults apply)*.

**M2 — Remote influence via iPhone link.** `InstructionRunner` (non-App-Store, off by default) turns CloudKit `Instruction` records into `claude -p <text> --resume <session>` in the session cwd → prompt injection from anyone controlling the iCloud account/CloudKit records. Decisions matched only by a non-secret SHA-256 fingerprint; authenticity = iCloud account. Tool names/commands are uploaded to iCloud (field-encrypted; Apple holds keys unless ADP). `ServiceDetailRunner` can re-run CI/merge PRs/redeploy with Keychain keys.
→ Bipuu v1: no phone link. If revived: opt-in, per-pairing authenticated (see Android E2E design), no remote instruction execution by default.

**M3 — Unauthenticated push relay (`relay/src/index.ts`).** Anyone with an APNs live-activity token can push attacker-chosen `statusText`/`agent`/`approval` (60-char validated) to that phone through the author's APNs key (phishing vector). No rate limit. Default URL hard-coded to the author's Worker, so every build sends agent name/state through a third party. → Delete; never ship a hard-coded third-party default.

**M4 — Config writers other than `ClaudeSettingsFile` are weaker** (Gemini, Antigravity, Copilot, OpenCode, Amp, Hermes): `writeJSONFile` (`HookServer.swift:1898`) backs up then `write(.atomic)` — does not preserve file mode (files may hold API keys) and replaces dotfile symlinks with regular files. Plugin installers write JS/TS/Python executed by those tools *(contents not read)*. Windows `config_file.rs` states it preserves permissions and follows symlinks *(callers not all verified)*.

**M5 — Install/uninstall matches by substring** (`HookServer.swift:1406-1427`): any hook command containing `"NotchBuddy"`/`"coucou"` is treated as Coucou's; uninstall drops the whole matcher group incl. other hooks in it. → explicit Bipuu marker/id; remove only own entries.

**M6 — Hardening differs across platforms.** Windows/Linux relay and server are stricter than macOS (peer verification, CSP `script-src 'self'`, minimal Tauri capabilities, keystore allow-list, ack timeout). Bring macOS to the same level.

### Low
- L1 Keychain: generic passwords, `WhenUnlockedThisDeviceOnly`, not synchronizable; legacy login keychain (accessibility attr largely ignored on macOS); no ACL object. Service `app.example.NotchBuddy`; keys: anthropic, google, openai, resend(+from), n8n(url+key), vercel, github, stripe, calcom, notion, elevenlabs. Nothing sensitive found in UserDefaults.
- L2 Logging: `AppLog` good (0700/0600, rotation, control chars escaped); no prompts/commands in `nb.log`. `instruction-last.log` contains claude output, no explicit mode.
- L3 Config backups `*.bak-<ts>` accumulate (no retention).
- L4 Statusline relay runs the user's previous command via `/bin/sh -c` from `statusline-previous.json` (0700 dir) — low.
- L5 File drop copies to `…/inbox` with no cleanup; PDFs/images sent whole to Anthropic with no size cap (text capped 200 KB).
- L6 Window capture (AX title + browser URL via AppleScript for Safari/Chrome/Arc/Firefox/Edge) sent to the chat provider on first message; memory only. → remove.
- L7 Windows/Android installers unsigned; no updater.

### Positive (keep)
No telemetry/analytics anywhere (CI guards forbid analytics/ads libs); no auto-updater; ATS only `NSAllowsLocalNetworking`, no pinning bypass; **no automatic approval path** — `sendApprovalDecision` only from Allow/Deny/Always buttons and phone decisions; timeouts/unreachable/unknown ⇒ `ask` (agent prompts itself); `ClaudeSettingsFile` (strict parse, fingerprint recheck, mandatory dated backup, temp+rename, mode+symlink preserved, preview, statusLine diff, uninstall); `safeWebURL` (http/https+host only); no third-party deps on Mac; macOS notarisation local (no Apple secrets in CI); no `pull_request_target`; relay: fail-open for events, deadline-bounded; Android relay design (fail-closed, constant-time compare, E2E, replay counter).

## Entitlements & permissions (Developer ID build)
Not sandboxed; hardened runtime on; entitlements: audio-input, addressbook, apple-events (+ iCloud/push in Cloud variants). Usage strings: Accessibility, Apple Events, Contacts, Microphone, Speech. **All of these except possibly Apple Events (terminal jump) belong to non-core features and are removed in Bipuu v1** → minimal entitlements.

## Egress inventory (Coucou)
api.github.com, api.vercel.com, api.stripe.com, api.notion.com, api.resend.com, api.cal.com, user n8n URL, api.anthropic.com, generativelanguage.googleapis.com, api.openai.com, api.elevenlabs.io, api.open-meteo.com, api.exchange.coinbase.com, www.okx.com, Spotify art CDN, `coucou-relay.relay.example.invalid`, CloudKit (if sync on), user local LLM. **Bipuu v1 egress target: none by default.**

## Supply chain
Mac: no packages. Rust: `windows/Cargo.lock` (563 pkgs, licences not audited). npm: wrangler/vitest/vite/typescript with `^` ranges. CI: actions pinned by major tag, unpinned `brew install xcodegen`; Android signing secrets only in tag workflow.
→ Pin actions by SHA, add `cargo-deny`/`cargo-audit`/`npm audit` and licence checks, reproducible helper-binary builds.

## Bipuu security requirements (from this audit)
1. Authenticated hook channel (H2) with fail-open semantics preserved: *if Bipuu is down or unauthenticated, the agent continues and asks in its own UI*.
2. Full-fidelity approval display + rule-scope preview (H1); policy engine decisions always attributable.
3. Single shared config-writer library (backup, merge, preview, fingerprint, atomic, preserve mode/symlink, explicit marker, backup retention) for every agent adapter (M4, M5, L3).
4. Strict, versioned `AgentEvent` schema validation at the boundary; length caps; path sanitisation before any `open`.
5. Secrets: Keychain with data-protection keychain; allow-list of keys; never in logs; redaction layer in `AppLog`.
6. Minimal entitlements; no mic/contacts/AX/AppleScript in v1.
7. No third-party default endpoints; no telemetry; any future network feature opt-in.
8. Windows pipe: explicit DACL, same-SID client check, read timeout, connection cap.
9. Security tests on the relay/server contract before refactoring `HookServer`.

## Not verified
Runtime behaviour (card clipping, relay latency); all agent-specific installers (Codex/Muse/Hermes/OpenCode/Amp contents); `asEscape` and every AppleScript path; iOS/Android apps; Windows phone-link bind address; whether published privacy docs match egress; CI secrets configuration; repository forks' CI behaviour.
