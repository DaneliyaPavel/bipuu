# Bipuu — guide for AI coding agents

Bipuu is a macOS-first control plane for AI software agents (agent sessions → tasks → projects),
with an ambient island at the top of the screen. Read [docs/PRODUCT_VISION.md](docs/PRODUCT_VISION.md) first;
[docs/ARCHITECTURE_BASELINE.md](docs/ARCHITECTURE_BASELINE.md) maps the current code.

## Where things are
- `Bipuu/Sources/App/` — macOS-only Swift (AppKit + SwiftUI). `Bipuu/Sources/BipuuKit/` — platform-neutral
  models and logic (no AppKit); keep it that way.
- `Bipuu/project.yml` — XcodeGen project; never edit or commit the generated `.xcodeproj`.
- `BipuuCore/` — SwiftPM domain core (Foundation only): entities, `AgentEvent`, `EventStore`. Source of truth:
  [docs/DOMAIN_MODEL.md](docs/DOMAIN_MODEL.md). Durable store: `BipuuSQLite` ([docs/STORAGE.md](docs/STORAGE.md)).
  Verify: `cd BipuuCore && swift run BipuuCoreChecks && swift run BipuuSQLiteChecks`.
- `hook/` — Rust hook relay (seed of the cross-platform `bipuu-hook`). `scripts/`, `tests/` — standalone
  Swift test scripts (`bash scripts/test-*.sh`).
- `docs/` — vision, architecture, security, IP migration, identifiers, roadmap.

## Build / verify
```
cd Bipuu && xcodegen && xcodebuild -scheme Bipuu -configuration Debug build
for s in scripts/test-*.sh; do bash $s; done
scripts/forbidden-content-check.sh
```
Without full Xcode, typecheck with `swiftc -typecheck` against the macOS 26.5 SDK (the 27 SDK needs the
SwiftUI macro plugin that only ships with Xcode).

## Rules
- Swift 6, strict concurrency. No third-party dependencies unless truly unavoidable.
- Core concepts are Project, Task, Agent, Session, Host, Environment, AgentEvent, Approval. Vendors
  (Claude, Cursor, Zed, GitHub…) are adapters; never add `if host == "…"` / `if agent == "…"` to core code.
- Secrets only in the Keychain, never in files or logs. No telemetry. Network calls only to services the
  user configured; no third-party default endpoints.
- Never block the agent: if Bipuu does not answer, the hook exits and the agent asks in its own UI.
- Never overwrite another tool's config: dated backup, merge, show the diff, write after confirmation, and
  only touch entries marked as Bipuu's (`bipuu-hook`).
- Never approve anything without an explicit click. The approval card must show the full operation.
- Performance is a requirement: 0 % CPU when hidden, no polling for unconfigured features.
- The Coucou/Mochi identity (names, character, artwork, sounds) is not part of this project. Do not
  recreate or imitate it. `scripts/forbidden-content-check.sh` enforces this in CI.
- Identifiers are a contract: see [docs/IDENTIFIERS.md](docs/IDENTIFIERS.md) before renaming one.
