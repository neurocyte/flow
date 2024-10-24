//TODO figure out how keybindings should be configured

//TODO figure out how to handle bindings that can take a numerical prefix

const tp = @import("thespian");
const std = @import("std");
const builtin = @import("builtin");

pub const renderer = @import("renderer");
const key = @import("renderer").input.key;
const mod = @import("renderer").input.modifier;
const event_type = @import("renderer").input.event_type;
const command = @import("command.zig");
const EventHandler = @import("EventHandler.zig");
const tui = @import("tui.zig");

//A single key event, such as Ctrl-E
pub const KeyEvent = struct {
    key: u32 = 0, //keypress value
    event_type: usize = event_type.PRESS,
    modifiers: u32 = 0,

    pub fn eql(self: @This(), other: @This()) bool {
        return std.meta.eql(self, other);
    }

    pub fn toString(self: @This(), allocator: std.mem.Allocator) []const u8 {
        //TODO implement
        _ = self;
        _ = allocator;
        return "";
    }
};

const Sequence = std.ArrayList(KeyEvent);

pub fn parseKeySequence(allocator: std.mem.Allocator, str: []const u8) !Sequence {
    const State = enum {
        base,
        escape_sequence,
        escape_S,
        escape_D,
        modifier_delimiter,
        modifier_char,
        modifier_end,
        function_key,
        tab_a,
        tab_b,
        tab_end,
        space_p,
        space_a,
        space_c,
        space_e,
        space_end,
        del_e,
        del_l,
        del_end,
    };
    var state: State = .base;
    var function_key_number: u8 = 0;
    var result = Sequence.init(allocator);
    errdefer result.deinit();
    var modifier: u32 = 0;
    for (str) |char| {
        switch (state) {
            .base => {
                switch (char) {
                    '<' => {
                        state = .escape_sequence;
                    },
                    'a'...'z' => {
                        try result.append(.{ .key = char });
                    },
                    else => {
                        return error.parseBase;
                    },
                }
            },
            .escape_sequence => {
                switch (char) {
                    'C' => {
                        modifier = mod.CTRL;
                        state = .modifier_delimiter;
                    },
                    'S' => {
                        state = .escape_S;
                    },
                    'A' => {
                        modifier = mod.ALT;
                        state = .modifier_delimiter;
                    },
                    'F' => {
                        state = .function_key;
                    },
                    'T' => {
                        state = .tab_a;
                    },
                    'D' => {
                        state = .escape_D;
                    },
                    else => {
                        return error.parseEscapeSequence;
                    },
                }
            },
            .space_p => {
                state = switch (char) {
                    'p' => .space_a,
                    else => return error.parseSpaceP,
                };
            },
            .escape_S => {
                switch (char) {
                    'p' => {
                        state = .space_a;
                    },
                    '-' => {
                        modifier = mod.SHIFT;
                        state = .modifier_char;
                    },
                    else => return error.parseEscapeS,
                }
            },
            .escape_D => {
                switch (char) {
                    'e' => {
                        state = .del_l;
                    },
                    '-' => {
                        modifier = mod.SUPER;
                        state = .modifier_char;
                    },
                    else => return error.parseEscapeD,
                }
            },
            .del_e => {
                state = switch (char) {
                    'e' => .del_l,
                    else => return error.parseDelE,
                };
            },
            .del_l => {
                state = switch (char) {
                    'l' => .del_end,
                    else => return error.parseDelL,
                };
            },

            .del_end => {
                switch (char) {
                    '>' => {
                        try result.append(.{ .key = key.DEL, .modifiers = modifier });
                        modifier = 0;
                        state = .base;
                    },
                    else => {
                        return error.parseDelEnd;
                    },
                }
            },
            .space_a => {
                state = switch (char) {
                    'a' => .space_c,
                    else => return error.parseSpaceA,
                };
            },
            .space_c => {
                state = switch (char) {
                    'c' => .space_e,
                    else => return error.parseSpaceC,
                };
            },
            .space_e => {
                state = switch (char) {
                    'e' => .space_end,
                    else => return error.parseSpaceE,
                };
            },
            .space_end => {
                switch (char) {
                    '>' => {
                        try result.append(.{ .key = key.SPACE, .modifiers = modifier });
                        modifier = 0;
                        state = .base;
                    },
                    else => return error.parseSpaceEnd,
                }
            },
            .tab_a => {
                state = switch (char) {
                    'a' => .tab_b,
                    else => return error.parseTabA,
                };
            },
            .tab_b => {
                state = switch (char) {
                    'b' => .tab_end,
                    else => return error.parseTabB,
                };
            },
            .tab_end => {
                switch (char) {
                    '>' => {
                        try result.append(.{ .key = key.TAB, .modifiers = modifier });
                        modifier = 0;
                        state = .base;
                    },
                    else => return error.parseTabEnd,
                }
            },
            .function_key => {
                switch (char) {
                    '0'...'9' => {
                        function_key_number *= 10;
                        function_key_number += char - '0';
                        if (function_key_number < 1 or function_key_number > 35) {
                            std.debug.print("function_key_number: {}\n", .{function_key_number});
                            return error.FunctionKeyNumber;
                        }
                    },
                    '>' => {
                        const function_key = key.F01 - 1 + function_key_number;
                        try result.append(.{ .key = function_key });
                        function_key_number = 0;
                        state = .base;
                    },
                    else => return error.parseFunctionKey,
                }
            },
            .modifier_delimiter => {
                switch (char) {
                    '-' => {
                        state = .modifier_char;
                    },
                    else => {
                        return error.parseModifierDelimiter;
                    },
                }
            },
            .modifier_char => {
                switch (char) {
                    'a'...'z' => {
                        try result.append(.{ .key = char, .modifiers = modifier });
                        modifier = 0;
                        state = .modifier_end;
                    },
                    'T' => {
                        state = .tab_a;
                    },
                    'S' => {
                        state = .space_p;
                    },
                    'D' => {
                        state = .del_e;
                    },
                    else => {
                        return error.parse;
                    },
                }
            },
            .modifier_end => {
                switch (char) {
                    '>' => {
                        state = .base;
                    },
                    else => {
                        return error.parse;
                    },
                }
            },
        }
    }
    return result;
}

pub fn parseBinding(allocator: std.mem.Allocator, str: []const u8) !Binding {
    const State = enum { key_sequence, command, args };
    var state: State = .key_sequence;
    var iter = std.mem.tokenizeAny(u8, str, &.{' '});
    var result = Binding.init(allocator);
    errdefer result.deinit();
    while (iter.next()) |token| {
        switch (state) {
            .key_sequence => {
                const key_sequence = try parseKeySequence(allocator, token);
                result.keys = key_sequence;
                state = .command;
            },
            .command => {
                try result.command.appendSlice(token);
            },
            .args => {
                var arg = String.init(allocator);
                try arg.appendSlice(token);
                try result.args.append(arg);
            },
        }
    }
    return result;
}

const String = std.ArrayList(u8);

//An association of an command with a triggering key chord
pub const Binding = struct {
    keys: Sequence,
    command: String,
    args: std.ArrayList(String),

    pub fn len(self: Binding) usize {
        return self.keys.items.len;
    }

    pub fn execute(self: @This()) !void {
        try command.executeName(self.command.items, .{ .buf = self.args.items });
    }

    pub const MatchResult = enum { match_impossible, match_possible, matched };

    pub fn match(self: @This(), keys: []const KeyEvent) MatchResult {
        for (keys, 0..) |key_event, i| {
            if (!key_event.eql(self.keys.items[i])) {
                return .match_impossible;
            }
        }

        if (keys.len >= self.len()) {
            return .matched;
        } else {
            return .match_possible;
        }
    }

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .keys = Sequence.init(allocator),
            .command = String.init(allocator),
            .args = std.ArrayList(String).init(allocator),
        };
    }

    pub fn deinit(self: *const @This()) void {
        self.keys.deinit();
        self.command.deinit();
        for (self.args.items) |arg| {
            arg.deinit();
        }
        self.args.deinit();
    }
};

//testing convenience function
fn matchBinding(binding: Binding, sequence: []const KeyEvent) Binding.MatchResult {
    return binding.match(sequence);
}

pub const Hint = struct {
    keys: []const u8,
    command: []const u8,
    description: []const u8,
};

//A Collection of keybindings
pub const Mode = struct {
    allocator: std.mem.Allocator,
    bindings: std.ArrayList(Binding),
    on_match_failure: NoMatchBehavior = .ignore,
    current_sequence: std.ArrayList(KeyEvent),
    current_sequence_egc: std.ArrayList(u8),
    last_key_event_timestamp_ms: i64 = 0,
    input_buffer: std.ArrayList(u8),
    tui_mode: tui.Mode,

    pub fn hints(self: *@This()) ![]const Hint {
        if (self.hints == null) {
            self.hints = try std.ArrayList(Hint).init(self.allocator);
        }

        if (self.hints.?.len == self.bindings.items.len) {
            return self.hints.?.items;
        } else {
            self.hints.?.clearRetainingCapacity();
            for (self.bindings.items) |binding| {
                const hint: Hint = .{
                    .keys = binding.KeyEvent.toString(self.allocator),
                    .command = binding.command,
                    .description = "", //TODO lookup command description here
                };
                try self.hints.?.append(hint);
            }
            return self.hints.?.items;
        }
    }

    //what to do with a key press that does not match any bindings
    pub const NoMatchBehavior = union(enum) {
        insert: void,
        ignore: void,
        fallback_mode: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) !*@This() {
        const self = try allocator.create(@This());
        self.* = .{
            .allocator = allocator,
            .current_sequence = try std.ArrayList(KeyEvent).initCapacity(allocator, 16),
            .current_sequence_egc = try std.ArrayList(u8).initCapacity(allocator, 16),
            .last_key_event_timestamp_ms = std.time.milliTimestamp(),
            .input_buffer = try std.ArrayList(u8).initCapacity(allocator, 16),
            .bindings = std.ArrayList(Binding).init(allocator),
            .tui_mode = tui.Mode{
                .handler = EventHandler.to_owned(self),
                .name = "INSERT",
                .description = "vim",
                .line_numbers = .relative,
                .cursor_shape = .beam,
            },
        };
        return self;
    }

    pub fn deinit(self: *const @This()) void {
        for (self.bindings.items) |binding| {
            binding.deinit();
        }
        self.bindings.deinit();
        self.current_sequence.deinit();
        self.current_sequence_egc.deinit();
        self.input_buffer.deinit();
        self.allocator.destroy(self);
    }

    pub fn parseBindingList(self: *@This(), str: []const u8) !void {
        var iter = std.mem.tokenizeAny(u8, str, &.{'\n'});
        while (iter.next()) |token| {
            try self.bindings.append(try parseBinding(self.allocator, token));
        }
    }

    fn cmd(self: *@This(), name_: []const u8, ctx: command.Context) tp.result {
        try self.flushInputBuffer();
        self.last_cmd = name_;
        if (builtin.is_test == false) {
            try command.executeName(name_, ctx);
        }
    }

    pub const max_key_sequence_time_interval = 750;
    pub const max_input_buffer_size = 1024;

    fn insertBytes(self: *@This(), bytes: []const u8) !void {
        if (self.input_buffer.items.len + 4 > max_input_buffer_size)
            try self.flushInputBuffer();
        try self.input_buffer.appendSlice(bytes);
    }

    fn flushInputBuffer(self: *@This()) !void {
        const Static = struct {
            var insert_chars_id: ?command.ID = null;
        };
        if (self.input_buffer.items.len > 0) {
            defer self.input_buffer.clearRetainingCapacity();
            const id = Static.insert_chars_id orelse
                command.get_id_cache("insert_chars", &Static.insert_chars_id) orelse {
                return tp.exit_error(error.InputTargetNotFound, null);
            };
            if (builtin.is_test == false) {
                try command.execute(id, command.fmt(.{self.input_buffer.items}));
            }
            //self.last_command = "insert_chars";
        }
    }

    pub fn receive(self: *@This(), _: tp.pid_ref, m: tp.message) error{Exit}!bool {
        var evtype: u32 = 0;
        var keypress: u32 = 0;
        var egc: u32 = 0;
        var modifiers: u32 = 0;
        var text: []const u8 = "";

        if (try m.match(.{
            "I",
            tp.extract(&evtype),
            tp.extract(&keypress),
            tp.extract(&egc),
            tp.string,
            tp.extract(&modifiers),
        })) {
            self.registerKeyEvent(@intCast(egc), .{
                .event_type = evtype,
                .key = keypress,
                .modifiers = modifiers,
            }) catch |e| return tp.exit_error(e, @errorReturnTrace());
        } else if (try m.match(.{"F"})) {
            self.flushInputBuffer() catch |e| return tp.exit_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "system_clipboard", tp.extract(&text) })) {
            self.flushInputBuffer() catch |e| return tp.exit_error(e, @errorReturnTrace());
            self.insertBytes(text) catch |e| return tp.exit_error(e, @errorReturnTrace());
            self.flushInputBuffer() catch |e| return tp.exit_error(e, @errorReturnTrace());
        }
        return false;
    }

    //register a key press and try to match it with a binding
    pub fn registerKeyEvent(self: *Mode, egc: u8, event: KeyEvent) !void {

        //clear key history if enough time has passed since last key press
        const timestamp = std.time.milliTimestamp();
        if (self.last_key_event_timestamp_ms - timestamp > max_key_sequence_time_interval) {
            try self.abortCurrentSequence(.timeout, egc, event);
        }
        self.last_key_event_timestamp_ms = timestamp;

        try self.current_sequence.append(event);
        try self.current_sequence_egc.append(egc);

        var all_matches_impossible = true;
        for (self.bindings.items) |binding| blk: {
            switch (binding.match(self.current_sequence.items)) {
                .matched => {
                    if (!builtin.is_test) {
                        try binding.execute();
                    }
                    self.current_sequence.clearRetainingCapacity();
                    self.current_sequence_egc.clearRetainingCapacity();
                    break :blk;
                },
                .match_possible => {
                    all_matches_impossible = false;
                },
                .match_impossible => {},
            }
        }
        if (all_matches_impossible) {
            try self.abortCurrentSequence(.match_impossible, egc, event);
        }
    }

    pub const AbortType = enum { timeout, match_impossible };
    pub fn abortCurrentSequence(self: *@This(), abort_type: AbortType, egc: u8, key_event: KeyEvent) anyerror!void {
        _ = egc;
        _ = key_event;
        if (abort_type == .match_impossible) {
            switch (self.on_match_failure) {
                .insert => {
                    try self.insertBytes(self.current_sequence_egc.items);
                    self.current_sequence_egc.clearRetainingCapacity();
                    self.current_sequence.clearRetainingCapacity();
                },
                .ignore => {
                    self.current_sequence.clearRetainingCapacity();
                    self.current_sequence_egc.clearRetainingCapacity();
                },
                .fallback_mode => |fallback_mode_name| {
                    _ = fallback_mode_name;
                    @panic("This feature not supported yet");
                    //const fallback_mode = self.activeNamespace().get(fallback_mode_name).?;
                    //try self.registerKeyEvent(fallback_mode, egc, key_event);
                },
            }
        } else if (abort_type == .timeout) {
            try self.insertBytes(self.current_sequence_egc.items);
            self.current_sequence_egc.clearRetainingCapacity();
            self.current_sequence.clearRetainingCapacity();
        }
    }
};

//A collection of various modes under a single namespace, such as "vim" or "emacs"
pub const Namespace = HashMap(*Mode);
const HashMap = std.StringArrayHashMap;

//Data structure for mapping key events to keybindings
pub const Bindings = struct {
    allocator: std.mem.Allocator,
    active_namespace: usize,
    active_mode: usize,
    namespaces: HashMap(Namespace),

    //lists namespaces
    pub fn listNamespaces(self: *const @This()) []const []const u8 {
        return self.namespaces.keys();
    }

    pub fn activeNamespace(self: *const Bindings) Namespace {
        return self.namespaces.values()[self.active_namespace];
    }

    pub fn activeMode(self: *Bindings) *Mode {
        return self.activeNamespace().values()[self.active_mode];
    }

    pub fn init(allocator: std.mem.Allocator) !*Bindings {
        const self: *@This() = try allocator.create(@This());
        self.* = .{
            .allocator = allocator,
            .active_namespace = 0,
            .active_mode = 0,
            .namespaces = std.StringArrayHashMap(Namespace).init(allocator),
        };
        return self;
    }

    pub fn addMode(self: *@This(), namespace_name: []const u8, mode_name: []const u8, mode: *Mode) !void {
        const namespace = self.namespaces.getPtr(namespace_name) orelse blk: {
            try self.namespaces.putNoClobber(namespace_name, Namespace.init(self.allocator));
            break :blk self.namespaces.getPtr(namespace_name).?;
        };
        try namespace.putNoClobber(mode_name, mode);
    }

    pub fn deinit(self: *Bindings) void {
        for (self.namespaces.values()) |*namespace| {
            for (namespace.values()) |mode| {
                mode.deinit();
            }
            namespace.deinit();
        }
        self.namespaces.deinit();
        self.allocator.destroy(self);
    }

    pub fn addNamespace(self: *Bindings, name: []const u8, modes: []const Mode) !void {
        try self.namespaces.put(name, .{ .name = name, .modes = modes });
    }
};

const alloc = std.testing.allocator;
const expectEqual = std.testing.expectEqual;

test "binding.match.1" {
    const binding = try parseBinding(alloc, "j");
    defer binding.deinit();
    const input = try parseKeySequence(alloc, "j");
    defer input.deinit();
    try expectEqual(.matched, matchBinding(binding, input.items));
}

test "binding.match.2" {
    const binding = try parseBinding(alloc, "jk");
    defer binding.deinit();
    const input = try parseKeySequence(alloc, "j");
    defer input.deinit();
    try expectEqual(.match_possible, matchBinding(binding, input.items));
}
test "binding.match.3" {
    const binding = try parseBinding(alloc, "jk");
    defer binding.deinit();
    const input = try parseKeySequence(alloc, "j");
    defer input.deinit();
    try expectEqual(.match_possible, matchBinding(binding, input.items));
}
test "binding.match.4" {
    const binding = try parseBinding(alloc, "jk");
    defer binding.deinit();
    const input = try parseKeySequence(alloc, "kjk");
    defer input.deinit();
    try expectEqual(.match_impossible, matchBinding(binding, input.items));
}
test "binding.match.5" {
    const binding = try parseBinding(alloc, "<C-x><C-c>");
    defer binding.deinit();
    const input = try parseKeySequence(alloc, "xjk");
    defer input.deinit();
    try expectEqual(.match_impossible, matchBinding(binding, input.items));
}

test "binding.match.6" {
    const binding = try parseBinding(alloc, "<C-x><C-c>");
    defer binding.deinit();
    const input = try parseKeySequence(alloc, "<C-x>c");
    defer input.deinit();
    try expectEqual(.match_impossible, matchBinding(binding, input.items));
}
test "binding.match.7" {
    const binding = try parseBinding(alloc, "<C-x><C-c>");
    defer binding.deinit();
    const input = try parseKeySequence(alloc, "<C-x><C-c>");
    defer input.deinit();
    try expectEqual(.matched, matchBinding(binding, input.items));
}
test "binding.match.8" {
    const binding = try parseBinding(alloc, "<C-x><A-c>b");
    defer binding.deinit();
    const input = try parseKeySequence(alloc, "<C-x><A-c>");
    defer input.deinit();
    try expectEqual(.match_possible, matchBinding(binding, input.items));
}

test "parseKeySequence" {
    const sequence = try parseKeySequence(alloc, "<C-x><A-Tab><C-c>p");
    defer sequence.deinit();
    const expected: []const KeyEvent = &[_]KeyEvent{
        KeyEvent{ .key = 'x', .modifiers = mod.CTRL },
        KeyEvent{ .key = key.TAB, .modifiers = mod.ALT },
        KeyEvent{ .key = 'c', .modifiers = mod.CTRL },
        KeyEvent{ .key = 'p' },
    };
    for (expected, 0..) |char, i| {
        try expectEqual(char, sequence.items[i]);
    }
}

test "parseBinding" {
    const str = "<F10> open_help";
    const binding = try parseBinding(alloc, str);
    binding.deinit();
}

const test_str =
    \\<F10> open_help
    \\<F10> open_help
    \\<C-p> open_recent_files
    \\<C-x><C-c> force_quit
    \\j cursor_down
    \\k cursor_up
    \\<Tab> indent
    \\<S-Tab> unindent
    \\<Space> buffer_next
    \\<S-Space> find
    \\<A-Del> test
    \\<D-Del><C-Tab><A-Space><Space><F10>asdf<Space><F35> brute_force_test
;

test "parseBindingList" {
    const mode = try Mode.init(alloc);
    defer mode.deinit();
    try mode.parseBindingList(test_str);
}

test "Bindings.register" {
    var bindings = try Bindings.init(alloc);
    defer bindings.deinit();
    try bindings.addMode("test_namespace", "test_mode", try Mode.init(alloc));

    const mode = bindings.activeMode();
    try mode.registerKeyEvent('j', .{ .key = 'j' });
    try mode.registerKeyEvent('k', .{ .key = 'k' });
    try mode.registerKeyEvent('g', .{ .key = 'g' });
    try mode.registerKeyEvent('i', .{ .key = 'i' });
    try mode.registerKeyEvent(0, .{ .key = 'i', .modifiers = mod.CTRL });
}
