const std = @import("std");

const main = @import("main");
const chunk = main.chunk;
const game = main.game;
const graphics = main.graphics;
const ZonElement = main.ZonElement;
const renderer = main.renderer;
const settings = main.settings;
const utils = main.utils;
const BinaryReader = utils.BinaryReader;
const vec = main.vec;
const Mat4f = vec.Mat4f;
const Vec3d = vec.Vec3d;
const Vec3f = vec.Vec3f;
const Vec4f = vec.Vec4f;
const NeverFailingAllocator = main.heap.NeverFailingAllocator;

const c = @import("c");

var lastTime: i16 = 0;
var timeDifference: utils.TimeDifference = utils.TimeDifference{};

pub var entities: main.utils.VirtualList(main.client.Entity, 1 << 20) = undefined;
pub var idMapping: main.ListManaged(?u32) = undefined;
pub var mutex: main.utils.Mutex = .{};

pub fn init() void {
	entities = .init();
	idMapping = .init(main.globalAllocator);
}

pub fn deinit() void {
	for (entities.items()) |ent| {
		ent.deinit(main.globalAllocator);
	}
	entities.deinit();
	idMapping.deinit();
}

pub fn clear() void {
	for (entities.items()) |ent| {
		ent.deinit(main.globalAllocator);
	}
	entities.clearRetainingCapacity();
	idMapping.clearRetainingCapacity();
	timeDifference = utils.TimeDifference{};
}

pub fn update() void {
	mutex.lock();
	defer mutex.unlock();

	var time: i16 = @truncate(main.timestamp().toMilliseconds() -% settings.entityLookback);
	time -%= timeDifference.difference.load(.monotonic);
	for (entities.items()) |*ent| {
		ent.update(time, lastTime);
	}
	lastTime = time;
}

pub fn addEntity(zon: ZonElement) !void {
	mutex.lock();
	defer mutex.unlock();

	const id = zon.get(u32, "id") orelse return error.entityIdMissing;
	// --- ASHFRAME (flood/crash hardening): entity ids are a small per-boot
	// counter (players + creatures). A gigantic id would grow idMapping by
	// gigabytes (OOM crash) — reject it loudly instead of growing. ---
	if (id >= 1 << 20) {
		std.log.err("addEntity: refusing insane entity id {d}", .{id});
		return error.entityIdMissing;
	}
	// --- ASHFRAME (flood hardening): the entity store is a fixed reservation;
	// growing past it segfaults. Legit counts are in the hundreds. ---
	if (entities.len >= (1 << 20) - 1) {
		std.log.err("addEntity: entity store full, dropping id {d}", .{id});
		return error.entityIdMissing;
	}
	// --- ASHFRAME (duplicate-add hardening): re-adding a live id used to
	// orphan the old slot (leaked, rendered forever) and corrupt the mapping.
	// Retire the old entry first so an add is always idempotent. ---
	if (id < idMapping.items.len and idMapping.items[id] != null) {
		removeEntityInternal(@enumFromInt(id));
	}
	const index = entities.len;
	var ent = entities.addOne();

	if (idMapping.items.len <= id) {
		idMapping.appendNTimes(null, id - idMapping.items.len + 1);
	}
	idMapping.items[id] = index;

	try ent.init(zon, main.globalAllocator);
}
pub fn getEntity(entity: main.entity.Entity) ?*main.client.Entity {
	mutex.assertLocked();
	if (@intFromEnum(entity) >= idMapping.items.len) return null;
	return &entities.items()[idMapping.items[@intFromEnum(entity)] orelse return null];
}
pub fn removeEntity(entity: main.entity.Entity) void {
	mutex.lock();
	defer mutex.unlock();

	removeEntityInternal(entity);
}

/// Same as `removeEntity` but requires the mutex to already be held.
fn removeEntityInternal(entity: main.entity.Entity) void {
	mutex.assertLocked();

	if (idMapping.items.len <= @intFromEnum(entity)) return;
	const index: u32 = idMapping.items[@intFromEnum(entity)] orelse return;
	const ent = entities.items()[index];

	// remove id
	idMapping.items[@intFromEnum(entity)] = null;

	// remove entity
	{
		std.debug.assert(ent.id == entity);
		ent.deinit(main.globalAllocator);
		_ = entities.swapRemove(index);

		if (index != entities.len) {
			idMapping.items[@intFromEnum(entities.items()[index].id)] = index;
			entities.items()[index].interpolatedValues.outPos = &entities.items()[index]._interpolationPos;
			entities.items()[index].interpolatedValues.outVel = &entities.items()[index]._interpolationVel;
		}
	}
}

pub fn serverUpdate(time: i16, entityData: []main.entity.EntityNetworkData) void {
	mutex.lock();
	defer mutex.unlock();
	timeDifference.addDataPoint(time);

	for (entityData) |data| {
		const pos = [_]f64{
			data.pos[0],
			data.pos[1],
			data.pos[2],
			@floatCast(data.rot[0]),
			@floatCast(data.rot[1]),
			@floatCast(data.rot[2]),
		};
		const vel = [_]f64{
			data.vel[0],
			data.vel[1],
			data.vel[2],
			0,
			0,
			0,
		};
		if (getEntity(data.id)) |ent| {
			ent.updatePosition(&pos, &vel, time);
		}
	}
}
