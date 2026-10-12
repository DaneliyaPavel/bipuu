# Bipuu — Product Vision

*Distilled from the master brief; this is the stable reference. Where the audit contradicts the brief, the audit wins and the difference is noted in ARCHITECTURE_BASELINE.*

## One line
**Bipuu — a living workspace and control plane for AI software agents.**
Friendly name, serious product (≈80% professional productivity software, 20% living-character identity).

## What it answers
Coucou: *what is my coding agent doing right now?*
Bipuu: *what work is happening across my projects, which agents are doing it, what changed, is the result healthy, where am I needed, and what should happen next?*

## Principles
1. **Work, not settings.** The primary unit is a Task/Mission; agent sessions are participants. No admin-panel sidebar (Models/Skills/MCP are capabilities used by work).
2. **Agent ≠ Host ≠ Environment.** Vendors (Claude, Codex, Cursor, Zed, GitHub, Vercel…) are adapters, never core domain primitives. UI adapts to *capabilities*, never `if host == "zed"`.
3. **Durable core:** Project · Task · Agent · Session · Host · Environment · AgentEvent · Artifact · Approval · Result.
4. **Local-first, private, no telemetry**, secrets in OS secure storage, Bipuu never a single point of failure (agents continue if it is closed).
5. **Interrupt only when judgement matters** — policy-aware permissions (auto-allow / ask / explicit confirmation).
6. **Ambient + workspace.** Main workspace answers 8 questions (what's happening, which agents, which tasks, where attention is needed, what changed, health, recent, stuck). Ambient surface (notch / menu bar / tray / top edge) stays calm; the notch is one renderer, not the product.
7. **Git/tests/CI/deploy are context of a task**, not separate products.
8. **Performance is a product requirement** (see budget below).
9. **macOS-first, not macOS-only** by architecture (core independent from SwiftUI/AppKit/notch).
10. **Incremental, no big-bang rewrite.**

## Living agents
One species of *synthetic organism*: soft layered shell around a recessed perceptual core; grown, not assembled (subtle asymmetry, living material tension); soft ceramic / frosted mineral / translucent polymer. Personalities via silhouette, proportions, shell tension, posture, openness, optical system, material, internal light and behaviour — **not primarily colour**.
Initial family (exploratory): Claude (calm, broad), Codex (compact, precise), Research (open, curious), Security (dense, vigilant). Reference sheet supplied by the owner is *design direction, not production assets*.
States: idle, thinking, reading, coding, running_tests, waiting_for_user, success, warning, error, tired. Motion system comes **after** the state model is stable.
Avoid: animals, Mochi resemblance, mascots, emoji, cute robots, game/Pixar characters, mechanical panel lines, glowing robot eye.

## Quality bar
Linear / Raycast / Vercel / Apple-system polish. Avoid generic SaaS cards, neon, gaming, terminal-everywhere.

## Performance budget (proposed, to be measured from day one)
- Hidden/idle: 0.0–0.1% CPU, ≤1 sustained wakeup/s, no timers for unconfigured integrations.
- Visible: ≤30 fps or throttled to 0 fps within 2 s of settling; <5% of one core.
- Hook: <10 ms end-to-end for fire-and-forget events; no resident helper per event beyond the relay process.
- Memory: <60 MB resident idle; every history buffer capped.
- Pollers: exponential backoff capped at 5 min; none when unconfigured.

## Out of scope for the first milestones
Cloud backend, cost dashboard, plugin marketplace, full orchestration automation, mobile apps, all agents at once, complex motion system.
