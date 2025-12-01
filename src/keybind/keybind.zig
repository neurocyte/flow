//TODO figure out how keybindings should be configured

//TODO figure out how to handle bindings that can take a numerical prefix

const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const builtin = @import("builtin");
const log = @import("log");
const root = @import("soft_root").root;

const input = @import("input");
const command = @import("command");
const EventHandler = @import("EventHandler");
const KeyEvent = input.KeyEvent;
const SelectionStyle = @import("Buffer").Selection.Style;
pub const CursorShape = @import("config").CursorShape;

const parse_flow = @import("parse_flow.zig");
const parse_vim = @import("parse_vim.zig");

const builtin_keybinds = std.StaticStringMap([]const u8).initComptime(.{
    .{ "flow", @embedFile("builtin/flow.json") },
    .{ "vim", @embedFile("builtin/vim.json") },
    .{ "helix", @embedFile("builtin/helix.json") },
    .{ "emacs", @embedFile("builtin/emacs.json") },
});

var integer_argument: ?usize = null;

var commands: Commands = undefined;
const Commands = command.Collection(struct {
    pub const Target = void;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn add_integer_argument_digit(_: *void, ctx: Ctx) Result {
        var digit: usize = undefined;
        if (!try ctx.args.match(.{tp.extract(&digit)}))
            return error.InvalidIntegerParameterArgument;
        if (digit > 9)
            return error.InvalidIntegerParameterDigit;
        integer_argument = if (integer_argument) |x| x * 10 + digit else digit;
    }
    pub const add_integer_argument_digit_meta: Meta = .{ .arguments = &.{.integer} };
});

pub fn init() !void {
    var v: void = {};
    try commands.init(&v);
}

pub fn mode(mode_name: []const u8, allocator: std.mem.Allocator, opts: anytype) !Mode {
    return Handler.create(mode_name, allocator, opts) catch |e| switch (e) {
        error.NotFound => return error.Stop,
        else => return e,
    };
}

pub const default_mode = "normal";
pub const default_namespace = "flow";

const Handler = struct {
    allocator: std.mem.Allocator,
    bindings: *const BindingSet,

    fn create(mode_name: []const u8, allocator: std.mem.Allocator, opts: anytype) !Mode {
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);
        const insert_command = if (@hasField(@TypeOf(opts), "insert_command"))
            opts.insert_command
        else
            "insert_chars";
        const bindings = try get_mode_binding_set(mode_name, insert_command);
        self.* = .{
            .allocator = allocator,
            .bindings = bindings,
        };
        return .{
            .allocator = allocator,
            .input_handler = EventHandler.to_owned(self),
            .bindings = bindings,
            .keybind_hints = self.bindings.hints(),
            .mode = try allocator.dupe(u8, mode_name),
            .name = self.bindings.name,
            .line_numbers = self.bindings.line_numbers,
            .cursor_shape = self.bindings.cursor_shape,
            .selection_style = self.bindings.selection_style,
            .init_command = self.bindings.init_command,
            .deinit_command = self.bindings.deinit_command,
            .insert_command = try allocator.dupe(u8, insert_command),
        };
    }
    fn replace(mode_: *Mode, mode_name: []const u8, allocator: std.mem.Allocator) !void {
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .bindings = try get_mode_binding_set(mode_name, mode_.insert_command),
        };

        if (mode_.deinit_command) |deinit_command| deinit_command.execute_const();
        if (mode_.input_handler) |ih| ih.deinit();
        mode_.allocator.free(mode_.mode);
        mode_.mode = try allocator.dupe(u8, mode_name);
        mode_.allocator = allocator;

        mode_.input_handler = EventHandler.to_owned(self);
        mode_.keybind_hints = self.bindings.hints();
        mode_.name = self.bindings.name;
        mode_.line_numbers = self.bindings.line_numbers;
        mode_.cursor_shape = self.bindings.cursor_shape;
        mode_.selection_style = self.bindings.selection_style;
        mode_.init_command = self.bindings.init_command;
        mode_.deinit_command = self.bindings.deinit_command;
        if (mode_.init_command) |init_command| init_command.execute_const();
    }
    pub fn deinit(self: *@This()) void {
        self.allocator.destroy(self);
    }
    pub fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) error{Exit}!bool {
        return self.bindings.receive(from, m);
    }
};

pub const Mode = struct {
    allocator: std.mem.Allocator,
    input_handler: ?EventHandler,
    event_handler: ?EventHandler = null,

    mode: []const u8,
    name: []const u8 = "",
    line_numbers: LineNumbers = .inherit,
    bindings: *const BindingSet,
    keybind_hints: *const KeybindHints,
    cursor_shape: ?CursorShape = null,
    selection_style: SelectionStyle,
    init_command: ?Command = null,
    deinit_command: ?Command = null,
    initialized: bool = false,
    insert_command: []const u8,

    pub fn run_init(self: *Mode) void {
        if (self.initialized) return;
        self.initialized = true;
        clear_integer_argument();
        if (self.init_command) |init_command| init_command.execute_const();
    }

    pub fn replace(self: *Mode, mode_name: []const u8, allocator: std.mem.Allocator) !void {
        Handler.replace(self, mode_name, allocator) catch |e| switch (e) {
            error.NotFound => return error.Stop,
            else => return e,
        };
    }

    pub fn deinit(self: *Mode) void {
        if (self.deinit_command) |deinit_command| deinit_command.execute_const();
        if (self.event_handler) |eh| eh.deinit();
        if (self.input_handler) |ih| ih.deinit();
        self.allocator.free(self.insert_command);
        self.allocator.free(self.mode);

        self.deinit_command = null;
        self.event_handler = null;
        self.input_handler = null;
        self.mode = &.{};

        self.name = "";
        self.line_numbers = .inherit;
        self.keybind_hints = &.{};
        self.cursor_shape = null;
        self.selection_style = .normal;
        self.init_command = null;
        self.deinit_command = null;
        self.initialized = false;
    }

    pub fn current_bindings(self: *const Mode, allocator: std.mem.Allocator, select_mode: SelectMode) error{OutOfMemory}![]const Binding {
        return self.bindings.get_bindings(allocator, select_mode);
    }

    pub fn current_key_event_sequence_bindings(self: *const Mode, allocator: std.mem.Allocator, select_mode: SelectMode) error{OutOfMemory}![]const Binding {
        if (globals.current_sequence.items.len == 0) return &.{};
        return self.bindings.get_matches_for_key_event_sequence(allocator, globals.current_sequence.items, select_mode);
    }
};

const NamespaceMap = std.StringHashMapUnmanaged(Namespace);

pub fn get_namespaces(allocator: std.mem.Allocator) ![]const []const u8 {
    const namespaces = try root.list_keybind_namespaces(allocator);
    defer {
        for (namespaces) |namespace| allocator.free(namespace);
        allocator.free(namespaces);
    }
    var result: std.ArrayList([]const u8) = .empty;
    try result.append(allocator, try allocator.dupe(u8, "flow"));
    try result.append(allocator, try allocator.dupe(u8, "emacs"));
    try result.append(allocator, try allocator.dupe(u8, "vim"));
    try result.append(allocator, try allocator.dupe(u8, "helix"));
    for (namespaces) |namespace| {
        var exists = false;
        for (result.items) |existing|
            if (std.mem.eql(u8, namespace, existing)) {
                exists = true;
                break;
            };
        if (!exists)
            try result.append(allocator, try allocator.dupe(u8, namespace));
    }
    return result.toOwnedSlice(allocator);
}

pub fn get_namespace() []const u8 {
    return current_namespace().name;
}

fn current_namespace() *const Namespace {
    return globals.current_namespace orelse @panic("no keybind namespace set");
}

fn get_or_load_namespace(namespace_name: []const u8) LoadError!*const Namespace {
    const allocator = globals_allocator;
    return globals.namespaces.getPtr(namespace_name) orelse blk: {
        const namespace = try Namespace.load(allocator, namespace_name);
        const result = try globals.namespaces.getOrPut(allocator, try allocator.dupe(u8, namespace_name));
        std.debug.assert(result.found_existing == false);
        result.value_ptr.* = namespace;
        break :blk result.value_ptr;
    };
}

pub fn set_namespace(namespace_name: []const u8) LoadError!void {
    const new_namespace = try get_or_load_namespace(namespace_name);
    if (globals.current_namespace) |old_namespace|
        if (old_namespace.deinit_command) |deinit_command|
            deinit_command.execute_const();
    globals.current_namespace = new_namespace;
    if (new_namespace.init_command) |init_command|
        init_command.execute_const();
}

fn get_mode_binding_set(mode_name: []const u8, insert_command: []const u8) LoadError!*const BindingSet {
    const namespace = current_namespace();
    var binding_set = namespace.get_mode(mode_name) orelse {
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

pub const LoadError = (error{ NotFound, NotAnObject, WriteFailed } || std.json.ParseError(std.json.Scanner) || parse_flow.ParseError || parse_vim.ParseError || std.json.ParseFromValueError);

///A collection of modes that represent a switchable editor emulation
const Namespace = struct {
    name: []const u8,
    fallback: ?*const Namespace = null,
    no_defaults: bool = false,
    modes: std.StringHashMapUnmanaged(BindingSet),

    init_command: ?Command = null,
    deinit_command: ?Command = null,

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
            .modes = .{},
        };
        errdefer allocator.free(self.name);
        var config = parsed.value.object.iterator();
        while (config.next()) |mode_entry| {
            if (!std.mem.eql(u8, mode_entry.key_ptr.*, "settings")) continue;
            try self.load_settings(allocator, mode_entry.value_ptr.*);
        }

        if (!self.no_defaults and !std.mem.eql(u8, self.name, default_namespace) and self.fallback == null)
            self.fallback = try get_or_load_namespace(default_namespace);

        var modes = parsed.value.object.iterator();
        while (modes.next()) |mode_entry| {
            if (std.mem.eql(u8, mode_entry.key_ptr.*, "settings")) continue;
            try self.load_mode(allocator, mode_entry.key_ptr.*, mode_entry.value_ptr.*);
        }

        if (self.fallback) |fallback| {
            var iter = fallback.modes.iterator();
            while (iter.next()) |entry|
                if (self.get_mode(entry.key_ptr.*) == null)
                    try self.copy_mode(allocator, entry.key_ptr.*, entry.value_ptr);
        }
        return self;
    }

    fn load_settings(self: *@This(), allocator: std.mem.Allocator, settings_value: std.json.Value) LoadError!void {
        const JsonSettings = struct {
            init_command: ?[]const std.json.Value = null,
            deinit_command: ?[]const std.json.Value = null,
            inherit: ?[]const u8 = null,
            no_defaults: ?bool = null,
        };
        const parsed = try std.json.parseFromValue(JsonSettings, allocator, settings_value, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        self.fallback = if (parsed.value.inherit) |fallback| try get_or_load_namespace(fallback) else null;
        self.no_defaults = parsed.value.no_defaults orelse false;
        if (parsed.value.init_command) |cmd| self.init_command = try Command.load(allocator, cmd);
        if (parsed.value.deinit_command) |cmd| self.deinit_command = try Command.load(allocator, cmd);
    }

    fn load_mode(self: *@This(), allocator: std.mem.Allocator, mode_name: []const u8, mode_value: std.json.Value) !void {
        const fallback_mode = if (self.fallback) |fallback| fallback.get_mode(mode_name) orelse fallback.get_mode(default_mode) else null;
        try self.modes.put(allocator, try allocator.dupe(u8, mode_name), try BindingSet.load(allocator, self.name, mode_value, fallback_mode, self));
    }

    fn copy_mode(self: *@This(), allocator: std.mem.Allocator, mode_name: []const u8, fallback_mode: *const BindingSet) !void {
        try self.modes.put(allocator, mode_name, try BindingSet.copy(allocator, fallback_mode));
    }

    fn get_mode(self: *const @This(), mode_name: []const u8) ?*BindingSet {
        return self.modes.getPtr(mode_name);
    }
};

/// A stored command with arguments
const Command = struct {
    command: []const u8,
    args: []const u8,
    command_id: ?command.ID = null,

    fn execute(self: *@This()) !void {
        const id = self.command_id orelse
            command.get_id_cache(self.command, &self.command_id) orelse {
            return command.notFoundError(self.command);
        };
        var buf: [2048]u8 = undefined;
        @memcpy(buf[0..self.args.len], self.args);
        if (integer_argument) |int_arg| {
            if (cbor.match(self.args, .{}) catch false and has_integer_argument(id)) {
                integer_argument = null;
                try command.execute(id, command.fmt(.{int_arg}));
                return;
            }
        }
        try command.execute(id, .{ .args = .{ .buf = buf[0..self.args.len] } });
    }

    fn execute_const(self: *const @This()) void {
        var buf: [2048]u8 = undefined;
        @memcpy(buf[0..self.args.len], self.args);
        command.executeName(self.command, .{ .args = .{ .buf = buf[0..self.args.len] } }) catch |e| {
            const logger = log.logger("keybind");
            logger.print_err("init/deinit_command", "ERROR: {s} {s}", .{ self.command, @errorName(e) });
            logger.deinit();
        };
    }

    fn has_integer_argument(id: command.ID) bool {
        const args = command.get_arguments(id) orelse return false;
        return args.len == 1 and args[0] == .integer;
    }

    fn load(allocator: std.mem.Allocator, tokens: []const std.json.Value) (error{WriteFailed} || parse_flow.ParseError || parse_vim.ParseError)!Command {
        if (tokens.len == 0) return error.InvalidFormat;
        var state: enum { command, args } = .command;
        var args = std.ArrayListUnmanaged(std.json.Value){};
        defer args.deinit(allocator);
        var command_: []const u8 = &[_]u8{};

        for (tokens) |token| {
            switch (state) {
                .command => {
                    if (token != .string) {
                        const logger = log.logger("keybind");
                        logger.print_err("keybind.load", "ERROR: invalid command token {any}", .{token});
                        logger.deinit();
                        return error.InvalidFormat;
                    }
                    command_ = try allocator.dupe(u8, token.string);
                    state = .args;
                },
                .args => {
                    switch (token) {
                        .string, .integer, .float, .bool => {},
                        else => {
                            const json = try std.json.Stringify.valueAlloc(allocator, token, .{});
                            defer allocator.free(json);
                            const logger = log.logger("keybind");
                            logger.print_err("keybind.load", "ERROR: invalid command argument '{s}'", .{json});
                            logger.deinit();
                            return error.InvalidFormat;
                        },
                    }
                    try args.append(allocator, token);
                },
            }
        }

        var args_cbor: std.Io.Writer.Allocating = .init(allocator);
        defer args_cbor.deinit();
        const writer = &args_cbor.writer;
        try cbor.writeArrayHeader(writer, args.items.len);
        for (args.items) |arg| try cbor.writeJsonValue(writer, arg);
        return .{
            .command = command_,
            .args = try args_cbor.toOwnedSlice(),
        };
    }
};

//An association of an command with a triggering key chord
pub const Binding = struct {
    key_events: []KeyEvent,
    commands: []Command,

    fn len(self: Binding) usize {
        return self.key_events.items.len;
    }

    const MatchResult = enum { match_impossible, match_possible, matched };

    fn match(self: *const @This(), match_key_events: []const KeyEvent) MatchResult {
        if (self.key_events.len == 0) return .match_impossible;
        for (self.key_events, 0..) |key_event, i| {
            if (match_key_events.len <= i) return .match_possible;
            if (!(key_event.eql(match_key_events[i]) or key_event.eql_unshifted(match_key_events[i])))
                return .match_impossible;
        }
        return if (self.key_events.len == match_key_events.len) .matched else .match_possible;
    }
};

pub const KeybindHints = std.StringHashMapUnmanaged([]u8);

const max_key_sequence_time_interval = 1500;
const max_input_buffer_size = 4096;

var globals: struct {
    namespaces: NamespaceMap = .{},
    current_namespace: ?*const Namespace = null,
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
    name: []const u8,
    line_numbers: LineNumbers = .inherit,
    cursor_shape: ?CursorShape = null,
    selection_style: SelectionStyle,
    insert_command: []const u8 = "",
    hints_map: KeybindHints = .{},
    init_command: ?Command = null,
    deinit_command: ?Command = null,

    const KeySyntax = enum { flow, vim };
    const OnMatchFailure = enum { insert, ignore };

    fn load(allocator: std.mem.Allocator, namespace_name: []const u8, mode_bindings: std.json.Value, fallback: ?*const BindingSet, namespace: *Namespace) (error{ OutOfMemory, WriteFailed } || parse_flow.ParseError || parse_vim.ParseError || std.json.ParseFromValueError)!@This() {
        var self: @This() = .{ .name = undefined, .selection_style = undefined };

        const JsonConfig = struct {
            press: []const []const std.json.Value = &[_][]std.json.Value{},
            release: []const []const std.json.Value = &[_][]std.json.Value{},
            syntax: KeySyntax = .flow,
            on_match_failure: OnMatchFailure = .insert,
            name: ?[]const u8 = null,
            line_numbers: LineNumbers = .inherit,
            cursor: ?CursorShape = null,
            inherit: ?[]const u8 = null,
            inherits: ?[][]const u8 = null,
            selection: ?SelectionStyle = null,
            init_command: ?[]const std.json.Value = null,
            deinit_command: ?[]const std.json.Value = null,
        };
        const parsed = try std.json.parseFromValue(JsonConfig, allocator, mode_bindings, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        self.syntax = parsed.value.syntax;
        self.on_match_failure = parsed.value.on_match_failure;
        self.name = try allocator.dupe(u8, parsed.value.name orelse namespace_name);
        self.line_numbers = parsed.value.line_numbers;
        self.cursor_shape = parsed.value.cursor;
        self.selection_style = parsed.value.selection orelse .normal;
        if (parsed.value.init_command) |cmd| self.init_command = try Command.load(allocator, cmd);
        if (parsed.value.deinit_command) |cmd| self.deinit_command = try Command.load(allocator, cmd);
        try self.load_event(allocator, &self.press, input.event.press, parsed.value.press);
        try self.load_event(allocator, &self.release, input.event.release, parsed.value.release);
        if (parsed.value.inherits) |sibling_fallbacks| {
            for (sibling_fallbacks) |sibling_fallback| if (namespace.get_mode(sibling_fallback)) |sib| {
                for (sib.press.items) |binding| try append_if_not_match(allocator, &self.press, binding);
                for (sib.release.items) |binding| try append_if_not_match(allocator, &self.release, binding);
            };
        } else if (parsed.value.inherit) |sibling_fallback| {
            if (namespace.get_mode(sibling_fallback)) |sib| {
                for (sib.press.items) |binding| try append_if_not_match(allocator, &self.press, binding);
                for (sib.release.items) |binding| try append_if_not_match(allocator, &self.release, binding);
            }
        } else if (fallback) |fallback_| {
            for (fallback_.press.items) |binding| try append_if_not_match(allocator, &self.press, binding);
            for (fallback_.release.items) |binding| try append_if_not_match(allocator, &self.release, binding);
        }
        self.build_hints(allocator) catch {};
        return self;
    }

    fn load_event(self: *BindingSet, allocator: std.mem.Allocator, dest: *std.ArrayListUnmanaged(Binding), event: input.Event, bindings: []const []const std.json.Value) (error{WriteFailed} || parse_flow.ParseError || parse_vim.ParseError)!void {
        _ = event;
        bindings: for (bindings) |entry| {
            if (entry.len < 2) {
                const logger = log.logger("keybind");
                logger.print_err("keybind.load", "ERROR: invalid binding definition {any}", .{entry});
                logger.deinit();
                continue :bindings;
            }
            const keys = entry[0];
            if (keys != .string) {
                const logger = log.logger("keybind");
                logger.print_err("keybind.load", "ERROR: invalid binding key definition {any}", .{keys});
                logger.deinit();
                continue :bindings;
            }

            const key_events = switch (self.syntax) {
                .flow => parse_flow.parse_key_events(allocator, keys.string) catch |e| {
                    const logger = log.logger("keybind");
                    logger.print_err("keybind.load", "ERROR: {s} {s}", .{ @errorName(e), parse_flow.parse_error_message });
                    logger.deinit();
                    break;
                },
                .vim => parse_vim.parse_key_events(allocator, keys.string) catch |e| {
                    const logger = log.logger("keybind");
                    logger.print_err("keybind.load.vim", "ERROR: {s} {s}", .{ @errorName(e), parse_vim.parse_error_message });
                    logger.deinit();
                    break;
                },
            };
            errdefer allocator.free(key_events);

            const cmd = entry[1];
            var cmds: std.ArrayList(Command) = .empty;
            defer cmds.deinit(allocator);
            if (cmd == .string) {
                try cmds.append(allocator, try Command.load(allocator, entry[1..]));
            } else {
                for (entry[1..]) |cmd_entry| {
                    if (cmd_entry != .array) {
                        const json = try std.json.Stringify.valueAlloc(allocator, cmd_entry, .{});
                        defer allocator.free(json);
                        const logger = log.logger("keybind");
                        logger.print_err("keybind.load", "ERROR: invalid command definition {s}", .{json});
                        logger.deinit();
                        continue :bindings;
                    }
                    try cmds.append(allocator, try Command.load(allocator, cmd_entry.array.items));
                }
            }
            try dest.append(allocator, .{
                .key_events = key_events,
                .commands = try cmds.toOwnedSlice(allocator),
            });
        }
    }

    fn copy(allocator: std.mem.Allocator, fallback: *const BindingSet) error{OutOfMemory}!@This() {
        var self: @This() = .{ .name = fallback.name, .selection_style = fallback.selection_style };
        self.on_match_failure = fallback.on_match_failure;
        for (fallback.press.items) |binding| try self.press.append(allocator, binding);
        for (fallback.release.items) |binding| try self.release.append(allocator, binding);
        self.build_hints(allocator) catch {};
        return self;
    }

    fn append_if_not_match(
        allocator: std.mem.Allocator,
        dest: *std.ArrayListUnmanaged(Binding),
        new_binding: Binding,
    ) error{OutOfMemory}!void {
        for (dest.items) |*binding| switch (binding.match(new_binding.key_events)) {
            .matched, .match_possible => return,
            .match_impossible => {},
        };
        try dest.append(allocator, new_binding);
    }

    fn hints(self: *const @This()) *const KeybindHints {
        return &self.hints_map;
    }

    fn build_hints(self: *@This(), allocator: std.mem.Allocator) !void {
        const hints_map = &self.hints_map;

        for (self.press.items) |binding| {
            const cmd = binding.commands[0].command;
            var end: usize = 0;
            var hint: std.Io.Writer.Allocating = if (hints_map.get(cmd)) |previous| blk: {
                end = previous.len;
                break :blk .initOwnedSlice(allocator, previous);
            } else .init(allocator);
            defer hint.deinit();
            const writer = &hint.writer;
            writer.end = end;
            if (hint.written().len > 0) try writer.writeAll(", ");
            const count = binding.key_events.len;
            for (binding.key_events, 0..) |key_, n| {
                var key = key_;
                key.event = 0;
                switch (self.syntax) {
                    // .flow => {
                    else => {
                        try writer.print("{f}", .{key});
                        if (n < count - 1)
                            try writer.writeAll(" ");
                    },
                }
            }
            try hints_map.put(allocator, cmd, try hint.toOwnedSlice());
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
        var keypress_shifted: input.Key = 0;
        var text: []const u8 = "";
        var modifiers: input.Mods = 0;

        if (try m.match(.{
            "I",
            tp.extract(&event),
            tp.extract(&keypress),
            tp.extract(&keypress_shifted),
            tp.extract(&text),
            tp.extract(&modifiers),
        })) {
            const key_event = input.KeyEvent.from_message(event, keypress, keypress_shifted, text, modifiers);
            if (self.process_key_event(key_event) catch |e| return tp.exit_error(e, @errorReturnTrace())) |binding| {
                for (binding.commands) |*cmd| try cmd.execute();
            }
        } else if (try m.match(.{"F"})) {
            self.flush() catch |e| return tp.exit_error(e, @errorReturnTrace());
        }
        return false;
    }

    //register a key press and try to match it with a binding
    fn process_key_event(self: *const @This(), key_event: KeyEvent) !?*Binding {
        const event = key_event.event;

        //ignore modifiers for modifier key events
        const mods = switch (key_event.key) {
            input.key.left_control, input.key.right_control => 0,
            input.key.left_alt, input.key.right_alt => 0,
            else => key_event.modifiers,
        };
        const text = key_event.text;

        if (event == input.event.release)
            return self.process_key_release_event(key_event);

        //clear key history if enough time has passed since last key press
        const timestamp = std.time.milliTimestamp();
        if (globals.last_key_event_timestamp_ms - timestamp > max_key_sequence_time_interval) {
            try self.terminate_sequence(.timeout);
        }
        globals.last_key_event_timestamp_ms = timestamp;

        if (globals.current_sequence.items.len > 0 and input.is_modifier(key_event.key))
            return null;

        try globals.current_sequence.append(globals_allocator, key_event);
        if ((mods & ~(input.mod.shift | input.mod.caps_lock) == 0) and !input.is_non_input_key(key_event.key)) {
            var buf: [6]u8 = undefined;
            const bytes = if (text.len > 0) text else text: {
                const bytes = try input.ucs32_to_utf8(&[_]u32{key_event.key}, &buf);
                break :text buf[0..bytes];
            };
            try globals.current_sequence_egc.appendSlice(globals_allocator, bytes);
        }

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
            try self.terminate_sequence(.match_impossible);
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
    fn terminate_sequence(self: *const @This(), abort_type: AbortType) anyerror!void {
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

    /// Retrieve bindings that will match a key event sequence
    pub fn get_matches_for_key_event_sequence(
        self: *const @This(),
        allocator: std.mem.Allocator,
        sequence: []const KeyEvent,
        select_mode: SelectMode,
    ) error{OutOfMemory}![]const Binding {
        var matches: std.ArrayListUnmanaged(Binding) = .{};
        for (self.press.items) |*binding| switch (binding.match(sequence)) {
            .matched, .match_possible => {
                if (select(select_mode, binding))
                    (try matches.addOne(allocator)).* = binding.*;
            },
            .match_impossible => {},
        };
        return matches.toOwnedSlice(allocator);
    }

    /// Retrieve possibly filtered bindings
    pub fn get_bindings(
        self: *const @This(),
        allocator: std.mem.Allocator,
        select_mode: SelectMode,
    ) error{OutOfMemory}![]const Binding {
        var matches: std.ArrayListUnmanaged(Binding) = .{};
        for (self.press.items) |*binding| if (select(select_mode, binding)) {
            (try matches.addOne(allocator)).* = binding.*;
        };
        return matches.toOwnedSlice(allocator);
    }
};

pub const SelectMode = enum { all, no_keypad };

fn select(select_mode: SelectMode, binding: *const Binding) bool {
    return switch (select_mode) {
        .no_keypad => blk: {
            for (binding.key_events) |key_event| switch (key_event.key) {
                input.key.kp_0,
                input.key.kp_1,
                input.key.kp_2,
                input.key.kp_3,
                input.key.kp_4,
                input.key.kp_5,
                input.key.kp_6,
                input.key.kp_7,
                input.key.kp_8,
                input.key.kp_9,
                input.key.kp_decimal,
                input.key.kp_divide,
                input.key.kp_multiply,
                input.key.kp_subtract,
                input.key.kp_add,
                input.key.kp_enter,
                input.key.kp_equal,
                input.key.kp_separator,
                input.key.kp_left,
                input.key.kp_right,
                input.key.kp_up,
                input.key.kp_down,
                input.key.kp_page_up,
                input.key.kp_page_down,
                input.key.kp_home,
                input.key.kp_end,
                input.key.kp_insert,
                input.key.kp_delete,
                input.key.kp_begin,
                => break :blk false,

                else => {},
            };
            break :blk true;
        },
        .all => true,
    };
}

pub const LineNumbers = enum {
    inherit,
    absolute,
    relative,
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

const KeyEventSequenceFmt = struct {
    key_events: []const KeyEvent,

    pub fn format(self: @This(), writer: anytype) !void {
        for (self.key_events) |key_event|
            try writer.print(" {f}", .{input.key_event_short_fmt(key_event)});
    }
};

pub fn key_event_sequence_fmt(key_events: []const KeyEvent) KeyEventSequenceFmt {
    return .{ .key_events = key_events };
}

pub fn current_key_event_sequence_fmt() KeyEventSequenceFmt {
    return .{ .key_events = globals.current_sequence.items };
}

pub fn current_integer_argument() ?usize {
    return integer_argument;
}

pub fn clear_integer_argument() void {
    integer_argument = null;
}

const expectEqual = std.testing.expectEqual;

const parse_test_cases = .{
    //input, expected
    .{ "j", &.{"j"} },
    .{ "J", &.{"J"} },
    .{ "jk", &.{ "j", "k" } },
    .{ "<Space>", &.{"space"} },
    .{ "<C-x><C-c>", &.{ "ctrl+x", "ctrl+c" } },
    .{ "<A-x><Tab>", &.{ "alt+x", "tab" } },
    .{ "<S-A-x><D-Del>", &.{ "alt+shift+x", "super+delete" } },
    .{ ".", &.{"."} },
    .{ ",", &.{","} },
    .{ "`", &.{"`"} },
    .{ "_<Home>", &.{ "_", "home" } },
    .{ "<S--><Home>", &.{ "shift+-", "home" } },
};

test "parse" {
    const alloc = std.testing.allocator;
    inline for (parse_test_cases) |case| {
        const parsed = try parse_vim.parse_key_events(alloc, case[0]);
        defer alloc.free(parsed);
        const expected: []const []const u8 = case[1];
        const actual: []const KeyEvent = parsed;
        try expectEqual(expected.len, actual.len);
        for (expected, 0..) |expected_event, i| {
            try std.testing.expectFmt(expected_event, "{f}", .{actual[i]});
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
    .{ "<S-'><S-->dd", "<S-'><S-->dd", .matched },
    .{ "<S-'><S-->dd", "<S-'><S-->da", .match_impossible },
    .{ ":", ":", .matched },
    .{ ":", ";", .match_impossible },
};

test "match" {
    const alloc = std.testing.allocator;
    inline for (match_test_cases) |case| {
        const events = try parse_vim.parse_key_events(alloc, case[0]);
        defer alloc.free(events);
        const binding: Binding = .{
            .key_events = try parse_vim.parse_key_events(alloc, case[1]),
            .commands = &[_]Command{},
        };
        defer alloc.free(binding.key_events);

        try expectEqual(case[2], binding.match(events));
    }
}

test "json" {
    var bindings: BindingSet = .{ .name = "test", .selection_style = .normal };
    _ = try bindings.process_key_event(input.KeyEvent.from_key('j'));
    _ = try bindings.process_key_event(input.KeyEvent.from_key('k'));
    _ = try bindings.process_key_event(input.KeyEvent.from_key('g'));
    _ = try bindings.process_key_event(input.KeyEvent.from_key('i'));
    _ = try bindings.process_key_event(input.KeyEvent.from_key_mods('i', input.mod.ctrl));
}
