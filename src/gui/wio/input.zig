// Translate wio button events into the Flow keyboard/mouse event format
// that is forwarded to the tui thread via cbor messages.

const std = @import("std");
const wio = @import("wio");
const vaxis = @import("vaxis");

// Modifiers bitmask (matches vaxis.Key.Modifiers packed struct layout used
// by the rest of Flow's input handling).
pub const Mods = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
    hyper: bool = false,
    meta: bool = false,
    _pad: u2 = 0,

    pub fn fromButtons(pressed: ButtonSet) Mods {
        return .{
            .shift = pressed.has(.left_shift) or pressed.has(.right_shift),
            .alt = pressed.has(.left_alt) or pressed.has(.right_alt),
            .ctrl = pressed.has(.left_control) or pressed.has(.right_control),
            .super = pressed.has(.left_gui) or pressed.has(.right_gui),
        };
    }

    /// True only when shift is the sole active modifier.
    pub fn shiftOnly(self: Mods) bool {
        return self.shift and !self.alt and !self.ctrl and !self.super and !self.hyper and !self.meta;
    }
};

// Simple set of currently held buttons (for modifier tracking)
pub const ButtonSet = struct {
    bits: std.bit_set.IntegerBitSet(256) = .initEmpty(),

    pub fn press(self: *ButtonSet, b: wio.Button) void {
        self.bits.set(@intFromEnum(b));
    }
    pub fn release(self: *ButtonSet, b: wio.Button) void {
        self.bits.unset(@intFromEnum(b));
    }
    pub fn has(self: ButtonSet, b: wio.Button) bool {
        return self.bits.isSet(@intFromEnum(b));
    }
};

// Translate a wio.Button that is a keyboard key into a Unicode codepoint
// (or 0 for non-printable keys) and a Flow key kind (press=1, repeat=2,
// release=3).
pub const KeyEvent = struct {
    kind: u8,
    codepoint: u21,
    shifted_codepoint: u21,
    text: []const u8,
    mods: u8,
};

// Map a wio.Button to the primary codepoint for that key
pub fn codepointFromButton(b: wio.Button, mods: Mods) u21 {
    return switch (b) {
        .a => if (mods.shiftOnly()) 'A' else 'a',
        .b => if (mods.shiftOnly()) 'B' else 'b',
        .c => if (mods.shiftOnly()) 'C' else 'c',
        .d => if (mods.shiftOnly()) 'D' else 'd',
        .e => if (mods.shiftOnly()) 'E' else 'e',
        .f => if (mods.shiftOnly()) 'F' else 'f',
        .g => if (mods.shiftOnly()) 'G' else 'g',
        .h => if (mods.shiftOnly()) 'H' else 'h',
        .i => if (mods.shiftOnly()) 'I' else 'i',
        .j => if (mods.shiftOnly()) 'J' else 'j',
        .k => if (mods.shiftOnly()) 'K' else 'k',
        .l => if (mods.shiftOnly()) 'L' else 'l',
        .m => if (mods.shiftOnly()) 'M' else 'm',
        .n => if (mods.shiftOnly()) 'N' else 'n',
        .o => if (mods.shiftOnly()) 'O' else 'o',
        .p => if (mods.shiftOnly()) 'P' else 'p',
        .q => if (mods.shiftOnly()) 'Q' else 'q',
        .r => if (mods.shiftOnly()) 'R' else 'r',
        .s => if (mods.shiftOnly()) 'S' else 's',
        .t => if (mods.shiftOnly()) 'T' else 't',
        .u => if (mods.shiftOnly()) 'U' else 'u',
        .v => if (mods.shiftOnly()) 'V' else 'v',
        .w => if (mods.shiftOnly()) 'W' else 'w',
        .x => if (mods.shiftOnly()) 'X' else 'x',
        .y => if (mods.shiftOnly()) 'Y' else 'y',
        .z => if (mods.shiftOnly()) 'Z' else 'z',
        .@"0" => if (mods.shiftOnly()) ')' else '0',
        .@"1" => if (mods.shiftOnly()) '!' else '1',
        .@"2" => if (mods.shiftOnly()) '@' else '2',
        .@"3" => if (mods.shiftOnly()) '#' else '3',
        .@"4" => if (mods.shiftOnly()) '$' else '4',
        .@"5" => if (mods.shiftOnly()) '%' else '5',
        .@"6" => if (mods.shiftOnly()) '^' else '6',
        .@"7" => if (mods.shiftOnly()) '&' else '7',
        .@"8" => if (mods.shiftOnly()) '*' else '8',
        .@"9" => if (mods.shiftOnly()) '(' else '9',
        .space => vaxis.Key.space,
        .enter => vaxis.Key.enter,
        .tab => vaxis.Key.tab,
        .backspace => vaxis.Key.backspace,
        .escape => vaxis.Key.escape,
        .minus => if (mods.shiftOnly()) '_' else '-',
        .equals => if (mods.shiftOnly()) '+' else '=',
        .left_bracket => if (mods.shiftOnly()) '{' else '[',
        .right_bracket => if (mods.shiftOnly()) '}' else ']',
        .backslash => if (mods.shiftOnly()) '|' else '\\',
        .semicolon => if (mods.shiftOnly()) ':' else ';',
        .apostrophe => if (mods.shiftOnly()) '"' else '\'',
        .grave => if (mods.shiftOnly()) '~' else '`',
        .comma => if (mods.shiftOnly()) '<' else ',',
        .dot => if (mods.shiftOnly()) '>' else '.',
        .slash => if (mods.shiftOnly()) '?' else '/',
        // Navigation and function keys: kitty protocol codepoints (vaxis.Key).
        .up => vaxis.Key.up,
        .down => vaxis.Key.down,
        .left => vaxis.Key.left,
        .right => vaxis.Key.right,
        .home => vaxis.Key.home,
        .end => vaxis.Key.end,
        .page_up => vaxis.Key.page_up,
        .page_down => vaxis.Key.page_down,
        .insert => vaxis.Key.insert,
        .delete => vaxis.Key.delete,
        .f1 => vaxis.Key.f1,
        .f2 => vaxis.Key.f2,
        .f3 => vaxis.Key.f3,
        .f4 => vaxis.Key.f4,
        .f5 => vaxis.Key.f5,
        .f6 => vaxis.Key.f6,
        .f7 => vaxis.Key.f7,
        .f8 => vaxis.Key.f8,
        .f9 => vaxis.Key.f9,
        .f10 => vaxis.Key.f10,
        .f11 => vaxis.Key.f11,
        .f12 => vaxis.Key.f12,
        // Keypad keys: kitty protocol codepoints (vaxis.Key).
        .kp_0 => vaxis.Key.kp_0,
        .kp_1 => vaxis.Key.kp_1,
        .kp_2 => vaxis.Key.kp_2,
        .kp_3 => vaxis.Key.kp_3,
        .kp_4 => vaxis.Key.kp_4,
        .kp_5 => vaxis.Key.kp_5,
        .kp_6 => vaxis.Key.kp_6,
        .kp_7 => vaxis.Key.kp_7,
        .kp_8 => vaxis.Key.kp_8,
        .kp_9 => vaxis.Key.kp_9,
        .kp_dot => vaxis.Key.kp_decimal,
        .kp_slash => vaxis.Key.kp_divide,
        .kp_star => vaxis.Key.kp_multiply,
        .kp_minus => vaxis.Key.kp_subtract,
        .kp_plus => vaxis.Key.kp_add,
        .kp_enter => vaxis.Key.kp_enter,
        .kp_equals => vaxis.Key.kp_equal,
        else => 0,
    };
}

pub const mouse_button_left: u8 = 0;
pub const mouse_button_right: u8 = 1;
pub const mouse_button_middle: u8 = 2;

pub fn mouseButtonId(b: wio.Button) ?u8 {
    return switch (b) {
        .mouse_left => mouse_button_left,
        .mouse_right => mouse_button_right,
        .mouse_middle => mouse_button_middle,
        .mouse_back => 3,
        .mouse_forward => 4,
        else => null,
    };
}

pub fn heldMouseButtonId(held: ButtonSet) ?u8 {
    const mouse_buttons = [_]wio.Button{ .mouse_left, .mouse_right, .mouse_middle, .mouse_back, .mouse_forward };
    for (mouse_buttons) |btn| {
        if (held.has(btn)) return mouseButtonId(btn);
    }
    return null;
}
