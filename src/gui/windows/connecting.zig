const std = @import("std");

const main = @import("main");
const ConnectionManager = main.network.ConnectionManager;
const settings = main.settings;
const Vec2f = main.vec.Vec2f;

const gui = @import("../gui.zig");
const GuiWindow = gui.GuiWindow;
const Button = @import("../components/Button.zig");
const Label = @import("../components/Label.zig");
const VerticalList = @import("../components/VerticalList.zig");

pub var window = GuiWindow{
	.contentSize = Vec2f{128, 64},
	.hasBackground = true,
	.closeable = false,
};

const padding: f32 = 8;
const width: f32 = 280;

const State = enum(u8) { connecting, connected, warming, failed, cancelled };

var connectionManager: ?*ConnectionManager = null;
var ip: []const u8 = "";
var connectFuture: ?std.Io.Future(void) = null;
var handshakeZon: main.ZonElement = undefined;
var state: std.atomic.Value(State) = .init(.connecting);
var errorMessage: []const u8 = "";
// --- ASHFRAME CUSTOM CLIENT: reveal gate (status label + warm deadline). ---
var statusLabel: ?*Label = null;
var warmT0: i64 = 0;
/// Current overlay status text + progress fraction. Owned here (module-level)
/// so the fullscreen overlay can draw them independently of the connecting
/// window's lifetime.
/// Owned copy of the current status text (allocated); `"Connecting..."` and
/// the other literals are restored by assigning without freeing, so we track
/// whether the current value is ours to free.
var loadStatusText: []const u8 = "Connecting...";
var loadStatusOwned: bool = false;
var loadFraction: f32 = 0;
/// True before the measurable `.warming` phase (handshake + blocking asset
/// load). The bar then animates indeterminately so the player sees motion
/// even though we cannot measure progress during the main-thread freeze.
var loadIndeterminate: bool = true;
var barAnimT: f64 = 0;

/// Set the overlay status text, freeing the previous owned copy.
fn setLoadStatus(text: []const u8) void {
	if (loadStatusOwned) main.globalAllocator.free(loadStatusText);
	loadStatusText = main.globalAllocator.dupe(u8, text);
	loadStatusOwned = true;
	if (statusLabel) |lbl| lbl.updateText(loadStatusText);
}
// --- ASHFRAME CUSTOM CLIENT ---

fn connectFromNewThread() void {
	main.initThreadLocals();
	defer main.deinitThreadLocals();

	handshakeZon = main.game.testWorld.init(ip, connectionManager.?) catch |err| {
		if (err == error.Canceled) {
			state.store(.cancelled, .release);
		} else {
			errorMessage = @errorName(err);
			state.store(.failed, .release);
		}
		return;
	};
	state.store(.connected, .release);
}

pub fn start(_ip: []const u8, manager: *ConnectionManager) void {
	ip = main.globalAllocator.dupe(u8, _ip);
	// --- ASHFRAME CUSTOM CLIENT ---
	main.ashframe_client.noteDialAddress(_ip);
	// --- ASHFRAME CUSTOM CLIENT (clean join): keep the backdrop up until
	// the world is actually ready, so nothing jumps/flashes. ---
	main.ashframe_client.setWorldRevealed(false);
	if (loadStatusOwned) {
		main.globalAllocator.free(loadStatusText);
		loadStatusOwned = false;
	}
	loadStatusText = "Connecting...";
	loadFraction = 0;
	loadIndeterminate = true; // handshake/assets phase has no measurable % yet
	// --- ASHFRAME CUSTOM CLIENT (clean join) ---
	connectionManager = manager;
	state = .init(.connecting);
	gui.openModalWindowFromRef(&window);
	connectFuture = main.io.concurrent(connectFromNewThread, .{}) catch |err| blk: {
		std.log.err("Error spawning connect task: {s}. Doing it in the current thread instead.", .{@errorName(err)});
		connectFromNewThread();
		break :blk null;
	};
}

fn cancel() void {
	if (connectFuture) |*future| {
		_ = future.cancel(main.io);
		connectFuture = null;
	}
	// --- ASHFRAME CUSTOM CLIENT: cancel during warmup (session live). ---
	if (state.load(.acquire) == .warming) {
		main.ashframe_client.sessionEnd();
		state.store(.cancelled, .release);
	}
	// --- ASHFRAME CUSTOM CLIENT ---
}

pub fn onOpen() void {
	const list = VerticalList.init(.{padding, 16 + padding}, width, 16);
	// --- ASHFRAME CUSTOM CLIENT: keep the label for warmup status. ---
	statusLabel = Label.init(.{0, 0}, width, "Connecting...", .center);
	list.add(statusLabel.?);
	// --- ASHFRAME CUSTOM CLIENT ---
	list.add(Button.initText(.{0, 0}, 100, "Cancel", .{.onAction = .init(cancel)}));
	list.finish(.center);
	window.rootComponent = list.toComponent();
	window.contentSize = window.rootComponent.?.pos() + window.rootComponent.?.size() + @as(Vec2f, @splat(padding));
	gui.updateWindowPositions();
}

pub fn onClose() void {
	std.debug.assert(connectFuture == null);
	statusLabel = null;
	if (ip.len != 0) {
		main.globalAllocator.free(ip);
		ip = "";
	}
	if (window.rootComponent) |*comp| {
		comp.deinit();
	}
}

// --- ASHFRAME CUSTOM CLIENT: shared reveal path (warmed or timed out). ---
fn finishConnect() void {
	// --- ASHFRAME CUSTOM CLIENT (clean join): reveal the world only now,
	// once the load gate has passed. ---
	main.ashframe_client.setWorldRevealed(true);
	// --- ASHFRAME CUSTOM CLIENT (clean join) ---
	gui.closeWindowFromRef(&window);
	main.globalAllocator.free(settings.lastUsedIPAddress);
	settings.lastUsedIPAddress = main.globalAllocator.dupe(u8, ip);
	settings.save();
	for (gui.openWindows.items) |openWindow| {
		gui.closeWindowFromRef(openWindow);
	}
	gui.openHud();
}
// --- ASHFRAME CUSTOM CLIENT ---

/// Fullscreen loading backdrop drawn in RAW screen space (called before the
/// GUI scale is applied) so its pixel math is correct. It paints an opaque
/// backdrop over the still-rendering world and a progress bar; the connecting
/// window (status text + Cancel) renders on top. Reveal = this lifting once
/// finishConnect sets worldRevealed.
pub fn renderOverlay() void {
	if (main.ashframe_client.isWorldRevealed()) return;
	const screen = main.Window.getWindowSize();
	const draw = main.graphics.draw;
	// Opaque backdrop: hides the not-yet-ready world behind it. The world
	// keeps rendering underneath so chunks/lightmaps continue to load.
	const oldColor = draw.setColor(0xff10141a);
	defer draw.restoreColor(oldColor);
	draw.rect(.{0, 0}, screen);

	// Progress bar near the bottom. High contrast: light track + border +
	// bright fill, so it reads clearly on the dark backdrop.
	const barW = @min(screen[0]*0.5, 420);
	const barH: f32 = 16;
	const barX = (screen[0] - barW)/2;
	const barY = screen[1]*0.78;
	const border: f32 = 2;
	// Outer border (light gray).
	{
		const c0 = draw.setColor(0xffc8d0dc);
		defer draw.restoreColor(c0);
		draw.rect(.{barX - border, barY - border}, .{barW + 2*border, barH + 2*border});
	}
	// Track (solid mid gray - visible, unlike the old 25%-alpha white).
	{
		const c0 = draw.setColor(0xff37404f);
		defer draw.restoreColor(c0);
		draw.rect(.{barX, barY}, .{barW, barH});
	}
	// Fill: measurable fraction, or an animated indeterminate sweep.
	{
		const c0 = draw.setColor(0xff2ee6a6);
		defer draw.restoreColor(c0);
		if (loadIndeterminate) {
			// A ~30% wide band sweeping left->right, looping, clipped to the
			// track. Compute the visible intersection [lo, hi] with [barX, barX+barW].
			const bandW = barW*0.3;
			const span = barW + bandW;
			const t = @mod(barAnimT*0.06, 1.0);
			const x = barX - bandW + @as(f32, @floatCast(t))*span;
			const lo = @max(x, barX);
			const hi = @min(x + bandW, barX + barW);
			if (hi > lo) draw.rect(.{lo, barY}, .{hi - lo, barH});
		} else {
			const frac = @min(@max(loadFraction, 0), 1);
			if (frac > 0) draw.rect(.{barX, barY}, .{barW*frac, barH});
		}
	}
	// Percentage (or a "…" while indeterminate) centered below the bar.
	var pctBuf: [16]u8 = undefined;
	const pct: []const u8 = if (loadIndeterminate) "..." else std.fmt.bufPrint(&pctBuf, "{d:.0}%", .{@min(@max(loadFraction, 0), 1)*100}) catch "0%";
	var pctLabel = Label.init(.{barX + barW/2 - 32, barY + barH + 8}, 64, pct, .center);
	defer pctLabel.deinit();
	pctLabel.render(.{0, 0});
}

pub fn update() void {
	// Drive the indeterminate bar animation from wall time (only visible
	// during the pre-warming phase; cheap either way).
	barAnimT = @as(f64, @floatFromInt(main.timestamp().toMilliseconds()))*0.001;
	stateSwitch: switch (state.load(.acquire)) {
		.connecting => {},
		.connected => {
			if (connectFuture) |*future| {
				_ = future.await(main.io);
				connectFuture = null;
			}
			// --- ASHFRAME CUSTOM CLIENT: session starts BEFORE the asset/
			// texture work below, so the prefetch worker warms the read
			// cache concurrently on this thread's stall. Unwound on failure.
			main.ashframe_client.sessionStart();
			if (main.ashframe_client.isActive()) {
				if (handshakeZon.getChildOrNull("player")) |playerZon| {
					if (playerZon.get(main.vec.Vec3d, "position")) |pp| {
						main.ashframe_client.kickPrefetch(@as(i32, @intFromFloat(pp[0])), @as(i32, @intFromFloat(pp[1])), @as(i32, @intFromFloat(pp[2])));
					}
				}
			}
			main.game.testWorld.finishHandshake(handshakeZon) catch |err| {
				main.ashframe_client.sessionEnd();
				errorMessage = @errorName(err);
				state.store(.failed, .release);
				continue :stateSwitch .failed;
			};
			// --- ASHFRAME CUSTOM CLIENT: fallback kick (spawn parsed by
			// finishHandshake). First kick wins; then hold the reveal until
			// prefetch warms the read cache (or the cap elapses). ---
			{
				const pp = main.game.Player.getPosBlocking();
				main.ashframe_client.kickPrefetch(@as(i32, @intFromFloat(pp[0])), @as(i32, @intFromFloat(pp[1])), @as(i32, @intFromFloat(pp[2])));
			}
			if (main.ashframe_client.isActive()) {
				// Deadline anchors on first evaluation, not here: the
				// first world frames can stall on serve work, and that
				// stall must not consume the warmup cap.
				warmT0 = 0;
				loadIndeterminate = false; // now measurable
				setLoadStatus("Loading lightmaps...");
				state.store(.warming, .release);
			} else {
				finishConnect();
			}
			// --- ASHFRAME CUSTOM CLIENT ---
		},
		.warming => {
			// --- ASHFRAME CUSTOM CLIENT (clean join): the fullscreen overlay
			// (renderOverlay) draws the status text + bar. We only compute the
			// state here and reveal the world ONCE genuinely ready. If the
			// safety cap elapses first, we keep waiting (never reveal a
			// bare/mis-lit world) and just tell the player it's taking longer;
			// the Cancel button stays available as the escape hatch. ---
			const nowMs = main.timestamp().toMilliseconds();
			if (warmT0 == 0) warmT0 = nowMs;
			const pp = main.game.Player.getPosBlocking();
			const px: i32 = @intFromFloat(pp[0]);
			const py: i32 = @intFromFloat(pp[1]);
			const cov = main.renderer.mesh_storage.nearLightCoverage(px, py);
			const meshCov = main.renderer.mesh_storage.nearMeshCoverage(px, py, @intFromFloat(pp[2]));
			// Both lightmaps AND chunk meshes must be resident near spawn,
			// or the world reveals with visible holes.
			const covered = (cov.total == 0 or cov.resident*10 >= cov.total*9) and
				(meshCov.total == 0 or meshCov.resident*10 >= meshCov.total*9);
			const status = main.ashframe_client.loadStatus(nowMs, covered, cov.resident, cov.total, meshCov.resident, meshCov.total);
			loadFraction = status.fraction;
			// Stage text, unless we're past the cap (then the "taking longer"
			// hint stays up instead of being overwritten each frame).
			const pastCap = nowMs -% warmT0 >= main.ashframe_client.warmCapMs;
			var textBuf: [64]u8 = undefined;
			const stageText: []const u8 = if (pastCap)
				"Taking longer than usual..."
			else switch (status.stage) {
				.connecting => "Connecting...",
				.assets => "Loading assets...",
				.lightmaps => if (cov.total != 0)
					std.fmt.bufPrint(&textBuf, "Loading lightmaps... {d}/{d}", .{cov.resident, cov.total}) catch "Loading lightmaps..."
				else
					"Loading lightmaps...",
				.time => "Syncing time...",
				.ready => "Ready!",
			};
			if (!std.mem.eql(u8, stageText, loadStatusText)) {
				setLoadStatus(stageText);
			}
			if (status.stage == .ready) {
				finishConnect();
			}
			// --- ASHFRAME CUSTOM CLIENT ---
		},
		.failed => {
			if (connectFuture) |*future| {
				_ = future.await(main.io);
				connectFuture = null;
			}
			// Reveal so the opaque loading overlay lifts even on failure,
			// otherwise the menu would stay hidden behind it.
			main.ashframe_client.setWorldRevealed(true);
			gui.closeWindowFromRef(&window);
			gui.windowlist.multiplayer_join.restoreConnection(connectionManager.?);
			main.gui.windowlist.notification.raiseNotification("Encountered error while opening world: {s}", .{errorMessage});
			errorMessage = "";
		},
		.cancelled => {
			// Reveal so the opaque loading overlay lifts and the menu is
			// usable again after a cancel.
			main.ashframe_client.setWorldRevealed(true);
			gui.closeWindowFromRef(&window);
			gui.windowlist.multiplayer_join.restoreConnection(connectionManager.?);
		},
	}
}
