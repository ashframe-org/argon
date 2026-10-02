const std = @import("std");
const Atomic = std.atomic.Value;

const main = @import("main");
const blocks = main.blocks;
const chunk = main.chunk;
const game = main.game;
const network = main.network;
const settings = main.settings;
const utils = main.utils;
const LightMap = main.server.terrain.LightMap;
const vec = main.vec;
const Vec2f = vec.Vec2f;
const Vec3i = vec.Vec3i;
const Vec3f = vec.Vec3f;
const Vec3d = vec.Vec3d;
const Vec4f = vec.Vec4f;
const Mat4f = vec.Mat4f;
const EventStatus = main.block_entity.EventStatus;

const chunk_meshing = @import("chunk_meshing.zig");
const ChunkMesh = chunk_meshing.ChunkMesh;

const ChunkMeshNode = struct {
	mesh: Atomic(?*chunk_meshing.ChunkMesh) = .init(null),
	active: bool = false,
	rendered: bool = false,
	finishedMeshing: bool = false, // Must be synced with mesh.finishedMeshing
	finishedMeshingHigherResolution: u8 = 0, // Must be synced with finishedMeshing of the 8 higher resolution chunks.
	pos: chunk.ChunkPosition = undefined,
	isNeighborLod: [6]bool = @splat(false), // Must be synced with mesh.isNeighborLod
};
const storageSize = 64;
const storageMask = storageSize - 1;
var storageLists: [settings.highestSupportedLod + 1]*[storageSize*storageSize*storageSize]ChunkMeshNode = undefined;
var mapStorageLists: [settings.highestSupportedLod + 1]*[storageSize*storageSize]Atomic(?*LightMap.LightMapFragment) = undefined;
var meshList: main.List(*chunk_meshing.ChunkMesh) = .empty;
var priorityMeshUpdateList: main.utils.ConcurrentQueue(chunk.ChunkPosition) = undefined;
// --- ASHFRAME CUSTOM CLIENT: mesh builds deferred until their lightmap
// fragment exists. Guarded by `mutex` (workers append, render thread scans).
// See deferMeshForLightmap. ---
const PendingLightMesh = struct {
	pos: chunk.ChunkPosition,
	data: []const u8,
	atMs: i64,
	retries: u8 = 0,
};
/// Expiry re-stamps instead of dark-building, and the fragment is actively
/// re-requested (see the pending-mesh scan). After this many expiries the
/// mesh is dropped (a temporary hole the client re-requests on movement)
/// rather than built black, which could never recover.
const maxPendingLightRetries: u8 = 12;
var pendingLightMeshes: main.ListManaged(PendingLightMesh) = undefined;
const maxPendingLightMeshes: usize = 512;
const pendingLightMeshExpiryMs: i64 = 5000;
var pendingLightScanMs: i64 = 0;
// --- ASHFRAME CUSTOM CLIENT ---
pub var updatableList: main.List(chunk.ChunkPosition) = .empty;
var mapUpdatableList: main.utils.ConcurrentQueue(*LightMap.LightMapFragment) = undefined;
var lastPx: i32 = 0;
var lastPy: i32 = 0;
var lastPz: i32 = 0;
var lastRD: u16 = 0;
var mutex: main.utils.Mutex = .{};

// --- ASHFRAME CUSTOM CLIENT (clean join): near-field re-request while the
// reveal gate is active. The client never retries requests on its own, so a
// request that is deferred/lost by the server (or skipped on the first frame)
// leaves a permanent hole until the player crosses a chunk boundary. At a low
// render distance the near-field set is tiny, so one missing cell can keep the
// coverage gate below its threshold. While the world is still hidden we scan
// the same near-field box the gate measures and re-issue requests for the
// still-missing positions, throttled so this never floods. ---
var nearRerequestLastMs: i64 = 0;
const nearRerequestIntervalMs: i64 = 1000;
const nearRerequestHalf: i32 = 192;

// --- ASHFRAME CUSTOM CLIENT (perf: cache the visible-node traversal) ---
// updateAndGetRenderChunks re-ran the whole hierarchical BFS + per-node
// neighbor-LOD recompute every frame (~250ms BFS + ~140ms nbrLod at RD12 on
// this hardware), even when nothing that affects visibility had changed.
// Cache the resulting node set and reuse it until something can change it:
// the player crossing a node-sized boundary, the render distance changing,
// or any node's meshed state changing (`visibilityGen`). Render thread only.
var cachedNodeList: main.List(*ChunkMeshNode) = .empty;
var cachedPx: i32 = std.math.minInt(i32);
var cachedPy: i32 = std.math.minInt(i32);
var cachedPz: i32 = std.math.minInt(i32);
var cachedRD: u16 = 0;
var cachedGen: u64 = 0;
var visibilityGen: u64 = 0;
/// visibilityGen at the time the neighbor-LOD loop last ran. The loop only
/// needs to re-run when some node's meshed/LOD state changed since then.
var lastNbrLodGen: u64 = std.math.maxInt(u64);
/// Bump whenever a node's meshed state can affect the visible set.
fn bumpVisibilityGen() void {
	visibilityGen +%= 1;
}

pub const BlockUpdate = struct {
	pos: Vec3i,
	newBlock: blocks.Block,
	blockEntityData: []const u8,

	pub fn init(pos: Vec3i, block: blocks.Block, blockEntityData: []const u8) BlockUpdate {
		return .{.pos = pos, .newBlock = block, .blockEntityData = blockEntityData};
	}

	pub fn initManaged(allocator: main.heap.NeverFailingAllocator, template: BlockUpdate) BlockUpdate {
		return .{
			.pos = template.pos,
			.newBlock = template.newBlock,
			.blockEntityData = allocator.dupe(u8, template.blockEntityData),
		};
	}

	pub fn deinitManaged(self: BlockUpdate, allocator: main.heap.NeverFailingAllocator) void {
		allocator.free(self.blockEntityData);
	}
};

pub var meshMemoryPool: main.heap.MemoryPool(chunk_meshing.ChunkMesh) = .init(main.globalArena);

pub fn init() void { // MARK: init()
	lastRD = 0;
	for (&storageLists) |*storageList| {
		storageList.* = main.globalAllocator.create([storageSize*storageSize*storageSize]ChunkMeshNode);
		for (storageList.*) |*val| {
			val.* = .{};
		}
	}
	for (&mapStorageLists) |*mapStorageList| {
		mapStorageList.* = main.globalAllocator.create([storageSize*storageSize]Atomic(?*LightMap.LightMapFragment));
		@memset(mapStorageList.*, .init(null));
	}
	priorityMeshUpdateList = .init(main.globalAllocator, 16);
	pendingLightMeshes = .init(main.globalAllocator); // ASHFRAME: deferred builds
	mapUpdatableList = .init(main.globalAllocator, 16);
	// --- ASHFRAME CUSTOM CLIENT (perf cache): storage arrays were just
	// recreated, so any cached node pointers are stale. Reset the cache. ---
	cachedNodeList = .empty;
	cachedPx = std.math.minInt(i32);
	cachedPy = std.math.minInt(i32);
	cachedPz = std.math.minInt(i32);
	cachedRD = 0;
	cachedGen = 0;
	visibilityGen = 0;
}

pub fn deinit() void {
	const olderPx = lastPx;
	const olderPy = lastPy;
	const olderPz = lastPz;
	const olderRD = lastRD;
	lastPx = 0;
	lastPy = 0;
	lastPz = 0;
	lastRD = 0;
	freeOldMeshes(olderPx, olderPy, olderPz, olderRD);
	for (storageLists) |storageList| {
		main.globalAllocator.destroy(storageList);
	}
	for (mapStorageLists) |mapStorageList| {
		main.globalAllocator.destroy(mapStorageList);
	}
	// --- ASHFRAME CUSTOM CLIENT (perf cache): drop stale node pointers. ---
	cachedNodeList.clearAndFree(main.globalAllocator);
	cachedPx = std.math.minInt(i32);
	cachedPy = std.math.minInt(i32);
	cachedPz = std.math.minInt(i32);
	cachedRD = 0;
	cachedGen = 0;
	visibilityGen = 0;

	updatableList.clearAndFree(main.globalAllocator);
	while (mapUpdatableList.popFront()) |map| {
		map.deferredDeinit();
	}
	mapUpdatableList.deinit();
	for (pendingLightMeshes.items) |entry| { // ASHFRAME: free deferred blobs
		main.globalAllocator.free(entry.data);
	}
	pendingLightMeshes.deinit();
	priorityMeshUpdateList.deinit();
	meshList.clearAndFree(main.globalAllocator);
	main.heap.GarbageCollection.waitForFreeCompletion();
}

// MARK: getters

fn getNodePointer(pos: chunk.ChunkPosition) *ChunkMeshNode {
	const lod = std.math.log2_int(u31, pos.voxelSize);
	var xIndex = pos.wx >> lod + chunk.chunkShift;
	var yIndex = pos.wy >> lod + chunk.chunkShift;
	var zIndex = pos.wz >> lod + chunk.chunkShift;
	xIndex &= storageMask;
	yIndex &= storageMask;
	zIndex &= storageMask;
	const index = (xIndex*storageSize + yIndex)*storageSize + zIndex;
	return &storageLists[lod][@intCast(index)];
}

fn finishedMeshingMask(x: bool, y: bool, z: bool) u8 {
	return @as(u8, 1) << (@as(u3, @intFromBool(x))*4 + @as(u3, @intFromBool(y))*2 + @as(u3, @intFromBool(z)));
}

fn updateHigherLodNodeFinishedMeshing(pos_: chunk.ChunkPosition, finishedMeshing: bool) void {
	const lod = std.math.log2_int(u31, pos_.voxelSize);
	if (lod == settings.highestLod) return;
	var pos = pos_;
	pos.wx &= ~@as(i32, pos.voxelSize*chunk.chunkSize);
	pos.wy &= ~@as(i32, pos.voxelSize*chunk.chunkSize);
	pos.wz &= ~@as(i32, pos.voxelSize*chunk.chunkSize);
	pos.voxelSize *= 2;
	const mask = finishedMeshingMask(pos.wx != pos_.wx, pos.wy != pos_.wy, pos.wz != pos_.wz);
	const node = getNodePointer(pos);
	if (finishedMeshing) {
		node.finishedMeshingHigherResolution |= mask;
	} else {
		node.finishedMeshingHigherResolution &= ~mask;
	}
}

fn getMapPiecePointer(x: i32, y: i32, voxelSize: u31) *Atomic(?*LightMap.LightMapFragment) {
	const lod = std.math.log2_int(u31, voxelSize);
	var xIndex = x >> lod + LightMap.LightMapFragment.mapShift;
	var yIndex = y >> lod + LightMap.LightMapFragment.mapShift;
	xIndex &= storageMask;
	yIndex &= storageMask;
	const index = xIndex*storageSize + yIndex;
	return &mapStorageLists[lod][@intCast(index)];
}

pub fn getLightMapPiece(x: i32, y: i32, voxelSize: u31) ?*LightMap.LightMapFragment {
	return getMapPiecePointer(x, y, voxelSize).load(.acquire);
}

pub fn getBlockFromRenderThread(x: i32, y: i32, z: i32) ?blocks.Block {
	const node = getNodePointer(.{.wx = x, .wy = y, .wz = z, .voxelSize = 1});
	const mesh = node.mesh.load(.acquire) orelse return null;
	const block = mesh.chunk.getBlock(x & chunk.chunkMask, y & chunk.chunkMask, z & chunk.chunkMask);
	return block;
}

pub fn getLight(wx: i32, wy: i32, wz: i32) ?[6]u8 {
	const node = getNodePointer(.{.wx = wx, .wy = wy, .wz = wz, .voxelSize = 1});
	const mesh = node.mesh.load(.acquire) orelse return null;
	const pos: chunk.BlockPos = .fromWorldCoords(wx, wy, wz);
	return mesh.lightingData[1].getValue(pos).toArray() ++ mesh.lightingData[0].getValue(pos).toArray();
}

pub fn getBlockFromAnyLodFromRenderThread(x: i32, y: i32, z: i32) blocks.Block {
	var lod: u5 = 0;
	while (lod <= settings.highestLod) : (lod += 1) {
		const node = getNodePointer(.{.wx = x, .wy = y, .wz = z, .voxelSize = @as(u31, 1) << lod});
		const mesh = node.mesh.load(.acquire) orelse continue;
		const block = mesh.chunk.getBlock(x & chunk.chunkMask << lod, y & chunk.chunkMask << lod, z & chunk.chunkMask << lod);
		return block;
	}
	return blocks.Block{.typ = 0, .data = 0};
}

pub fn getMesh(pos: chunk.ChunkPosition) ?*chunk_meshing.ChunkMesh {
	const lod = std.math.log2_int(u31, pos.voxelSize);
	const mask = ~((@as(i32, 1) << lod + chunk.chunkShift) - 1);
	const node = getNodePointer(pos);
	const mesh = node.mesh.load(.acquire) orelse return null;
	if (pos.wx & mask != mesh.pos.wx or pos.wy & mask != mesh.pos.wy or pos.wz & mask != mesh.pos.wz) {
		return null;
	}
	return mesh;
}

pub fn getMeshFromAnyLod(wx: i32, wy: i32, wz: i32, voxelSize: u31) ?*chunk_meshing.ChunkMesh {
	var lod: u5 = @ctz(voxelSize);
	while (lod < settings.highestLod) : (lod += 1) {
		const mesh = getMesh(.{.wx = wx & ~chunk.chunkMask << lod, .wy = wy & ~chunk.chunkMask << lod, .wz = wz & ~chunk.chunkMask << lod, .voxelSize = @as(u31, 1) << lod});
		return mesh orelse continue;
	}
	return null;
}

pub fn getNeighbor(_pos: chunk.ChunkPosition, resolution: u31, neighbor: chunk.Neighbor) ?*chunk_meshing.ChunkMesh {
	var pos = _pos;
	pos.wx +%= pos.voxelSize*chunk.chunkSize*neighbor.relX();
	pos.wy +%= pos.voxelSize*chunk.chunkSize*neighbor.relY();
	pos.wz +%= pos.voxelSize*chunk.chunkSize*neighbor.relZ();
	pos.voxelSize = resolution;
	return getMesh(pos);
}

fn reduceRenderDistance(fullRenderDistance: i64, reduction: i64) i32 {
	const reducedRenderDistanceSquare: f64 = @floatFromInt(fullRenderDistance*fullRenderDistance - reduction*reduction);
	const reducedRenderDistance: i32 = @ceil(@as(f64, @sqrt(@max(0, reducedRenderDistanceSquare))));
	return reducedRenderDistance;
}

fn isInRenderDistance(pos: chunk.ChunkPosition) bool { // MARK: isInRenderDistance()
	const maxRenderDistance = lastRD*chunk.chunkSize*pos.voxelSize;
	const size: u31 = chunk.chunkSize*pos.voxelSize;
	const mask: i32 = size - 1;
	const invMask: i32 = ~mask;

	const minX = lastPx -% maxRenderDistance & invMask;
	const maxX = lastPx +% maxRenderDistance +% size & invMask;
	if (pos.wx -% minX < 0) return false;
	if (pos.wx -% maxX >= 0) return false;
	var deltaX: i64 = @abs(pos.wx +% size/2 -% lastPx);
	deltaX = @max(0, deltaX - size/2);

	const maxYRenderDistance: i32 = reduceRenderDistance(maxRenderDistance, deltaX);
	const minY = lastPy -% maxYRenderDistance & invMask;
	const maxY = lastPy +% maxYRenderDistance +% size & invMask;
	if (pos.wy -% minY < 0) return false;
	if (pos.wy -% maxY >= 0) return false;
	var deltaY: i64 = @abs(pos.wy +% size/2 -% lastPy);
	deltaY = @max(0, deltaY - size/2);

	const maxZRenderDistance: i32 = reduceRenderDistance(maxYRenderDistance, deltaY);
	if (maxZRenderDistance == 0) return false;
	const minZ = lastPz -% maxZRenderDistance & invMask;
	const maxZ = lastPz +% maxZRenderDistance +% size & invMask;
	if (pos.wz -% minZ < 0) return false;
	if (pos.wz -% maxZ >= 0) return false;
	return true;
}

fn isMapInRenderDistance(pos: LightMap.MapFragmentPosition) bool {
	const maxRenderDistance = lastRD*chunk.chunkSize*pos.voxelSize;
	const size: u31 = @as(u31, LightMap.LightMapFragment.mapSize)*pos.voxelSize;
	const mask: i32 = size - 1;
	const invMask: i32 = ~mask;

	const minX = lastPx -% maxRenderDistance & invMask;
	const maxX = lastPx +% maxRenderDistance +% size & invMask;
	if (pos.wx -% minX < 0) return false;
	if (pos.wx -% maxX >= 0) return false;
	var deltaX: i64 = @abs(pos.wx +% size/2 -% lastPx);
	deltaX = @max(0, deltaX - size/2);

	const maxYRenderDistance: i32 = reduceRenderDistance(maxRenderDistance, deltaX);
	if (maxYRenderDistance == 0) return false;
	const minY = lastPy -% maxYRenderDistance & invMask;
	const maxY = lastPy +% maxYRenderDistance +% size & invMask;
	if (pos.wy -% minY < 0) return false;
	if (pos.wy -% maxY >= 0) return false;
	return true;
}

fn freeOldMeshes(olderPx: i32, olderPy: i32, olderPz: i32, olderRD: u16) void { // MARK: freeOldMeshes()
	for (0..settings.highestLod + 1) |_lod| {
		const lod: u5 = @intCast(_lod);
		const maxRenderDistanceNew = lastRD*chunk.chunkSize << lod;
		const maxRenderDistanceOld = olderRD*chunk.chunkSize << lod;
		const size: u31 = chunk.chunkSize << lod;
		const mask: i32 = size - 1;
		const invMask: i32 = ~mask;

		std.debug.assert(@divFloor(2*maxRenderDistanceNew + size - 1, size) + 2 <= storageSize);

		const minX = olderPx -% maxRenderDistanceOld & invMask;
		const maxX = olderPx +% maxRenderDistanceOld +% size & invMask;
		var x = minX;
		while (x != maxX) : (x +%= size) {
			const xIndex = @divExact(x, size) & storageMask;
			var deltaXNew: i64 = @abs(x +% size/2 -% lastPx);
			deltaXNew = @max(0, deltaXNew - size/2);
			var deltaXOld: i64 = @abs(x +% size/2 -% olderPx);
			deltaXOld = @max(0, deltaXOld - size/2);
			const maxYRenderDistanceNew: i32 = reduceRenderDistance(maxRenderDistanceNew, deltaXNew);
			const maxYRenderDistanceOld: i32 = reduceRenderDistance(maxRenderDistanceOld, deltaXOld);

			const minY = olderPy -% maxYRenderDistanceOld & invMask;
			const maxY = olderPy +% maxYRenderDistanceOld +% size & invMask;
			var y = minY;
			while (y != maxY) : (y +%= size) {
				const yIndex = @divExact(y, size) & storageMask;
				var deltaYOld: i64 = @abs(y +% size/2 -% olderPy);
				deltaYOld = @max(0, deltaYOld - size/2);
				var deltaYNew: i64 = @abs(y +% size/2 -% lastPy);
				deltaYNew = @max(0, deltaYNew - size/2);
				var maxZRenderDistanceOld: i32 = reduceRenderDistance(maxYRenderDistanceOld, deltaYOld);
				if (maxZRenderDistanceOld == 0) maxZRenderDistanceOld -= size/2;
				var maxZRenderDistanceNew: i32 = reduceRenderDistance(maxYRenderDistanceNew, deltaYNew);
				if (maxZRenderDistanceNew == 0) maxZRenderDistanceNew -= size/2;

				const minZOld = olderPz -% maxZRenderDistanceOld & invMask;
				const maxZOld = olderPz +% maxZRenderDistanceOld +% size & invMask;
				const minZNew = lastPz -% maxZRenderDistanceNew & invMask;
				const maxZNew = lastPz +% maxZRenderDistanceNew +% size & invMask;

				var zValues: [storageSize]i32 = undefined;
				var zValuesLen: usize = 0;
				if (minZNew -% minZOld > 0) {
					var z = minZOld;
					while (z != minZNew and z != maxZOld) : (z +%= size) {
						zValues[zValuesLen] = z;
						zValuesLen += 1;
					}
				}
				if (maxZOld -% maxZNew > 0) {
					var z = minZOld +% @max(0, maxZNew -% minZOld);
					while (z != maxZOld) : (z +%= size) {
						zValues[zValuesLen] = z;
						zValuesLen += 1;
					}
				}

				for (zValues[0..zValuesLen]) |z| {
					const zIndex = @divExact(z, size) & storageMask;
					const index = (xIndex*storageSize + yIndex)*storageSize + zIndex;

					const node = &storageLists[_lod][@intCast(index)];
					const oldMesh = node.mesh.swap(null, .monotonic);
					node.pos = undefined;
					if (oldMesh) |mesh| {
						node.finishedMeshing = false;
						bumpVisibilityGen();
						updateHigherLodNodeFinishedMeshing(mesh.pos, false);
						mesh.deferredDeinit();
					}
					node.isNeighborLod = @splat(false);
				}
			}
		}
	}
	for (0..settings.highestLod + 1) |_lod| {
		const lod: u5 = @intCast(_lod);
		const maxRenderDistanceNew = lastRD*chunk.chunkSize << lod;
		const maxRenderDistanceOld = olderRD*chunk.chunkSize << lod;
		const size: u31 = @as(u31, LightMap.LightMapFragment.mapSize) << lod;
		const mask: i32 = size - 1;
		const invMask: i32 = ~mask;

		std.debug.assert(@divFloor(2*maxRenderDistanceNew + size - 1, size) + 2 <= storageSize);

		const minX = olderPx -% maxRenderDistanceOld & invMask;
		const maxX = olderPx +% maxRenderDistanceOld +% size & invMask;
		var x = minX;
		while (x != maxX) : (x +%= size) {
			const xIndex = @divExact(x, size) & storageMask;
			var deltaXNew: i64 = @abs(x +% size/2 -% lastPx);
			deltaXNew = @max(0, deltaXNew - size/2);
			var deltaXOld: i64 = @abs(x +% size/2 -% olderPx);
			deltaXOld = @max(0, deltaXOld - size/2);
			var maxYRenderDistanceNew: i32 = reduceRenderDistance(maxRenderDistanceNew, deltaXNew);
			if (maxYRenderDistanceNew == 0) maxYRenderDistanceNew -= size/2;
			var maxYRenderDistanceOld: i32 = reduceRenderDistance(maxRenderDistanceOld, deltaXOld);
			if (maxYRenderDistanceOld == 0) maxYRenderDistanceOld -= size/2;

			const minYOld = olderPy -% maxYRenderDistanceOld & invMask;
			const maxYOld = olderPy +% maxYRenderDistanceOld +% size & invMask;
			const minYNew = lastPy -% maxYRenderDistanceNew & invMask;
			const maxYNew = lastPy +% maxYRenderDistanceNew +% size & invMask;

			var yValues: [storageSize]i32 = undefined;
			var yValuesLen: usize = 0;
			if (minYNew -% minYOld > 0) {
				var y = minYOld;
				while (y != minYNew and y != maxYOld) : (y +%= size) {
					yValues[yValuesLen] = y;
					yValuesLen += 1;
				}
			}
			if (maxYOld -% maxYNew > 0) {
				var y = minYOld +% @max(0, maxYNew -% minYOld);
				while (y != maxYOld) : (y +%= size) {
					yValues[yValuesLen] = y;
					yValuesLen += 1;
				}
			}

			for (yValues[0..yValuesLen]) |y| {
				const yIndex = @divExact(y, size) & storageMask;
				const index = xIndex*storageSize + yIndex;

				const oldMap = mapStorageLists[_lod][@intCast(index)].swap(null, .monotonic);
				if (oldMap) |map| {
					map.deferredDeinit();
				}
			}
		}
	}
}

fn createNewMeshes(olderPx: i32, olderPy: i32, olderPz: i32, olderRD: u16, meshRequests: *main.ListManaged(chunk.ChunkPosition), mapRequests: *main.ListManaged(LightMap.MapFragmentPosition)) void { // MARK: createNewMeshes()
	for (0..settings.highestLod + 1) |_lod| {
		const lod: u5 = @intCast(_lod);
		const maxRenderDistanceNew = lastRD*chunk.chunkSize << lod;
		const maxRenderDistanceOld = olderRD*chunk.chunkSize << lod;
		const size: u31 = chunk.chunkSize << lod;
		const mask: i32 = size - 1;
		const invMask: i32 = ~mask;

		std.debug.assert(@divFloor(2*maxRenderDistanceNew + size - 1, size) + 2 <= storageSize);

		const minX = lastPx -% maxRenderDistanceNew & invMask;
		const maxX = lastPx +% maxRenderDistanceNew +% size & invMask;
		var x = minX;
		while (x != maxX) : (x +%= size) {
			const xIndex = @divExact(x, size) & storageMask;
			var deltaXNew: i64 = @abs(x +% size/2 -% lastPx);
			deltaXNew = @max(0, deltaXNew - size/2);
			var deltaXOld: i64 = @abs(x +% size/2 -% olderPx);
			deltaXOld = @max(0, deltaXOld - size/2);
			const maxYRenderDistanceNew: i32 = reduceRenderDistance(maxRenderDistanceNew, deltaXNew);
			const maxYRenderDistanceOld: i32 = reduceRenderDistance(maxRenderDistanceOld, deltaXOld);

			const minY = lastPy -% maxYRenderDistanceNew & invMask;
			const maxY = lastPy +% maxYRenderDistanceNew +% size & invMask;
			var y = minY;
			while (y != maxY) : (y +%= size) {
				const yIndex = @divExact(y, size) & storageMask;
				var deltaYOld: i64 = @abs(y +% size/2 -% olderPy);
				deltaYOld = @max(0, deltaYOld - size/2);
				var deltaYNew: i64 = @abs(y +% size/2 -% lastPy);
				deltaYNew = @max(0, deltaYNew - size/2);
				var maxZRenderDistanceNew: i32 = reduceRenderDistance(maxYRenderDistanceNew, deltaYNew);
				if (maxZRenderDistanceNew == 0) maxZRenderDistanceNew -= size/2;
				var maxZRenderDistanceOld: i32 = reduceRenderDistance(maxYRenderDistanceOld, deltaYOld);
				if (maxZRenderDistanceOld == 0) maxZRenderDistanceOld -= size/2;

				const minZOld = olderPz -% maxZRenderDistanceOld & invMask;
				const maxZOld = olderPz +% maxZRenderDistanceOld +% size & invMask;
				const minZNew = lastPz -% maxZRenderDistanceNew & invMask;
				const maxZNew = lastPz +% maxZRenderDistanceNew +% size & invMask;

				var zValues: [storageSize]i32 = undefined;
				var zValuesLen: usize = 0;
				if (minZOld -% minZNew > 0) {
					var z = minZNew;
					while (z != minZOld and z != maxZNew) : (z +%= size) {
						zValues[zValuesLen] = z;
						zValuesLen += 1;
					}
				}
				if (maxZNew -% maxZOld > 0) {
					var z = minZNew +% @max(0, maxZOld -% minZNew);
					while (z != maxZNew) : (z +%= size) {
						zValues[zValuesLen] = z;
						zValuesLen += 1;
					}
				}

				for (zValues[0..zValuesLen]) |z| {
					const zIndex = @divExact(z, size) & storageMask;
					const index = (xIndex*storageSize + yIndex)*storageSize + zIndex;
					const pos = chunk.ChunkPosition{.wx = x, .wy = y, .wz = z, .voxelSize = @as(u31, 1) << lod};

					const node = &storageLists[_lod][@intCast(index)];
					node.pos = pos;
					if (node.mesh.load(.acquire)) |mesh| {
						std.debug.assert(std.meta.eql(pos, mesh.pos));
					} else {
						// --- ASHFRAME CUSTOM CLIENT: serve from disk if cached. ---
						if (main.ashframe_client.loadChunk(pos)) |cached| {
							const task = main.globalAllocator.create(network.protocols.chunkTransmission.MeshGenerationTask);
							task.* = .{
								.pos = pos,
								.data = cached,
							};
							main.threadPool.addTask(task, &network.protocols.chunkTransmission.MeshGenerationTask.vtable);
						} else {
							meshRequests.append(pos);
						}
						// --- ASHFRAME CUSTOM CLIENT ---
					}
				}
			}
		}
	}
	for (0..settings.highestLod + 1) |_lod| {
		const lod: u5 = @intCast(_lod);
		const maxRenderDistanceNew = lastRD*chunk.chunkSize << lod;
		const maxRenderDistanceOld = olderRD*chunk.chunkSize << lod;
		const size: u31 = @as(u31, LightMap.LightMapFragment.mapSize) << lod;
		const mask: i32 = size - 1;
		const invMask: i32 = ~mask;

		std.debug.assert(@divFloor(2*maxRenderDistanceNew + size - 1, size) + 2 <= storageSize);

		const minX = lastPx -% maxRenderDistanceNew & invMask;
		const maxX = lastPx +% maxRenderDistanceNew +% size & invMask;
		var x = minX;
		while (x != maxX) : (x +%= size) {
			const xIndex = @divExact(x, size) & storageMask;
			var deltaXNew: i64 = @abs(x +% size/2 -% lastPx);
			deltaXNew = @max(0, deltaXNew - size/2);
			var deltaXOld: i64 = @abs(x +% size/2 -% olderPx);
			deltaXOld = @max(0, deltaXOld - size/2);
			var maxYRenderDistanceNew: i32 = reduceRenderDistance(maxRenderDistanceNew, deltaXNew);
			if (maxYRenderDistanceNew == 0) maxYRenderDistanceNew -= size/2;
			var maxYRenderDistanceOld: i32 = reduceRenderDistance(maxRenderDistanceOld, deltaXOld);
			if (maxYRenderDistanceOld == 0) maxYRenderDistanceOld -= size/2;

			const minYOld = olderPy -% maxYRenderDistanceOld & invMask;
			const maxYOld = olderPy +% maxYRenderDistanceOld +% size & invMask;
			const minYNew = lastPy -% maxYRenderDistanceNew & invMask;
			const maxYNew = lastPy +% maxYRenderDistanceNew +% size & invMask;

			var yValues: [storageSize]i32 = undefined;
			var yValuesLen: usize = 0;
			if (minYOld -% minYNew > 0) {
				var y = minYNew;
				while (y != minYOld and y != maxYNew) : (y +%= size) {
					yValues[yValuesLen] = y;
					yValuesLen += 1;
				}
			}
			if (maxYNew -% maxYOld > 0) {
				var y = minYNew +% @max(0, maxYOld -% minYNew);
				while (y != maxYNew) : (y +%= size) {
					yValues[yValuesLen] = y;
					yValuesLen += 1;
				}
			}

			for (yValues[0..yValuesLen]) |y| {
				const yIndex = @divExact(y, size) & storageMask;
				const index = xIndex*storageSize + yIndex;
				const pos = LightMap.MapFragmentPosition{.wx = x, .wy = y, .voxelSize = @as(u31, 1) << lod, .voxelSizeShift = lod};

				const map = mapStorageLists[_lod][@intCast(index)].load(.monotonic);
				if (map) |_map| {
					std.debug.assert(std.meta.eql(pos, _map.pos));
				} else {
					mapRequests.append(pos);
				}
			}
		}
	}
}

pub noinline fn updateAndGetRenderChunks(conn: *network.Connection, frustum: *const main.renderer.Frustum, playerPos: Vec3d, renderDistance: u16) []*chunk_meshing.ChunkMesh { // MARK: updateAndGetRenderChunks()
	meshList.clearRetainingCapacity();

	const playerPosInt: Vec3i = @floor(playerPos);

	var meshRequests: main.ListManaged(chunk.ChunkPosition) = .init(main.stackAllocator);
	defer meshRequests.deinit();
	var mapRequests: main.ListManaged(LightMap.MapFragmentPosition) = .init(main.stackAllocator);
	defer mapRequests.deinit();

	const olderPx = lastPx;
	const olderPy = lastPy;
	const olderPz = lastPz;
	const olderRD = lastRD;
	mutex.lock();
	lastPx = @trunc(playerPos[0]);
	lastPy = @trunc(playerPos[1]);
	lastPz = @trunc(playerPos[2]);
	lastRD = renderDistance;
	mutex.unlock();
	// --- ASHFRAME CUSTOM CLIENT (perf) ---
	main.ashframe_client.profBegin(.freeOld);
	// Only walk the old render-distance volume when we actually moved to a
	// new chunk cell or the distance changed. When stationary old==new, the
	// walk frees nothing but cost ~19ms/frame over the whole volume. ---
	if (olderPx != lastPx or olderPy != lastPy or olderPz != lastPz or olderRD != lastRD) {
		freeOldMeshes(olderPx, olderPy, olderPz, olderRD);
	}
	main.ashframe_client.profEnd();
	// --- ASHFRAME CUSTOM CLIENT ---

	// --- ASHFRAME CUSTOM CLIENT: one dir handle + timing for the serve pass. ---
	main.ashframe_client.profBegin(.serveBatch);
	main.ashframe_client.beginServeBatch();
	// --- ASHFRAME CUSTOM CLIENT (perf) ---
	main.ashframe_client.profBegin(.createNew);
	createNewMeshes(olderPx, olderPy, olderPz, olderRD, &meshRequests, &mapRequests);
	main.ashframe_client.profEnd();
	// --- ASHFRAME CUSTOM CLIENT ---

	// --- ASHFRAME CUSTOM CLIENT: serve lightmaps from disk if cached. ---
	{
		var kept: usize = 0;
		for (mapRequests.items) |req| {
			if (main.ashframe_client.loadLightMap(req.wx, req.wy, req.voxelSize)) |cached| {
				const task = main.globalAllocator.create(network.protocols.lightMapTransmission.LightMapTask);
				task.* = .{
					.wx = req.wx,
					.wy = req.wy,
					.voxelSizeShift = req.voxelSizeShift,
					.data = cached,
				};
				main.threadPool.addTask(task, &network.protocols.lightMapTransmission.LightMapTask.vtable);
			} else {
				mapRequests.items[kept] = req;
				kept += 1;
			}
		}
		mapRequests.items.len = kept;
	}
	// --- ASHFRAME CUSTOM CLIENT ---
	main.ashframe_client.endServeBatch();
	main.ashframe_client.profEnd();
	// --- ASHFRAME CUSTOM CLIENT: while the clean-join gate is active,
	// re-request near-field positions that never arrived (bounded, ~1/s). ---
	{
		main.ashframe_client.profBegin(.serveBatch);
		main.ashframe_client.beginServeBatch();
		rerequestMissingNearField(&meshRequests, &mapRequests);
		main.ashframe_client.endServeBatch();
		main.ashframe_client.profEnd();
	}
	// --- ASHFRAME CUSTOM CLIENT (perf) ---

	// Make requests as soon as possible to reduce latency:
	network.protocols.lightMapRequest.sendRequest(conn, mapRequests.items);
	network.protocols.chunkRequest.sendRequest(conn, meshRequests.items, .{lastPx, lastPy, lastPz}, lastRD);

	// Finds all visible chunks and lod chunks using a breadth-first hierarchical search.

	// --- ASHFRAME CUSTOM CLIENT (perf: cached traversal) ---
	// Reuse the previous frame's visible-node set while nothing that affects
	// visibility changed (same quantized player pos + RD + no mesh-state
	// change). Idle at RD12 was paying the full ~400ms traversal every frame.
	// Quantize to the block (floor) position: while standing on the same
	// block the frustum is effectively identical, so the visible set cannot
	// change. Walking re-runs the BFS each block-step (correct, and still
	// far cheaper than every frame at every sub-block).
	const qx: i32 = playerPosInt[0];
	const qy: i32 = playerPosInt[1];
	const qz: i32 = playerPosInt[2];
	// --- ASHFRAME CUSTOM CLIENT (perf fix): the cached set is the whole
	// render cylinder (view-independent), so turning must NOT invalidate it.
	// The frustum is applied per-frame in the meshBuild loop instead. Only
	// position, render distance and mesh-state changes re-run the BFS. ---
	const cacheValid = cachedPx == qx and cachedPy == qy and cachedPz == qz and
		cachedRD == renderDistance and cachedGen == visibilityGen;

	var nodeList: main.ListManaged(*ChunkMeshNode) = .initCapacity(main.stackAllocator, 1024);
	defer nodeList.deinit();

	if (cacheValid) {
		// Nothing changed: reuse the cached visible-node set, skipping the
		// entire BFS + frustum tests. The neighborLod + meshBuild loops below
		// still run (cheap, and they handle pending uploads).
		nodeList.appendSlice(cachedNodeList.items);
	} else {
		var searchList = main.utils.CircularBufferQueue(*ChunkMeshNode).init(main.stackAllocator, 1024);
		defer searchList.deinit();
		{
			var firstPos = chunk.ChunkPosition{
				.wx = playerPosInt[0],
				.wy = playerPosInt[1],
				.wz = playerPosInt[2],
				.voxelSize = 1,
			};
			const lod: u3 = settings.highestLod;
			firstPos.wx &= ~@as(i32, chunk.chunkMask << lod | (@as(i32, 1) << lod) - 1);
			firstPos.wy &= ~@as(i32, chunk.chunkMask << lod | (@as(i32, 1) << lod) - 1);
			firstPos.wz &= ~@as(i32, chunk.chunkMask << lod | (@as(i32, 1) << lod) - 1);
			firstPos.voxelSize <<= lod;
			const node = getNodePointer(firstPos);
			const hasMesh = node.finishedMeshing;
			if (hasMesh) {
				node.active = true;
				node.rendered = true;
				searchList.pushBack(node);
			}
		}
		// --- ASHFRAME CUSTOM CLIENT (perf profiling) ---
		main.ashframe_client.profBegin(.bfs);
		// --- ASHFRAME CUSTOM CLIENT ---
		while (searchList.popFront()) |node| {
			std.debug.assert(node.finishedMeshing);
			std.debug.assert(node.active);
			if (!node.active) continue;
			node.active = false;

			const pos = node.pos;

			const relPos: Vec3i = Vec3i{pos.wx, pos.wy, pos.wz} - playerPosInt;

			if (pos.voxelSize == @as(i32, 1) << settings.highestLod) {
				for (chunk.Neighbor.iterable) |neighbor| {
					const component = neighbor.extractDirectionComponent(relPos);
					if (neighbor.isPositive() and component + chunk.chunkSize*pos.voxelSize <= 0) continue;
					if (!neighbor.isPositive() and component > 0) continue;
					const neighborPos = chunk.ChunkPosition{
						.wx = pos.wx +% neighbor.relX()*chunk.chunkSize*pos.voxelSize,
						.wy = pos.wy +% neighbor.relY()*chunk.chunkSize*pos.voxelSize,
						.wz = pos.wz +% neighbor.relZ()*chunk.chunkSize*pos.voxelSize,
						.voxelSize = pos.voxelSize,
					};
					const node2 = getNodePointer(neighborPos);
					if (!node2.active and node2.finishedMeshing) {
						// --- ASHFRAME CUSTOM CLIENT (perf fix): no frustum
						// test here. The BFS now selects the whole render
						// cylinder (view-independent, cacheable); the frustum
						// is applied per-frame in the meshBuild loop, so
						// turning reveals already-selected chunks with no seam
						// and without re-running the BFS. ---
						node2.active = true;
						node2.rendered = true;
						searchList.pushBack(node2);
					}
				}
			}

			if (node.finishedMeshingHigherResolution == 0xff) {
				node.rendered = false;
				const lowerLodBit: i32 = pos.voxelSize*chunk.chunkSize >> 1;
				const startPos: chunk.ChunkPosition = .{
					.wx = pos.wx | if ((pos.wx | lowerLodBit) -% playerPosInt[0] > 0) lowerLodBit else 0,
					.wy = pos.wy | if ((pos.wy | lowerLodBit) -% playerPosInt[1] > 0) lowerLodBit else 0,
					.wz = pos.wz | if ((pos.wz | lowerLodBit) -% playerPosInt[2] > 0) lowerLodBit else 0,
					.voxelSize = pos.voxelSize >> 1,
				};
				for (0..2) |dx| {
					for (0..2) |dy| {
						for (0..2) |dz| {
							var nextPos = startPos;
							if (dx == 1) nextPos.wx ^= lowerLodBit;
							if (dy == 1) nextPos.wy ^= lowerLodBit;
							if (dz == 1) nextPos.wz ^= lowerLodBit;
							const node2 = getNodePointer(nextPos);
							std.debug.assert(node2.finishedMeshing);
							node2.active = true;
							node2.rendered = true;
							searchList.pushFront(node2);
						}
					}
				}
			} else {
				nodeList.append(node);
			}
		}
		// --- ASHFRAME CUSTOM CLIENT (perf profiling) ---
		main.ashframe_client.profEnd(); // end BFS
		// --- ASHFRAME CUSTOM CLIENT ---
		// Refresh the cache with this frame's result.
		cachedNodeList.clearRetainingCapacity();
		cachedNodeList.appendSlice(main.globalAllocator, nodeList.items);
		cachedPx = qx;
		cachedPy = qy;
		cachedPz = qz;
		cachedRD = renderDistance;
		cachedGen = visibilityGen;
	}
	// --- ASHFRAME CUSTOM CLIENT (perf profiling) ---
	main.ashframe_client.profBegin(.neighborLod);
	// --- ASHFRAME CUSTOM CLIENT ---
	// Neighbor-LOD only changes when some node's meshed state changed
	// (`visibilityGen`). Skip the whole per-node recompute otherwise - it was
	// ~140ms/frame of pure repeated work while idle. ---
	// --- ASHFRAME CUSTOM CLIENT (loading speed): while the world is hidden by
	// the join overlay this recompute is purely visual (seam flags) and, with
	// meshes finishing every frame during warmup, it re-ran over the whole
	// growing node list every frame (a large part of the ~1s warmup frames).
	// Skip it while hidden; it runs once the world is revealed. ---
	if (main.ashframe_client.isWorldRevealed() and visibilityGen != lastNbrLodGen) {
		lastNbrLodGen = visibilityGen;
		for (nodeList.items) |node| {
			const pos = node.pos;
			var isNeighborLod: [6]bool = @splat(false);
			if (pos.voxelSize != @as(i32, 1) << settings.highestLod) {
				for (chunk.Neighbor.iterable) |neighbor| {
					var neighborPos = chunk.ChunkPosition{
						.wx = pos.wx +% neighbor.relX()*chunk.chunkSize*pos.voxelSize,
						.wy = pos.wy +% neighbor.relY()*chunk.chunkSize*pos.voxelSize,
						.wz = pos.wz +% neighbor.relZ()*chunk.chunkSize*pos.voxelSize,
						.voxelSize = pos.voxelSize,
					};
					neighborPos.wx &= ~@as(i32, neighborPos.voxelSize*chunk.chunkSize);
					neighborPos.wy &= ~@as(i32, neighborPos.voxelSize*chunk.chunkSize);
					neighborPos.wz &= ~@as(i32, neighborPos.voxelSize*chunk.chunkSize);
					neighborPos.voxelSize *= 2;
					const node2 = getNodePointer(neighborPos);
					isNeighborLod[neighbor.toInt()] = node2.finishedMeshingHigherResolution != 0xff;
				}
			}
			if (!std.meta.eql(node.isNeighborLod, isNeighborLod)) {
				const mesh = node.mesh.load(.acquire).?; // no other thread is allowed to overwrite the mesh (unless it's null).
				mesh.isNeighborLod = isNeighborLod;
				node.isNeighborLod = isNeighborLod;
				mesh.uploadData();
			}
		}
	} // end visibilityGen != lastNbrLodGen gate
	// --- ASHFRAME CUSTOM CLIENT (perf profiling) ---
	main.ashframe_client.profEnd(); // end neighborLod
	main.ashframe_client.profBegin(.meshBuild);
	// --- ASHFRAME CUSTOM CLIENT ---
	for (nodeList.items) |node| {
		node.rendered = false;
		if (!node.finishedMeshing) continue;

		// --- ASHFRAME CUSTOM CLIENT (perf fix): per-frame frustum test.
		// The BFS is view-independent now, so cull here using this frame's
		// frustum. Chunks outside the view are skipped without re-running the
		// BFS, and turning shows already-loaded chunks immediately. ---
		{
			const pos = node.pos;
			const chunkSizeVector: Vec3f = @floatFromInt(Vec3i{chunk.chunkSize*pos.voxelSize, chunk.chunkSize*pos.voxelSize, chunk.chunkSize*pos.voxelSize});
			const relPosFloat: Vec3f = @floatCast(@as(Vec3d, @floatFromInt(Vec3i{pos.wx, pos.wy, pos.wz})) - playerPos);
			if (!frustum.testAAB(relPosFloat, chunkSizeVector)) continue;
		}

		const mesh = node.mesh.load(.acquire).?; // no other thread is allowed to overwrite the mesh (unless it's null).

		if (mesh.needsMeshUpdate) {
			mesh.needsMeshUpdate = false;
			mesh.uploadData();
		}
		// Remove empty meshes.
		if (!mesh.isEmpty()) {
			meshList.append(main.globalAllocator, mesh);
		}
	}
	// --- ASHFRAME CUSTOM CLIENT (perf profiling) ---
	main.ashframe_client.profEnd(); // end meshBuild
	// --- ASHFRAME CUSTOM CLIENT ---

	return meshList.items;
}

pub fn updateMeshes(targetTime: std.Io.Timestamp) void { // MARK: updateMeshes()
	mutex.lock();
	defer mutex.unlock();
	while (priorityMeshUpdateList.popFront()) |pos| {
		const mesh = getMesh(pos) orelse continue;
		if (!mesh.needsMeshUpdate) {
			continue;
		}
		mesh.needsMeshUpdate = false;
		mutex.unlock();
		defer mutex.lock();
		mesh.uploadData();
		if (targetTime.durationTo(main.timestamp()).nanoseconds >= 0) break; // Update at least one mesh.
	}
	// --- ASHFRAME CUSTOM CLIENT (liveness): upload freshly-finished meshes
	// BEFORE the map/relight block. The relight sweep is unbudgeted; running it
	// first could spend the whole frame and skip this loop, leaving the world
	// empty while the render thread stayed busy. Uploading first guarantees the
	// world fills regardless of relight load. ---
	uploadFinishedMeshes(targetTime);
	// --- ASHFRAME CUSTOM CLIENT ---
	var newMapsStored = false;
	while (mapUpdatableList.popFront()) |map| {
		// Budget the relight block too: each stored fragment runs a relight
		// sweep. Stop draining once the frame budget is spent; remaining maps
		// stay queued (updateLightMap already pushed them) for the next frame.
		if (newMapsStored and targetTime.durationTo(main.timestamp()).nanoseconds >= 0) {
			// Re-queue this one and stop; don't lose it.
			mapUpdatableList.pushBack(map);
			break;
		}
		if (!isMapInRenderDistance(map.pos)) {
			map.deferredDeinit();
		} else {
			const mapPointer = getMapPiecePointer(map.pos.wx, map.pos.wy, map.pos.voxelSize).swap(map, .release);
			if (mapPointer) |old| {
				old.deferredDeinit();
			}
			newMapsStored = true;
			// --- ASHFRAME CUSTOM CLIENT: a mesh built before its fragment
			// arrived stays dark otherwise (nothing re-lights built meshes).
			// Refresh the covered meshes so they pick up real light now. ---
			relightMeshesForFragment(map.pos.wx, map.pos.wy, map.pos.voxelSize);
		}
	}
	// --- ASHFRAME CUSTOM CLIENT: retry deferred mesh builds. Runs when new
	// fragments landed (or ~1/s so expiry can't strand entries). Each entry
	// either re-enters the stock pipeline as a fresh task, builds now if it
	// waited too long, or is dropped when out of range. Only addTask calls
	// happen under the lock; the heavy builds run on workers.
	if (pendingLightMeshes.items.len != 0) {
		const nowMs = main.timestamp().toMilliseconds();
		if (newMapsStored or nowMs -% pendingLightScanMs >= 1000) {
			pendingLightScanMs = nowMs;
			// Missing fragments a deferred mesh is still waiting on get
			// re-requested here: the client never retries on its own, so a
			// dropped/lost fragment would otherwise strand the mesh (and, after
			// the force-build fallback, leave it dark until relit). Bounded by
			// the pending-mesh count and sent once per scan.
			var fragReqs: main.ListManaged(LightMap.MapFragmentPosition) = .init(main.stackAllocator);
			defer fragReqs.deinit();
			var i: usize = pendingLightMeshes.items.len;
			while (i > 0) {
				i -= 1;
				const entry = pendingLightMeshes.items[i];
				const hasFragment = getLightMapPiece(entry.pos.wx, entry.pos.wy, entry.pos.voxelSize) != null;
				const expired = nowMs -% entry.atMs >= pendingLightMeshExpiryMs;
				const inRange = isInRenderDistance(entry.pos);
				if (!hasFragment and inRange) {
					const fsize: i32 = @as(i32, LightMap.LightMapFragment.mapSize)*@as(i32, @intCast(entry.pos.voxelSize));
					const fpos = LightMap.MapFragmentPosition{
						.wx = entry.pos.wx & ~(fsize - 1),
						.wy = entry.pos.wy & ~(fsize - 1),
						.voxelSize = entry.pos.voxelSize,
						.voxelSizeShift = @intCast(std.math.log2_int(u31, entry.pos.voxelSize)),
					};
					// Dedup: many pending meshes share one fragment. Without this
					// the scan emitted one request PER MESH (up to 512/frame for a
					// handful of fragments), the server echoed each, and every echo
					// re-ran the full relight sweep - a self-sustaining flood that
					// starved mesh uploads. Only request genuinely-distinct fragments.
					var dup = false;
					for (fragReqs.items) |existing| {
						if (existing.wx == fpos.wx and existing.wy == fpos.wy and existing.voxelSize == fpos.voxelSize) {
							dup = true;
							break;
						}
					}
					if (!dup) fragReqs.append(fpos);
				}
				if (!inRange) {
					main.globalAllocator.free(entry.data);
					_ = pendingLightMeshes.swapRemove(i);
				} else if (hasFragment) {
					const task = main.globalAllocator.create(network.protocols.chunkTransmission.MeshGenerationTask);
					task.* = .{
						.pos = entry.pos,
						.data = entry.data,
						.forceBuild = true,
					};
					main.threadPool.addTask(task, &network.protocols.chunkTransmission.MeshGenerationTask.vtable);
					_ = pendingLightMeshes.swapRemove(i);
				} else if (expired) {
					// --- ASHFRAME CUSTOM CLIENT (black-shadow fix): NEVER build
					// dark. Building without the fragment produces a permanently
					// black mesh (the sun channel is set only at mesh birth).
					// Keep the mesh deferred and re-request the fragment (done
					// above); only if it stays missing after a large retry budget
					// do we drop it (a temporary hole that the client re-requests
					// on movement) rather than show black. ---
					if (entry.retries >= maxPendingLightRetries) {
						main.globalAllocator.free(entry.data);
						_ = pendingLightMeshes.swapRemove(i);
					} else {
						pendingLightMeshes.items[i].atMs = nowMs;
						pendingLightMeshes.items[i].retries += 1;
					}
				}
			}
			if (fragReqs.items.len != 0) {
				if (game.world) |w| {
					network.protocols.lightMapRequest.sendRequest(w.conn, fragReqs.items);
				}
			}
		}
	}
}

/// Uploads freshly-finished meshes (nearest first) within the frame budget.
/// Called early from `updateMeshes` (before the unbudgeted relight sweep) so
/// the world fills even when relighting is heavy. Runs with `mutex` held; the
/// stock unlock/defer-lock idiom keeps the lock balanced around the upload.
fn uploadFinishedMeshes(targetTime: std.Io.Timestamp) void {
	if (updatableList.items.len == 0 or targetTime.durationTo(main.timestamp()).nanoseconds >= 0) return;
	const playerPos = game.Player.getEyePosBlocking();
	// Sort ascending by priority; we then walk from the end (highest
	// priority = nearest) so meshes closest to the player are built
	// first. In-place on our own scratch list; bounded by the pending
	// set now that entries are removed as they are handled. pdq is fast
	// and stable enough here since priorities rarely tie exactly.
	std.sort.pdq(chunk.ChunkPosition, updatableList.items, playerPos, struct {
		fn gt(pos: Vec3d, a: chunk.ChunkPosition, b: chunk.ChunkPosition) bool {
			return a.getPriority(pos) < b.getPriority(pos);
		}
	}.gt);
	// --- ASHFRAME CUSTOM (perf FIX): process from the END and swapRemove
	// every entry we've handled (or that no longer needs work), so the
	// list only ever holds genuinely-pending meshes. The previous version
	// only `continue`d past finished entries, leaving them in the list
	// forever - it then re-sorted an ever-growing list every frame, which
	// is what collapsed FPS at high render distance. Stock drained the
	// list; restore that behavior. ---
	var i: usize = updatableList.items.len;
	while (i > 0) {
		i -= 1;
		const pos = updatableList.items[i];
		if (!isInRenderDistance(pos)) {
			_ = updatableList.swapRemove(i);
			continue;
		}
		const node = getNodePointer(pos);
		if (node.finishedMeshing) {
			_ = updatableList.swapRemove(i);
			continue;
		}
		const mesh = getMesh(pos) orelse {
			_ = updatableList.swapRemove(i);
			continue;
		};
		node.finishedMeshing = true;
		mesh.finishedMeshing = true;
		bumpVisibilityGen();
		updateHigherLodNodeFinishedMeshing(pos, true);
		_ = updatableList.swapRemove(i);
		mutex.unlock();
		defer mutex.lock();
		mesh.uploadData();
		if (targetTime.durationTo(main.timestamp()).nanoseconds >= 0) break; // Update at least one mesh.
	}
}

// MARK: adders

pub fn addToUpdateList(mesh: *chunk_meshing.ChunkMesh) void {
	mutex.lock();
	defer mutex.unlock();
	if (mesh.finishedMeshing) {
		priorityMeshUpdateList.pushBack(mesh.pos);
		mesh.needsMeshUpdate = true;
	}
}

pub fn addMeshToStorage(mesh: *chunk_meshing.ChunkMesh) error{ AlreadyStored, NoLongerNeeded }!void {
	mutex.lock();
	defer mutex.unlock();
	if (!isInRenderDistance(mesh.pos)) {
		return error.NoLongerNeeded;
	}
	const node = getNodePointer(mesh.pos);
	if (node.mesh.cmpxchgStrong(null, mesh, .release, .monotonic) != null) {
		return error.AlreadyStored;
	}
	node.finishedMeshing = mesh.finishedMeshing;
	bumpVisibilityGen();
	updateHigherLodNodeFinishedMeshing(mesh.pos, mesh.finishedMeshing);
}

pub fn finishMesh(pos: chunk.ChunkPosition) void {
	mutex.lock();
	defer mutex.unlock();
	updatableList.append(main.globalAllocator, pos);
}

// --- ASHFRAME CUSTOM CLIENT: refresh built meshes covered by a newly
// landed lightmap fragment. Called from the render thread (updateMeshes
// holds `mutex`). Without this, a mesh built before its fragment arrived
// stays dark: the stock pipeline only relights via block updates, and
// the deferred retry only handles unbuilt entries. Same-vs chunks in the
// fragment's 256*vs box, all z in render range; missing meshes skip. ---
fn relightMeshesForFragment(fx: i32, fy: i32, vs: u31) void {
	// --- ASHFRAME CUSTOM CLIENT (perf): this box scan + per-hit task enqueue
	// is the prime suspect for the render-distance FPS collapse; profile it. ---
	main.ashframe_client.profBegin(.relight); // count = number of invocations
	defer main.ashframe_client.profEnd();
	// --- ASHFRAME CUSTOM CLIENT ---
	const span: i32 = 256*@as(i32, @intCast(vs));
	const cs: i32 = 32*@as(i32, @intCast(vs));
	const zExt: i32 = @as(i32, lastRD)*32*@as(i32, @intCast(vs));
	var x = fx;
	while (x < fx + span) : (x += cs) {
		var y = fy;
		while (y < fy + span) : (y += cs) {
			var z = lastPz - zExt;
			while (z <= lastPz + zExt) : (z += cs) {
				const pos = chunk.ChunkPosition{.wx = x, .wy = y, .wz = z, .voxelSize = vs};
				if (getMesh(pos) != null) {
					ChunkMesh.scheduleLightRefresh(pos);
					main.ashframe_client.profCount(.relightCalls, 1); // meshes scheduled
				}
			}
		}
	}
}

// --- ASHFRAME CUSTOM CLIENT (clean join): near-field coverage for the
// reveal gate. The gate used to count a FIXED +-192 block box across all
// LODs regardless of the render distance. At a low render distance the
// coarse LODs in that box are outside the render volume and are never
// requested/meshed, so `resident/total` could never reach the threshold and
// the screen stalled at "Taking longer than usual" (RD5). Coverage now
// counts only positions that actually intersect the render volume for their
// LOD at the current render distance. Render/main thread only; no locks. ---
pub const NearCoverage = struct { total: u32, resident: u32 };

/// Render distance in blocks for the current frame (falls back to the
/// setting before the first render pass has set `lastRD`).
fn coverageRenderDistanceBlocks() i32 {
	const rd: u16 = if (lastRD != 0) lastRD else settings.renderDistance;
	return @as(i32, @intCast(rd))*chunk.chunkSize;
}

/// True when the axis-aligned box `[minX,maxX) x [minY,maxY)` (block units,
/// half-open) lies within `rd` blocks of the player on the X/Y plane (with
/// +1 block of slack). The reveal gate only cares that the near field around
/// the player is populated, so a per-axis plane test is enough and matches
/// the horizontal chunk/fragment grid the box already walks.
fn boxInRenderVolume(px: i32, py: i32, rd: i32, minX: i64, minY: i64, maxX: i64, maxY: i64) bool {
	const nx = @min(@max(@as(i64, px), minX), maxX);
	const ny = @min(@max(@as(i64, py), minY), maxY);
	const ddx = nx - px;
	const ddy = ny - py;
	const r = @as(i64, rd) + 1;
	return ddx*ddx + ddy*ddy <= r*r;
}

// --- ASHFRAME CUSTOM CLIENT (clean join): iterate exactly the mesh cells the
// BFS/render pipeline builds near the player, per LOD. `createNewMeshes` walks
// a DISK: the Y range is reduced per X, and the Z range per Y, via
// `reduceRenderDistance`. The reveal gate must count this same set, otherwise
// its denominator includes cells that are never built and the ratio is
// unreachable (this was the RD5 "taking longer than usual" stall: a full
// rectangle of 726 cells vs at most 528 buildable => max 72.7% < 80%).
// ---
/// Calls `cb` once per (x,y) built cell, with the built Z cell nearest `pz`
/// (the near-field column the reveal gate measures). This keeps the gate on
/// the near surface column while restricting the (x,y) footprint to the DISK
/// `createNewMeshes` actually builds, so `resident` can reach `total`.
/// `radiusChunks`: if > 0, restrict the walk to a small DISK of that many
/// chunks (used by the reveal gate so the player waits only for the immediate
/// area, not the whole render disk). 0 = full render distance.
fn forEachBuiltNearMeshCell(px: i32, py: i32, pz: i32, rd: u16, radiusChunks: i32, comptime Ctx: type, ctx: Ctx, comptime cb: fn (Ctx, chunk.ChunkPosition) void) void {
	for (0..@as(usize, settings.highestLod) + 1) |_lod| {
		const lod: u5 = @intCast(_lod);
		const vs: u31 = @as(u31, 1) << lod;
		const sz: i32 = chunk.chunkSize*@as(i32, @intCast(vs));
		const mask: i32 = sz - 1;
		const invMask: i32 = ~mask;
		// Effective radius in blocks: the inner reveal disk (if set) scaled per
		// LOD, else the full render distance for this LOD. Both scale by `vs`
		// the same way, so the walked cell count per LOD is identical.
		const radius: i32 = if (radiusChunks > 0)
			radiusChunks*chunk.chunkSize*@as(i32, @intCast(vs))
		else
			@as(i32, @intCast(rd))*chunk.chunkSize << lod;

		const minX = px -% radius & invMask;
		const maxX = px +% radius +% sz & invMask;
		var cx = minX;
		while (cx != maxX) : (cx +%= sz) {
			var deltaX: i64 = @abs(cx +% @divTrunc(sz, 2) -% px);
			deltaX = @max(0, deltaX - @divTrunc(sz, 2));
			const maxYRD: i32 = reduceRenderDistance(radius, deltaX);

			const minY = py -% maxYRD & invMask;
			const maxY = py +% maxYRD +% sz & invMask;
			var cy = minY;
			while (cy != maxY) : (cy +%= sz) {
				var deltaY: i64 = @abs(cy +% @divTrunc(sz, 2) -% py);
				deltaY = @max(0, deltaY - @divTrunc(sz, 2));
				var maxZRD: i32 = reduceRenderDistance(maxYRD, deltaY);
				if (maxZRD == 0) maxZRD -= @divTrunc(sz, 2);

				// The single built Z cell containing pz. It is always inside the
				// built Z range because maxZRD >= 0 (clamped above), so this cell
				// is genuinely requested and can become resident.
				const cz = pz & invMask;
				cb(ctx, .{.wx = cx, .wy = cy, .wz = cz, .voxelSize = vs});
			}
		}
	}
}

/// `radiusChunks`: 0 = full render disk (used for reporting); > 0 = inner disk
/// (used by the reveal gate so the player waits only for the immediate area).
pub fn nearMeshCoverageRadius(px: i32, py: i32, pz: i32, radiusChunks: i32) NearCoverage {
	const rd: u16 = if (lastRD != 0) lastRD else settings.renderDistance;
	const Ctx = struct {
		total: u32 = 0,
		resident: u32 = 0,
		fn cb(self: *@This(), pos: chunk.ChunkPosition) void {
			self.total += 1;
			const node = getNodePointer(pos);
			if (node.mesh.load(.acquire)) |mesh| {
				if (mesh.finishedMeshing) self.resident += 1;
			}
		}
	};
	var ctx = Ctx{};
	forEachBuiltNearMeshCell(px, py, pz, rd, radiusChunks, *Ctx, &ctx, Ctx.cb);
	return .{.total = ctx.total, .resident = ctx.resident};
}

pub fn nearMeshCoverage(px: i32, py: i32, pz: i32) NearCoverage {
	return nearMeshCoverageRadius(px, py, pz, 0);
}

pub fn nearLightCoverage(px: i32, py: i32) NearCoverage {
	var total: u32 = 0;
	var resident: u32 = 0;
	const rd: i32 = coverageRenderDistanceBlocks();
	for (0..@as(usize, settings.highestLod) + 1) |_lod| {
		const lod: u5 = @intCast(_lod);
		const vs: u31 = @as(u31, 1) << lod;
		const frag: i32 = @as(i32, LightMap.LightMapFragment.mapSize)*@as(i32, @intCast(vs));
		const reach: i32 = (@divTrunc(rd, frag) + 1)*frag;
		var fx = (px - reach) & ~(frag - 1);
		const maxFx = (px + reach) & ~(frag - 1);
		while (fx <= maxFx) : (fx += frag) {
			var fy = (py - reach) & ~(frag - 1);
			const maxFy = (py + reach) & ~(frag - 1);
			while (fy <= maxFy) : (fy += frag) {
				if (!boxInRenderVolume(px, py, rd, fx, fy, @as(i64, fx) + frag, @as(i64, fy) + frag)) continue;
				total += 1;
				if (getLightMapPiece(fx, fy, vs) != null) resident += 1;
			}
		}
	}
	return .{.total = total, .resident = resident};
}

/// While the world is still hidden by the clean-join reveal gate, re-issue
/// requests for near-field chunks/lightmaps that have not arrived. Bounded to
/// once per `nearRerequestIntervalMs` and to the fixed near-field box the
/// prefetch warms, so it only covers the area the gate actually measures.
/// Once the world is revealed the normal pipeline (and movement) requests
/// what's needed; re-requesting post-reveal kept re-triggering fragment
/// arrivals and the relight sweep. Render/main thread only.
fn rerequestMissingNearField(meshRequests: *main.ListManaged(chunk.ChunkPosition), mapRequests: *main.ListManaged(LightMap.MapFragmentPosition)) void {
	if (main.ashframe_client.isWorldRevealed()) return;
	const nowMs = main.timestamp().toMilliseconds();
	if (nowMs -% nearRerequestLastMs < nearRerequestIntervalMs) return;
	nearRerequestLastMs = nowMs;
	const px = lastPx;
	const py = lastPy;
	const pz = lastPz;
	for (0..@as(usize, settings.highestLod) + 1) |_lod| {
		const lod: u5 = @intCast(_lod);
		const vs: u31 = @as(u31, 1) << lod;
		const sz: i32 = chunk.chunkSize*@as(i32, @intCast(vs));
		const half: i32 = if (vs >= 8) 768 else nearRerequestHalf;
		var cx = (px - half) & ~(sz - 1);
		const maxCx = (px + half) & ~(sz - 1);
		while (cx <= maxCx) : (cx += sz) {
			var cy = (py - half) & ~(sz - 1);
			const maxCy = (py + half) & ~(sz - 1);
			while (cy <= maxCy) : (cy += sz) {
				const cz = pz & ~(sz - 1);
				const node = getNodePointer(.{.wx = cx, .wy = cy, .wz = cz, .voxelSize = vs});
				const has = if (node.mesh.load(.acquire)) |m| m.finishedMeshing else false;
				// Only ask for positions that are genuinely wanted (in render
				// distance) and not already served from the disk cache.
				const pos = chunk.ChunkPosition{.wx = cx, .wy = cy, .wz = cz, .voxelSize = vs};
				if (!has and isInRenderDistance(pos)) {
					if (main.ashframe_client.loadChunk(pos)) |cached| {
						const task = main.globalAllocator.create(network.protocols.chunkTransmission.MeshGenerationTask);
						task.* = .{.pos = pos, .data = cached};
						main.threadPool.addTask(task, &network.protocols.chunkTransmission.MeshGenerationTask.vtable);
					} else {
						meshRequests.append(pos);
					}
				}
			}
		}
		const frag: i32 = @as(i32, LightMap.LightMapFragment.mapSize)*@as(i32, @intCast(vs));
		var fx = (px - half) & ~(frag - 1);
		const maxFx = (px + half) & ~(frag - 1);
		while (fx <= maxFx) : (fx += frag) {
			var fy = (py - half) & ~(frag - 1);
			const maxFy = (py + half) & ~(frag - 1);
			while (fy <= maxFy) : (fy += frag) {
				if (getLightMapPiece(fx, fy, vs) != null) continue;
				const pos = LightMap.MapFragmentPosition{.wx = fx, .wy = fy, .voxelSize = vs, .voxelSizeShift = lod};
				if (!isMapInRenderDistance(pos)) continue;
				if (main.ashframe_client.loadLightMap(fx, fy, vs)) |cached| {
					const task = main.globalAllocator.create(network.protocols.lightMapTransmission.LightMapTask);
					task.* = .{.wx = fx, .wy = fy, .voxelSizeShift = lod, .data = cached};
					main.threadPool.addTask(task, &network.protocols.lightMapTransmission.LightMapTask.vtable);
				} else {
					mapRequests.append(pos);
				}
			}
		}
	}
}

// --- ASHFRAME CUSTOM CLIENT: defer mesh creation until the lightmap
// fragment exists, so meshes are never born dark. Called from mesh-build
// worker threads; takes ownership of `data` on true. Returns false when
// the pending list is full (caller falls back to the stock path).
// The scan in updateMeshes retries entries once their fragment lands;
// entries that outlive the wait (expiry) re-stamp a few times, then build
// anyway so nothing stalls forever; out-of-range entries drop. Relighting
// of already-built meshes happens via relightMeshesForFragment, so dark
// builds still converge to real light once their fragment lands.
pub fn deferMeshForLightmap(pos: chunk.ChunkPosition, data: []const u8) bool {
	mutex.lock();
	defer mutex.unlock();
	if (pendingLightMeshes.items.len >= maxPendingLightMeshes) return false;
	pendingLightMeshes.append(.{
		.pos = pos,
		.data = data,
		.atMs = main.timestamp().toMilliseconds(),
	});
	return true;
}
// --- ASHFRAME CUSTOM CLIENT ---

// MARK: updaters

pub fn updateBlock(blockUpdate: BlockUpdate) void {
	const pos = chunk.ChunkPosition{.wx = blockUpdate.pos[0], .wy = blockUpdate.pos[1], .wz = blockUpdate.pos[2], .voxelSize = 1};
	if (getMesh(pos)) |mesh| {
		mesh.updateBlock(blockUpdate);
	} // TODO: It seems like we simply ignore the block update if we don't have the mesh yet.
}

pub fn updateLightMap(map: *LightMap.LightMapFragment) void {
	mapUpdatableList.pushBack(map);
}

// MARK: Block breaking animation

pub fn addBreakingAnimation(pos: Vec3i, breakingProgress: f32) void {
	const animationFrame: usize = @trunc(breakingProgress*@as(f32, @floatFromInt(main.blocks.meshes.blockBreakingTextures.items.len)));
	const texture = main.blocks.meshes.blockBreakingTextures.items[animationFrame];

	const block = getBlockFromRenderThread(pos[0], pos[1], pos[2]) orelse return;
	const model = main.blocks.meshes.model(block).model();

	for (model.internalQuads) |quadIndex| {
		addBreakingAnimationFace(pos, quadIndex, texture, null, block.transparent());
	}
	for (&model.neighborFacingQuads, 0..) |quads, n| {
		for (quads) |quadIndex| {
			addBreakingAnimationFace(pos, quadIndex, texture, @enumFromInt(n), block.transparent());
		}
	}
}

fn addBreakingAnimationFace(pos: Vec3i, quadIndex: main.models.QuadIndex, texture: u16, neighbor: ?chunk.Neighbor, isTransparent: bool) void {
	const worldPos = pos +% if (neighbor) |n| n.relPos() else Vec3i{0, 0, 0};
	const relPos = worldPos & @as(Vec3i, @splat(main.chunk.chunkMask));
	const mesh = getMesh(.{.wx = worldPos[0], .wy = worldPos[1], .wz = worldPos[2], .voxelSize = 1}) orelse return;
	mesh.mutex.lock();
	defer mesh.mutex.unlock();
	const lightIndex = blk: {
		mesh.meshUploadMutex.lock();
		defer mesh.meshUploadMutex.unlock();
		const meshData = if (isTransparent) &mesh.transparentMesh else &mesh.opaqueMesh;
		for (meshData.completeList.getEverything()) |face| {
			if (face.position.x == relPos[0] and face.position.y == relPos[1] and face.position.z == relPos[2] and face.blockAndQuad.quadIndex == quadIndex) {
				break :blk face.position.lightIndex;
			}
		}
		// The face doesn't exist.
		return;
	};
	mesh.blockBreakingFacesChanged = true;
	mesh.blockBreakingFaces.append(.{
		.position = .{
			.x = @intCast(relPos[0]),
			.y = @intCast(relPos[1]),
			.z = @intCast(relPos[2]),
			.isBackFace = false,
			.lightIndex = lightIndex,
		},
		.blockAndQuad = .{
			.texture = texture,
			.quadIndex = quadIndex,
		},
	});
}

fn removeBreakingAnimationFace(pos: Vec3i, quadIndex: main.models.QuadIndex, neighbor: ?chunk.Neighbor) void {
	const worldPos = pos +% if (neighbor) |n| n.relPos() else Vec3i{0, 0, 0};
	const relPos = worldPos & @as(Vec3i, @splat(main.chunk.chunkMask));
	const mesh = getMesh(.{.wx = worldPos[0], .wy = worldPos[1], .wz = worldPos[2], .voxelSize = 1}) orelse return;
	for (mesh.blockBreakingFaces.items, 0..) |face, i| {
		if (face.position.x == relPos[0] and face.position.y == relPos[1] and face.position.z == relPos[2] and face.blockAndQuad.quadIndex == quadIndex) {
			_ = mesh.blockBreakingFaces.swapRemove(i);
			mesh.blockBreakingFacesChanged = true;
			break;
		}
	}
}

pub fn removeBreakingAnimation(pos: Vec3i) void {
	const block = getBlockFromRenderThread(pos[0], pos[1], pos[2]) orelse return;
	const model = main.blocks.meshes.model(block).model();

	for (model.internalQuads) |quadIndex| {
		removeBreakingAnimationFace(pos, quadIndex, null);
	}
	for (&model.neighborFacingQuads, 0..) |quads, n| {
		for (quads) |quadIndex| {
			removeBreakingAnimationFace(pos, quadIndex, @enumFromInt(n));
		}
	}
}
