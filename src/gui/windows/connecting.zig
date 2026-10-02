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
/// Last text we pushed to the label + last load fraction, so we only rebuild
/// the TextBuffer when it actually changes (avoids per-frame churn).
var loadStatusText: []const u8 = "";
var loadFraction: f32 = 0;
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
	loadStatusText = "";
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

/// Fullscreen loading overlay drawn on top of everything while the world is
/// not revealed: a dark backdrop, the centered status text (drawn by the
/// window) and a progress bar. Called from the GUI pass so it survives even
/// once the connecting window itself is a small modal.
pub fn renderOverlay() void {
	if (main.ashframe_client.isWorldRevealed()) return;
	const screen = main.Window.getWindowSize();
	const draw = main.graphics.draw;
	// Dim the whole screen so the backdrop/world behind is not distracting.
	const oldColor = draw.setColor(0xc0000000);
	defer draw.restoreColor(oldColor);
	draw.rect(.{0, 0}, screen);
	// Progress bar near the bottom center.
	const barW = @min(screen[0]*0.5, 420);
	const barH: f32 = 12;
	const barX = (screen[0] - barW)/2;
	const barY = screen[1]*0.72;
	// Track.
	{
		const trackColor = draw.setColor(0x40ffffff);
		defer draw.restoreColor(trackColor);
		draw.rect(.{barX, barY}, .{barW, barH});
	}
	// Fill.
	const frac = @min(@max(loadFraction, 0), 1);
	if (frac > 0) {
		const fillColor = draw.setColor(0xff00d0a0);
		defer draw.restoreColor(fillColor);
		draw.rect(.{barX, barY}, .{barW*frac, barH});
	}
	// Percentage text centered just above the bar.
	var pctBuf: [16]u8 = undefined;
	const pct = std.fmt.bufPrint(&pctBuf, "{d:.0}%", .{frac*100}) catch "0%";
	var pctLabel = Label.init(.{screen[0]/2 - 24, barY - 22}, 64, pct, .center);
	defer pctLabel.deinit();
	pctLabel.render(.{0, 0});
}

pub fn update() void {
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
				if (statusLabel) |lbl| lbl.updateText("Loading lightmaps...");
				state.store(.warming, .release);
			} else {
				finishConnect();
			}
			// --- ASHFRAME CUSTOM CLIENT ---
		},
		.warming => {
			// --- ASHFRAME CUSTOM CLIENT: reveal when the prefetch is
			// done AND the first serve pass ran plus a grace AND the
			// near lightmap fragments are actually resident (measured,
			// not guessed) — or the cap elapses. The cap is measured
			// from the first evaluation so render stalls before it
			// don't eat the budget. ---
			const nowMs = main.timestamp().toMilliseconds();
			if (warmT0 == 0) warmT0 = nowMs;
			const pp = main.game.Player.getPosBlocking();
			const cov = main.renderer.mesh_storage.nearLightCoverage(@as(i32, @intFromFloat(pp[0])), @as(i32, @intFromFloat(pp[1])));
			const covered = cov.total == 0 or cov.resident*10 >= cov.total*9;
			// Single source of truth for progress + stage (shared with the
			// overlay's bar and the render gate).
			const status = main.ashframe_client.loadStatus(nowMs, covered, cov.resident, cov.total);
			loadFraction = status.fraction;
			// Only rebuild the label text when the stage text changes.
			const stageText: []const u8 = switch (status.stage) {
				.connecting => "Connecting...",
				.assets => "Loading assets...",
				.lightmaps => "Loading lightmaps...",
				.time => "Syncing time...",
				.ready => "Ready!",
			};
			if (status.stage == .lightmaps and cov.total != 0) {
				var countBuf: [64]u8 = undefined;
				const txt = std.fmt.bufPrint(&countBuf, "Loading lightmaps... {d}/{d}", .{cov.resident, cov.total}) catch "Loading lightmaps...";
				if (!std.mem.eql(u8, txt, loadStatusText)) {
					loadStatusText = main.globalAllocator.dupe(u8, txt);
					if (statusLabel) |lbl| lbl.updateText(loadStatusText);
				}
			} else if (!std.mem.eql(u8, stageText, loadStatusText)) {
				loadStatusText = main.globalAllocator.dupe(u8, stageText);
				if (statusLabel) |lbl| lbl.updateText(loadStatusText);
			}
			const lit = status.stage == .ready;
			// Safety: if readiness never comes, reveal anyway after the cap
			// (a broken server must not trap the player forever).
			if (lit or nowMs -% warmT0 >= main.ashframe_client.warmCapMs) {
				finishConnect();
			}
			// --- ASHFRAME CUSTOM CLIENT ---
		},
		.failed => {
			if (connectFuture) |*future| {
				_ = future.await(main.io);
				connectFuture = null;
			}
			gui.closeWindowFromRef(&window);
			gui.windowlist.multiplayer_join.restoreConnection(connectionManager.?);
			main.gui.windowlist.notification.raiseNotification("Encountered error while opening world: {s}", .{errorMessage});
			errorMessage = "";
		},
		.cancelled => {
			gui.closeWindowFromRef(&window);
			gui.windowlist.multiplayer_join.restoreConnection(connectionManager.?);
		},
	}
}
