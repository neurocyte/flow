const vaxis = @import("vaxis");

const meta = @import("std").meta;
const utf8Encode = @import("std").unicode.utf8Encode;
const utf8Decode = @import("std").unicode.utf8Decode;
const utf8ValidateSlice = @import("std").unicode.utf8ValidateSlice;
const FormatOptions = @import("std").fmt.FormatOptions;

pub const key = vaxis.Key;
pub const Key = u21;

pub const Mouse = vaxis.Mouse.Button;
pub const MouseType = @typeInfo(Mouse).@"enum".tag_type;

pub const mouse = struct {
    pub const MOTION: Mouse = vaxis.Mouse.Button.none;
    pub const BUTTON1: Mouse = vaxis.Mouse.Button.left;
    pub const BUTTON2: Mouse = vaxis.Mouse.Button.middle;
    pub const BUTTON3: Mouse = vaxis.Mouse.Button.right;
    pub const BUTTON4: Mouse = vaxis.Mouse.Button.wheel_up;
    pub const BUTTON5: Mouse = vaxis.Mouse.Button.wheel_down;
    // pub const BUTTON6: Mouse = vaxis.Mouse.Button.button_6;
    // pub const BUTTON7: Mouse = vaxis.Mouse.Button.button_7;
    pub const BUTTON8: Mouse = vaxis.Mouse.Button.button_8;
    pub const BUTTON9: Mouse = vaxis.Mouse.Button.button_9;
    pub const BUTTON10: Mouse = vaxis.Mouse.Button.button_10;
    pub const BUTTON11: Mouse = vaxis.Mouse.Button.button_11;
};

/// Does this key represent input?
pub fn is_non_input_key(w: Key) bool {
    return switch (w) {
        vaxis.Key.insert...vaxis.Key.iso_level_5_shift => true,
        vaxis.Key.enter => true,
        vaxis.Key.tab => true,
        vaxis.Key.escape => true,
        vaxis.Key.backspace => true,
        else => false,
    };
}

pub fn is_modifier(w: Key) bool {
    return key.isModifier(.{ .codepoint = w });
}

pub const ModSet = vaxis.Key.Modifiers;
pub const Mods = u8;

pub const mod = struct {
    pub const shift: u8 = @bitCast(ModSet{ .shift = true });
    pub const alt: u8 = @bitCast(ModSet{ .alt = true });
    pub const ctrl: u8 = @bitCast(ModSet{ .ctrl = true });
    pub const super: u8 = @bitCast(ModSet{ .super = true });
    pub const caps_lock: u8 = @bitCast(ModSet{ .caps_lock = true });
    pub const num_lock: u8 = @bitCast(ModSet{ .num_lock = true });
};

pub const Event = u8;
pub const event = struct {
    pub const press: Event = 1;
    pub const repeat: Event = 2;
    pub const release: Event = 3;
};

pub const KeyEvent = struct {
    event: Event = 0,
    key: Key,
    key_unshifted: Key,
    modifiers: Mods = 0,
    text: []const u8 = "",

    pub fn eql(self: @This(), other: @This()) bool {
        const self_mods = self.mods_no_shifts();
        const other_mods = other.mods_no_shifts();
        return self.key == other.key and self_mods == other_mods;
    }

    pub fn eql_unshifted(self: @This(), other: @This()) bool {
        if (self.text.len > 0 or other.text.len > 0) return false;
        const self_mods = self.mods_no_caps();
        const other_mods = other.mods_no_caps();
        return self.key_unshifted == other.key_unshifted and self_mods == other_mods;
    }

    inline fn mods_no_shifts(self: @This()) Mods {
        return if (self.key != self.key_unshifted) self.modifiers & ~(mod.shift | mod.caps_lock) else self.modifiers;
    }

    inline fn mods_no_caps(self: @This()) Mods {
        return self.modifiers & ~mod.caps_lock;
    }

    pub fn format(self: @This(), comptime _: []const u8, _: FormatOptions, writer: anytype) !void {
        const mods = self.mods_no_shifts();
        return if (self.event > 0)
            writer.print("{}:{}{}", .{ event_fmt(self.event), mod_fmt(mods), key_fmt(self.key) })
        else
            writer.print("{}{}", .{ mod_fmt(mods), key_fmt(self.key) });
    }

    pub fn from_key(keypress: Key) @This() {
        return .{
            .key = keypress,
            .key_unshifted = keypress,
        };
    }

    pub fn from_key_mods(keypress: Key, modifiers: Mods) @This() {
        return .{
            .key = keypress,
            .key_unshifted = keypress,
            .modifiers = modifiers,
        };
    }

    pub fn from_key_modset(keypress: Key, modifiers: ModSet) @This() {
        return from_key_mods(keypress, @bitCast(modifiers));
    }

    pub fn from_message(
        event_: Event,
        keypress_: Key,
        keypress_shifted_: Key,
        text: []const u8,
        modifiers: Mods,
    ) @This() {
        const mods_ = switch (keypress_) {
            key.left_super, key.right_super => modifiers & ~mod.super,
            key.left_shift, key.right_shift => modifiers & ~mod.shift,
            key.left_control, key.right_control => modifiers & ~mod.ctrl,
            key.left_alt, key.right_alt => modifiers & ~mod.alt,
            else => modifiers,
        };

        var keypress_shifted: Key = keypress_shifted_;
        if (text.len > 0 and text.len < 5 and utf8ValidateSlice(text)) blk: {
            keypress_shifted = utf8Decode(text) catch break :blk;
        }
        const keypress, const mods = if (keypress_shifted == keypress_)
            map_key_to_unshifed_legacy(keypress_shifted, mods_)
        else
            .{ keypress_, mods_ };

        return .{
            .event = event_,
            .key = keypress_shifted,
            .key_unshifted = keypress,
            .modifiers = mods,
            .text = text,
        };
    }
};

pub fn ucs32_to_utf8(ucs32: []const u32, utf8: []u8) !usize {
    return @intCast(try utf8Encode(@intCast(ucs32[0]), utf8));
}

pub const utils = struct {
    pub fn key_id_string(k: Key) []const u8 {
        return switch (k) {
            vaxis.Key.enter => "enter",
            vaxis.Key.tab => "tab",
            vaxis.Key.escape => "escape",
            vaxis.Key.space => "space",
            vaxis.Key.backspace => "backspace",
            vaxis.Key.insert => "insert",
            vaxis.Key.delete => "delete",
            vaxis.Key.left => "left",
            vaxis.Key.right => "right",
            vaxis.Key.up => "up",
            vaxis.Key.down => "down",
            vaxis.Key.page_down => "page_down",
            vaxis.Key.page_up => "page_up",
            vaxis.Key.home => "home",
            vaxis.Key.end => "end",
            vaxis.Key.caps_lock => "caps_lock",
            vaxis.Key.scroll_lock => "scroll_lock",
            vaxis.Key.num_lock => "num_lock",
            vaxis.Key.print_screen => "print_screen",
            vaxis.Key.pause => "pause",
            vaxis.Key.menu => "menu",
            vaxis.Key.f1 => "f1",
            vaxis.Key.f2 => "f2",
            vaxis.Key.f3 => "f3",
            vaxis.Key.f4 => "f4",
            vaxis.Key.f5 => "f5",
            vaxis.Key.f6 => "f6",
            vaxis.Key.f7 => "f7",
            vaxis.Key.f8 => "f8",
            vaxis.Key.f9 => "f9",
            vaxis.Key.f10 => "f10",
            vaxis.Key.f11 => "f11",
            vaxis.Key.f12 => "f12",
            vaxis.Key.f13 => "f13",
            vaxis.Key.f14 => "f14",
            vaxis.Key.f15 => "f15",
            vaxis.Key.f16 => "f16",
            vaxis.Key.f17 => "f17",
            vaxis.Key.f18 => "f18",
            vaxis.Key.f19 => "f19",
            vaxis.Key.f20 => "f20",
            vaxis.Key.f21 => "f21",
            vaxis.Key.f22 => "f22",
            vaxis.Key.f23 => "f23",
            vaxis.Key.f24 => "f24",
            vaxis.Key.f25 => "f25",
            vaxis.Key.f26 => "f26",
            vaxis.Key.f27 => "f27",
            vaxis.Key.f28 => "f28",
            vaxis.Key.f29 => "f29",
            vaxis.Key.f30 => "f30",
            vaxis.Key.f31 => "f31",
            vaxis.Key.f32 => "f32",
            vaxis.Key.f33 => "f33",
            vaxis.Key.f34 => "f34",
            vaxis.Key.f35 => "f35",
            vaxis.Key.media_play => "media_play",
            vaxis.Key.media_pause => "media_pause",
            vaxis.Key.media_play_pause => "media_play_pause",
            vaxis.Key.media_reverse => "media_reverse",
            vaxis.Key.media_stop => "media_stop",
            vaxis.Key.media_fast_forward => "media_fast_forward",
            vaxis.Key.media_rewind => "media_rewind",
            vaxis.Key.media_track_next => "media_track_next",
            vaxis.Key.media_track_previous => "media_track_previous",
            vaxis.Key.media_record => "media_record",
            vaxis.Key.lower_volume => "lower_volume",
            vaxis.Key.raise_volume => "raise_volume",
            vaxis.Key.mute_volume => "mute_volume",
            vaxis.Key.left_shift => "left_shift",
            vaxis.Key.left_control => "left_control",
            vaxis.Key.left_alt => "left_alt",
            vaxis.Key.left_super => "left_super",
            vaxis.Key.left_hyper => "left_hyper",
            vaxis.Key.left_meta => "left_meta",
            vaxis.Key.right_shift => "right_shift",
            vaxis.Key.right_control => "right_control",
            vaxis.Key.right_alt => "right_alt",
            vaxis.Key.right_super => "right_super",
            vaxis.Key.right_hyper => "right_hyper",
            vaxis.Key.right_meta => "right_meta",
            vaxis.Key.iso_level_3_shift => "iso_level_3_shift",
            vaxis.Key.iso_level_5_shift => "iso_level_5_shift",
            else => "",
        };
    }

    pub fn key_id_string_short(k: Key) []const u8 {
        return switch (k) {
            vaxis.Key.enter => "ret",
            vaxis.Key.tab => "tab",
            vaxis.Key.escape => "esc",
            vaxis.Key.space => "sp",
            vaxis.Key.backspace => "bs",
            vaxis.Key.insert => "ins",
            vaxis.Key.delete => "del",
            vaxis.Key.left => "←",
            vaxis.Key.right => "→",
            vaxis.Key.up => "↑",
            vaxis.Key.down => "↓",
            vaxis.Key.page_down => "pgdn",
            vaxis.Key.page_up => "pgup",
            vaxis.Key.left_shift => "lshft",
            vaxis.Key.left_control => "lctrl",
            vaxis.Key.left_alt => "lalt",
            vaxis.Key.left_super => "lsuper",
            vaxis.Key.left_hyper => "lhyper",
            vaxis.Key.left_meta => "lmeta",
            vaxis.Key.right_shift => "rshft",
            vaxis.Key.right_control => "rctrl",
            vaxis.Key.right_alt => "ralt",
            vaxis.Key.right_super => "rsuper",
            vaxis.Key.right_hyper => "rhyper",
            vaxis.Key.right_meta => "rmeta",
            vaxis.Key.iso_level_3_shift => "iso3",
            vaxis.Key.iso_level_5_shift => "iso5",
            else => key_id_string(k),
        };
    }

    pub fn button_id_string(m: Mouse) []const u8 {
        return switch (m) {
            mouse.MOTION => "motion",
            mouse.BUTTON1 => "button1",
            mouse.BUTTON2 => "button2",
            mouse.BUTTON3 => "button3",
            mouse.BUTTON4 => "button4",
            mouse.BUTTON5 => "button5",
            // mouse.BUTTON6 => "button6",
            // mouse.BUTTON7 => "button7",
            mouse.BUTTON8 => "button8",
            mouse.BUTTON9 => "button9",
            mouse.BUTTON10 => "button10",
            mouse.BUTTON11 => "button11",
            else => "",
        };
    }
};

pub fn key_event_short_fmt(ke: KeyEvent) struct {
    ke: KeyEvent,
    pub fn format(self: @This(), comptime _: []const u8, _: FormatOptions, writer: anytype) !void {
        return writer.print("{}{}", .{ mod_short_fmt(self.ke.modifiers), key_short_fmt(self.ke.key) });
    }
} {
    return .{ .ke = ke };
}

pub fn event_fmt(evt: Event) struct {
    event: Event,
    pub fn format(self: @This(), comptime _: []const u8, _: FormatOptions, writer: anytype) !void {
        return switch (self.event) {
            event.press => writer.writeAll("press"),
            event.repeat => writer.writeAll("repeat"),
            event.release => writer.writeAll("release"),
            else => {},
        };
    }
} {
    return .{ .event = evt };
}

pub fn event_short_fmt(evt: Event) struct {
    event: Event,
    pub fn format(self: @This(), comptime _: []const u8, _: FormatOptions, writer: anytype) !void {
        return switch (self.event) {
            event.press => writer.writeAll("P"),
            event.repeat => writer.writeAll("RP"),
            event.release => writer.writeAll("R"),
            else => {},
        };
    }
} {
    return .{ .event = evt };
}

pub fn key_fmt(key_: Key) struct {
    key: Key,
    pub fn format(self: @This(), comptime _: []const u8, _: FormatOptions, writer: anytype) !void {
        var key_string = utils.key_id_string(self.key);
        var buf: [6]u8 = undefined;
        if (key_string.len == 0) {
            const bytes = try ucs32_to_utf8(&[_]u32{self.key}, &buf);
            key_string = buf[0..bytes];
        }
        try writer.writeAll(key_string);
    }
} {
    return .{ .key = key_ };
}

pub fn key_short_fmt(key_: Key) struct {
    key: Key,
    pub fn format(self: @This(), comptime _: []const u8, _: FormatOptions, writer: anytype) !void {
        var key_string = utils.key_id_string_short(self.key);
        var buf: [6]u8 = undefined;
        if (key_string.len == 0) {
            const bytes = try ucs32_to_utf8(&[_]u32{self.key}, &buf);
            key_string = buf[0..bytes];
        }
        try writer.writeAll(key_string);
    }
} {
    return .{ .key = key_ };
}

pub fn mod_fmt(mods: Mods) struct {
    modifiers: Mods,
    pub fn format(self: @This(), comptime _: []const u8, _: FormatOptions, writer: anytype) !void {
        const modset: ModSet = @bitCast(self.modifiers);
        if (modset.super) try writer.writeAll("super+");
        if (modset.ctrl) try writer.writeAll("ctrl+");
        if (modset.alt) try writer.writeAll("alt+");
        if (modset.shift) try writer.writeAll("shift+");
    }
} {
    return .{ .modifiers = mods };
}

pub fn mod_short_fmt(mods: Mods) struct {
    modifiers: Mods,
    pub fn format(self: @This(), comptime _: []const u8, _: FormatOptions, writer: anytype) !void {
        const modset: ModSet = @bitCast(self.modifiers);
        if (modset.super) try writer.writeAll("Super-");
        if (modset.ctrl) try writer.writeAll("C-");
        if (modset.alt) try writer.writeAll("A-");
        if (modset.shift) try writer.writeAll("S-");
    }
} {
    return .{ .modifiers = mods };
}

fn map_key_to_unshifed_legacy(keypress_shifted: Key, mods: Mods) struct { Key, Mods } {
    return switch (keypress_shifted) {
        'A'...'Z' => .{ keypress_shifted + ('a' - 'A'), mods | mod.shift },
        '!' => .{ '1', mods | mod.shift },
        '@' => .{ '2', mods | mod.shift },
        '#' => .{ '3', mods | mod.shift },
        '$' => .{ '4', mods | mod.shift },
        '%' => .{ '5', mods | mod.shift },
        '^' => .{ '6', mods | mod.shift },
        '&' => .{ '7', mods | mod.shift },
        '*' => .{ '8', mods | mod.shift },
        '(' => .{ '9', mods | mod.shift },
        ')' => .{ '0', mods | mod.shift },
        '_' => .{ '-', mods | mod.shift },
        '+' => .{ '=', mods | mod.shift },
        '~' => .{ '`', mods | mod.shift },
        '{' => .{ '[', mods | mod.shift },
        '}' => .{ ']', mods | mod.shift },
        '|' => .{ '\\', mods | mod.shift },
        ':' => .{ ';', mods | mod.shift },
        '"' => .{ '\'', mods | mod.shift },
        '<' => .{ ',', mods | mod.shift },
        '>' => .{ '.', mods | mod.shift },
        '?' => .{ '/', mods | mod.shift },
        else => .{ keypress_shifted, mods },
    };
}
