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
const graphics = main.graphics;
const Texture = graphics.Texture;

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
/// Current overlay status text. Owned here (module-level) so the fullscreen
/// overlay can draw it independently of the connecting window's lifetime.
/// Owned copy: allocated via setLoadStatus; freed on the next change/reset.
var loadStatusText: []const u8 = "Connecting...";
var loadStatusOwned: bool = false;
var loadFraction: f32 = 0;
/// True before the measurable `.warming` phase (handshake + blocking asset
/// load). The bar then animates indeterminately so the player sees motion
/// even though we cannot measure progress during the main-thread freeze.
var loadIndeterminate: bool = true;
var barAnimT: f64 = 0;
/// The Cubyz logo shown on the loading screen (loaded lazily).
var logo: ?Texture = null;

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
	// --- ASHFRAME CUSTOM CLIENT (clean join): the connecting dialog handles
	// the handshake phase (as before). We only take over with the fullscreen
	// overlay once the handshake is done, to avoid any window/overlay overlap
	// flash. So worldRevealed stays true here. ---
	if (loadStatusOwned) {
		main.globalAllocator.free(loadStatusText);
		loadStatusOwned = false;
	}
	loadStatusText = "Connecting...";
	loadFraction = 0;
	loadIndeterminate = true; // handshake phase has no measurable % yet
	window.suppressRender = false; // show the dialog for the handshake phase
	// Persist the dial address now (while `ip` is valid): the dialog may be
	// closed early when the fullscreen overlay takes over, freeing `ip`.
	main.globalAllocator.free(settings.lastUsedIPAddress);
	settings.lastUsedIPAddress = main.globalAllocator.dupe(u8, _ip);
	settings.save();
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

/// Public so the overlay's own Cancel can call it.
pub fn requestCancel() void {
	cancel();
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
	window.suppressRender = false; // restore normal rendering for next time
	// --- ASHFRAME CUSTOM CLIENT (clean join) ---
	gui.closeWindowFromRef(&window);
	// lastUsedIPAddress is saved in start() (ip may be freed by then).
	for (gui.openWindows.items) |openWindow| {
		gui.closeWindowFromRef(openWindow);
	}
	gui.openHud();
}
// --- ASHFRAME CUSTOM CLIENT ---

/// Hide the small connecting dialog once the fullscreen overlay takes over.
/// IMPORTANT: we must NOT close the window - its update() drives the whole
/// load state machine (and is only called while it is open). Instead we
/// suppress only its rendering; it stays open and keeps updating underneath.
fn hideConnectingDialog() void {
	window.suppressRender = true;
}

/// Fullscreen loading screen drawn in RAW screen space (called before the GUI
/// scale is applied) so its pixel math is correct. Opaque backdrop hides the
/// still-rendering world; shows the Cubyz logo, a status + percentage line,
/// and a progress bar. Reveal = this lifting once finishConnect runs.
pub fn renderOverlay() void {
	if (!settings.launchConfig.ashframeLoadingScreen) return;
	if (main.ashframe_client.isWorldRevealed()) return;
	const screen = main.Window.getWindowSize();
	const draw = main.graphics.draw;
	// IMPORTANT: draw.setColor MULTIPLIES the current color, so every
	// element must be set from a known base. Force the base to plain white
	// first; otherwise the dark backdrop multiplies into every following
	// color (bar, fill, text) and everything renders near-black.
	const baseColor = draw.setColor(0xffffffff);
	defer draw.restoreColor(baseColor);
	// Opaque backdrop (hides the still-rendering, not-yet-ready world).
	{
		const c = draw.setColor(0xff10141a);
		draw.rect(.{0, 0}, screen);
		draw.restoreColor(c);
	}

	const centerX = screen[0]/2;

	// Logo, centered ~24% down, preserving aspect (852x240).
	if (logo == null) {
		logo = Texture.initFromFile("assets/cubyz/ui/bigcubyz.png");
	}
	if (logo) |tex| {
		const logoH: f32 = @min(screen[1]*0.18, 110);
		const logoW = logoH*(852.0/240.0);
		{
			const c = draw.setColor(0xffffffff);
			draw.image(tex, .{centerX - logoW/2, screen[1]*0.20}, .{logoW, logoH});
			draw.restoreColor(c);
		}
	}

	// Progress bar (high contrast: border + mid track + vivid fill).
	const barW = @min(screen[0]*0.5, 420);
	const barH: f32 = 16;
	const barX = centerX - barW/2;
	const barY = screen[1]*0.66;
	const border: f32 = 2;
	{
		const c = draw.setColor(0xffc8d0dc);
		draw.rect(.{barX - border, barY - border}, .{barW + 2*border, barH + 2*border});
		draw.restoreColor(c);
	}
	{
		const c = draw.setColor(0xff37404f);
		draw.rect(.{barX, barY}, .{barW, barH});
		draw.restoreColor(c);
	}
	{
		const c = draw.setColor(0xff2ee6a6);
		if (loadIndeterminate) {
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
		draw.restoreColor(c);
	}

	// One line under the bar: "Status… 42%" (or the status alone while the
	// fraction is indeterminate).
	var lineBuf: [128]u8 = undefined;
	const line: []const u8 = if (loadIndeterminate)
		loadStatusText
	else
		std.fmt.bufPrint(&lineBuf, "{s} {d:.0}%", .{loadStatusText, @min(@max(loadFraction, 0), 1)*100}) catch loadStatusText;
	var lineLabel = Label.init(.{centerX - 200, barY + barH + 10}, 400, line, .center);
	defer lineLabel.deinit();
	lineLabel.render(.{0, 0});

	// Hint that Cancel is available (Esc / the dialog's button remains).
	var hint = Label.init(.{centerX - 120, screen[1]*0.90}, 240, "Press Esc to cancel", .center);
	defer hint.deinit();
	hint.render(.{0, 0});
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
			if (main.ashframe_client.isActive() and settings.launchConfig.ashframeLoadingScreen) {
				// Handshake done -> now take over with the fullscreen overlay.
				// Close every other window first so nothing flashes over it.
				main.ashframe_client.setWorldRevealed(false);
				hideConnectingDialog();
				warmT0 = 0;
				loadIndeterminate = false; // now measurable
				setLoadStatus("Loading chunks...");
				state.store(.warming, .release);
			} else {
				// Clean-join screen disabled (or cache inactive): reveal
				// immediately, vanilla-style. The cache/prefetch still runs.
				finishConnect();
			}
			// --- ASHFRAME CUSTOM CLIENT ---
		},
		.warming => {
			// --- ASHFRAME CUSTOM CLIENT (clean join): the fullscreen overlay
			// draws the status + bar. We compute the state and reveal the world
			// ONCE genuinely ready; if the safety cap elapses first we keep
			// waiting (never reveal a bare/mis-lit world) and just say so. ---
			const nowMs = main.timestamp().toMilliseconds();
			if (warmT0 == 0) warmT0 = nowMs;
			const pp = main.game.Player.getPosBlocking();
			const px: i32 = @intFromFloat(pp[0]);
			const py: i32 = @intFromFloat(pp[1]);
			const cov = main.renderer.mesh_storage.nearLightCoverage(px, py);
			const meshCov = main.renderer.mesh_storage.nearMeshCoverage(px, py, @intFromFloat(pp[2]));
			const covered = (cov.total == 0 or cov.resident*10 >= cov.total*9) and
				(meshCov.total == 0 or meshCov.resident*10 >= meshCov.total*9);
			const status = main.ashframe_client.loadStatus(nowMs, covered, cov.resident, cov.total, meshCov.resident, meshCov.total);
			loadFraction = status.fraction;
			const pastCap = nowMs -% warmT0 >= main.ashframe_client.warmCapMs;
			const stageText: []const u8 = if (pastCap)
				"Taking longer than usual..."
			else switch (status.stage) {
				.connecting => "Waiting for handshake...",
				.assets => "Loading assets...",
				.lightmaps => "Loading chunks...",
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
			window.suppressRender = false;
			gui.closeWindowFromRef(&window);
			gui.windowlist.multiplayer_join.restoreConnection(connectionManager.?);
			main.gui.windowlist.notification.raiseNotification("Encountered error while opening world: {s}", .{errorMessage});
			errorMessage = "";
		},
		.cancelled => {
			// Reveal so the opaque loading overlay lifts and the menu is
			// usable again after a cancel.
			main.ashframe_client.setWorldRevealed(true);
			window.suppressRender = false;
			gui.closeWindowFromRef(&window);
			gui.windowlist.multiplayer_join.restoreConnection(connectionManager.?);
		},
	}
}
