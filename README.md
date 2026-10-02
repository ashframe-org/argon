# Argon (Ashframe's Cubyz Client)

Lightweight Modification that brings improved game & network performance along with some cool multiplayer / singleplayer features.

## What it does

- Chunks & Lighting are cached in RAM & DISK.
- **Performance**: uses a fast multi-core allocator instead of the engine's
  debug allocator; right-sized GPU buffers; cached chunk-visibility traversal
  with per-frame frustum culling. Much higher FPS at large render distances,
  and far less VRAM/RAM use.
- **Clean join**: a logo + progress screen with staged status ("loading
  chunks", "syncing time") that holds the world hidden until it is actually
  ready, so there are no dark/bare first frames or flashes.
- **Shop signs**: item icons & click a sign to open the buy menu.
- **Chat**: tab-completion for commands and subcommands, `@name`
  completion, and gold `@mention` pings.
- **MTU path discovery** (RFC 8899): sizes packets to your connection on
  high-latency / lossy links for fewer stalls.
- faster handshake on high-latency links, stable ping.
- Skips re-unpacking server addons when unchanged.
- Fixes flashing translucent (water/glass) squares on some GPUs/drivers.
- Delete `~/.cubyz/ashframeCache/` anytime to force a full redownload.
- Set `ashframeDebug = false` in `launchConfig.zon` to silence the
  `[fps]`/cache debug logging.

## Comparison (live Ashframe server, Sep–Oct 2026)

Timings are measured session averages (`~` = approximate); behaviour rows
(marked ✳) are qualitative/verified by testing, not timed.

| Task | Vanilla + Vanilla | Vanilla + Ashframe | Argon + Vanilla | Argon + Ashframe |
|---|---|---|---|---|
| Repeat join | ~35 s ❌ | ~12 s 🟡 | ~10 s 🟡 | ~9 s ✅ |
| Asset pack transfer (per join) | ~23 s ❌ | ~0 s ✅ | ~23 s ❌ | ~0 s ✅ |
| Chunk download rate | ~7.6 MB/s ❌ | ~11.1 MB/s ✅ | ~7.6 MB/s 🟡 | ~11.1 MB/s ✅ |
| Terrain-gen stall | ~162 ms/chunk ❌ | ~5 ms/chunk ✅ | ~162 ms/chunk ❌ | ~5 ms/chunk ✅ |
| Revisit / teleport back | full re-stream ❌ | full re-stream ❌ | ~0.16 s ✅ | ~0.16 s ✅ |
| High render-distance FPS ✳ | stock ❌ | stock ❌ | high ✅ | high ✅ |
| Join first frame (dark/flash) ✳ | flash ❌ | flash ❌ | clean ✅ | clean ✅ |
| Flashing water/glass (some GPUs) ✳ | yes ❌ | yes ❌ | fixed ✅ | fixed ✅ |
| Background network traffic ✳ | high ❌ | reduced ✅ | high ❌ | reduced ✅ |
| Startup GPU memory ✳ | stock 🟡 | stock 🟡 | lower ✅ | lower ✅ |
| Stalls on high-latency / lossy links ✳ | — ➖ | — ➖ | — ➖ | fewer ✅ |
| Shop icons / click-to-buy | no ❌ | no ❌ | yes ✅ | yes ✅ |
| Mentions / autocomplete | no ❌ | partial 🟡 | yes ✅ | yes ✅ |
| Extra RAM | — ➖ | — ➖ | ~128 MB 🟡 | ~128 MB 🟡 |


`Vanilla + Ashframe` = server optimisations only. `Argon + Vanilla` =
client-only (cache, performance, clean join, icons, chat, shops). The
high-latency/lossy-link row needs both: the Ashframe server probes and the
Argon client answers.

First join downloads everything once; repeats skip it.

## Install

**Linux**

```bash
git clone -b ashframe https://github.com/ashframe-org/argon.git
cd argon
./run_linux.sh -Doptimize=ReleaseSafe
```

**Windows**

```bat
git clone -b ashframe https://github.com/ashframe-org/argon.git
cd argon
run_windows.bat -Doptimize=ReleaseSafe
```

## Keeping it up to date

```bash
cd argon
git pull
./run_linux.sh -Doptimize=ReleaseSafe
```

## Optional config

`launchConfig.zon` tweaks (defaults work out of the box; our keys are
`ashframeCache`, `ashframeServer`, `ashframeCacheTTLHours`,
`ashframeFlushMaxMB`, `ashframeFlushIntervalMinutes`,
`ashframeCacheMaxMB`, `ashframeReadCacheMB`, `ashframeDebug`,
`ashframeLoadingScreen`, `ashframeClickSignShop`, `mtuProbing`,
`chatWidth`). Set `ashframeLoadingScreen = false` for vanilla-style
instant joining instead of the clean-join screen.

## Notes

- Fork of [Cubyz](https://github.com/PixelGuys/Cubyz) tag `0.4.1`
  (GPLv3, see LICENSE).
- Custom changes marked `ASHFRAME CUSTOM CLIENT` in the source.
