// --- ASHFRAME (shared name cleaner) ---
// One purpose-built "clean name" routine used by the game (nametags, player
// list, chat, sign owners, veteran badges, @mention matching) and by the
// external Discord relay bot, so every surface agrees on the visible name.
//
// "Clean name" = exactly what the Cubyz text renderer (graphics.zig Parser)
// shows for a decorated name: colour codes and *~_ markdown are consumed,
// escapes resolved, and the literal visible characters kept. It is NOT a
// cosmetic strip-all-symbols: lone '~'/'_' survive (the parser keeps them),
// only their doubled forms are controls.
//
// Self-contained: depends on std only, so it compiles standalone for tests
// and can be ported verbatim to the relay bot.

const std = @import("std");

fn isHex(c: u8) bool {
	return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// True if the 6 bytes at s[0..6] are all hex (caller ensures len >= 6).
fn isHex6(s: []const u8) bool {
	if (s.len < 6) return false;
	for (s[0..6]) |c| {
		if (!isHex(c)) return false;
	}
	return true;
}

/// Length in bytes of the UTF-8 codepoint starting at raw[i] (1..4).
/// Invalid bytes count as 1 (matches the oracle's derail behavior).
fn utf8Len(raw: []const u8, i: usize) usize {
	if (i >= raw.len) return 0;
	const c = raw[i];
	if (c < 0x80) return 1;
	if (c < 0xC2) return 1;
	if (c < 0xE0) return 2;
	if (c < 0xF0) return 3;
	if (c < 0xF5) return 4;
	return 1;
}

/// The engine's Parser, reduced to the visible text (no effects/colours).
/// This is the ORACLE: cleaner(raw) must equal this for every real name.
/// Mirrors graphics.zig:Parser bit-for-bit.
/// Verbatim port of graphics.zig Parser.parse, collecting the emitted
/// glyphs (appendGetNext) instead of building effects. This is the ORACLE:
/// identical control flow to the renderer. NOTE: countVisibleCharacters is
/// NOT the oracle — it eats '#' + 7 chars while parse eats '#' + 6,
/// so the counter disagrees with rendering on color codes.
pub fn engineVisible(text: []const u8, out: *std.array_list.Managed(u8)) !void {
	var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
	// appendControlGetNext: advance, load next. appendGetNext: emit + advance.
	var cur = it.nextCodepoint() orelse return;
	while (true) {
		switch (cur) {
			'*' => {
				cur = it.nextCodepoint() orelse return; // consume '*'
				if (cur == '*') {
					cur = it.nextCodepoint() orelse return; // consume 2nd
				}
				// else: italic; cur already holds the next content char
			},
			'_' => {
				// Parser peeks the next BYTE for '_' (not codepoint).
				const pb: u8 = if (it.i < text.len) text[it.i] else 0;
				if (pb == '_') {
					_ = it.nextCodepoint(); // consume 1st
					cur = it.nextCodepoint() orelse return; // consume 2nd
				} else {
					try appendUtf8(out, '_');
					cur = it.nextCodepoint() orelse return;
				}
			},
			'~' => {
				const pb: u8 = if (it.i < text.len) text[it.i] else 0;
				if (pb == '~') {
					_ = it.nextCodepoint();
					cur = it.nextCodepoint() orelse return;
				} else {
					try appendUtf8(out, '~');
					cur = it.nextCodepoint() orelse return;
				}
			},
			'\\' => {
				cur = it.nextCodepoint() orelse return; // consume '\'
				try appendUtf8(out, cur); // emit next literally
				cur = it.nextCodepoint() orelse return;
			},
			'#' => {
				// Consume '#' (already held) + exactly 6 following chars.
				cur = it.nextCodepoint() orelse return;
				var shift: u5 = 20;
				while (true) : (shift -= 4) {
					// (nibble value irrelevant for visibility)
					cur = it.nextCodepoint() orelse return;
					if (shift == 0) break;
				}
			},
			'§' => {
				// Consumed alone; a following '#rrggbb' is handled by '#'.
				cur = it.nextCodepoint() orelse return;
			},
			else => {
				try appendUtf8(out, cur);
				cur = it.nextCodepoint() orelse return;
			},
		}
	}
}

fn appendUtf8(out: *std.array_list.Managed(u8), cp: u21) !void {
	var buf: [4]u8 = undefined;
	const n = std.unicode.utf8Encode(cp, &buf) catch {
		// Lone byte from invalid input: emit as-is.
		if (cp <= 0xff) try out.append(@intCast(cp));
		return;
	};
	try out.appendSlice(buf[0..n]);
}

/// The cleaner: single-pass, byte-level, no BOM/codepoint decoding except
/// where the oracle needs it. Mirrors the oracle's visible output, then
/// collapses ASCII-space runs and trims ends. This is the DELIVERABLE
/// (relay bot ports this file's logic); engineVisible is only the check.
pub fn clean(raw: []const u8, alloc: std.mem.Allocator) ![]u8 {
	var out = std.array_list.Managed(u8).init(alloc);
	errdefer out.deinit();
	var i: usize = 0;
	var hashLeft: u8 = 0;
	var skipNext: bool = false; // second char of ** or ~~
	while (i < raw.len) {
		const c = raw[i];
		if (hashLeft > 0) {
			// Inside #rrggbb: consume exactly 6 CODEPOINTS after '#'
			// (the oracle counts codepoints, so ß counts as one).
			const l = utf8Len(raw, i);
			hashLeft -= 1;
			i += l;
			continue;
		}
		if (skipNext) {
			skipNext = false;
			i += 1;
			continue;
		}
		switch (c) {
			'*' => {
				if (i + 1 < raw.len and raw[i + 1] == '*') {
					i += 2; // bold toggle
				} else {
					i += 1; // italic
				}
			},
			'_' => {
				if (i + 1 < raw.len and raw[i + 1] == '_') {
					i += 2; // underline
				} else {
					try out.append('_');
					i += 1;
				}
			},
			'~' => {
				if (i + 1 < raw.len and raw[i + 1] == '~') {
					i += 2; // strikethrough
				} else {
					try out.append('~');
					i += 1;
				}
			},
			'\\' => {
				// Escape: emit the next whole codepoint literally.
				if (i + 1 < raw.len) {
					const l = utf8Len(raw, i + 1);
					try out.appendSlice(raw[i + 1 .. i + 1 + l]);
					i += 1 + l;
				} else {
					i += 1; // trailing backslash: dropped (oracle too)
				}
			},
			'#' => {
				hashLeft = 6;
				i += 1;
			},
			0xC2 => {
				// Possible § (U+00A7 = C2 A7): consume both, nothing emitted.
				if (i + 1 < raw.len and raw[i + 1] == 0xA7) {
					i += 2;
				} else {
					try out.append(c);
					i += 1;
				}
			},
			' ' => {
				if (out.items.len == 0 or out.items[out.items.len - 1] == ' ') {
					i += 1;
					continue;
				}
				try out.append(' ');
				i += 1;
			},
			else => {
				try out.append(c);
				i += 1;
			},
		}
	}
	while (out.items.len != 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
	return out.toOwnedSlice();
}

/// Visible text WITHOUT whitespace collapsing (used to diagnose mismatches).
/// Raw visible text (whitespace NOT collapsed) — the oracle output.
pub fn visibleOnly(raw: []const u8, alloc: std.mem.Allocator) ![]u8 {
	var vis = std.array_list.Managed(u8).init(alloc);
	errdefer vis.deinit();
	try engineVisible(raw, &vis);
	return vis.toOwnedSlice();
}
// --- ASHFRAME (shared name cleaner) ---

test "cleaner matches the engine parser for every real name" {
	const corpus = @import("names_corpus.zig").corpus;
	const alloc = std.testing.allocator;
	var mismatches: usize = 0;
	for (corpus) |raw| {
		const cleaned = try clean(raw, alloc);
		defer alloc.free(cleaned);
		const oracle = try visibleOnly(raw, alloc);
		defer alloc.free(oracle);
		var norm = std.array_list.Managed(u8).init(alloc);
		defer norm.deinit();
		for (oracle) |c| {
			if (c == ' ') {
				if (norm.items.len == 0 or norm.items[norm.items.len - 1] == ' ') continue;
			}
			try norm.append(c);
		}
		while (norm.items.len != 0 and norm.items[norm.items.len - 1] == ' ') _ = norm.pop();
		if (!std.mem.eql(u8, cleaned, norm.items)) {
			mismatches += 1;
			std.debug.print("MISMATCH raw={s} cleaned={s} engine={s}\n", .{ raw, cleaned, norm.items });
		}
	}
	try std.testing.expectEqual(@as(usize, 0), mismatches);
}

test "cleaner never leaves control syntax" {
	const corpus = @import("names_corpus.zig").corpus;
	const alloc = std.testing.allocator;
	for (corpus) |raw| {
		const cleaned = try clean(raw, alloc);
		defer alloc.free(cleaned);
		try std.testing.expect(std.mem.indexOfScalar(u8, cleaned, 0xC2) == null);
		var i: usize = 0;
		while (i < cleaned.len) : (i += 1) {
			if (cleaned[i] == '#' and i + 7 <= cleaned.len) {
				var allHex = true;
				for (cleaned[i + 1 .. i + 7]) |c| {
					if (!std.ascii.isHex(c)) allHex = false;
				}
				try std.testing.expect(!allHex);
			}
		}
	}
}
