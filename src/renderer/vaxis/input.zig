const Key = @import("vaxis").Key;
const Mouse = @import("vaxis").Mouse;

pub const key = struct {
    pub const ENTER: key_type = Key.enter;
    pub const TAB: key_type = Key.tab;
    pub const ESC: key_type = Key.escape;
    pub const SPACE: key_type = Key.space;
    pub const BACKSPACE: key_type = Key.backspace;

    pub const INS: key_type = Key.insert;
    pub const DEL: key_type = Key.delete;
    pub const LEFT: key_type = Key.left;
    pub const RIGHT: key_type = Key.right;
    pub const UP: key_type = Key.up;
    pub const DOWN: key_type = Key.down;
    pub const PGDOWN: key_type = Key.page_down;
    pub const PGUP: key_type = Key.page_up;
    pub const HOME: key_type = Key.home;
    pub const END: key_type = Key.end;
    pub const CAPS_LOCK: key_type = Key.caps_lock;
    pub const SCROLL_LOCK: key_type = Key.scroll_lock;
    pub const NUM_LOCK: key_type = Key.num_lock;
    pub const PRINT_SCREEN: key_type = Key.print_screen;
    pub const PAUSE: key_type = Key.pause;
    pub const MENU: key_type = Key.menu;
    pub const F01: key_type = Key.f1;
    pub const F02: key_type = Key.f2;
    pub const F03: key_type = Key.f3;
    pub const F04: key_type = Key.f4;
    pub const F05: key_type = Key.f5;
    pub const F06: key_type = Key.f6;
    pub const F07: key_type = Key.f7;
    pub const F08: key_type = Key.f8;
    pub const F09: key_type = Key.f9;
    pub const F10: key_type = Key.f10;
    pub const F11: key_type = Key.f11;
    pub const F12: key_type = Key.f12;
    pub const F13: key_type = Key.f13;
    pub const F14: key_type = Key.f14;
    pub const F15: key_type = Key.f15;
    pub const F16: key_type = Key.f16;
    pub const F17: key_type = Key.f17;
    pub const F18: key_type = Key.f18;
    pub const F19: key_type = Key.f19;
    pub const F20: key_type = Key.f20;
    pub const F21: key_type = Key.f21;
    pub const F22: key_type = Key.f22;
    pub const F23: key_type = Key.f23;
    pub const F24: key_type = Key.f24;
    pub const F25: key_type = Key.f25;
    pub const F26: key_type = Key.f26;
    pub const F27: key_type = Key.f27;
    pub const F28: key_type = Key.f28;
    pub const F29: key_type = Key.f29;
    pub const F30: key_type = Key.f30;
    pub const F31: key_type = Key.f31;
    pub const F32: key_type = Key.f32;
    pub const F33: key_type = Key.f33;
    pub const F34: key_type = Key.f34;
    pub const F35: key_type = Key.f35;

    pub const F58: key_type = Key.iso_level_5_shift + 1; // FIXME bogus

    pub const MEDIA_PLAY: key_type = Key.media_play;
    pub const MEDIA_PAUSE: key_type = Key.media_pause;
    pub const MEDIA_PPAUSE: key_type = Key.media_play_pause;
    pub const MEDIA_REV: key_type = Key.media_reverse;
    pub const MEDIA_STOP: key_type = Key.media_stop;
    pub const MEDIA_FF: key_type = Key.media_fast_forward;
    pub const MEDIA_REWIND: key_type = Key.media_rewind;
    pub const MEDIA_NEXT: key_type = Key.media_track_next;
    pub const MEDIA_PREV: key_type = Key.media_track_previous;
    pub const MEDIA_RECORD: key_type = Key.media_record;
    pub const MEDIA_LVOL: key_type = Key.lower_volume;
    pub const MEDIA_RVOL: key_type = Key.raise_volume;
    pub const MEDIA_MUTE: key_type = Key.mute_volume;
    pub const LSHIFT: key_type = Key.left_shift;
    pub const LCTRL: key_type = Key.left_control;
    pub const LALT: key_type = Key.left_alt;
    pub const LSUPER: key_type = Key.left_super;
    pub const LHYPER: key_type = Key.left_hyper;
    pub const LMETA: key_type = Key.left_meta;
    pub const RSHIFT: key_type = Key.right_shift;
    pub const RCTRL: key_type = Key.right_control;
    pub const RALT: key_type = Key.right_alt;
    pub const RSUPER: key_type = Key.right_super;
    pub const RHYPER: key_type = Key.right_hyper;
    pub const RMETA: key_type = Key.right_meta;
    pub const L3SHIFT: key_type = Key.iso_level_3_shift;
    pub const L5SHIFT: key_type = Key.iso_level_5_shift;

    pub const MOTION: key_type = @intCast(@intFromEnum(Mouse.Button.none));
    pub const BUTTON1: key_type = @intCast(@intFromEnum(Mouse.Button.left));
    pub const BUTTON2: key_type = @intCast(@intFromEnum(Mouse.Button.middle));
    pub const BUTTON3: key_type = @intCast(@intFromEnum(Mouse.Button.right));
    pub const BUTTON4: key_type = @intCast(@intFromEnum(Mouse.Button.wheel_up));
    pub const BUTTON5: key_type = @intCast(@intFromEnum(Mouse.Button.wheel_down));
    // pub const BUTTON6: key_type = @intCast(@intFromEnum(Mouse.Button.button_6));
    // pub const BUTTON7: key_type = @intCast(@intFromEnum(Mouse.Button.button_7));
    pub const BUTTON8: key_type = @intCast(@intFromEnum(Mouse.Button.button_8));
    pub const BUTTON9: key_type = @intCast(@intFromEnum(Mouse.Button.button_9));
    pub const BUTTON10: key_type = @intCast(@intFromEnum(Mouse.Button.button_10));
    pub const BUTTON11: key_type = @intCast(@intFromEnum(Mouse.Button.button_11));

    // pub const SIGNAL: key_type = Key.SIGNAL;
    // pub const EOF: key_type = Key.EOF;
    // pub const SCROLL_UP: key_type = Key.SCROLL_UP;
    // pub const SCROLL_DOWN: key_type = Key.SCROLL_DOWN;

    /// Is this uint32_t a synthesized event?
    pub fn synthesized_p(w: u32) bool {
        return switch (w) {
            Key.up...Key.iso_level_5_shift => true,
            Key.enter => true,
            Key.tab => true,
            Key.escape => true,
            Key.space => true,
            Key.backspace => true,
            else => false,
        };
    }
};
pub const key_type = u21;

pub const modifier = struct {
    pub const SHIFT: modifier_type = 1;
    pub const ALT: modifier_type = 2;
    pub const CTRL: modifier_type = 4;
    pub const SUPER: modifier_type = 8;
    pub const HYPER: modifier_type = 16;
    pub const META: modifier_type = 32;
    pub const CAPSLOCK: modifier_type = 64;
    pub const NUMLOCK: modifier_type = 128;
};
pub const modifier_type = u32;

pub const event_type = struct {
    pub const PRESS: usize = 1;
    pub const REPEAT: usize = 2;
    pub const RELEASE: usize = 3;
};

pub const utils = struct {
    pub fn isSuper(modifiers: u32) bool {
        return modifiers & modifier.SUPER != 0;
    }

    pub fn isCtrl(modifiers: u32) bool {
        return modifiers & modifier.CTRL != 0;
    }

    pub fn isShift(modifiers: u32) bool {
        return modifiers & modifier.SHIFT != 0;
    }

    pub fn isAlt(modifiers: u32) bool {
        return modifiers & modifier.ALT != 0;
    }

    pub fn key_id_string(k: u32) []const u8 {
        return switch (k) {
            key.ENTER => "ENTER",
            key.TAB => "TAB",
            key.ESC => "ESC",
            key.SPACE => "SPACE",
            key.BACKSPACE => "BACKSPACE",
            key.INS => "INS",
            key.DEL => "DEL",
            key.LEFT => "LEFT",
            key.RIGHT => "RIGHT",
            key.UP => "UP",
            key.DOWN => "DOWN",
            key.PGDOWN => "PGDOWN",
            key.PGUP => "PGUP",
            key.HOME => "HOME",
            key.END => "END",
            key.CAPS_LOCK => "CAPS_LOCK",
            key.SCROLL_LOCK => "SCROLL_LOCK",
            key.NUM_LOCK => "NUM_LOCK",
            key.PRINT_SCREEN => "PRINT_SCREEN",
            key.PAUSE => "PAUSE",
            key.MENU => "MENU",
            key.F01 => "F01",
            key.F02 => "F02",
            key.F03 => "F03",
            key.F04 => "F04",
            key.F05 => "F05",
            key.F06 => "F06",
            key.F07 => "F07",
            key.F08 => "F08",
            key.F09 => "F09",
            key.F10 => "F10",
            key.F11 => "F11",
            key.F12 => "F12",
            key.F13 => "F13",
            key.F14 => "F14",
            key.F15 => "F15",
            key.F16 => "F16",
            key.F17 => "F17",
            key.F18 => "F18",
            key.F19 => "F19",
            key.F20 => "F20",
            key.F21 => "F21",
            key.F22 => "F22",
            key.F23 => "F23",
            key.F24 => "F24",
            key.F25 => "F25",
            key.F26 => "F26",
            key.F27 => "F27",
            key.F28 => "F28",
            key.F29 => "F29",
            key.F30 => "F30",
            key.F31 => "F31",
            key.F32 => "F32",
            key.F33 => "F33",
            key.F34 => "F34",
            key.F35 => "F35",
            key.MEDIA_PLAY => "MEDIA_PLAY",
            key.MEDIA_PAUSE => "MEDIA_PAUSE",
            key.MEDIA_PPAUSE => "MEDIA_PPAUSE",
            key.MEDIA_REV => "MEDIA_REV",
            key.MEDIA_STOP => "MEDIA_STOP",
            key.MEDIA_FF => "MEDIA_FF",
            key.MEDIA_REWIND => "MEDIA_REWIND",
            key.MEDIA_NEXT => "MEDIA_NEXT",
            key.MEDIA_PREV => "MEDIA_PREV",
            key.MEDIA_RECORD => "MEDIA_RECORD",
            key.MEDIA_LVOL => "MEDIA_LVOL",
            key.MEDIA_RVOL => "MEDIA_RVOL",
            key.MEDIA_MUTE => "MEDIA_MUTE",
            key.LSHIFT => "LSHIFT",
            key.LCTRL => "LCTRL",
            key.LALT => "LALT",
            key.LSUPER => "LSUPER",
            key.LHYPER => "LHYPER",
            key.LMETA => "LMETA",
            key.RSHIFT => "RSHIFT",
            key.RCTRL => "RCTRL",
            key.RALT => "RALT",
            key.RSUPER => "RSUPER",
            key.RHYPER => "RHYPER",
            key.RMETA => "RMETA",
            key.L3SHIFT => "L3SHIFT",
            key.L5SHIFT => "L5SHIFT",
            else => "",
        };
    }

    pub fn button_id_string(k: u32) []const u8 {
        return switch (k) {
            key.MOTION => "MOTION",
            key.BUTTON1 => "BUTTON1",
            key.BUTTON2 => "BUTTON2",
            key.BUTTON3 => "BUTTON3",
            key.BUTTON4 => "BUTTON4",
            key.BUTTON5 => "BUTTON5",
            // key.BUTTON6 => "BUTTON6",
            // key.BUTTON7 => "BUTTON7",
            key.BUTTON8 => "BUTTON8",
            key.BUTTON9 => "BUTTON9",
            key.BUTTON10 => "BUTTON10",
            key.BUTTON11 => "BUTTON11",
            else => "",
        };
    }
};
