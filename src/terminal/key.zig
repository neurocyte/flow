const std = @import("std");
const vaxis = @import("vaxis");

/// A key event action. Values match the kitty protocol's event-type encoding
/// (press+1 = 1, repeat+1 = 2, release+1 = 3).
pub const Event = enum(u8) { press = 0, repeat = 1, release = 2 };

pub fn encode(
    writer: *std.Io.Writer,
    key: vaxis.Key,
    event: Event,
    kitty_flags: vaxis.Key.KittyFlags,
    cursor_keys_app: bool,
    modify_other_keys: u8,
) !void {
    const flags: u5 = @bitCast(kitty_flags);
    if (flags != 0) return kitty(writer, key, event, kitty_flags, cursor_keys_app);
    // Legacy path: releases are not reported.
    if (event == .release) return;
    if (modify_other_keys >= 1 and try encodeModifyOtherKeys(writer, key, modify_other_keys))
        return;
    try legacy(writer, key, cursor_keys_app);
}

// Kitty keyboard protocol encoder

const FUNC_FIRST = 57344; // Unicode PUA start = GLFW_FKEY_FIRST
const FUNC_LAST = 57454; // iso_level_5_shift = last functional key
const MOD_FIRST = 57441; // left_shift
const MOD_LAST = 57454; // iso_level_5_shift

fn modifierValue(mods: vaxis.Key.Modifiers) u8 {
    var v: u8 = 0;
    if (mods.shift) v |= 1;
    if (mods.alt) v |= 2;
    if (mods.ctrl) v |= 4;
    if (mods.super) v |= 8;
    if (mods.hyper) v |= 16;
    if (mods.meta) v |= 32;
    if (mods.caps_lock) v |= 64;
    if (mods.num_lock) v |= 128;
    return v;
}

fn isModifierKey(cp: u21) bool {
    return cp >= MOD_FIRST and cp <= MOD_LAST;
}

fn isFunctional(cp: u21) bool {
    return kittyDef(cp) != null or (cp >= FUNC_FIRST and cp <= FUNC_LAST);
}

fn kittyDef(cp: u21) ?Definition {
    return switch (cp) {
        vaxis.Key.escape => escape,
        vaxis.Key.enter, vaxis.Key.kp_enter => enter,
        vaxis.Key.tab => tab,
        vaxis.Key.backspace => backspace,
        vaxis.Key.insert, vaxis.Key.kp_insert => insert,
        vaxis.Key.delete, vaxis.Key.kp_delete => delete,
        vaxis.Key.left, vaxis.Key.kp_left => left,
        vaxis.Key.right, vaxis.Key.kp_right => right,
        vaxis.Key.up, vaxis.Key.kp_up => up,
        vaxis.Key.down, vaxis.Key.kp_down => down,
        vaxis.Key.page_up, vaxis.Key.kp_page_up => page_up,
        vaxis.Key.page_down, vaxis.Key.kp_page_down => page_down,
        vaxis.Key.home, vaxis.Key.kp_home => home,
        vaxis.Key.end, vaxis.Key.kp_end => end,
        vaxis.Key.f1 => f1,
        vaxis.Key.f2 => f2,
        vaxis.Key.f3 => f3,
        vaxis.Key.f4 => f4,
        vaxis.Key.f5 => f5,
        vaxis.Key.f6 => f6,
        vaxis.Key.f7 => f7,
        vaxis.Key.f8 => f8,
        vaxis.Key.f9 => f9,
        vaxis.Key.f10 => f10,
        vaxis.Key.f11 => f11,
        vaxis.Key.f12 => f12,
        else => null,
    };
}

fn hasText(key: vaxis.Key) bool {
    const t = key.text orelse return false;
    return t.len > 0 and !(t[0] < 0x20 or t[0] == 0x7f);
}

fn encodeUtf8(writer: *std.Io.Writer, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return;
    try writer.writeAll(buf[0..n]);
}

const Encoding = struct {
    key: u21,
    shifted: u21 = 0,
    base_layout: u21 = 0,
    mods: u8, // raw bitmask
    event: Event,
    report_events: bool,
    add_alternates: bool = false,
    text: ?[]const u8 = null, // associated text (embed) or null
};

fn serialize(writer: *std.Io.Writer, e: Encoding, csi_trailer: u8) !void {
    const encoded_mods: u16 = @as(u16, e.mods) + 1;
    const has_mods = encoded_mods != 1;
    const add_actions = e.report_events and e.event != .press;
    // The shifted key is only meaningful while shift is held; the base layout
    // key stands on its own.
    const shifted: u21 = if (e.add_alternates and (e.mods & 1) != 0) e.shifted else 0;
    const base_layout: u21 = if (e.add_alternates) e.base_layout else 0;
    const add_text = e.text != null and e.text.?.len > 0;
    const second = has_mods or add_actions;
    const third = add_text;

    try writer.writeAll("\x1b[");
    if (e.key != 1 or e.add_alternates or second or third) try writer.print("{d}", .{e.key});
    if (e.add_alternates) {
        try writer.writeAll(":");
        if (shifted != 0) try writer.print("{d}", .{shifted});
        if (base_layout != 0) try writer.print(":{d}", .{base_layout});
    }
    if (second or third) {
        try writer.writeAll(";");
        if (second) try writer.print("{d}", .{encoded_mods});
        if (add_actions) try writer.print(":{d}", .{@intFromEnum(e.event) + 1});
    }
    if (third) {
        if (std.unicode.Utf8View.init(e.text.?)) |view| {
            var it = view.iterator();
            var first = true;
            while (it.nextCodepoint()) |c| {
                try writer.writeAll(if (first) ";" else ":");
                try writer.print("{d}", .{c});
                first = false;
            }
        } else |_| {}
    }
    try writer.writeByte(csi_trailer);
}

fn kitty(writer: *std.Io.Writer, key: vaxis.Key, event: Event, kf: vaxis.Key.KittyFlags, cursor_keys_app: bool) !void {
    const cp = key.codepoint;
    const report_all = kf.report_all_as_ctl_seqs; // kitty "report_text" flag (bit 3)
    const embed_text = kf.report_text; // kitty "embed_text" flag (bit 4)

    // Lone modifier keys are not reported unless all keys are reported.
    if (!report_all and isModifierKey(cp)) return;
    // A key that produces text just sends it, unless reporting all as escapes.
    if (!report_all and hasText(key) and event != .release) return writer.writeAll(key.text.?);
    // Releases require the report-event-types flag.
    if (event == .release and !kf.report_events) return;

    if (isFunctional(cp)) return kittyFunctional(writer, key, event, kf, cursor_keys_app);

    // Text key.
    const mods = modifierValue(key.mods);
    const has_mods = mods != 0;
    const shifted = key.shifted_codepoint orelse 0;
    const base_layout = key.base_layout_codepoint orelse 0;
    // Either alternate may be reported on its own: the shifted key when shift
    // is held, the base layout key whenever the active layout moved the key.
    const has_shifted = key.mods.shift and shifted != 0 and shifted != cp;
    const has_base_layout = base_layout != 0 and base_layout != cp;
    const add_alternates = kf.report_alternate_keys and (has_shifted or has_base_layout);
    const embed = embed_text and hasText(key) and event != .release;
    const add_actions = kf.report_events and event != .press;
    const simple = !add_actions and !add_alternates and !embed;

    if (simple and !has_mods) {
        if (report_all) return serialize(writer, .{ .key = cp, .mods = 0, .event = event, .report_events = kf.report_events }, 'u');
        return encodeUtf8(writer, cp);
    }
    if (simple and has_mods and !kf.disambiguate and !report_all) {
        // Disambiguation off: fall back to the legacy encoding.
        return legacy(writer, key, cursor_keys_app);
    }
    return serialize(writer, .{
        .key = cp,
        .shifted = shifted,
        .base_layout = base_layout,
        .mods = mods,
        .event = event,
        .report_events = kf.report_events,
        .add_alternates = add_alternates,
        .text = if (embed) key.text else null,
    }, 'u');
}

fn kittyFunctional(writer: *std.Io.Writer, key: vaxis.Key, event: Event, kf: vaxis.Key.KittyFlags, cursor_keys_app: bool) !void {
    const cp = key.codepoint;
    const mods = modifierValue(key.mods);
    const non_lock = mods & ~@as(u8, 64 | 128);
    const report_all = kf.report_all_as_ctl_seqs;
    const legacy_mode = !kf.report_events and !kf.disambiguate and !report_all;

    if (cursor_keys_app and legacy_mode and mods == 0) switch (cp) {
        vaxis.Key.up => return writer.writeAll("\x1bOA"),
        vaxis.Key.down => return writer.writeAll("\x1bOB"),
        vaxis.Key.right => return writer.writeAll("\x1bOC"),
        vaxis.Key.left => return writer.writeAll("\x1bOD"),
        vaxis.Key.end => return writer.writeAll("\x1bOF"),
        vaxis.Key.home => return writer.writeAll("\x1bOH"),
        else => {},
    };
    if (mods == 0 and legacy_mode) switch (cp) {
        vaxis.Key.f1 => return writer.writeAll("\x1bOP"),
        vaxis.Key.f2 => return writer.writeAll("\x1bOQ"),
        vaxis.Key.f3 => return writer.writeAll("\x1bOR"),
        vaxis.Key.f4 => return writer.writeAll("\x1bOS"),
        else => {},
    };
    if (mods == 0 and !kf.disambiguate and !report_all and cp == vaxis.Key.escape) return writer.writeAll("\x1b");
    // Enter/Tab/Backspace keep their control bytes unless all keys are reported.
    if (non_lock == 0 and !report_all and event != .release) switch (cp) {
        vaxis.Key.enter, vaxis.Key.kp_enter => return writer.writeAll("\r"),
        vaxis.Key.backspace => return writer.writeAll("\x7f"),
        vaxis.Key.tab => return writer.writeAll("\t"),
        else => {},
    };

    const def = kittyDef(cp);
    const number: u21 = if (def) |d| d.number else cp;
    const trailer: u8 = if (def) |d| d.suffix else 'u';
    return serialize(writer, .{
        .key = number,
        .mods = mods,
        .event = event,
        .report_events = kf.report_events,
    }, trailer);
}

/// The CSI-u / modifyOtherKeys modifier parameter: 1 + the modifier bitmask.
fn modifierParam(mods: vaxis.Key.Modifiers) u8 {
    var v: u8 = 0;
    if (mods.shift) v |= 1;
    if (mods.alt) v |= 2;
    if (mods.ctrl) v |= 4;
    if (mods.super) v |= 8;
    if (mods.hyper) v |= 16;
    if (mods.meta) v |= 32;
    return v + 1;
}

/// XTMODKEYS modifyOtherKeys: format Ctrl/Alt/Meta-modified "other" keys (not
/// the named cursor/function keys) as `CSI 27 ; modifier ; codepoint ~`.
/// Returns true if the key was emitted.
fn encodeModifyOtherKeys(writer: *std.Io.Writer, key: vaxis.Key, level: u8) !bool {
    const cp = key.codepoint;
    // Functional keys (vaxis puts them at 57344+) keep their legacy CSI forms.
    if (cp == 0 or cp >= 57344) return false;
    const m = key.mods;
    // Only Ctrl/Alt/Meta trigger this; Shift alone stays a plain character.
    if (!(m.ctrl or m.alt or m.super or m.hyper or m.meta)) return false;
    if (level < 2) {
        // Level 1: leave combinations the legacy encoding represents cleanly
        // (a lone Ctrl or lone Alt) to the legacy encoder; format the rest.
        const complex = m.shift or (m.ctrl and m.alt) or m.super or m.hyper or m.meta;
        if (!complex) return false;
    }
    try writer.print("\x1b[27;{d};{d}~", .{ modifierParam(m), cp });
    return true;
}

fn legacy(writer: *std.Io.Writer, key: vaxis.Key, cursor_keys_app: bool) !void {
    // If we have text, we always write it directly
    if (key.text) |text| {
        try writer.writeAll(text);
        return;
    }

    const shift = 0b00000001;
    const alt = 0b00000010;
    const ctrl = 0b00000100;

    const effective_mods: u8 = blk: {
        const mods: u8 = @bitCast(key.mods);
        break :blk mods & (shift | alt | ctrl);
    };

    // If we have no mods and an ascii byte, write it directly
    if (effective_mods == 0 and key.codepoint <= 0x7F) {
        const b: u8 = @truncate(key.codepoint);
        try writer.writeByte(b);
        return;
    }

    // If we are lowercase ascii and ctrl, we map to a control byte
    if (effective_mods == ctrl and key.codepoint >= 'a' and key.codepoint <= 'z') {
        const b: u8 = @truncate(key.codepoint);
        try writer.writeByte(b -| 0x60);
        return;
    }

    // If we are printable ascii + alt
    if (effective_mods == alt and key.codepoint >= ' ' and key.codepoint < 0x7F) {
        const b: u8 = @truncate(key.codepoint);
        try writer.print("\x1b{c}", .{b});
        return;
    }

    // If we are ctrl + alt + lowercase ascii
    if (effective_mods == (ctrl | alt) and key.codepoint >= 'a' and key.codepoint <= 'z') {
        // convert to control sequence
        try writer.print("\x1b{d}", .{key.codepoint - 0x60});
    }

    const def = switch (key.codepoint) {
        vaxis.Key.escape => escape,
        vaxis.Key.enter,
        vaxis.Key.kp_enter,
        => enter,
        vaxis.Key.tab => tab,
        vaxis.Key.backspace => backspace,
        vaxis.Key.insert,
        vaxis.Key.kp_insert,
        => insert,
        vaxis.Key.delete,
        vaxis.Key.kp_delete,
        => delete,
        vaxis.Key.left,
        vaxis.Key.kp_left,
        => left,
        vaxis.Key.right,
        vaxis.Key.kp_right,
        => right,
        vaxis.Key.up,
        vaxis.Key.kp_up,
        => up,
        vaxis.Key.down,
        vaxis.Key.kp_down,
        => down,
        vaxis.Key.page_up,
        vaxis.Key.kp_page_up,
        => page_up,
        vaxis.Key.page_down,
        vaxis.Key.kp_page_down,
        => page_down,
        vaxis.Key.home,
        vaxis.Key.kp_home,
        => home,
        vaxis.Key.end,
        vaxis.Key.kp_end,
        => end,
        vaxis.Key.f1 => f1,
        vaxis.Key.f2 => f2,
        vaxis.Key.f3 => f3_legacy,
        vaxis.Key.f4 => f4,
        vaxis.Key.f5 => f5,
        vaxis.Key.f6 => f6,
        vaxis.Key.f7 => f7,
        vaxis.Key.f8 => f8,
        vaxis.Key.f9 => f9,
        vaxis.Key.f10 => f10,
        vaxis.Key.f11 => f11,
        vaxis.Key.f12 => f12,
        else => return, // TODO: more keys
    };

    switch (effective_mods) {
        0 => {
            if (def.number == 1)
                switch (key.codepoint) {
                    vaxis.Key.f1,
                    vaxis.Key.f2,
                    vaxis.Key.f3,
                    vaxis.Key.f4,
                    => try writer.print("\x1bO{c}", .{def.suffix}),
                    // Arrow keys: use application mode (ESC O) or normal mode (ESC [)
                    vaxis.Key.up,
                    vaxis.Key.down,
                    vaxis.Key.left,
                    vaxis.Key.right,
                    vaxis.Key.kp_up,
                    vaxis.Key.kp_down,
                    vaxis.Key.kp_left,
                    vaxis.Key.kp_right,
                    => try writer.print("{s}{c}", .{ if (cursor_keys_app) "\x1bO" else "\x1b[", def.suffix }),
                    else => try writer.print("\x1b[{c}", .{def.suffix}),
                }
            else
                try writer.print("\x1b[{d}{c}", .{ def.number, def.suffix });
        },
        else => try writer.print("\x1b[{d};{d}{c}", .{ def.number, effective_mods + 1, def.suffix }),
    }
}

const Definition = struct {
    number: u21,
    suffix: u8,
};

const escape: Definition = .{ .number = 27, .suffix = 'u' };
const enter: Definition = .{ .number = 13, .suffix = 'u' };
const tab: Definition = .{ .number = 9, .suffix = 'u' };
const backspace: Definition = .{ .number = 127, .suffix = 'u' };
const insert: Definition = .{ .number = 2, .suffix = '~' };
const delete: Definition = .{ .number = 3, .suffix = '~' };
const left: Definition = .{ .number = 1, .suffix = 'D' };
const right: Definition = .{ .number = 1, .suffix = 'C' };
const up: Definition = .{ .number = 1, .suffix = 'A' };
const down: Definition = .{ .number = 1, .suffix = 'B' };
const page_up: Definition = .{ .number = 5, .suffix = '~' };
const page_down: Definition = .{ .number = 6, .suffix = '~' };
const home: Definition = .{ .number = 1, .suffix = 'H' };
const end: Definition = .{ .number = 1, .suffix = 'F' };
const caps_lock: Definition = .{ .number = 57358, .suffix = 'u' };
const scroll_lock: Definition = .{ .number = 57359, .suffix = 'u' };
const num_lock: Definition = .{ .number = 57360, .suffix = 'u' };
const print_screen: Definition = .{ .number = 57361, .suffix = 'u' };
const pause: Definition = .{ .number = 57362, .suffix = 'u' };
const menu: Definition = .{ .number = 57363, .suffix = 'u' };
const f1: Definition = .{ .number = 1, .suffix = 'P' };
const f2: Definition = .{ .number = 1, .suffix = 'Q' };
const f3: Definition = .{ .number = 13, .suffix = '~' };
const f3_legacy: Definition = .{ .number = 1, .suffix = 'R' };
const f4: Definition = .{ .number = 1, .suffix = 'S' };
const f5: Definition = .{ .number = 15, .suffix = '~' };
const f6: Definition = .{ .number = 17, .suffix = '~' };
const f7: Definition = .{ .number = 18, .suffix = '~' };
const f8: Definition = .{ .number = 19, .suffix = '~' };
const f9: Definition = .{ .number = 20, .suffix = '~' };
const f10: Definition = .{ .number = 21, .suffix = '~' };
const f11: Definition = .{ .number = 23, .suffix = '~' };
const f12: Definition = .{ .number = 24, .suffix = '~' };

// Alternate key reporting. Expectations are taken from kitty's own output for
// the same keystrokes (`kitten show-key --key-mode=kitty`).

fn expectEncoded(
    expected: []const u8,
    key: vaxis.Key,
    event: Event,
    kitty_flags: vaxis.Key.KittyFlags,
) !void {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try encode(&writer, key, event, kitty_flags, false, 0);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

// A layout that moves the key reports the base layout key, with the shifted
// slot left empty. German ö on the physical `o` key, no modifiers held.
test "alternates: base layout key without shift" {
    try expectEncoded("\x1b[246::111u", .{
        .codepoint = 246,
        .base_layout_codepoint = 111,
    }, .press, .{
        .report_events = false,
        .report_all_as_ctl_seqs = false,
        .report_text = false,
    });
}

test "alternates: base layout key on release" {
    try expectEncoded("\x1b[246::111;1:3u", .{
        .codepoint = 246,
        .base_layout_codepoint = 111,
    }, .release, .{
        .report_events = true,
        .report_all_as_ctl_seqs = false,
        .report_text = false,
    });
}

// With text embedding on, the associated text follows in the third field.
test "alternates: base layout key with embedded text" {
    try expectEncoded("\x1b[246::111;;246u", .{
        .codepoint = 246,
        .base_layout_codepoint = 111,
        .text = "ö",
    }, .press, .{ .report_events = false });
}

// An unmoved key has no alternates to report.
test "alternates: omitted when base layout matches" {
    try expectEncoded("a", .{
        .codepoint = 'a',
        .base_layout_codepoint = 'a',
    }, .press, .{
        .report_events = false,
        .report_all_as_ctl_seqs = false,
        .report_text = false,
    });
}

test "alternates: omitted when unknown" {
    try expectEncoded("a", .{ .codepoint = 'a' }, .press, .{
        .report_events = false,
        .report_all_as_ctl_seqs = false,
        .report_text = false,
    });
}

// The shifted slot stays gated on shift being held.
test "alternates: shifted key requires shift" {
    try expectEncoded("\x1b[97:65;2u", .{
        .codepoint = 'a',
        .shifted_codepoint = 'A',
        .mods = .{ .shift = true },
    }, .press, .{
        .report_events = false,
        .report_all_as_ctl_seqs = false,
        .report_text = false,
    });
    // Same key without shift: no alternates section at all.
    try expectEncoded("a", .{
        .codepoint = 'a',
        .shifted_codepoint = 'A',
    }, .press, .{
        .report_events = false,
        .report_all_as_ctl_seqs = false,
        .report_text = false,
    });
}

// Both slots populated: shifted and base layout together.
test "alternates: shifted and base layout together" {
    try expectEncoded("\x1b[246:214:111;2u", .{
        .codepoint = 246,
        .shifted_codepoint = 214,
        .base_layout_codepoint = 111,
        .mods = .{ .shift = true },
    }, .press, .{
        .report_events = false,
        .report_all_as_ctl_seqs = false,
        .report_text = false,
    });
}

// Functional keys never carry alternates.
test "alternates: not reported for functional keys" {
    try expectEncoded("\x1b[1;2P", .{
        .codepoint = vaxis.Key.f1,
        .base_layout_codepoint = 111,
        .mods = .{ .shift = true },
    }, .press, .{
        .report_events = false,
        .report_all_as_ctl_seqs = false,
        .report_text = false,
    });
}
