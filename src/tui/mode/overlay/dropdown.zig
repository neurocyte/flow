const std = @import("std");
const tp = @import("thespian");
const log = @import("log");
const cbor = @import("cbor");
const fuzzig = @import("fuzzig");

const Plane = @import("renderer").Plane;
const input = @import("input");
const keybind = @import("keybind");
const command = @import("command");
const MouseEvent = @import("MouseEvent");
const EventHandler = @import("EventHandler");

const tui = @import("../../tui.zig");
const Button = @import("../../Button.zig");
const Widget = @import("../../Widget.zig");
const scrollbar_v = @import("../../scrollbar_v.zig");
const ModalBackground = @import("../../ModalBackground.zig");

const renderer = @import("renderer");
const Scroller = @import("../../Scroller.zig");
pub const ListBox = @import("../../ListBox.zig");

const max_list_box_width = 80;
const default_widget_type: Widget.Type = .palette;

pub const Placement = enum {
    primary_cursor,
};

pub fn Create(options: type) type {
    return struct {
        allocator: std.mem.Allocator,
        list_box_layer: *tui.WidgetLayerBox,
        list_box: *ListBox.State(*Self),
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
        scroller: Scroller = .{ .pixel_offsets = true },
        selected: ?usize = null,
        last_updated: ?usize = null,
        matches: std.ArrayList(Match) = .empty,

        value: ValueType = if (@hasDecl(options, "defaultValue")) options.defaultValue else {},

        const Entry = options.Entry;
        const Match = struct { entry: *Entry, positions: ?[]const usize };
        const Self = @This();
        const ValueType = if (@hasDecl(options, "ValueType")) options.ValueType else void;
        const widget_type: Widget.Type = if (@hasDecl(options, "widget_type")) options.widget_type else default_widget_type;

        pub const ListBoxType = ListBox.Options(*Self).ListBoxType;
        pub const ButtonType = ListBoxType.ButtonType;
        pub const Pos = Widget.Pos;

        pub fn create(allocator: std.mem.Allocator) !tui.Mode {
            return create_with_args(allocator, .empty());
        }

        pub fn create_with_args(allocator: std.mem.Allocator, ctx: command.Context) !tui.Mode {
            const mv = tui.mainview() orelse return error.NotFound;
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const list_box_layer = try tui.WidgetLayerBox.create(allocator, tui.plane(), .{ .name = "dropdown.layer" });
            list_box_layer.blend = .src_over_blur;
            list_box_layer.alpha = tui.palette_opacity();
            list_box_layer.radius = 8;
            list_box_layer.corners = .bottom;
            list_box_layer.shadow = .{ .edges = .{ .top = false } };
            errdefer list_box_layer.deinit(allocator);
            self.* = .{
                .allocator = allocator,
                .list_box_layer = list_box_layer,
                .list_box = try ListBox.create(*Self, allocator, list_box_layer.inner_plane(), .{
                    .ctx = self,
                    .style = widget_type,
                    .on_render = options.on_render_list_box,
                    .after_resize = after_resize_list_box,
                    .on_mouse = on_list_mouse,
                    .pixel_scroll = true,
                    .submit_in_parent = true,
                }),
                .logger = log.logger(@typeName(Self)),
                .query = .empty,
                .view_rows = @min(
                    get_view_rows(tui.screen()),
                    tui.config().dropdown_limit + self.list_box.header_count,
                ),
                .entries = .empty,
                .mode = try keybind.mode(switch (tui.config().dropdown_keybinds) {
                    .standard => "overlay/dropdown",
                    .noninvasive => "overlay/dropdown-noninvasive",
                }, allocator, .{}),
                .placement = if (@hasDecl(options, "placement")) options.placement else .top_center,
                .match_count = 0,
            };
            try self.commands.init(self);
            errdefer self.commands.deinit();
            self.mode.event_handler = EventHandler.to_owned(self);
            self.mode.name = options.name;
            self.list_box_layer.ctx = self;
            self.list_box_layer.prepare_resize = prepare_resize_layer;
            self.list_box_layer.before_update = before_update_layer;
            self.list_box_layer.after_submit = after_submit_layer;
            try self.scroller.attach_scrollbar(allocator, self.list_box.container, self.list_box.container.plane);
            if (@hasDecl(options, "walk")) self.list_box_layer.walk_extra = walk_layer;
            self.list_box_layer.set(self.list_box.container_widget);
            if (self.scroller.scrollbar) |scrollbar| scrollbar.style_factory = scrollbar_style;
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
            try mv.floating_views.add(self.list_box_layer.widget());

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
            self.clear_matches();
            self.matches.deinit(self.allocator);
            self.scroller.deinit();
            self.entries.deinit(self.allocator);
            self.query.deinit(self.allocator);
            if (tui.mainview()) |mv|
                mv.floating_views.remove(self.list_box_layer.widget());
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

        fn walk_layer(ctx_: ?*anyopaque, walk_ctx: *anyopaque, f: Widget.WalkFn) bool {
            const self: *Self = @ptrCast(@alignCast(ctx_ orelse return false));
            return options.walk(self, walk_ctx, f);
        }

        fn prepare_resize_layer(ctx_: ?*anyopaque, _: *tui.WidgetLayerBox, _: Widget.Box) Widget.Box {
            const self: *Self = @ptrCast(@alignCast(ctx_.?));
            const padding = tui.get_widget_style(widget_type).padding;
            const box = self.prepare_resize(padding) orelse return .{};
            return box.from_client_box(padding);
        }

        fn prepare_resize(self: *Self, padding: Widget.Style.Margin) ?Widget.Box {
            const screen = tui.screen();
            const w = self.prepare_width(screen);
            return switch (self.placement) {
                .primary_cursor => self.prepare_resize_primary_cursor(screen, w, padding),
            };
        }

        fn prepare_width(self: *Self, screen: Widget.Box) usize {
            return @min(screen.w -| 2, @max(@min(self.longest + 3, max_list_box_width) + 2 + self.longest_hint, options.label.len + 2));
        }

        fn prepare_resize_at_y_x(self: *Self, screen: Widget.Box, w: usize, y: usize, x: usize) Widget.Box {
            self.view_rows = @min(
                get_view_rows(screen) -| y,
                tui.config().dropdown_limit + self.list_box.header_count,
            );
            const h = @min(self.items + self.list_box.header_count, self.view_rows + self.list_box.header_count);
            return .{ .y = y, .x = x, .w = w, .h = h };
        }

        fn prepare_resize_primary_cursor(self: *Self, screen: Widget.Box, w: usize, padding: Widget.Style.Margin) ?Widget.Box {
            const mv = tui.mainview() orelse return null;
            const ed = mv.get_active_editor() orelse return null;
            const cursor = ed.get_primary_abs() orelse return null;
            const x, const fit_w = self.fit_width(screen, w, cursor.col, padding);
            return self.prepare_resize_at_y_x(screen, fit_w, cursor.row + 1 + padding.top, x);
        }

        fn fit_width(self: *Self, screen: Widget.Box, w: usize, x: usize, padding: Widget.Style.Margin) struct { usize, usize } {
            const scrollbar_cols = 1;
            const min_w = @min(w, @max(@min(self.longest + 3, max_list_box_width) + 2 + scrollbar_cols, options.label.len + 2));
            const reserve = if (@hasDecl(options, "reserve_right")) options.reserve_right(self, x -| padding.left) else 0;
            const room = screen.w -| x -| padding.right;
            const fit_w = if (room >= min_w + reserve) @min(w, room - reserve) else @max(min_w, @min(w, room));
            return .{ @min(x, screen.w -| fit_w -| padding.right), fit_w };
        }

        fn after_resize_list_box(self: *Self, _: *ListBox.State(*Self), _: Widget.Box) void {
            return self.after_resize();
        }

        fn after_resize(self: *Self) void {
            const rows = @min(self.total_items, self.view_rows);
            self.scroller.set_view(.{ .h = rows, .w = self.list_box.list.plane.dim_x() }, &self.list_box.list.plane);
            self.scroller.set_size(self.total_items, rows);
            if (@hasDecl(options, "after_resize"))
                options.after_resize(self);
            self.selection_updated();
        }

        fn before_update_layer(ctx_: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx_ orelse return));
            self.scroller.update();
            if (self.scroller.take_owner_top()) |top| if (top != self.view_pos) {
                self.view_pos = top;
                self.fill_rows() catch {};
            };
            if (self.scroller.render()) tui.need_render(@src());
            self.list_box.set_scroll(self.scroller.pos(), self.scroller.draw_rows(), self.scroller.view_px());
        }

        fn after_submit_layer(ctx_: ?*anyopaque, handle: renderer.Layer.Handle) void {
            const self: *Self = @ptrCast(@alignCast(ctx_ orelse return));
            self.list_box.submit_items(handle);
        }

        fn on_list_mouse(self: *Self, m: tp.message) error{Exit}!bool {
            return self.scroller.receive_mouse(m);
        }

        fn do_resize(self: *Self, padding: Widget.Style.Margin) void {
            const box = self.prepare_resize(padding) orelse return;
            self.list_box_layer.handle_resize(box.to_client_box(padding));
            self.after_resize();
        }

        fn get_view_rows(screen: Widget.Box) usize {
            if (tui.config().completion_info_mode == .panel) {
                var h = screen.h;
                if (h > 0) h = h / 5 * 4;
                return h;
            } else {
                return screen.h;
            }
        }

        fn mouse_palette_menu_cancel(self: *Self, _: *ModalBackground.State(*Self), _: MouseEvent.Modifiers) void {
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
            defer tui.reset_hover(@src());
            self.longest = self.query.items.len;
            for (self.entries.items) |entry|
                self.longest = @max(self.longest, entry.label.len);
            self.clear_matches();
            if (self.query.items.len == 0) {
                try self.matches.ensureTotalCapacity(self.allocator, self.entries.items.len);
                for (self.entries.items) |*entry| self.matches.appendAssumeCapacity(.{ .entry = entry, .positions = null });
                self.match_count = self.entries.items.len;
            } else {
                self.match_count = try self.query_entries(self.query.items);
            }
            self.last_updated = null;
            self.total_items = self.matches.items.len;
            self.scroller.set_size(self.total_items, @min(self.total_items, self.view_rows));
            if (self.initial_selected) |idx| {
                self.initial_selected = null;
                return self.select(idx);
            }
            self.select_index(if (self.total_items > 0) @min(n, self.total_items - 1) else null, .jump);
        }

        fn clear_matches(self: *Self) void {
            for (self.matches.items) |match| if (match.positions) |p| self.allocator.free(p);
            self.matches.clearRetainingCapacity();
        }

        fn query_entries(self: *Self, query: []const u8) error{ OutOfMemory, WriteFailed }!usize {
            var searcher = try fuzzig.Ascii.init(
                self.allocator,
                self.longest, // haystack max size
                self.longest, // needle max size
                .{ .case_sensitive = false },
            );
            defer searcher.deinit();

            const Scored = struct { match: Match, score: i32 };
            var scored: std.ArrayList(Scored) = .empty;
            defer scored.deinit(self.allocator);
            errdefer for (scored.items) |m| if (m.match.positions) |p| self.allocator.free(p);
            var match_count: usize = 0;

            for (self.entries.items) |*entry| {
                const match = searcher.scoreMatches(entry.label, query);
                if (match.score) |_| match_count += 1;
                const match_positions = try self.allocator.dupe(usize, match.matches);
                errdefer self.allocator.free(match_positions);
                (try scored.addOne(self.allocator)).* = .{
                    .match = .{ .entry = entry, .positions = match_positions },
                    .score = match.score orelse 0,
                };
            }
            const less_fn = struct {
                fn less_fn(_: void, lhs: Scored, rhs: Scored) bool {
                    return if (lhs.score == rhs.score)
                        std.mem.order(u8, lhs.match.entry.sort_text, rhs.match.entry.sort_text) == .lt
                    else
                        lhs.score > rhs.score;
                }
            }.less_fn;
            std.mem.sort(Scored, scored.items, {}, less_fn);
            try self.matches.ensureTotalCapacity(self.allocator, scored.items.len);
            for (scored.items) |m| self.matches.appendAssumeCapacity(m.match);
            return match_count;
        }

        fn fill_rows(self: *Self) !void {
            defer tui.reset_hover(@src());
            self.items = 0;
            self.list_box.reset_items();
            const end = @min(self.total_items, self.view_pos + self.view_rows + 1);
            for (self.matches.items[@min(self.view_pos, end)..end]) |match|
                try options.add_list_box_entry(self, match.entry, match.positions);
            self.sync_selected();
            const padding = tui.get_widget_style(widget_type).padding;
            self.do_resize(padding);
        }

        fn sync_selected(self: *Self) void {
            const sel = self.selected orelse {
                self.list_box.selected = null;
                return;
            };
            self.list_box.selected = if (sel >= self.view_pos and sel < self.view_pos + self.items) sel - self.view_pos else null;
        }

        fn select_index(self: *Self, idx: ?usize, motion: enum { jump, glide }) void {
            self.selected = idx;
            if (idx) |sel| {
                const rows = @max(1, @min(self.total_items, self.view_rows));
                const top = self.scroller.dest();
                const new_top = if (sel < top) sel else if (sel >= top + rows) sel + 1 - rows else top;
                switch (motion) {
                    .jump => self.scroller.jump_to(new_top),
                    .glide => self.scroller.glide_to(new_top),
                }
                if (motion == .jump) {
                    self.view_pos = self.scroller.top();
                    _ = self.scroller.take_owner_top();
                }
            }
            self.fill_rows() catch {};
        }

        pub fn selected_button(self: *Self) ?*ButtonType {
            if (self.list_box.get_selected()) |button| return button;
            const sel = self.selected orelse return null;
            self.select_index(sel, .jump);
            return self.list_box.get_selected();
        }

        pub fn activate_selected(self: *Self) void {
            const button = self.selected_button() orelse return;
            button.opts.on_click(&button.opts.ctx, button, .{});
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
            if (!@hasDecl(options, "updated")) return;
            const button = self.list_box.get_selected();
            const current = if (button != null) self.selected else null;
            if (current != null and current == self.last_updated) return;
            self.last_updated = current;
            options.updated(self, button) catch {};
        }

        fn select(self: *Self, idx: usize) void {
            if (self.total_items == 0) return self.select_index(null, .jump);
            const sel = @min(idx -| 1, self.total_items - 1);
            const rows = @min(self.total_items, self.view_rows);
            self.scroller.jump_to(@min(sel -| rows / 2, self.total_items - rows));
            self.select_index(sel, .jump);
        }

        const cmds = struct {
            pub const Target = Self;
            const Ctx = command.Context;
            const Meta = command.Metadata;
            const Result = command.Result;

            pub fn palette_menu_down(self: *Self, _: Ctx) Result {
                if (self.total_items == 0) return;
                const sel = if (self.selected) |sel| @min(sel + 1, self.total_items - 1) else 0;
                self.select_index(sel, .jump);
            }
            pub const palette_menu_down_meta: Meta = .{ .description = "Next item" };

            pub fn palette_menu_up(self: *Self, _: Ctx) Result {
                if (self.total_items == 0) return;
                self.select_index((self.selected orelse 0) -| 1, .jump);
            }
            pub const palette_menu_up_meta: Meta = .{ .description = "Previous item" };

            pub fn palette_menu_pagedown(self: *Self, _: Ctx) Result {
                if (self.total_items == 0) return;
                self.select_index(@min((self.selected orelse 0) + self.view_rows, self.total_items - 1), .glide);
            }
            pub const palette_menu_pagedown_meta: Meta = .{ .description = "Next page" };

            pub fn palette_menu_pageup(self: *Self, _: Ctx) Result {
                if (self.total_items == 0) return;
                self.select_index((self.selected orelse 0) -| self.view_rows, .glide);
            }
            pub const palette_menu_pageup_meta: Meta = .{ .description = "Previous page" };

            pub fn palette_menu_bottom(self: *Self, _: Ctx) Result {
                if (self.total_items == 0) return;
                self.select_index(self.total_items - 1, .jump);
            }
            pub const palette_menu_bottom_meta: Meta = .{ .description = "Last item" };

            pub fn palette_menu_top(self: *Self, _: Ctx) Result {
                if (self.total_items == 0) return;
                self.select_index(0, .jump);
            }
            pub const palette_menu_top_meta: Meta = .{ .description = "First item" };

            pub fn palette_menu_delete_item(self: *Self, _: Ctx) Result {
                if (@hasDecl(options, "delete_item")) {
                    const button = self.selected_button() orelse return;
                    const refresh = options.delete_item(self.list_box, button);
                    if (refresh) {
                        if (@hasDecl(options, "load_entries")) {
                            options.clear_entries(self);
                            self.longest_hint = try options.load_entries(self);
                            if (self.entries.items.len > 0)
                                self.initial_selected = if (self.selected) |sel| sel + 1 else null;
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
                    options.complete(self, self.selected_button()) catch {};
            }
            pub const palette_menu_complete_meta: Meta = .{ .description = "Complete selected item" };

            pub fn palette_menu_activate(self: *Self, _: Ctx) Result {
                self.activate_selected();
            }
            pub const palette_menu_activate_meta: Meta = .{ .description = "Select" };

            pub fn palette_menu_cancel(self: *Self, ctx: Ctx) Result {
                if (@hasDecl(options, "cancel")) try options.cancel(self, ctx);
                try self.cmd("exit_overlay_mode", ctx);
            }
            pub const palette_menu_cancel_meta: Meta = .{ .description = "Cancel" };

            pub fn mini_mode_paste(_: *Self, ctx: Ctx) Result {
                var bytes: []const u8 = undefined;
                if (!try ctx.args.match(.{tp.extract(&bytes)}))
                    return error.InvalidDropdownPasteArgument;
                try tui.paste_to_editor(bytes);
            }
            pub const mini_mode_paste_meta: Meta = .{ .arguments = &.{.string} };

            pub fn overlay_next_widget_style(self: *Self, _: Ctx) Result {
                tui.set_next_style(widget_type);
                const padding = tui.get_widget_style(widget_type).padding;
                self.do_resize(padding);
                tui.need_render(@src());
                try tui.save_config();
            }
            pub const overlay_next_widget_style_meta: Meta = .{ .description = "Next dropdown style" };
        };
    };
}
