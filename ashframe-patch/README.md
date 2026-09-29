# Ashframe Custom Client

Client-side cache for the Ashframe Cubyz server. On other servers it behaves
exactly like stock Cubyz 0.4.1.

## What it does

- Skips re-unpacking server addons when they didn't change.
- Saves downloaded chunks and lighting to disk, reuses them on revisit.
  Writes are batched in RAM and flushed periodically, not on every chunk.
  Chunks pack 64 per region file (lightmaps 16): measured ~79 MB of real
  data in ~93 MB on disk across ~4600 files (was ~500 MB across 100k+
  tiny files before bucketing).
- In-RAM read cache (default 128 MB cap) + connect prefetch, so rejoins
  serve from memory; each downloaded blob is stored once (write buffer
  serves until flush, then disk + read cache).
- Edited areas re-download automatically. Old data expires on its own.
- Chunk meshes wait for their light data before building, mesh builds
  never go dark, and landed lightmaps relight already-built meshes —
  lighting is correct on arrival instead of dark-until-revisit.
- The world only reveals once near lightmaps are resident (measured
  coverage, "Loading lightmaps... r/t") and the server clock has synced
  (no false-noon flash on night joins).
- Faster handshake ramp on high-latency links (send pacing only).
- Stable ping readout (median of recent samples, no more 0 ms flashes).
- Delete `~/.cubyz/ashframeCache/` anytime to force a full redownload.

## Vanilla vs custom client (measured, high-latency link)

| | Vanilla 0.4.1 | Ashframe client |
|---|---|---|
| Repeat join | 28–42 s | ~7–13 s |
| Asset pack re-download | every join (~17–29 s) | skipped when unchanged (~0 s) |
| Revisit / teleport back | full re-stream | instant from disk |
| Dark shadows until teleport | yes | no (waits for light data) |
| Night join bright flash | yes (renders noon until server time) | no (waits for clock sync) |
| First serve pass, cached rejoin | n/a (streams) | ~0.16 s for ~95k blobs (region-file cache; was ~1.3 s) |
| Disk cache | n/a (re-downloads) | ~93 MB for ~79 MB data, ~4600 files |
| Extra RAM while playing | — | ~128 MB read cache (cap) + write buffer, single copy each (both configurable) |
| Chat width | 256 px fixed | configurable |

First-ever join still downloads everything once; repeats skip it.
Disk/RAM numbers measured Sep 2026 on the live server cache; caps are
`ashframeCacheMaxMB` / `ashframeReadCacheMB` / `ashframeFlushMaxMB`.

## Install

1. Get clean Cubyz 0.4.1 source (tag `0.4.1`).
2. Copy the `src/` files from here over the matching paths.
3. Build normally.
4. Optional `launchConfig.zon` settings (defaults work out of the box;
   see `launchConfig.example.zon` for all keys with comments):
   `.ashframeCache = true`, `.ashframeServer = "cubyz.ashframe.net"`,
   `.ashframeCacheTTLHours = 24`, `.ashframeFlushMaxMB = 256`,
   `.ashframeFlushIntervalMinutes = 5`, `.ashframeCacheMaxMB = 256`,
   `.ashframeReadCacheMB = 128`,
   `.ashframeDebug = true`, `.chatWidth = 480`.

## Notes

- Derived from Cubyz 0.4.1 (GPLv3, see LICENSE).
- 10 changed files, marked `ASHFRAME CUSTOM CLIENT` in the source.
