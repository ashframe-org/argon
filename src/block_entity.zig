const std = @import("std");

const main = @import("main.zig");
const Block = main.blocks.Block;
const Chunk = main.chunk.Chunk;
const ChunkPosition = main.chunk.ChunkPosition;
const getIndex = main.chunk.getIndex;
const graphics = main.graphics;
const server = main.server;
const User = server.User;
const mesh_storage = main.renderer.mesh_storage;
const BinaryReader = main.utils.BinaryReader;
const BinaryWriter = main.utils.BinaryWriter;
const vec = main.vec;
const Mat4f = vec.Mat4f;
const Vec3d = vec.Vec3d;
const Vec3f = vec.Vec3f;
const Vec3i = vec.Vec3i;

const c = @import("c");

const UpdateEvent = union(enum) {
	remove: void,
	update: *BinaryReader,
};

pub const ErrorSet = BinaryReader.AllErrors || error{Invalid};

pub const BlockEntityType = struct { // MARK: BlockEntityType
	id: []const u8,
	vtable: VTable,

	const VTable = struct {
		onLoadClient: *const fn (pos: Vec3i, chunk: *Chunk, reader: *BinaryReader) ErrorSet!void,
		onUnloadClient: *const fn (entity: BlockEntity) void,
		onLoadServer: *const fn (pos: Vec3i, chunk: *Chunk, reader: *BinaryReader) ErrorSet!void,
		onUnloadServer: *const fn (entity: BlockEntity) void,
		onStoreServerToDisk: *const fn (entity: BlockEntity, writer: *BinaryWriter) void,
		onStoreServerToClient: *const fn (entity: BlockEntity, writer: *BinaryWriter) void,
		updateClientData: *const fn (pos: Vec3i, chunk: *Chunk, event: UpdateEvent) ErrorSet!void,
		updateServerData: *const fn (pos: Vec3i, chunk: *Chunk, event: UpdateEvent) ErrorSet!void,
		getServerToClientData: *const fn (pos: Vec3i, chunk: *Chunk, writer: *BinaryWriter) void,
		getClientToServerData: *const fn (pos: Vec3i, chunk: *Chunk, writer: *BinaryWriter) void,
	};
	pub fn init(comptime BlockEntityTypeT: type, comptime id: []const u8) BlockEntityType {
		BlockEntityTypeT.init();
		var class = BlockEntityType{
			.id = id,
			.vtable = undefined,
		};

		inline for (@typeInfo(BlockEntityType.VTable).@"struct".fields) |field| {
			if (!@hasDecl(BlockEntityTypeT, field.name)) {
				@compileError("BlockEntityType missing field '" ++ field.name ++ "'");
			}
			@field(class.vtable, field.name) = &@field(BlockEntityTypeT, field.name);
		}
		return class;
	}
	pub inline fn onLoadClient(self: *const BlockEntityType, pos: Vec3i, chunk: *Chunk, reader: *BinaryReader) ErrorSet!void {
		return self.vtable.onLoadClient(pos, chunk, reader);
	}
	pub inline fn onUnloadClient(self: *const BlockEntityType, entity: BlockEntity) void {
		return self.vtable.onUnloadClient(entity);
	}
	pub inline fn onLoadServer(self: *const BlockEntityType, pos: Vec3i, chunk: *Chunk, reader: *BinaryReader) ErrorSet!void {
		return self.vtable.onLoadServer(pos, chunk, reader);
	}
	pub inline fn onUnloadServer(self: *const BlockEntityType, entity: BlockEntity) void {
		return self.vtable.onUnloadServer(entity);
	}
	pub inline fn onStoreServerToDisk(self: *const BlockEntityType, entity: BlockEntity, writer: *BinaryWriter) void {
		return self.vtable.onStoreServerToDisk(entity, writer);
	}
	pub inline fn onStoreServerToClient(self: *const BlockEntityType, entity: BlockEntity, writer: *BinaryWriter) void {
		return self.vtable.onStoreServerToClient(entity, writer);
	}
	pub inline fn updateClientData(self: *const BlockEntityType, pos: Vec3i, chunk: *Chunk, event: UpdateEvent) ErrorSet!void {
		return try self.vtable.updateClientData(pos, chunk, event);
	}
	pub inline fn updateServerData(self: *const BlockEntityType, pos: Vec3i, chunk: *Chunk, event: UpdateEvent) ErrorSet!void {
		return try self.vtable.updateServerData(pos, chunk, event);
	}
	pub inline fn getServerToClientData(self: *const BlockEntityType, pos: Vec3i, chunk: *Chunk, writer: *BinaryWriter) void {
		return self.vtable.getServerToClientData(pos, chunk, writer);
	}
	pub inline fn getClientToServerData(self: *const BlockEntityType, pos: Vec3i, chunk: *Chunk, writer: *BinaryWriter) void {
		return self.vtable.getClientToServerData(pos, chunk, writer);
	}
};

pub const BlockEntity = enum(u32) { // MARK: BlockEntity
	noValue = std.math.maxInt(u32),
	_,

	var freeIndexList: main.List(BlockEntity) = .empty;
	var nextIndex: BlockEntity = @enumFromInt(0);
	var mutex: main.utils.Mutex = .{};

	fn globalDeinit() void {
		freeIndexList.deinit(main.globalAllocator);
		nextIndex = undefined;
		freeIndexList = undefined;
	}

	fn reset() void {
		freeIndexList.clearRetainingCapacity();
		nextIndex = @enumFromInt(0);
	}

	fn create() BlockEntity {
		mutex.lock();
		defer mutex.unlock();
		return freeIndexList.popOrNull() orelse {
			defer nextIndex = @enumFromInt(@intFromEnum(nextIndex) + 1);
			return nextIndex;
		};
	}

	fn destroy(self: BlockEntity) void {
		mutex.lock();
		defer mutex.unlock();
		freeIndexList.append(main.globalAllocator, self);
	}
};

fn BlockEntityDataStorage(T: type) type { // MARK: BlockEntityDataStorage
	return struct {
		pub const DataT = T;
		var storage: main.utils.SparseSet(DataT, BlockEntity) = undefined;
		pub var mutex: main.utils.Mutex = .{};

		pub fn init() void {
			storage = .{};
		}
		pub fn deinit() void {
			storage.deinit(main.globalAllocator);
			storage = undefined;
		}
		pub fn reset() void {
			storage.clear();
		}
		fn createEntry(pos: Vec3i, chunk: *Chunk) BlockEntity {
			mutex.assertLocked();
			const entity: BlockEntity = .create();
			const localPos = chunk.getLocalBlockPos(pos);

			chunk.blockPosToEntityDataMapMutex.lock();
			chunk.blockPosToEntityDataMap.put(main.globalAllocator.allocator, localPos, entity) catch unreachable;
			chunk.blockPosToEntityDataMapMutex.unlock();
			return entity;
		}
		pub fn add(pos: Vec3i, value: DataT, chunk: *Chunk) void {
			mutex.lock();
			defer mutex.unlock();

			const entity = createEntry(pos, chunk);
			storage.set(main.globalAllocator, entity, value);
		}
		pub fn removeAtIndex(entity: BlockEntity) ?DataT {
			mutex.assertLocked();
			entity.destroy();
			return storage.fetchRemove(entity) catch null;
		}
		pub fn remove(pos: Vec3i, chunk: *Chunk) ?DataT {
			mutex.lock();
			defer mutex.unlock();

			const localPos = chunk.getLocalBlockPos(pos);

			chunk.blockPosToEntityDataMapMutex.lock();
			const entityNullable = chunk.blockPosToEntityDataMap.fetchRemove(localPos);
			chunk.blockPosToEntityDataMapMutex.unlock();

			const entry = entityNullable orelse return null;

			const entity = entry.value;
			return removeAtIndex(entity);
		}
		pub fn getByIndex(entity: BlockEntity) ?*DataT {
			mutex.assertLocked();

			return storage.get(entity);
		}
		pub fn get(pos: Vec3i, chunk: *Chunk) ?*DataT {
			mutex.assertLocked();

			const localPos = chunk.getLocalBlockPos(pos);

			chunk.blockPosToEntityDataMapMutex.lock();
			defer chunk.blockPosToEntityDataMapMutex.unlock();

			const entity = chunk.blockPosToEntityDataMap.get(localPos) orelse return null;
			return storage.get(entity);
		}
		pub const GetOrPutResult = struct {
			valuePtr: *DataT,
			foundExisting: bool,
		};
		pub fn getOrPut(pos: Vec3i, chunk: *Chunk) GetOrPutResult {
			mutex.assertLocked();
			if (get(pos, chunk)) |result| return .{.valuePtr = result, .foundExisting = true};

			const entity = createEntry(pos, chunk);
			return .{.valuePtr = storage.add(main.globalAllocator, entity), .foundExisting = false};
		}
	};
}

pub const BlockEntityTypes = struct { // MARK: BlockEntityTypes
	pub const @"cubyz:chest" = struct { // MARK: cubyz:chest
		pub const inventorySize = 20;
		const StorageServer = BlockEntityDataStorage(struct {
			invId: main.items.Inventory.InventoryId,
		});

		pub fn init() void {
			StorageServer.init();
		}
		pub fn deinit() void {
			StorageServer.deinit();
		}
		pub fn reset() void {
			StorageServer.reset();
		}

		fn onInventoryUpdateCallback(source: main.items.Inventory.Source) void {
			const pos = source.blockInventory;
			const simChunk = main.server.world.?.getSimulationChunkAndIncreaseRefCount(pos[0], pos[1], pos[2]) orelse return;
			defer simChunk.decreaseRefCount();
			const ch = simChunk.getChunk() orelse return;
			ch.mutex.lock();
			defer ch.mutex.unlock();
			ch.setChanged();
		}

		const inventoryCallbacks = main.items.Inventory.Callbacks{
			.onUpdateCallback = &onInventoryUpdateCallback,
		};

		pub fn onLoadClient(_: Vec3i, _: *Chunk, _: *BinaryReader) ErrorSet!void {}
		pub fn onUnloadClient(_: BlockEntity) void {}
		pub fn onLoadServer(pos: Vec3i, chunk: *Chunk, reader: *BinaryReader) ErrorSet!void {
			StorageServer.mutex.lock();
			defer StorageServer.mutex.unlock();

			const data = StorageServer.getOrPut(pos, chunk);
			std.debug.assert(!data.foundExisting);
			data.valuePtr.invId = main.items.Inventory.server.createExternallyManagedInventory(inventorySize, .{.blockInventory = pos}, reader, inventoryCallbacks);
		}

		pub fn onUnloadServer(entity: BlockEntity) void {
			StorageServer.mutex.lock();
			const data = StorageServer.removeAtIndex(entity).?;
			StorageServer.mutex.unlock();
			main.items.Inventory.server.destroyExternallyManagedInventory(data.invId);
		}
		pub fn onStoreServerToDisk(entity: BlockEntity, writer: *BinaryWriter) void {
			StorageServer.mutex.lock();
			defer StorageServer.mutex.unlock();
			const data = StorageServer.getByIndex(entity) orelse return;

			const inv = main.items.Inventory.server.getInventoryFromId(data.invId);
			var isEmpty: bool = true;
			for (inv._items) |item| {
				if (item.amount != 0) isEmpty = false;
			}
			if (isEmpty) return;
			inv.toBytes(writer);
		}
		pub fn onStoreServerToClient(_: BlockEntity, _: *BinaryWriter) void {}

		pub fn updateClientData(_: Vec3i, _: *Chunk, _: UpdateEvent) ErrorSet!void {}
		pub fn updateServerData(pos: Vec3i, chunk: *Chunk, event: UpdateEvent) ErrorSet!void {
			switch (event) {
				.remove => {
					const chestComponent = StorageServer.remove(pos, chunk) orelse return;
					main.items.Inventory.server.destroyAndDropExternallyManagedInventory(chestComponent.invId, pos);
				},
				.update => {
					StorageServer.mutex.lock();
					defer StorageServer.mutex.unlock();
					const data = StorageServer.getOrPut(pos, chunk);
					if (data.foundExisting) return;
					var reader = BinaryReader.init(&.{});
					data.valuePtr.invId = main.items.Inventory.server.createExternallyManagedInventory(inventorySize, .{.blockInventory = pos}, &reader, inventoryCallbacks);
				},
			}
		}
		pub fn getServerToClientData(_: Vec3i, _: *Chunk, _: *BinaryWriter) void {}
		pub fn getClientToServerData(_: Vec3i, _: *Chunk, _: *BinaryWriter) void {}

		pub fn renderAll(_: Vec3f) void {}
	};

	pub const @"cubyz:sign" = struct { // MARK: cubyz:sign
		const StorageServer = BlockEntityDataStorage(struct {
			text: []const u8,
		});
		pub const StorageClient = BlockEntityDataStorage(struct {
			text: []const u8,
			renderedTexture: ?main.graphics.Texture = null,
			blockPos: Vec3i,
			block: main.blocks.Block,

			fn deinit(self: @This()) void {
				main.globalAllocator.free(self.text);
				if (self.renderedTexture) |texture| {
					textureDeinitLock.lock();
					defer textureDeinitLock.unlock();
					textureDeinitList.append(main.globalAllocator, texture);
				}
			}
		});
		var textureDeinitList: main.List(graphics.Texture) = .empty;
		var textureDeinitLock: main.utils.Mutex = .{};
		var pipeline: graphics.Pipeline = undefined;
		var uniforms: struct {
			ambientLight: c_int,
			quadIndex: c_int,
			lightData: c_int,
			chunkPos: c_int,
			blockPos: c_int,
		} = undefined;
		// --- ASHFRAME (Argon sign icons): dedicated 2D textured-quad
		// pipeline for baking item icons into the sign texture. draw.image
		// is a GUI-pass pipeline (swapChain format, GUI scissor/color) and
		// silently no-ops here in the world/offscreen pass. ---
		var iconPipeline: graphics.Pipeline = undefined;
		var iconUniforms: struct {
			start: c_int,
			size: c_int,
			screen: c_int,
		} = undefined;
		var iconVao: graphics.VertexArray = undefined;

		// TODO: Load these from some per-block settings
		const textureWidth = 128;
		const textureHeight = 72;
		const textureMargin = 4;
		// --- ASHFRAME (Argon large sign + icons): bigger canvas for the
		// large-sign block; normal signs keep stock dimensions. ---
		const largeTextureWidth = 256;
		const largeTextureHeight = 144;
		const largeFontSize = 30;
		const stockFontSize = 16;

		fn isLargeSign(block: main.blocks.Block) bool {
			return std.mem.eql(u8, block.id(), "ashframe:large_sign");
		}

		/// Resolve a shop-text item name to its item index. Shop signs store
		/// short ids ("ruby"), so try full id, cubyz-namespaced id, then a
		/// case-insensitive short-id scan. No GPU work here.
		fn itemForName(name: []const u8) ?main.items.BaseItemIndex {
			if (main.items.BaseItemIndex.fromId(name)) |item| return item;
			var nsBuf: [128]u8 = undefined;
			const namespaced = std.fmt.bufPrint(&nsBuf, "cubyz:{s}", .{name}) catch null;
			if (namespaced) |ns| {
				if (main.items.BaseItemIndex.fromId(ns)) |item| return item;
			}
			var i: u16 = 0;
			while (i < main.items.itemListSize) : (i += 1) {
				const item: main.items.BaseItemIndex = @enumFromInt(i);
				const id = item.id();
				const short = if (std.mem.indexOfScalar(u8, id, ':')) |colon| id[colon + 1 ..] else id;
				if (std.ascii.eqlIgnoreCase(short, name)) return item;
			}
			return null;
		}

		/// The already-generated icon texture for an item, or null if it has
		/// not been generated yet. Read-only: must NOT generate here.
		fn iconTextureFor(item: main.items.BaseItemIndex) ?main.graphics.Texture {
			return item.texture();
		}

		/// Draw an item icon as a 2D quad inside the bound sign framebuffer,
		/// at sign-texture pixel (x, y) with size px. Uses the dedicated
		/// world-format pipeline (draw.image cannot render here).
		fn drawIcon(icon: main.graphics.Texture, x: f32, y: f32, size: f32, canvasW: f32, canvasH: f32) void {
			icon.bindTo(0);
			iconPipeline.bind(null);
			c.glUniform2f(iconUniforms.start, x, y);
			c.glUniform2f(iconUniforms.size, size, size);
			c.glUniform2f(iconUniforms.screen, canvasW, canvasH);
			iconVao.bind();
			c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
		}

		/// Pre-generate icons for every qty-line item in `text`, BEFORE the
		/// sign framebuffer is bound. getTexture() runs GPU work (binds its
		/// own FBO + viewport), so calling it mid-pass clobbered the sign
		/// render — icons silently vanished. Generate once up front.
		fn pregenerateIcons(text: []const u8) void {
			var it = std.mem.splitScalar(u8, text, '\n');
			while (it.next()) |line| {
				const qty = parseQtyLine(line) orelse continue;
				const item = itemForName(qty.item) orelse continue;
				_ = item.getTexture();
			}
		}

		/// Split a shop quantity line ("-12x amber_ore", color codes kept)
		/// into the text prefix to draw ("-12x ") and the item name.
		/// Null when the line is not a quantity line.
		const QtyLine = struct { prefix: []const u8, item: []const u8 };
		fn parseQtyLine(line: []const u8) ?QtyLine {
			var i: usize = 0;
			// Skip leading color codes (§ is 2 UTF-8 bytes; then #rrggbb
			// (7 more) or a single effect char).
			while (std.mem.startsWith(u8, line[i..], "§")) {
				i += "§".len;
				if (i < line.len and line[i] == '#') {
					i += 7;
				} else if (i < line.len) {
					i += 1;
				} else break;
			}
			if (i >= line.len or (line[i] != '+' and line[i] != '-')) return null;
			i += 1;
			const digitStart = i;
			while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
			if (i == digitStart or i + 1 >= line.len or line[i] != 'x' or line[i + 1] != ' ') return null;
			const prefixEnd = i + 2;
			const item = line[prefixEnd..];
			if (item.len == 0) return null;
			return .{ .prefix = line[0..prefixEnd], .item = item };
		}
		// --- ASHFRAME (Argon large sign + icons) ---

		pub fn init() void {
			StorageServer.init();
			StorageClient.init();
			if (!main.settings.launchConfig.headlessServer) {
				pipeline = graphics.Pipeline.init(
					"assets/cubyz/shaders/block_entity/sign.vert",
					"assets/cubyz/shaders/block_entity/sign.frag",
					"",
					&uniforms,
					graphics.VertexArray.EmptyVertex,
					.{
						.rasterState = .{},
						.depthStencilState = .{.depthTest = true, .depthCompare = .equal, .depthWrite = false},
						.blendState = .{.attachments = &.{.alphaBlending}, .formats = &.{.world}},
					},
				);
				// --- ASHFRAME (Argon sign icons) ---
				iconPipeline = graphics.Pipeline.init(
					"assets/cubyz/shaders/block_entity/sign_icon.vert",
					"assets/cubyz/shaders/block_entity/sign_icon.frag",
					"",
					&iconUniforms,
					graphics.draw.SimpleVertex2D,
					.{
						.rasterState = .{.cullMode = .none},
						.depthStencilState = .{.depthTest = false, .depthWrite = false},
						.blendState = .{.attachments = &.{.alphaBlending}, .formats = &.{.world}},
						.inputAssemblyState = .{.topology = .triangleStrip},
					},
				);
				const quadVertices = [_]graphics.draw.SimpleVertex2D{
					.{.pos = .{0, 0}},
					.{.pos = .{0, 1}},
					.{.pos = .{1, 0}},
					.{.pos = .{1, 1}},
				};
				iconVao = .init(graphics.draw.SimpleVertex2D, &quadVertices, null);
				// --- ASHFRAME (Argon sign icons) ---
			}
		}
		pub fn deinit() void {
			while (textureDeinitList.popOrNull()) |texture| {
				texture.deinit();
			}
			textureDeinitList.deinit(main.globalAllocator);
			if (!main.settings.launchConfig.headlessServer) {
				pipeline.deinit();
				// --- ASHFRAME (Argon sign icons) ---
				iconPipeline.deinit();
				iconVao.deinit();
				// --- ASHFRAME (Argon sign icons) ---
			}
			StorageServer.deinit();
			StorageClient.deinit();
		}
		pub fn reset() void {
			StorageServer.reset();
			StorageClient.reset();
		}

		pub fn onUnloadClient(entity: BlockEntity) void {
			StorageClient.mutex.lock();
			defer StorageClient.mutex.unlock();
			const entry = StorageClient.removeAtIndex(entity).?;
			entry.deinit();
		}
		pub fn onUnloadServer(entity: BlockEntity) void {
			StorageServer.mutex.lock();
			defer StorageServer.mutex.unlock();
			const entry = StorageServer.removeAtIndex(entity).?;
			main.globalAllocator.free(entry.text);
		}

		pub fn onLoadClient(pos: Vec3i, chunk: *Chunk, reader: *BinaryReader) ErrorSet!void {
			return updateClientData(pos, chunk, .{.update = reader});
		}
		pub fn updateClientData(pos: Vec3i, chunk: *Chunk, event: UpdateEvent) ErrorSet!void {
			if (event == .remove or event.update.remaining.len == 0) {
				const entry = StorageClient.remove(pos, chunk) orelse return;
				entry.deinit();
				return;
			}

			StorageClient.mutex.lock();
			defer StorageClient.mutex.unlock();

			const data = StorageClient.getOrPut(pos, chunk);
			if (data.foundExisting) {
				data.valuePtr.deinit();
			}
			data.valuePtr.* = .{
				.blockPos = pos,
				.block = chunk.data.getValue(chunk.getLocalBlockPos(pos).toIndex()),
				.renderedTexture = null,
				.text = main.globalAllocator.dupe(u8, event.update.remaining),
			};
		}

		pub fn onLoadServer(pos: Vec3i, chunk: *Chunk, reader: *BinaryReader) ErrorSet!void {
			return updateServerData(pos, chunk, .{.update = reader});
		}
		pub fn updateServerData(pos: Vec3i, chunk: *Chunk, event: UpdateEvent) ErrorSet!void {
			if (event == .remove or event.update.remaining.len == 0) {
				const entry = StorageServer.remove(pos, chunk) orelse return;
				main.globalAllocator.free(entry.text);
				return;
			}

			StorageServer.mutex.lock();
			defer StorageServer.mutex.unlock();

			const newText = event.update.remaining;

			if (!std.unicode.utf8ValidateSlice(newText)) {
				std.log.err("Received sign text with invalid UTF-8 characters.", .{});
				return error.Invalid;
			}

			const data = StorageServer.getOrPut(pos, chunk);
			if (data.foundExisting) main.globalAllocator.free(data.valuePtr.text);
			data.valuePtr.text = main.globalAllocator.dupe(u8, event.update.remaining);
		}

		pub const onStoreServerToClient = onStoreServerToDisk;
		pub fn onStoreServerToDisk(entity: BlockEntity, writer: *BinaryWriter) void {
			StorageServer.mutex.lock();
			defer StorageServer.mutex.unlock();

			const data = StorageServer.getByIndex(entity) orelse return;
			writer.writeSlice(data.text);
		}
		pub fn getServerToClientData(pos: Vec3i, chunk: *Chunk, writer: *BinaryWriter) void {
			StorageServer.mutex.lock();
			defer StorageServer.mutex.unlock();

			const data = StorageServer.get(pos, chunk) orelse return;
			writer.writeSlice(data.text);
		}

		pub fn getClientToServerData(pos: Vec3i, chunk: *Chunk, writer: *BinaryWriter) void {
			StorageClient.mutex.lock();
			defer StorageClient.mutex.unlock();

			const data = StorageClient.get(pos, chunk) orelse return;
			writer.writeSlice(data.text);
		}

		pub fn updateTextFromClient(pos: Vec3i, newText: []const u8) void {
			{
				const mesh = main.renderer.mesh_storage.getMesh(.initFromWorldPos(pos, 1)) orelse return;
				mesh.mutex.lock();
				defer mesh.mutex.unlock();
				const localPos = mesh.chunk.getLocalBlockPos(pos);
				const block = mesh.chunk.data.getValue(localPos.toIndex());
				const blockEntity = block.blockEntity() orelse return;
				if (!std.mem.eql(u8, blockEntity.id, "cubyz:sign")) return;

				StorageClient.mutex.lock();
				defer StorageClient.mutex.unlock();

				const data = StorageClient.getOrPut(pos, mesh.chunk);
				if (data.foundExisting) {
					data.valuePtr.deinit();
				}
				data.valuePtr.* = .{
					.blockPos = pos,
					.block = mesh.chunk.data.getValue(localPos.toIndex()),
					.renderedTexture = null,
					.text = main.globalAllocator.dupe(u8, newText),
				};
			}

			main.network.protocols.blockEntityUpdate.sendClientDataUpdateToServer(main.game.world.?.conn, pos);
		}

		pub fn renderAll(ambientLight: Vec3f) void {
			var oldFramebufferBinding: c_int = undefined;
			c.glGetIntegerv(c.GL_DRAW_FRAMEBUFFER_BINDING, &oldFramebufferBinding);

			StorageClient.mutex.lock();
			defer StorageClient.mutex.unlock();

			for (StorageClient.storage.dense.items) |*signData| {
				if (signData.renderedTexture != null) continue;

				// Generate any needed item icons first: that rebinds the
				// framebuffer/viewport, so it must happen before the sign
				// FBO is bound below.
				pregenerateIcons(signData.text);

				// --- ASHFRAME (Argon large sign): canvas follows block. ---
				const largeSign = isLargeSign(signData.block);
				const canvasW: c_int = if (largeSign) largeTextureWidth else textureWidth;
				const canvasH: c_int = if (largeSign) largeTextureHeight else textureHeight;
				// --- ASHFRAME (Argon large sign) ---

				var oldViewport: [4]c_int = undefined;
				c.glGetIntegerv(c.GL_VIEWPORT, &oldViewport);
				c.glViewport(0, 0, canvasW, canvasH);
				defer c.glViewport(oldViewport[0], oldViewport[1], oldViewport[2], oldViewport[3]);

				var finalFrameBuffer: graphics.FrameBuffer = undefined;
				finalFrameBuffer.init(false, c.GL_NEAREST, c.GL_REPEAT);
				finalFrameBuffer.updateSize(@intCast(canvasW), @intCast(canvasH), c.GL_RGBA8);
				finalFrameBuffer.bind();
				finalFrameBuffer.clear(.{0, 0, 0, 0});
				signData.renderedTexture = .{.textureID = finalFrameBuffer.texture, .vulkanImage = null};
				defer c.glDeleteFramebuffers(1, &finalFrameBuffer.frameBuffer);

				// --- ASHFRAME (Argon large sign + icons): per-line layout so
				// quantity lines ("-12x ruby") draw the item icon after the
				// qty text. Large signs get a bigger canvas + font; normal
				// signs keep stock dimensions. One-time per sign (cached). ---
				const large = isLargeSign(signData.block);
				const texW: f32 = if (large) largeTextureWidth else textureWidth;
				const texH: f32 = if (large) largeTextureHeight else textureHeight;
				const font: f32 = if (large) largeFontSize else stockFontSize;
				const oldTranslation = graphics.draw.setTranslation(.{textureMargin, textureMargin});
				defer graphics.draw.restoreTranslation(oldTranslation);
				const oldClip = graphics.draw.setClip(.{texW - 2*textureMargin, texH - 2*textureMargin});
				defer graphics.draw.restoreClip(oldClip);

				// Stock anchors at the top (y=0) advancing one font per line;
				// centering here pushed content down and clipped it.
				const lineH = font;
				var y: f32 = 0;
				var lineIt = std.mem.splitScalar(u8, signData.text, '\n');
				while (lineIt.next()) |line| {
					if (parseQtyLine(line)) |qty| {
						const iconItem = itemForName(qty.item) orelse null;
						if (iconItem) |it_| {
							if (iconTextureFor(it_)) |icon| {
								var prefixBuf = graphics.TextBuffer.init(main.stackAllocator, qty.prefix, .{.color = 0x000000}, false, .left);
								defer prefixBuf.deinit();
								const prefixSize = prefixBuf.calculateLineBreaks(font, texW - 2*textureMargin);
								prefixBuf.renderTextWithoutShadow(0, y, font);
								const iconSize: f32 = font;
								drawIcon(icon, prefixSize[0] + 2, y + (lineH - iconSize)/2, iconSize, texW - 2*textureMargin, texH - 2*textureMargin);
								y += lineH;
								continue;
							}
						}
					}
					var lineBuf = graphics.TextBuffer.init(main.stackAllocator, line, .{.color = 0x000000}, false, .center);
					defer lineBuf.deinit();
					const lineSize = lineBuf.calculateLineBreaks(font, texW - 2*textureMargin);
					lineBuf.renderTextWithoutShadow((texW - 2*textureMargin - lineSize[0])/2, y, font);
					y += lineH;
				}
				// --- ASHFRAME (Argon large sign + icons) ---
			}

			c.glBindFramebuffer(c.GL_FRAMEBUFFER, @bitCast(oldFramebufferBinding));

			pipeline.bind(null);
			main.renderer.chunk_meshing.vao.bind();

			c.glUniform3f(uniforms.ambientLight, ambientLight[0], ambientLight[1], ambientLight[2]);

			outer: for (StorageClient.storage.dense.items) |signData| {
				if (main.blocks.meshes.model(signData.block).model().internalQuads.len == 0) continue;
				const quad = main.blocks.meshes.model(signData.block).model().internalQuads[0];

				signData.renderedTexture.?.bindTo(0);

				c.glUniform1i(uniforms.quadIndex, @intFromEnum(quad));
				const mesh = main.renderer.mesh_storage.getMesh(main.chunk.ChunkPosition.initFromWorldPos(signData.blockPos, 1)) orelse continue :outer;
				const light: [4]u32 = main.renderer.lighting.getLight(mesh, signData.blockPos -% Vec3i{mesh.pos.wx, mesh.pos.wy, mesh.pos.wz}, 0, quad);
				c.glUniform4ui(uniforms.lightData, light[0], light[1], light[2], light[3]);
				c.glUniform3i(uniforms.chunkPos, signData.blockPos[0] & ~main.chunk.chunkMask, signData.blockPos[1] & ~main.chunk.chunkMask, signData.blockPos[2] & ~main.chunk.chunkMask);
				c.glUniform3i(uniforms.blockPos, signData.blockPos[0] & main.chunk.chunkMask, signData.blockPos[1] & main.chunk.chunkMask, signData.blockPos[2] & main.chunk.chunkMask);

				c.glDrawElements(c.GL_TRIANGLES, 6, c.GL_UNSIGNED_INT, null);
			}
		}
	};
};

var blockyEntityTypes: std.StringHashMapUnmanaged(BlockEntityType) = .{};

pub fn init() void {
	inline for (@typeInfo(BlockEntityTypes).@"struct".decls) |declaration| {
		const class = BlockEntityType.init(@field(BlockEntityTypes, declaration.name), declaration.name);
		blockyEntityTypes.putNoClobber(main.globalAllocator.allocator, class.id, class) catch unreachable;
		std.log.debug("Registered BlockEntityType '{s}'", .{class.id});
	}
}

pub fn reset() void {
	inline for (@typeInfo(BlockEntityTypes).@"struct".decls) |declaration| {
		@field(BlockEntityTypes, declaration.name).reset();
	}
	BlockEntity.reset();
}

pub fn deinit() void {
	inline for (@typeInfo(BlockEntityTypes).@"struct".decls) |declaration| {
		@field(BlockEntityTypes, declaration.name).deinit();
	}
	BlockEntity.globalDeinit();
	blockyEntityTypes.deinit(main.globalAllocator.allocator);
}

pub fn getByID(_id: ?[]const u8) ?*const BlockEntityType {
	const id = _id orelse return null;
	if (blockyEntityTypes.getPtr(id)) |cls| return cls;
	std.log.err("BlockEntityType with id '{s}' not found", .{id});
	return null;
}

pub fn renderAll(ambientLight: Vec3f) void {
	inline for (@typeInfo(BlockEntityTypes).@"struct".decls) |declaration| {
		@field(BlockEntityTypes, declaration.name).renderAll(ambientLight);
	}
}
