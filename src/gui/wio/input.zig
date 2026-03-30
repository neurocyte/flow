// Translate wio button events into the Flow keyboard/mouse event format
// that is forwarded to the tui thread via cbor messages.

const std = @import("std");
const wio = @import("wio");

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
        .a => if (mods.shift) 'A' else 'a',
        .b => if (mods.shift) 'B' else 'b',
        .c => if (mods.shift) 'C' else 'c',
        .d => if (mods.shift) 'D' else 'd',
        .e => if (mods.shift) 'E' else 'e',
        .f => if (mods.shift) 'F' else 'f',
        .g => if (mods.shift) 'G' else 'g',
        .h => if (mods.shift) 'H' else 'h',
        .i => if (mods.shift) 'I' else 'i',
        .j => if (mods.shift) 'J' else 'j',
        .k => if (mods.shift) 'K' else 'k',
        .l => if (mods.shift) 'L' else 'l',
        .m => if (mods.shift) 'M' else 'm',
        .n => if (mods.shift) 'N' else 'n',
        .o => if (mods.shift) 'O' else 'o',
        .p => if (mods.shift) 'P' else 'p',
        .q => if (mods.shift) 'Q' else 'q',
        .r => if (mods.shift) 'R' else 'r',
        .s => if (mods.shift) 'S' else 's',
        .t => if (mods.shift) 'T' else 't',
        .u => if (mods.shift) 'U' else 'u',
        .v => if (mods.shift) 'V' else 'v',
        .w => if (mods.shift) 'W' else 'w',
        .x => if (mods.shift) 'X' else 'x',
        .y => if (mods.shift) 'Y' else 'y',
        .z => if (mods.shift) 'Z' else 'z',
        .@"0" => if (mods.shift) ')' else '0',
        .@"1" => if (mods.shift) '!' else '1',
        .@"2" => if (mods.shift) '@' else '2',
        .@"3" => if (mods.shift) '#' else '3',
        .@"4" => if (mods.shift) '$' else '4',
        .@"5" => if (mods.shift) '%' else '5',
        .@"6" => if (mods.shift) '^' else '6',
        .@"7" => if (mods.shift) '&' else '7',
        .@"8" => if (mods.shift) '*' else '8',
        .@"9" => if (mods.shift) '(' else '9',
        .space => ' ',
        .enter => '\r',
        .tab => '\t',
        .backspace => 0x7f,
        .escape => 0x1b,
        .minus => if (mods.shift) '_' else '-',
        .equals => if (mods.shift) '+' else '=',
        .left_bracket => if (mods.shift) '{' else '[',
        .right_bracket => if (mods.shift) '}' else ']',
        .backslash => if (mods.shift) '|' else '\\',
        .semicolon => if (mods.shift) ':' else ';',
        .apostrophe => if (mods.shift) '"' else '\'',
        .grave => if (mods.shift) '~' else '`',
        .comma => if (mods.shift) '<' else ',',
        .dot => if (mods.shift) '>' else '.',
        .slash => if (mods.shift) '?' else '/',
        // Navigation keys map to special Unicode private-use codepoints
        // that Flow's input layer understands (matching kitty protocol).
        .up => 0xF700,
        .down => 0xF701,
        .left => 0xF702,
        .right => 0xF703,
        .home => 0xF704,
        .end => 0xF705,
        .page_up => 0xF706,
        .page_down => 0xF707,
        .insert => 0xF708,
        .delete => 0xF709,
        .f1 => 0xF710,
        .f2 => 0xF711,
        .f3 => 0xF712,
        .f4 => 0xF713,
        .f5 => 0xF714,
        .f6 => 0xF715,
        .f7 => 0xF716,
        .f8 => 0xF717,
        .f9 => 0xF718,
        .f10 => 0xF719,
        .f11 => 0xF71A,
        .f12 => 0xF71B,
        .kp_0 => '0',
        .kp_1 => '1',
        .kp_2 => '2',
        .kp_3 => '3',
        .kp_4 => '4',
        .kp_5 => '5',
        .kp_6 => '6',
        .kp_7 => '7',
        .kp_8 => '8',
        .kp_9 => '9',
        .kp_dot => '.',
        .kp_slash => '/',
        .kp_star => '*',
        .kp_minus => '-',
        .kp_plus => '+',
        .kp_enter => '\r',
        .kp_equals => '=',
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
