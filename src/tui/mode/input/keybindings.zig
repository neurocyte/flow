const tp = @import("thespian");
const std = @import("std");

const key = @import("renderer").input.key;
const mod = @import("renderer").input.modifier;
const event_type = @import("renderer").input.event_type;
const command = @import("../../../command.zig");

//A single key event, such as Ctrl-E
pub const KeyEvent = struct {
    key: u32, //keypress value
    event_type: usize = event_type.PRESS,
    modifiers: u32 = 0,

    pub fn eql(self: @This(), other: @This()) bool {
        return std.meta.eql(self, other);
    }
};

// pub const KeyEventRecord = struct {
//     key_event: KeyEvent,
//     timestamp_ms: i64,
//     egc_inserted: bool = false,
//};

// pub const SequenceBuilder = struct {
//     //events: std.MultiArrayList(KeyEventRecord),
//     partial_match_buffer: std.ArrayList(Binding),

//     pub const MatchResult = union(enum) {
//         no_match: void,
//         partial_match: []const Binding,
//         match: Binding,
//     };

//     pub fn attemptMatch(self: @This(), key_sequence: []const KeyEventRecord, bindings: []const Binding) MatchResult {
//         self.partial_match_buffer.clearRetainingCapacity();
//         for (bindings) |binding| {
//             for (binding.key_sequence, 0..) |key_event, i| {
//                 if (key_event.eql(key_sequence[i].key_event)) {}
//             }
//         }
//     }
//     // for(binding.key_sequence) |key_event| {
//     // if(key_event.eql
//     // }
// };

//An action that can be triggered by a Key Sequence
pub const Action = struct {
    command: []const u8 = "",
    args: []const u8 = "",
    //description: []const u8 = "",

    pub fn activate(self: Action) !void {
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
        var result: MatchResult = .match_possible;
        for (keys, 0..) |key_event, i| {
            if (!key_event.eql(self.keys[i])) {
                result = .match_impossible;
            }
        }

        if (result == .match_possible and keys.len == self.len()) {
            result = .matched;
        }
        return result;
    }
};

//A Collection of keybindings
pub const Mode = struct {
    name: []const u8,
    bindings: []const Binding,
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
    current_sequence_egc: std.ArrayList(u32),
    last_key_event_timestamp_ms: i64,
    input_buffer: std.ArrayList(u8),
    required_undo_count: usize = 0,
    last_command: []const u8 = "",

    const Self = @This();
    pub const max_key_sequence_time_interval = 750;
    pub const max_input_buffer_size = 1024;

    fn insertBytes(self: *Self, bytes: []const u8) !void {
        if (self.input_buffer.items.len + 4 > max_input_buffer_size)
            try self.flushInputBuffer();
        try self.input.appendSlice(bytes);
    }

    fn flushInputBuffer(self: *Self) !void {
        const Static = struct {
            var insert_chars_id: ?command.ID = null;
        };
        if (self.input_buffer.items.len > 0) {
            defer self.input.clearRetainingCapacity();
            const id = Static.insert_chars_id orelse
                command.get_id_cache("insert_chars", &Static.insert_chars_id) orelse {
                return tp.exit_error(error.InputTargetNotFound, null);
            };
            try command.execute(id, command.fmt(.{self.input.items}));
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
                .character = egc,
                .modifiers = modifiers,
            }) catch |e| return tp.exit_error(e, @errorReturnTrace());
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

    //lists modes of active namespace
    // pub fn listModes(self: *const Bindings) []const []const u8 {
    // return self.namespaces.values[self.active_namespace].modes.keys();
    // }

    //register a key press and try to match it with a binding
    pub fn registerKeyEvent(self: *Bindings, event: KeyEvent) !void {

        //clear key history if enough time has passed since last key press
        const timestamp = std.time.milliTimestamp();
        if (self.last_key_event_timestamp_ms - timestamp > max_key_sequence_time_interval) {
            self.history.clearRetainingCapacity();
        }
        self.last_key_event_timestamp_ms = timestamp;

        try self.current_sequence.append(event);

        var all_matches_impossible = true;
        for (self.activeMode().bindings) |binding| blk: {
            switch (binding.match(self.current_sequence.items)) {
                .matched => {
                    binding.action.activate();
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
            self.insertBytes(self.current_sequence_egc.items);
            self.current_sequence.clearRetainingCapacity();
            self.current_sequence_egc.clearRetainingCapacity();
        }
    }

    ///Returns active bindings
    // pub fn active(self: *Bindings) []const Binding {
    // return self.namespaces.entries[self.active_namespace].modes[self.active_mode].bindings;
    // }

    //Returns the last N key events
    pub fn lastNKeyEvents(self: *const Bindings, n: usize) ?[]const KeyEvent {
        const len = self.history.items.len;
        if (len >= n) {
            return self.history.items[len - n ..];
        } else {
            return null;
        }
    }

    pub fn lastKeyEvent(self: *const Bindings) KeyEvent {
        std.debug.assert(self.history.items.len > 0);
        return self.history.items[self.history.items.len - 1];
    }

    // pub fn activateNamespace(self: *Bindings, namespace_name: []const u8) void {
    // self.history.clearRetainingCapacity();
    //self.active_namespace = self.namespaces.getIndex(namespace_name).?;
    // }

    // pub fn activateMode(self: *Bindings, mode_name: []const u8) void {
    //     for (self.activeNamespace().modes, 0..) |mode, i| {
    //         if (std.mem.eql(u8, mode_name, mode.name)) {
    //             self.active_mode = i;
    //             return;
    //         }
    //     }
    //     std.debug.assert(false); //mode name should always be valid
    // }

    pub fn activeNamespace(self: *const Bindings) *Namespace {
        return self.namespaces.values().ptr + self.active_namespace;
    }

    pub fn activeMode(self: *Bindings) *Mode {
        return self.activeNamespace().modes.values().ptr + self.active_mode;
    }

    //erases current key sequence
    // pub fn clearHistory(self: *@This()) void {
    //     self.history.clearRetainingCapacity();
    //     for (0..self.required_undo_count) |_| {
    //         self.cmd("undo", .{});
    //     }
    // }

    //Checks if recent key events correspond to any key action
    // pub fn matchHistory(self: *const Bindings, mode: *Mode) !?Action {
    //     for (mode.bindings) |binding| {
    //         const relevant_history = self.lastNKeyEvents(binding.len()) orelse continue;
    //         if (std.mem.eql(KeyEvent, binding.trigger, relevant_history)) {
    //             self.clearHistory();

    //             return binding.action;
    //         }
    //     }

    //     //handle no match
    //     switch (mode.no_match_behavior) {
    //         .ignore => {
    //             return null;
    //         },
    //         .insert => {
    //             try self.insert_bytes(self.lastKeyEvent().character);
    //             self.required_undo_count += 1;
    //             return null;
    //         },
    //         .fallback_mode => |mode_name| {
    //             return try self.matchHistoryToAction(self.getModeFromName(mode_name).?);
    //         },
    //     }
    // }

    pub fn init(allocator: std.mem.Allocator) !Bindings {
        return .{
            .allocator = allocator,
            .active_namespace = 0,
            .active_mode = 0,
            .namespaces = std.StringArrayHashMap(Namespace).init(allocator),
            .current_sequence = try std.ArrayList(KeyEvent).initCapacity(allocator, 16),
            .current_sequence_egc = try std.ArrayList(u32).initCapacity(allocator, 16),
            .last_key_event_timestamp_ms = std.time.milliTimestamp(),
            .input_buffer = try std.ArrayList(u8).initCapacity(allocator, 16),
        };
    }

    pub fn deinit(self: *Bindings) void {
        for (self.namespaces.values()) |*namespace| {
            // for(namespace.values()) |*mode| {
                // mode.deinit();
            // }
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
        try command.executeName(name_, ctx);
    }
};

// pub const vim = struct {
//     pub const actions = struct {
//         pub const return_to_normal_mode: []const Action = &.{.{ .command = "mode_change" }};
//     };

//     pub const bindings = struct {
//         pub const normal_navigation: []const Binding = &.{
//             Binding{
//                 .key_sequence = &[_]KeyEvent{KeyEvent{ .key = 'j' }},
//                 .actions = &.{.{ .command = "move_cursor_down", .description = "Moves Cursor Down" }},
//             },
//             Binding{
//                 .trigger = &[_]KeyEvent{KeyEvent{ .key = 'j' }},
//                 .actions = &.{.{ .command = "move_cursor_up", .description = "Moves Cursor Up" }},
//             },
//         };

//         pub const return_to_normal_mode: []const Binding = &.{
//             Binding{
//                 .trigger = &[_]KeyEvent{ KeyEvent{ .key = 'j' }, KeyEvent{ .key = 'k' } },
//                 .actions = actions.return_to_normal_mode,
//             },
//             Binding{
//                 .trigger = &[_]KeyEvent{KeyEvent{ .key = key.ESC }},
//                 .actions = actions.return_to_normal_mode,
//             },
//         };
//     };
// };

// // pub fn addVimNamespace(bindings: *Bindings) !void {
// //     try bindings.addNamespace("vim", &[_]Mode{ .{
// //         .name = "normal",
// //         .no_match_behavior = .ignore,
// //         .bindings = vim.bindings.normal_navigation,
//     }, .{
//         .name = "insert",
//         .no_match_behavior = .insert,
//         .bindings = vim.bindings.return_to_normal_mode,
//     } });
// }

// test "match" {
//     const alloc = std.testing.allocator;
//     var bind = try Bindings.init(alloc);
//     defer bind.deinit();

//     try addVimNamespace(&bind);
//     bind.activateNamespace("vim");
//     bind.activeMode("insert");

//     bind.history.append(.{ .key = 'j' });
//     bind.history.append(.{ .key = 'k' });
//     std.testing.expectEqual(vim.actions.return_to_normal_mode, bind.matchHistory());
// }
