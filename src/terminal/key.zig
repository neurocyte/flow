const std = @import("std");
const vaxis = @import("../../main.zig");

pub fn encode(
    writer: std.io.AnyWriter,
    key: vaxis.Key,
    press: bool,
    kitty_flags: vaxis.Key.KittyFlags,
) !void {
    const flags: u5 = @bitCast(kitty_flags);
    switch (press) {
        true => {
            switch (flags) {
                0 => try legacy(writer, key),
                else => unreachable, // TODO: kitty encodings
            }
        },
        false => {},
    }
}

fn legacy(writer: std.io.AnyWriter, key: vaxis.Key) !void {
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
