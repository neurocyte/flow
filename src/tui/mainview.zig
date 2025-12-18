const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const tracy = @import("tracy");
const ripgrep = @import("ripgrep");
const root = @import("soft_root").root;
const location_history = @import("location_history");
const project_manager = @import("project_manager");
const log = @import("log");
const shell = @import("shell");
const syntax = @import("syntax");
const file_type_config = @import("file_type_config");
const lsp_config = @import("lsp_config");
const builtin = @import("builtin");
const build_options = @import("build_options");

const Plane = @import("renderer").Plane;
const input = @import("input");
const command = @import("command");
const Buffer = @import("Buffer");

const tui = @import("tui.zig");
const Box = @import("Box.zig");
const EventHandler = @import("EventHandler");
const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const WidgetStack = @import("WidgetStack.zig");
const ed = @import("editor.zig");
const home = @import("home.zig");

const logview = @import("logview.zig");
const filelist_view = @import("filelist_view.zig");
const info_view = @import("info_view.zig");
const input_view = @import("inputview.zig");
const keybind_view = @import("keybindview.zig");

const Self = @This();
const Commands = command.Collection(cmds);

allocator: std.mem.Allocator,
plane: Plane,
widgets: *WidgetList,
widgets_widget: Widget,
floating_views: WidgetStack,
commands: Commands = undefined,
top_bar: ?Widget = null,
bottom_bar: ?Widget = null,
active_editor: ?*ed.Editor = null,
views: *WidgetList,
views_widget: Widget,
active_view: usize = 0,
panes: *WidgetList,
panes_widget: Widget,
panels: ?*WidgetList = null,
last_match_text: ?[]const u8 = null,
location_history_: location_history,
buffer_manager: Buffer.Manager,
find_in_files_state: enum { init, adding, done } = .done,
file_list_type: FileListType = .find_in_files,
panel_height: ?usize = null,
symbols: std.ArrayListUnmanaged(u8) = .empty,
symbols_complete: bool = true,
closing_project: bool = false,

const FileListType = enum {
    diagnostics,
    references,
    find_in_files,
};

pub const CreateError = error{ OutOfMemory, ThespianSpawnFailed };

pub fn create(allocator: std.mem.Allocator) CreateError!Widget {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .plane = tui.plane(),
        .widgets = undefined,
        .widgets_widget = undefined,
        .floating_views = WidgetStack.init(allocator),
        .location_history_ = try location_history.create(),
        .views = undefined,
        .views_widget = undefined,
        .panes = undefined,
        .panes_widget = undefined,
        .buffer_manager = Buffer.Manager.init(allocator),
    };
    try self.commands.init(self);
    const w = Widget.to(self);

    const widgets = try WidgetList.createV(allocator, self.plane, @typeName(Self), .dynamic);
    self.widgets = widgets;
    self.widgets_widget = widgets.widget();
    if (tui.config().top_bar.len > 0)
        self.top_bar = (try widgets.addP(try @import("status/bar.zig").create(allocator, self.plane, tui.config().top_bar, .none, null))).*;

    const views = try WidgetList.createH(allocator, self.plane, @typeName(Self), .dynamic);
    self.views = views;
    self.views_widget = views.widget();
    try views.add(try Widget.empty(allocator, self.views_widget.plane.*, .dynamic));

    const panes = try WidgetList.createH(allocator, self.plane, @typeName(Self), .dynamic);
    self.panes = panes;
    self.panes_widget = panes.widget();
    try self.update_panes_layout();

    try widgets.add(self.panes_widget);

    if (tui.config().bottom_bar.len > 0) {
        self.bottom_bar = (try widgets.addP(try @import("status/bar.zig").create(allocator, self.plane, tui.config().bottom_bar, .grip, EventHandler.bind(self, handle_bottom_bar_event)))).*;
    }
    if (tp.env.get().is("show-input")) {
        self.toggle_inputview_async();
        self.toggle_keybindview_async();
    }
    if (tp.env.get().is("show-log"))
        self.toggle_logview_async();
    return w;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.close_all_panel_views();
    self.commands.deinit();
    self.widgets.deinit(allocator);
    self.symbols.deinit(allocator);
    self.floating_views.deinit();
    self.buffer_manager.deinit();
    allocator.destroy(self);
}

// Receives the file_path to identify symbols to clear
pub fn clear_symbols(self: *Self, _: []const u8) void {
    self.symbols.clearRetainingCapacity();
}

pub fn receive(self: *Self, from_: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var path: []const u8 = undefined;
    var begin_line: usize = undefined;
    var begin_pos: usize = undefined;
    var end_line: usize = undefined;
    var end_pos: usize = undefined;
    var lines: []const u8 = undefined;
    var goto_args: []const u8 = undefined;
    var line: i64 = undefined;
    var column: i64 = undefined;

    if (try m.match(.{ "REF", tp.extract(&path), tp.extract(&begin_line), tp.extract(&begin_pos), tp.extract(&end_line), tp.extract(&end_pos), tp.extract(&lines) })) {
        try self.add_find_in_files_result(.references, path, begin_line, begin_pos, end_line, end_pos, lines, .Information);
        return true;
    } else if (try m.match(.{ "FIF", tp.extract(&path), tp.extract(&begin_line), tp.extract(&begin_pos), tp.extract(&end_line), tp.extract(&end_pos), tp.extract(&lines) })) {
        try self.add_find_in_files_result(.find_in_files, path, begin_line, begin_pos, end_line, end_pos, lines, .Information);
        return true;
    } else if (try m.match(.{ "REF", "done" })) {
        self.find_in_files_state = .done;
        return true;
    } else if (try m.match(.{ "FIF", "done" })) {
        switch (self.find_in_files_state) {
            .init => self.clear_find_in_files_results(self.file_list_type),
            else => {},
        }
        self.find_in_files_state = .done;
        return true;
    } else if (try m.match(.{ "HREF", tp.extract(&path), tp.extract(&begin_line), tp.extract(&begin_pos), tp.extract(&end_line), tp.extract(&end_pos), tp.extract(&lines) })) {
        if (self.get_active_editor()) |editor| editor.add_highlight_reference(.{
            .begin = .{ .row = begin_line, .col = begin_pos },
            .end = .{ .row = end_line, .col = end_pos },
        });
        return true;
    } else if (try m.match(.{ "HREF", "done" })) {
        if (self.get_active_editor()) |editor| editor.done_highlight_reference();
        return true;
    } else if (try m.match(.{ "hover", tp.extract(&path), tp.string, tp.extract(&lines), tp.extract(&begin_line), tp.extract(&begin_pos), tp.extract(&end_line), tp.extract(&end_pos) })) {
        try self.set_info_content(lines, .replace);
        if (self.get_active_editor()) |editor|
            editor.add_hover_highlight(.{
                .begin = .{ .row = begin_line, .col = begin_pos },
                .end = .{ .row = end_line, .col = end_pos },
            });
        return true;
    } else if (try m.match(.{ "navigate_complete", tp.extract(&path), tp.extract(&goto_args), tp.extract(&line), tp.extract(&column) })) {
        cmds.navigate_complete(self, null, path, goto_args, line, column, null) catch |e| return tp.exit_error(e, @errorReturnTrace());
        return true;
    } else if (try m.match(.{ "navigate_complete", tp.extract(&path), tp.extract(&goto_args), tp.null_, tp.null_ })) {
        cmds.navigate_complete(self, null, path, goto_args, null, null, null) catch |e| return tp.exit_error(e, @errorReturnTrace());
        return true;
    }
    return if (try self.floating_views.send(from_, m)) true else self.widgets.send(from_, m);
}

pub fn update(self: *Self) void {
    self.widgets.update();
    self.floating_views.update();
}

pub fn is_view_centered(self: *const Self) bool {
    const conf = tui.config();
    const centered_view_width = conf.centered_view_width;
    const screen_width = tui.screen().w;
    const need_padding = screen_width > centered_view_width;
    const have_vsplits = self.views.widgets.items.len > 1;
    const have_min_screen_width = screen_width > conf.centered_view_min_screen_width;
    const centered_view = need_padding and conf.centered_view and !have_vsplits and have_min_screen_width;
    return centered_view;
}

pub fn update_panes_layout(self: *Self) !void {
    while (self.panes.pop()) |widget| if (widget.dynamic_cast(WidgetList) == null)
        widget.deinit(self.allocator);
    if (self.is_view_centered()) {
        const conf = tui.config();
        const centered_view_width = conf.centered_view_width;
        const screen_width = tui.screen().w;
        const padding = (screen_width - centered_view_width) / 2;
        try self.panes.add(try self.create_padding_pane(padding, .pane_left));
        try self.panes.add(self.views_widget);
        try self.panes.add(try self.create_padding_pane(padding, .pane_right));
    } else {
        try self.panes.add(self.views_widget);
    }
}

fn create_padding_pane(self: *Self, padding: usize, widget_type: Widget.Type) !Widget {
    const pane = try WidgetList.createHStyled(
        self.allocator,
        self.panes_widget.plane.*,
        @typeName(Self),
        .{ .static = padding },
        widget_type,
    );
    try pane.add(try Widget.empty(self.allocator, self.views_widget.plane.*, .dynamic));
    return pane.widget();
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    const widgets_more = self.widgets.render(theme);
    const views_more = self.floating_views.render(theme);
    return widgets_more or views_more;
}

pub fn handle_resize(self: *Self, pos: Box) void {
    self.update_panes_layout() catch {};
    self.plane = tui.plane();
    if (self.panel_height) |h| if (h >= self.box().h) {
        self.panel_height = null;
    };
    self.widgets.handle_resize(pos);
    self.floating_views.resize(pos);
}

pub fn box(self: *const Self) Box {
    return Box.from(self.plane);
}

fn handle_bottom_bar_event(self: *Self, _: tp.pid_ref, m: tp.message) tp.result {
    var y: usize = undefined;
    if (try m.match(.{ "D", input.event.press, @intFromEnum(input.mouse.BUTTON1), tp.any, tp.any, tp.extract(&y), tp.any, tp.any }))
        return self.bottom_bar_primary_drag(y);
}

fn bottom_bar_primary_drag(self: *Self, y: usize) tp.result {
    const panels = self.panels orelse blk: {
        cmds.toggle_panel(self, .{}) catch return;
        break :blk self.panels.?;
    };
    const h = self.plane.dim_y();
    self.panel_height = @max(1, h - @min(h, y + 1));
    panels.layout_ = .{ .static = self.panel_height.? };
    if (self.panel_height == 1) {
        self.panel_height = null;
        command.executeName("toggle_panel", .{}) catch {};
    }
}

fn toggle_panel_view(self: *Self, view: anytype, mode: enum { toggle, enable, disable }) !void {
    if (self.panels) |panels| {
        if (self.get_panel(@typeName(view))) |w| {
            if (mode != .enable) {
                panels.remove(w.*);
                if (panels.empty()) {
                    self.widgets.remove(panels.widget());
                    self.panels = null;
                }
            }
        } else {
            if (mode != .disable)
                try panels.add(try view.create(self.allocator, self.widgets.plane));
        }
    } else if (mode != .disable) {
        const panels = try WidgetList.createH(self.allocator, self.widgets.plane, "panel", .{ .static = self.panel_height orelse self.box().h / 5 });
        try self.widgets.add(panels.widget());
        try panels.add(try view.create(self.allocator, self.widgets.plane));
        self.panels = panels;
    }
    tui.resize();
}

fn get_panel(self: *Self, name_: []const u8) ?*Widget {
    if (self.panels) |panels|
        for (panels.widgets.items) |*w|
            if (w.widget.get(name_)) |_|
                return &w.widget;
    return null;
}

fn get_panel_view(self: *Self, comptime view: type) ?*view {
    return if (self.panels) |panels| if (panels.get(@typeName(view))) |w| w.dynamic_cast(view) else null else null;
}

fn is_panel_view_showing(self: *Self, comptime view: type) bool {
    return self.get_panel_view(view) != null;
}

fn close_all_panel_views(self: *Self) void {
    if (self.panels) |panels| {
        self.widgets.remove(panels.widget());
        self.panels = null;
    }
    tui.resize();
}

fn check_all_not_dirty(self: *const Self) command.Result {
    if (self.buffer_manager.is_dirty())
        return tp.exit("unsaved changes");
}

fn open_style_config(self: *Self, Style: type) command.Result {
    const file_name = try root.get_config_file_name(Style);
    const style, const style_bufs: [][]const u8 = if (root.exists_config(Style)) blk: {
        const style, const style_bufs = root.read_config(Style, self.allocator);
        break :blk .{ style, style_bufs };
    } else .{ Style{}, &.{} };
    defer root.free_config(self.allocator, style_bufs);
    var conf: std.Io.Writer.Allocating = .init(self.allocator);
    defer conf.deinit();
    root.write_config_to_writer(Style, style, &conf.writer) catch {};
    tui.reset_drag_context();
    try self.create_editor();
    try command.executeName("open_scratch_buffer", command.fmt(.{
        file_name[0 .. file_name.len - ".json".len],
        conf.written(),
        "conf",
    }));
    if (self.get_active_buffer()) |buffer| buffer.mark_not_ephemeral();
    self.location_update_from_editor();
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn quit(self: *Self, _: Ctx) Result {
        const logger = log.logger("buffer");
        defer logger.deinit();
        self.check_all_not_dirty() catch |err| {
            const count_dirty_buffers = self.buffer_manager.count_dirty_buffers();
            logger.print("{} unsaved buffer(s), use 'quit without saving' to exit", .{count_dirty_buffers});
            return err;
        };
        try tp.self_pid().send("quit");
    }
    pub const quit_meta: Meta = .{ .description = "Quit" };

    pub fn quit_without_saving(_: *Self, _: Ctx) Result {
        try tp.self_pid().send("quit");
    }
    pub const quit_without_saving_meta: Meta = .{ .description = "Quit without saving" };

    pub fn save_session(self: *Self, _: Ctx) Result {
        const logger = log.logger("session");
        defer logger.deinit();
        logger.print("saving session...", .{});
        try self.write_restore_info();
        logger.print("session saved", .{});
    }
    pub const save_session_meta: Meta = .{ .description = "Save session" };

    pub fn save_session_quiet(self: *Self, _: Ctx) Result {
        try self.write_restore_info();
    }
    pub const save_session_quiet_meta: Meta = .{};

    pub fn save_session_and_quit(self: *Self, _: Ctx) Result {
        try self.write_restore_info();
        try tp.self_pid().send("quit");
    }
    pub const save_session_and_quit_meta: Meta = .{ .description = "Save session and quit" };

    pub fn open_project_cwd(self: *Self, _: Ctx) Result {
        if (try project_manager.open(".")) |state|
            try self.restore_state(state);
        if (self.top_bar) |bar| _ = try bar.msg(.{ "PRJ", "open" });
        if (self.bottom_bar) |bar| _ = try bar.msg(.{ "PRJ", "open" });
    }
    pub const open_project_cwd_meta: Meta = .{};

    pub fn open_project_dir(self: *Self, ctx: Ctx) Result {
        var project_dir: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&project_dir)}))
            return;
        if (try project_manager.open(project_dir)) |state|
            try self.restore_state(state);
        const project = tp.env.get().str("project");
        tui.rdr().set_terminal_working_directory(project);
        if (self.top_bar) |bar| _ = try bar.msg(.{ "PRJ", "open" });
        if (self.bottom_bar) |bar| _ = try bar.msg(.{ "PRJ", "open" });
    }
    pub const open_project_dir_meta: Meta = .{ .arguments = &.{.string} };

    pub fn close_project(_: *Self, ctx: Ctx) Result {
        var project_dir: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&project_dir)}))
            return;
        project_manager.close(project_dir) catch |e| switch (e) {
            error.CloseCurrentProject => {
                const logger = log.logger("project");
                defer logger.deinit();
                logger.print_err("project", "cannot close current project", .{});
            },
            else => return e,
        };
    }
    pub const close_project_meta: Meta = .{ .arguments = &.{.string} };

    pub fn change_project(self: *Self, ctx: Ctx) Result {
        const logger = log.logger("change_project");
        defer logger.deinit();
        var project_dir: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&project_dir)}))
            return;
        try self.check_all_not_dirty();

        {
            var state_writer: std.Io.Writer.Allocating = .init(self.allocator);
            defer state_writer.deinit();
            try self.write_state(&state_writer.writer);
            try state_writer.writer.flush();
            const old_project = tp.env.get().str("project");
            var state_al = state_writer.toArrayList();
            const state = state_al.toManaged(self.allocator);
            try project_manager.store_state(old_project, state);
            logger.print("stored project state for: {s} ({d} bytes)", .{ old_project, state.items.len });
        }

        const project_state = try project_manager.open(project_dir);

        {
            self.closing_project = true;
            defer self.closing_project = false;
            try self.close_all_editors();
            self.delete_all_buffers();
            self.clear_find_in_files_results(.diagnostics);
            if (self.file_list_type == .diagnostics)
                try self.toggle_panel_view(filelist_view, .disable);
            self.buffer_manager.deinit();
            self.buffer_manager = Buffer.Manager.init(self.allocator);
        }

        const project = tp.env.get().str("project");
        tui.rdr().set_terminal_working_directory(project);
        if (project_state) |state| {
            logger.print("restoring {d} bytes of project state for: {s}", .{ state.len, project });
            try self.restore_state(state);
        } else {
            logger.print("no project state to restore for: {s}", .{project});
        }

        if (self.top_bar) |bar| _ = try bar.msg(.{ "PRJ", "open" });
        if (self.bottom_bar) |bar| _ = try bar.msg(.{ "PRJ", "open" });
    }
    pub const change_project_meta: Meta = .{ .arguments = &.{.string} };

    pub fn navigate_split_vertical(self: *Self, ctx: Ctx) Result {
        try command.executeName("add_split", .{});
        try navigate(self, ctx);
    }
    pub const navigate_split_vertical_meta: Meta = .{ .arguments = &.{.object} };

    pub fn navigate(self: *Self, ctx: Ctx) Result {
        tui.reset_drag_context();
        const frame = tracy.initZone(@src(), .{ .name = "navigate" });
        defer frame.deinit();
        var file: ?[]const u8 = null;
        var file_name: []const u8 = undefined;
        var line: ?i64 = null;
        var column: ?i64 = null;
        var offset: ?i64 = null;
        var goto_args: []const u8 = &.{};

        var iter = ctx.args.buf;
        if (cbor.decodeMapHeader(&iter)) |len_| {
            var len = len_;
            while (len > 0) : (len -= 1) {
                var field_name: []const u8 = undefined;
                if (!try cbor.matchString(&iter, &field_name))
                    return error.InvalidNavigateArgumentFieldName;
                if (std.mem.eql(u8, field_name, "line")) {
                    if (!try cbor.matchValue(&iter, cbor.extract(&line)))
                        return error.InvalidNavigateLineArgument;
                } else if (std.mem.eql(u8, field_name, "column")) {
                    if (!try cbor.matchValue(&iter, cbor.extract(&column)))
                        return error.InvalidNavigateColumnArgument;
                } else if (std.mem.eql(u8, field_name, "file")) {
                    if (!try cbor.matchValue(&iter, cbor.extract(&file)))
                        return error.InvalidNavigateFileArgument;
                } else if (std.mem.eql(u8, field_name, "goto")) {
                    if (!try cbor.matchValue(&iter, cbor.extract_cbor(&goto_args)))
                        return error.InvalidNavigateGotoArgument;
                } else if (std.mem.eql(u8, field_name, "offset")) {
                    if (!try cbor.matchValue(&iter, cbor.extract(&offset)))
                        return error.InvalidNavigateOffsetArgument;
                } else {
                    try cbor.skipValue(&iter);
                }
            }
        } else |_| if (ctx.args.match(tp.extract(&file_name)) catch false) {
            file = file_name;
        } else return error.InvalidNavigateArgument;

        if (tp.env.get().str("project").len == 0) {
            try open_project_cwd(self, .{});
        }

        const f_ = project_manager.normalize_file_path(file orelse return);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const f = project_manager.expand_home(self.allocator, &buf, f_);
        const view = self.get_view_for_file(f);
        const have_editor_metadata = if (self.buffer_manager.get_buffer_for_file(f)) |_| true else false;

        if (tui.config().restore_last_cursor_position and
            view == null and
            !have_editor_metadata and
            line == null and
            offset == null)
        {
            const ctx_: struct {
                allocator: std.mem.Allocator,
                from: tp.pid,
                path: []const u8,
                goto_args: []const u8,

                pub fn deinit(ctx_: *@This()) void {
                    ctx_.from.deinit();
                    ctx_.allocator.free(ctx_.path);
                    ctx_.allocator.free(ctx_.goto_args);
                }
                pub fn receive(ctx_: @This(), rsp: tp.message) !void {
                    var line_: ?i64 = null;
                    var column_: ?i64 = null;
                    _ = try cbor.match(rsp.buf, .{ tp.extract(&line_), tp.extract(&column_) });
                    try ctx_.from.send(.{ "navigate_complete", ctx_.path, ctx_.goto_args, line_, column_ });
                }
            } = .{
                .allocator = self.allocator,
                .from = tp.self_pid().clone(),
                .path = try self.allocator.dupe(u8, f),
                .goto_args = try self.allocator.dupe(u8, goto_args),
            };

            try project_manager.get_mru_position(self.allocator, f, ctx_);
            return;
        }

        return cmds.navigate_complete(self, view, f, goto_args, line, column, offset);
    }
    pub const navigate_meta: Meta = .{ .arguments = &.{.object} };

    fn navigate_complete(self: *Self, view: ?usize, f: []const u8, goto_args: []const u8, line: ?i64, column: ?i64, offset: ?i64) Result {
        if (view) |n| try self.focus_view(n);

        if (view == null) {
            if (self.get_active_editor()) |editor| {
                editor.send_editor_jump_source() catch {};
            }
            try self.create_editor();
            try command.executeName("open_buffer_from_file", command.fmt(.{f}));
        }
        if (goto_args.len != 0) {
            try command.executeName("goto_line_and_column", .{ .args = .{ .buf = goto_args } });
        } else if (line) |l| {
            try command.executeName("goto_line", command.fmt(.{l}));
            if (view == null)
                try command.executeName("scroll_view_center", .{});
            if (column) |col|
                try command.executeName("goto_column", command.fmt(.{col}));
        } else if (offset) |o| {
            try command.executeName("goto_byte_offset", command.fmt(.{o}));
            if (view == null)
                try command.executeName("scroll_view_center", .{});
        }
        tui.need_render();
        self.location_update_from_editor();
    }

    pub fn open_help(self: *Self, _: Ctx) Result {
        tui.reset_drag_context();
        try self.create_editor();
        try command.executeName("open_scratch_buffer", command.fmt(.{ "help", @embedFile("help.md"), "markdown" }));
        tui.need_render();
        self.location_update_from_editor();
    }
    pub const open_help_meta: Meta = .{ .description = "Open help" };

    pub fn open_font_test_text(self: *Self, _: Ctx) Result {
        tui.reset_drag_context();
        try self.create_editor();
        try command.executeName("open_scratch_buffer", command.fmt(.{ "font test", @import("fonts.zig").font_test_text, "text" }));
        tui.need_render();
        self.location_update_from_editor();
    }
    pub const open_font_test_text_meta: Meta = .{ .description = "Open font glyph test text" };

    pub fn open_version_info(self: *Self, _: Ctx) Result {
        tui.reset_drag_context();
        try self.create_editor();
        try command.executeName("open_scratch_buffer", command.fmt(.{ "version", root.version_info, "gitcommit" }));
        tui.need_render();
        self.location_update_from_editor();
    }
    pub const open_version_info_meta: Meta = .{ .description = "Version" };

    pub fn open_config(_: *Self, _: Ctx) Result {
        const file_name = try root.get_config_file_name(@import("config"));
        try tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_name[0 .. file_name.len - 5] } });
    }
    pub const open_config_meta: Meta = .{ .description = "Edit configuration" };

    pub fn open_gui_config(_: *Self, _: Ctx) Result {
        const file_name = try root.get_config_file_name(@import("gui_config"));
        try tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_name[0 .. file_name.len - ".json".len] } });
    }
    pub const open_gui_config_meta: Meta = .{ .description = "Edit gui configuration" };

    pub fn open_tabs_style_config(self: *Self, _: Ctx) Result {
        try self.open_style_config(@import("status/tabs.zig").Style);
    }
    pub const open_tabs_style_config_meta: Meta = .{ .description = "Edit tab style" };

    pub fn open_home_style_config(self: *Self, _: Ctx) Result {
        try self.open_style_config(@import("home.zig").Style);
    }
    pub const open_home_style_config_meta: Meta = .{ .description = "Edit home screen" };

    pub fn change_file_type(_: *Self, _: Ctx) Result {
        return tui.open_overlay(
            @import("mode/overlay/file_type_palette.zig").Variant("set_file_type", "Select file type", false).Type,
        );
    }
    pub const change_file_type_meta: Meta = .{ .description = "Change file type" };

    pub fn open_file_type_config(self: *Self, ctx: Ctx) Result {
        var file_type_name: []const u8 = undefined;
        if (!(ctx.args.match(.{tp.extract(&file_type_name)}) catch false))
            return tui.open_overlay(
                @import("mode/overlay/file_type_palette.zig").Variant("open_file_type_config", "Edit file type", true).Type,
            );

        const file_name = try file_type_config.get_config_file_path(self.allocator, file_type_name);
        defer self.allocator.free(file_name);

        const file: ?std.fs.File = std.fs.openFileAbsolute(file_name, .{ .mode = .read_only }) catch null;
        if (file) |f| {
            f.close();
            return tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_name } });
        }

        const content = try file_type_config.get_default(self.allocator, file_type_name);
        defer self.allocator.free(content);

        tui.reset_drag_context();
        try self.create_editor();
        try command.executeName("open_scratch_buffer", command.fmt(.{
            file_name,
            content,
            "conf",
        }));
        if (self.get_active_buffer()) |buffer| buffer.mark_not_ephemeral();
        self.location_update_from_editor();
    }
    pub const open_file_type_config_meta: Meta = .{
        .arguments = &.{.string},
        .description = "Edit file type configuration",
    };

    pub fn open_lsp_config_global(self: *Self, _: Ctx) Result {
        const editor = self.get_active_editor() orelse return no_lsp_error();
        const file_type = editor.file_type orelse return no_lsp_error();
        const language_server = file_type.language_server orelse return no_lsp_error();
        const lsp_name = language_server[0];
        const file_name = try lsp_config.get_config_file_path(null, lsp_name, .global, .mk_parents);
        try tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_name } });
    }
    pub const open_lsp_config_global_meta: Meta = .{ .description = "Edit LSP configuration (global)" };

    pub fn open_lsp_config_project(self: *Self, _: Ctx) Result {
        const editor = self.get_active_editor() orelse return no_lsp_error();
        const file_type = editor.file_type orelse return no_lsp_error();
        const language_server = file_type.language_server orelse return no_lsp_error();
        const lsp_name = language_server[0];
        const project = tp.env.get().str("project");
        const file_name = try lsp_config.get_config_file_path(project, lsp_name, .project, .mk_parents);
        try tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_name } });
    }
    pub const open_lsp_config_project_meta: Meta = .{ .description = "Edit LSP configuration (project)" };

    pub fn create_scratch_buffer(self: *Self, ctx: Ctx) Result {
        const args = try ctx.args.clone(self.allocator);
        defer self.allocator.free(args.buf);
        tui.reset_drag_context();
        try self.create_editor();
        try command.executeName("open_scratch_buffer", .{ .args = args });
        tui.need_render();
        self.location_update_from_editor();
    }
    pub const create_scratch_buffer_meta: Meta = .{ .arguments = &.{ .string, .string, .string } };

    pub fn create_new_file(self: *Self, _: Ctx) Result {
        var n: usize = 1;
        var found_unique = false;
        var name: std.ArrayList(u8) = .empty;
        defer name.deinit(self.allocator);
        while (!found_unique) {
            name.clearRetainingCapacity();
            try name.writer(self.allocator).print("Untitled-{d}", .{n});
            if (self.buffer_manager.get_buffer_for_file(name.items)) |_| {
                n += 1;
            } else {
                found_unique = true;
            }
        }
        try command.executeName("create_scratch_buffer", command.fmt(.{name.items}));
        if (tp.env.get().str("language").len == 0)
            try command.executeName("change_file_type", .{});
    }
    pub const create_new_file_meta: Meta = .{ .description = "New file" };

    pub fn save_buffer(self: *Self, ctx: Ctx) Result {
        var file_path: []const u8 = undefined;
        if (!(ctx.args.match(.{tp.extract(&file_path)}) catch false))
            return error.InvalidSaveBufferArgument;

        const buffer = self.buffer_manager.get_buffer_for_file(file_path) orelse return;

        if (self.get_active_editor()) |editor| blk: {
            const editor_buffer = editor.buffer orelse break :blk;
            if (buffer == editor_buffer) {
                try editor.save_file(.{});
                return;
            }
        }

        const logger = log.logger("buffer");
        defer logger.deinit();
        if (buffer.is_ephemeral()) return logger.print_err("save", "ephemeral buffer, use save as", .{});
        if (!buffer.is_dirty()) return logger.print("no changes to save", .{});
        try buffer.store_to_file_and_clean(file_path);
    }
    pub const save_buffer_meta: Meta = .{ .arguments = &.{.string} };

    pub fn save_file_as(self: *Self, ctx: Ctx) Result {
        var file_path: []const u8 = undefined;
        if (!(ctx.args.match(.{tp.extract(&file_path)}) catch false))
            return error.InvalidSaveFileAsArgument;

        if (self.get_active_editor()) |editor| {
            const buffer = editor.buffer orelse return;
            var content: std.Io.Writer.Allocating = .init(self.allocator);
            defer content.deinit();
            try buffer.root.store(&content.writer, buffer.file_eol_mode);

            var existing = false;
            if (self.buffer_manager.get_buffer_for_file(file_path)) |new_buffer| {
                if (new_buffer.is_dirty())
                    return tp.exit("save as would overwrite unsaved changes");
                if (buffer == new_buffer)
                    return tp.exit("same file");
                existing = true;
            }
            try self.create_editor();
            try command.executeName("open_scratch_buffer", command.fmt(.{
                file_path,
                "",
                buffer.file_type_name,
            }));
            if (self.get_active_editor()) |new_editor| {
                const new_buffer = new_editor.buffer orelse return;
                if (existing) new_editor.update_buf(new_buffer.root) catch {}; // store an undo point
                try new_buffer.reset_from_string_and_update(content.written());
                new_buffer.mark_not_ephemeral();
                new_buffer.mark_dirty();
                new_editor.clamp();
                new_editor.update_buf(new_buffer.root) catch {};
                tui.need_render();
            }
            try command.executeName("save_file", .{});
            try command.executeName("place_next_tab", command.fmt(.{
                if (buffer.is_ephemeral()) "before" else "after",
                self.buffer_manager.buffer_to_ref(buffer),
            }));
            if (buffer.is_ephemeral())
                self.buffer_manager.close_buffer(buffer);
        }
        self.location_update_from_editor();
    }
    pub const save_file_as_meta: Meta = .{ .arguments = &.{.string} };

    pub fn delete_buffer(self: *Self, ctx: Ctx) Result {
        var file_path: []const u8 = undefined;
        if (!(ctx.args.match(.{tp.extract(&file_path)}) catch false)) {
            const editor = self.get_active_editor() orelse return error.InvalidDeleteBufferArgument;
            file_path = editor.file_path orelse return error.InvalidDeleteBufferArgument;
        }
        const buffer = self.buffer_manager.get_buffer_for_file(file_path) orelse return;
        if (buffer.is_dirty())
            return tp.exit("unsaved changes");
        if (self.get_active_editor()) |editor| if (editor.buffer == buffer)
            editor.close_file(.{}) catch |e| return e;
        self.buffer_manager.delete_buffer(buffer);
        const logger = log.logger("buffer");
        defer logger.deinit();
        logger.print("deleted buffer {s}", .{file_path});
        tui.need_render();
    }
    pub const delete_buffer_meta: Meta = .{ .arguments = &.{.string} };

    pub fn close_buffer(self: *Self, ctx: Ctx) Result {
        var file_path: []const u8 = undefined;
        if (!(ctx.args.match(.{tp.extract(&file_path)}) catch false))
            return error.InvalidDeleteBufferArgument;
        const buffer = self.buffer_manager.get_buffer_for_file(file_path) orelse return;
        if (buffer.is_dirty())
            return tp.exit("unsaved changes");
        if (self.get_active_editor()) |editor| if (editor.buffer == buffer) {
            editor.close_file(.{}) catch |e| return e;
            return;
        };
        _ = self.buffer_manager.close_buffer(buffer);
        tui.need_render();
    }
    pub const close_buffer_meta: Meta = .{ .arguments = &.{.string} };

    pub fn restore_session(self: *Self, _: Ctx) Result {
        try self.read_restore_info();
        tui.need_render();
    }
    pub const restore_session_meta: Meta = .{};

    pub fn toggle_panel(self: *Self, _: Ctx) Result {
        if (self.is_panel_view_showing(logview))
            try self.toggle_panel_view(logview, .toggle)
        else if (self.is_panel_view_showing(info_view))
            try self.toggle_panel_view(info_view, .toggle)
        else if (self.is_panel_view_showing(filelist_view))
            try self.toggle_panel_view(filelist_view, .toggle)
        else if (self.is_panel_view_showing(keybind_view))
            try self.toggle_panel_view(keybind_view, .toggle)
        else if (self.is_panel_view_showing(input_view))
            try self.toggle_panel_view(input_view, .toggle)
        else
            try self.toggle_panel_view(logview, .toggle);
    }
    pub const toggle_panel_meta: Meta = .{ .description = "Toggle panel" };

    pub fn toggle_logview(self: *Self, _: Ctx) Result {
        try self.toggle_panel_view(logview, .toggle);
    }
    pub const toggle_logview_meta: Meta = .{};

    pub fn show_logview(self: *Self, _: Ctx) Result {
        try self.toggle_panel_view(logview, .enable);
    }
    pub const show_logview_meta: Meta = .{ .description = "View log" };

    pub fn toggle_inputview(self: *Self, _: Ctx) Result {
        try self.toggle_panel_view(input_view, .toggle);
    }
    pub const toggle_inputview_meta: Meta = .{ .description = "Toggle raw input log" };

    pub fn toggle_keybindview(self: *Self, _: Ctx) Result {
        try self.toggle_panel_view(keybind_view, .toggle);
    }
    pub const toggle_keybindview_meta: Meta = .{ .description = "Toggle keybind log" };

    pub fn toggle_inspector_view(self: *Self, _: Ctx) Result {
        try self.toggle_panel_view(@import("inspector_view.zig"), .toggle);
    }
    pub const toggle_inspector_view_meta: Meta = .{ .description = "Toggle inspector view" };

    pub fn show_inspector_view(self: *Self, _: Ctx) Result {
        try self.toggle_panel_view(@import("inspector_view.zig"), .enable);
    }
    pub const show_inspector_view_meta: Meta = .{};

    pub fn close_find_in_files_results(self: *Self, _: Ctx) Result {
        if (self.file_list_type == .find_in_files)
            try self.toggle_panel_view(filelist_view, .disable);
    }
    pub const close_find_in_files_results_meta: Meta = .{ .description = "Close find in files results view" };

    pub fn jump_back(self: *Self, _: Ctx) Result {
        try self.location_history_.back(location_jump);
    }
    pub const jump_back_meta: Meta = .{ .description = "Navigate back to previous history location" };

    pub fn jump_forward(self: *Self, _: Ctx) Result {
        try self.location_history_.forward(location_jump);
    }
    pub const jump_forward_meta: Meta = .{ .description = "Navigate forward to next history location" };

    pub fn show_home(self: *Self, _: Ctx) Result {
        return self.create_home();
    }
    pub const show_home_meta: Meta = .{};

    pub fn add_split(self: *Self, _: Ctx) Result {
        return self.create_home_split();
    }
    pub const add_split_meta: Meta = .{ .description = "Add split view" };

    pub fn close_split(self: *Self, _: Ctx) Result {
        if (self.views.widgets.items.len == 1 and self.views.widgets.items[0].widget.dynamic_cast(home) != null)
            return command.executeName("quit", .{});
        return self.remove_active_view();
    }
    pub const close_split_meta: Meta = .{ .description = "Close split view" };

    pub fn focus_split(self: *Self, ctx: Ctx) Result {
        var n: usize = undefined;
        if (!try ctx.args.match(.{tp.extract(&n)})) return error.InvalidFocusSplitArgument;
        try self.focus_view(n);
    }
    pub const focus_split_meta: Meta = .{ .description = "Focus split view", .arguments = &.{.integer} };

    pub fn gutter_mode_next(self: *Self, _: Ctx) Result {
        const config = tui.config_mut();
        const mode: ?@import("config").LineNumberMode = if (config.gutter_line_numbers_mode) |mode| switch (mode) {
            .absolute => .relative,
            .relative => .none,
            .none => null,
        } else .relative;

        config.gutter_line_numbers_mode = mode;
        try tui.save_config();
        if (self.widgets.get("editor_gutter")) |gutter_widget| {
            const gutter = gutter_widget.dynamic_cast(@import("editor_gutter.zig")) orelse return;
            gutter.mode = mode;
        }
    }
    pub const gutter_mode_next_meta: Meta = .{ .description = "Next gutter mode" };

    pub fn gutter_style_next(self: *Self, _: Ctx) Result {
        const config = tui.config_mut();
        config.gutter_line_numbers_style = switch (config.gutter_line_numbers_style) {
            .ascii => .digital,
            .digital => .subscript,
            .subscript => .superscript,
            .superscript => .ascii,
        };
        try tui.save_config();
        if (self.widgets.get("editor_gutter")) |gutter_widget| {
            const gutter = gutter_widget.dynamic_cast(@import("editor_gutter.zig")) orelse return;
            gutter.render_style = config.gutter_line_numbers_style;
        }
    }
    pub const gutter_style_next_meta: Meta = .{ .description = "Next line number style" };

    pub fn toggle_inline_diagnostics(_: *Self, _: Ctx) Result {
        const config = tui.config_mut();
        config.inline_diagnostics = !config.inline_diagnostics;
        try tui.save_config();
    }
    pub const toggle_inline_diagnostics_meta: Meta = .{ .description = "Toggle display of diagnostics inline" };

    pub fn goto_next_file_or_diagnostic(self: *Self, ctx: Ctx) Result {
        if (self.is_panel_view_showing(filelist_view)) {
            switch (self.file_list_type) {
                .diagnostics => try command.executeName("goto_next_diagnostic", ctx),
                else => try command.executeName("goto_next_file", ctx),
            }
        } else {
            try command.executeName("goto_next_diagnostic", ctx);
        }
    }
    pub const goto_next_file_or_diagnostic_meta: Meta = .{ .description = "Navigate to next file or diagnostic location" };

    pub fn goto_prev_file_or_diagnostic(self: *Self, ctx: Ctx) Result {
        if (self.is_panel_view_showing(filelist_view)) {
            switch (self.file_list_type) {
                .diagnostics => try command.executeName("goto_prev_diagnostic", ctx),
                else => try command.executeName("goto_prev_file", ctx),
            }
        } else {
            try command.executeName("goto_prev_diagnostic", ctx);
        }
    }
    pub const goto_prev_file_or_diagnostic_meta: Meta = .{ .description = "Navigate to previous file or diagnostic location" };

    pub fn add_diagnostic(self: *Self, ctx: Ctx) Result {
        var file_path: []const u8 = undefined;
        var source: []const u8 = undefined;
        var code: []const u8 = undefined;
        var message: []const u8 = undefined;
        var severity: i32 = 0;
        var sel: ed.Selection = .{};
        if (!try ctx.args.match(.{
            tp.extract(&file_path),
            tp.extract(&source),
            tp.extract(&code),
            tp.extract(&message),
            tp.extract(&severity),
            tp.extract(&sel.begin.row),
            tp.extract(&sel.begin.col),
            tp.extract(&sel.end.row),
            tp.extract(&sel.end.col),
        })) return error.InvalidAddDiagnosticArgument;
        file_path = project_manager.normalize_file_path(file_path);
        if (self.get_active_editor()) |editor| if (std.mem.eql(u8, file_path, editor.file_path orelse "")) {
            try editor.add_diagnostic(file_path, source, code, message, severity, sel);
            if (!tui.config().show_local_diagnostics_in_panel)
                return;
        };
        try self.add_find_in_files_result(
            .diagnostics,
            file_path,
            sel.begin.row + 1,
            sel.begin.col,
            sel.end.row + 1,
            sel.end.col,
            message,
            ed.Diagnostic.to_severity(severity),
        );
    }
    pub const add_diagnostic_meta: Meta = .{ .arguments = &.{ .string, .string, .string, .string, .integer, .integer, .integer, .integer, .integer } };

    pub fn add_completion(self: *Self, ctx: Ctx) Result {
        var file_path: []const u8 = undefined;
        var row: usize = undefined;
        var col: usize = undefined;
        var is_incomplete: bool = undefined;

        if (!try ctx.args.match(.{
            tp.extract(&file_path),
            tp.extract(&row),
            tp.extract(&col),
            tp.extract(&is_incomplete),
            tp.more,
        })) return error.InvalidAddDiagnosticArgument;
        file_path = project_manager.normalize_file_path(file_path);
        if (self.get_active_editor()) |editor| if (std.mem.eql(u8, file_path, editor.file_path orelse ""))
            try editor.add_completion(row, col, is_incomplete, ctx.args);
    }
    pub const add_completion_meta: Meta = .{
        .arguments = &.{
            .string, // file_path
            .integer, // row
            .integer, // col
            .boolean, // is_incomplete
            .string, // label
            .string, // label_detail
            .string, // label_description
            .integer, // kind
            .string, // detail
            .string, // documentation
            .string, // documentation_kind
            .string, // sortText
            .integer, // insertTextFormat
            .string, // textEdit_newText
            .integer, // insert.begin.row
            .integer, // insert.begin.col
            .integer, // insert.end.row
            .integer, // insert.end.col
            .integer, // replace.begin.row
            .integer, // replace.begin.col
            .integer, // replace.end.row
            .integer, // replace.end.col
        },
    };

    pub fn add_document_symbol_done(self: *Self, ctx: Ctx) Result {
        var file_path: []const u8 = undefined;

        if (!try ctx.args.match(.{
            tp.extract(&file_path),
        })) return error.InvalidAddDiagnosticArgument;
        file_path = project_manager.normalize_file_path(file_path);
        if (self.get_active_editor()) |editor| if (std.mem.eql(u8, file_path, editor.file_path orelse "")) {
            self.symbols_complete = true;
            try tui.open_overlay(@import("mode/overlay/symbol_palette.zig").Type);
            tui.need_render();
        };
    }
    pub const add_document_symbol_done_meta: Meta = .{
        .arguments = &.{
            .string, // file_path
        },
    };

    pub fn add_document_symbol(self: *Self, ctx: Ctx) Result {
        var file_path: []const u8 = undefined;
        var name: []const u8 = undefined;
        var parent: []const u8 = undefined;
        var kind: u8 = 0;
        if (!try ctx.args.match(.{
            tp.extract(&file_path),
            tp.extract(&name),
            tp.extract(&parent),
            tp.extract(&kind),
            tp.more,
        })) return error.InvalidAddDiagnosticArgument;
        file_path = project_manager.normalize_file_path(file_path);
        if (self.get_active_editor()) |editor| if (std.mem.eql(u8, file_path, editor.file_path orelse "")) {
            self.symbols_complete = false;
            try self.symbols.appendSlice(self.allocator, ctx.args.buf);
        };
    }
    pub const add_document_symbol_meta: Meta = .{
        .arguments = &.{
            .string, // file_path
            .string, // name
            .string, // parent_name
            .integer, // kind
            .integer, // range.begin.row
            .integer, // range.begin.col
            .integer, // range.end.row
            .integer, // range.end.col
            .array, // tags
            .integer, // selectionRange.begin.row
            .integer, // selectionRange.begin.col
            .integer, // selectionRange.end.row
            .integer, // selectionRange.end.col
            .boolean, // deprecated
            .string, //detail
        },
    };

    pub fn add_completion_done(self: *Self, ctx: Ctx) Result {
        var file_path: []const u8 = undefined;
        var row: usize = undefined;
        var col: usize = undefined;

        if (!try ctx.args.match(.{
            tp.extract(&file_path),
            tp.extract(&row),
            tp.extract(&col),
        })) return error.InvalidAddDiagnosticArgument;
        file_path = project_manager.normalize_file_path(file_path);
        if (self.get_active_editor()) |editor| if (std.mem.eql(u8, file_path, editor.file_path orelse "")) {
            switch (tui.config().completion_style) {
                .palette => try tui.open_overlay(@import("mode/overlay/completion_palette.zig").Type),
                .dropdown => try tui.open_overlay(@import("mode/overlay/completion_dropdown.zig").Type),
            }
            tui.need_render();
        };
    }
    pub const add_completion_done_meta: Meta = .{
        .arguments = &.{
            .string, // file_path
            .integer, // row
            .integer, // col
        },
    };

    pub fn rename_symbol_item(self: *Self, ctx: Ctx) Result {
        const editor = self.get_active_editor() orelse return;
        const primary_cursor = editor.get_primary().cursor;
        var iter = ctx.args.buf;
        var len = try cbor.decodeArrayHeader(&iter);
        var first = true;
        while (len != 0) : (len -= 1) {
            if (try cbor.decodeArrayHeader(&iter) != 7) return error.InvalidRenameSymbolItemArgument;
            var file_path: []const u8 = undefined;
            if (!try cbor.matchString(&iter, &file_path)) return error.MissingArgument;
            var sel: ed.Selection = .{};
            if (!try cbor.matchInt(usize, &iter, &sel.begin.row)) return error.MissingArgument;
            if (!try cbor.matchInt(usize, &iter, &sel.begin.col)) return error.MissingArgument;
            if (!try cbor.matchInt(usize, &iter, &sel.end.row)) return error.MissingArgument;
            if (!try cbor.matchInt(usize, &iter, &sel.end.col)) return error.MissingArgument;
            var new_text: []const u8 = undefined;
            if (!try cbor.matchString(&iter, &new_text)) return error.MissingArgument;
            var line_text: []const u8 = undefined;
            if (!try cbor.matchString(&iter, &line_text)) return error.MissingArgument;

            file_path = project_manager.normalize_file_path(file_path);
            if (std.mem.eql(u8, file_path, editor.file_path orelse "")) {
                if (len == 1 and sel.begin.row == 0 and sel.begin.col == 0 and sel.end.row > 0) //probably a full file edit
                    return editor.add_cursors_from_content_diff(new_text);
                try editor.add_cursor_from_selection(sel, if (first) .cancel else .push);
                first = false;
            } else {
                try self.add_find_in_files_result(
                    .references,
                    file_path,
                    sel.begin.row + 1,
                    sel.begin.col,
                    sel.end.row + 1,
                    sel.end.col,
                    line_text,
                    .Information,
                );
            }
        }
        try editor.set_primary_selection_from_cursor(primary_cursor);
    }
    pub const rename_symbol_item_meta: Meta = .{ .arguments = &.{.array} };
    pub const rename_symbol_item_elem_meta: Meta = .{ .arguments = &.{ .string, .integer, .integer, .integer, .integer, .string } };

    pub fn clear_diagnostics(self: *Self, ctx: Ctx) Result {
        var file_path: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&file_path)})) return error.InvalidClearDiagnosticsArgument;
        file_path = project_manager.normalize_file_path(file_path);
        if (self.get_active_editor()) |editor| if (std.mem.eql(u8, file_path, editor.file_path orelse ""))
            editor.clear_diagnostics();

        self.clear_find_in_files_results(.diagnostics);
        if (self.file_list_type == .diagnostics)
            try self.toggle_panel_view(filelist_view, .disable);
    }
    pub const clear_diagnostics_meta: Meta = .{ .arguments = &.{.string} };

    pub fn show_diagnostics(self: *Self, _: Ctx) Result {
        const editor = self.get_active_editor() orelse return;
        self.clear_find_in_files_results(.diagnostics);
        for (editor.diagnostics.items) |diagnostic| {
            try self.add_find_in_files_result(
                .diagnostics,
                editor.file_path orelse "",
                diagnostic.sel.begin.row + 1,
                diagnostic.sel.begin.col,
                diagnostic.sel.end.row + 1,
                diagnostic.sel.end.col,
                diagnostic.message,
                ed.Diagnostic.to_severity(diagnostic.severity),
            );
        }
    }
    pub const show_diagnostics_meta: Meta = .{ .description = "Show diagnostics panel" };

    pub fn open_previous_file(self: *Self, _: Ctx) Result {
        self.show_file_async(self.get_next_mru_buffer(.all) orelse return error.Stop);
    }
    pub const open_previous_file_meta: Meta = .{ .description = "Open the previous file" };

    pub fn open_most_recent_file(self: *Self, _: Ctx) Result {
        if (try project_manager.request_most_recent_file(self.allocator)) |file_path|
            self.show_file_async(file_path);
    }
    pub const open_most_recent_file_meta: Meta = .{ .description = "Open the last changed file" };

    pub fn restore_closed_tab(self: *Self, _: Ctx) Result {
        self.show_file_async(self.get_next_mru_buffer(.hidden) orelse return error.Stop);
    }
    pub const restore_closed_tab_meta: Meta = .{ .description = "Restore last closed tab" };

    pub fn system_paste(self: *Self, _: Ctx) Result {
        if (builtin.os.tag == .windows) {
            const text = try @import("renderer").request_windows_clipboard(self.allocator);
            defer self.allocator.free(text);
            return command.executeName("paste", command.fmt(.{text})) catch {};
        }
        tui.rdr().request_system_clipboard();
    }
    pub const system_paste_meta: Meta = .{ .description = "Paste from system clipboard" };

    pub fn find_in_files_query(self: *Self, ctx: Ctx) Result {
        var query: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&query)})) return error.InvalidFindInFilesQueryArgument;
        const logger = log.logger("find");
        defer logger.deinit();
        logger.print("finding files...", .{});
        const find_f = ripgrep.find_in_files;
        if (std.mem.indexOfScalar(u8, query, '\n')) |_| return;
        var rg = try find_f(self.allocator, query, "FIF");
        defer rg.deinit();
        self.find_in_files_state = .init;
    }
    pub const find_in_files_query_meta: Meta = .{ .arguments = &.{.string} };

    pub fn shell_execute_log(self: *Self, ctx: Ctx) Result {
        if (!try ctx.args.match(.{ tp.string, tp.more }))
            return error.InvalidShellArgument;
        const cmd = ctx.args;
        try shell.execute(self.allocator, cmd, .{
            .out = shell.log_handler,
            .err = shell.log_err_handler,
            .exit = shell.log_exit_err_handler,
        });
    }
    pub const shell_execute_log_meta: Meta = .{ .arguments = &.{.string} };

    pub fn shell_execute_insert(self: *Self, ctx: Ctx) Result {
        if (!try ctx.args.match(.{ tp.string, tp.more }))
            return error.InvalidShellArgument;
        const cmd = ctx.args;
        const handlers = struct {
            fn out(_: usize, parent: tp.pid_ref, _: []const u8, output: []const u8) void {
                var pos: usize = 0;
                var nl_count: usize = 0;
                while (std.mem.indexOfScalarPos(u8, output, pos, '\n')) |next| {
                    pos = next + 1;
                    nl_count += 1;
                }
                const output_ = if (nl_count == 1 and output[output.len - 1] == '\n')
                    if (output.len > 2 and output[output.len - 2] == '\r')
                        output[0 .. output.len - 2]
                    else
                        output[0 .. output.len - 1]
                else
                    output;
                parent.send(.{ "cmd", "insert_chars", .{output_} }) catch {};
            }
        };
        try shell.execute(self.allocator, cmd, .{ .out = handlers.out });
    }
    pub const shell_execute_insert_meta: Meta = .{ .arguments = &.{.string} };

    pub fn shell_execute_stream(self: *Self, ctx: Ctx) Result {
        if (!try ctx.args.match(.{ tp.string, tp.more }))
            return error.InvalidShellArgument;
        const cmd = ctx.args;
        const handlers = struct {
            fn out(buffer_ref: usize, parent: tp.pid_ref, _: []const u8, output: []const u8) void {
                parent.send(.{ "cmd", "shell_execute_stream_output", .{ buffer_ref, output } }) catch {};
            }
            fn exit(buffer_ref: usize, parent: tp.pid_ref, arg0: []const u8, err_msg: []const u8, exit_code: i64) void {
                var buf: [256]u8 = undefined;
                var stream = std.io.fixedBufferStream(&buf);
                const writer = stream.writer();
                if (exit_code > 0) {
                    writer.print("\n'{s}' terminated {s} exitcode: {d}\n", .{ arg0, err_msg, exit_code }) catch {};
                } else {
                    writer.print("\n'{s}' exited\n", .{arg0}) catch {};
                }
                parent.send(.{ "cmd", "shell_execute_stream_output", .{ buffer_ref, stream.getWritten() } }) catch {};
                parent.send(.{ "cmd", "shell_execute_stream_output_complete", .{buffer_ref} }) catch {};
            }
        };
        const editor = self.get_active_editor() orelse return error.Stop;
        const buffer = editor.buffer orelse return error.Stop;
        const buffer_ref = self.buffer_manager.buffer_to_ref(buffer);
        try shell.execute(self.allocator, cmd, .{ .context = buffer_ref, .out = handlers.out, .err = handlers.out, .exit = handlers.exit });
    }
    pub const shell_execute_stream_meta: Meta = .{ .arguments = &.{.string} };

    pub fn shell_execute_stream_output(self: *Self, ctx: Ctx) Result {
        var buffer_ref: usize = 0;
        var output: []const u8 = undefined;
        if (!try ctx.args.match(.{ tp.extract(&buffer_ref), tp.extract(&output) }))
            return error.InvalidShellOutputArgument;
        const buffer = self.buffer_manager.buffer_from_ref(buffer_ref) orelse return;
        if (self.get_editor_for_buffer(buffer)) |editor| if (editor.buffer) |eb| if (eb == buffer) {
            editor.smart_buffer_append(command.fmt(.{output})) catch {};
            tui.need_render();
            return;
        };
        var cursor: Buffer.Cursor = .{};
        const metrics = self.plane.metrics(1);
        cursor.move_buffer_end(buffer.root, metrics);
        var root_ = buffer.root;
        _, _, root_ = try root_.insert_chars(cursor.row, cursor.col, output, self.allocator, metrics);
        buffer.store_undo(&[_]u8{}) catch {};
        buffer.update(root_);
        tui.need_render();
    }
    pub const shell_execute_stream_output_meta: Meta = .{ .arguments = &.{ .integer, .string } };

    pub fn shell_execute_stream_output_complete(self: *Self, ctx: Ctx) Result {
        var buffer_ref: usize = 0;
        if (!try ctx.args.match(.{tp.extract(&buffer_ref)}))
            return error.InvalidShellOutputCompleteArgument;
        const buffer = self.buffer_manager.buffer_from_ref(buffer_ref) orelse return;
        if (self.get_active_editor()) |editor| if (editor.buffer) |eb| if (eb == buffer) {
            editor.forced_mark_clean(.{}) catch {};
            return;
        };
        buffer.mark_clean();
        tui.need_render();
    }
    pub const shell_execute_stream_output_complete_meta: Meta = .{ .arguments = &.{ .integer, .string } };

    pub fn adjust_fontsize(_: *Self, ctx: Ctx) Result {
        var amount: f32 = undefined;
        if (!try ctx.args.match(.{tp.extract(&amount)}))
            return error.InvalidArgument;
        if (build_options.gui)
            tui.rdr().adjust_fontsize(amount);
    }
    pub const adjust_fontsize_meta: Meta = .{ .arguments = &.{.float} };

    pub fn set_fontsize(_: *Self, ctx: Ctx) Result {
        var fontsize: f32 = undefined;
        if (!try ctx.args.match(.{tp.extract(&fontsize)}))
            return error.InvalidArgument;
        if (build_options.gui)
            tui.rdr().set_fontsize(fontsize);
    }
    pub const set_fontsize_meta: Meta = .{ .arguments = &.{.float} };

    pub fn reset_fontsize(_: *Self, _: Ctx) Result {
        if (build_options.gui)
            tui.rdr().reset_fontsize();
    }
    pub const reset_fontsize_meta: Meta = .{ .description = "Reset font to configured size" };

    pub fn set_fontface(_: *Self, ctx: Ctx) Result {
        var fontface: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&fontface)}))
            return error.InvalidArgument;
        if (build_options.gui)
            tui.rdr().set_fontface(fontface);
    }
    pub const set_fontface_meta: Meta = .{ .arguments = &.{.float} };

    pub fn reset_fontface(_: *Self, _: Ctx) Result {
        if (build_options.gui)
            tui.rdr().reset_fontface();
    }
    pub const reset_fontface_meta: Meta = .{ .description = "Reset font to configured face" };

    pub fn next_tab(self: *Self, _: Ctx) Result {
        _ = try self.widgets_widget.msg(.{"next_tab"});
    }
    pub const next_tab_meta: Meta = .{ .description = "Switch to next tab" };

    pub fn previous_tab(self: *Self, _: Ctx) Result {
        _ = try self.widgets_widget.msg(.{"previous_tab"});
    }
    pub const previous_tab_meta: Meta = .{ .description = "Switch to previous tab" };

    pub fn move_tab_next(self: *Self, _: Ctx) Result {
        _ = try self.widgets_widget.msg(.{"move_tab_next"});
    }
    pub const move_tab_next_meta: Meta = .{ .description = "Move tab to next position" };

    pub fn move_tab_previous(self: *Self, _: Ctx) Result {
        _ = try self.widgets_widget.msg(.{"move_tab_previous"});
    }
    pub const move_tab_previous_meta: Meta = .{ .description = "Move tab to previous position" };

    pub fn swap_tabs(self: *Self, ctx: Ctx) Result {
        var buffer_ref_a: usize = undefined;
        var buffer_ref_b: usize = undefined;
        if (!try ctx.args.match(.{
            tp.extract(&buffer_ref_a),
            tp.extract(&buffer_ref_b),
        })) return error.InvalidSwapTabsArgument;
        _ = try self.widgets_widget.msg(.{ "swap_tabs", buffer_ref_a, buffer_ref_b });
    }
    pub const swap_tabs_meta: Meta = .{ .arguments = &.{ .integer, .integer } };

    pub fn place_next_tab(self: *Self, ctx: Ctx) Result {
        var pos: enum { before, after } = undefined;
        var buffer_ref: usize = undefined;
        if (try ctx.args.match(.{ tp.extract(&pos), tp.extract(&buffer_ref) })) {
            _ = try self.widgets_widget.msg(.{ "place_next_tab", pos, buffer_ref });
        } else if (try ctx.args.match(.{"atend"})) {
            _ = try self.widgets_widget.msg(.{ "place_next_tab", "atend" });
        } else return error.InvalidSwapTabsArgument;
    }
    pub const place_next_tab_meta: Meta = .{ .arguments = &.{ .string, .integer } };
};

fn no_lsp_error() void {
    const logger = log.logger("editor");
    defer logger.deinit();
    logger.print("no LSP currently in use", .{});
}

pub fn handle_editor_event(self: *Self, _: tp.pid_ref, m: tp.message) tp.result {
    const editor = self.get_active_editor() orelse return;
    var sel: ed.Selection = undefined;

    if (try m.match(.{ "E", "location", tp.more }))
        return self.location_update(m);

    if (try m.match(.{ "E", "close" })) {
        if (!self.closing_project) {
            if (self.get_next_mru_buffer(.non_hidden)) |file_path|
                self.show_file_async(file_path)
            else
                self.show_home_async();
        } else self.show_home_async();
        self.active_editor = null;
        return;
    }

    if (try m.match(.{ "E", "sel", tp.more })) {
        if (try m.match(.{ tp.any, tp.any, "none" }))
            return self.clear_auto_find(editor);
        if (try m.match(.{ tp.any, tp.any, tp.extract(&sel.begin.row), tp.extract(&sel.begin.col), tp.extract(&sel.end.row), tp.extract(&sel.end.col) })) {
            if (editor.have_matches_not_of_type(.auto_find)) return;
            if (!tui.config().enable_auto_find) return;
            sel.normalize();
            if (sel.end.row - sel.begin.row > ed.max_match_lines)
                return self.clear_auto_find(editor);
            const text = editor.get_selection(sel, self.allocator) catch return self.clear_auto_find(editor);
            if (text.len == 0)
                return self.clear_auto_find(editor);
            if (text.len == 1 and (text[0] == ' '))
                return self.clear_auto_find(editor);
            if (!self.is_last_match_text(text))
                tp.self_pid().send(.{ "cmd", "find_query", .{ text, "auto_find" } }) catch return;
        }
        return;
    }
}

pub fn location_update(self: *Self, m: tp.message) tp.result {
    var row: usize = 0;
    var col: usize = 0;
    const file_path = self.get_active_file_path() orelse return;
    const ephemeral = if (self.get_active_buffer()) |buffer| buffer.is_ephemeral() else false;

    if (try m.match(.{ tp.any, tp.any, tp.any, tp.extract(&row), tp.extract(&col) })) {
        if (row == 0 and col == 0) return;
        project_manager.update_mru(file_path, row, col, ephemeral) catch {};
        return self.location_history_.update(file_path, .{ .row = row + 1, .col = col + 1 }, null);
    }

    var sel: location_history.Selection = .{};
    if (try m.match(.{ tp.any, tp.any, tp.any, tp.extract(&row), tp.extract(&col), tp.extract(&sel.begin.row), tp.extract(&sel.begin.col), tp.extract(&sel.end.row), tp.extract(&sel.end.col) })) {
        project_manager.update_mru(file_path, row, col, ephemeral) catch {};
        return self.location_history_.update(file_path, .{ .row = row + 1, .col = col + 1 }, sel);
    }
}

pub fn location_update_from_editor(self: *Self) void {
    const editor = self.get_active_editor() orelse return;
    const file_path = editor.file_path orelse return;
    const ephemeral = if (editor.buffer) |buffer| buffer.is_ephemeral() else false;
    const primary = editor.get_primary();
    const row: usize = primary.cursor.row;
    const col: usize = primary.cursor.col;
    project_manager.update_mru(file_path, row, col, ephemeral) catch {};
}

fn location_jump(from: tp.pid_ref, file_path: []const u8, cursor: location_history.Cursor, selection: ?location_history.Selection) void {
    if (selection) |sel|
        from.send(.{ "cmd", "navigate", .{
            .file = file_path,
            .goto = .{ cursor.row, cursor.col, sel.begin.row, sel.begin.col, sel.end.row, sel.end.col },
        } }) catch return
    else
        from.send(.{ "cmd", "navigate", .{
            .file = file_path,
            .goto = .{ cursor.row, cursor.col },
        } }) catch return;
}

fn clear_auto_find(self: *Self, editor: *ed.Editor) void {
    editor.clear_matches_if_type(.auto_find);
    self.store_last_match_text(null);
}

fn is_last_match_text(self: *Self, text: []const u8) bool {
    const is = if (self.last_match_text) |old| std.mem.eql(u8, old, text) else false;
    self.store_last_match_text(text);
    return is;
}

fn store_last_match_text(self: *Self, text: ?[]const u8) void {
    if (self.last_match_text) |old|
        self.allocator.free(old);
    self.last_match_text = text;
}

pub fn get_active_editor(self: *Self) ?*ed.Editor {
    if (self.active_editor) |editor| return editor;
    const active_view = self.views.get_at(self.active_view) orelse return null;
    const editor = active_view.get("editor") orelse return null;
    if (editor.dynamic_cast(ed.EditorWidget)) |p| {
        self.active_editor = &p.editor;
        return &p.editor;
    }
    return null;
}

pub fn get_editor_for_buffer(self: *Self, buffer: *Buffer) ?*ed.Editor {
    for (self.views.widgets.items) |*view| {
        const editor = view.widget.get("editor") orelse continue;
        if (editor.dynamic_cast(ed.EditorWidget)) |p|
            if (p.editor.buffer == buffer)
                return &p.editor;
    }
    return null;
}

pub fn get_view_for_file(self: *Self, file_path: []const u8) ?usize {
    for (self.views.widgets.items, 0..) |*view, n| {
        const editor = view.widget.get("editor") orelse continue;
        if (editor.dynamic_cast(ed.EditorWidget)) |p|
            if (std.mem.eql(u8, p.editor.file_path orelse continue, file_path))
                return n;
    }
    return null;
}

pub fn get_active_file_path(self: *Self) ?[]const u8 {
    return if (self.get_active_editor()) |editor| editor.file_path orelse null else null;
}

pub fn get_active_buffer(self: *Self) ?*Buffer {
    return if (self.get_active_editor()) |editor| editor.buffer orelse null else null;
}

pub fn walk(self: *Self, ctx: *anyopaque, f: Widget.WalkFn, w: *Widget) bool {
    return self.floating_views.walk(ctx, f) or self.widgets.walk(ctx, f, &self.widgets_widget) or f(ctx, w);
}

fn close_all_editors(self: *Self) !void {
    self.active_editor = null;
    for (self.views.widgets.items) |*view| {
        const editor = view.widget.get("editor") orelse continue;
        if (editor.dynamic_cast(ed.EditorWidget)) |p| {
            p.editor.clear_diagnostics();
            try p.editor.close_file(.{});
        }
    }
}

fn add_and_activate_view(self: *Self, widget: Widget) !void {
    self.active_editor = null;
    if (self.views.get_at(self.active_view)) |view| view.unfocus();
    try self.views.add(widget);
    self.active_view = self.views.widgets.items.len - 1;
    if (self.views.get_at(self.active_view)) |view| view.focus();
}

pub fn find_view_for_widget(self: *Self, w_: *Widget) ?usize {
    const Ctx = struct {
        w: *Widget,
        fn find(ctx_: *anyopaque, w: *Widget) bool {
            const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
            return ctx.w == w;
        }
    };
    var ctx: Ctx = .{ .w = w_ };
    for (self.views.widgets.items, 0..) |*view, n|
        if (view.widget.walk(&ctx, Ctx.find)) return n;
    return null;
}

pub fn focus_view_by_widget(self: *Self, w: *Widget) tui.FocusAction {
    const n = self.find_view_for_widget(w) orelse return .notfound;
    if (n >= self.views.widgets.items.len) return .notfound;
    if (n == self.active_view) return .same;
    if (self.views.get_at(self.active_view)) |view| view.unfocus();
    self.active_editor = null;
    self.active_view = n;
    if (self.views.get_at(self.active_view)) |view| view.focus();
    return .changed;
}

pub fn focus_view(self: *Self, n: usize) !void {
    if (n == self.active_view) return;
    if (n > self.views.widgets.items.len) return;
    if (n == self.views.widgets.items.len)
        return self.create_home_split();

    if (self.views.get_at(self.active_view)) |view| view.unfocus();
    self.active_view = n;
    if (self.views.get_at(self.active_view)) |view| view.focus();
}

fn remove_active_view(self: *Self) !void {
    if (self.views.widgets.items.len == 1) return; // can't delete last view
    self.active_editor = null;
    self.views.delete(self.active_view);
    if (self.active_view >= self.views.widgets.items.len)
        self.active_view = self.views.widgets.items.len - 1;
    if (self.views.get_at(self.active_view)) |view| view.focus();
    tui.resize();
}

fn replace_active_view(self: *Self, widget: Widget) !void {
    const n = self.active_view;
    self.active_editor = null;
    if (self.views.get_at(n)) |view| view.unfocus();
    self.views.replace(n, widget);
    if (self.views.get_at(n)) |view| view.focus();
}

fn create_editor(self: *Self) !void {
    const frame = tracy.initZone(@src(), .{ .name = "create_editor" });
    defer frame.deinit();
    command.executeName("enter_mode_default", .{}) catch {};
    var editor_widget = try ed.create(self.allocator, self.plane, &self.buffer_manager);
    errdefer editor_widget.deinit(self.allocator);
    const editor = editor_widget.get("editor") orelse @panic("mainview editor not found");
    if (self.top_bar) |*bar| editor.subscribe(EventHandler.to_unowned(bar)) catch @panic("subscribe unsupported");
    if (self.bottom_bar) |*bar| editor.subscribe(EventHandler.to_unowned(bar)) catch @panic("subscribe unsupported");
    editor.subscribe(EventHandler.bind(self, handle_editor_event)) catch @panic("subscribe unsupported");
    try self.replace_active_view(editor_widget);
    tui.resize();
}

fn toggle_logview_async(_: *Self) void {
    tp.self_pid().send(.{ "cmd", "toggle_logview" }) catch return;
}

fn toggle_inputview_async(_: *Self) void {
    tp.self_pid().send(.{ "cmd", "toggle_inputview" }) catch return;
}

fn toggle_keybindview_async(_: *Self) void {
    tp.self_pid().send(.{ "cmd", "toggle_keybindview" }) catch return;
}

fn show_file_async(_: *Self, file_path: []const u8) void {
    tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_path } }) catch return;
}

fn show_home_async(_: *Self) void {
    tp.self_pid().send(.{ "cmd", "show_home" }) catch return;
}

fn create_home(self: *Self) !void {
    tui.reset_drag_context();
    try self.replace_active_view(try home.create(self.allocator, Widget.to(self)));
    tui.resize();
}

fn create_home_split(self: *Self) !void {
    tui.reset_drag_context();
    try self.add_and_activate_view(try home.create(self.allocator, Widget.to(self)));
    tui.resize();
}

pub const WriteStateError = error{
    OutOfMemory,
    Stop,
    WriteFailed,
};

pub fn write_restore_info(self: *Self) WriteStateError!void {
    const file_name = root.get_restore_file_name() catch return;
    var file = std.fs.createFileAbsolute(file_name, .{ .truncate = true }) catch return;
    defer file.close();
    var buf: [32 + 1024]u8 = undefined;
    var file_writer = file.writer(&buf);
    const writer = &file_writer.interface;

    try self.write_state(writer);
    try writer.flush();
}

pub fn write_state(self: *Self, writer: *std.Io.Writer) WriteStateError!void {
    const current_project = tp.env.get().str("project");
    try cbor.writeValue(writer, current_project);
    if (self.get_active_editor()) |editor| {
        try cbor.writeValue(writer, editor.file_path);
        editor.update_meta();
    } else {
        try cbor.writeValue(writer, null);
    }

    if (tui.clipboard_get_history()) |clipboard| {
        try cbor.writeArrayHeader(writer, clipboard.len);
        for (clipboard) |item| {
            try cbor.writeArrayHeader(writer, 2);
            try cbor.writeValue(writer, item.group);
            try cbor.writeValue(writer, item.text);
        }
    } else {
        try cbor.writeValue(writer, null);
    }

    const buffer_manager = tui.get_buffer_manager() orelse @panic("tabs no buffer manager");
    try buffer_manager.write_state(writer);

    if (self.widgets.get("tabs")) |tabs_widget|
        if (tabs_widget.dynamic_cast(@import("status/tabs.zig").TabBar)) |tabs|
            try tabs.write_state(writer);
}

fn read_restore_info(self: *Self) !void {
    const file_name = try root.get_restore_file_name();
    const file = try std.fs.openFileAbsolute(file_name, .{ .mode = .read_only });
    defer file.close();
    const stat = try file.stat();
    var buf = try self.allocator.alloc(u8, @intCast(stat.size));
    defer self.allocator.free(buf);
    const size = try file.readAll(buf);
    var iter: []const u8 = buf[0..size];

    try self.extract_state(&iter, .with_project);
}

fn restore_state(self: *Self, state: []const u8) !void {
    var iter = state;
    try self.extract_state(&iter, .no_project);
}

fn extract_state(self: *Self, iter: *[]const u8, mode: enum { no_project, with_project }) !void {
    const logger = log.logger("extract_state");
    defer logger.deinit();
    tp.trace(tp.channel.debug, .{ "mainview", "extract" });
    var project_dir: []const u8 = undefined;
    var editor_file_path: ?[]const u8 = undefined;
    var prev_len = iter.len;
    if (!try cbor.matchValue(iter, cbor.extract(&project_dir))) {
        logger.print("restore project_dir failed", .{});
        return error.MatchStoredProjectFailed;
    }

    switch (mode) {
        .with_project => {
            _ = try project_manager.open(project_dir);
            tui.rdr().set_terminal_working_directory(project_dir);
            if (self.top_bar) |bar| _ = try bar.msg(.{ "PRJ", "open" });
            if (self.bottom_bar) |bar| _ = try bar.msg(.{ "PRJ", "open" });
        },
        .no_project => {},
    }

    if (!try cbor.matchValue(iter, cbor.extract(&editor_file_path))) {
        logger.print("restore editor_file_path failed", .{});
        return error.MatchFilePathFailed;
    }
    logger.print("restored editor_file_path: {s} ({d} bytes)", .{ editor_file_path orelse "(null)", prev_len - iter.len });

    tui.clipboard_clear_all();
    prev_len = iter.len;
    var len = try cbor.decodeArrayHeader(iter);
    var prev_group: usize = 0;
    const clipboard_allocator = tui.clipboard_allocator();
    while (len > 0) : (len -= 1) {
        const len_ = try cbor.decodeArrayHeader(iter);
        if (len_ != 2) return error.MatchClipboardArrayFailed;
        var group: usize = 0;
        var text: []const u8 = undefined;
        if (!try cbor.matchValue(iter, cbor.extract(&group))) return error.MatchClipboardGroupFailed;
        if (!try cbor.matchValue(iter, cbor.extract(&text))) return error.MatchClipboardTextFailed;
        if (prev_group != group) tui.clipboard_start_group();
        prev_group = group;
        tui.clipboard_add_chunk(try clipboard_allocator.dupe(u8, text));
    }
    logger.print("restored clipboard ({d} bytes)", .{prev_len - iter.len});

    prev_len = iter.len;
    try self.buffer_manager.extract_state(iter);
    logger.print("restored buffer manager ({d} bytes)", .{prev_len - iter.len});

    prev_len = iter.len;
    if (self.widgets.get("tabs")) |tabs_widget|
        if (tabs_widget.dynamic_cast(@import("status/tabs.zig").TabBar)) |tabs|
            tabs.extract_state(iter) catch |e|
                logger.print_err("mainview", "failed to restore tabs: {}", .{e});
    logger.print("restored tabs ({d} bytes)", .{prev_len - iter.len});

    const buffers = try self.buffer_manager.list_unordered(self.allocator);
    defer self.allocator.free(buffers);
    for (buffers) |buffer| if (!buffer.is_ephemeral())
        send_buffer_did_open(self.allocator, buffer) catch {};

    if (editor_file_path) |file_path|
        if (self.buffer_manager.get_buffer_for_file(file_path)) |_|
            try tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_path } });
}

fn send_buffer_did_open(allocator: std.mem.Allocator, buffer: *Buffer) !void {
    const ft = try file_type_config.get(buffer.file_type_name orelse return) orelse return;
    var content: std.Io.Writer.Allocating = .init(allocator);
    defer content.deinit();
    try buffer.root.store(&content.writer, buffer.file_eol_mode);

    try project_manager.did_open(
        buffer.get_file_path(),
        ft,
        buffer.lsp_version,
        try content.toOwnedSlice(),
        buffer.is_ephemeral(),
    );
    if (!buffer.is_ephemeral())
        project_manager.request_vcs_id(buffer.get_file_path()) catch {};
}

fn get_next_mru_buffer(self: *Self, mode: enum { all, hidden, non_hidden }) ?[]const u8 {
    const buffers = self.buffer_manager.list_most_recently_used(self.allocator) catch return null;
    defer self.allocator.free(buffers);
    const active_file_path = self.get_active_file_path();
    for (buffers) |buffer| {
        if (active_file_path) |fp| if (std.mem.eql(u8, fp, buffer.get_file_path()))
            continue;
        if (switch (mode) {
            .all => false,
            .hidden => !buffer.hidden,
            .non_hidden => buffer.hidden,
        }) continue;
        return buffer.get_file_path();
    }
    return null;
}

fn delete_all_buffers(self: *Self) void {
    self.buffer_manager.delete_all();
}

fn add_find_in_files_result(
    self: *Self,
    file_list_type: FileListType,
    path: []const u8,
    begin_line: usize,
    begin_pos: usize,
    end_line: usize,
    end_pos: usize,
    lines: []const u8,
    severity: ed.Diagnostic.Severity,
) tp.result {
    _ = self.toggle_panel_view(filelist_view, .enable) catch |e| return tp.exit_error(e, @errorReturnTrace());
    const fl = self.get_panel_view(filelist_view) orelse @panic("filelist_view missing");
    if (self.file_list_type != file_list_type) {
        self.clear_find_in_files_results(self.file_list_type);
        self.file_list_type = file_list_type;
    } else switch (self.find_in_files_state) {
        .init, .done => {
            self.clear_find_in_files_results(self.file_list_type);
            self.file_list_type = file_list_type;
            self.find_in_files_state = .adding;
        },
        .adding => {},
    }
    fl.add_item(.{
        .path = path,
        .begin_line = @max(1, begin_line) - 1,
        .begin_pos = @max(1, begin_pos) - 1,
        .end_line = @max(1, end_line) - 1,
        .end_pos = @max(1, end_pos) - 1,
        .lines = lines,
        .severity = severity,
        .pos_type = .byte,
    }) catch |e| return tp.exit_error(e, @errorReturnTrace());
}

fn clear_find_in_files_results(self: *Self, file_list_type: FileListType) void {
    if (self.file_list_type != file_list_type) return;
    if (!self.is_panel_view_showing(filelist_view)) return;
    const fl = self.get_panel_view(filelist_view) orelse @panic("filelist_view missing");
    self.find_in_files_state = .done;
    self.file_list_type = file_list_type;
    fl.reset();
}

pub fn set_info_content(self: *Self, content: []const u8, mode: enum { replace, append }) tp.result {
    if (content.len == 0) return;
    _ = self.toggle_panel_view(info_view, .enable) catch |e| return tp.exit_error(e, @errorReturnTrace());
    const info = self.get_panel_view(info_view) orelse @panic("info_view missing");
    switch (mode) {
        .replace => info.set_content(content) catch |e| return tp.exit_error(e, @errorReturnTrace()),
        .append => info.append_content(content) catch |e| return tp.exit_error(e, @errorReturnTrace()),
    }
    tui.need_render();
}

pub fn cancel_info_content(self: *Self) tp.result {
    _ = self.toggle_panel_view(info_view, .disable) catch |e| return tp.exit_error(e, @errorReturnTrace());
    tui.need_render();
}

pub fn vcs_id_update(self: *Self, m: tp.message) void {
    var file_path: []const u8 = undefined;
    var vcs_id: []const u8 = undefined;

    if (m.match(.{ "PRJ", "vcs_id", tp.extract(&file_path), tp.extract(&vcs_id) }) catch return) {
        const buffer = self.buffer_manager.get_buffer_for_file(file_path) orelse return;
        const need_vcs_content = buffer.set_vcs_id(vcs_id) catch false;
        if (need_vcs_content)
            project_manager.request_vcs_content(file_path, vcs_id) catch {};
    }
}

pub fn vcs_content_update(self: *Self, m: tp.message) void {
    var file_path: []const u8 = undefined;
    var vcs_id: []const u8 = undefined;
    var content: []const u8 = undefined;

    if (m.match(.{ "PRJ", "vcs_content", tp.extract(&file_path), tp.extract(&vcs_id), tp.extract(&content) }) catch return) {
        const buffer = self.buffer_manager.get_buffer_for_file(file_path) orelse return;
        buffer.set_vcs_content(vcs_id, content) catch {};
    } else if (m.match(.{ "PRJ", "vcs_content", tp.extract(&file_path), tp.extract(&vcs_id), tp.null_ }) catch return) {
        const buffer = self.buffer_manager.get_buffer_for_file(file_path) orelse return;
        if (self.get_editor_for_buffer(buffer)) |editor|
            editor.vcs_content_update() catch {};
    }
}
