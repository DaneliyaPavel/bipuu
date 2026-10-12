# Bipuu — agent integration

Any tool that can run a command on an event can show its activity in Bipuu, and tools with a
permission prompt can have it answered from the island. Bipuu never blocks an agent: if the app is
closed, unreachable or does not answer, the relay prints nothing and the agent asks in its own UI.

> **Platform status.** The relay and app described here are the **macOS** implementation. The Rust
> relay in `hook/` (Windows/Linux) still speaks the older unauthenticated protocol and is not wired to
> any app yet; it is the seed of the cross-platform `bipuu-hook` and must adopt the BIPUU1 channel below
> before use.

## The `bipuu_agent` field

Add the optional field `bipuu_agent` to a hook payload (the relay does it for you with `--agent <name>`).
Bipuu routes all events carrying it to a pill labelled with that name.

**Validation:** the name must match `^[a-z0-9-]{1,24}$` (lowercase letters, digits and hyphens, 1–24 characters). An absent or invalid name routes the event to the Claude Code pill instead.

## Hook command (macOS)

Configure your tool to call the Bipuu relay with `--agent <your-name>` after the hook executable:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "type": "command", "command": "/path/to/bipuu-hook --agent my-tool" }
    ]
  }
}
```

The shell wrapper (`bipuu-hook`) always exits 0 and passes `"$@"` to the Python relay (`bipuu-hook.py`), which injects the agent name, normalises event and field names, and forwards the payload to Bipuu. Both are installed next to the socket at app launch (sources: `Bipuu/Resources/hook`).

## Payload format

The relay adds `bipuu_agent` to the JSON it forwards. You can also add it yourself if you talk to the socket directly:

```json
{
  "hook_event_name": "UserPromptSubmit",
  "session_id": "my-session-1",
  "bipuu_agent": "my-tool",
  "prompt": "Running task…"
}
```

## The channel (protocol BIPUU1)

The socket is `~/Library/Application Support/Bipuu/bipuu.sock` (directory 0700, socket 0600, same user
only). Use the relay if you can. If you must talk to the socket yourself, every message must prove it
comes from a holder of the channel key:

```
request   BIPUU1 <nonce> <mac>\n<json>\n          mac = HMAC-SHA256(key, "bipuu1|"  + nonce + "|" + json)
reply     BIPUU1R <mac>\n<json>\n                 mac = HMAC-SHA256(key, "bipuu1r|" + nonce + "|" + json)
```

- `key` is the 32 bytes in `~/Library/Application Support/Bipuu/channel.key` (64 hex characters; the app
  creates it with mode 0600 and you must refuse it if anyone else can read it).
- `nonce` is 32 lowercase hex characters, fresh for every request. The reply is bound to it.
- `<json>` is the exact bytes that were signed, on one line.
- The app drops a request without a valid signature **without replying** (and logs one line a minute,
  never any content). A client must ignore any reply whose signature does not verify for its own nonce
  and treat that as "no decision": **print nothing, exit 0, let the agent ask**.
- Before connecting, check that the directory and the socket belong to you and are not accessible to
  others, and that the peer is your own user (`LOCAL_PEERCRED`). The relay does all of this.

Messages the app answers on the same connection: `{"permissionDecision": "allow" | "always" | "deny" |
"ask" | "answer", "answers": {...}}` for a `PermissionRequest` or an `AskUserQuestion`; events get
`{"ok":true}`.

This protects against processes that cannot read `channel.key` (squatting the socket path, forging
approval cards, replaying old replies, tampering). It does not defend against malware running as the
same user, which can read the key and could equally rewrite the agent's own settings; see
[SECURITY_BASELINE.md](SECURITY_BASELINE.md).

Payload example (before signing):

```json
{
  "hook_event_name": "UserPromptSubmit",
  "session_id": "my-session-1",
  "bipuu_agent": "my-tool",
  "prompt": "Running task…"
}
```

## Supported events

All standard Claude Code hook events are supported. A `PermissionRequest` gets an approval card for
Claude Code (and Cursor, which rides its hooks), Codex, Copilot CLI, Muse Code, and Hermes when its
approval transport is enabled. For any other agent it is answered immediately with "ask", so the relay
writes nothing and the agent asks in its own terminal.

**What the card shows.** The operation itself, in full: the whole command, file path and the text being
replaced or written, URL, or MCP arguments (invisible and direction-changing characters are shown as
visible `⟨U+…⟩` escapes). The block scrolls instead of clipping, and anything cut at 16 KB is flagged in
red. **Always** is offered only when its exact effect can be shown (for Claude Code: each rule in
`permission_suggestions` and where it will be saved); Codex, Copilot and Muse have no durable rule, so
they only get Allow and Deny. Nothing is ever approved without a click.

The pill lifecycle:

| Event | Effect |
|---|---|
| `SessionStart` | Creates the pill (if absent), sets state to idle |
| `UserPromptSubmit` | State → thinking; prompt shown in ticker |
| `PreToolUse` | State → working; tool label shown in ticker |
| `PostToolUse` / `PostToolUseFailure` | State → working |
| `Notification` | Rate-limit or question state if applicable |
| `Stop` | State → finished for 5 s; active declared pills (catalog + checked in Settings) reset to idle — all others are removed |
| `StopFailure` | State → error |
| `SessionEnd` | Active declared pills (catalog + checked in Settings) reset to idle — all others are removed |
| `SubagentStart` / `SubagentStop` | Step added to ticker |

## Declared pills

A **declared pill** is a catalog entry (`PillCatalog.swift`) that has been enabled in **Settings → Active pills**. When a session ends for a declared pill, the pill stays visible and resets to idle instead of disappearing.

A catalog pill that is not checked in Settings behaves like any other agent: it gets an automatic pill when a session starts, and that pill is removed when the session ends.

Gemini CLI (`agent_gemini`), Antigravity (`agent_antigravity`), GitHub Copilot CLI (`agent_copilot`), Muse Code (`agent_muse`), OpenCode (`agent_opencode`), Amp (`agent_amp`), Hermes (`agent_hermes`), Cursor (`agent_cursor`) and Codex (`agent_codex`) can be declared in Settings → Active pills. These pill ids are legacy and will be replaced by Agent/Host/Session ids (see [ROADMAP.md](ROADMAP.md)).

Claude Desktop (`agent_claude-desktop`) is there as well. Claude Code sessions started from the Claude desktop app's Code tab carry `CLAUDE_CODE_ENTRYPOINT=claude-desktop`; the relay tags them `bipuu_agent: claude-desktop` on its own (an explicit `--agent` still wins), so nothing extra is installed. Declare the pill to keep it after the session ends; the ↗ button opens the Claude app.

## Real-world examples

### Gemini CLI (macOS)

Bipuu supports Gemini CLI via **Settings → Gemini CLI → Install hooks**.
The installer writes to `~/.gemini/settings.json` and uses `--agent gemini` so
Gemini sessions get their own pill. The relay translates Gemini event names to canonical
Bipuu events automatically.

| Gemini CLI event | Canonical event |
|---|---|
| `BeforeTool` | `PreToolUse` |
| `AfterTool` | `PostToolUse` |
| `BeforeAgent` | `UserPromptSubmit` |
| `AfterAgent` | `Stop` |

`AfterModel` is not installed — it fires on every response chunk and would flood the island.

### Antigravity — `agy` (macOS)

Bipuu supports Antigravity out of the box via **Settings → Antigravity → Install hooks**.
The installer writes to `~/.gemini/config/hooks.json` (timeouts in seconds) and uses
`--agent antigravity`. The relay translates `toolCall.name` / `conversationId` to the
island's `tool_name` / `session_id`.

| Antigravity event | Canonical event |
|---|---|
| `PreInvocation` | `UserPromptSubmit` |
| `PreToolUse` | `PreToolUse` |
| `PostToolUse` | `PostToolUse` |
| `PostInvocation` | `PostToolUse` |
| `Stop` | `Stop` |

### GitHub Copilot CLI (macOS)

Bipuu supports Copilot CLI out of the box via **Settings → GitHub Copilot CLI Hooks → Install hooks**.
The installer writes to `~/.copilot/hooks/bipuu.json` and uses `--agent copilot`.
Copilot CLI uses camelCase event names and `{"bash":"…","timeoutSec":N}` entries.
Copilot CLI is fail-closed on `permissionRequest`: the relay always outputs valid JSON
and returns `{"permissionDecision":"ask"}` on timeout so Copilot re-prompts in the terminal.
Bipuu shows a real Allow / Deny card for Copilot approval requests.

| Copilot CLI event | Canonical event |
|---|---|
| `sessionStart` | `SessionStart` |
| `userPromptSubmitted` | `UserPromptSubmit` |
| `preToolUse` | `PreToolUse` |
| `permissionRequest` | `PermissionRequest` |
| `postToolUse` | `PostToolUse` |
| `agentStop` | `Stop` |
| `sessionEnd` | `SessionEnd` |
| `notification` | `Notification` |

### Muse Code (macOS)

Bipuu supports Muse Code out of the box via **Settings → Muse Code Hooks → Install hooks**.
The installer merges into `~/.config/muse/settings.json` and uses `--agent muse`.
Muse uses PascalCase event names. Bipuu shows a real Allow / Deny card for Muse approval requests.

| Muse Code event | Canonical event |
|---|---|
| `SessionStart` | `SessionStart` |
| `UserPromptSubmit` | `UserPromptSubmit` |
| `PreToolUse` | `PreToolUse` |
| `PermissionRequest` | `PermissionRequest` |
| `PostToolUse` | `PostToolUse` |
| `Stop` | `Stop` |
| `SessionEnd` | `SessionEnd` |

### OpenCode (macOS)

Bipuu supports OpenCode via **Settings → OpenCode Plugin → Install plugin**.
The installer writes a JS plugin to `~/.config/opencode/plugins/bipuu.js`.
The plugin maps OpenCode event types to canonical Bipuu names and forwards them fire-and-forget; OpenCode is never blocked.

| OpenCode event | Canonical event |
|---|---|
| `session.created` | `SessionStart` |
| `session.idle` | `Stop` |
| `session.error` | `StopFailure` |
| `session.deleted` | `SessionEnd` |
| `tool.execute.before` | `PreToolUse` |
| `tool.execute.after` | `PostToolUse` |
| `permission.asked` | `PermissionRequest` |

### Amp (macOS)

Bipuu supports Amp via **Settings → Amp Plugin → Install plugin**.
The installer writes a TypeScript plugin to `~/.config/amp/plugins/bipuu.ts`.
The `tool.call` handler returns `{ action: 'allow' }` so Amp always proceeds; all events are forwarded display-only.

| Amp event | Canonical event |
|---|---|
| `session.start` | `SessionStart` |
| `agent.start` | `UserPromptSubmit` |
| `tool.call` | `PreToolUse` |
| `tool.result` | `PostToolUse` |
| `agent.end` | `Stop` |

### Hermes Agent (macOS)

Bipuu supports Hermes via **Settings → Agents → Hermes → Install plugin**.
The installer writes a Python plugin to `~/.hermes/plugins/bipuu/` and enables it in
`~/.hermes/config.yaml`. The plugin uses `on_session_start` (sends the platform when running
via the gateway), `post_llm_call` (sends the final response), and a `pre_approval_request`
observer hook that fires a `⏳ Approval pending in Hermes` step in the notch.
Approving from the notch requires `register_approval_transport`, which is not yet available
in Hermes 0.15.x; the Approvals toggle activates automatically once Hermes exposes it.
Every event is fire-and-forget: if the app is closed or unreachable, nothing is sent and Hermes carries on, handling approvals itself.

| Hermes event | Canonical event |
|---|---|
| `on_session_start` | `SessionStart` |
| `post_llm_call` | `Stop` |
| `pre_approval_request` | `PreToolUse` (observer only, shows "⏳ Approval pending in Hermes") |

### Any other tool

Call `bipuu-hook --agent <your-name> <EventName>` and let the relay forward the event.

## Quick test (macOS)

With Bipuu running:

```sh
echo '{"hook_event_name":"UserPromptSubmit","session_id":"t1","prompt":"hello","bipuu_agent":"demo"}' \
  | /bin/sh ~/Library/Application\ Support/Bipuu/bipuu-hook --agent demo
```

A "demo" pill should appear in the island. For diagnostics, start the app with `BIPUU_HOOK_TRACE=1`: one line
per hook event (event name, agent, shortened session id, tool name — never content) goes to
`~/Library/Logs/Bipuu/bipuu.log`.

## Tests

`bash scripts/test-hook-relay.sh` runs the relay's contract tests against a fake app: fail-open behaviour,
per-agent decision formats, event normalisation, and the channel authentication cases above.
