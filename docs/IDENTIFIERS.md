# Bipuu — stable identifiers

These identifiers are a contract: Keychain items, preferences, permissions, IPC and agent configs
depend on them. Change one only with a migration. **Provisional** = must be confirmed before the first
signed public release (there are no installed users yet, so changing now is free).

| Identifier | Value | Status |
|---|---|---|
| Bundle identifier | `app.bipuu.Bipuu` | **Provisional** — confirm the reverse-DNS domain Bipuu owns |
| Keychain service | `app.bipuu.Bipuu` | follows bundle id |
| Application Support dir | `~/Library/Application Support/Bipuu/` | stable |
| Hook socket (macOS) | `~/Library/Application Support/Bipuu/bipuu.sock` (dir 0700, socket 0600) | stable |
| Hook relay | `~/Library/Application Support/Bipuu/bipuu-hook` (+ `bipuu-hook.py`) | stable |
| Log dir | `~/Library/Logs/Bipuu/` | stable |
| Hook payload fields | `bipuu_agent`, `bipuu_kind`, `bipuu_has_transport` | stable; `bipuu_agent` matches `^[a-z0-9-]{1,24}$` |
| Hook ownership marker | any hook command containing `bipuu-hook` | stable — install/uninstall touch only these entries |
| Config files written for other agents | `~/.copilot/hooks/bipuu.json`, `~/.config/opencode/plugins/bipuu.js`, `~/.config/amp/plugins/bipuu.ts`, `~/.hermes/plugins/bipuu/`, key `"bipuu"` in Gemini/Antigravity hooks | stable |
| Env vars | `BIPUU_*` | stable |
| Windows pipe / Linux socket (cross-platform relay) | `\\.\pipe\bipuu-<SID>`, `$XDG_RUNTIME_DIR/bipuu.sock` | stable |
| Git-hash plist key | `BipuuGitHash` | stable |
| Hot-key signature | `BIPU` | stable |
| Pill / session ids (`integration_claude`, `agent_*`) | legacy Coucou-style ids, internal only | **will be replaced** by Agent/Host/Session ids in Phase 2–3 |

Not shipped: any Coucou identifier, signing identity, Apple team id, iCloud/CloudKit container,
push topic, relay endpoint or URL scheme (see [IP_MIGRATION.md](IP_MIGRATION.md) §5).
Bipuu does **not** detect or remove Coucou's hooks: its markers differ, so the two never interfere.
