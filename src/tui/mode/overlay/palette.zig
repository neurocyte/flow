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

pub fn Create(options: type) type {
    return struct {
        allocator: std.mem.Allocator,
        modal: *ModalBackground.State(*Self),
        menu: *Menu.State(*Self),
        inputbox: *InputBox.State(*Self),
        logger: log.Logger,
        longest: usize = 0,
        commands: command.Collection(cmds) = undefined,
        entries: std.ArrayList(Entry) = undefined,
        longest_hint: usize = 0,
        initial_selected: ?usize = null,

        items: usize = 0,
        view_rows: usize,
        view_pos: usize = 0,
        total_items: usize = 0,

        const Entry = options.Entry;
        const Self = @This();

        pub const MenuState = Menu.State(*Self);
        pub const ButtonState = Button.State(*Menu.State(*Self));

        pub fn create(allocator: std.mem.Allocator) !tui.Mode {
            const mv = tui.mainview() orelse return error.NotFound;
            const self: *Self = try allocator.create(Self);
            self.* = .{
                .allocator = allocator,
                .modal = try ModalBackground.create(*Self, allocator, tui.mainview_widget(), .{
                    .ctx = self,
                    .on_click = mouse_palette_menu_cancel,
                }),
                .menu = try Menu.create(*Self, allocator, tui.plane(), .{
                    .ctx = self,
                    .on_render = if (@hasDecl(options, "on_render_menu")) options.on_render_menu else on_render_menu,
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
                .view_rows = get_view_rows(tui.screen()),
                .entries = std.ArrayList(Entry).init(allocator),
            };
            if (self.menu.scrollbar) |scrollbar| scrollbar.style_factory = scrollbar_style;
            self.longest_hint = try options.load_entries(self);
            if (@hasDecl(options, "restore_state"))
                options.restore_state(self) catch {};
            try self.commands.init(self);
            try self.start_query(0);
            try mv.floating_views.add(self.modal.widget());
            try mv.floating_views.add(self.menu.container_widget);
            var mode = try keybind.mode("overlay/palette", allocator, .{
                .insert_command = "overlay_insert_bytes",
            });
            mode.event_handler = EventHandler.to_owned(self);
            mode.name = options.name;
            return mode;
        }

        pub fn deinit(self: *Self) void {
            self.commands.deinit();
            if (@hasDecl(options, "deinit"))
                options.deinit(self);
            self.entries.deinit();
            tui.message_filters().remove_ptr(self);
            if (tui.mainview()) |mv| {
                mv.floating_views.remove(self.menu.container_widget);
                mv.floating_views.remove(self.modal.widget());
            }
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
            const pointer = if (selected) "⏵" else " ";
            _ = button.plane.print("{s}", .{pointer}) catch {};
            button.plane.set_style(style_label);
            _ = button.plane.print("{s} ", .{label}) catch {};
            button.plane.set_style(style_hint);
            _ = button.plane.print_aligned_right(0, "{s} ", .{hint}) catch {};
            var index: usize = 0;
            var len = cbor.decodeArrayHeader(&iter) catch return false;
            while (len > 0) : (len -= 1) {
                if (cbor.matchValue(&iter, cbor.extract(&index)) catch break) {
                    tui.render_match_cell(&button.plane, 0, index + 1, theme) catch break;
                } else break;
            }
            return false;
        }

        fn on_resize_menu(self: *Self, _: *Menu.State(*Self), _: Widget.Box) void {
            self.do_resize();
            // self.start_query(0) catch {};
        }

        fn do_resize(self: *Self) void {
            const screen = tui.screen();
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
                self.start_query(0) catch |e| return tp.exit_error(e, @errorReturnTrace());
            }
        }

        fn update_scrollbar(self: *Self) void {
            if (self.menu.scrollbar) |scrollbar|
                scrollbar.set(@intCast(@max(self.total_items, 1) - 1), @intCast(self.view_rows), @intCast(self.view_pos));
        }

        fn mouse_click_button4(menu: **Menu.State(*Self), _: *Button.State(*Menu.State(*Self))) void {
            const self = &menu.*.opts.ctx.*;
            if (self.view_pos < Menu.scroll_lines) {
                self.view_pos = 0;
            } else {
                self.view_pos -= Menu.scroll_lines;
            }
            self.update_scrollbar();
            self.start_query(0) catch {};
        }

        fn mouse_click_button5(menu: **Menu.State(*Self), _: *Button.State(*Menu.State(*Self))) void {
            const self = &menu.*.opts.ctx.*;
            if (self.view_pos < @max(self.total_items, self.view_rows) - self.view_rows)
                self.view_pos += Menu.scroll_lines;
            self.update_scrollbar();
            self.start_query(0) catch {};
        }

        fn mouse_palette_menu_cancel(self: *Self, _: *ModalBackground.State(*Self)) void {
            self.cmd("palette_menu_cancel", .{}) catch {};
        }

        pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
            var text: []const u8 = undefined;

            if (try m.match(.{ "system_clipboard", tp.extract(&text) })) {
                self.insert_bytes(text) catch |e| return tp.exit_error(e, @errorReturnTrace());
            }
            return false;
        }

        fn start_query(self: *Self, n: usize) !void {
            self.items = 0;
            self.menu.reset_items();
            self.menu.selected = null;
            for (self.entries.items) |entry|
                self.longest = @max(self.longest, entry.label.len);

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
            if (self.initial_selected) |idx| {
                self.initial_selected = null;
                self.select(idx);
            } else {
                self.menu.select_down();
                var i = n;
                while (i > 0) : (i -= 1)
                    self.menu.select_down();
                self.do_resize();
                tui.refresh_hover();
                self.selection_updated();
            }
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
                const match = searcher.scoreMatches(entry.label, query);
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
                        lhs.entry.label.len < rhs.entry.label.len
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
            self.inputbox.cursor = tui.egc_chunk_width(self.inputbox.text.items, 0, 8);
            self.view_pos = 0;
            return self.start_query(0);
        }

        fn delete_code_point(self: *Self) !void {
            if (self.inputbox.text.items.len > 0) {
                self.inputbox.text.shrinkRetainingCapacity(self.inputbox.text.items.len - tui.egc_last(self.inputbox.text.items).len);
                self.inputbox.cursor = tui.egc_chunk_width(self.inputbox.text.items, 0, 8);
            }
            self.view_pos = 0;
            return self.start_query(0);
        }

        fn insert_code_point(self: *Self, c: u32) !void {
            var buf: [6]u8 = undefined;
            const bytes = try input.ucs32_to_utf8(&[_]u32{c}, &buf);
            try self.inputbox.text.appendSlice(buf[0..bytes]);
            self.inputbox.cursor = tui.egc_chunk_width(self.inputbox.text.items, 0, 8);
            self.view_pos = 0;
            return self.start_query(0);
        }

        fn insert_bytes(self: *Self, bytes: []const u8) !void {
            try self.inputbox.text.appendSlice(bytes);
            self.inputbox.cursor = tui.egc_chunk_width(self.inputbox.text.items, 0, 8);
            self.view_pos = 0;
            return self.start_query(0);
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
                    if (selected == self.view_rows - 1 and
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

            pub fn palette_menu_delete_item(self: *Self, _: Ctx) Result {
                if (@hasDecl(options, "delete_item")) {
                    const button = self.menu.get_selected() orelse return;
                    const refresh = options.delete_item(self.menu, button);
                    if (refresh) {
                        options.clear_entries(self);
                        self.longest_hint = try options.load_entries(self);
                        if (self.entries.items.len > 0)
                            self.initial_selected = self.menu.selected;
                        try self.start_query(0);
                    }
                }
            }
            pub const palette_menu_delete_item_meta: Meta = .{};

            pub fn palette_menu_activate(self: *Self, _: Ctx) Result {
                self.menu.activate_selected();
            }
            pub const palette_menu_activate_meta: Meta = .{};

            pub fn palette_menu_activate_quick(self: *Self, _: Ctx) Result {
                if (self.menu.selected orelse 0 > 0) self.menu.activate_selected();
            }
            pub const palette_menu_activate_quick_meta: Meta = .{};

            pub fn palette_menu_cancel(self: *Self, _: Ctx) Result {
                if (@hasDecl(options, "cancel")) try options.cancel(self);
                try self.cmd("exit_overlay_mode", .{});
            }
            pub const palette_menu_cancel_meta: Meta = .{};

            pub fn overlay_delete_word_left(self: *Self, _: Ctx) Result {
                self.delete_word() catch |e| return tp.exit_error(e, @errorReturnTrace());
            }
            pub const overlay_delete_word_left_meta: Meta = .{ .description = "Delete word to the left" };

            pub fn overlay_delete_backwards(self: *Self, _: Ctx) Result {
                self.delete_code_point() catch |e| return tp.exit_error(e, @errorReturnTrace());
            }
            pub const overlay_delete_backwards_meta: Meta = .{ .description = "Delete backwards" };

            pub fn overlay_insert_code_point(self: *Self, ctx: Ctx) Result {
                var egc: u32 = 0;
                if (!try ctx.args.match(.{tp.extract(&egc)}))
                    return error.InvalidPaletteInsertCodePointArgument;
                self.insert_code_point(egc) catch |e| return tp.exit_error(e, @errorReturnTrace());
            }
            pub const overlay_insert_code_point_meta: Meta = .{ .arguments = &.{.integer} };

            pub fn overlay_insert_bytes(self: *Self, ctx: Ctx) Result {
                var bytes: []const u8 = undefined;
                if (!try ctx.args.match(.{tp.extract(&bytes)}))
                    return error.InvalidPaletteInsertBytesArgument;
                self.insert_bytes(bytes) catch |e| return tp.exit_error(e, @errorReturnTrace());
            }
            pub const overlay_insert_bytes_meta: Meta = .{ .arguments = &.{.string} };

            pub fn overlay_toggle_panel(self: *Self, _: Ctx) Result {
                return self.cmd_async("toggle_panel");
            }
            pub const overlay_toggle_panel_meta: Meta = .{};

            pub fn overlay_toggle_inputview(self: *Self, _: Ctx) Result {
                return self.cmd_async("toggle_inputview");
            }
            pub const overlay_toggle_inputview_meta: Meta = .{};

            pub fn mini_mode_paste(self: *Self, ctx: Ctx) Result {
                return overlay_insert_bytes(self, ctx);
            }
            pub const mini_mode_paste_meta: Meta = .{ .arguments = &.{.string} };
        };
    };
}
