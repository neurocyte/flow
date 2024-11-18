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

fn Handler(namespace_name: []const u8, mode_name: []const u8) type {
    return struct {
        allocator: std.mem.Allocator,
        bindings: BindingSet,

        pub fn create(allocator: std.mem.Allocator, opts: anytype) !EventHandler {
            const self: *@This() = try allocator.create(@This());
            self.* = .{
                .allocator = allocator,
                .bindings = try BindingSet.init(
                    allocator,
                    @embedFile("keybindings.json"),
                    namespace_name,
                    mode_name,
                    if (@hasField(@TypeOf(opts), "insert_command"))
                        opts.insert_command
                    else
                        "insert_chars",
                ),
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

//An association of an command with a triggering key chord
const Binding = struct {
    keys: []KeyEvent,
    command: []const u8,
    args: []const u8,
    command_id: ?command.ID = null,

    fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.keys);
        allocator.free(self.command);
        allocator.free(self.args);
    }

    fn len(self: Binding) usize {
        return self.keys.items.len;
    }

    fn execute(self: *@This()) !void {
        const id = self.command_id orelse
            command.get_id_cache(self.command, &self.command_id) orelse {
            return tp.exit_error(error.InputTargetNotFound, null);
        };
        try command.execute(id, .{ .args = .{ .buf = self.args } });
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
    syntax: KeySyntax = .flow,
    on_match_failure: OnMatchFailure = .ignore,
    current_sequence: std.ArrayList(KeyEvent),
    current_sequence_egc: std.ArrayList(u8),
    last_key_event_timestamp_ms: i64 = 0,
    input_buffer: std.ArrayList(u8),
    logger: log.Logger,
    namespace_name: []const u8,
    mode_name: []const u8,
    insert_command: []const u8,
    insert_command_id: ?command.ID = null,

    const KeySyntax = enum { flow, vim };
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

    fn init(allocator: std.mem.Allocator, json_string: []const u8, namespace_name: []const u8, mode_name: []const u8, insert_command: []const u8) !@This() {
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
            .insert_command = try allocator.dupe(u8, insert_command),
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
        self.allocator.free(self.insert_command);
    }

    fn load_json(self: *@This(), json_string: []const u8, namespace_name: []const u8, mode_name: []const u8) !void {
        defer self.bindings.append(.{
            .keys = self.allocator.dupe(KeyEvent, &[_]KeyEvent{.{ .key = input.key.f2 }}) catch @panic("failed to add toggle_input_mode fallback"),
            .command = self.allocator.dupe(u8, "toggle_input_mode") catch @panic("failed to add toggle_input_mode fallback"),
            .args = "",
        }) catch {};
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

    fn load_set_from_json(self: *BindingSet, mode_bindings: std.json.Value) (parse_flow.ParseError || parse_vim.ParseError || std.json.ParseFromValueError)!void {
        const JsonConfig = struct {
            bindings: []const []const std.json.Value,
            syntax: KeySyntax = .flow,
            on_match_failure: OnMatchFailure = .insert,
        };
        const parsed = try std.json.parseFromValue(JsonConfig, self.allocator, mode_bindings, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        self.syntax = parsed.value.syntax;
        self.on_match_failure = parsed.value.on_match_failure;
        bindings: for (parsed.value.bindings) |entry| {
            var state: enum { key_event, command, args } = .key_event;
            var keys: ?[]KeyEvent = null;
            var command_: ?[]const u8 = null;
            var args = std.ArrayListUnmanaged(std.json.Value){};
            defer {
                if (keys) |p| self.allocator.free(p);
                if (command_) |p| self.allocator.free(p);
                args.deinit(self.allocator);
            }
            for (entry) |token| {
                switch (state) {
                    .key_event => {
                        if (token != .string) {
                            self.logger.print_err("keybind.load", "ERROR: invalid binding key token {any} in '{s}' mode '{s}' ", .{
                                token,
                                self.namespace_name,
                                self.mode_name,
                            });
                            continue :bindings;
                        }
                        keys = switch (self.syntax) {
                            .flow => parse_flow.parse_key_events(self.allocator, token.string) catch |e| {
                                self.logger.print_err("keybind.load", "ERROR: {s} {s}", .{ @errorName(e), parse_flow.parse_error_message });
                                break;
                            },
                            .vim => parse_vim.parse_key_events(self.allocator, token.string) catch |e| {
                                self.logger.print_err("keybind.load.vim", "ERROR: {s} {s}", .{ @errorName(e), parse_vim.parse_error_message });
                                break;
                            },
                        };
                        state = .command;
                    },
                    .command => {
                        if (token != .string) {
                            self.logger.print_err("keybind.load", "ERROR: invalid binding command token {any} in '{s}' mode '{s}' ", .{
                                token,
                                self.namespace_name,
                                self.mode_name,
                            });
                            continue :bindings;
                        }
                        command_ = try self.allocator.dupe(u8, token.string);
                        state = .args;
                    },
                    .args => {
                        try args.append(self.allocator, token);
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
            for (args.items) |arg| try cbor.writeJsonValue(writer, arg);

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
        if (self.input_buffer.items.len > 0) {
            defer self.input_buffer.clearRetainingCapacity();
            const id = self.insert_command_id orelse
                command.get_id_cache(self.insert_command, &self.insert_command_id) orelse {
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
                    self.current_sequence.clearRetainingCapacity();
                    self.current_sequence_egc.clearRetainingCapacity();
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
                .insert => try self.insert_bytes(self.current_sequence_egc.items),
                .ignore => {},
            }
            self.current_sequence.clearRetainingCapacity();
            self.current_sequence_egc.clearRetainingCapacity();
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
        const parsed = try parse_vim.parse_key_events(alloc, case[0]);
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
        const events = try parse_vim.parse_key_events(alloc, case[0]);
        defer alloc.free(events);
        const binding: Binding = .{
            .keys = try parse_vim.parse_key_events(alloc, case[1]),
            .command = undefined,
            .args = undefined,
        };
        defer alloc.free(binding.keys);

        try expectEqual(case[2], binding.match(events));
    }
}

test "json" {
    const alloc = std.testing.allocator;
    var bindings = try BindingSet.init(alloc, @embedFile("keybindings.json"), "vim", "normal", "insert_chars");
    defer bindings.deinit();
    _ = try bindings.process_key_event('j', .{ .key = 'j' });
    _ = try bindings.process_key_event('k', .{ .key = 'k' });
    _ = try bindings.process_key_event('g', .{ .key = 'g' });
    _ = try bindings.process_key_event('i', .{ .key = 'i' });
    _ = try bindings.process_key_event(0, .{ .key = 'i', .modifiers = input.mod.ctrl });
}
