# Phase 1 — exit report

> **Status: Phase 1 exit recorded.** The Foundation Verification Gate passed: sanitised history pushed, first CI on a
> full-Xcode macOS runner green (see "xcodebuild / CI result"). Still **not** release-verified: signing, notarisation
> and the final bundle id are open (see "Remaining limitations").

Status of the Phase 1 exit criteria (ROADMAP §Phase 1), with the evidence and the limits of that evidence.
Everything below was run on a Mac with Command Line Tools only: **no Xcode, no Rust toolchain** were installed.

| Criterion | Result | Evidence / limit |
|---|---|---|
| Builds | **Yes** | `xcodebuild` Release build, unsigned, **succeeded on CI** (Xcode 26.6, SDK 26.5, macOS 26 arm64 runner). Locally the target also compiles and links with plain `swiftc` (`scripts/dev-app-bundle.sh`) and the resulting app runs. |
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

## Foundation Verification Gate

| Step | Status |
|---|---|
| Forbidden-content scan, tree + all history | **Done** (re-run after the scrub below): no protected names, media or character-drawing markers; author identifiers absent from file contents of every commit |
| History scrub of author data inside file contents | **Done**: Apple Team ID, e-mail, relay host, TestFlight link, private hostnames replaced in all commits. Commit **messages** and authorship are untouched on purpose (provenance); contributor e-mails in commit metadata remain, as in the public upstream |
| Commit messages mentioning Coucou/Mochi | **Kept as provenance** (decision); protected assets/code/data are not present in any commit |
| Bundle id | **Unchanged** (`app.bipuu.Bipuu`, provisional until the owner confirms the domain) |
| Push to `origin` | **Done** (owner confirmed): `main` + tags `sanitized-import`, `parked/windows-tauri-ui` only, from a clean worktree; remote verified to hold exactly those refs |
| First CI on a macOS runner with full Xcode | **Green** on the first run |
| Fix real `xcodebuild` failures | **None occurred** |
| Baseline tag + this report updated with the real result | **Done**: tag `phase1-baseline` |

### xcodebuild / CI result

Run [38243393651](https://github.com/DaneliyaPavel/bipuu/actions/runs/38243393651) on commit `03b74e9`:

| Job | Result |
|---|---|
| Forbidden content (tree + full history, `fetch-depth: 0`) | ✔ 3 s |
| macOS build and tests | ✔ 2 m 53 s — runner `macos-26-arm64`, Xcode 26.6 (SDK `MacOSX26.5`); XcodeGen; 20 standalone test scripts incl. 42 relay tests: all OK; `xcodebuild -scheme Bipuu -configuration Release CODE_SIGNING_ALLOWED=NO` → **`** BUILD SUCCEEDED **`**, 0 errors, 1 distinct deprecation warning (`activateIgnoringOtherApps`, macOS 14) |

A second run on the commit that records this result is linked from the tag.

### Remaining limitations

- Signing, Developer ID, notarisation and an updater are not set up (need the owner's credentials); CI builds unsigned.
- Bundle id `app.bipuu.Bipuu` is provisional until the owner registers the domain (expected final: `com.bipuu.Bipuu`); changing it later also changes the Keychain service and the Application Support/log directories (no users yet, so no migration needed).
- Phase 3 validation items below (live Codex/Gemini/Copilot, Rust `bipuu-hook`, model-driven Claude e2e, live focus-jump).
- CI actions are pinned by major tag, not SHA (SECURITY_BASELINE supply-chain item); `actions/checkout@v4` runs on Node 24 with a deprecation notice.
- No runtime performance measurement yet beyond one idle sample (Phase 5).

## Phase 3 validation items (do not block Phase 2)

Moved here from the Phase 1 exit criteria; to be done with the adapter work:

1. Live verification of Codex, Gemini CLI, Copilot CLI (and Muse, Hermes, OpenCode, Amp) against real agent binaries and real configs: installer preview/apply/uninstall, event mapping, approval round trip where supported.
2. Native cross-platform `bipuu-hook` (Rust, from `hook/`): adopt the BIPUU1 channel, build and test on macOS/Linux/Windows, signing/notarisation of the helper binary, latency target (<10 ms).
3. Full model-driven Claude Code session through `scripts/e2e-hooks.sh --with-claude` (needs `claude login` on the verifying machine).
4. Live focus-jump to real terminals/editors (`ClaudeHost`/`TerminalTarget`) as part of the `HostAdapter` capabilities model.
5. Shared config-writer library for all adapters (SECURITY M4).
