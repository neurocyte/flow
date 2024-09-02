const std = @import("std");
const tp = @import("thespian");
const log = @import("log");
const cbor = @import("cbor");
const fuzzig = @import("fuzzig");

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
const Widget = @import("../../Widget.zig");
const mainview = @import("../../mainview.zig");
const scrollbar_v = @import("../../scrollbar_v.zig");

pub const Menu = @import("../../Menu.zig");

const max_menu_width = 80;

pub fn Create(options: type) type {
    return struct {
        allocator: std.mem.Allocator,
        menu: *Menu.State(*Self),
        inputbox: *InputBox.State(*Self),
        logger: log.Logger,
        longest: usize = 0,
        commands: command.Collection(cmds) = undefined,
        entries: std.ArrayList(Entry) = undefined,
        hints: ?*const tui.KeybindHints = null,
        longest_hint: usize = 0,

        items: usize = 0,
        view_rows: usize,
        view_pos: usize = 0,
        total_items: usize = 0,

        const Entry = options.Entry;
        const Self = @This();

        pub const MenuState = Menu.State(*Self);
        pub const ButtonState = Button.State(*Menu.State(*Self));

        pub fn create(allocator: std.mem.Allocator) !tui.Mode {
            const mv = tui.current().mainview.dynamic_cast(mainview) orelse return error.NotFound;
            const self: *Self = try allocator.create(Self);
            self.* = .{
                .allocator = allocator,
                .menu = try Menu.create(*Self, allocator, tui.current().mainview, .{
                    .ctx = self,
                    .on_render = on_render_menu,
                    .on_resize = on_resize_menu,
                    .on_scroll = EventHandler.bind(self, Self.on_scroll),
                    .on_click4 = mouse_click_button4,
                    .on_click5 = mouse_click_button5,
                }),
                .logger = log.logger(@typeName(Self)),
                .inputbox = (try self.menu.add_header(try InputBox.create(*Self, self.allocator, self.menu.menu.parent, .{
                    .ctx = self,
                    .label = options.label,
                }))).dynamic_cast(InputBox.State(*Self)) orelse unreachable,
                .hints = if (tui.current().input_mode) |m| m.keybind_hints else null,
                .view_rows = get_view_rows(tui.current().screen()),
                .entries = std.ArrayList(Entry).init(allocator),
            };
            self.menu.scrollbar.?.style_factory = scrollbar_style;
            if (self.hints) |hints| {
                for (hints.values()) |val|
                    self.longest_hint = @max(self.longest_hint, val.len);
            }
            try options.load_entries(self);
            if (@hasDecl(options, "restore_state"))
                options.restore_state(self) catch {};
            try self.commands.init(self);
            try self.start_query();
            try mv.floating_views.add(self.menu.container_widget);
            return .{
                .handler = EventHandler.to_owned(self),
                .name = options.name,
                .description = options.description,
            };
        }

        pub fn deinit(self: *Self) void {
            self.commands.deinit();
            if (@hasDecl(options, "deinit"))
                options.deinit(self);
            self.entries.deinit();
            tui.current().message_filters.remove_ptr(self);
            if (tui.current().mainview.dynamic_cast(mainview)) |mv|
                mv.floating_views.remove(self.menu.container_widget);
            self.logger.deinit();
            self.allocator.destroy(self);
        }

        fn scrollbar_style(sb: *scrollbar_v, theme: *const Widget.Theme) Widget.Theme.Style {
            return if (sb.active)
                .{ .fg = theme.scrollbar_active.fg, .bg = theme.editor_widget.bg }
            else if (sb.hover)
                .{ .fg = theme.scrollbar_hover.fg, .bg = theme.editor_widget.bg }
            else
                .{ .fg = theme.scrollbar.fg, .bg = theme.editor_widget.bg };
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
            button.plane.set_style(style_keybind);
            const pointer = if (selected) "⏵" else " ";
            _ = button.plane.print("{s}", .{pointer}) catch {};
            button.plane.set_style(style_base);
            _ = button.plane.print("{s} ", .{command_name}) catch {};
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
            const h = @min(self.items + self.menu.header_count, self.view_rows + self.menu.header_count);
            self.menu.container.resize(.{ .y = 0, .x = x, .w = w, .h = h });
            self.update_scrollbar();
        }

        fn get_view_rows(screen: Widget.Box) usize {
            var h = screen.h;
            if (h > 0) h = h / 5 * 4;
            return h;
        }

        fn on_scroll(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!void {
            if (try m.match(.{ "scroll_to", tp.extract(&self.view_pos) })) {
                self.start_query() catch |e| return tp.exit_error(e, @errorReturnTrace());
            }
        }

        fn update_scrollbar(self: *Self) void {
            self.menu.scrollbar.?.set(@intCast(self.total_items), @intCast(self.view_rows), @intCast(self.view_pos));
        }

        fn mouse_click_button4(menu: **Menu.State(*Self), _: *Button.State(*Menu.State(*Self))) void {
            const self = &menu.*.opts.ctx.*;
            if (self.view_pos < Menu.scroll_lines) {
                self.view_pos = 0;
            } else {
                self.view_pos -= Menu.scroll_lines;
            }
            self.update_scrollbar();
            self.start_query() catch {};
        }

        fn mouse_click_button5(menu: **Menu.State(*Self), _: *Button.State(*Menu.State(*Self))) void {
            const self = &menu.*.opts.ctx.*;
            if (self.view_pos < @max(self.total_items, self.view_rows) - self.view_rows)
                self.view_pos += Menu.scroll_lines;
            self.update_scrollbar();
            self.start_query() catch {};
        }

        pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
            var evtype: u32 = undefined;
            var keypress: u32 = undefined;
            var egc: u32 = undefined;
            var modifiers: u32 = undefined;
            var text: []const u8 = undefined;

            if (try m.match(.{ "I", tp.extract(&evtype), tp.extract(&keypress), tp.extract(&egc), tp.string, tp.extract(&modifiers) })) {
                self.mapEvent(evtype, keypress, egc, modifiers) catch |e| return tp.exit_error(e, @errorReturnTrace());
            } else if (try m.match(.{ "system_clipboard", tp.extract(&text) })) {
                self.insert_bytes(text) catch |e| return tp.exit_error(e, @errorReturnTrace());
            }
            return false;
        }

        fn mapEvent(self: *Self, evtype: u32, keypress: u32, egc: u32, modifiers: u32) !void {
            return switch (evtype) {
                event_type.PRESS => self.mapPress(keypress, egc, modifiers),
                event_type.REPEAT => self.mapPress(keypress, egc, modifiers),
                event_type.RELEASE => self.mapRelease(keypress, modifiers),
                else => {},
            };
        }

        fn mapPress(self: *Self, keypress: u32, egc: u32, modifiers: u32) !void {
            const keynormal = if ('a' <= keypress and keypress <= 'z') keypress - ('a' - 'A') else keypress;
            return switch (modifiers) {
                mod.CTRL => switch (keynormal) {
                    'J' => self.cmd("toggle_panel", .{}),
                    'Q' => self.cmd("quit", .{}),
                    'W' => self.cmd("close_file", .{}),
                    'P' => self.cmd("palette_menu_up", .{}),
                    'N' => self.cmd("palette_menu_down", .{}),
                    'T' => self.cmd("palette_menu_down", .{}), // select theme repeat key
                    'R' => self.cmd("palette_menu_down", .{}), // open recent project repeat key
                    'V' => self.cmd("system_paste", .{}),
                    'C' => self.cmd("palette_menu_cancel", .{}),
                    'G' => self.cmd("palette_menu_cancel", .{}),
                    key.ESC => self.cmd("palette_menu_cancel", .{}),
                    key.UP => self.cmd("palette_menu_up", .{}),
                    key.DOWN => self.cmd("palette_menu_down", .{}),
                    key.PGUP => self.cmd("palette_menu_pageup", .{}),
                    key.PGDOWN => self.cmd("palette_menu_pagedown", .{}),
                    key.ENTER => self.cmd("palette_menu_activate", .{}),
                    key.BACKSPACE => self.delete_word(),
                    else => {},
                },
                mod.CTRL | mod.SHIFT => switch (keynormal) {
                    'P' => self.cmd("palette_menu_down", .{}), // command palette repeat key
                    'Q' => self.cmd("quit_without_saving", .{}),
                    'W' => self.cmd("close_file_without_saving", .{}),
                    'R' => self.cmd("restart", .{}),
                    'L' => self.cmd_async("toggle_panel"),
                    'I' => self.cmd_async("toggle_inputview"),
                    else => {},
                },
                mod.ALT | mod.SHIFT => switch (keynormal) {
                    'P' => self.cmd("palette_menu_down", .{}),
                    else => {},
                },
                mod.ALT => switch (keynormal) {
                    'P' => self.cmd("palette_menu_up", .{}),
                    'L' => self.cmd("toggle_panel", .{}),
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
                    key.F11 => self.cmd("toggle_panel", .{}),
                    key.F12 => self.cmd("toggle_inputview", .{}),
                    key.ESC => self.cmd("palette_menu_cancel", .{}),
                    key.UP => self.cmd("palette_menu_up", .{}),
                    key.DOWN => self.cmd("palette_menu_down", .{}),
                    key.PGUP => self.cmd("palette_menu_pageup", .{}),
                    key.PGDOWN => self.cmd("palette_menu_pagedown", .{}),
                    key.ENTER => self.cmd("palette_menu_activate", .{}),
                    key.BACKSPACE => self.delete_code_point(),
                    else => if (!key.synthesized_p(keypress))
                        self.insert_code_point(egc)
                    else {},
                },
                else => {},
            };
        }

        fn mapRelease(self: *Self, keypress: u32, _: u32) !void {
            return switch (keypress) {
                key.LCTRL, key.RCTRL => if (self.menu.selected orelse 0 > 0) return self.cmd("palette_menu_activate", .{}),
                else => {},
            };
        }

        fn start_query(self: *Self) !void {
            self.items = 0;
            self.menu.reset_items();
            self.menu.selected = null;
            for (self.entries.items) |entry|
                self.longest = @max(self.longest, entry.name.len);

            if (self.inputbox.text.items.len == 0) {
                self.total_items = 0;
                var pos: usize = 0;
                for (self.entries.items) |*entry| {
                    defer self.total_items += 1;
                    defer pos += 1;
                    if (pos < self.view_pos) continue;
                    if (self.items < self.view_rows)
                        try options.add_menu_entry(self, entry, null);
                }
            } else {
                _ = try self.query_entries(self.inputbox.text.items);
            }
            self.menu.select_down();
            self.do_resize();
            tui.current().refresh_hover();
            self.selection_updated();
        }

        fn query_entries(self: *Self, query: []const u8) error{OutOfMemory}!usize {
            var searcher = try fuzzig.Ascii.init(
                self.allocator,
                self.longest, // haystack max size
                self.longest, // needle max size
                .{ .case_sensitive = false },
            );
            defer searcher.deinit();

            const Match = struct {
                entry: *Entry,
                score: i32,
                matches: []const usize,
            };

            var matches = std.ArrayList(Match).init(self.allocator);

            for (self.entries.items) |*entry| {
                const match = searcher.scoreMatches(entry.name, query);
                if (match.score) |score|
                    (try matches.addOne()).* = .{
                        .entry = entry,
                        .score = score,
                        .matches = try self.allocator.dupe(usize, match.matches),
                    };
            }
            if (matches.items.len == 0) return 0;

            const less_fn = struct {
                fn less_fn(_: void, lhs: Match, rhs: Match) bool {
                    return if (lhs.score == rhs.score)
                        lhs.entry.name.len < rhs.entry.name.len
                    else
                        lhs.score > rhs.score;
                }
            }.less_fn;
            std.mem.sort(Match, matches.items, {}, less_fn);

            var pos: usize = 0;
            self.total_items = 0;
            for (matches.items) |*match| {
                defer self.total_items += 1;
                defer pos += 1;
                if (pos < self.view_pos) continue;
                if (self.items < self.view_rows)
                    try options.add_menu_entry(self, match.entry, match.matches);
            }
            return matches.items.len;
        }

        fn delete_word(self: *Self) !void {
            if (std.mem.lastIndexOfAny(u8, self.inputbox.text.items, "/\\. -_")) |pos| {
                self.inputbox.text.shrinkRetainingCapacity(pos);
            } else {
                self.inputbox.text.shrinkRetainingCapacity(0);
            }
            self.inputbox.cursor = self.inputbox.text.items.len;
            self.view_pos = 0;
            return self.start_query();
        }

        fn delete_code_point(self: *Self) !void {
            if (self.inputbox.text.items.len > 0) {
                self.inputbox.text.shrinkRetainingCapacity(self.inputbox.text.items.len - 1);
                self.inputbox.cursor = self.inputbox.text.items.len;
            }
            self.view_pos = 0;
            return self.start_query();
        }

        fn insert_code_point(self: *Self, c: u32) !void {
            var buf: [6]u8 = undefined;
            const bytes = try ucs32_to_utf8(&[_]u32{c}, &buf);
            try self.inputbox.text.appendSlice(buf[0..bytes]);
            self.inputbox.cursor = self.inputbox.text.items.len;
            self.view_pos = 0;
            return self.start_query();
        }

        fn insert_bytes(self: *Self, bytes: []const u8) !void {
            try self.inputbox.text.appendSlice(bytes);
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

        fn selection_updated(self: *Self) void {
            if (@hasDecl(options, "updated"))
                options.updated(self, self.menu.get_selected()) catch {};
        }

        const cmds = struct {
            pub const Target = Self;
            const Ctx = command.Context;
            const Result = command.Result;

            pub fn palette_menu_down(self: *Self, _: Ctx) Result {
                if (self.menu.selected) |selected| {
                    if (selected == self.view_rows - 1) {
                        self.view_pos += 1;
                        try self.start_query();
                        self.menu.select_last();
                        return;
                    }
                }
                self.menu.select_down();
                self.selection_updated();
            }

            pub fn palette_menu_up(self: *Self, _: Ctx) Result {
                if (self.menu.selected) |selected| {
                    if (selected == 0 and self.view_pos > 0) {
                        self.view_pos -= 1;
                        try self.start_query();
                        self.menu.select_first();
                        return;
                    }
                }
                self.menu.select_up();
                self.selection_updated();
            }

            pub fn palette_menu_pagedown(self: *Self, _: Ctx) Result {
                if (self.total_items > self.view_rows) {
                    self.view_pos += self.view_rows;
                    if (self.view_pos > self.total_items - self.view_rows)
                        self.view_pos = self.total_items - self.view_rows;
                }
                try self.start_query();
                self.menu.select_last();
                self.selection_updated();
            }

            pub fn palette_menu_pageup(self: *Self, _: Ctx) Result {
                if (self.view_pos > self.view_rows)
                    self.view_pos -= self.view_rows
                else
                    self.view_pos = 0;
                try self.start_query();
                self.menu.select_first();
                self.selection_updated();
            }

            pub fn palette_menu_activate(self: *Self, _: Ctx) Result {
                self.menu.activate_selected();
            }

            pub fn palette_menu_cancel(self: *Self, _: Ctx) Result {
                if (@hasDecl(options, "cancel")) try options.cancel(self);
                try self.cmd("exit_overlay_mode", .{});
            }
        };
    };
}
