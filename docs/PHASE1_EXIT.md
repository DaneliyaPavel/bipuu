# Phase 1 — exit report

Status of the Phase 1 exit criteria (ROADMAP §Phase 1), with the evidence and the limits of that evidence.
Everything below was run on a Mac with Command Line Tools only: **no Xcode, no Rust toolchain** were installed.

| Criterion | Result | Evidence / limit |
|---|---|---|
| Builds | **Partly verified** | The whole macOS target compiles and links with `swiftc` (SDK 26.5; `scripts/dev-app-bundle.sh`), and the resulting app runs. `xcodegen` generates the project. **`xcodebuild` itself was not run** (needs full Xcode); the 27 SDK needs the SwiftUI macro plugin that only ships with Xcode, hence 26.5. The first CI run on a macOS runner is the real test. |
| Existing tests pass | **Yes** | 20 standalone scripts: the 17 inherited ones that cover code we kept (tests of removed features were deleted) plus relay contract tests (42), approval description/guard (38 checks), channel auth (16 checks). |
| Claude Code hook flow works end to end | **Yes, with one limit** | `scripts/e2e-hooks.sh` (20 checks) against the real app and the real relay: events arrive, approvals are held, forged messages are dropped, fail-open when the app dies, second instance quits. The real `claude` binary was run once with Bipuu's hooks (`--settings`): its `SessionStart`, `UserPromptSubmit` and `SessionEnd` reached the app. A full model-driven session (tool use, permission) could not be run here: the nested `claude` CLI had an expired OAuth session, and signing in is yours to do. Run `scripts/e2e-hooks.sh --with-claude` after `claude login`. |
| No protected assets / character code / inherited identity | **Yes** | `scripts/forbidden-content-check.sh --history`: no Coucou/Mochi/author identifiers in the tree, no media in the tree or any commit; character-drawing markers absent from all commits (see IP_MIGRATION §11). Residual: names in commit messages (§11). |
| MIT notices preserved | **Yes** | `LICENSE`, `THIRD_PARTY_NOTICES.md`; authorship preserved in history. |
| Identifiers established | **Yes** | `docs/IDENTIFIERS.md`. Bundle id `app.bipuu.Bipuu` is **provisional**. |
| H1 / H2 addressed | **Yes** | SECURITY_BASELINE "Status after Phase 1". |
| Detection of editors/terminals not regressed | **Unchanged, untested live** | `ClaudeHost`/`TerminalTarget` and their tests are untouched; focus-jump to a real terminal was not exercised. |
| Other agents (Codex, Gemini, Copilot…) still work | **Not verified live** | Covered by the relay's contract tests (per-agent output formats). The installers for those agents were not run against real agent configs; none of their binaries were exercised. |
| Windows/Linux relay (`hook/`) | **Not built** | No Rust toolchain; still speaks the old protocol, unused by the macOS app. |

## Numbers

- Swift source: 47.6k → 10.8k lines. Protected material, voice, music, crypto, mail, service pollers, recap, demo, chat, iPhone/Android/phone-link: gone.
- Hook relay latency measured on this machine: ~40–95 ms per event (shell wrapper + Python); the app's reply to a fire-and-forget event takes ~0.1 ms. The native relay in Phase 3 is the fix.
- Idle app: ~0.5 % CPU and 29 MB resident right after launch (a single `ps` sample ~25 s after launch, not a benchmark; proper measurement is Phase 5).

## Behaviour changes made on the way (not just deletions)

- Hook relay: Copilot's `workdir` was ignored (fixed, tested); decisions need a verified signature; refuses an endpoint others can reach.
- App: refuses to replace a running instance's socket; never deletes a foreign file at the socket path; second copy quits.
- Approval card: shows the full operation; offers "Always" only when its effect is shown; Allow/Always inactive for 0.8 s after the card appears.
- Island: no global mouse-move/keyboard monitors left except Escape; no timers for unconfigured features.

## Next (Phase 1 → 2)

1. Push the sanitised history to `origin` **after your go-ahead** (nothing has been pushed).
2. First CI run on macOS; fix whatever `xcodebuild` finds.
3. Confirm the bundle-id domain; Developer ID signing and notarisation need your credentials.
4. Phase 2 domain model (Project/Task/Agent/Session/Host/Environment/AgentEvent) with SQLite as the source of truth (decisions in ROADMAP).
