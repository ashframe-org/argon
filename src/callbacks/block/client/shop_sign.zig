const std = @import("std");

const main = @import("main");
const Block = main.blocks.Block;
const vec = main.vec;
const Vec3i = vec.Vec3i;
const ZonElement = main.ZonElement;

pub fn init(_: ZonElement, _: main.callbacks.Creator) ?*anyopaque {
	return @as(*anyopaque, undefined);
}

// --- ASHFRAME CUSTOM CLIENT (sign shop: click sign to open) ---
// On Argon, clicking a sign tries to open the shop it advertises, reusing
// the normal chest-open path (no new protocol, vanilla untouched). The
// chest is derived from the sign's mount direction. If the server finds no
// shop there it simply opens/ignores the chest as usual. Shift-click still
// falls through to the stock edit_sign behaviour.
pub fn run(_: *anyopaque, params: main.callbacks.ClientBlockCallback.Params) main.callbacks.Result {
	const block = params.block;
	if (block.blockEntity() == null or !std.mem.eql(u8, block.blockEntity().?.id, "cubyz:sign")) {
		return .ignored;
	}
	// On non-Ashframe servers, fall through to the stock editor.
	if (main.ashframe_client.isActive()) {
		// Side mounts only (16..19): 0..7 ceiling, 8..15 floor.
		if (switch (block.data) {
			16 => Vec3i{ -1, 0, 0 },
			17 => Vec3i{ 0, -1, 0 },
			18 => Vec3i{ 1, 0, 0 },
			19 => Vec3i{ 0, 1, 0 },
			else => null,
		}) |off| {
			const chest: Vec3i = .{ params.blockPos[0] + off[0], params.blockPos[1] + off[1], params.blockPos[2] + off[2] };
			if (main.renderer.mesh_storage.getBlockFromRenderThread(chest[0], chest[1], chest[2])) |chestBlock| {
				if (chestBlock.blockEntity() != null and std.mem.eql(u8, chestBlock.blockEntity().?.id, "cubyz:chest")) {
					// Ask the server to open the shop at this chest (customer
					// -> buy menu, owner -> chest, no shop -> normal open).
					main.network.protocols.blockEntityUpdate.sendClientDataUpdateToServer(main.game.world.?.conn, chest);
					return .handled;
				}
			}
		}
	}
	// No mounted chest (plain sign) or non-Ashframe: open the editor.
	main.block_entity.BlockEntityTypes.@"cubyz:sign".StorageClient.mutex.lock();
	defer main.block_entity.BlockEntityTypes.@"cubyz:sign".StorageClient.mutex.unlock();
	const data = main.block_entity.BlockEntityTypes.@"cubyz:sign".StorageClient.get(params.blockPos, params.chunk);
	main.gui.windowlist.sign_editor.openFromSignData(params.blockPos, if (data) |d| d.text else "");
	return .handled;
}
// --- ASHFRAME CUSTOM CLIENT ---
