# Argon (Ashframe Custom Client)

Client-side cache and quality-of-life upgrades for the Ashframe Cubyz
server. On other servers it behaves exactly like stock Cubyz 0.4.1.

## What it does

- Caches chunks and lighting on disk; rejoins serve from disk and RAM.
- **LRU eviction**: the areas you revisit (spawn and back) stay cached;
  one-shot chunks (deep caves, fly-throughs) aren't persisted. Same caps.
- Meshes wait for light data, so lighting is correct on arrival.
- Reveals the world once nearby light is resident and the clock synced
  (no false-noon flash, no darkness on rejoin).
- **Shop signs**: item icons + red header on shop signs; click a sign to
  open the buy menu.
- **Chat**: tab-completion for commands and subcommands, `@name`
  completion, and gold `@mention` pings.
- **Shops**: out-of-stock / sales summary on join, and a notice when a
  shop is disbanded.
- Day-on-restart, faster handshake on high-latency links, stable ping.
- Skips re-unpacking server addons when unchanged.
- Delete `~/.cubyz/ashframeCache/` anytime to force a full redownload.

## Comparison (measured on the live Ashframe server, Sep 2026)

Average of test sessions; `~` = approximate. Ranked best-on-the-right
(checkmarks show at-a-glance quality, numbers the actual figures).

| Task | Vanilla + Vanilla | Vanilla + Ashframe | Argon + Vanilla | Argon + Ashframe |
|---|---|---|---|---|
| Repeat join | ~35 s ❌ | ~12 s 🟡 | ~10 s 🟡 | ~9 s ✅ |
| Asset pack transfer (per join) | ~23 s ❌ | ~0 s ✅ | ~23 s ❌ | ~0 s ✅ |
| Chunk download rate | ~7.6 MB/s ❌ | ~11.1 MB/s ✅ | ~7.6 MB/s 🟡 | ~11.1 MB/s ✅ |
| Terrain-gen stall | ~162 ms/chunk ❌ | ~5 ms/chunk ✅ | ~162 ms/chunk 🟡 | ~5 ms/chunk ✅ |
| Revisit / teleport back | full re-stream ❌ | full re-stream ❌ | ~0.16 s ✅ | ~0.16 s ✅ |
| Dark shadows / night flash | yes ❌ | yes ❌ | no ✅ | no ✅ |
| Shop icons / click-to-buy | no ❌ | no ❌ | yes ✅ | yes ✅ |
| Mentions / autocomplete / shop report | no ❌ | partial 🟡 | yes ✅ | yes ✅ |
| Extra RAM | — ➖ | — ➖ | ~128 MB 🟡 | ~128 MB 🟡 |

Legend: ✅ best · 🟡 good/partial · ❌ worst/none · ➖ n/a.

`Vanilla + Ashframe` = server optimisations only. `Argon + Vanilla` =
client-only (cache, icons, chat, shops). `Argon + Ashframe` = both.

First join downloads everything once; repeats skip it.

## Install

1. Clone this repo and check out branch `ashframe`.
2. Build normally (`zig build -Doptimize=ReleaseSafe`).
3. `git pull` for updates.
4. Optional `launchConfig.zon` tweaks (defaults work out of the box;
   our keys are `ashframeCache`, `ashframeServer`,
   `ashframeCacheTTLHours`, `ashframeFlushMaxMB`,
   `ashframeFlushIntervalMinutes`, `ashframeCacheMaxMB`,
   `ashframeReadCacheMB`, `ashframeDebug`, `chatWidth`).

## Notes

- Fork of [Cubyz](https://github.com/PixelGuys/Cubyz) tag `0.4.1`
  (GPLv3, see LICENSE).
- Custom changes marked `ASHFRAME CUSTOM CLIENT` in the source.
