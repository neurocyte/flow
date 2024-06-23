const std = @import("std");
const tp = @import("thespian");
const log = @import("log");
const cbor = @import("cbor");
const fuzzig = @import("fuzzig");
const root = @import("root");

const Plane = @import("renderer").Plane;
const key = @import("renderer").input.key;
const mod = @import("renderer").input.modifier;
const event_type = @import("renderer").input.event_type;
const ucs32_to_utf8 = @import("renderer").ucs32_to_utf8;

const tui = @import("../../tui.zig");
const command = @import("../../command.zig");
const EventHandler = @import("../../EventHandler.zig");
const WidgetList = @import("../../WidgetList.zig");
const Button = @import("../../Button.zig");
const InputBox = @import("../../InputBox.zig");
const Menu = @import("../../Menu.zig");
const Widget = @import("../../Widget.zig");
const mainview = @import("../../mainview.zig");

const Self = @This();
const max_menu_width = 80;

a: std.mem.Allocator,
menu: *Menu.State(*Self),
inputbox: *InputBox.State(*Self),
logger: log.Logger,
longest: usize = 0,
palette_commands: command.Collection(cmds) = undefined,
commands: std.ArrayList(Command) = undefined,
hints: ?*const tui.KeybindHints = null,
longest_hint: usize = 0,

items: usize = 0,
view_rows: usize,
view_pos: usize = 0,
total_items: usize = 0,

const Command = struct {
    name: []const u8,
    id: command.ID,
    used_time: i64,
};

pub fn create(a: std.mem.Allocator) !tui.Mode {
    const mv = if (tui.current().mainview.dynamic_cast(mainview)) |mv_| mv_ else return error.NotFound;
    const self: *Self = try a.create(Self);
    self.* = .{
        .a = a,
        .menu = try Menu.create(*Self, a, tui.current().mainview, .{
            .ctx = self,
            .on_render = on_render_menu,
            .on_resize = on_resize_menu,
            .on_scroll = EventHandler.bind(self, Self.on_scroll),
        }),
        .logger = log.logger(@typeName(Self)),
        .inputbox = (try self.menu.add_header(try InputBox.create(*Self, self.a, self.menu.menu.parent, .{
            .ctx = self,
            .label = "Search commands",
        }))).dynamic_cast(InputBox.State(*Self)) orelse unreachable,
        .hints = if (tui.current().input_mode) |m| m.keybind_hints else null,
        .view_rows = get_view_rows(tui.current().screen()),
        .commands = std.ArrayList(Command).init(a),
    };
    if (self.hints) |hints| {
        for (hints.values()) |val|
            self.longest_hint = @max(self.longest_hint, val.len);
    }
    for (command.commands.items) |cmd_| if (cmd_) |p| {
        (self.commands.addOne() catch @panic("oom")).* = .{
            .name = p.name,
            .id = p.id,
            .used_time = 0,
        };
    };
    self.restore_state() catch {};
    self.sort_by_used_time();
    try self.palette_commands.init(self);
    try self.start_query();
    try mv.floating_views.add(self.menu.container_widget);
    return .{
        .handler = EventHandler.to_owned(self),
        .name = "󱊒 command",
        .description = "command",
    };
}

pub fn deinit(self: *Self) void {
    self.palette_commands.deinit();
    self.commands.deinit();
    tui.current().message_filters.remove_ptr(self);
    if (tui.current().mainview.dynamic_cast(mainview)) |mv|
        mv.floating_views.remove(self.menu.container_widget);
    self.logger.deinit();
    self.a.destroy(self);
}

fn on_render_menu(_: *Self, button: *Button.State(*Menu.State(*Self)), theme: *const Widget.Theme, selected: bool) bool {
    const style_base = if (button.active) theme.editor_cursor else if (button.hover or selected) theme.editor_selection else theme.editor_widget;
    const style_keybind = if (tui.find_scope_style(theme, "entity.name")) |sty| sty.style else style_base;
    button.plane.set_base_style(" ", style_base);
    button.plane.erase();
    button.plane.home();
    var command_name: []const u8 = undefined;
    var keybind_hint: []const u8 = undefined;
    var iter = button.opts.label; // label contains cbor, first the file name, then multiple match indexes
    if (!(cbor.matchString(&iter, &command_name) catch false))
        command_name = "#ERROR#";
    var command_id: command.ID = undefined;
    if (!(cbor.matchValue(&iter, cbor.extract(&command_id)) catch false))
        command_id = 0;
    if (!(cbor.matchString(&iter, &keybind_hint) catch false))
        keybind_hint = "";
    const pointer = if (selected) "⏵" else " ";
    _ = button.plane.print("{s}{s} ", .{ pointer, command_name }) catch {};
    button.plane.set_style(style_keybind);
    _ = button.plane.print_aligned_right(0, "{s} ", .{keybind_hint}) catch {};
    var index: usize = 0;
    var len = cbor.decodeArrayHeader(&iter) catch return false;
    while (len > 0) : (len -= 1) {
        if (cbor.matchValue(&iter, cbor.extract(&index)) catch break) {
            render_cell(&button.plane, 0, index + 1, theme.editor_match) catch break;
        } else break;
    }
    return false;
}

fn render_cell(plane: *Plane, y: usize, x: usize, style: Widget.Theme.Style) !void {
    plane.cursor_move_yx(@intCast(y), @intCast(x)) catch return;
    var cell = plane.cell_init();
    _ = plane.at_cursor_cell(&cell) catch return;
    cell.set_style(style);
    _ = plane.putc(&cell) catch {};
}

fn on_resize_menu(self: *Self, _: *Menu.State(*Self), _: Widget.Box) void {
    self.do_resize();
    self.start_query() catch {};
}

fn do_resize(self: *Self) void {
    const screen = tui.current().screen();
    const w = @min(self.longest, max_menu_width) + 2 + 1 + self.longest_hint;
    const x = if (screen.w > w) (screen.w - w) / 2 else 0;
    self.view_rows = get_view_rows(screen);
    const h = @min(self.items, self.view_rows);
    self.menu.container.resize(.{ .y = 0, .x = x, .w = w, .h = h });
    self.update_scrollbar();
}

fn get_view_rows(screen: Widget.Box) usize {
    var h = screen.h;
    if (h > 0) h = h / 5 * 4;
    return h;
}

fn menu_action_execute_command(menu: **Menu.State(*Self), button: *Button.State(*Menu.State(*Self))) void {
    var command_name: []const u8 = undefined;
    var command_id: command.ID = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &command_name) catch false)) return;
    if (!(cbor.matchValue(&iter, cbor.extract(&command_id)) catch false)) return;
    menu.*.opts.ctx.update_used_time(command_id);
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err("navigate", e);
    tp.self_pid().send(.{ "cmd", command_name, .{} }) catch |e| menu.*.opts.ctx.logger.err("navigate", e);
}

fn on_scroll(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!void {
    if (try m.match(.{ "scroll_to", tp.extract(&self.view_pos) })) {
        try self.start_query();
    }
}

fn update_scrollbar(self: *Self) void {
    self.menu.scrollbar.?.set(@intCast(self.total_items), @intCast(self.view_rows), @intCast(self.view_pos));
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var evtype: u32 = undefined;
    var keypress: u32 = undefined;
    var egc: u32 = undefined;
    var modifiers: u32 = undefined;
    var text: []const u8 = undefined;

    if (try m.match(.{ "I", tp.extract(&evtype), tp.extract(&keypress), tp.extract(&egc), tp.string, tp.extract(&modifiers) })) {
        try self.mapEvent(evtype, keypress, egc, modifiers);
    } else if (try m.match(.{ "system_clipboard", tp.extract(&text) })) {
        try self.insert_bytes(text);
    }
    return false;
}

fn mapEvent(self: *Self, evtype: u32, keypress: u32, egc: u32, modifiers: u32) tp.result {
    return switch (evtype) {
        event_type.PRESS => self.mapPress(keypress, egc, modifiers),
        event_type.REPEAT => self.mapPress(keypress, egc, modifiers),
        event_type.RELEASE => self.mapRelease(keypress, modifiers),
        else => {},
    };
}

fn mapPress(self: *Self, keypress: u32, egc: u32, modifiers: u32) tp.result {
    const keynormal = if ('a' <= keypress and keypress <= 'z') keypress - ('a' - 'A') else keypress;
    return switch (modifiers) {
        mod.CTRL => switch (keynormal) {
            'J' => self.cmd("toggle_logview", .{}),
            'Q' => self.cmd("quit", .{}),
            'W' => self.cmd("close_file", .{}),
            'P' => self.cmd("command_palette_menu_up", .{}),
            'N' => self.cmd("command_palette_menu_down", .{}),
            'V' => self.cmd("system_paste", .{}),
            'C' => self.cmd("exit_overlay_mode", .{}),
            'G' => self.cmd("exit_overlay_mode", .{}),
            key.ESC => self.cmd("exit_overlay_mode", .{}),
            key.UP => self.cmd("command_palette_menu_up", .{}),
            key.DOWN => self.cmd("command_palette_menu_down", .{}),
            key.PGUP => self.cmd("command_palette_menu_pageup", .{}),
            key.PGDOWN => self.cmd("command_palette_menu_pagedown", .{}),
            key.ENTER => self.cmd("command_palette_menu_activate", .{}),
            key.BACKSPACE => self.delete_word(),
            else => {},
        },
        mod.CTRL | mod.SHIFT => switch (keynormal) {
            'P' => self.cmd("command_palette_menu_down", .{}),
            'Q' => self.cmd("quit_without_saving", .{}),
            'W' => self.cmd("close_file_without_saving", .{}),
            'R' => self.cmd("restart", .{}),
            'L' => self.cmd_async("toggle_logview"),
            'I' => self.cmd_async("toggle_inputview"),
            else => {},
        },
        mod.ALT | mod.SHIFT => switch (keynormal) {
            'P' => self.cmd("command_palette_menu_down", .{}),
            else => {},
        },
        mod.ALT => switch (keynormal) {
            'P' => self.cmd("command_palette_menu_up", .{}),
            'L' => self.cmd("toggle_logview", .{}),
            'I' => self.cmd("toggle_inputview", .{}),
            else => {},
        },
        mod.SHIFT => switch (keypress) {
            else => if (!key.synthesized_p(keypress))
                self.insert_code_point(egc)
            else {},
        },
        0 => switch (keypress) {
            key.F09 => self.cmd("theme_prev", .{}),
            key.F10 => self.cmd("theme_next", .{}),
            key.F11 => self.cmd("toggle_logview", .{}),
            key.F12 => self.cmd("toggle_inputview", .{}),
            key.ESC => self.cmd("exit_overlay_mode", .{}),
            key.UP => self.cmd("command_palette_menu_up", .{}),
            key.DOWN => self.cmd("command_palette_menu_down", .{}),
            key.PGUP => self.cmd("command_palette_menu_pageup", .{}),
            key.PGDOWN => self.cmd("command_palette_menu_pagedown", .{}),
            key.ENTER => self.cmd("command_palette_menu_activate", .{}),
            key.BACKSPACE => self.delete_code_point(),
            else => if (!key.synthesized_p(keypress))
                self.insert_code_point(egc)
            else {},
        },
        else => {},
    };
}

fn mapRelease(self: *Self, keypress: u32, _: u32) tp.result {
    return switch (keypress) {
        key.LCTRL, key.RCTRL => if (self.menu.selected orelse 0 > 0) return self.cmd("command_palette_menu_activate", .{}),
        else => {},
    };
}

fn start_query(self: *Self) tp.result {
    self.items = 0;
    self.menu.reset_items();
    self.menu.selected = null;
    for (self.commands.items) |cmd_|
        self.longest = @max(self.longest, cmd_.name.len);

    if (self.inputbox.text.items.len == 0) {
        self.total_items = 0;
        var pos: usize = 0;
        for (self.commands.items) |cmd_| {
            defer self.total_items += 1;
            defer pos += 1;
            if (pos < self.view_pos) continue;
            if (self.items < self.view_rows)
                self.add_item(cmd_.name, cmd_.id, null) catch |e| return tp.exit_error(e);
        }
    } else {
        _ = self.query_commands(self.inputbox.text.items) catch |e| return tp.exit_error(e);
    }
    self.menu.select_down();
    self.do_resize();
}

fn query_commands(self: *Self, query: []const u8) error{OutOfMemory}!usize {
    var searcher = try fuzzig.Ascii.init(
        self.a,
        self.longest, // haystack max size
        self.longest, // needle max size
        .{ .case_sensitive = false },
    );
    defer searcher.deinit();

    const Match = struct {
        name: []const u8,
        id: command.ID,
        score: i32,
        matches: []const usize,
    };
    var matches = std.ArrayList(Match).init(self.a);

    for (self.commands.items) |cmd_| {
        const match = searcher.scoreMatches(cmd_.name, query);
        if (match.score) |score| {
            (try matches.addOne()).* = .{
                .name = cmd_.name,
                .id = cmd_.id,
                .score = score,
                .matches = try self.a.dupe(usize, match.matches),
            };
        }
    }
    if (matches.items.len == 0) return 0;

    const less_fn = struct {
        fn less_fn(_: void, lhs: Match, rhs: Match) bool {
            return lhs.score > rhs.score;
        }
    }.less_fn;
    std.mem.sort(Match, matches.items, {}, less_fn);

    var pos: usize = 0;
    self.total_items = 0;
    for (matches.items) |match| {
        defer self.total_items += 1;
        defer pos += 1;
        if (pos < self.view_pos) continue;
        if (self.items < self.view_rows)
            try self.add_item(match.name, match.id, match.matches);
    }
    return matches.items.len;
}

fn add_item(self: *Self, name: []const u8, id: command.ID, matches: ?[]const usize) !void {
    var label = std.ArrayList(u8).init(self.a);
    defer label.deinit();
    const writer = label.writer();
    try cbor.writeValue(writer, name);
    try cbor.writeValue(writer, id);
    try cbor.writeValue(writer, if (self.hints) |hints| hints.get(name) orelse "" else "");
    if (matches) |matches_|
        try cbor.writeValue(writer, matches_);
    try self.menu.add_item_with_handler(label.items, menu_action_execute_command);
    self.items += 1;
}

fn delete_word(self: *Self) tp.result {
    if (std.mem.lastIndexOfAny(u8, self.inputbox.text.items, "/\\. -_")) |pos| {
        self.inputbox.text.shrinkRetainingCapacity(pos);
    } else {
        self.inputbox.text.shrinkRetainingCapacity(0);
    }
    self.inputbox.cursor = self.inputbox.text.items.len;
    self.view_pos = 0;
    return self.start_query();
}

fn delete_code_point(self: *Self) tp.result {
    if (self.inputbox.text.items.len > 0) {
        self.inputbox.text.shrinkRetainingCapacity(self.inputbox.text.items.len - 1);
        self.inputbox.cursor = self.inputbox.text.items.len;
    }
    self.view_pos = 0;
    return self.start_query();
}

fn insert_code_point(self: *Self, c: u32) tp.result {
    var buf: [6]u8 = undefined;
    const bytes = ucs32_to_utf8(&[_]u32{c}, &buf) catch |e| return tp.exit_error(e);
    self.inputbox.text.appendSlice(buf[0..bytes]) catch |e| return tp.exit_error(e);
    self.inputbox.cursor = self.inputbox.text.items.len;
    self.view_pos = 0;
    return self.start_query();
}

fn insert_bytes(self: *Self, bytes: []const u8) tp.result {
    self.inputbox.text.appendSlice(bytes) catch |e| return tp.exit_error(e);
    self.inputbox.cursor = self.inputbox.text.items.len;
    self.view_pos = 0;
    return self.start_query();
}

fn cmd(_: *Self, name_: []const u8, ctx: command.Context) tp.result {
    try command.executeName(name_, ctx);
}

fn msg(_: *Self, text: []const u8) tp.result {
    return tp.self_pid().send(.{ "log", "home", text });
}

fn cmd_async(_: *Self, name_: []const u8) tp.result {
    return tp.self_pid().send(.{ "cmd", name_ });
}

fn sort_by_used_time(self: *Self) void {
    const less_fn = struct {
        fn less_fn(_: void, lhs: Command, rhs: Command) bool {
            return lhs.used_time > rhs.used_time;
        }
    }.less_fn;
    std.mem.sort(Command, self.commands.items, {}, less_fn);
}

fn update_used_time(self: *Self, id: command.ID) void {
    self.set_used_time(id, std.time.milliTimestamp());
    self.write_state() catch {};
}

fn set_used_time(self: *Self, id: command.ID, used_time: i64) void {
    self.commands.items[id].used_time = used_time;
}

fn write_state(self: *Self) !void {
    var state_file_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const state_file = try std.fmt.bufPrint(&state_file_buffer, "{s}/{s}", .{ try root.get_state_dir(), "commands" });
    var file = try std.fs.createFileAbsolute(state_file, .{ .truncate = true });
    defer file.close();
    var buffer = std.io.bufferedWriter(file.writer());
    defer buffer.flush() catch {};
    const writer = buffer.writer();

    for (self.commands.items) |cmd_| {
        if (cmd_.used_time == 0) continue;
        try cbor.writeArrayHeader(writer, 2);
        try cbor.writeValue(writer, cmd_.name);
        try cbor.writeValue(writer, cmd_.used_time);
    }
}

fn restore_state(self: *Self) !void {
    var state_file_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const state_file = try std.fmt.bufPrint(&state_file_buffer, "{s}/{s}", .{ try root.get_state_dir(), "commands" });
    const a = std.heap.c_allocator;
    var file = std.fs.openFileAbsolute(state_file, .{ .mode = .read_only }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer file.close();
    const stat = try file.stat();
    var buffer = try a.alloc(u8, stat.size);
    defer a.free(buffer);
    const size = try file.readAll(buffer);
    const data = buffer[0..size];

    var name: []const u8 = undefined;
    var used_time: i64 = undefined;
    var iter: []const u8 = data;
    while (cbor.matchValue(&iter, .{
        tp.extract(&name),
        tp.extract(&used_time),
    }) catch |e| switch (e) {
        error.CborTooShort => return,
        else => return e,
    }) {
        const id = command.getId(name) orelse continue;
        self.set_used_time(id, used_time);
    }
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;

    pub fn command_palette_menu_down(self: *Self, _: Ctx) tp.result {
        if (self.menu.selected) |selected| {
            if (selected == self.view_rows - 1) {
                self.view_pos += 1;
                try self.start_query();
                self.menu.select_last();
                return;
            }
        }
        self.menu.select_down();
    }

    pub fn command_palette_menu_up(self: *Self, _: Ctx) tp.result {
        if (self.menu.selected) |selected| {
            if (selected == 0 and self.view_pos > 0) {
                self.view_pos -= 1;
                try self.start_query();
                self.menu.select_first();
                return;
            }
        }
        self.menu.select_up();
    }

    pub fn command_palette_menu_pagedown(self: *Self, _: Ctx) tp.result {
        if (self.total_items > self.view_rows) {
            self.view_pos += self.view_rows;
            if (self.view_pos > self.total_items - self.view_rows)
                self.view_pos = self.total_items - self.view_rows;
        }
        try self.start_query();
        self.menu.select_last();
    }

    pub fn command_palette_menu_pageup(self: *Self, _: Ctx) tp.result {
        if (self.view_pos > self.view_rows)
            self.view_pos -= self.view_rows;
        try self.start_query();
        self.menu.select_first();
    }

    pub fn command_palette_menu_activate(self: *Self, _: Ctx) tp.result {
        self.menu.activate_selected();
    }
};
