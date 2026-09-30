const std = @import("std");

const main = @import("main");

// --- ASHFRAME CUSTOM CLIENT ---
// Per-server asset + chunk caches. Active only on the configured Ashframe
// server; inert elsewhere (no new packets, stock request flow).
// Cache dir: ~/.cubyz/ashframeCache/<server>/ (delete to force redownload).

var dialAddress: ?[]u8 = null;

// --- ASHFRAME CUSTOM CLIENT: join-stage timing (observability only). ---
// Logs per-stage durations on every connect (vanilla + Ashframe) so slow
// joins can be attributed to a stage instead of guessed at. No behavior.
var timingStartMs: i64 = 0;
var timingLastMs: i64 = 0;

fn timingReset() void {
	timingStartMs = main.timestamp().toMilliseconds();
	timingLastMs = timingStartMs;
}

pub fn timingMark(stage: []const u8) void {
	if (!main.settings.launchConfig.ashframeDebug) return;
	const now = main.timestamp().toMilliseconds();
	if (timingStartMs == 0) timingReset();
	std.log.info("[timing] {s}: +{d}ms (total {d}ms)", .{ stage, now - timingLastMs, now - timingStartMs });
	timingLastMs = now;
}

/// Info-level cache chatter, gated behind `ashframeDebug`. Errors log always.
pub fn infoLog(comptime fmt: []const u8, args: anytype) void {
	if (!main.settings.launchConfig.ashframeDebug) return;
	std.log.info("[ashframe] " ++ fmt, args);
}

/// Remembers the typed server address. Called from the connecting window.
/// Flushes first: any still-staged blobs belong to the previous session.
pub fn noteDialAddress(ip: []const u8) void {
	flushRam(true);
	timeSynced.store(false, .release);
	if (dialAddress) |old| main.globalAllocator.free(old);
	dialAddress = main.globalAllocator.dupe(u8, ip);
	timingReset();
}

/// Live multiplayer session on the dialed server. Set on connect, cleared
/// on disconnect; keeps stale dial state from serving singleplayer.
var sessionLive: std.atomic.Value(bool) = .init(false);

/// First server `.time` received. The client renders noon until the clock
/// syncs, so the reveal gate waits for this (vanilla-safe: the packet is
/// stock, only the wait is ours). Reset on dial/disconnect, NOT on
/// sessionStart — the join-time packet can arrive during the handshake.
var timeSynced: std.atomic.Value(bool) = .init(false);

pub fn noteTimeSynced() void {
	timeSynced.store(true, .release);
}

pub fn isTimeSynced() bool {
	return timeSynced.load(.acquire);
}

pub fn sessionStart() void {
	lastFlushMs.store(main.timestamp().toMilliseconds(), .release);
	readClear();
	missClear();
	batchRegionClear();
	firstServeDone = false;
	firstServeMs = 0;
	prefetchGen +%= 1;
	prefetchKicked.store(false, .release);
	prefetchDoneFlag.store(false, .release);
	sessionLive.store(true, .release);
}

pub fn sessionEnd() void {
	flushRam(true);
	sessionLive.store(false, .release);
	timeSynced.store(false, .release);
	prefetchGen +%= 1;
	readClear();
	missClear();
}

/// Master toggle on, live session, and dialed address matches Ashframe.
pub fn isActive() bool {
	if (!main.settings.launchConfig.ashframeCache) return false;
	if (!sessionLive.load(.acquire)) return false;
	const dial = dialAddress orelse return false;
	const want = main.settings.launchConfig.ashframeServer;
	if (want.len == 0) return false;
	return std.mem.indexOf(u8, dial, want) != null;
}

/// Filesystem-safe per-server key derived from the dial address.
fn serverKey(buf: *[256]u8) []const u8 {
	const dial = dialAddress orelse return "unknown";
	var len: usize = 0;
	for (dial) |ch| {
		if (len >= buf.len) break;
		const c = std.ascii.toLower(ch);
		buf[len] = if (std.ascii.isAlphanumeric(c)) c else '_';
		len += 1;
	}
	if (len == 0) {
		buf[0] = 'u';
		return buf[0..1];
	}
	return buf[0..len];
}

fn cacheDir(buf: *[256]u8) []const u8 {
	var keyBuf: [256]u8 = undefined;
	const key = serverKey(&keyBuf);
	return std.fmt.bufPrint(buf, "ashframeCache/{s}", .{key}) catch "ashframeCache/unknown";
}

fn packHash(data: []const u8) u64 {
	return std.hash.Wyhash.hash(0, data);
}

/// Cached pack hash to announce at handshake, or null when there is nothing
/// usable to announce (feature off, no cache, TTL expired, version changed).
/// The server replies with an empty marker instead of the pack on a match;
/// otherwise it sends the full pack exactly as before.
/// Single read of the cache meta file; missing/corrupt file -> all null/false.
const Meta = struct {
	ts: ?i64 = null,
	versionMatches: bool = false,
	formatMatches: bool = false,
	packHash: ?u64 = null,
};

fn readMeta(dir: main.files.Dir) Meta {
	var out = Meta{};
	const zon = dir.readToZon(main.stackAllocator, metaFile) catch return out;
	defer zon.deinit(main.stackAllocator);
	out.ts = zon.get(i64, "flushedAtMs");
	if (zon.get([]const u8, "clientVersion")) |v| {
		out.versionMatches = std.mem.eql(u8, v, main.settings.version.version);
	}
	if (zon.get(i64, "formatVersion")) |f| {
		out.formatMatches = f == cacheFormatVersion;
	}
	if (zon.get(i64, "packHash")) |h| out.packHash = @bitCast(h);
	return out;
}

fn cacheTtlMs() i64 {
	return @as(i64, @intCast(main.settings.launchConfig.ashframeCacheTTLHours))*60*60*1000;
}

/// Argon capability version announced at handshake (userData ZON).
/// Vanilla servers ignore unknown fields. Bump when adding gated features
/// the server must know about (icons=1, large sign=1).
pub const clientVersion: u16 = 1;

pub fn announcedPackHash() ?u64 {
	if (!isActive()) return null;
	var dirBuf: [256]u8 = undefined;
	const dirPath = cacheDir(&dirBuf);
	var dir = main.files.cubyzDir().openDir(dirPath) catch return null;
	defer dir.close();
	const meta = readMeta(dir);
	if (!meta.versionMatches) return null;
	const ts = meta.ts orelse return null;
	const ttl = cacheTtlMs();
	if (ttl > 0 and main.timestamp().toMilliseconds() -% ts > ttl) return null;
	return meta.packHash;
}

const metaFile = "cache.zon";

fn writeMeta(dir: main.files.Dir, packHashValue: ?u64) void {
	const zon = main.ZonElement.initObject(main.stackAllocator);
	defer zon.deinit(main.stackAllocator);
	zon.put("flushedAtMs", main.timestamp().toMilliseconds());
	zon.put("clientVersion", main.settings.version.version);
	zon.put("formatVersion", @as(i64, cacheFormatVersion));
	if (packHashValue) |h| zon.put("packHash", @as(i64, @bitCast(h)));
	dir.writeZon(metaFile, zon) catch |err| {
		std.log.err("Ashframe cache: could not write meta: {s}", .{@errorName(err)});
	};
}

/// Wipes the per-server cache dir and records the new pack hash.
/// Returns an open handle to the fresh dir (caller closes), or null.
fn wipeCache(dirPath: []const u8, hash: u64) ?main.files.Dir {
	const cubyz = main.files.cubyzDir();
	ramClear();
	cubyz.deleteTree(dirPath) catch {};
	cubyz.makePath(dirPath) catch return null;
	const fresh = cubyz.openDir(dirPath) catch return null;
	writeMeta(fresh, hash);
	return fresh;
}

pub const PackStatus = enum { off, unchanged, changed };

/// `.unchanged` -> skip delete+unpack; `.changed`/`.off` -> unpack, then
/// call noteAssetsUnpacked(). Enforces TTL expiry and pack-change wipes.
pub fn checkAssetPack(packData: []const u8) PackStatus {
	if (!isActive()) return .off;
	var dirBuf: [256]u8 = undefined;
	const dirPath = cacheDir(&dirBuf);
	const cubyz = main.files.cubyzDir();
	cubyz.makePath(dirPath) catch |err| {
		std.log.err("Ashframe cache: could not create {s}: {s}", .{ dirPath, @errorName(err) });
		return .off;
	};
	var dir = cubyz.openDir(dirPath) catch return .off;
	defer dir.close();

	const h = packHash(packData);
	const nowMs = main.timestamp().toMilliseconds();
	const meta = readMeta(dir);
	if (meta.ts) |ts| {
		const ttl = cacheTtlMs();
		if (ttl > 0 and nowMs -% ts > ttl) {
			infoLog("cache: expired (older than {d}h), flushing.", .{main.settings.launchConfig.ashframeCacheTTLHours});
			var fresh = wipeCache(dirPath, h) orelse return .off;
			defer fresh.close();
			return .changed;
		}
	}
	if (!meta.versionMatches or !meta.formatMatches) {
		infoLog("cache: client version or format changed, flushing chunk cache.", .{});
		var fresh = wipeCache(dirPath, h) orelse return .off;
		defer fresh.close();
		return .changed;
	}
	if (meta.packHash) |old| {
		if (old == h) return .unchanged;
	}
	infoLog("cache: asset pack changed, flushing chunk cache.", .{});
	var fresh = wipeCache(dirPath, h) orelse return .off;
	defer fresh.close();
	return .changed;
}

pub fn noteAssetsUnpacked(packData: []const u8) void {
	if (!isActive()) return;
	var dirBuf: [256]u8 = undefined;
	const dirPath = cacheDir(&dirBuf);
	var dir = main.files.cubyzDir().openDir(dirPath) catch return;
	defer dir.close();
	writeMeta(dir, packHash(packData));
}

fn chunkFileName(pos: main.chunk.ChunkPosition, buf: *[128]u8) []const u8 {
	return std.fmt.bufPrint(buf, "c_{d}_{d}_{d}_{d}.bin", .{ pos.wx, pos.wy, pos.wz, pos.voxelSize }) catch "c_invalid.bin";
}

/// Unique temp per call: duplicate in-flight tasks for the same chunk would
/// otherwise collide on the shared fixed temp name and fail the rename.
threadlocal var writeSeq: u64 = 0;

fn writeAtomic(dir: main.files.Dir, name: []const u8, data: []const u8) !void {
	writeSeq +%= 1;
	const seq = writeSeq;
	var tmpBuf: [192]u8 = undefined;
	const tmp = std.fmt.bufPrint(&tmpBuf, "{s}.{d}.{d}.tmp", .{ name, main.timestamp().toNanoseconds(), seq }) catch return error.OutOfMemory;
	try dir.dir.writeFile(main.io, .{ .sub_path = tmp, .data = data });
	try dir.dir.rename(tmp, dir.dir, name, main.io);
}

// --- ASHFRAME CUSTOM CLIENT: region-bucketed cache (format v1). ---
// One-file-per-chunk wasted a 4KB block per ~390B blob. Chunks pack 4×4×4
// per region file (mirroring the server RegionFile layout), lightmaps 4×4:
//   [u32 version][u32 fileSize][N × u32 blobLen][blob bytes...]
// Corrupt region = miss (re-downloads, never crashes). Temp+rename keeps
// writes atomic. Old per-file caches lack formatVersion and wipe once.
const cacheFormatVersion: u32 = 1;
const chunkRegionSlots: usize = 64;
const lightRegionSlots: usize = 16;

fn readU32Le(b: []const u8) u32 {
	return std.mem.readInt(u32, b[0..4], .little);
}

fn writeU32Le(b: []u8, v: u32) void {
	std.mem.writeInt(u32, b[0..4], v, .little);
}

fn chunkSpan(vs: u31) i32 {
	return 128*@as(i32, @intCast(vs));
}

fn chunkRegionPath(wx: i32, wy: i32, wz: i32, vs: u31, buf: *[128]u8) ?[]const u8 {
	const s = chunkSpan(vs);
	return std.fmt.bufPrint(buf, "r_{d}_{d}_{d}_{d}.bin", .{ wx & ~(s - 1), wy & ~(s - 1), wz & ~(s - 1), vs }) catch null;
}

fn chunkRegionSlot(wx: i32, wy: i32, wz: i32, vs: u31) usize {
	const cs: i32 = 32*@as(i32, @intCast(vs));
	const s = chunkSpan(vs);
	const ix: usize = @intCast(@divTrunc(wx - (wx & ~(s - 1)), cs));
	const iy: usize = @intCast(@divTrunc(wy - (wy & ~(s - 1)), cs));
	const iz: usize = @intCast(@divTrunc(wz - (wz & ~(s - 1)), cs));
	return (ix*4 + iy)*4 + iz;
}

fn lightRegionPath(wx: i32, wy: i32, vs: u31, buf: *[128]u8) ?[]const u8 {
	const s: i32 = 1024*@as(i32, @intCast(vs));
	return std.fmt.bufPrint(buf, "lm_{d}_{d}_{d}.bin", .{ wx & ~(s - 1), wy & ~(s - 1), vs }) catch null;
}

fn lightRegionSlot(wx: i32, wy: i32, vs: u31) usize {
	const fs: i32 = 256*@as(i32, @intCast(vs));
	const bs: i32 = 4*fs;
	const ix: usize = @intCast(@divTrunc(wx - (wx & ~(bs - 1)), fs));
	const iy: usize = @intCast(@divTrunc(wy - (wy & ~(bs - 1)), fs));
	return ix*4 + iy;
}

const ParsedChunk = struct { wx: i32, wy: i32, wz: i32, vs: u31 };

fn validVs(vs: u31) bool {
	return vs != 0 and vs <= 32 and (vs & (vs - 1)) == 0;
}

fn parseChunkName(name: []const u8) ?ParsedChunk {
	var n = name;
	if (std.mem.endsWith(u8, n, ".bin")) n = n[0 .. n.len - 4] else return null;
	if (n.len < 3 or n[0] != 'c' or n[1] != '_') return null;
	var it = std.mem.splitScalar(u8, n[2..], '_');
	const a = it.next() orelse return null;
	const b = it.next() orelse return null;
	const c = it.next() orelse return null;
	const d = it.next() orelse return null;
	if (it.next() != null) return null;
	const vs = std.fmt.parseInt(u31, d, 10) catch return null;
	if (!validVs(vs)) return null;
	return .{
		.wx = std.fmt.parseInt(i32, a, 10) catch return null,
		.wy = std.fmt.parseInt(i32, b, 10) catch return null,
		.wz = std.fmt.parseInt(i32, c, 10) catch return null,
		.vs = vs,
	};
}

const ParsedLight = struct { wx: i32, wy: i32, vs: u31 };

fn parseLightName(name: []const u8) ?ParsedLight {
	var n = name;
	if (std.mem.endsWith(u8, n, ".bin")) n = n[0 .. n.len - 4] else return null;
	if (n.len < 3 or n[0] != 'm' or n[1] != '_') return null;
	var it = std.mem.splitScalar(u8, n[2..], '_');
	const a = it.next() orelse return null;
	const b = it.next() orelse return null;
	const c = it.next() orelse return null;
	if (it.next() != null) return null;
	const vs = std.fmt.parseInt(u31, c, 10) catch return null;
	if (!validVs(vs)) return null;
	return .{
		.wx = std.fmt.parseInt(i32, a, 10) catch return null,
		.wy = std.fmt.parseInt(i32, b, 10) catch return null,
		.vs = vs,
	};
}

/// Validates a region file; on success fills lens/blobs (borrowing `data`).
/// `n` is 64 (chunks) or 16 (lightmaps).
fn parseRegion(data: []const u8, n: usize, lens: *[64]u32, blobs: *[64][]const u8) bool {
	if (data.len < 8 + 4*n) return false;
	if (readU32Le(data[0..4]) != cacheFormatVersion) return false;
	const fileSize = readU32Le(data[4..8]);
	if (fileSize != data.len - 8 - 4*n) return false;
	var off: usize = 8 + 4*n;
	var sum: usize = 0;
	for (0..n) |i| {
		const l = readU32Le(data[8 + 4*i ..][0..4]);
		lens[i] = l;
		sum += l;
		if (off + l > data.len) return false;
		blobs[i] = data[off..][0..l];
		off += l;
	}
	if (sum != fileSize) return false;
	if (off != data.len) return false;
	return true;
}

/// Writes lens/blobs as a region file (atomic temp+rename). Deletes the file
/// when every slot is empty (saves inodes).
fn rewriteRegion(dir: main.files.Dir, path: []const u8, n: usize, lens: *[64]u32, blobs: *[64][]const u8) void {
	var allEmpty = true;
	for (lens[0..n]) |l| {
		if (l != 0) {
			allEmpty = false;
			break;
		}
	}
	if (allEmpty) {
		dir.deleteFile(path) catch {};
		return;
	}
	var total: usize = 8 + 4*n;
	for (lens[0..n]) |l| total += l;
	const buf = main.globalAllocator.alloc(u8, total);
	defer main.globalAllocator.free(buf);
	writeU32Le(buf[0..4], cacheFormatVersion);
	writeU32Le(buf[4..8], @intCast(total - 8 - 4*n));
	for (0..n) |i| writeU32Le(buf[8 + 4*i ..][0..4], lens[i]);
	var off: usize = 8 + 4*n;
	for (0..n) |i| {
		const l: usize = lens[i];
		@memcpy(buf[off..][0..l], blobs[i][0..l]);
		off += l;
	}
	writeAtomic(dir, path, buf) catch |err| {
		std.log.err("Ashframe cache: region store {s}: {s}", .{ path, @errorName(err) });
	};
}

/// Single-region accumulator: staged blobs sharing one region file are
/// merged with a single read-modify-write instead of one cycle per blob.
const RegionWriter = struct {
	dir: main.files.Dir,
	active: bool = false,
	n: usize = chunkRegionSlots,
	pathBuf: [128]u8 = undefined,
	pathLen: usize = 0,
	lens: [64]u32 = [_]u32{0} ** 64,
	blobs: [64][]const u8 = undefined,
	backing: ?[]u8 = null,

	fn path(self: *const RegionWriter) []const u8 {
		return self.pathBuf[0..self.pathLen];
	}

	fn flush(self: *RegionWriter) void {
		if (!self.active) return;
		self.active = false;
		rewriteRegion(self.dir, self.path(), self.n, &self.lens, &self.blobs);
		if (self.backing) |b| main.globalAllocator.free(b);
		self.backing = null;
	}

	fn switchTo(self: *RegionWriter, dir: main.files.Dir, chunkMode: bool, regionPath: []const u8) void {
		self.flush();
		self.dir = dir;
		self.n = if (chunkMode) chunkRegionSlots else lightRegionSlots;
		@memcpy(self.pathBuf[0..regionPath.len], regionPath);
		self.pathLen = regionPath.len;
		self.lens = [_]u32{0} ** 64;
		self.backing = null;
		const data = dir.read(main.globalAllocator, self.path()) catch {
			self.active = true;
			return;
		};
		var tmpLens: [64]u32 = undefined;
		var tmpBlobs: [64][]const u8 = undefined;
		if (parseRegion(data, self.n, &tmpLens, &tmpBlobs)) {
			self.lens = tmpLens;
			self.blobs = tmpBlobs;
			self.backing = data;
		} else {
			main.globalAllocator.free(data);
		}
		self.active = true;
	}

	fn put(self: *RegionWriter, slot: usize, data: []const u8) void {
		std.debug.assert(self.active);
		std.debug.assert(slot < self.n);
		self.lens[slot] = @intCast(data.len);
		self.blobs[slot] = data;
	}
};

/// One staged blob with its resolved region. Sorted by region before
/// writing so each region file pays exactly one read-modify-write per
/// flush instead of one per blob (hash iteration order is random).
const FlushWork = struct {
	kind: u8, // 1 chunk, 2 lightmap
	ox: i32,
	oy: i32,
	oz: i32,
	vs: u31,
	slot: usize,
	data: []const u8,

	fn lessThan(_: void, a: FlushWork, b: FlushWork) bool {
		if (a.kind != b.kind) return a.kind < b.kind;
		if (a.ox != b.ox) return a.ox < b.ox;
		if (a.oy != b.oy) return a.oy < b.oy;
		if (a.oz != b.oz) return a.oz < b.oz;
		if (a.vs != b.vs) return a.vs < b.vs;
		return a.slot < b.slot;
	}
};

/// Parses region bytes + extracts one slot (duped, caller-owned).
/// Null on miss/corruption (safe).
fn extractSlot(data: []const u8, n: usize, slot: usize) ?[]u8 {
	var lens: [64]u32 = undefined;
	var blobs: [64][]const u8 = undefined;
	if (!parseRegion(data, n, &lens, &blobs)) return null;
	if (slot >= n or lens[slot] == 0) return null;
	return main.globalAllocator.dupe(u8, blobs[slot]);
}

/// Reads one blob out of a region file. Null on miss/corruption (safe).
fn loadRegionSlot(dir: main.files.Dir, path: []const u8, n: usize, slot: usize) ?[]u8 {
	const data = dir.read(main.globalAllocator, path) catch return null;
	defer main.globalAllocator.free(data);
	return extractSlot(data, n, slot);
}

/// Per-serve-pass region-file cache: the first frame reads ~50k blobs out
/// of ~3k region files, so without this the same file is re-read dozens
/// of times per pass (one full read+parse per slot). Bounded; drop-all on
/// overflow stays correct. Cleared at every batch boundary.
const batchRegionCapEntries: usize = 2048;
const batchRegionCapBytes: usize = 64*1024*1024;
var batchRegionMutex: main.utils.Mutex = .{};
var batchRegions: std.StringHashMapUnmanaged([]u8) = .empty;
var batchRegionBytes: usize = 0;

fn batchRegionClearLocked() void {
	var it = batchRegions.iterator();
	while (it.next()) |kv| {
		main.globalAllocator.free(kv.key_ptr.*);
		main.globalAllocator.free(kv.value_ptr.*);
	}
	batchRegions.clearRetainingCapacity();
	batchRegionBytes = 0;
}

fn batchRegionSlot(d: main.files.Dir, regionPath: []const u8, n: usize, slot: usize) ?[]u8 {
	batchRegionMutex.lock();
	defer batchRegionMutex.unlock();
	if (batchRegions.get(regionPath)) |data| {
		return extractSlot(data, n, slot);
	}
	const data = d.read(main.globalAllocator, regionPath) catch return null;
	if (batchRegions.count() >= batchRegionCapEntries or batchRegionBytes + data.len > batchRegionCapBytes) {
		batchRegionClearLocked();
	}
	const key = main.globalAllocator.dupe(u8, regionPath);
	batchRegions.put(main.globalAllocator.allocator, key, data) catch {
		main.globalAllocator.free(key);
		defer main.globalAllocator.free(data);
		return extractSlot(data, n, slot);
	};
	batchRegionBytes += data.len;
	return extractSlot(data, n, slot);
}

fn batchRegionClear() void {
	batchRegionMutex.lock();
	defer batchRegionMutex.unlock();
	batchRegionClearLocked();
}

/// Zeros one slot; deletes the file when the region ends up empty.
fn clearRegionSlot(dir: main.files.Dir, path: []const u8, n: usize, slot: usize) void {
	const data = dir.read(main.globalAllocator, path) catch return;
	defer main.globalAllocator.free(data);
	var lens: [64]u32 = undefined;
	var blobs: [64][]const u8 = undefined;
	if (!parseRegion(data, n, &lens, &blobs)) return;
	if (slot >= n) return;
	lens[slot] = 0;
	rewriteRegion(dir, path, n, &lens, &blobs);
}

var flushMutex: main.utils.Mutex = .{};

/// On-disk per-server budget (bytes). Random eviction down to 4/5 of cap.
fn cacheMaxBytes() usize {
	return @as(usize, main.settings.launchConfig.ashframeCacheMaxMB)*1024*1024;
}

threadlocal var sweepCounter: u32 = 0;
var lastSweepMs: std.atomic.Value(i64) = .init(0);

/// Full directory scan + stat of every blob is expensive at 100k+ files, so
/// sweeps run at most once a minute on top of the store-count cadence.
fn maybeSweep(dirPath: []const u8) void {
	sweepCounter +%= 1;
	if (sweepCounter % 2048 != 0) return;
	const nowMs = main.timestamp().toMilliseconds();
	if (nowMs -% lastSweepMs.load(.monotonic) < 60*1000) return;
	lastSweepMs.store(nowMs, .monotonic);
	const cubyz = main.files.cubyzDir();
	var dir = cubyz.openDir(dirPath) catch return;
	defer dir.close();
	const Entry = struct { name: []u8, size: u64 };
	var entries: main.ListManaged(Entry) = .init(main.globalAllocator);
	defer {
		for (entries.items) |e| main.globalAllocator.free(e.name);
		entries.deinit();
	}
	var total: u64 = 0;
	var it = dir.iterate();
	while (true) {
		const entry = (it.next(main.io) catch break) orelse break;
		if (entry.kind != .file) continue;
		if (!std.mem.endsWith(u8, entry.name, ".bin")) continue;
		const st = dir.dir.statFile(main.io, entry.name, .{}) catch continue;
		const name = main.globalAllocator.dupe(u8, entry.name);
		entries.append(.{ .name = name, .size = st.size });
		total += st.size;
	}
	const cap = cacheMaxBytes();
	if (total <= cap) return;
	var rng: u64 = @as(u64, @intCast(main.timestamp().toNanoseconds())) | 0x9e3779b97f4a7c15;
	var over: u64 = total - cap*4/5;
	var i: usize = entries.items.len;
	while (i > 0 and over > 0) {
		rng ^= rng << 13;
		rng ^= rng >> 7;
		rng ^= rng << 17;
		const victim = rng % i;
		i -= 1;
		const tmp = entries.items[victim];
		entries.items[victim] = entries.items[i];
		entries.items[i] = tmp;
		over -= @min(over, tmp.size);
		dir.deleteFile(tmp.name) catch {};
	}
}

// --- ASHFRAME CUSTOM CLIENT: RAM write buffer. ---
// Received blobs stage here instead of hitting disk per chunk (thousands of
// temp+rename cycles per join otherwise). Flushed to disk at
// ashframeFlushMaxMB or every ashframeFlushIntervalMinutes, plus on
// (re)connect and disconnect. Crash/kill loses at most one interval, which
// just re-downloads; only complete flushes ever reach disk, so the on-disk
// cache is never torn.
var ramMap: std.StringHashMapUnmanaged([]u8) = .empty;
var ramBytes: usize = 0;
var ramMutex: main.utils.Mutex = .{};
// Written by sessionStart (main thread) and flushRam (workers): atomic.
var lastFlushMs: std.atomic.Value(i64) = .init(0);

fn flushMaxBytes() usize {
	return @as(usize, main.settings.launchConfig.ashframeFlushMaxMB)*1024*1024;
}

fn flushIntervalMs() i64 {
	return @as(i64, @intCast(main.settings.launchConfig.ashframeFlushIntervalMinutes))*60*1000;
}

fn ramPut(name: []const u8, data: []const u8) void {
	ramMutex.lock();
	defer ramMutex.unlock();
	const gpa = main.globalAllocator;
	if (ramMap.getPtr(name)) |slot| {
		ramBytes -= slot.*.len;
		gpa.free(slot.*);
		slot.* = gpa.dupe(u8, data);
		ramBytes += slot.*.len;
	} else {
		const key = gpa.dupe(u8, name);
		const val = gpa.dupe(u8, data);
		ramMap.put(gpa.allocator, key, val) catch {
			gpa.free(key);
			gpa.free(val);
			return;
		};
		ramBytes += val.len;
	}
}

fn ramGet(name: []const u8) ?[]u8 {
	ramMutex.lock();
	defer ramMutex.unlock();
	const blob = ramMap.get(name) orelse return null;
	return main.globalAllocator.dupe(u8, blob);
}

fn ramRemove(name: []const u8) void {
	ramMutex.lock();
	defer ramMutex.unlock();
	const kv = ramMap.fetchRemove(name) orelse return;
	ramBytes -= kv.value.len;
	main.globalAllocator.free(kv.key);
	main.globalAllocator.free(kv.value);
}

fn ramClear() void {
	ramMutex.lock();
	defer ramMutex.unlock();
	var it = ramMap.iterator();
	while (it.next()) |kv| {
		main.globalAllocator.free(kv.key_ptr.*);
		main.globalAllocator.free(kv.value_ptr.*);
	}
	ramMap.clearRetainingCapacity();
	ramBytes = 0;
}

/// In-RAM read cache: blobs served from here never touch disk. Populated
/// on every disk hit and every network store; cleared on session end and
/// warmed by prefetch on connect. Bounded (arbitrary eviction to 4/5 cap).
var readMutex: main.utils.Mutex = .{};
var readCache: std.StringHashMapUnmanaged([]u8) = .empty;
var readBytes: usize = 0;

fn readCapBytes() usize {
	return @as(usize, main.settings.launchConfig.ashframeReadCacheMB)*1024*1024;
}

fn readGet(name: []const u8) ?[]u8 {
	readMutex.lock();
	defer readMutex.unlock();
	const blob = readCache.get(name) orelse return null;
	return main.globalAllocator.dupe(u8, blob);
}

fn readPut(name: []const u8, data: []const u8) void {
	readMutex.lock();
	defer readMutex.unlock();
	const gpa = main.globalAllocator;
	if (readCache.getPtr(name)) |slot| {
		readBytes -= slot.*.len;
		gpa.free(slot.*);
		slot.* = gpa.dupe(u8, data);
		readBytes += slot.*.len;
	} else {
		const key = gpa.dupe(u8, name);
		const val = gpa.dupe(u8, data);
		readCache.put(gpa.allocator, key, val) catch {
			gpa.free(key);
			gpa.free(val);
			return;
		};
		readBytes += val.len;
	}
	// Arbitrary eviction down to 4/5 of cap (hash order ~ random).
	const cap = readCapBytes();
	if (cap == 0) {
		readClearLocked();
		return;
	}
	const target = cap*4/5;
	while (readBytes > target) {
		var it = readCache.iterator();
		const kv = it.next() orelse break;
		const gone = readCache.fetchRemove(kv.key_ptr.*) orelse break;
		readBytes -= gone.value.len;
		gpa.free(gone.key);
		gpa.free(gone.value);
	}
}

fn readRemove(name: []const u8) void {
	readMutex.lock();
	defer readMutex.unlock();
	const kv = readCache.fetchRemove(name) orelse return;
	readBytes -= kv.value.len;
	main.globalAllocator.free(kv.key);
	main.globalAllocator.free(kv.value);
}

fn readClearLocked() void {
	var it = readCache.iterator();
	while (it.next()) |kv| {
		main.globalAllocator.free(kv.key_ptr.*);
		main.globalAllocator.free(kv.value_ptr.*);
	}
	readCache.clearRetainingCapacity();
	readBytes = 0;
}

fn readClear() void {
	readMutex.lock();
	defer readMutex.unlock();
	readClearLocked();
}

/// Negative disk-miss cache: names that missed on disk are not re-read
/// for missTtlMs. The first serve pass issues tens of thousands of reads
/// for chunks that simply aren't cached; without this every frame repeats
/// them. Stores and invalidations clear the entry (data may exist now).
const missTtlMs: i64 = 5000;
const missCap: usize = 8192;
var missMutex: main.utils.Mutex = .{};
var missCache: std.StringHashMapUnmanaged(i64) = .empty;

fn missCheck(name: []const u8, nowMs: i64) bool {
	missMutex.lock();
	defer missMutex.unlock();
	const ts = missCache.get(name) orelse return false;
	return nowMs -% ts < missTtlMs;
}

fn missPut(name: []const u8, nowMs: i64) void {
	missMutex.lock();
	defer missMutex.unlock();
	const gpa = main.globalAllocator;
	if (missCache.getPtr(name)) |slot| {
		slot.* = nowMs;
		return;
	}
	const key = gpa.dupe(u8, name);
	missCache.put(gpa.allocator, key, nowMs) catch {
		gpa.free(key);
		return;
	};
	while (missCache.count() > missCap) {
		var it = missCache.iterator();
		const kv = it.next() orelse break;
		const gone = missCache.fetchRemove(kv.key_ptr.*) orelse break;
		gpa.free(gone.key);
	}
}

fn missClearEntry(name: []const u8) void {
	missMutex.lock();
	defer missMutex.unlock();
	const kv = missCache.fetchRemove(name) orelse return;
	main.globalAllocator.free(kv.key);
}

fn missClear() void {
	missMutex.lock();
	defer missMutex.unlock();
	var it = missCache.iterator();
	while (it.next()) |kv| main.globalAllocator.free(kv.key_ptr.*);
	missCache.clearRetainingCapacity();
}

/// Writes everything staged to disk (dir of the session that buffered it;
/// callers order this before any dial-address switch). No-op when empty.
fn flushRam(force: bool) void {
	const nowMs = main.timestamp().toMilliseconds();
	ramMutex.lock();
	if (ramMap.count() == 0) {
		ramMutex.unlock();
		return;
	}
	const interval = flushIntervalMs();
	if (!force and ramBytes < flushMaxBytes() and (interval <= 0 or nowMs -% lastFlushMs.load(.acquire) < interval)) {
		ramMutex.unlock();
		return;
	}
	var batch = ramMap;
	ramMap = .empty;
	ramBytes = 0;
	lastFlushMs.store(nowMs, .release);
	ramMutex.unlock();
	defer batch.deinit(main.globalAllocator.allocator);
	var dirBuf: [256]u8 = undefined;
	const dirPath = cacheDir(&dirBuf);
	const cubyz = main.files.cubyzDir();
	flushMutex.lock();
	defer flushMutex.unlock();
	var flushIt = batch.iterator();
	const dirOpt: ?main.files.Dir = blk: {
		cubyz.makePath(dirPath) catch break :blk null;
		break :blk cubyz.openDir(dirPath) catch null;
	};
	if (dirOpt) |dir| {
		var d = dir;
		defer d.close();
		// Group by region first: hash iteration order is random, and without
		// sorting every blob would trigger its own read-modify-write cycle.
		var work: main.ListManaged(FlushWork) = .init(main.globalAllocator);
		defer work.deinit();
		while (flushIt.next()) |kv| {
			const key = kv.key_ptr.*;
			const val = kv.value_ptr.*;
			if (parseChunkName(key)) |pc| {
				const s = chunkSpan(pc.vs);
				work.append(.{
					.kind = 1,
					.ox = pc.wx & ~(s - 1),
					.oy = pc.wy & ~(s - 1),
					.oz = pc.wz & ~(s - 1),
					.vs = pc.vs,
					.slot = chunkRegionSlot(pc.wx, pc.wy, pc.wz, pc.vs),
					.data = val,
				});
			} else if (parseLightName(key)) |pl| {
				const bs: i32 = 1024*@as(i32, @intCast(pl.vs));
				work.append(.{
					.kind = 2,
					.ox = pl.wx & ~(bs - 1),
					.oy = pl.wy & ~(bs - 1),
					.oz = 0,
					.vs = pl.vs,
					.slot = lightRegionSlot(pl.wx, pl.wy, pl.vs),
					.data = val,
				});
			}
			// NOTE: keys/values are freed in the loop below, AFTER rw.flush().
			// The RegionWriter only borrows these slices.
		}
		std.mem.sort(FlushWork, work.items, {}, FlushWork.lessThan);
		var rw: RegionWriter = .{ .dir = d };
		var i: usize = 0;
		while (i < work.items.len) {
			const w0 = work.items[i];
			var pathBuf: [128]u8 = undefined;
			const path: ?[]const u8 = if (w0.kind == 1)
				chunkRegionPath(w0.ox, w0.oy, w0.oz, w0.vs, &pathBuf)
			else
				lightRegionPath(w0.ox, w0.oy, w0.vs, &pathBuf);
			const p = path orelse {
				i += 1;
				continue;
			};
			rw.switchTo(d, w0.kind == 1, p);
			while (i < work.items.len) {
				const w = work.items[i];
				if (w.kind != w0.kind or w.ox != w0.ox or w.oy != w0.oy or w.oz != w0.oz or w.vs != w0.vs) break;
				rw.put(w.slot, w.data);
				i += 1;
			}
		}
		rw.flush();
		var freeIt = batch.iterator();
		while (freeIt.next()) |kv| {
			main.globalAllocator.free(kv.key_ptr.*);
			main.globalAllocator.free(kv.value_ptr.*);
		}
		maybeSweep(dirPath);
	} else {
		std.log.err("Ashframe cache: flush failed, dropping {d} staged blobs (re-downloaded later)", .{batch.count()});
		while (flushIt.next()) |kv| {
			main.globalAllocator.free(kv.key_ptr.*);
			main.globalAllocator.free(kv.value_ptr.*);
		}
	}
}

/// Stages a received blob in RAM; flushed by size/interval/disconnect.
fn stageBlob(name: []const u8, data: []const u8) void {
	ramPut(name, data);
	flushRam(false);
}

/// Per-frame serve batch: one dir handle for the render-thread serve pass
/// (updateAndGetRenderChunks) instead of open+close per blob. Render thread
/// only; workers never touch loadBlob.
var batchDir: ?main.files.Dir = null;
var batchBlobs: u32 = 0;
var batchT0: std.Io.Timestamp = undefined;
/// Negative-miss skips since the last serve log (diagnostic only).
var missSkips: std.atomic.Value(u64) = .init(0);

/// First-serve signal for the reveal gate: set by endServeBatch once a
/// real serve pass ran (so the gate waits for the actual work, not just
/// the prefetch). Reset each session; render thread only.
var firstServeDone: bool = false;
var firstServeMs: i64 = 0;
/// Grace after the first serve pass for workers to land lightmap
/// fragments + rebuild deferred meshes before the world reveals.
pub const litGraceMs: i64 = 500;

pub fn firstServeReady(nowMs: i64) bool {
	if (!firstServeDone) return false;
	return nowMs -% firstServeMs >= litGraceMs;
}

pub fn beginServeBatch() void {
	if (batchDir != null) return;
	if (!isActive()) return;
	var dirBuf: [256]u8 = undefined;
	const dirPath = cacheDir(&dirBuf);
	batchDir = main.files.cubyzDir().openDir(dirPath) catch return;
	batchBlobs = 0;
	batchT0 = main.timestamp();
}

pub fn endServeBatch() void {
	if (batchDir) |*d| {
		d.close();
		batchDir = null;
	} else return;
	batchRegionClear();
	if (!firstServeDone) {
		firstServeDone = true;
		firstServeMs = main.timestamp().toMilliseconds();
	}
	if (batchBlobs >= 50) {
		const us: i64 = @intCast(@divTrunc(batchT0.durationTo(main.timestamp()).nanoseconds, 1000));
		infoLog("serve: {d} blobs ({d} miss-skips) in {d}us", .{ batchBlobs, missSkips.swap(0, .acquire), us });
	}
}

/// Loads one blob out of a region file (RAM has its own per-blob check
/// upstream). In-batch serves share one dir handle plus the per-pass
/// region cache; outside a batch it's open+close. Caller owns the memory.
fn loadRegionBlob(dirPath: []const u8, regionPath: []const u8, n: usize, slot: usize) ?[]u8 {
	if (batchDir) |d| {
		batchBlobs += 1;
		return batchRegionSlot(d, regionPath, n, slot);
	}
	var dir = main.files.cubyzDir().openDir(dirPath) catch return null;
	defer dir.close();
	return loadRegionSlot(dir, regionPath, n, slot);
}

/// Stages a received chunk blob in RAM; flushed by size/interval/disconnect.
/// Single RAM copy: loads check the write buffer first, so no readCache
/// duplicate is needed until flush evicts it (next load re-caches it).
pub fn storeChunk(pos: main.chunk.ChunkPosition, data: []const u8) void {
	if (!isActive()) return;
	var nameBuf: [128]u8 = undefined;
	const name = chunkFileName(pos, &nameBuf);
	stageBlob(name, data);
	missClearEntry(name);
}

/// Loads a cached chunk blob (write buffer, read cache, then its region
/// file slice), or null on miss. Recent disk misses skip the re-read.
/// Caller owns the memory.
pub fn loadChunk(pos: main.chunk.ChunkPosition) ?[]u8 {
	if (!isActive()) return null;
	var nameBuf: [128]u8 = undefined;
	const name = chunkFileName(pos, &nameBuf);
	if (ramGet(name)) |blob| return blob;
	if (readGet(name)) |blob| return blob;
	const nowMs = main.timestamp().toMilliseconds();
	if (missCheck(name, nowMs)) {
		_ = missSkips.fetchAdd(1, .monotonic);
		return null;
	}
	var dirBuf: [256]u8 = undefined;
	const dirPath = cacheDir(&dirBuf);
	var pathBuf: [128]u8 = undefined;
	const path = chunkRegionPath(pos.wx, pos.wy, pos.wz, pos.voxelSize, &pathBuf) orelse return null;
	if (loadRegionBlob(dirPath, path, chunkRegionSlots, chunkRegionSlot(pos.wx, pos.wy, pos.wz, pos.voxelSize))) |blob| {
		readPut(name, blob);
		return blob;
	}
	missPut(name, nowMs);
	return null;
}

/// Drops cached blobs for a live-edited block (RAM + region slots, all LODs
/// + lightmap). Region files surviving empty are deleted to save inodes.
pub fn invalidateChunk(wx: i32, wy: i32, wz: i32) void {
	if (!isActive()) return;
	var dirBuf: [256]u8 = undefined;
	const dirPath = cacheDir(&dirBuf);
	var dir = main.files.cubyzDir().openDir(dirPath) catch return;
	defer dir.close();
	flushMutex.lock();
	defer flushMutex.unlock();
	for ([_]u31{ 1, 2, 4, 8, 16, 32 }) |vs| {
		const size: i32 = 32*@as(i32, @intCast(vs));
		const mask: i32 = size - 1;
		const cx = wx & ~mask;
		const cy = wy & ~mask;
		const cz = wz & ~mask;
		var nameBuf: [128]u8 = undefined;
		const name = chunkFileName(.{ .wx = cx, .wy = cy, .wz = cz, .voxelSize = vs }, &nameBuf);
		ramRemove(name);
		readRemove(name);
		missClearEntry(name);
		var pathBuf: [128]u8 = undefined;
		const path = chunkRegionPath(cx, cy, cz, vs, &pathBuf) orelse continue;
		clearRegionSlot(dir, path, chunkRegionSlots, chunkRegionSlot(cx, cy, cz, vs));
		invalidateLightMapIn(dir, wx, wy, vs);
	}
}

fn lightMapFileName(wx: i32, wy: i32, vs: u31, buf: *[128]u8) []const u8 {
	return std.fmt.bufPrint(buf, "m_{d}_{d}_{d}.bin", .{ wx, wy, vs }) catch "m_invalid.bin";
}

/// Stages a received lightmap fragment blob. Same contract as storeChunk.
pub fn storeLightMap(wx: i32, wy: i32, vs: u31, data: []const u8) void {
	if (!isActive()) return;
	var nameBuf: [128]u8 = undefined;
	const name = lightMapFileName(wx, wy, vs, &nameBuf);
	stageBlob(name, data);
	missClearEntry(name);
}

/// Loads a cached lightmap fragment (write buffer, read cache, then its
/// region slice), or null on miss. Recent disk misses skip the re-read.
/// Caller owns the memory.
pub fn loadLightMap(wx: i32, wy: i32, vs: u31) ?[]u8 {
	if (!isActive()) return null;
	var nameBuf: [128]u8 = undefined;
	const name = lightMapFileName(wx, wy, vs, &nameBuf);
	if (ramGet(name)) |blob| return blob;
	if (readGet(name)) |blob| return blob;
	const nowMs = main.timestamp().toMilliseconds();
	if (missCheck(name, nowMs)) {
		_ = missSkips.fetchAdd(1, .monotonic);
		return null;
	}
	var dirBuf: [256]u8 = undefined;
	const dirPath = cacheDir(&dirBuf);
	var pathBuf: [128]u8 = undefined;
	const path = lightRegionPath(wx, wy, vs, &pathBuf) orelse return null;
	if (loadRegionBlob(dirPath, path, lightRegionSlots, lightRegionSlot(wx, wy, vs))) |blob| {
		readPut(name, blob);
		return blob;
	}
	missPut(name, nowMs);
	return null;
}

/// Deletes the cached lightmap fragment covering column (x, y).
fn invalidateLightMapIn(dir: main.files.Dir, x: i32, y: i32, vs: u31) void {
	const span: i32 = 256*@as(i32, @intCast(vs));
	const mask: i32 = span - 1;
	const fx = x & ~mask;
	const fy = y & ~mask;
	var nameBuf: [128]u8 = undefined;
	const lmName = lightMapFileName(fx, fy, vs, &nameBuf);
	ramRemove(lmName);
	readRemove(lmName);
	missClearEntry(lmName);
	var pathBuf: [128]u8 = undefined;
	const path = lightRegionPath(fx, fy, vs, &pathBuf) orelse return;
	clearRegionSlot(dir, path, lightRegionSlots, lightRegionSlot(fx, fy, vs));
}

/// Connect-time prefetch: warms the read cache on a worker so the world
/// reveals already lit. Kicked once per session by the first teleport
/// (spawn position); the reveal gate waits for completion or warmCapMs.
pub const warmCapMs: i64 = 3000;
var prefetchKicked: std.atomic.Value(bool) = .init(false);
var prefetchDoneFlag: std.atomic.Value(bool) = .init(true);
var prefetchGen: u64 = 0;

pub fn isWarmupDone() bool {
	return prefetchDoneFlag.load(.acquire);
}

/// Starts the connect prefetch once per session. Call after sessionStart
/// with the spawn position. No-op when inactive or already kicked.
pub fn kickPrefetch(px: i32, py: i32, pz: i32) void {
	if (!isActive()) return;
	if (prefetchKicked.swap(true, .acq_rel)) return;
	prefetchDoneFlag.store(false, .release);
	const task = main.globalAllocator.create(PrefetchTask);
	task.* = .{ .px = px, .py = py, .pz = pz, .gen = prefetchGen };
	main.threadPool.addTask(task, &PrefetchTask.vtable);
}

/// Called from the teleport handler (network thread). Fallback trigger —
/// the primary kick happens in .connected once the spawn is parsed.
pub fn noteTeleport(px: i32, py: i32, pz: i32) void {
	kickPrefetch(px, py, pz);
}

const PrefetchTask = struct {
	px: i32,
	py: i32,
	pz: i32,
	gen: u64,

	pub const vtable = main.utils.ThreadPool.VTable{
		.getPriority = main.meta.castFunctionSelfToAnyopaque(getPriority),
		.isStillNeeded = main.meta.castFunctionSelfToAnyopaque(isStillNeeded),
		.run = main.meta.castFunctionSelfToAnyopaque(run),
		.clean = main.meta.castFunctionSelfToAnyopaque(clean),
		.taskType = .misc,
	};

	pub fn getPriority(_: *PrefetchTask) f32 {
		return std.math.floatMax(f32);
	}

	pub fn isStillNeeded(self: *PrefetchTask) bool {
		return sessionLive.load(.acquire) and self.gen == prefetchGen;
	}

	fn warmChunk(pos: main.chunk.ChunkPosition) void {
		if (loadChunk(pos)) |b| main.globalAllocator.free(b);
	}

	fn warmLightMap(wx: i32, wy: i32, vs: u31) void {
		if (loadLightMap(wx, wy, vs)) |b| main.globalAllocator.free(b);
	}

	pub fn run(self: *PrefetchTask) void {
		defer self.clean();
		// NOTE: done is stored only after genuine work below. A stale or
		// culled task must NOT release the reveal gate (early `defer` here
		// used to do exactly that on reconnects).
		if (!self.isStillNeeded()) return;
		var chunks: u32 = 0;
		var frags: u32 = 0;
		const t0 = main.timestamp().toMilliseconds();
		// Near chunks: +-192 blocks each axis, every LOD. Coarse LODs
		// (vs>=8, what the far field actually renders) get +-768: only
		// ~250 extra positions, warms far geometry nearly free.
		for (0..@as(usize, main.settings.highestLod) + 1) |_lod| {
			const lod: u5 = @intCast(_lod);
			const vs: u31 = @as(u31, 1) << lod;
			const half: i32 = if (vs >= 8) 768 else 192;
			const cs: i32 = 32*@as(i32, @intCast(vs));
			var x = (self.px - half) & ~(cs - 1);
			const maxX = (self.px + half) & ~(cs - 1);
			while (x <= maxX) : (x += cs) {
				var y = (self.py - half) & ~(cs - 1);
				const maxY = (self.py + half) & ~(cs - 1);
				while (y <= maxY) : (y += cs) {
					var z = (self.pz - half) & ~(cs - 1);
					const maxZ = (self.pz + half) & ~(cs - 1);
					while (z <= maxZ) : (z += cs) {
						if (!self.isStillNeeded()) return;
						warmChunk(.{ .wx = x, .wy = y, .wz = z, .voxelSize = vs });
						chunks += 1;
					}
				}
			}
		}
		// All visible map fragments (few files, cheap).
		const rd: i32 = main.settings.renderDistance;
		for (0..@as(usize, main.settings.highestLod) + 1) |_lod| {
			const lod: u5 = @intCast(_lod);
			const vs: u31 = @as(u31, 1) << lod;
			const frag: i32 = 256*@as(i32, @intCast(vs));
			const ext: i32 = rd*32*@as(i32, @intCast(vs));
			var fx = (self.px - ext) & ~(frag - 1);
			const maxFx = (self.px + ext) & ~(frag - 1);
			while (fx <= maxFx) : (fx += frag) {
				var fy = (self.py - ext) & ~(frag - 1);
				const maxFy = (self.py + ext) & ~(frag - 1);
				while (fy <= maxFy) : (fy += frag) {
					if (!self.isStillNeeded()) return;
					warmLightMap(fx, fy, vs);
					frags += 1;
				}
			}
		}
		infoLog("prefetch: {d} chunks + {d} frags in {d}ms", .{ chunks, frags, main.timestamp().toMilliseconds() - t0 });
		prefetchDoneFlag.store(true, .release);
	}

	pub fn clean(self: *PrefetchTask) void {
		main.globalAllocator.destroy(self);
	}
};

test "ashframe region math" {
	// Chunk region origin/slot, including negatives (two's complement mask).
	var buf: [128]u8 = undefined;
	try std.testing.expectEqualStrings("r_0_0_0_1.bin", chunkRegionPath(0, 0, 0, 1, &buf).?);
	try std.testing.expectEqualStrings("r_-128_-128_-128_1.bin", chunkRegionPath(-1, -1, -1, 1, &buf).?);
	try std.testing.expectEqual(@as(usize, 0), chunkRegionSlot(0, 0, 0, 1));
	try std.testing.expectEqual(@as(usize, 63), chunkRegionSlot(-1, -1, -1, 1));
	try std.testing.expectEqual(@as(usize, 0), chunkRegionSlot(128, 0, 0, 1));
	// Lightmap region origin/slot.
	try std.testing.expectEqualStrings("lm_0_0_1.bin", lightRegionPath(0, 0, 1, &buf).?);
	try std.testing.expectEqualStrings("lm_-1024_-1024_1.bin", lightRegionPath(-1, -1, 1, &buf).?);
	try std.testing.expectEqual(@as(usize, 0), lightRegionSlot(0, 0, 1));
	try std.testing.expectEqual(@as(usize, 15), lightRegionSlot(-1, -1, 1));
	// Name round-trip + rejection.
	const pc = parseChunkName("c_-64_128_-32_2.bin").?;
	try std.testing.expectEqual(@as(i32, -64), pc.wx);
	try std.testing.expectEqual(@as(i32, 128), pc.wy);
	try std.testing.expectEqual(@as(i32, -32), pc.wz);
	try std.testing.expectEqual(@as(u31, 2), pc.vs);
	try std.testing.expect(parseChunkName("c_1_2_3.bin") == null);
	try std.testing.expect(parseChunkName("x_1_2_3_1.bin") == null);
	try std.testing.expect(parseChunkName("c_1_2_3_7.bin") == null);
	const pl = parseLightName("m_-256_512_4.bin").?;
	try std.testing.expectEqual(@as(i32, -256), pl.wx);
	try std.testing.expectEqual(@as(u31, 4), pl.vs);
	try std.testing.expect(parseLightName("m_1_2.bin") == null);
	// Format parse on a hand-built region (no allocator needed).
	var raw: [8 + 4*4 + 6]u8 = undefined;
	writeU32Le(raw[0..4], cacheFormatVersion);
	writeU32Le(raw[4..8], 6);
	writeU32Le(raw[8..12], 0);
	writeU32Le(raw[12..16], 3);
	writeU32Le(raw[16..20], 0);
	writeU32Le(raw[20..24], 3);
	@memcpy(raw[24..27], "abc");
	@memcpy(raw[27..30], "def");
	var lens: [64]u32 = undefined;
	var blobs: [64][]const u8 = undefined;
	try std.testing.expect(parseRegion(&raw, 4, &lens, &blobs));
	try std.testing.expectEqual(@as(u32, 3), lens[1]);
	try std.testing.expectEqualStrings("abc", blobs[1]);
	try std.testing.expectEqualStrings("def", blobs[3]);
	try std.testing.expectEqual(@as(u32, 0), lens[0]);
	// Corrupt version / truncated size must fail closed (miss, never crash).
	raw[0] ^= 0xff;
	try std.testing.expect(!parseRegion(&raw, 4, &lens, &blobs));
}
// --- ASHFRAME CUSTOM CLIENT ---
