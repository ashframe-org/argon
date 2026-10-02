const std = @import("std");

const main = @import("main");
const graphics = main.graphics;
const draw = graphics.draw;
const Texture = graphics.Texture;
const Vec2f = main.vec.Vec2f;

const c = @import("c");

const gui = @import("../gui.zig");
const GuiWindow = gui.GuiWindow;
const GuiComponent = gui.GuiComponent;

pub const Samples = enum(u8) {
	screenbuffer_clear,
	clear,
	skybox,
	animation,
	chunk_rendering_preparation,
	chunk_rendering,
	entity_rendering,
	block_entity_rendering,
	particle_rendering,
	transparent_rendering_preparation,
	transparent_rendering,
	bloom_extract_downsample,
	bloom_first_pass,
	bloom_second_pass,
	final_copy,
	gui,
};

const names = [_][]const u8{
	"Screenbuffer clear",
	"Clear",
	"Skybox",
	"Pre-processing Block Animations",
	"Chunk Rendering Preparation",
	"Chunk Rendering",
	"Entity Rendering",
	"Block Entity Rendering",
	"Particle Rendering",
	"Transparent Rendering Preparation",
	"Transparent Rendering",
	"Bloom - Extract color and downsample",
	"Bloom - First Pass",
	"Bloom - Second Pass",
	"Copy to screen",
	"GUI Rendering",
};

const buffers = 4;
var curBuffer: u2 = 0;
var queryObjects: [buffers][@typeInfo(Samples).@"enum".fields.len]c_uint = undefined;

var activeSample: ?Samples = null;

pub fn init() void {
	for (&queryObjects) |*buf| {
		c.glGenQueries(buf.len, buf);
		for (buf) |queryObject| { // Start them to get an initial value.
			c.glBeginQuery(c.GL_TIME_ELAPSED, queryObject);
			c.glEndQuery(c.GL_TIME_ELAPSED);
		}
	}
}

pub fn deinit() void {
	c.glDeleteQueries(queryObjects.len*buffers, @ptrCast(&queryObjects));
}

pub fn startQuery(sample: Samples) void {
	std.debug.assert(activeSample == null); // There can be at most one active measurement at a time.
	activeSample = sample;
	c.glBeginQuery(c.GL_TIME_ELAPSED, queryObjects[curBuffer][@intFromEnum(sample)]);
}

pub fn stopQuery() void {
	std.debug.assert(activeSample != null); // There must be an active measurement to stop.
	activeSample = null;
	c.glEndQuery(c.GL_TIME_ELAPSED);
}

pub var window = GuiWindow{
	.relativePosition = .{
		.{.attachedToFrame = .{.selfAttachmentPoint = .upper, .otherAttachmentPoint = .upper}},
		.{.attachedToFrame = .{.selfAttachmentPoint = .lower, .otherAttachmentPoint = .lower}},
	},
	.contentSize = Vec2f{256, 16},
	.isHud = false,
	.showTitleBar = false,
	.hasBackground = false,
	.hideIfMouseIsGrabbed = false,
};

pub fn render() void {
	curBuffer +%= 1;
	var sum: isize = 0;
	var y: f32 = 8;
	inline for (0..queryObjects[curBuffer].len) |i| {
		var result: u32 = undefined;
		c.glGetQueryObjectuiv(queryObjects[curBuffer][i], c.GL_QUERY_RESULT, &result);
		draw.print("{s}: {} µs", .{names[i], @divTrunc(result, 1000)}, 0, y, 8);
		sum += result;
		y += 8;
	}
	draw.print("Total: {} µs", .{@divTrunc(sum, 1000)}, 0, 0, 8);

	// --- ASHFRAME CUSTOM CLIENT (perf): CPU render-thread scopes + counters.
	// Only populated when `ashframeDebug` is on (the profiler is gated there),
	// so this section is blank otherwise. Shown in the same window to keep
	// CPU vs GPU costs side by side at RD5/RD12, idle/moving. ---
	if (main.ashframe_client.profEnabled()) {
		y += 8;
		draw.print("#ffff00-- CPU (render thread, last frame) --", .{}, 0, y, 8);
		y += 8;
		const snap = main.ashframe_client.profSnapshot();
		const framesDiv: i64 = @max(1, @as(i64, snap.frameCount));
		draw.print("FPS(CPU): {d:.0}  frame {d} µs x{d}", .{
			if (snap.frameUs > 0) @as(f32, @floatFromInt(snap.frameCount))*1_000_000.0/@as(f32, @floatFromInt(snap.frameUs)) else 0,
			@divTrunc(snap.frameUs, framesDiv),
			snap.frameCount,
		}, 0, y, 8);
		y += 8;
		for (std.enums.values(main.ashframe_client.Scope)) |scope| {
			const idx = @intFromEnum(scope);
			if (scope == .relightCalls) {
				draw.print("{s}: {}", .{main.ashframe_client.profScopeName(scope), snap.count[idx]}, 0, y, 8);
			} else {
				draw.print("{s}: {d} µs x{d}", .{main.ashframe_client.profScopeName(scope), @divTrunc(snap.us[idx], 1000), snap.count[idx]}, 0, y, 8);
			}
			y += 8;
		}
	}
}
