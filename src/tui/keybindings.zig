//TODO figure out how keybindings should be configured

//TODO figure out how to handle bindings that can take a numerical prefix

const tp = @import("thespian");
const std = @import("std");
const builtin = @import("builtin");

pub const renderer = @import("renderer");
const key = @import("renderer").input.key;
const mod = @import("renderer").input.modifier;
const event_type = @import("renderer").input.event_type;
const command = @import("command");
const EventHandler = @import("EventHandler");
const tui = @import("tui.zig");

//A single key event, such as Ctrl-E
pub const KeyEvent = struct {
    key: u32 = 0, //keypress value
    event_type: usize = event_type.PRESS,
    modifiers: u32 = 0,

    pub fn eql(self: @This(), other: @This()) bool {
        return std.meta.eql(self, other);
    }

    pub fn toString(self: @This(), allocator: std.mem.Allocator) String {
        //TODO implement
        _ = self;
        _ = allocator;
        return "";
    }
};

fn peek(str: []const u8, i: usize) !u8 {
    if (i + 1 < str.len) {
        return str[i + 1];
    } else return error.outOfBounds;
}

const Sequence = std.ArrayList(KeyEvent);

pub fn parseKeySequence(result: *Sequence, str: []const u8) !void {
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
    };
    var state: State = .base;
    var function_key_number: u8 = 0;
    var modifiers: u32 = 0;

    var i: usize = 0;
    while (i < str.len) {
        switch (state) {
            .base => {
                switch (str[i]) {
                    '<' => {
                        state = .escape_sequence_start;
                        i += 1;
                    },
                    'a'...'z', ';', '0'...'9' => {
                        try result.append(.{ .key = str[i] });
                        i += 1;
                    },
                    else => {
                        return error.parseBase;
                    },
                }
            },
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
                            else => {
                                return error.parseEscapeSequenceStartC;
                            },
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
                            else => return error.parseEscapeSequenceStartS,
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
                    'E' => {
                        state = .esc;
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
                            else => return error.parseEscapeSequenceStartD,
                        }
                    },
                    else => {
                        std.debug.print("str: {s}, i: {}\n", .{ str, i });
                        return error.parseEscapeSequenceStart;
                    },
                }
            },
            .cr => {
                if (std.mem.indexOf(u8, str[i..], "CR") == 0) {
                    try result.append(.{ .key = key.ENTER, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 2;
                } else return error.parseCR;
            },
            .space => {
                if (std.mem.indexOf(u8, str[i..], "Space") == 0) {
                    try result.append(.{ .key = key.SPACE, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 5;
                } else {
                    std.debug.print("str: {s}, i: {}, char: {}\n", .{ str, i, str[i] });
                    return error.parseSpace;
                }
            },
            .del => {
                if (std.mem.indexOf(u8, str[i..], "Del") == 0) {
                    try result.append(.{ .key = key.DEL, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 3;
                } else return error.parseDel;
            },
            .tab => {
                if (std.mem.indexOf(u8, str[i..], "Tab") == 0) {
                    try result.append(.{ .key = key.TAB, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 3;
                } else return error.parseTab;
            },
            .up => {
                if (std.mem.indexOf(u8, str[i..], "Up") == 0) {
                    try result.append(.{ .key = key.UP, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 2;
                } else return error.parseSpace;
            },
            .esc => {
                if (std.mem.indexOf(u8, str[i..], "Esc") == 0) {
                    try result.append(.{ .key = key.ESC, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 3;
                } else return error.parseEsc;
            },
            .down => {
                if (std.mem.indexOf(u8, str[i..], "Down") == 0) {
                    try result.append(.{ .key = key.DOWN, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 4;
                } else return error.parseDown;
            },
            .left => {
                if (std.mem.indexOf(u8, str[i..], "Left") == 0) {
                    try result.append(.{ .key = key.LEFT, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 4;
                } else return error.parseLeft;
            },
            .right => {
                if (std.mem.indexOf(u8, str[i..], "Right") == 0) {
                    try result.append(.{ .key = key.RIGHT, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 5;
                } else return error.parseRight;
            },
            .function_key => {
                switch (str[i]) {
                    '0'...'9' => {
                        function_key_number *= 10;
                        function_key_number += str[i] - '0';
                        if (function_key_number < 1 or function_key_number > 35) {
                            std.debug.print("function_key_number: {}\n", .{function_key_number});
                            return error.FunctionKeyNumber;
                        }
                        i += 1;
                    },
                    '>' => {
                        const function_key = key.F01 - 1 + function_key_number;
                        try result.append(.{ .key = function_key, .modifiers = modifiers });
                        modifiers = 0;
                        function_key_number = 0;
                        state = .base;
                        i += 1;
                    },
                    else => return error.parseFunctionKey,
                }
            },
            .escape_sequence_delimiter => {
                switch (str[i]) {
                    '-' => {
                        state = .char_or_key_or_modifier;
                        i += 1;
                    },
                    else => {
                        return error.parseEscapeSequenceDelimiter;
                    },
                }
            },
            .char_or_key_or_modifier => {
                switch (str[i]) {
                    'a'...'z', ';', '0'...'9' => {
                        try result.append(.{ .key = str[i], .modifiers = modifiers });
                        modifiers = 0;
                        state = .escape_sequence_end;
                        i += 1;
                    },
                    else => {
                        state = .escape_sequence_start;
                    },
                }
            },
            .modifier => {
                modifiers |= switch (str[i]) {
                    'A' => mod.ALT,
                    'C' => mod.CTRL,
                    'D' => mod.SUPER,
                    'S' => mod.SHIFT,
                    else => return error.parseModifier,
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
                    else => {
                        return error.parseEscapeSequenceEnd;
                    },
                }
            },
        }
    }
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

    pub fn match(self: *const @This(), keys: []const KeyEvent) MatchResult {
        return matchKeySequence(self.keys.items, keys);
    }

    pub fn matchKeySequence(self: []const KeyEvent, keys: []const KeyEvent) MatchResult {
        if (self.len == 0) {
            return .match_impossible;
        }
        for (keys, 0..) |key_event, i| {
            if (!key_event.eql(self[i])) {
                return .match_impossible;
            }
        }

        if (keys.len >= self.len) {
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

pub const Hint = struct {
    keys: []const u8,
    command: []const u8,
    description: []const u8,
};

//A Collection of keybindings
pub const Mode = struct {
    allocator: std.mem.Allocator,
    bindings: std.ArrayList(Binding),
    on_match_failure: OnMatchFailure = .ignore,
    current_sequence: std.ArrayList(KeyEvent),
    current_sequence_egc: std.ArrayList(u8),
    last_key_event_timestamp_ms: i64 = 0,
    input_buffer: std.ArrayList(u8),
    tui_mode: tui.Mode,

    const OnMatchFailure = enum { insert, ignore };

    pub const JsonConfig = struct {
        bindings: []const []const []const u8,
        on_match_failure: OnMatchFailure,

        pub fn toMode(self: *const @This(), allocator: std.mem.Allocator) !*Mode {
            var result = try Mode.init(allocator);
            result.on_match_failure = self.on_match_failure;
            var state: enum { key_event, command, args } = .key_event;
            for (self.bindings) |entry| {
                var binding = Binding.init(allocator);
                for (entry) |token| {
                    switch (state) {
                        .key_event => {
                            try parseKeySequence(&binding.keys, token);
                            state = .command;
                        },
                        .command => {
                            binding.command = String.init(allocator);
                            try binding.command.appendSlice(token);
                            state = .args;
                        },
                        .args => {
                            var arg = String.init(allocator);
                            try arg.appendSlice(token);
                            try binding.args.append(arg);
                        },
                    }
                }
                try result.bindings.append(binding);
            }
            return result;
        }
    };

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
                //.description = "vim",
                .line_numbers = .relative,
                .cursor_shape = .beam,
            },
        };
        return self;
    }

    pub fn deinit(self: *const Mode) void {
        for (self.bindings.items) |binding| {
            binding.deinit();
        }
        self.bindings.deinit();
        self.current_sequence.deinit();
        self.current_sequence_egc.deinit();
        self.input_buffer.deinit();
        self.allocator.destroy(self);
    }

    // pub fn parseBindingList(self: *@This(), str: []const u8) !void {
    // var iter = std.mem.tokenizeAny(u8, str, &.{'\n'});
    // while (iter.next()) |token| {
    // try self.bindings.append(try parseBinding(self.allocator, token));
    // }
    // }

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
                // .fallback_mode => |fallback_mode_name| {
                // _ = fallback_mode_name;
                // @panic("This feature not supported yet");
                //const fallback_mode = self.activeNamespace().get(fallback_mode_name).?;
                //try self.registerKeyEvent(fallback_mode, egc, key_event);
                // },
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

    pub fn loadJson(self: *@This(), json_string: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json_string, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.notObject;
        for (parsed.value.object.values(), 0..) |namespace, i| {
            if (namespace != .object) return error.namespaceNotObject;
            for (namespace.object.values(), 0..) |mode, j| {
                const mode_config = try std.json.parseFromValue(Mode.JsonConfig, self.allocator, mode, .{});
                defer mode_config.deinit();
                const parsed_mode = try mode_config.value.toMode(self.allocator);
                try self.addMode(parsed.value.object.keys()[i], namespace.object.keys()[j], parsed_mode);
            }
        }
    }
};

const alloc = std.testing.allocator;
const expectEqual = std.testing.expectEqual;

const parse_test_cases = .{
    //input, expected
    .{ "j", &.{KeyEvent{ .key = 'j' }} },
    .{ "jk", &.{ KeyEvent{ .key = 'j' }, KeyEvent{ .key = 'k' } } },
    .{ "<Space>", &.{KeyEvent{ .key = key.SPACE }} },
    .{ "<C-x><C-c>", &.{ KeyEvent{ .key = 'x', .modifiers = mod.CTRL }, KeyEvent{ .key = 'c', .modifiers = mod.CTRL } } },
    .{ "<A-x><Tab>", &.{ KeyEvent{ .key = 'x', .modifiers = mod.ALT }, KeyEvent{ .key = key.TAB } } },
    .{ "<S-A-x><D-Del>", &.{ KeyEvent{ .key = 'x', .modifiers = mod.ALT | mod.SHIFT }, KeyEvent{ .key = key.DEL, .modifiers = mod.SUPER } } },
};

test "parse" {
    inline for (parse_test_cases) |case| {
        var parsed = Sequence.init(alloc);
        defer parsed.deinit();
        try parseKeySequence(&parsed, case[0]);
        const expected: []const KeyEvent = case[1];
        const actual: []const KeyEvent = parsed.items;
        try expectEqual(expected.len, actual.len);
        for (expected, 0..) |expected_event, i| {
            try expectEqual(expected_event, actual[i]);
        }
    }
}

const match_test_cases = .{
    //input, binding, expected_result
    .{ "j", "j", .matched },
    .{ "j", "jk", .match_possible },
    .{ "kjk", "jk", .match_impossible },
    .{ "k<C-v>", "<C-x><C-c>", .match_impossible },
    .{ "<C-x>c", "<C-x><C-c>", .match_impossible },
    .{ "<C-x><C-c>", "<C-x><C-c>", .matched },
    .{ "<C-x><A-a>", "<C-x><A-a><Tab>", .match_possible },
    .{ "<C-o>", "<C-o>", .matched },
};

test "match" {
    inline for (match_test_cases) |case| {
        var input = Sequence.init(alloc);
        defer input.deinit();
        var binding = Sequence.init(alloc);
        defer binding.deinit();

        try parseKeySequence(&input, case[0]);
        try parseKeySequence(&binding, case[1]);
        try expectEqual(case[2], Binding.matchKeySequence(binding.items, input.items));
    }
}

test "json" {
    var bindings = try Bindings.init(alloc);
    defer bindings.deinit();
    try bindings.loadJson(@embedFile("keybindings.json"));
    const mode = bindings.activeMode();
    try mode.registerKeyEvent('j', .{ .key = 'j' });
    try mode.registerKeyEvent('k', .{ .key = 'k' });
    try mode.registerKeyEvent('g', .{ .key = 'g' });
    try mode.registerKeyEvent('i', .{ .key = 'i' });
    try mode.registerKeyEvent(0, .{ .key = 'i', .modifiers = mod.CTRL });
}
