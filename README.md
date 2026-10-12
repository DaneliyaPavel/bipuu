# Bipuu

**A living workspace and control plane for AI software agents.**

Bipuu shows what your AI coding agents are doing — which project, which task, what changed,
where you are needed — without making you watch a terminal. Local-first, no telemetry,
no account.

> Status: **Phase 1 — clean foundation.** The macOS app currently provides the ambient island
> (notch / top bar), live agent sessions via hooks, approvals and questions. The task-centric
> workspace, the domain model and the original character system are on the roadmap.
> See [docs/ROADMAP.md](docs/ROADMAP.md) and [docs/PRODUCT_VISION.md](docs/PRODUCT_VISION.md).

## Supported agents (today)

Claude Code, Codex, Copilot CLI, Muse Code, Hermes (live sessions and approvals);
Gemini CLI, Antigravity, OpenCode, Amp (activity only). Any tool that can write a JSON line to
the local socket can be added — see [docs/AGENTS.md](docs/AGENTS.md).

## Build (macOS 15+)

```
cd Bipuu && xcodegen && xcodebuild -scheme Bipuu -configuration Debug build
```

Tests are standalone Swift scripts: `for s in scripts/test-*.sh; do bash $s; done`.

## Design principles

Work, not settings · agent ≠ host ≠ environment · adapters, never vendor branches in the core ·
interrupt only when your judgement matters · near-zero idle cost.

## Repository documents

[docs/ARCHITECTURE_BASELINE.md](docs/ARCHITECTURE_BASELINE.md) ·
[docs/SECURITY_BASELINE.md](docs/SECURITY_BASELINE.md) ·
[docs/IP_MIGRATION.md](docs/IP_MIGRATION.md) ·
[docs/IDENTIFIERS.md](docs/IDENTIFIERS.md)

## Licence and provenance

MIT. Bipuu began from the MIT-licensed source code of [Coucou](https://github.com/louis-cfm/coucou)
by Louis Raillé; the Coucou name, the Mochi character and all of its artwork, sounds and media are
**not** part of Bipuu. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and
[docs/IP_MIGRATION.md](docs/IP_MIGRATION.md).
