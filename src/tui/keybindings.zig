//TODO implement keybinding hints

//TODO handle inserting and then deleting characters inside keybindings

//TODO figure out how keybindings should be configured

//TODO create vimscript style keybinding parser for KeyEvent (ie, convert "<C-p>a" into a sequence of key events)

//TODO figure out how to handle bindings that can take a numerical prefix

const tp = @import("thespian");
const std = @import("std");
const builtin = @import("builtin");

const key = @import("renderer").input.key;
const mod = @import("renderer").input.modifier;
const event_type = @import("renderer").input.event_type;
const command = @import("command.zig");

//A single key event, such as Ctrl-E
pub const KeyEvent = struct {
    key: u32 = 0, //keypress value
    event_type: usize = event_type.PRESS,
    modifiers: u32 = 0,

    pub fn eql(self: @This(), other: @This()) bool {
        return std.meta.eql(self, other);
    }
};

const Sequence = std.ArrayList(KeyEvent);

pub fn parseKeySequence(allocator: std.mem.Allocator, str: []const u8) !Sequence {
    const State = enum {
        base,
        escape_sequence,
        modifier_delimiter,
        modifier_char,
        modifier_end,
        function_key,
        tab_a,
        tab_b,
        tab_end,
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
                        return error.parse;
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
                        modifier = mod.SHIFT;
                        state = .modifier_delimiter;
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
                    else => {
                        return error.parse;
                    },
                }
            },
            .tab_a => {
                switch (char) {
                    'a' => {
                        state = .tab_b;
                    },
                    else => return error.parse,
                }
            },
            .tab_b => {
                switch (char) {
                    'b' => {
                        state = .tab_end;
                    },
                    else => {
                        return error.parse;
                    },
                }
            },
            .tab_end => {
                switch (char) {
                    '>' => {
                        try result.append(.{ .key = key.TAB, .modifiers = modifier });
                        state = .base;
                    },
                    else => {
                        return error.parse;
                    },
                }
            },
            .function_key => {
                switch (char) {
                    '0'...'9' => {
                        function_key_number *= 10;
                        function_key_number += char;
                        if (function_key_number < 1 or function_key_number > 35) return error.parse;
                    },
                    '>' => {
                        const function_key = key.F01 - 1 + function_key_number;
                        try result.append(.{ .key = function_key });
                        function_key_number = 0;
                        state = .base;
                    },
                    else => return error.parse,
                }
            },
            .modifier_delimiter => {
                switch (char) {
                    '-' => {
                        state = .modifier_char;
                    },
                    else => {
                        return error.parse;
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

//An action that can be triggered by a Key Sequence
pub const Action = struct {
    command: []const u8 = "",
    args: []const u8 = "",
    //description: []const u8 = "",

    pub fn activate(self: Action) !void {
        //TODO implement
        _ = self;
    }
};

//An association of an action with a triggering key chord
pub const Binding = struct {
    keys: []const KeyEvent = &.{},
    action: Action = .{},

    pub fn len(self: Binding) usize {
        return self.keys.len;
    }

    pub const MatchResult = enum { match_impossible, match_possible, matched };

    pub fn match(self: @This(), keys: []const KeyEvent) MatchResult {
        for (keys, 0..) |key_event, i| {
            if (!key_event.eql(self.keys[i])) {
                return .match_impossible;
            }
        }

        if (keys.len >= self.len()) {
            return .matched;
        } else {
            return .match_possible;
        }
    }
};

fn matchBinding(binding: Binding, sequence: []const KeyEvent) Binding.MatchResult {
    return binding.match(sequence);
}

//A Collection of keybindings
pub const Mode = struct {
    bindings: []const Binding = &.{},
    no_match_behavior: NoMatchBehavior = .ignore,

    //what to do with a key press that does not match any bindings
    pub const NoMatchBehavior = union(enum) {
        insert: void,
        ignore: void,
        fallback_mode: []const u8,
    };
};

//A collection of various modes under a single namespace, such as "vim" or "emacs"
pub const Namespace = HashMap(Mode);
const HashMap = std.StringArrayHashMap;

//Data structure for mapping key events to keybindings
pub const Bindings = struct {
    allocator: std.mem.Allocator,
    active_namespace: usize,
    active_mode: usize,
    namespaces: HashMap(Namespace),
    current_sequence: std.ArrayList(KeyEvent),
    current_sequence_egc: std.ArrayList(u8),
    last_key_event_timestamp_ms: i64 = 0,
    input_buffer: std.ArrayList(u8),
    required_undo_count: usize = 0,
    last_command: []const u8 = "",

    const Self = @This();
    pub const max_key_sequence_time_interval = 750;
    pub const max_input_buffer_size = 1024;

    fn insertBytes(self: *Self, bytes: []const u8) !void {
        if (self.input_buffer.items.len + 4 > max_input_buffer_size)
            try self.flushInputBuffer();
        try self.input_buffer.appendSlice(bytes);
    }

    fn flushInputBuffer(self: *Self) !void {
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
            self.last_command = "insert_chars";
        }
    }

    pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
        var evtype: u32 = undefined;
        var keypress: u32 = undefined;
        var egc: u32 = undefined;
        var modifiers: u32 = undefined;
        var text: []const u8 = undefined;

        if (try m.match(.{
            "I",
            tp.extract(&evtype),
            tp.extract(&keypress),
            tp.extract(&egc),
            tp.string,
            tp.extract(&modifiers),
        })) {
            try self.registerKeyEvent(.{
                .event_type = evtype,
                .key = keypress,
                .modifiers = modifiers,
            }, egc) catch |e| return tp.exit_error(e, @errorReturnTrace());
        } else if (try m.match(.{"F"})) {
            self.flush_input() catch |e| return tp.exit_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "system_clipboard", tp.extract(&text) })) {
            self.flush_input() catch |e| return tp.exit_error(e, @errorReturnTrace());
            self.insert_bytes(text) catch |e| return tp.exit_error(e, @errorReturnTrace());
            self.flush_input() catch |e| return tp.exit_error(e, @errorReturnTrace());
        }
        return false;
    }

    //lists namespaces
    pub fn listNamespaces(self: *const @This()) []const []const u8 {
        return self.namespaces.keys();
    }

    //register a key press and try to match it with a binding
    pub fn registerKeyEvent(self: *Bindings, mode: Mode, egc: u8, event: KeyEvent) !void {

        //clear key history if enough time has passed since last key press
        const timestamp = std.time.milliTimestamp();
        if (self.last_key_event_timestamp_ms - timestamp > max_key_sequence_time_interval) {
            try self.abortCurrentSequence(.timeout, mode, egc, event);
        }
        self.last_key_event_timestamp_ms = timestamp;

        try self.current_sequence.append(event);
        try self.current_sequence_egc.append(egc);

        var all_matches_impossible = true;
        for (mode.bindings) |binding| blk: {
            switch (binding.match(self.current_sequence.items)) {
                .matched => {
                    try binding.action.activate();
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
            try self.abortCurrentSequence(.match_impossible, mode, egc, event);
        }
    }

    pub const AbortType = enum { timeout, match_impossible };
    pub fn abortCurrentSequence(self: *@This(), abort_type: AbortType, mode: Mode, egc: u8, key_event: KeyEvent) anyerror!void {
        if (abort_type == .match_impossible) {
            switch (mode.no_match_behavior) {
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
                    const fallback_mode = self.activeNamespace().get(fallback_mode_name).?;
                    try self.registerKeyEvent(fallback_mode, egc, key_event);
                },
            }
        } else if (abort_type == .timeout) {
            try self.insertBytes(self.current_sequence_egc.items);
            self.current_sequence_egc.clearRetainingCapacity();
            self.current_sequence.clearRetainingCapacity();
        }
    }

    pub fn activeNamespace(self: *const Bindings) Namespace {
        return self.namespaces.values()[self.active_namespace];
    }

    pub fn activeMode(self: *Bindings) Mode {
        return self.activeNamespace().values()[self.active_mode];
    }

    pub fn init(allocator: std.mem.Allocator) !Bindings {
        var result: @This() = .{
            .allocator = allocator,
            .active_namespace = 0,
            .active_mode = 0,
            .namespaces = std.StringArrayHashMap(Namespace).init(allocator),
            .current_sequence = try std.ArrayList(KeyEvent).initCapacity(allocator, 16),
            .current_sequence_egc = try std.ArrayList(u8).initCapacity(allocator, 16),
            .last_key_event_timestamp_ms = std.time.milliTimestamp(),
            .input_buffer = try std.ArrayList(u8).initCapacity(allocator, 16),
        };
        var flow = HashMap(Mode).init(allocator);
        try flow.put("flow", .{});
        try result.namespaces.put("flow", flow);
        return result;
    }

    pub fn deinit(self: *Bindings) void {
        for (self.namespaces.values()) |*namespace| {
            namespace.deinit();
        }
        self.namespaces.deinit();
        self.current_sequence.deinit();
        self.current_sequence_egc.deinit();
        self.input_buffer.deinit();
    }

    pub fn addNamespace(self: *Bindings, name: []const u8, modes: []const Mode) !void {
        try self.namespaces.put(name, .{ .name = name, .modes = modes });
    }

    fn cmd(self: *Self, name_: []const u8, ctx: command.Context) tp.result {
        try self.flush_input();
        self.last_cmd = name_;
        if (builtin.is_test == false) {
            try command.executeName(name_, ctx);
        }
    }
};

const alloc = std.testing.allocator;
const expectEqual = std.testing.expectEqual;

test "binding.match" {
    try expectEqual(
        .matched,
        matchBinding(
            Binding{ .keys = &[_]KeyEvent{.{ .key = 'j' }} },
            &[_]KeyEvent{.{ .key = 'j' }},
        ),
    );

    try expectEqual(
        .match_possible,
        matchBinding(
            Binding{ .keys = &[_]KeyEvent{ .{ .key = 'j' }, .{ .key = 'k' } } },
            &[_]KeyEvent{.{ .key = 'j' }},
        ),
    );

    try expectEqual(
        .matched,
        matchBinding(
            Binding{ .keys = &[_]KeyEvent{ .{ .key = 'j' }, .{ .key = 'k' } } },
            &[_]KeyEvent{ .{ .key = 'j' }, .{ .key = 'k' } },
        ),
    );

    try expectEqual(
        .match_impossible,
        matchBinding(
            Binding{ .keys = &[_]KeyEvent{ .{ .key = 'j' }, .{ .key = 'k' } } },
            &[_]KeyEvent{ .{ .key = 'k' }, .{ .key = 'j' }, .{ .key = 'k' } },
        ),
    );

    try expectEqual(
        .match_impossible,
        matchBinding(
            Binding{ .keys = &[_]KeyEvent{ .{ .key = 'x', .modifiers = mod.CTRL }, .{ .key = 'c', .modifiers = mod.CTRL } } },
            &[_]KeyEvent{ .{ .key = 'x' }, .{ .key = 'j' }, .{ .key = 'k' } },
        ),
    );

    try expectEqual(
        .match_impossible,
        matchBinding(
            Binding{ .keys = &[_]KeyEvent{ .{ .key = 'x', .modifiers = mod.CTRL }, .{ .key = 'c', .modifiers = mod.CTRL } } },
            &[_]KeyEvent{ .{ .key = 'x', .modifiers = mod.CTRL }, .{ .key = 'c' } },
        ),
    );

    try expectEqual(
        .matched,
        matchBinding(
            Binding{ .keys = &[_]KeyEvent{ .{ .key = 'x', .modifiers = mod.CTRL }, .{ .key = 'c', .modifiers = mod.CTRL } } },
            &[_]KeyEvent{ .{ .key = 'x', .modifiers = mod.CTRL }, .{ .key = 'c', .modifiers = mod.CTRL } },
        ),
    );

    try expectEqual(
        .match_possible,
        matchBinding(
            Binding{ .keys = &[_]KeyEvent{
                .{ .key = 'x', .modifiers = mod.CTRL },
                .{ .key = 'c', .modifiers = mod.ALT },
                .{ .key = 'b' },
            } },
            &[_]KeyEvent{ .{ .key = 'x', .modifiers = mod.CTRL }, .{ .key = 'c', .modifiers = mod.ALT } },
        ),
    );
}

test "Bindings.register" {
    var bindings = try Bindings.init(alloc);
    defer bindings.deinit();
    const mode = bindings.activeMode();
    try bindings.registerKeyEvent(mode, 'j', .{ .key = 'j' });
    try bindings.registerKeyEvent(mode, 'k', .{ .key = 'k' });
    try bindings.registerKeyEvent(mode, 'g', .{ .key = 'g' });
    try bindings.registerKeyEvent(mode, 'i', .{ .key = 'i' });
    try bindings.registerKeyEvent(mode, 0, .{ .key = 'i', .modifiers = mod.CTRL });
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
