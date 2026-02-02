const std = @import("std");
const tp = @import("thespian");
const log = @import("log");
const cbor = @import("cbor");
const fuzzig = @import("fuzzig");

const Plane = @import("renderer").Plane;
const input = @import("input");
const keybind = @import("keybind");
const command = @import("command");
const EventHandler = @import("EventHandler");

const tui = @import("../../tui.zig");
const Button = @import("../../Button.zig");
const InputBox = @import("../../InputBox.zig");
const Widget = @import("../../Widget.zig");
const scrollbar_v = @import("../../scrollbar_v.zig");
const ModalBackground = @import("../../ModalBackground.zig");

pub const Menu = @import("../../Menu.zig");

const max_menu_width = 80;
const default_widget_type: Widget.Type = .palette;

pub const Placement = enum {
    primary_cursor,
};

pub fn Create(options: type) type {
    return struct {
        allocator: std.mem.Allocator,
        menu: *Menu.State(*Self),
        mode: keybind.Mode,
        query: std.ArrayList(u8),
        match_count: usize,
        logger: log.Logger,
        longest: usize = 0,
        commands: command.Collection(cmds) = undefined,
        entries: std.ArrayList(Entry) = undefined,
        longest_hint: usize = 0,
        initial_selected: ?usize = null,
        placement: Placement,
        quick_activate_enabled: bool = true,

        items: usize = 0,
        view_rows: usize,
        view_pos: usize = 0,
        total_items: usize = 0,

        value: ValueType = if (@hasDecl(options, "defaultValue")) options.defaultValue else {},

        const Entry = options.Entry;
        const Self = @This();
        const ValueType = if (@hasDecl(options, "ValueType")) options.ValueType else void;
        const widget_type: Widget.Type = if (@hasDecl(options, "widget_type")) options.widget_type else default_widget_type;

        pub const MenuType = Menu.Options(*Self).MenuType;
        pub const ButtonType = MenuType.ButtonType;
        pub const Pos = Widget.Pos;

        pub fn create(allocator: std.mem.Allocator) !tui.Mode {
            return create_with_args(allocator, .{});
        }

        pub fn create_with_args(allocator: std.mem.Allocator, ctx: command.Context) !tui.Mode {
            const mv = tui.mainview() orelse return error.NotFound;
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .menu = try Menu.create(*Self, allocator, tui.plane(), .{
                    .ctx = self,
                    .style = widget_type,
                    .on_render = if (@hasDecl(options, "on_render_menu")) options.on_render_menu else on_render_menu,
                    .prepare_resize = prepare_resize_menu,
                    .after_resize = after_resize_menu,
                    .on_scroll = EventHandler.bind(self, Self.on_scroll),
                    .on_click4 = mouse_click_button4,
                    .on_click5 = mouse_click_button5,
                }),
                .logger = log.logger(@typeName(Self)),
                .query = .empty,
                .view_rows = get_view_rows(tui.screen()),
                .entries = .empty,
                .mode = try keybind.mode(switch (tui.config().dropdown_keybinds) {
                    .standard => "overlay/dropdown",
                    .noninvasive => "overlay/dropdown-noninvasive",
                }, allocator, .{}),
                .placement = if (@hasDecl(options, "placement")) options.placement else .top_center,
                .match_count = 0,
            };
            try self.commands.init(self);
            self.mode.event_handler = EventHandler.to_owned(self);
            self.mode.name = options.name;
            if (self.menu.scrollbar) |scrollbar| scrollbar.style_factory = scrollbar_style;
            if (@hasDecl(options, "init")) try options.init(self);
            self.longest_hint = if (@hasDecl(options, "load_entries_with_args"))
                try options.load_entries_with_args(self, ctx)
            else
                try options.load_entries(self);
            self.match_count = self.entries.items.len;
            if (@hasDecl(options, "restore_state"))
                options.restore_state(self) catch {};
            if (@hasDecl(options, "initial_query")) blk: {
                const initial_query = options.initial_query(self, self.allocator) catch break :blk;
                defer self.allocator.free(initial_query);
                try self.query.appendSlice(self.allocator, initial_query);
            }
            try self.start_query(0);
            try mv.floating_views.add(self.menu.container_widget);

            if (@hasDecl(options, "handle_event")) blk: {
                const editor = mv.get_active_editor() orelse break :blk;
                editor.handlers.add(EventHandler.bind(self, handle_event)) catch {};
            }
            return self.mode;
        }

        pub fn deinit(self: *Self) void {
            if (@hasDecl(options, "handle_event")) blk: {
                const editor = tui.get_active_editor() orelse break :blk;
                editor.handlers.remove_ptr(self);
            }
            self.commands.deinit();
            if (@hasDecl(options, "deinit"))
                options.deinit(self);
            self.entries.deinit(self.allocator);
            if (tui.mainview()) |mv|
                mv.floating_views.remove(self.menu.container_widget);
            self.logger.deinit();
            self.allocator.destroy(self);
        }

        fn handle_event(self: *Self, from_: tp.pid_ref, m: tp.message) tp.result {
            if (@hasDecl(options, "handle_event"))
                return options.handle_event(self, from_, m);
        }

        fn scrollbar_style(sb: *scrollbar_v, theme: *const Widget.Theme) Widget.Theme.Style {
            return if (sb.active)
                .{ .fg = theme.scrollbar_active.fg, .bg = theme.editor_widget.bg }
            else if (sb.hover)
                .{ .fg = theme.scrollbar_hover.fg, .bg = theme.editor_widget.bg }
            else
                .{ .fg = theme.scrollbar.fg, .bg = theme.editor_widget.bg };
        }

        fn on_render_menu(_: *Self, button: *ButtonType, theme: *const Widget.Theme, selected: bool) bool {
            const style_base = theme.editor_widget;
            const style_label = if (button.active) theme.editor_cursor else if (button.hover or selected) theme.editor_selection else theme.editor_widget;
            const style_hint = if (tui.find_scope_style(theme, "entity.name")) |sty| sty.style else style_label;
            button.plane.set_base_style(style_base);
            button.plane.erase();
            button.plane.home();
            button.plane.set_style(style_label);
            if (button.active or button.hover or selected) {
                button.plane.fill(" ");
                button.plane.home();
            }
            var label: []const u8 = undefined;
            var hint: []const u8 = undefined;
            var iter = button.opts.label; // label contains cbor, first the file name, then multiple match indexes
            if (!(cbor.matchString(&iter, &label) catch false))
                label = "#ERROR#";
            if (!(cbor.matchString(&iter, &hint) catch false))
                hint = "";
            button.plane.set_style(style_hint);
            tui.render_pointer(&button.plane, selected);
            button.plane.set_style(style_label);
            _ = button.plane.print("{s} ", .{label}) catch {};
            button.plane.set_style(style_hint);
            _ = button.plane.print_aligned_right(0, "{s} ", .{hint}) catch {};
            var index: usize = 0;
            var len = cbor.decodeArrayHeader(&iter) catch return false;
            while (len > 0) : (len -= 1) {
                if (cbor.matchValue(&iter, cbor.extract(&index)) catch break) {
                    tui.render_match_cell(&button.plane, 0, index + 2, theme) catch break;
                } else break;
            }
            return false;
        }

        fn prepare_resize_menu(self: *Self, menu: *Menu.State(*Self), _: Widget.Box) Widget.Box {
            const padding = tui.get_widget_style(menu.opts.style).padding;
            return self.prepare_resize(padding) orelse .{};
        }

        fn prepare_resize(self: *Self, padding: Widget.Style.Margin) ?Widget.Box {
            const screen = tui.screen();
            const w = self.prepare_width(screen);
            return switch (self.placement) {
                .primary_cursor => self.prepare_resize_primary_cursor(screen, w, padding),
            };
        }

        fn prepare_width(self: *Self, screen: Widget.Box) usize {
            return @min(screen.w - 2, @max(@min(self.longest + 3, max_menu_width) + 2 + self.longest_hint, options.label.len + 2));
        }

        fn prepare_resize_at_y_x(self: *Self, screen: Widget.Box, w: usize, y: usize, x: usize) Widget.Box {
            self.view_rows = get_view_rows(screen) -| y;
            const h = @min(self.items + self.menu.header_count, self.view_rows + self.menu.header_count);
            return .{ .y = y, .x = x, .w = w, .h = h };
        }

        fn prepare_resize_primary_cursor(self: *Self, screen: Widget.Box, w: usize, padding: Widget.Style.Margin) ?Widget.Box {
            const mv = tui.mainview() orelse return null;
            const ed = mv.get_active_editor() orelse return null;
            const cursor = ed.get_primary_abs() orelse return null;
            return self.prepare_resize_at_y_x(screen, w, cursor.row + 1 + padding.top, cursor.col);
        }

        fn after_resize_menu(self: *Self, _: *Menu.State(*Self), _: Widget.Box) void {
            return self.after_resize();
        }

        fn after_resize(self: *Self) void {
            self.update_scrollbar();
            // self.start_query(0) catch {};
        }

        fn do_resize(self: *Self, padding: Widget.Style.Margin) void {
            const box = self.prepare_resize(padding) orelse return;
            self.menu.resize(box.to_client_box(padding));
            self.after_resize();
        }

        fn get_view_rows(screen: Widget.Box) usize {
            var h = screen.h;
            if (h > 0) h = h / 5 * 4;
            return h;
        }

        fn on_scroll(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!void {
            if (try m.match(.{ "scroll_to", tp.extract(&self.view_pos) })) {
                self.start_query(0) catch |e| return tp.exit_error(e, @errorReturnTrace());
            }
        }

        fn update_scrollbar(self: *Self) void {
            if (self.menu.scrollbar) |scrollbar|
                scrollbar.set(@intCast(@max(self.total_items, 1) - 1), @intCast(self.view_rows), @intCast(self.view_pos));
        }

        fn mouse_click_button4(menu: **Menu.State(*Self), _: *ButtonType, _: Widget.Pos) void {
            const self = &menu.*.opts.ctx.*;
            if (self.view_pos < Menu.scroll_lines) {
                self.view_pos = 0;
            } else {
                self.view_pos -= Menu.scroll_lines;
            }
            self.update_scrollbar();
            self.start_query(0) catch {};
        }

        fn mouse_click_button5(menu: **Menu.State(*Self), _: *ButtonType, _: Widget.Pos) void {
            const self = &menu.*.opts.ctx.*;
            if (self.view_pos < @max(self.total_items, self.view_rows) - self.view_rows)
                self.view_pos += Menu.scroll_lines;
            self.update_scrollbar();
            self.start_query(0) catch {};
        }

        fn mouse_palette_menu_cancel(self: *Self, _: *ModalBackground.State(*Self)) void {
            self.cmd("palette_menu_cancel", .{}) catch {};
        }

        pub fn receive(_: *Self, _: tp.pid_ref, _: tp.message) error{Exit}!bool {
            return false;
        }

        pub fn update_query(self: *Self, query: []const u8) !void {
            self.query.clearRetainingCapacity();
            try self.query.appendSlice(self.allocator, query);
            return self.start_query(0);
        }

        fn start_query(self: *Self, n: usize) !void {
            self.items = 0;
            self.menu.reset_items();
            self.menu.selected = null;
            self.longest = self.query.items.len;
            for (self.entries.items) |entry|
                self.longest = @max(self.longest, entry.label.len);

            if (self.query.items.len == 0) {
                self.total_items = 0;
                var pos: usize = 0;
                for (self.entries.items) |*entry| {
                    defer self.total_items += 1;
                    defer pos += 1;
                    if (pos < self.view_pos) continue;
                    if (self.items < self.view_rows)
                        try options.add_menu_entry(self, entry, null);
                }
                self.match_count = self.entries.items.len;
            } else {
                self.match_count = try self.query_entries(self.query.items);
            }
            if (self.initial_selected) |idx| {
                self.initial_selected = null;
                self.select(idx);
            } else {
                self.menu.select_down();
                var i = n;
                while (i > 0) : (i -= 1)
                    self.menu.select_down();
                const padding = tui.get_widget_style(widget_type).padding;
                self.do_resize(padding);
                tui.refresh_hover(@src());
                self.selection_updated();
            }
        }

        fn query_entries(self: *Self, query: []const u8) error{ OutOfMemory, WriteFailed }!usize {
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

            var matches: std.ArrayList(Match) = .empty;

            for (self.entries.items) |*entry| {
                const match = searcher.scoreMatches(entry.label, query);
                (try matches.addOne(self.allocator)).* = .{
                    .entry = entry,
                    .score = match.score orelse 0,
                    .matches = try self.allocator.dupe(usize, match.matches),
                };
            }
            if (matches.items.len == 0) return 0;

            const less_fn = struct {
                fn less_fn(_: void, lhs: Match, rhs: Match) bool {
                    return if (lhs.score == rhs.score)
                        std.mem.order(u8, lhs.entry.sort_text, rhs.entry.sort_text) == .lt
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

        fn select(self: *Self, idx: usize) void {
            if (self.total_items < self.view_rows) {
                self.view_pos = 0;
            } else if (idx > self.total_items - self.view_rows) {
                self.view_pos = self.total_items - self.view_rows;
            } else if (idx > self.view_rows / 2) {
                self.view_pos = idx - self.view_rows / 2;
            } else {
                self.view_pos = 0;
            }
            self.update_scrollbar();
            if (idx < self.view_pos + 1)
                self.start_query(0) catch {}
            else
                self.start_query(idx - self.view_pos - 1) catch {};
        }

        const cmds = struct {
            pub const Target = Self;
            const Ctx = command.Context;
            const Meta = command.Metadata;
            const Result = command.Result;

            pub fn palette_menu_down(self: *Self, _: Ctx) Result {
                if (self.menu.selected) |selected| {
                    if (selected == self.view_rows -| 1 and
                        self.view_pos + self.view_rows < self.total_items)
                    {
                        self.view_pos += 1;
                        try self.start_query(0);
                        self.menu.select_last();
                        self.selection_updated();
                        return;
                    }
                }
                self.menu.select_down();
                self.selection_updated();
            }
            pub const palette_menu_down_meta: Meta = .{};

            pub fn palette_menu_up(self: *Self, _: Ctx) Result {
                if (self.menu.selected) |selected| {
                    if (selected == 0 and self.view_pos > 0) {
                        self.view_pos -= 1;
                        try self.start_query(0);
                        self.menu.select_first();
                        self.selection_updated();
                        return;
                    }
                }
                self.menu.select_up();
                self.selection_updated();
            }
            pub const palette_menu_up_meta: Meta = .{};

            pub fn palette_menu_pagedown(self: *Self, _: Ctx) Result {
                if (self.total_items > self.view_rows) {
                    self.view_pos += self.view_rows;
                    if (self.view_pos > self.total_items - self.view_rows)
                        self.view_pos = self.total_items - self.view_rows;
                }
                try self.start_query(0);
                self.menu.select_last();
                self.selection_updated();
            }
            pub const palette_menu_pagedown_meta: Meta = .{};

            pub fn palette_menu_pageup(self: *Self, _: Ctx) Result {
                if (self.view_pos > self.view_rows)
                    self.view_pos -= self.view_rows
                else
                    self.view_pos = 0;
                try self.start_query(0);
                self.menu.select_first();
                self.selection_updated();
            }
            pub const palette_menu_pageup_meta: Meta = .{};

            pub fn palette_menu_bottom(self: *Self, _: Ctx) Result {
                if (self.total_items > self.view_rows) {
                    self.view_pos = self.total_items - self.view_rows;
                }
                try self.start_query(0);
                self.menu.select_last();
                self.selection_updated();
            }
            pub const palette_menu_bottom_meta: Meta = .{};

            pub fn palette_menu_top(self: *Self, _: Ctx) Result {
                self.view_pos = 0;
                try self.start_query(0);
                self.menu.select_first();
                self.selection_updated();
            }
            pub const palette_menu_top_meta: Meta = .{};

            pub fn palette_menu_delete_item(self: *Self, _: Ctx) Result {
                if (@hasDecl(options, "delete_item")) {
                    const button = self.menu.get_selected() orelse return;
                    const refresh = options.delete_item(self.menu, button);
                    if (refresh) {
                        if (@hasDecl(options, "load_entries")) {
                            options.clear_entries(self);
                            self.longest_hint = try options.load_entries(self);
                            if (self.entries.items.len > 0)
                                self.initial_selected = self.menu.selected;
                            try self.start_query(0);
                        } else {
                            return palette_menu_cancel(self, .{});
                        }
                    }
                }
            }
            pub const palette_menu_delete_item_meta: Meta = .{
                .description = "Delete item",
                .icon = "󰗨",
            };

            pub fn palette_menu_complete(self: *Self, _: Ctx) Result {
                if (@hasDecl(options, "complete"))
                    options.complete(self, self.menu.get_selected()) catch {};
            }
            pub const palette_menu_complete_meta: Meta = .{};

            pub fn palette_menu_activate(self: *Self, _: Ctx) Result {
                self.menu.activate_selected();
            }
            pub const palette_menu_activate_meta: Meta = .{};

            pub fn palette_menu_cancel(self: *Self, _: Ctx) Result {
                if (@hasDecl(options, "cancel")) try options.cancel(self);
                try self.cmd("exit_overlay_mode", .{});
            }
            pub const palette_menu_cancel_meta: Meta = .{};

            pub fn overlay_next_widget_style(self: *Self, _: Ctx) Result {
                tui.set_next_style(widget_type);
                const padding = tui.get_widget_style(widget_type).padding;
                self.do_resize(padding);
                tui.need_render(@src());
                try tui.save_config();
            }
            pub const overlay_next_widget_style_meta: Meta = .{};
        };
    };
}
