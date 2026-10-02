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

## Comparison (measured on the live Ashframe server, Sep 2026)

Average of test sessions; `~` = approximate. Ranked best-on-the-right

| Task | Vanilla + Vanilla | Vanilla + Ashframe | Argon + Vanilla | Argon + Ashframe |
|---|---|---|---|---|
| Repeat join | ~35 s ❌ | ~12 s 🟡 | ~10 s 🟡 | ~9 s ✅ |
| Asset pack transfer (per join) | ~23 s ❌ | ~0 s ✅ | ~23 s ❌ | ~0 s ✅ |
| Chunk download rate | ~7.6 MB/s ❌ | ~11.1 MB/s ✅ | ~7.6 MB/s 🟡 | ~11.1 MB/s ✅ |
| Terrain-gen stall | ~162 ms/chunk ❌ | ~5 ms/chunk ✅ | ~162 ms/chunk ❌ | ~5 ms/chunk ✅ |
| Revisit / teleport back | full re-stream ❌ | full re-stream ❌ | ~0.16 s ✅ | ~0.16 s ✅ |
| Shop icons / click-to-buy | no ❌ | no ❌ | yes ✅ | yes ✅ |
| Mentions / autocomplete | no ❌ | partial 🟡 | yes ✅ | yes ✅ |
| Chunk-visibility traversal | every frame ❌ | every frame ❌ | cached ✅ | cached ✅ |
| Extra RAM | — ➖ | — ➖ | ~128 MB 🟡 | ~128 MB 🟡 |


`Vanilla + Ashframe` = server optimisations only. `Argon + Vanilla` =
client-only (cache, icons, chat, shops). `Argon + Ashframe` = both.

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
`ashframeClickSignShop`, `mtuProbing`, `chatWidth`).

## Notes

- Fork of [Cubyz](https://github.com/PixelGuys/Cubyz) tag `0.4.1`
  (GPLv3, see LICENSE).
- Custom changes marked `ASHFRAME CUSTOM CLIENT` in the source.
