const tp = @import("thespian");
const std = @import("std");

const key = @import("renderer").input.key;
const mod = @import("renderer").input.modifier;

//A single key event, such as Ctrl-E
pub const KeyEvent = struct {
    keynormal: u32,
    modifiers: u32 = 0,
};

//An action that can be triggered by a Key Sequence
pub const Action = struct {
    command: []const u8 = "",
    args: []const u8 = "",
    description: []const u8 = "",

    pub fn activate(self: Action) !void {
        _ = self;
    }
};

//An association of an action with a triggering key chord
pub const Binding = struct {
    key_sequence: []KeyEvent,
    action: Action,

    pub fn len(self: Binding) usize {
        return self.key_sequence.len;
    }
};

//A Collection of keybindings
pub const Mode = struct {
    name: []const u8,
    bindings: []Binding,
    no_match_behavior: NoMatchBehavior = .ignore,

    //what to do with a key press that does not match any bindings
    pub const NoMatchBehavior = enum { ignore, insert };
};

//A collection of various modes under a single namespace, such as "vim" or "emacs"
pub const Namespace = struct {
    name: []const u8,
    modes: []const Mode,
};

//Data structure for mapping key events to keybindings
pub const Bindings = struct {
    allocator: std.mem.Allocator,
    active_namespace: usize,
    active_mode: usize,
    namespaces: std.StringArrayHashMap(Namespace),
    history: std.ArrayList(KeyEvent),
    last_key_event_timestamp_ms: usize,

    pub const max_key_sequence_time_interval = 750;

    //lists namespaces
    pub fn listNamespaces(self: *const Bindings) []const []const u8 {
        return self.namespaces.keys();
    }

    //lists modes of active namespace
    pub fn listModes(self: *const Bindings) []const []const u8 {
        return self.namespaces.entries[self.active_namespace].modes.keys();
    }

    //register a key press and try to match it with a binding
    pub fn registerKeyEvent(self: *Bindings, event: KeyEvent) !void {

        //clear key history if enough time has passed since last key press
        const timestamp = std.time.milliTimestamp();
        if (self.last_key_event_timestamp_ms - timestamp > max_key_sequence_time_interval) {
            self.history.clearRetainingCapacity();
        }
        self.last_key_event_timestamp_ms = timestamp;

        try self.history.append(event);
        try self.matchHistoryToAction();
    }

    ///Returns active bindings
    pub fn active(self: *Bindings) []const Binding {
        return self.namespaces.entries[self.active_namespace].modes[self.active_mode].bindings;
    }

    //Returns the last N key events
    pub fn lastNKeyEvents(self: *const Bindings, n: usize) ?[]const KeyEvent {
        const len = self.history.items.len;
        if (len >= n) {
            return self.history.items[len - n ..];
        } else {
            return null;
        }
    }

    //Checks if recent key events correspond to any key action, and if so, activate it
    pub fn matchHistoryToAction(self: *Bindings) !void {
        for (self.active) |binding| {
            const relevant_history = self.lastNKeyEvents(binding.len()) orelse continue;
            if (std.mem.eql(KeyEvent, binding.key_sequence, relevant_history)) {
                try binding.action.activate();
                self.history.clearRetainingCapacity();
            }
        }
    }

    pub fn init(allocator: std.mem.Allocator) !Bindings {
        return .{
            .allocator = allocator,
            .active_namespace = 0,
            .active_mode = 0,
            .namespaces = std.StringArrayHashMap(Mode).init(allocator),
            .history = try std.ArrayList(KeyEvent).initCapacity(allocator, 16),
            .last_key_event_timestamp_ms = std.time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *Bindings) void {
        for (self.namespaces.entries) |namespace| {
            namespace.modes.deinit();
        }
        self.namespaces.deinit();
        self.history.deinit();
    }

    pub fn addNamespace(self: *Bindings, name: []const u8, modes: []const Mode) !void {
        self.namespaces.put(name, .{ .name = name, .modes = modes });
    }
};

pub fn addVimNamespace(bindings: *Bindings) !void {
    bindings.addNamespace("vim", []Mode{ .{
        .name = "normal",
        .no_match_behavior = .ignore,
        .bindings = []Binding{
            Binding{
                .key_sequence = []KeyEvent{KeyEvent{ .keynormal = 'J' }},
                .action = .{ .command = "move_cursor_down", .description = "Moves Cursor Down" },
            },
            Binding{
                .key_sequence = []KeyEvent{KeyEvent{ .keynormal = 'K' }},
                .action = .{ .command = "move_cursor_up", .description = "Moves Cursor Up" },
            },
        },
    }, .{
        .name = "insert",
        .no_match_behavior = .insert,
        .bindings = []Binding{
            Binding{
                .key_sequence = []KeyEvent{ KeyEvent{ .keynormal = 'J' }, KeyEvent{ .keynormal = 'K' } },
                .action = .{ .command = "mode_change", .description = "Exits Normal Mode", .args = "vim/normal" },
            },
            Binding{
                .key_sequence = []KeyEvent{KeyEvent{ .keynormal = key.ESC }},
                .action = .{ .command = "mode_change", .description = "Exits Normal Mode", .args = "vim/normal" },
            },
        },
    } });
}
