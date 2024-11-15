//TODO figure out how keybindings should be configured

//TODO figure out how to handle bindings that can take a numerical prefix

const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const builtin = @import("builtin");
const log = @import("log");

const input = @import("input");
const command = @import("command");
const EventHandler = @import("EventHandler");

const KeyEvent = @import("KeyEvent.zig");

pub const mode = struct {
    pub const input = struct {
        pub const flow = Handler("flow", "normal");
        pub const home = Handler("flow", "home");
        pub const vim = struct {
            pub const normal = Handler("vim", "normal");
            pub const insert = Handler("vim", "insert");
            pub const visual = Handler("vim", "visual");
        };
        pub const helix = struct {
            pub const normal = Handler("helix", "normal");
            pub const insert = Handler("helix", "insert");
            pub const visual = Handler("helix", "select");
        };
    };
    pub const overlay = struct {
        pub const palette = Handler("flow", "palette");
    };
    pub const mini = struct {
        pub const goto = Handler("flow", "mini/goto");
        pub const move_to_char = Handler("flow", "mini/move_to_char");
        pub const file_browser = Handler("flow", "mini/file_browser");
        pub const find_in_files = Handler("flow", "mini/find_in_files");
        pub const find = Handler("flow", "mini/find");
    };
};

fn Handler(namespace_name: []const u8, mode_name: []const u8) type {
    return struct {
        allocator: std.mem.Allocator,
        bindings: BindingSet,
        pub fn create(allocator: std.mem.Allocator, _: anytype) !EventHandler {
            const self: *@This() = try allocator.create(@This());
            self.* = .{
                .allocator = allocator,
                .bindings = try BindingSet.init(allocator, @embedFile("keybindings.json"), namespace_name, mode_name),
            };
            return EventHandler.to_owned(self);
        }
        pub fn deinit(self: *@This()) void {
            self.bindings.deinit();
            self.allocator.destroy(self);
        }
        pub fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) error{Exit}!bool {
            return self.bindings.receive(from, m);
        }
        pub const hints = KeybindHints.initComptime(.{});
    };
}

pub const Mode = struct {
    input_handler: EventHandler,
    event_handler: ?EventHandler = null,

    name: []const u8 = "",
    line_numbers: enum { absolute, relative } = .absolute,
    keybind_hints: ?*const KeybindHints = null,
    cursor_shape: CursorShape = .block,

    pub fn deinit(self: *Mode) void {
        self.input_handler.deinit();
        if (self.event_handler) |eh| eh.deinit();
    }
};

pub const KeybindHints = std.static_string_map.StaticStringMap([]const u8);

fn peek(str: []const u8, i: usize) error{OutOfBounds}!u8 {
    if (i + 1 < str.len) {
        return str[i + 1];
    } else return error.OutOfBounds;
}

const ParseError = error{
    OutOfMemory,
    OutOfBounds,
    InvalidEscapeSequenceStart,
    InvalidInitialCharacter,
    InvalidStartOfControlBinding,
    InvalidStartOfShiftBinding,
    InvalidStartOfDeleteBinding,
    InvalidCRBinding,
    InvalidSpaceBinding,
    InvalidDeleteBinding,
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
};

var parse_error_buf: [256]u8 = undefined;
var parse_error_message: []const u8 = "";

fn parse_error_reset() void {
    parse_error_message = "";
}

fn parse_error(e: ParseError, comptime format: anytype, args: anytype) ParseError {
    parse_error_message = std.fmt.bufPrint(&parse_error_buf, format, args) catch "error in parse_error";
    return e;
}

fn parse_key_events(allocator: std.mem.Allocator, str: []const u8) ParseError![]KeyEvent {
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
    };
    var state: State = .base;
    var function_key_number: u8 = 0;
    var modifiers: input.Mods = 0;
    var result = std.ArrayList(KeyEvent).init(allocator);
    defer result.deinit();

    var i: usize = 0;
    while (i < str.len) {
        switch (state) {
            .base => {
                switch (str[i]) {
                    '<' => {
                        state = .escape_sequence_start;
                        i += 1;
                    },
                    'a'...'z', '\\', '[', ']', '/', '`', '-', '=', ';', '0'...'9' => {
                        try result.append(.{ .key = str[i] });
                        i += 1;
                    },
                    else => return parse_error(error.InvalidInitialCharacter, "str: {s}, i: {} c: {c}", .{ str, i, str[i] }),
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
                            else => return parse_error(error.InvalidStartOfControlBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] }),
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
                            else => return parse_error(error.InvalidStartOfShiftBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] }),
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
                            else => return parse_error(error.InvalidStartOfDeleteBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] }),
                        }
                    },
                    else => return parse_error(error.InvalidEscapeSequenceStart, "str: {s}, i: {} c: {c}", .{ str, i, str[i] }),
                }
            },
            .cr => {
                if (std.mem.indexOf(u8, str[i..], "CR") == 0) {
                    try result.append(.{ .key = input.key.enter, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 2;
                } else return parse_error(error.InvalidCRBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] });
            },
            .space => {
                if (std.mem.indexOf(u8, str[i..], "Space") == 0) {
                    try result.append(.{ .key = input.key.space, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 5;
                } else return parse_error(error.InvalidSpaceBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] });
            },
            .del => {
                if (std.mem.indexOf(u8, str[i..], "Del") == 0) {
                    try result.append(.{ .key = input.key.delete, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 3;
                } else return parse_error(error.InvalidDeleteBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] });
            },
            .tab => {
                if (std.mem.indexOf(u8, str[i..], "Tab") == 0) {
                    try result.append(.{ .key = input.key.tab, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 3;
                } else return parse_error(error.InvalidTabBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] });
            },
            .up => {
                if (std.mem.indexOf(u8, str[i..], "Up") == 0) {
                    try result.append(.{ .key = input.key.up, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 2;
                } else return parse_error(error.InvalidUpBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] });
            },
            .esc => {
                if (std.mem.indexOf(u8, str[i..], "Esc") == 0) {
                    try result.append(.{ .key = input.key.escape, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 3;
                } else return parse_error(error.InvalidEscapeBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] });
            },
            .down => {
                if (std.mem.indexOf(u8, str[i..], "Down") == 0) {
                    try result.append(.{ .key = input.key.down, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 4;
                } else return parse_error(error.InvalidDownBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] });
            },
            .left => {
                if (std.mem.indexOf(u8, str[i..], "Left") == 0) {
                    try result.append(.{ .key = input.key.left, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 4;
                } else return parse_error(error.InvalidLeftBinding, "str: {s}, i: {} c: {c}", .{ str, i, str[i] });
            },
            .right => {
                if (std.mem.indexOf(u8, str[i..], "Right") == 0) {
                    try result.append(.{ .key = input.key.right, .modifiers = modifiers });
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
                        try result.append(.{ .key = function_key, .modifiers = modifiers });
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

//An association of an command with a triggering key chord
const Binding = struct {
    keys: []KeyEvent,
    command: []const u8,
    args: []const u8,

    fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.keys);
        allocator.free(self.command);
        allocator.free(self.args);
    }

    fn len(self: Binding) usize {
        return self.keys.items.len;
    }

    fn execute(self: @This()) !void {
        try command.executeName(self.command, .{ .args = .{ .buf = self.args } });
    }

    const MatchResult = enum { match_impossible, match_possible, matched };

    fn match(self: *const @This(), match_keys: []const KeyEvent) MatchResult {
        if (self.keys.len == 0) return .match_impossible;
        for (self.keys, 0..) |key_event, i| {
            if (match_keys.len <= i) return .match_possible;
            if (!key_event.eql(match_keys[i])) return .match_impossible;
        }
        return if (self.keys.len == match_keys.len) .matched else .match_possible;
    }
};

const Hint = struct {
    keys: []const u8,
    command: []const u8,
    description: []const u8,
};

//A Collection of keybindings
const BindingSet = struct {
    allocator: std.mem.Allocator,
    bindings: std.ArrayList(Binding),
    on_match_failure: OnMatchFailure = .ignore,
    current_sequence: std.ArrayList(KeyEvent),
    current_sequence_egc: std.ArrayList(u8),
    last_key_event_timestamp_ms: i64 = 0,
    input_buffer: std.ArrayList(u8),
    logger: log.Logger,
    namespace_name: []const u8,
    mode_name: []const u8,

    const OnMatchFailure = enum { insert, ignore };

    fn hints(self: *@This()) ![]const Hint {
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

    fn init(allocator: std.mem.Allocator, json_string: []const u8, namespace_name: []const u8, mode_name: []const u8) !@This() {
        var self: @This() = .{
            .allocator = allocator,
            .current_sequence = try std.ArrayList(KeyEvent).initCapacity(allocator, 16),
            .current_sequence_egc = try std.ArrayList(u8).initCapacity(allocator, 16),
            .last_key_event_timestamp_ms = std.time.milliTimestamp(),
            .input_buffer = try std.ArrayList(u8).initCapacity(allocator, 16),
            .bindings = std.ArrayList(Binding).init(allocator),
            .logger = if (!builtin.is_test) log.logger("keybind") else undefined,
            .namespace_name = try allocator.dupe(u8, namespace_name),
            .mode_name = try allocator.dupe(u8, mode_name),
        };
        try self.load_json(json_string, namespace_name, mode_name);
        return self;
    }

    fn deinit(self: *const BindingSet) void {
        for (self.bindings.items) |binding| binding.deinit(self.allocator);
        self.bindings.deinit();
        self.current_sequence.deinit();
        self.current_sequence_egc.deinit();
        self.input_buffer.deinit();
        if (!builtin.is_test) self.logger.deinit();
        self.allocator.free(self.namespace_name);
        self.allocator.free(self.mode_name);
    }

    fn load_json(self: *@This(), json_string: []const u8, namespace_name: []const u8, mode_name: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json_string, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.NotAnObject;
        var namespaces = parsed.value.object.iterator();
        while (namespaces.next()) |*namespace_entry| {
            if (namespace_entry.value_ptr.* != .object) return error.NotAnObject;
            if (!std.mem.eql(u8, namespace_entry.key_ptr.*, namespace_name)) continue;
            var modes = namespace_entry.value_ptr.object.iterator();
            while (modes.next()) |mode_entry| {
                if (!std.mem.eql(u8, mode_entry.key_ptr.*, mode_name)) continue;
                try self.load_set_from_json(mode_entry.value_ptr.*);
            }
        }
    }

    fn load_set_from_json(self: *BindingSet, mode_bindings: std.json.Value) !void {
        const JsonConfig = struct {
            bindings: []const []const []const u8,
            on_match_failure: OnMatchFailure,
        };
        const parsed = try std.json.parseFromValue(JsonConfig, self.allocator, mode_bindings, .{});
        defer parsed.deinit();
        self.on_match_failure = parsed.value.on_match_failure;
        for (parsed.value.bindings) |entry| {
            var state: enum { key_event, command, args } = .key_event;
            var keys: ?[]KeyEvent = null;
            var command_: ?[]const u8 = null;
            var args = std.ArrayListUnmanaged([]const u8){};
            defer {
                if (keys) |p| self.allocator.free(p);
                if (command_) |p| self.allocator.free(p);
                for (args.items) |p| self.allocator.free(p);
                args.deinit(self.allocator);
            }
            for (entry) |token| {
                switch (state) {
                    .key_event => {
                        keys = parse_key_events(self.allocator, token) catch |e| {
                            self.logger.print_err("keybind.load", "ERROR: {s} {s}", .{ @errorName(e), parse_error_message });
                            break;
                        };
                        state = .command;
                    },
                    .command => {
                        command_ = try self.allocator.dupe(u8, token);
                        state = .args;
                    },
                    .args => {
                        try args.append(self.allocator, try self.allocator.dupe(u8, token));
                    },
                }
            }
            if (state != .args) {
                if (builtin.is_test) @panic("invalid state in load_set_from_json");
                continue;
            }
            var args_cbor = std.ArrayListUnmanaged(u8){};
            defer args_cbor.deinit(self.allocator);
            const writer = args_cbor.writer(self.allocator);
            try cbor.writeArrayHeader(writer, args.items.len);
            for (args.items) |arg| try cbor.writeValue(writer, arg);

            try self.bindings.append(.{
                .keys = keys.?,
                .command = command_.?,
                .args = try args_cbor.toOwnedSlice(self.allocator),
            });
            keys = null;
            command_ = null;
        }
    }

    const max_key_sequence_time_interval = 750;
    const max_input_buffer_size = 1024;

    fn insert_bytes(self: *@This(), bytes: []const u8) !void {
        if (self.input_buffer.items.len + 4 > max_input_buffer_size)
            try self.flush();
        try self.input_buffer.appendSlice(bytes);
    }

    fn flush(self: *@This()) !void {
        const Static = struct {
            var insert_chars_id: ?command.ID = null;
        };
        if (self.input_buffer.items.len > 0) {
            defer self.input_buffer.clearRetainingCapacity();
            const id = Static.insert_chars_id orelse
                command.get_id_cache("insert_chars", &Static.insert_chars_id) orelse {
                return tp.exit_error(error.InputTargetNotFound, null);
            };
            if (!builtin.is_test) {
                try command.execute(id, command.fmt(.{self.input_buffer.items}));
            }
        }
    }

    fn receive(self: *@This(), _: tp.pid_ref, m: tp.message) error{Exit}!bool {
        var event: input.Event = 0;
        var keypress: input.Key = 0;
        var egc: input.Key = 0;
        var modifiers: input.Mods = 0;
        var text: []const u8 = "";

        if (try m.match(.{
            "I",
            tp.extract(&event),
            tp.extract(&keypress),
            tp.extract(&egc),
            tp.string,
            tp.extract(&modifiers),
        })) {
            if (self.process_key_event(egc, .{
                .event = event,
                .key = keypress,
                .modifiers = modifiers,
            }) catch |e| return tp.exit_error(e, @errorReturnTrace())) |binding| {
                try binding.execute();
            }
        } else if (try m.match(.{"F"})) {
            self.flush() catch |e| return tp.exit_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "system_clipboard", tp.extract(&text) })) {
            self.flush() catch |e| return tp.exit_error(e, @errorReturnTrace());
            self.insert_bytes(text) catch |e| return tp.exit_error(e, @errorReturnTrace());
            self.flush() catch |e| return tp.exit_error(e, @errorReturnTrace());
        }
        return false;
    }

    //register a key press and try to match it with a binding
    fn process_key_event(self: *BindingSet, egc: input.Key, event: KeyEvent) !?*Binding {

        //hacky fix since we are ignoring repeats and keyups right now
        if (event.event != input.event.press) return null;

        //clear key history if enough time has passed since last key press
        const timestamp = std.time.milliTimestamp();
        if (self.last_key_event_timestamp_ms - timestamp > max_key_sequence_time_interval) {
            try self.terminate_sequence(.timeout, egc, event);
        }
        self.last_key_event_timestamp_ms = timestamp;

        try self.current_sequence.append(event);
        var buf: [6]u8 = undefined;
        const bytes = try input.ucs32_to_utf8(&[_]u32{egc}, &buf);
        if (!input.is_non_input_key(event.key))
            try self.current_sequence_egc.appendSlice(buf[0..bytes]);

        var all_matches_impossible = true;
        for (self.bindings.items) |*binding| {
            switch (binding.match(self.current_sequence.items)) {
                .matched => {
                    defer {
                        //clear current sequence if command execution fails
                        self.current_sequence.clearRetainingCapacity();
                        self.current_sequence_egc.clearRetainingCapacity();
                    }
                    return binding;
                },
                .match_possible => {
                    all_matches_impossible = false;
                },
                .match_impossible => {},
            }
        }
        if (all_matches_impossible) {
            try self.terminate_sequence(.match_impossible, egc, event);
        }
        return null;
    }

    const AbortType = enum { timeout, match_impossible };
    fn terminate_sequence(self: *@This(), abort_type: AbortType, egc: input.Key, key_event: KeyEvent) anyerror!void {
        _ = egc;
        _ = key_event;
        if (abort_type == .match_impossible) {
            switch (self.on_match_failure) {
                .insert => {
                    try self.insert_bytes(self.current_sequence_egc.items);
                    self.current_sequence_egc.clearRetainingCapacity();
                    self.current_sequence.clearRetainingCapacity();
                },
                .ignore => {
                    self.current_sequence.clearRetainingCapacity();
                    self.current_sequence_egc.clearRetainingCapacity();
                },
            }
        } else if (abort_type == .timeout) {
            try self.insert_bytes(self.current_sequence_egc.items);
            self.current_sequence_egc.clearRetainingCapacity();
            self.current_sequence.clearRetainingCapacity();
        }
    }
};

//A collection of various modes under a single namespace, such as "vim" or "emacs"
const Namespace = struct {
    name: []const u8,
    modes: std.ArrayList(BindingSet),

    fn init(allocator: std.mem.Allocator, name: []const u8) !Namespace {
        return .{
            .name = try allocator.dupe(u8, name),
            .modes = std.ArrayList(BindingSet).init(allocator),
        };
    }

    fn deinit(self: *@This()) void {
        self.modes.allocator.free(self.name);
        for (self.modes.items) |*mode_| mode_.deinit();
        self.modes.deinit();
    }

    fn get_mode(self: *@This(), mode_name: []const u8) !*BindingSet {
        for (self.modes.items) |*mode_|
            if (std.mem.eql(u8, mode_.name, mode_name))
                return mode_;
        const mode_ = try self.modes.addOne();
        mode_.* = try BindingSet.init(self.modes.allocator, mode_name);
        return mode_;
    }
};

pub const CursorShape = enum {
    default,
    block_blink,
    block,
    underline_blink,
    underline,
    beam_blink,
    beam,
};

const expectEqual = std.testing.expectEqual;

const parse_test_cases = .{
    //input, expected
    .{ "j", &.{KeyEvent{ .key = 'j' }} },
    .{ "jk", &.{ KeyEvent{ .key = 'j' }, KeyEvent{ .key = 'k' } } },
    .{ "<Space>", &.{KeyEvent{ .key = input.key.space }} },
    .{ "<C-x><C-c>", &.{ KeyEvent{ .key = 'x', .modifiers = input.mod.ctrl }, KeyEvent{ .key = 'c', .modifiers = input.mod.ctrl } } },
    .{ "<A-x><Tab>", &.{ KeyEvent{ .key = 'x', .modifiers = input.mod.alt }, KeyEvent{ .key = input.key.tab } } },
    .{ "<S-A-x><D-Del>", &.{ KeyEvent{ .key = 'x', .modifiers = input.mod.alt | input.mod.shift }, KeyEvent{ .key = input.key.delete, .modifiers = input.mod.super } } },
};

test "parse" {
    const alloc = std.testing.allocator;
    inline for (parse_test_cases) |case| {
        const parsed = try parse_key_events(alloc, case[0]);
        defer alloc.free(parsed);
        const expected: []const KeyEvent = case[1];
        const actual: []const KeyEvent = parsed;
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
    const alloc = std.testing.allocator;
    inline for (match_test_cases) |case| {
        const events = try parse_key_events(alloc, case[0]);
        defer alloc.free(events);
        const binding: Binding = .{
            .keys = try parse_key_events(alloc, case[1]),
            .command = undefined,
            .args = undefined,
        };
        defer alloc.free(binding.keys);

        try expectEqual(case[2], binding.match(events));
    }
}

test "json" {
    const alloc = std.testing.allocator;
    var bindings = try BindingSet.init(alloc, @embedFile("keybindings.json"), "vim", "normal");
    defer bindings.deinit();
    try bindings.process_key_event('j', .{ .key = 'j' });
    try bindings.process_key_event('k', .{ .key = 'k' });
    try bindings.process_key_event('g', .{ .key = 'g' });
    try bindings.process_key_event('i', .{ .key = 'i' });
    try bindings.process_key_event(0, .{ .key = 'i', .modifiers = input.mod.ctrl });
}
