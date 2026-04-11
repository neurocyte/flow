// Translate wio button events into the Flow keyboard/mouse event format
// that is forwarded to the tui thread via cbor messages.

const std = @import("std");
const wio = @import("wio");
const vaxis = @import("vaxis");

// Modifiers bitmask (matches vaxis.Key.Modifiers packed struct layout used
// by the rest of Flow's input handling).
pub const Mods = vaxis.Key.Modifiers;

pub fn fromWioModifiers(modifiers: wio.Modifiers) Mods {
    return .{
        .shift = modifiers.shift,
        .alt = modifiers.alt,
        .ctrl = modifiers.control,
        .super = modifiers.gui,
    };
}

pub fn isShifted(mods: Mods) bool {
    return mods.shift and !mods.alt and !mods.ctrl and !mods.super and !mods.hyper and !mods.meta;
}

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
pub fn codepointFromButton(b: wio.Button, mods: Mods) ?u21 {
    return switch (b) {
        .a => if (isShifted(mods)) 'A' else 'a',
        .b => if (isShifted(mods)) 'B' else 'b',
        .c => if (isShifted(mods)) 'C' else 'c',
        .d => if (isShifted(mods)) 'D' else 'd',
        .e => if (isShifted(mods)) 'E' else 'e',
        .f => if (isShifted(mods)) 'F' else 'f',
        .g => if (isShifted(mods)) 'G' else 'g',
        .h => if (isShifted(mods)) 'H' else 'h',
        .i => if (isShifted(mods)) 'I' else 'i',
        .j => if (isShifted(mods)) 'J' else 'j',
        .k => if (isShifted(mods)) 'K' else 'k',
        .l => if (isShifted(mods)) 'L' else 'l',
        .m => if (isShifted(mods)) 'M' else 'm',
        .n => if (isShifted(mods)) 'N' else 'n',
        .o => if (isShifted(mods)) 'O' else 'o',
        .p => if (isShifted(mods)) 'P' else 'p',
        .q => if (isShifted(mods)) 'Q' else 'q',
        .r => if (isShifted(mods)) 'R' else 'r',
        .s => if (isShifted(mods)) 'S' else 's',
        .t => if (isShifted(mods)) 'T' else 't',
        .u => if (isShifted(mods)) 'U' else 'u',
        .v => if (isShifted(mods)) 'V' else 'v',
        .w => if (isShifted(mods)) 'W' else 'w',
        .x => if (isShifted(mods)) 'X' else 'x',
        .y => if (isShifted(mods)) 'Y' else 'y',
        .z => if (isShifted(mods)) 'Z' else 'z',
        .@"0" => if (isShifted(mods)) ')' else '0',
        .@"1" => if (isShifted(mods)) '!' else '1',
        .@"2" => if (isShifted(mods)) '@' else '2',
        .@"3" => if (isShifted(mods)) '#' else '3',
        .@"4" => if (isShifted(mods)) '$' else '4',
        .@"5" => if (isShifted(mods)) '%' else '5',
        .@"6" => if (isShifted(mods)) '^' else '6',
        .@"7" => if (isShifted(mods)) '&' else '7',
        .@"8" => if (isShifted(mods)) '*' else '8',
        .@"9" => if (isShifted(mods)) '(' else '9',
        .space => vaxis.Key.space,
        .enter => vaxis.Key.enter,
        .tab => vaxis.Key.tab,
        .backspace => vaxis.Key.backspace,
        .escape => vaxis.Key.escape,
        .minus => if (isShifted(mods)) '_' else '-',
        .equals => if (isShifted(mods)) '+' else '=',
        .left_bracket => if (isShifted(mods)) '{' else '[',
        .right_bracket => if (isShifted(mods)) '}' else ']',
        .backslash => if (isShifted(mods)) '|' else '\\',
        .semicolon => if (isShifted(mods)) ':' else ';',
        .apostrophe => if (isShifted(mods)) '"' else '\'',
        .grave => if (isShifted(mods)) '~' else '`',
        .comma => if (isShifted(mods)) '<' else ',',
        .dot => if (isShifted(mods)) '>' else '.',
        .slash => if (isShifted(mods)) '?' else '/',
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
        else => null,
    };
}

pub const mouse_button_left: u8 = 0;
pub const mouse_button_middle: u8 = 1;
pub const mouse_button_right: u8 = 2;

// Map modifier wio.Button values to kitty protocol codepoints (vaxis.Key.*).
// Returns 0 for non-modifier buttons.
pub fn modifierCodepoint(b: wio.Button) ?u21 {
    return switch (b) {
        .left_shift => vaxis.Key.left_shift,
        .left_control => vaxis.Key.left_control,
        .left_alt => vaxis.Key.left_alt,
        .left_gui => vaxis.Key.left_super,
        .right_shift => vaxis.Key.right_shift,
        .right_control => vaxis.Key.right_control,
        .right_alt => vaxis.Key.right_alt,
        .right_gui => vaxis.Key.right_super,
        .caps_lock => vaxis.Key.caps_lock,
        .num_lock => vaxis.Key.num_lock,
        .scroll_lock => vaxis.Key.scroll_lock,
        else => null,
    };
}

// All buttons that contribute to modifier state, for unfocus cleanup.
pub const modifier_buttons = [_]wio.Button{
    .left_shift,  .left_control,  .left_alt,    .left_gui,
    .right_shift, .right_control, .right_alt,   .right_gui,
    .caps_lock,   .num_lock,      .scroll_lock,
};

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
