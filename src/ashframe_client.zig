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

pub fn timingReset() void {
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
	if (dialAddress) |old| main.globalAllocator.free(old);
	dialAddress = main.globalAllocator.dupe(u8, ip);
	timingReset();
}

/// Live multiplayer session on the dialed server. Set on connect, cleared
/// on disconnect; keeps stale dial state from serving singleplayer.
pub var sessionLive: std.atomic.Value(bool) = .init(false);

pub fn sessionStart() void {
	lastFlushMs = main.timestamp().toMilliseconds();
	sessionLive.store(true, .release);
}

pub fn sessionEnd() void {
	flushRam(true);
	sessionLive.store(false, .release);
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

pub fn packHash(data: []const u8) u64 {
	return std.hash.Wyhash.hash(0, data);
}

/// Cached pack hash to announce at handshake, or null when there is nothing
/// usable to announce (feature off, no cache, TTL expired, version changed).
/// The server replies with an empty marker instead of the pack on a match;
/// otherwise it sends the full pack exactly as before.
pub fn announcedPackHash() ?u64 {
	if (!isActive()) return null;
	var dirBuf: [256]u8 = undefined;
	const dirPath = cacheDir(&dirBuf);
	var dir = main.files.cubyzDir().openDir(dirPath) catch return null;
	defer dir.close();
	const zon = dir.readToZon(main.stackAllocator, metaFile) catch return null;
	defer zon.deinit(main.stackAllocator);
	const oldVer = zon.get([]const u8, "clientVersion") orelse return null;
	if (!std.mem.eql(u8, oldVer, main.settings.version.version)) return null;
	const ts = zon.get(i64, "flushedAtMs") orelse return null;
	const ttlMs: i64 = @as(i64, @intCast(main.settings.launchConfig.ashframeCacheTTLHours))*60*60*1000;
	if (ttlMs > 0 and main.timestamp().toMilliseconds() -% ts > ttlMs) return null;
	const h = zon.get(i64, "packHash") orelse return null;
	return @bitCast(h);
}

const metaFile = "cache.zon";

fn readMetaTs(dir: main.files.Dir) ?i64 {
	const zon = dir.readToZon(main.stackAllocator, metaFile) catch return null;
	defer zon.deinit(main.stackAllocator);
	const ts = zon.get(i64, "flushedAtMs") orelse return null;
	return ts;
}

fn writeMeta(dir: main.files.Dir, packHashValue: ?u64) void {
	const zon = main.ZonElement.initObject(main.stackAllocator);
	defer zon.deinit(main.stackAllocator);
	zon.put("flushedAtMs", main.timestamp().toMilliseconds());
	zon.put("clientVersion", main.settings.version.version);
	if (packHashValue) |h| zon.put("packHash", @as(i64, @bitCast(h)));
	dir.writeZon(metaFile, zon) catch |err| {
		std.log.err("Ashframe cache: could not write meta: {s}", .{@errorName(err)});
	};
}

/// Meta from another client build -> treat as changed (wipe).
fn clientVersionMismatch(dir: main.files.Dir) bool {
	const zon = dir.readToZon(main.stackAllocator, metaFile) catch return false;
	defer zon.deinit(main.stackAllocator);
	const old = zon.get([]const u8, "clientVersion") orelse return false;
	return !std.mem.eql(u8, old, main.settings.version.version);
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
	const ttlMs: i64 = @as(i64, @intCast(main.settings.launchConfig.ashframeCacheTTLHours))*60*60*1000;
	if (readMetaTs(dir)) |ts| {
		if (ttlMs > 0 and nowMs -% ts > ttlMs) {
			infoLog("cache: expired (older than {d}h), flushing.", .{main.settings.launchConfig.ashframeCacheTTLHours});
			ramClear();
			cubyz.deleteTree(dirPath) catch {};
			cubyz.makePath(dirPath) catch return .off;
			var fresh = cubyz.openDir(dirPath) catch return .off;
			defer fresh.close();
			writeMeta(fresh, h);
			return .changed;
		}
	}
	if (clientVersionMismatch(dir)) {
		infoLog("cache: client version changed, flushing chunk cache.", .{});
		ramClear();
		cubyz.deleteTree(dirPath) catch {};
		cubyz.makePath(dirPath) catch return .off;
		var fresh = cubyz.openDir(dirPath) catch return .off;
		defer fresh.close();
		writeMeta(fresh, h);
		return .changed;
	}
	const zon = dir.readToZon(main.stackAllocator, metaFile) catch null;
	if (zon) |z| {
		defer z.deinit(main.stackAllocator);
		const old = z.get(i64, "packHash");
		if (old != null and old.? == @as(i64, @bitCast(h))) return .unchanged;
	}
	infoLog("cache: asset pack changed, flushing chunk cache.", .{});
	ramClear();
	cubyz.deleteTree(dirPath) catch {};
	cubyz.makePath(dirPath) catch return .off;
	var fresh = cubyz.openDir(dirPath) catch return .off;
	defer fresh.close();
	writeMeta(fresh, h);
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
var lastFlushMs: i64 = 0;

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

pub fn ramClear() void {
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

/// Writes everything staged to disk (dir of the session that buffered it;
/// callers order this before any dial-address switch). No-op when empty.
pub fn flushRam(force: bool) void {
	const nowMs = main.timestamp().toMilliseconds();
	ramMutex.lock();
	if (ramMap.count() == 0) {
		ramMutex.unlock();
		return;
	}
	const interval = flushIntervalMs();
	if (!force and ramBytes < flushMaxBytes() and (interval <= 0 or nowMs -% lastFlushMs < interval)) {
		ramMutex.unlock();
		return;
	}
	var batch = ramMap;
	ramMap = .empty;
	ramBytes = 0;
	lastFlushMs = nowMs;
	ramMutex.unlock();
	defer batch.deinit(main.globalAllocator.allocator);
	var dirBuf: [256]u8 = undefined;
	const dirPath = cacheDir(&dirBuf);
	const cubyz = main.files.cubyzDir();
	var flushIt = batch.iterator();
	const dirOpt: ?main.files.Dir = blk: {
		cubyz.makePath(dirPath) catch break :blk null;
		break :blk cubyz.openDir(dirPath) catch null;
	};
	if (dirOpt) |dir| {
		var d = dir;
		defer d.close();
		while (flushIt.next()) |kv| {
			writeAtomic(d, kv.key_ptr.*, kv.value_ptr.*) catch |err| {
				std.log.err("Ashframe cache: flush store {s}: {s}", .{ kv.key_ptr.*, @errorName(err) });
			};
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

/// Stages a received chunk blob in RAM; flushed by size/interval/disconnect.
pub fn storeChunk(pos: main.chunk.ChunkPosition, data: []const u8) void {
	if (!isActive()) return;
	var nameBuf: [128]u8 = undefined;
	const name = chunkFileName(pos, &nameBuf);
	ramPut(name, data);
	flushRam(false);
}

/// Loads a cached chunk blob (RAM first, then disk), or null on miss.
/// Caller owns the memory.
pub fn loadChunk(pos: main.chunk.ChunkPosition) ?[]u8 {
	if (!isActive()) return null;
	var nameBuf: [128]u8 = undefined;
	const name = chunkFileName(pos, &nameBuf);
	if (ramGet(name)) |blob| return blob;
	var dirBuf: [256]u8 = undefined;
	const dirPath = cacheDir(&dirBuf);
	var dir = main.files.cubyzDir().openDir(dirPath) catch return null;
	defer dir.close();
	const data = dir.read(main.globalAllocator, name) catch return null;
	return data;
}

/// Drops cached blobs for a live-edited block (RAM + disk, all LODs + lightmap).
pub fn invalidateChunk(wx: i32, wy: i32, wz: i32) void {
	if (!isActive()) return;
	var dirBuf: [256]u8 = undefined;
	const dirPath = cacheDir(&dirBuf);
	var dir = main.files.cubyzDir().openDir(dirPath) catch return;
	defer dir.close();
	for ([_]u31{ 1, 2, 4, 8, 16, 32 }) |vs| {
		const size: i32 = 32*@as(i32, @intCast(vs));
		const mask: i32 = size - 1;
		var nameBuf: [128]u8 = undefined;
		const name = chunkFileName(.{
			.wx = wx & ~mask,
			.wy = wy & ~mask,
			.wz = wz & ~mask,
			.voxelSize = vs,
		}, &nameBuf);
		ramRemove(name);
		dir.deleteFile(name) catch {};
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
	ramPut(name, data);
	flushRam(false);
}

/// Loads a cached lightmap fragment (RAM first, then disk), or null on miss.
/// Caller owns the memory.
pub fn loadLightMap(wx: i32, wy: i32, vs: u31) ?[]u8 {
	if (!isActive()) return null;
	var nameBuf: [128]u8 = undefined;
	const name = lightMapFileName(wx, wy, vs, &nameBuf);
	if (ramGet(name)) |blob| return blob;
	var dirBuf: [256]u8 = undefined;
	const dirPath = cacheDir(&dirBuf);
	var dir = main.files.cubyzDir().openDir(dirPath) catch return null;
	defer dir.close();
	const data = dir.read(main.globalAllocator, name) catch return null;
	return data;
}

/// Deletes the cached lightmap fragment covering column (x, y).
fn invalidateLightMapIn(dir: main.files.Dir, x: i32, y: i32, vs: u31) void {
	const span: i32 = 256*@as(i32, @intCast(vs));
	const mask: i32 = span - 1;
	var nameBuf: [128]u8 = undefined;
	const name = lightMapFileName(x & ~mask, y & ~mask, vs, &nameBuf);
	ramRemove(name);
	dir.deleteFile(name) catch {};
}
// --- ASHFRAME CUSTOM CLIENT ---
