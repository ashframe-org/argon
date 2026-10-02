# Argon (Ashframe's Cubyz Client)

Lightweight Modification that brings improved game & network performance along with some cool multiplayer / singleplayer features.

## What it does

- Chunks & Lighting are cached in RAM & DISK.
- **Shop signs**: item icons & click a sign to open the buy menu.
- **Chat**: tab-completion for commands and subcommands, `@name`
  completion, and gold `@mention` pings.
- faster handshake on high-latency links, stable ping.
- Skips re-unpacking server addons when unchanged.
- Delete `~/.cubyz/ashframeCache/` anytime to force a full redownload.

## Comparison (measured on the live Ashframe server, Sep 2026)

Average of test sessions; `~` = approximate. Ranked best-on-the-right

| Task | Vanilla + Vanilla | Vanilla + Ashframe | Argon + Vanilla | Argon + Ashframe |
|---|---|---|---|---|
| Repeat join | ~35 s ❌ | ~12 s 🟡 | ~10 s 🟡 | ~9 s ✅ |
| Asset pack transfer (per join) | ~23 s ❌ | ~0 s ✅ | ~23 s ❌ | ~0 s ✅ |
| Chunk download rate | ~7.6 MB/s ❌ | ~11.1 MB/s ✅ | ~7.6 MB/s 🟡 | ~11.1 MB/s ✅ |
| Terrain-gen stall | ~162 ms/chunk ❌ | ~5 ms/chunk ✅ | ~162 ms/chunk ❌ | ~5 ms/chunk ✅ |
| Revisit / teleport back | full re-stream ❌ | full re-stream ❌ | ~0.16 s ✅ | ~0.16 s ✅ |
| Dark shadows / night flash | yes ❌ | yes ❌ | no ✅ | no ✅ |
| Shop icons / click-to-buy | no ❌ | no ❌ | yes ✅ | yes ✅ |
| Mentions / autocomplete / shop report | no ❌ | partial 🟡 | yes ✅ | yes ✅ |
| Extra RAM | — ➖ | — ➖ | ~128 MB 🟡 | ~128 MB 🟡 |


`Vanilla + Ashframe` = server optimisations only. `Argon + Vanilla` =
client-only (cache, icons, chat, shops). `Argon + Ashframe` = both.

First join downloads everything once; repeats skip it.

## Install

**Linux**

```bash
git clone -b ashframe https://github.com/ashframe-org/argon.git
cd argon
./run_linux.sh
```

**Windows**

```bat
git clone -b ashframe https://github.com/ashframe-org/argon.git
cd argon
run_windows.bat
```

## Keeping it up to date

```bash
cd argon
git pull
./run_linux.sh
```

## Optional config

`launchConfig.zon` tweaks (defaults work out of the box; our keys are
`ashframeCache`, `ashframeServer`, `ashframeCacheTTLHours`,
`ashframeFlushMaxMB`, `ashframeFlushIntervalMinutes`,
`ashframeCacheMaxMB`, `ashframeReadCacheMB`, `ashframeDebug`,
`chatWidth`).

## Notes

- Fork of [Cubyz](https://github.com/PixelGuys/Cubyz) tag `0.4.1`
  (GPLv3, see LICENSE).
- Custom changes marked `ASHFRAME CUSTOM CLIENT` in the source.
