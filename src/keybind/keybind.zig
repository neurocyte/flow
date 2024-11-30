//TODO figure out how keybindings should be configured

//TODO figure out how to handle bindings that can take a numerical prefix

const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const builtin = @import("builtin");
const log = @import("log");
const root = @import("root");

const input = @import("input");
const command = @import("command");
const EventHandler = @import("EventHandler");
const KeyEvent = input.KeyEvent;

const parse_flow = @import("parse_flow.zig");
const parse_vim = @import("parse_vim.zig");

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

const builtin_keybinds = std.static_string_map.StaticStringMap([]const u8).initComptime(.{
    .{ "flow", @embedFile("builtin/flow.json") },
    .{ "vim", @embedFile("builtin/vim.json") },
    .{ "helix", @embedFile("builtin/helix.json") },
    .{ "emacs", @embedFile("builtin/emacs.json") },
});

fn Handler(namespace_name: []const u8, mode_name: []const u8) type {
    return struct {
        allocator: std.mem.Allocator,
        bindings: *const BindingSet,

        pub fn create(allocator: std.mem.Allocator, opts: anytype) !struct { EventHandler, *const KeybindHints } {
            const self: *@This() = try allocator.create(@This());
            self.* = .{
                .allocator = allocator,
                .bindings = try get_namespace_mode(
                    namespace_name,
                    mode_name,
                    if (@hasField(@TypeOf(opts), "insert_command"))
                        opts.insert_command
                    else
                        "insert_chars",
                ),
            };
            return .{ EventHandler.to_owned(self), self.bindings.hints() };
        }
        pub fn deinit(self: *@This()) void {
            self.allocator.destroy(self);
        }
        pub fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) error{Exit}!bool {
            return self.bindings.receive(from, m);
        }
    };
}

pub const Mode = struct {
    input_handler: EventHandler,
    event_handler: ?EventHandler = null,

    name: []const u8 = "",
    line_numbers: enum { absolute, relative } = .absolute,
    keybind_hints: *const KeybindHints,
    cursor_shape: CursorShape = .block,

    pub fn deinit(self: *Mode) void {
        self.input_handler.deinit();
        if (self.event_handler) |eh| eh.deinit();
    }
};

const NamespaceMap = std.StringHashMapUnmanaged(Namespace);

fn get_namespace_mode(namespace_name: []const u8, mode_name: []const u8, insert_command: []const u8) LoadError!*const BindingSet {
    const allocator = globals_allocator;
    const namespace = globals.namespaces.getPtr(namespace_name) orelse blk: {
        const namespace = try Namespace.load(allocator, namespace_name);
        const result = try globals.namespaces.getOrPut(allocator, try allocator.dupe(u8, namespace_name));
        std.debug.assert(result.found_existing == false);
        result.value_ptr.* = namespace;
        break :blk result.value_ptr;
    };
    var binding_set = namespace.modes.getPtr(mode_name) orelse {
        const logger = log.logger("keybind");
        logger.print_err("get_namespace_mode", "ERROR: mode not found: {s}", .{mode_name});
        var iter = namespace.modes.iterator();
        while (iter.next()) |entry| logger.print("available modes: {s}", .{entry.key_ptr.*});
        logger.deinit();
        return error.NotFound;
    };
    binding_set.set_insert_command(insert_command);
    return binding_set;
}

const LoadError = (error{ NotFound, NotAnObject } || std.json.ParseError(std.json.Scanner) || parse_flow.ParseError || parse_vim.ParseError || std.json.ParseFromValueError);

///A collection of modes that represent a switchable editor emulation
const Namespace = struct {
    name: []const u8,
    fallback: ?*const Namespace = null,
    default_mode: []const u8,
    modes: std.StringHashMapUnmanaged(BindingSet),

    init_command: Command = .{},
    deinit_command: Command = .{},

    fn load(allocator: std.mem.Allocator, namespace_name: []const u8) LoadError!Namespace {
        var free_json_string = true;
        const json_string = root.read_keybind_namespace(allocator, namespace_name) orelse blk: {
            free_json_string = false;
            break :blk builtin_keybinds.get(namespace_name) orelse return error.NotFound;
        };
        defer if (free_json_string) allocator.free(json_string);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_string, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.NotAnObject;

        var self: @This() = .{
            .name = try allocator.dupe(u8, namespace_name),
            .default_mode = "",
            .modes = .{},
        };
        errdefer allocator.free(self.name);
        var config = parsed.value.object.iterator();
        while (config.next()) |mode_entry| {
            if (!std.mem.eql(u8, mode_entry.key_ptr.*, "settings")) continue;
            try self.load_settings(allocator, mode_entry.value_ptr.*);
        }

        var modes = parsed.value.object.iterator();
        while (modes.next()) |mode_entry| {
            if (std.mem.eql(u8, mode_entry.key_ptr.*, "settings")) continue;
            try self.load_mode(allocator, mode_entry.key_ptr.*, mode_entry.value_ptr.*);
        }
        return self;
    }

    fn load_settings(self: *@This(), allocator: std.mem.Allocator, settings_value: std.json.Value) (parse_flow.ParseError || parse_vim.ParseError || std.json.ParseFromValueError)!void {
        const JsonSettings = struct {
            init_command: []const std.json.Value = &[_]std.json.Value{},
            deinit_command: []const std.json.Value = &[_]std.json.Value{},
            fallback: []const u8 = "flow",
        };
        const parsed = try std.json.parseFromValue(JsonSettings, allocator, settings_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        // self.fallback = try allocator.dupe(u8, parsed.value.fallback);
        try self.init_command.load(allocator, parsed.value.init_command);
        try self.deinit_command.load(allocator, parsed.value.deinit_command);
    }

    fn load_mode(self: *@This(), allocator: std.mem.Allocator, mode_name: []const u8, mode_value: std.json.Value) !void {
        try self.modes.put(allocator, try allocator.dupe(u8, mode_name), try BindingSet.load(allocator, mode_value));
    }

    fn get_mode(self: *@This(), mode_name: []const u8) error{}!*BindingSet {
        for (self.modes.items) |*mode_|
            if (std.mem.eql(u8, mode_.name, mode_name))
                return mode_;
        const mode_ = try self.modes.addOne();
        mode_.* = try BindingSet.init(self.modes.allocator, mode_name);
        return mode_;
    }
};

/// A stored command with arguments
const Command = struct {
    command: []const u8 = &[_]u8{},
    args: []const u8 = &[_]u8{},
    command_id: ?command.ID = null,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        return self.reset(allocator);
    }

    fn reset(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        allocator.free(self.args);
        self.command = &[_]u8{};
        self.args = &[_]u8{};
    }

    fn execute(self: *@This()) !void {
        const id = self.command_id orelse
            command.get_id_cache(self.command, &self.command_id) orelse {
            return tp.exit_fmt("CommandNotFound: {s}", .{self.command});
        };
        var buf: [2048]u8 = undefined;
        @memcpy(buf[0..self.args.len], self.args);
        try command.execute(id, .{ .args = .{ .buf = buf[0..self.args.len] } });
    }

    fn load(self: *@This(), allocator: std.mem.Allocator, tokens: []const std.json.Value) (parse_flow.ParseError || parse_vim.ParseError)!void {
        self.reset(allocator);
        if (tokens.len == 0) return;
        var state: enum { command, args } = .command;
        var args = std.ArrayListUnmanaged(std.json.Value){};
        defer args.deinit(allocator);

        for (tokens) |token| {
            switch (state) {
                .command => {
                    if (token != .string) {
                        const logger = log.logger("keybind");
                        logger.print_err("keybind.load", "ERROR: invalid command token {any}", .{token});
                        logger.deinit();
                        return error.InvalidFormat;
                    }
                    self.command = try allocator.dupe(u8, token.string);
                    state = .args;
                },
                .args => try args.append(allocator, token),
            }
        }

        var args_cbor = std.ArrayListUnmanaged(u8){};
        defer args_cbor.deinit(allocator);
        const writer = args_cbor.writer(allocator);
        try cbor.writeArrayHeader(writer, args.items.len);
        for (args.items) |arg| try cbor.writeJsonValue(writer, arg);
        self.args = try args_cbor.toOwnedSlice(allocator);
    }
};

//An association of an command with a triggering key chord
const Binding = struct {
    key_events: []KeyEvent,
    command: Command,

    fn len(self: Binding) usize {
        return self.key_events.items.len;
    }

    const MatchResult = enum { match_impossible, match_possible, matched };

    fn match(self: *const @This(), match_key_events: []const KeyEvent) MatchResult {
        if (self.key_events.len == 0) return .match_impossible;
        for (self.key_events, 0..) |key_event, i| {
            if (match_key_events.len <= i) return .match_possible;
            if (!key_event.eql(match_key_events[i])) return .match_impossible;
        }
        return if (self.key_events.len == match_key_events.len) .matched else .match_possible;
    }
};

pub const KeybindHints = std.StringHashMapUnmanaged([]u8);

const max_key_sequence_time_interval = 750;
const max_input_buffer_size = 4096;

var globals: struct {
    namespaces: NamespaceMap = .{},
    input_buffer: std.ArrayListUnmanaged(u8) = .{},
    insert_command: []const u8 = "",
    insert_command_id: ?command.ID = null,
    last_key_event_timestamp_ms: i64 = 0,
    current_sequence: std.ArrayListUnmanaged(KeyEvent) = .{},
    current_sequence_egc: std.ArrayListUnmanaged(u8) = .{},
} = .{};
const globals_allocator = std.heap.c_allocator;

//A Collection of keybindings
const BindingSet = struct {
    press: std.ArrayListUnmanaged(Binding) = .{},
    release: std.ArrayListUnmanaged(Binding) = .{},
    syntax: KeySyntax = .flow,
    on_match_failure: OnMatchFailure = .ignore,
    insert_command: []const u8 = "",
    hints_map: KeybindHints = .{},

    const KeySyntax = enum { flow, vim };
    const OnMatchFailure = enum { insert, ignore };

    fn load(allocator: std.mem.Allocator, mode_bindings: std.json.Value) (error{OutOfMemory} || parse_flow.ParseError || parse_vim.ParseError || std.json.ParseFromValueError)!@This() {
        var self: @This() = .{};

        defer self.press.append(allocator, .{
            .key_events = allocator.dupe(KeyEvent, &[_]KeyEvent{.{ .key = input.key.f2 }}) catch @panic("failed to add toggle_input_mode fallback"),
            .command = .{
                .command = allocator.dupe(u8, "toggle_input_mode") catch @panic("failed to add toggle_input_mode fallback"),
                .args = "",
            },
        }) catch {};

        const JsonConfig = struct {
            press: []const []const std.json.Value = &[_][]std.json.Value{},
            release: []const []const std.json.Value = &[_][]std.json.Value{},
            syntax: KeySyntax = .flow,
            on_match_failure: OnMatchFailure = .insert,
        };
        const parsed = try std.json.parseFromValue(JsonConfig, allocator, mode_bindings, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        self.syntax = parsed.value.syntax;
        self.on_match_failure = parsed.value.on_match_failure;
        try self.load_event(allocator, &self.press, input.event.press, parsed.value.press);
        try self.load_event(allocator, &self.release, input.event.release, parsed.value.release);
        self.build_hints(allocator) catch {};
        return self;
    }

    fn load_event(self: *BindingSet, allocator: std.mem.Allocator, dest: *std.ArrayListUnmanaged(Binding), event: input.Event, bindings: []const []const std.json.Value) (parse_flow.ParseError || parse_vim.ParseError)!void {
        bindings: for (bindings) |entry| {
            var state: enum { key_event, command, args } = .key_event;
            var key_events: ?[]KeyEvent = null;
            var command_: ?[]const u8 = null;
            var args = std.ArrayListUnmanaged(std.json.Value){};
            defer {
                if (key_events) |p| allocator.free(p);
                if (command_) |p| allocator.free(p);
                args.deinit(allocator);
            }
            for (entry) |token| {
                switch (state) {
                    .key_event => {
                        if (token != .string) {
                            const logger = log.logger("keybind");
                            logger.print_err("keybind.load", "ERROR: invalid binding key token {any}", .{token});
                            logger.deinit();
                            continue :bindings;
                        }
                        key_events = switch (self.syntax) {
                            .flow => parse_flow.parse_key_events(allocator, event, token.string) catch |e| {
                                const logger = log.logger("keybind");
                                logger.print_err("keybind.load", "ERROR: {s} {s}", .{ @errorName(e), parse_flow.parse_error_message });
                                logger.deinit();
                                break;
                            },
                            .vim => parse_vim.parse_key_events(allocator, event, token.string) catch |e| {
                                const logger = log.logger("keybind");
                                logger.print_err("keybind.load.vim", "ERROR: {s} {s}", .{ @errorName(e), parse_vim.parse_error_message });
                                logger.deinit();
                                break;
                            },
                        };
                        state = .command;
                    },
                    .command => {
                        if (token != .string) {
                            const logger = log.logger("keybind");
                            logger.print_err("keybind.load", "ERROR: invalid binding command token {any}", .{token});
                            logger.deinit();
                            continue :bindings;
                        }
                        command_ = try allocator.dupe(u8, token.string);
                        state = .args;
                    },
                    .args => {
                        try args.append(allocator, token);
                    },
                }
            }
            if (state != .args) {
                if (builtin.is_test) @panic("invalid state");
                continue;
            }
            var args_cbor = std.ArrayListUnmanaged(u8){};
            defer args_cbor.deinit(allocator);
            const writer = args_cbor.writer(allocator);
            try cbor.writeArrayHeader(writer, args.items.len);
            for (args.items) |arg| try cbor.writeJsonValue(writer, arg);

            try dest.append(allocator, .{
                .key_events = key_events.?,
                .command = .{
                    .command = command_.?,
                    .args = try args_cbor.toOwnedSlice(allocator),
                },
            });
            key_events = null;
            command_ = null;
        }
    }

    fn hints(self: *const @This()) *const KeybindHints {
        return &self.hints_map;
    }

    fn build_hints(self: *@This(), allocator: std.mem.Allocator) !void {
        const hints_map = &self.hints_map;

        for (self.press.items) |binding| {
            var hint = if (hints_map.get(binding.command.command)) |previous|
                std.ArrayList(u8).fromOwnedSlice(allocator, previous)
            else
                std.ArrayList(u8).init(allocator);
            defer hint.deinit();
            const writer = hint.writer();
            if (hint.items.len > 0) try writer.writeAll(", ");
            const count = binding.key_events.len;
            for (binding.key_events, 0..) |key_, n| {
                var key = key_;
                key.event = 0;
                switch (self.syntax) {
                    // .flow => {
                    else => {
                        try writer.print("{}", .{key});
                        if (n < count - 1)
                            try writer.writeAll(" ");
                    },
                }
            }
            try hints_map.put(allocator, binding.command.command, try hint.toOwnedSlice());
        }
    }

    fn set_insert_command(self: *@This(), insert_command: []const u8) void {
        self.insert_command = insert_command;
    }

    fn insert_bytes(self: *const @This(), bytes: []const u8) !void {
        if (globals.input_buffer.items.len + 4 > max_input_buffer_size)
            try self.flush();
        try globals.input_buffer.appendSlice(globals_allocator, bytes);
    }

    fn flush(self: *const @This()) !void {
        if (globals.input_buffer.items.len > 0) {
            defer globals.input_buffer.clearRetainingCapacity();
            if (!std.mem.eql(u8, self.insert_command, globals.insert_command)) {
                globals.insert_command = self.insert_command;
                globals.insert_command_id = null;
            }
            const id = globals.insert_command_id orelse
                command.get_id_cache(globals.insert_command, &globals.insert_command_id) orelse {
                return tp.exit_error(error.InputTargetNotFound, null);
            };
            if (!builtin.is_test) {
                try command.execute(id, command.fmt(.{globals.input_buffer.items}));
            }
        }
    }

    fn receive(self: *const @This(), _: tp.pid_ref, m: tp.message) error{Exit}!bool {
        var event: input.Event = 0;
        var keypress: input.Key = 0;
        var egc: input.Key = 0;
        var modifiers: input.Mods = 0;

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
                try binding.command.execute();
            }
        } else if (try m.match(.{"F"})) {
            self.flush() catch |e| return tp.exit_error(e, @errorReturnTrace());
        }
        return false;
    }

    //register a key press and try to match it with a binding
    fn process_key_event(self: *const @This(), egc: input.Key, event_: KeyEvent) !?*Binding {
        var event = event_;

        //ignore modifiers for modifier key events
        event.modifiers = switch (event.key) {
            input.key.left_control, input.key.right_control => 0,
            input.key.left_alt, input.key.right_alt => 0,
            else => event.modifiers,
        };

        if (event.event == input.event.release)
            return self.process_key_release_event(event);

        //clear key history if enough time has passed since last key press
        const timestamp = std.time.milliTimestamp();
        if (globals.last_key_event_timestamp_ms - timestamp > max_key_sequence_time_interval) {
            try self.terminate_sequence(.timeout, egc, event);
        }
        globals.last_key_event_timestamp_ms = timestamp;

        try globals.current_sequence.append(globals_allocator, event);
        var buf: [6]u8 = undefined;
        const bytes = try input.ucs32_to_utf8(&[_]u32{egc}, &buf);
        if (!input.is_non_input_key(event.key))
            try globals.current_sequence_egc.appendSlice(globals_allocator, buf[0..bytes]);

        var all_matches_impossible = true;

        for (self.press.items) |*binding| {
            switch (binding.match(globals.current_sequence.items)) {
                .matched => {
                    globals.current_sequence.clearRetainingCapacity();
                    globals.current_sequence_egc.clearRetainingCapacity();
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

    fn process_key_release_event(self: *const @This(), event: KeyEvent) !?*Binding {
        for (self.release.items) |*binding| {
            switch (binding.match(&[_]KeyEvent{event})) {
                .matched => return binding,
                .match_possible => {},
                .match_impossible => {},
            }
        }
        return null;
    }

    const AbortType = enum { timeout, match_impossible };
    fn terminate_sequence(self: *const @This(), abort_type: AbortType, egc: input.Key, key_event: KeyEvent) anyerror!void {
        _ = egc;
        _ = key_event;
        if (abort_type == .match_impossible) {
            switch (self.on_match_failure) {
                .insert => try self.insert_bytes(globals.current_sequence_egc.items),
                .ignore => {},
            }
            globals.current_sequence.clearRetainingCapacity();
            globals.current_sequence_egc.clearRetainingCapacity();
        } else if (abort_type == .timeout) {
            try self.insert_bytes(globals.current_sequence_egc.items);
            globals.current_sequence_egc.clearRetainingCapacity();
            globals.current_sequence.clearRetainingCapacity();
        }
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

pub fn get_or_create_namespace_config_file(allocator: std.mem.Allocator, namespace_name: []const u8) ![]const u8 {
    if (root.read_keybind_namespace(allocator, namespace_name)) |content| {
        allocator.free(content);
    } else {
        try root.write_keybind_namespace(
            namespace_name,
            builtin_keybinds.get(namespace_name) orelse builtin_keybinds.get("flow").?,
        );
    }
    return try root.get_keybind_namespace_file_name(namespace_name);
}

const expectEqual = std.testing.expectEqual;

const parse_test_cases = .{
    //input, expected
    .{ "j", &.{KeyEvent{ .key = 'j' }} },
    .{ "J", &.{KeyEvent{ .key = 'j', .modifiers = input.mod.shift }} },
    .{ "jk", &.{ KeyEvent{ .key = 'j' }, KeyEvent{ .key = 'k' } } },
    .{ "<Space>", &.{KeyEvent{ .key = input.key.space }} },
    .{ "<C-x><C-c>", &.{ KeyEvent{ .key = 'x', .modifiers = input.mod.ctrl }, KeyEvent{ .key = 'c', .modifiers = input.mod.ctrl } } },
    .{ "<A-x><Tab>", &.{ KeyEvent{ .key = 'x', .modifiers = input.mod.alt }, KeyEvent{ .key = input.key.tab } } },
    .{ "<S-A-x><D-Del>", &.{
        KeyEvent{ .key = 'x', .modifiers = input.mod.alt | input.mod.shift },
        KeyEvent{ .key = input.key.delete, .modifiers = input.mod.super },
    } },
    .{ ".", &.{KeyEvent{ .key = '.' }} },
    .{ ",", &.{KeyEvent{ .key = ',' }} },
    .{ "`", &.{KeyEvent{ .key = '`' }} },
    .{ "<S--><Home>", &.{
        KeyEvent{ .key = '-', .modifiers = input.mod.shift },
        KeyEvent{ .key = input.key.home },
    } },
};

test "parse" {
    const alloc = std.testing.allocator;
    inline for (parse_test_cases) |case| {
        const parsed = try parse_vim.parse_key_events(alloc, input.event.press, case[0]);
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
        const events = try parse_vim.parse_key_events(alloc, input.event.press, case[0]);
        defer alloc.free(events);
        const binding: Binding = .{
            .keys = try parse_vim.parse_key_events(alloc, input.event.press, case[1]),
            .command = .{},
        };
        defer alloc.free(binding.keys);

        try expectEqual(case[2], binding.match(events));
    }
}

test "json" {
    var bindings: BindingSet = .{};
    _ = try bindings.process_key_event('j', .{ .key = 'j' });
    _ = try bindings.process_key_event('k', .{ .key = 'k' });
    _ = try bindings.process_key_event('g', .{ .key = 'g' });
    _ = try bindings.process_key_event('i', .{ .key = 'i' });
    _ = try bindings.process_key_event(0, .{ .key = 'i', .modifiers = input.mod.ctrl });
}
