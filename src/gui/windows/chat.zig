const std = @import("std");

const main = @import("main");
const Vec2f = main.vec.Vec2f;

const gui = @import("../gui.zig");
const GuiComponent = gui.GuiComponent;
const GuiWindow = gui.GuiWindow;
const Button = @import("../components/Button.zig");
const Label = GuiComponent.Label;
const TextInput = GuiComponent.TextInput;
const VerticalList = @import("../components/VerticalList.zig");
const FixedSizeCircularBuffer = main.utils.FixedSizeCircularBuffer;

pub var window: GuiWindow = GuiWindow{
	.relativePosition = .{
		.{.attachedToFrame = .{.selfAttachmentPoint = .lower, .otherAttachmentPoint = .lower}},
		.{.attachedToFrame = .{.selfAttachmentPoint = .upper, .otherAttachmentPoint = .upper}},
	},
	.scale = 0.75,
	.contentSize = Vec2f{128, 256},
	.showTitleBar = false,
	.hasBackground = false,
	.isHud = true,
	.hideIfMouseIsGrabbed = false,
	.closeable = false,
};

const padding: f32 = 8;
const messageTimeout: i32 = 10000;
const messageFade = 1000;
const reusableHistoryMaxSize = 8192;

var history: main.ListManaged(*Label) = undefined;
var messageQueue: main.utils.ConcurrentQueue([]const u8) = undefined;
var expirationTime: main.ListManaged(i32) = undefined;
var historyStart: u32 = 0;
var fadeOutEnd: u32 = 0;
pub var input: *TextInput = undefined;
var hideInput: bool = true;
var messageHistory: History = undefined;

pub const History = struct {
	up: FixedSizeCircularBuffer([]const u8, reusableHistoryMaxSize),
	down: FixedSizeCircularBuffer([]const u8, reusableHistoryMaxSize),

	fn init() History {
		return .{
			.up = .init(main.globalAllocator),
			.down = .init(main.globalAllocator),
		};
	}
	fn deinit(self: *History) void {
		self.clear();
		self.up.deinit(main.globalAllocator);
		self.down.deinit(main.globalAllocator);
	}
	fn clear(self: *History) void {
		while (self.up.popFront()) |msg| {
			main.globalAllocator.free(msg);
		}
		while (self.down.popFront()) |msg| {
			main.globalAllocator.free(msg);
		}
	}
	fn flushUp(self: *History) void {
		while (self.down.popBack()) |msg| {
			if (msg.len == 0) {
				continue;
			}

			if (self.up.forcePushBack(msg)) |old| {
				main.globalAllocator.free(old);
			}
		}
	}
	pub fn isDuplicate(self: *History, new: []const u8) bool {
		if (new.len == 0) return true;
		if (self.down.peekBack()) |msg| {
			if (std.mem.eql(u8, msg, new)) return true;
		}
		if (self.up.peekBack()) |msg| {
			if (std.mem.eql(u8, msg, new)) return true;
		}
		return false;
	}
	pub fn pushDown(self: *History, new: []const u8) void {
		if (self.down.forcePushBack(new)) |old| {
			main.globalAllocator.free(old);
		}
	}
	pub fn pushUp(self: *History, new: []const u8) void {
		if (self.up.forcePushBack(new)) |old| {
			main.globalAllocator.free(old);
		}
	}
	pub fn cycleUp(self: *History) bool {
		if (self.down.popBack()) |msg| {
			self.pushUp(msg);
			return true;
		}
		return false;
	}
	pub fn cycleDown(self: *History) void {
		if (self.up.popBack()) |msg| {
			self.pushDown(msg);
		}
	}
};

pub fn clearChat() void {
	while (history.popOrNull()) |label| {
		label.deinit();
	}
	historyStart = 0;
	fadeOutEnd = 0;
	expirationTime.clearRetainingCapacity();
	refresh();
}

pub fn init() void {
	history = .init(main.globalAllocator);
	messageHistory = .init();
	expirationTime = .init(main.globalAllocator);
	messageQueue = .init(main.globalAllocator, 16);
}

pub fn deinit() void {
	for (history.items) |label| {
		label.deinit();
	}
	history.deinit();
	while (messageQueue.popFront()) |msg| {
		main.globalAllocator.free(msg);
	}
	messageHistory.deinit();
	messageQueue.deinit();
	expirationTime.deinit();
}

fn refresh() void {
	if (window.rootComponent) |old| {
		old.verticalList.children.clearRetainingCapacity();
		old.deinit();
	}
	const list = VerticalList.init(.{padding, 16 + padding}, 300, 0);
	for (history.items[if (hideInput) historyStart else 0..]) |msg| {
		msg.pos = .{0, 0};
		list.add(msg);
	}
	if (!hideInput) {
		input.pos = .{0, 0};
		list.add(input);
	}
	list.finish(.center);
	list.scrollBar.currentState = 1;
	window.rootComponent = list.toComponent();
	window.contentSize = window.rootComponent.?.pos() + window.rootComponent.?.size() + @as(Vec2f, @splat(padding));
	window.contentSize[0] = @max(window.contentSize[0], window.getMinWindowWidth());
	gui.updateWindowPositions();
	if (!hideInput) {
		for (history.items) |label| {
			label.alpha = 1;
		}
	} else {
		list.scrollBar.currentState = 1;
		list.scrollBar.hidden = true;
	}
}

// --- ASHFRAME CUSTOM CLIENT: configurable chat width (px). ---
fn chatWidth() f32 {
	return @min(@max(main.settings.launchConfig.chatWidth, 256), 1200);
}
// --- ASHFRAME CUSTOM CLIENT ---

pub fn onOpen() void {
	input = TextInput.init(.{0, 0}, chatWidth(), 32, "", .{.onNewline = .init(sendMessage), .onUp = .init(loadNextHistoryEntry), .onDown = .init(loadPreviousHistoryEntry), .onTab = .init(completeCommand)});
	refresh();
}

pub fn loadNextHistoryEntry() void {
	const isSuccess = messageHistory.cycleUp();
	if (messageHistory.isDuplicate(input.currentString.items)) {
		if (isSuccess) messageHistory.cycleDown();
		messageHistory.cycleDown();
	} else {
		messageHistory.pushDown(main.globalAllocator.dupe(u8, input.currentString.items));
		messageHistory.cycleDown();
	}
	const msg = messageHistory.down.peekBack() orelse "";
	input.setString(msg);
}

pub fn loadPreviousHistoryEntry() void {
	_ = messageHistory.cycleUp();
	if (messageHistory.isDuplicate(input.currentString.items)) {} else {
		messageHistory.pushUp(main.globalAllocator.dupe(u8, input.currentString.items));
	}
	const msg = messageHistory.down.peekBack() orelse "";
	input.setString(msg);
}

pub fn onClose() void {
	clearChat();
	while (messageQueue.popFront()) |msg| {
		main.globalAllocator.free(msg);
	}
	messageHistory.clear();
	input.deinit();
	window.rootComponent.?.verticalList.children.clearRetainingCapacity();
	window.rootComponent.?.deinit();
	window.rootComponent = null;
}

pub fn update() void {
	if (!messageQueue.isEmpty()) {
		const currentTime: i32 = @truncate(main.timestamp().toMilliseconds());
		while (messageQueue.popFront()) |msg| {
			history.append(Label.init(.{0, 0}, chatWidth(), msg, .left));
			main.globalAllocator.free(msg);
			expirationTime.append(currentTime +% messageTimeout);
		}
		refresh();
	}

	const currentTime: i32 = @truncate(main.timestamp().toMilliseconds());
	while (fadeOutEnd < history.items.len and currentTime -% expirationTime.items[fadeOutEnd] >= 0) {
		fadeOutEnd += 1;
	}
	if (hideInput != main.Window.grabbed) {
		hideInput = main.Window.grabbed;
		refresh();
	}
	if (hideInput) {
		for (expirationTime.items[historyStart..fadeOutEnd], history.items[historyStart..fadeOutEnd]) |time, label| {
			if (currentTime -% time >= messageFade) {
				historyStart += 1;
				refresh();
			} else {
				const timeDifference: f32 = @floatFromInt(currentTime -% time);
				label.alpha = 1.0 - timeDifference/messageFade;
			}
		}
	}
}

pub fn render() void {
	if (!hideInput) {
		const oldColor = main.graphics.draw.setColor(0x80000000);
		defer main.graphics.draw.restoreColor(oldColor);
		main.graphics.draw.rect(.{0, 0}, window.contentSize);
	}
}

pub fn addMessage(msg: []const u8) void {
	messageQueue.pushBack(main.globalAllocator.dupe(u8, msg));
}

// --- ASHFRAME CUSTOM CLIENT: command tab-completion. ---
// Names mirror the Ashframe server command set; completion is purely local
// (no protocol change), so it works on any server and never affects vanilla.
const commandNames = [_][]const u8{
	"clear",      "gamemode", "help",     "invite",   "kick",      "kill",     "particles", "seed",     "server", "spawn",
	"tickspeed",  "time",     "tp",       "whitelist", "home",     "tpa",      "tpaccept",  "back",     "players", "playtime",
	"stats",      "afk",      "prefix",   "tpdeny",   "msg",       "claim",    "alliance",  "sethome",  "delhome", "homes",
	"waypoint",   "unban",    "unstrike", "ban",      "bans",      "skyscan",  "eat",       "titles",   "title",   "veteran",
	"shop",       "report",   "avatar",   "group",    "perm",      "undo",     "redo",      "pos1",     "pos2",    "deselect",
	"copy",       "count",    "paste",    "blueprint", "rotate",   "set",      "mask",      "replace",  "toggledecay",
};

/// Called on Tab while the chat input is focused. If the input is a command
/// (`/...`) and the first word is an unambiguous prefix, complete it.
fn completeCommand() void {
	const text = input.currentString.items;
	if (text.len == 0 or text[0] != '/') return;
	const body = text[1..];
	const end = std.mem.indexOfScalar(u8, body, ' ') orelse body.len;
	if (end == 0) return; // just "/": nothing to complete
	const word = body[0..end];
	// Only complete the command word (leave arguments alone for now).
	if (end != body.len) return;
	var match: ?[]const u8 = null;
	var count: usize = 0;
	for (commandNames) |cmd| {
		if (std.mem.startsWith(u8, cmd, word)) {
			match = cmd;
			count += 1;
		}
	}
	if (count == 1) {
		const completed = main.stackAllocator.print("/{s}", .{match.?});
		defer main.stackAllocator.free(completed);
		input.setString(completed);
	} else if (count > 1) {
		// Ambiguous: list the options in chat so the player can narrow down.
		var list: main.ListManaged(u8) = .init(main.stackAllocator);
		defer list.deinit();
		list.appendSlice("#8a8a8aCommands: #cfcfcf");
		for (commandNames) |cmd| {
			if (!std.mem.startsWith(u8, cmd, word)) continue;
			list.appendSlice(cmd);
			list.append(' ');
		}
		addMessage(list.items);
	}
}
// --- ASHFRAME CUSTOM CLIENT ---

pub fn sendMessage() void {
	if (input.currentString.items.len != 0) {
		const data = input.currentString.items;
		if (data.len > 10000 or main.graphics.TextBuffer.Parser.countVisibleCharacters(data) > 1000) {
			std.log.err("Chat message is too long with {}/{} characters. Limits are 1000/10000", .{main.graphics.TextBuffer.Parser.countVisibleCharacters(data), data.len});
		} else {
			messageHistory.flushUp();
			if (!messageHistory.isDuplicate(data)) {
				messageHistory.pushUp(main.globalAllocator.dupe(u8, data));
			}

			if (input.currentString.items[0] == '/') {
				main.sync.client.executeCommand(.{.chatCommand = .{.message = main.globalAllocator.dupe(u8, input.currentString.items[1..])}});
			} else {
				main.network.protocols.chat.send(main.game.world.?.conn, data);
			}
			input.clear();
		}
	}
}
