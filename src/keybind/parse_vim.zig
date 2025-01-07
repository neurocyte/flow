const std = @import("std");
const input = @import("input");

fn peek(str: []const u8, i: usize) error{OutOfBounds}!u8 {
    if (i + 1 < str.len) {
        return str[i + 1];
    } else return error.OutOfBounds;
}

pub const ParseError = error{
    OutOfMemory,
    OutOfBounds,
    InvalidEscapeSequenceStart,
    InvalidInitialCharacter,
    InvalidStartOfControlBinding,
    InvalidStartOfShiftBinding,
    InvalidStartOfDelBinding,
    InvalidStartOfEscBinding,
    InvalidStartOfHomeBinding,
    InvalidCRBinding,
    InvalidSpaceBinding,
    InvalidDelBinding,
    InvalidTabBinding,
    InvalidUpBinding,
    InvalidEscapeBinding,
    InvalidDownBinding,
    InvalidLeftBinding,
    InvalidRightBinding,
    InvalidFunctionKeyNumber,
    InvalidFunctionKeyBinding,
    InvalidEscapeSequenceDelimiter,
    InvalidModifier,
    InvalidEscapeSequenceEnd,
    InvalidHomeBinding,
    InvalidEndBinding,
    InvalidBSBinding,
    InvalidInsertBinding,
};

var parse_error_buf: [256]u8 = undefined;
pub var parse_error_message: []const u8 = "";

fn parse_error_reset() void {
    parse_error_message = "";
}

fn parse_error(e: ParseError, comptime format: anytype, args: anytype) ParseError {
    parse_error_message = std.fmt.bufPrint(&parse_error_buf, format, args) catch "error in parse_error";
    return e;
}

pub fn parse_key_events(allocator: std.mem.Allocator, str: []const u8) ParseError![]input.KeyEvent {
    const from_key = input.KeyEvent.from_key;
    const from_key_mods = input.KeyEvent.from_key_mods;
    parse_error_reset();
    const State = enum {
        base,
        escape_sequence_start,
        escape_sequence_delimiter,
        char_or_key_or_modifier,
        modifier,
        escape_sequence_end,
        function_key,
        tab,
        space,
        del,
        cr,
        esc,
        up,
        down,
        left,
        right,
        home,
        end,
        insert,
        bs,
    };
    var state: State = .base;
    var function_key_number: u8 = 0;
    var modifiers: input.Mods = 0;
    var result = std.ArrayList(input.KeyEvent).init(allocator);
    defer result.deinit();

    var i: usize = 0;
    while (i < str.len) {
        switch (state) {
            // zig fmt: off
            .base => {
                switch (str[i]) {
                    '<' => {
                        state = .escape_sequence_start;
                        i += 1;
                    },
                    //lowercase characters
                    'A'...'Z',
                    'a'...'z',
                    '0'...'9',
                    '!', '@', '#', '$', '%', '^', '&', '*', '(', ')',
                    '`', '~', '-', '_', '=', '+', '[', ']', '{', '}', '\\', '|', ':', ';', '\'', '"', ',', '.', '/', '?', => {
                        try result.append(from_key(str[i]));
                        i += 1;
                    },
                    else => return parse_error(error.InvalidInitialCharacter, "str: {s}, i: {} c: {c}", .{ str, i, str[i] }),
                }
            },
            // zig fmt: on
            .escape_sequence_start => {
                switch (str[i]) {
                    'A' => {
                        state = .modifier;
                    },
                    'C' => {
                        switch (try peek(str, i)) {
                            'R' => {
                                state = .cr;
                            },
                            '-' => {
                                state = .modifier;
                            },
                            else => return parse_error(
                                error.InvalidStartOfControlBinding,
                                "str: {s}, i: {} c: {c}",
                                .{ str, i, str[i] },
                            ),
                        }
                    },
                    'S' => {
                        switch (try peek(str, i)) {
                            '-' => {
                                state = .modifier;
                            },
                            'p' => {
                                state = .space;
                            },
                            else => return parse_error(
                                error.InvalidStartOfShiftBinding,
                                "str: {s}, i: {} c: {c}",
                                .{ str, i, str[i] },
                            ),
                        }
                    },
                    'F' => {
                        state = .function_key;
                        i += 1;
                    },
                    'T' => {
                        state = .tab;
                    },
                    'U' => {
                        state = .up;
                    },
                    'L' => {
                        state = .left;
                    },
                    'R' => {
                        state = .right;
                    },
                    'I' => {
                        state = .insert;
                    },
                    'B' => {
                        state = .bs;
                    },
                    'E' => {
                        state = switch (try peek(str, i)) {
                            's' => .esc,
                            'n' => .end,
                            else => return parse_error(
                                error.InvalidStartOfEscBinding,
                                "str: {s}, i: {} c: {c}",
                                .{ str, i, str[i] },
                            ),
                        };
                    },
                    'D' => {
                        switch (try peek(str, i)) {
                            'o' => {
                                state = .down;
                            },
                            '-' => {
                                state = .modifier;
                            },
                            'e' => {
                                state = .del;
                            },
                            else => return parse_error(
                                error.InvalidStartOfDelBinding,
                                "str: {s}, i: {} c: {c}",
                                .{ str, i, str[i] },
                            ),
                        }
                    },
                    'H' => {
                        state = .home;
                    },
                    else => return parse_error(
                        error.InvalidStartOfHomeBinding,
                        "str: {s}, i: {} c: {c}",
                        .{ str, i, str[i] },
                    ),
                }
            },
            .insert => {
                if (std.mem.indexOf(u8, str[i..], "Insert") == 0) {
                    try result.append(from_key_mods(input.key.insert, modifiers));
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 4;
                } else return parse_error(error.InvalidInsertBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] });
            },
            .end => {
                if (std.mem.indexOf(u8, str[i..], "End") == 0) {
                    try result.append(from_key_mods(input.key.end, modifiers));
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 3;
                } else return parse_error(error.InvalidEndBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] });
            },
            .home => {
                if (std.mem.indexOf(u8, str[i..], "Home") == 0) {
                    try result.append(from_key_mods(input.key.home, modifiers));
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 4;
                } else return parse_error(error.InvalidHomeBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] });
            },
            .bs => {
                if (std.mem.indexOf(u8, str[i..], "BS") == 0) {
                    try result.append(from_key_mods(input.key.backspace, modifiers));
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 2;
                } else return parse_error(error.InvalidBSBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] });
            },
            .cr => {
                if (std.mem.indexOf(u8, str[i..], "CR") == 0) {
                    try result.append(from_key_mods(input.key.enter, modifiers));
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 2;
                } else return parse_error(error.InvalidCRBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] });
            },
            .space => {
                if (std.mem.indexOf(u8, str[i..], "Space") == 0) {
                    try result.append(from_key_mods(input.key.space, modifiers));
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 5;
                } else return parse_error(error.InvalidSpaceBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] });
            },
            .del => {
                if (std.mem.indexOf(u8, str[i..], "Del") == 0) {
                    try result.append(from_key_mods(input.key.delete, modifiers));
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 3;
                } else return parse_error(error.InvalidDelBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] });
            },
            .tab => {
                if (std.mem.indexOf(u8, str[i..], "Tab") == 0) {
                    try result.append(from_key_mods(input.key.tab, modifiers));
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 3;
                } else return parse_error(error.InvalidTabBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] });
            },
            .up => {
                if (std.mem.indexOf(u8, str[i..], "Up") == 0) {
                    try result.append(from_key_mods(input.key.up, modifiers));
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 2;
                } else return parse_error(error.InvalidUpBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] });
            },
            .esc => {
                if (std.mem.indexOf(u8, str[i..], "Esc") == 0) {
                    try result.append(from_key_mods(input.key.escape, modifiers));
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 3;
                } else return parse_error(error.InvalidEscapeBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] });
            },
            .down => {
                if (std.mem.indexOf(u8, str[i..], "Down") == 0) {
                    try result.append(from_key_mods(input.key.down, modifiers));
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 4;
                } else return parse_error(error.InvalidDownBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] });
            },
            .left => {
                if (std.mem.indexOf(u8, str[i..], "Left") == 0) {
                    try result.append(from_key_mods(input.key.left, modifiers));
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 4;
                } else return parse_error(error.InvalidLeftBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] });
            },
            .right => {
                if (std.mem.indexOf(u8, str[i..], "Right") == 0) {
                    try result.append(from_key_mods(input.key.right, modifiers));
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 5;
                } else return parse_error(error.InvalidRightBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] });
            },
            .function_key => {
                switch (str[i]) {
                    '0'...'9' => {
                        function_key_number *= 10;
                        function_key_number += str[i] - '0';
                        if (function_key_number < 1 or function_key_number > 35)
                            return parse_error(error.InvalidFunctionKeyNumber, "function_key_number: {}", .{function_key_number});
                        i += 1;
                    },
                    '>' => {
                        const function_key = input.key.f1 - 1 + function_key_number;
                        try result.append(from_key_mods(function_key, modifiers));
                        modifiers = 0;
                        function_key_number = 0;
                        state = .base;
                        i += 1;
                    },
                    else => return parse_error(error.InvalidFunctionKeyBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] }),
                }
            },
            .escape_sequence_delimiter => {
                switch (str[i]) {
                    '-' => {
                        state = .char_or_key_or_modifier;
                        i += 1;
                    },
                    else => return parse_error(error.InvalidEscapeSequenceDelimiter, "str: {s}, i: {} c: {c}", .{ str, i, str[i] }),
                }
            },
            // zig fmt: off
            .char_or_key_or_modifier => {
                switch (str[i]) {
                    //lowercase characters only inside the escape sequence
                    'a'...'z',
                    '0'...'9',
                    '`', '-', '=', '[', ']', '\\', ':', ';', '\'', ',', '.', '/',
                     => {
                        try result.append(from_key_mods(str[i], modifiers));
                        modifiers = 0;
                        state = .escape_sequence_end;
                        i += 1;
                    },
                    else => {
                        state = .escape_sequence_start;
                    },
                }
            },
            // zig fmt: on
            .modifier => {
                modifiers |= switch (str[i]) {
                    'A' => input.mod.alt,
                    'C' => input.mod.ctrl,
                    'D' => input.mod.super,
                    'S' => input.mod.shift,
                    else => return parse_error(error.InvalidModifier, "str: {s}, i: {} c: {c}", .{ str, i, str[i] }),
                };

                state = .escape_sequence_delimiter;
                i += 1;
            },
            .escape_sequence_end => {
                switch (str[i]) {
                    '>' => {
                        state = .base;
                        i += 1;
                    },
                    else => return parse_error(error.InvalidEscapeSequenceEnd, "str: {s}, i: {} c: {c}", .{ str, i, str[i] }),
                }
            },
        }
    }
    return result.toOwnedSlice();
}
