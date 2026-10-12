# Bipuu — IP / Licence migration (Coucou → Bipuu)

Source of truth for the transition. Engineering inventory, **not legal advice**; get a lawyer's read before commercial release.
Basis: Coucou @ `0dffbaf`. Re-run the inventory commands at import time; counts may drift.

## 1. Licence structure

| Document | Covers | Holder |
|---|---|---|
| `LICENSE` (MIT) | source code | © 2026 Louis Raillé |
| `LICENSE-ASSETS.md` | names *Coucou*, *Mochi*; the Mochi character ("design, look, expressions and animations as a character"); app + menu-bar icons; sounds; everything in `docs/media/`, `design/`; copies in `android/`, `windows/` | Louis Raillé, all rights reserved |
| `android/LICENSE` (MIT) | Android code and `windows/.../phone_link/` | © 2026 Rhytam Biswas |
| `android/PERMISSION.md` | narrow, non-transferable, revocable permission for the Android port to use the assets | — **Bipuu cannot inherit it** |

Explicitly allowed: fork and ship under **your own name, icon, character and sounds**. Explicitly forbidden: shipping under Coucou/Mochi names or with the icon/character/sounds.

## 2. Rule for Bipuu

**Zero reuse of anything in §3–§4. When in doubt, remove.** Preserve MIT notices for any retained code (§7).

## 3. Protected creative assets (remove / replace)

| Group | Path | Count | Build-critical? | Action |
|---|---|---|---|---|
| Mac app + menu-bar icon | `NotchBuddy/Assets.xcassets` | 13 PNG | **yes** (`AppIcon`; menu-bar has SF Symbol fallback) | replace with neutral placeholder |
| iPhone icons | `NotchBuddy/PhoneAssets.xcassets` | 14 PNG | yes (iPhone target) | delete with iPhone target |
| Win/Linux icons | `windows/src-tauri/icons/` (+ `scripts/gen-icons.mjs` draws Mochi procedurally) | 5 | yes (bundling) | replace; delete generator |
| Android icons | `mipmap-xxxhdpi/ic_launcher.png`, `drawable/ic_stat_mochi.xml` | 2 | yes | delete with Android |
| Mac sounds | `NotchBuddy/Resources/sounds/*.wav` | **29** (CLAUDE.md says 28) | folder ref in `project.yml`; missing file is skipped at runtime | delete all; `SoundEngine` → no-op |
| Android sounds | `android/.../res/raw/*.wav` | 14 | yes (`R.raw.*`) | delete with Android |
| Docs media | `docs/media/` | 17 (8 JPG, 7 PNG, GIF, MP4) | README/site only | delete |
| Design | `design/captures` (34 PNG), `design/outfits` (3), `design/animations` (2), `design/prototype/notch-buddy.html` | 40 | no (orphaned) | delete |
| Windows screenshots | `windows/screenshots/` | 7 PNG | README only | delete |
| Site | `docs/*.html`, `site.css` | 8 | no | delete / rewrite |

Totals found: 81 PNG, 8 JPG, 43 WAV, 1 GIF, 1 MP4, 1 ICO. **No fonts, SVG files, ML/wake-word models** in the repo. Sound provenance: SPEC says rendered from the prototype's own engine (author's synthesis) — still reserved.

## 4. MIT code that encodes the reserved character (the subtle risk)

The character exists **only as drawing code**. The MIT grant covers the code, but the code's output is the reserved design (geometry constants, eye shapes, colours, badges, 12 outfits). Keeping it risks an infringement claim and store takedown. **Decision: delete.**

| Files | ~Lines |
|---|---|
| `CoucouKit/BotEngine.swift` (mixes state machine + drawing) | 1,868 |
| `CoucouKit/MochiOutfitDrawing.swift`, `MochiWardrobe.swift`, `MochiStill.swift` | 1,464 / 89 / 89 |
| `BotCanvasView`, `GreetingCanvasView`, `UploadCanvasView`, `UploadSequenceEngine`, `FileDropView` | 315 / 689 / 582 / 437 / 124 |
| `DesktopMochi.swift`, `DesktopMochiLogic.swift` | 769 / 82 |
| `MochiLiveActivity.swift`, `MochiLive.swift` | 235 / 38 |
| `windows/src/mochi/*` (engine, outfits, greeting, wardrobe, minibots, desktop-logic) | ~3.7k |
| `android/.../mochi/**` | ~2k |
| `design/outfits/mochi-outfits.js` (source the ports derive from) | 618 |

**Safe to keep as *ideas / mechanics* (rewrite rather than copy-trace):** easing/tween machinery, the *concept* of an 11-state enum, blink scheduling, eye-tracking maths, particle pruning, island FSM. Re-implement behind a new `CharacterRenderer` protocol; the Bipuu organism is drawn from scratch and **not traced** from Mochi.

## 5. Identifier inventory (brand-bearing or compatibility-sensitive)

Since Bipuu is a *new product with no installed base*, almost everything is "rename now". Migration code is needed **only** to clean up pre-existing Coucou hook entries on a developer machine (optional).

| Identifier | Where | Action |
|---|---|---|
| `app.example.NotchBuddy` | `project.yml`, Info.plist, entitlements, Keychain service (`ClaudeService.swift:7`, 16 uses) | rename now |
| `app.example.Coucou`, `.Widgets`, `.NotificationContent` | App Store + iPhone | delete (targets dropped) |
| `iCloud.app.example.Coucou` (14 refs), `group.app.example.Coucou` | PhoneLink, entitlements | delete |
| `app.example.Coucou.push-type.liveactivity`, `APNS_TEAM_ID TEAMID-REMOVED` | `relay/wrangler.toml` | delete |
| `TEAMID-REMOVED` (author's Apple Team ID) | `project.yml` ×7, `.pbxproj` ×23, entitlements, scripts | **must not appear in Bipuu** |
| `https://coucou-relay.relay.example.invalid` | `LiveActivityRelay.swift:28` (default!) | **delete — would route Bipuu data through a third party** |
| `app.example.coucou` (Tauri id, keyring), `app.example.Coucou.Focus` | `tauri.conf.json`, `secrets.rs`, `portal.rs`, `linux_focus.rs` | rename |
| `~/Library/Application Support/NotchBuddy/`, `~/Library/Logs/NotchBuddy/`, `nb.sock` | `HookServer.swift:17`, `SoundEngine`, `RecapStore` | rename |
| `~/.claude/coucou/{nb-hook,nb-hook.py}` | `HookServer.swift:1571` | rename |
| `nb-hook`, `coucou-hook` | 13 files | rename → `bipuu-hook` |
| `coucou_agent` payload field | 15 files | rename → `bipuu_agent`; optionally accept both on read |
| pipe `\\.\pipe\coucou-<sid>`, `$XDG_RUNTIME_DIR/coucou.sock` | `pipe.rs`, `platform/linux.rs` | rename |
| Hook detection by substring `"NotchBuddy"`/`"coucou"`/`"nb-hook"` | `ClaudeHookDetection`, `HookServer`, `agent_hooks.rs` | replace with explicit Bipuu marker (also fixes SECURITY M5) |
| `COUCOU_*` env vars (≈12) | CI, Linux switches, tests | → `BIPUU_*` |
| `coucou://` scheme, `_coucou._tcp` mDNS, `coucou-relay/v1` HKDF label | phone link | delete with phone link (rename if revived) |
| `com.coucou.android` (186 files) | Android | delete |
| UserDefaults keys (~51; `mochiOutfit`, `outfitPresence`, `greetThreshold`, `coucouHooksInstalled`, `coucou.musicAutomationGranted`, …) | App | rename/delete |
| Updater feed | **none exists** | design Bipuu's own |
| URLs: `github.com/Louis-CFM/coucou`, `louis-cfm.github.io/coucou/*`, TestFlight `testflight.example.invalid` | README, `release.sh`, PKGBUILD, `AboutView.swift`, `WeeklyRecapView.swift:305`, `recap/share.ts:33` | delete / replace |

CLAUDE.md of Coucou forbids renaming bundle id/pill ids **for Coucou**; that constraint does not carry over to Bipuu, but Bipuu must define its *own* stable contract IDs from day one (see ROADMAP).

### Author personal data that must not leak into Bipuu
`removed@example.invalid` (LICENSE-ASSETS, `docs/terms|support|legal.html`), `example.invalid`, `projectColors` hard-coding the author's projects (`IslandTypes.swift:221-230`, `windows/src/core/layout.ts:205-212`: "korus", "sbe hub", "morning ai brief", "publication ig", …), private n8n host in `docs/INTEGRATIONS.md:207`, `/Users/user/…` in a `HookServer.swift:22` comment, `© Louis Raille` in `tauri.conf.json:52`, ~50 contributor emails in git history, Team ID `TEAMID-REMOVED`.

## 6. Third-party marks and data

`PillCatalog.swift` uses product *names + hex colours* only (no logo files): Claude, Codex, Cursor, Gemini, Copilot, Spotify `#1DB954`, Stripe `#0570DE`, Claude Desktop `#D97757`, n8n `#F29B38`, Apple Music `#FA2D48`. Likely nominative use; **Bipuu must not ship other companies' logos and should choose its own neutral colour system** (agent identity via silhouette per the vision, not brand colour). Other: Spotify artwork host, Coinbase/OKX/open-meteo/ElevenLabs APIs (all removed with non-core features).

## 7. Notices that must remain

- If **any** Coucou MIT code is retained: keep `Copyright (c) 2026 Louis Raillé` + MIT text (ship as `THIRD_PARTY_NOTICES` or keep `LICENSE` with Bipuu's own copyright line added above it).
- If `windows/.../phone_link/` or `android/` code is reused: keep `android/LICENSE` (Rhytam Biswas) and the header in `phone_link/mod.rs`. **Not planned for v1.**
- If Android is ever kept: ZXing core 3.5.3 and AndroidX/Compose/CameraX (Apache-2.0) via `licenses/NOTICES.txt`.
- Rust/npm deps in `windows/`: no consolidated NOTICE in the repo; generate with `cargo about`/`cargo deny` + `license-checker` before shipping. Dev-only npm trees contain MPL-2.0 (lightningcss) and LGPL-3.0 (`@img/sharp-libvips-*`) transitive packages — build tooling, not shipped in Worker bundles.
- `linux/arch/PKGBUILD` declares `LicenseRef-coucou-assets` (community maintainer FabioLukas123) → delete.
- The Mac app has **no third-party dependencies** (no SPM packages) → nothing to attribute there.

## 8. Unclear legal status (do not reuse until resolved)

1. ~50 external contributors, **no CLA**; 179 commits authored "Claude" (copyright in AI-generated code unclear). Mitigation: Bipuu keeps only retained files; for each retained file check `git log` authorship; rewrite where multi-author and important.
2. `android/.../licenses/NOTICES.txt` says the code is © Louis Raillé while `android/LICENSE` says © Rhytam Biswas — inconsistent.
3. `windows/src/views/icons.ts` SVG paths "standing in for SF Symbols" — Apple's SF Symbols licence restricts imitation; **do not reuse**.
4. Screenshots/media show third-party UIs (Stripe, Vercel, GitHub, n8n, VS Code) — only `stripe.png` was viewed (invented names). Others unviewed.
5. `HANDOFF.md`, `PROPOSAL_FOR_LOUIS.md` exist at repo root — **not read**; may contain authorship context.
6. Byte-identity of icons/sounds across platforms not checksummed (sizes match).
7. `test-desktop.p12` in Android test resources — contents unverified.

## 9. Non-core feature disposition

| Feature | Files / LOC | Action |
|---|---|---|
| Mochi, wardrobe, outfits, greeting, upload, desktop pet | ~5.5k Swift | **remove** (legal) |
| Sounds | 114 + 29 WAV | remove; keep a no-op sink |
| Voice assistant, wake word, dictation, ElevenLabs | ~6.8k + 300 | remove |
| Spotify, Apple Music, Now Playing | ~1.3k | remove |
| Crypto, Mail | ~490 + ~630 | remove |
| Pollers: Stripe, Resend, n8n, Vercel, Notion, Cal.com | ~800 | remove |
| GitHub pollers (stats/pulse/activity) | ~665 | **defer**; re-introduce later as Git/CI signals via a proper integration, not a poller |
| Local chat / AI chat providers | ~940 (+1.4k Rust) | remove for v1 |
| Weekly recap | ~690 (+1k Rust) | remove (aggregates may inform later cost/quality signals) |
| iPhone app, widgets, Live Activities, PhoneLink, `relay/` | ~10k | remove for v1 |
| Android, Android relay, Windows phone_link | ~21k + 8k | remove for v1 |
| Demo mode | 756 | remove; replace with neutral fixture feed for UI dev |
| Window-context capture (AX title + browser URL via AppleScript) | small | remove for v1 (privacy) |

Estimated outcome: Swift 47.6k → ~28–30k, before `IslandViewContent` is rewritten.

## 10. Execution checklist (Phase 1)

- [ ] Create `bipuu` repo content from Coucou with history preserved (preserves authorship + enables `git log` provenance checks); `upstream` remote → coucou, `origin` → bipuu. *(Decision pending: history vs squash.)*
- [ ] Add `LICENSE` (Bipuu copyright + preserved Raillé MIT text), `THIRD_PARTY_NOTICES.md`.
- [ ] Delete §3 assets and §4 code; add neutral placeholder icon and `NullCharacterRenderer`.
- [ ] Purge §5 personal data and the default relay URL.
- [ ] Drop `LICENSE-ASSETS.md` references; do **not** copy it into Bipuu.
- [ ] CI guard: grep for `coucou|mochi|notchbuddy|example|TEAMID-REMOVED|example` must fail the build outside `docs/IP_MIGRATION.md` and `THIRD_PARTY_NOTICES.md`.
- [ ] Run existing tests; build; verify hook flow end-to-end with Claude Code.
