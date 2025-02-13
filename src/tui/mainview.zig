const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const tracy = @import("tracy");
const ripgrep = @import("ripgrep");
const root = @import("root");
const location_history = @import("location_history");
const project_manager = @import("project_manager");
const log = @import("log");
const shell = @import("shell");
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

const Self = @This();
const Commands = command.Collection(cmds);

allocator: std.mem.Allocator,
plane: Plane,
widgets: *WidgetList,
widgets_widget: Widget,
floating_views: WidgetStack,
commands: Commands = undefined,
top_bar: ?*Widget = null,
bottom_bar: ?*Widget = null,
active_editor: ?usize = null,
editors: std.ArrayListUnmanaged(*ed.Editor) = .{},
views: *WidgetList,
views_widget: Widget,
active_view: ?usize = 0,
panels: ?*WidgetList = null,
last_match_text: ?[]const u8 = null,
location_history_: location_history,
buffer_manager: Buffer.Manager,
find_in_files_state: enum { init, adding, done } = .done,
file_list_type: FileListType = .find_in_files,
panel_height: ?usize = null,

const FileListType = enum {
    diagnostics,
    references,
    find_in_files,
};

pub fn create(allocator: std.mem.Allocator) !Widget {
    const self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .plane = tui.plane(),
        .widgets = undefined,
        .widgets_widget = undefined,
        .floating_views = WidgetStack.init(allocator),
        .location_history_ = try location_history.create(),
        .views = undefined,
        .views_widget = undefined,
        .buffer_manager = Buffer.Manager.init(allocator),
    };
    try self.commands.init(self);
    const w = Widget.to(self);

    const widgets = try WidgetList.createV(allocator, self.plane, @typeName(Self), .dynamic);
    self.widgets = widgets;
    self.widgets_widget = widgets.widget();
    if (tui.config().top_bar.len > 0)
        self.top_bar = try widgets.addP(try @import("status/bar.zig").create(allocator, self.plane, tui.config().top_bar, .none, null));

    const views = try WidgetList.createH(allocator, self.plane, @typeName(Self), .dynamic);
    self.views = views;
    self.views_widget = views.widget();
    try views.add(try Widget.empty(allocator, self.views_widget.plane.*, .dynamic));

    try widgets.add(self.views_widget);

    if (tui.config().bottom_bar.len > 0) {
        self.bottom_bar = try widgets.addP(try @import("status/bar.zig").create(allocator, self.plane, tui.config().bottom_bar, .grip, EventHandler.bind(self, handle_bottom_bar_event)));
    }
    if (tp.env.get().is("show-input"))
        self.toggle_inputview_async();
    if (tp.env.get().is("show-log"))
        self.toggle_logview_async();
    return w;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.close_all_panel_views();
    self.commands.deinit();
    self.widgets.deinit(allocator);
    self.floating_views.deinit();
    self.buffer_manager.deinit();
    allocator.destroy(self);
}

pub fn receive(self: *Self, from_: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var path: []const u8 = undefined;
    var begin_line: usize = undefined;
    var begin_pos: usize = undefined;
    var end_line: usize = undefined;
    var end_pos: usize = undefined;
    var lines: []const u8 = undefined;
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
    } else if (try m.match(.{ "hover", tp.extract(&path), tp.string, tp.extract(&lines), tp.extract(&begin_line), tp.extract(&begin_pos), tp.extract(&end_line), tp.extract(&end_pos) })) {
        try self.add_info_content(lines);
        if (self.get_active_editor()) |editor|
            editor.add_hover_highlight(.{
                .begin = .{ .row = begin_line, .col = begin_pos },
                .end = .{ .row = end_line, .col = end_pos },
            });
        return true;
    }
    return if (try self.floating_views.send(from_, m)) true else self.widgets.send(from_, m);
}

pub fn update(self: *Self) void {
    self.widgets.update();
    self.floating_views.update();
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    const widgets_more = self.widgets.render(theme);
    const views_more = self.floating_views.render(theme);
    return widgets_more or views_more;
}

pub fn handle_resize(self: *Self, pos: Box) void {
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

fn toggle_panel_view(self: *Self, view: anytype, enable_only: bool) !void {
    if (self.panels) |panels| {
        if (panels.get(@typeName(view))) |w| {
            if (!enable_only) {
                panels.remove(w.*);
                if (panels.empty()) {
                    self.widgets.remove(panels.widget());
                    self.panels = null;
                }
            }
        } else {
            try panels.add(try view.create(self.allocator, self.widgets.plane));
        }
    } else {
        const panels = try WidgetList.createH(self.allocator, self.widgets.plane, "panel", .{ .static = self.panel_height orelse self.box().h / 5 });
        try self.widgets.add(panels.widget());
        try panels.add(try view.create(self.allocator, self.widgets.plane));
        self.panels = panels;
    }
    tui.resize();
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

fn toggle_view(self: *Self, view: anytype) !void {
    if (self.widgets.get(@typeName(view))) |w| {
        self.widgets.remove(w.*);
    } else {
        try self.widgets.add(try view.create(self.allocator, self.plane));
    }
    tui.resize();
}

fn check_all_not_dirty(self: *const Self) command.Result {
    if (self.buffer_manager.is_dirty())
        return tp.exit("unsaved changes");
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn quit(self: *Self, _: Ctx) Result {
        try self.check_all_not_dirty();
        try tp.self_pid().send("quit");
    }
    pub const quit_meta: Meta = .{ .description = "Quit (exit) Flow Control" };

    pub fn quit_without_saving(_: *Self, _: Ctx) Result {
        try tp.self_pid().send("quit");
    }
    pub const quit_without_saving_meta: Meta = .{ .description = "Quit without saving" };

    pub fn open_project_cwd(self: *Self, _: Ctx) Result {
        try project_manager.open(".");
        if (self.top_bar) |bar| _ = try bar.msg(.{ "PRJ", "open" });
        if (self.bottom_bar) |bar| _ = try bar.msg(.{ "PRJ", "open" });
    }
    pub const open_project_cwd_meta: Meta = .{};

    pub fn open_project_dir(self: *Self, ctx: Ctx) Result {
        var project_dir: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&project_dir)}))
            return;
        try project_manager.open(project_dir);
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
        var project_dir: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&project_dir)}))
            return;
        try self.check_all_not_dirty();
        for (self.editors.items) |editor| {
            editor.clear_diagnostics();
            try editor.close_file(.{});
        }
        self.delete_all_buffers();
        self.clear_find_in_files_results(.diagnostics);
        if (self.file_list_type == .diagnostics and self.is_panel_view_showing(filelist_view))
            try self.toggle_panel_view(filelist_view, false);
        self.buffer_manager.deinit();
        self.buffer_manager = Buffer.Manager.init(self.allocator);
        try project_manager.open(project_dir);
        const project = tp.env.get().str("project");
        tui.rdr().set_terminal_working_directory(project);
        if (self.top_bar) |bar| _ = try bar.msg(.{ "PRJ", "open" });
        if (self.bottom_bar) |bar| _ = try bar.msg(.{ "PRJ", "open" });
        if (try project_manager.request_most_recent_file(self.allocator)) |file_path|
            self.show_file_async_and_free(file_path);
    }
    pub const change_project_meta: Meta = .{ .arguments = &.{.string} };

    pub fn navigate(self: *Self, ctx: Ctx) Result {
        tui.reset_drag_context();
        const frame = tracy.initZone(@src(), .{ .name = "navigate" });
        defer frame.deinit();
        var file: ?[]const u8 = null;
        var file_name: []const u8 = undefined;
        var line: ?i64 = null;
        var column: ?i64 = null;
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

        const f = project_manager.normalize_file_path(file orelse return);
        const same_file = if (self.get_active_file_path()) |fp| std.mem.eql(u8, fp, f) else false;
        const have_editor_metadata = if (self.buffer_manager.get_buffer_for_file(f)) |_| true else false;

        if (!same_file) {
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
            if (!same_file)
                try command.executeName("scroll_view_center", .{});
            if (column) |col|
                try command.executeName("goto_column", command.fmt(.{col}));
        } else {
            if (!same_file and !have_editor_metadata)
                try project_manager.get_mru_position(f);
        }
        tui.need_render();
    }
    pub const navigate_meta: Meta = .{ .arguments = &.{.object} };

    pub fn open_help(self: *Self, _: Ctx) Result {
        tui.reset_drag_context();
        try self.create_editor();
        try command.executeName("open_scratch_buffer", command.fmt(.{ "help", @embedFile("help.md"), "markdown" }));
        tui.need_render();
    }
    pub const open_help_meta: Meta = .{ .description = "Open help" };

    pub fn open_font_test_text(self: *Self, _: Ctx) Result {
        tui.reset_drag_context();
        try self.create_editor();
        try command.executeName("open_scratch_buffer", command.fmt(.{ "font test", @import("fonts.zig").font_test_text, "text" }));
        tui.need_render();
    }
    pub const open_font_test_text_meta: Meta = .{ .description = "Open font glyph test text" };

    pub fn open_version_info(self: *Self, _: Ctx) Result {
        tui.reset_drag_context();
        try self.create_editor();
        try command.executeName("open_scratch_buffer", command.fmt(.{ "version", root.version_info, "diff" }));
        tui.need_render();
    }
    pub const open_version_info_meta: Meta = .{ .description = "Show build version information" };

    pub fn open_config(_: *Self, _: Ctx) Result {
        const file_name = try root.get_config_file_name(@import("config"));
        try tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_name[0 .. file_name.len - 5] } });
    }
    pub const open_config_meta: Meta = .{ .description = "Edit configuration file" };

    pub fn open_gui_config(_: *Self, _: Ctx) Result {
        const file_name = try root.get_config_file_name(@import("gui_config"));
        try tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_name[0 .. file_name.len - ".json".len] } });
    }
    pub const open_gui_config_meta: Meta = .{ .description = "Edit gui configuration file" };

    pub fn open_tabs_style_config(self: *Self, _: Ctx) Result {
        const Style = @import("status/tabs.zig").Style;
        const file_name = try root.get_config_file_name(Style);
        const tab_style, const tab_style_bufs: [][]const u8 = if (root.exists_config(Style)) blk: {
            const tab_style, const tab_style_bufs = root.read_config(Style, self.allocator);
            break :blk .{ tab_style, tab_style_bufs };
        } else .{ Style{}, &.{} };
        defer root.free_config(self.allocator, tab_style_bufs);
        var conf = std.ArrayList(u8).init(self.allocator);
        defer conf.deinit();
        root.write_config_to_writer(Style, tab_style, conf.writer()) catch {};
        tui.reset_drag_context();
        try self.create_editor();
        try command.executeName("open_scratch_buffer", command.fmt(.{
            file_name[0 .. file_name.len - ".json".len],
            conf.items,
            "conf",
        }));
        if (self.get_active_buffer()) |buffer| buffer.mark_not_ephemeral();
    }
    pub const open_tabs_style_config_meta: Meta = .{ .description = "Edit tab styles configuration file" };

    pub fn create_scratch_buffer(self: *Self, ctx: Ctx) Result {
        const args = try ctx.args.clone(self.allocator);
        defer self.allocator.free(args.buf);
        tui.reset_drag_context();
        try self.create_editor();
        try command.executeName("open_scratch_buffer", .{ .args = args });
        tui.need_render();
    }
    pub const create_scratch_buffer_meta: Meta = .{ .arguments = &.{ .string, .string, .string } };

    pub fn create_new_file(self: *Self, _: Ctx) Result {
        var n: usize = 1;
        var found_unique = false;
        var name = std.ArrayList(u8).init(self.allocator);
        defer name.deinit();
        while (!found_unique) {
            name.clearRetainingCapacity();
            try name.writer().print("Untitled-{d}", .{n});
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
    pub const create_new_file_meta: Meta = .{ .description = "Create: New File…" };

    pub fn delete_buffer(self: *Self, ctx: Ctx) Result {
        var file_path: []const u8 = undefined;
        if (!(ctx.args.match(.{tp.extract(&file_path)}) catch false))
            return error.InvalidDeleteBufferArgument;
        const buffer = self.buffer_manager.get_buffer_for_file(file_path) orelse return;
        if (buffer.is_dirty())
            return tp.exit("unsaved changes");
        if (self.get_active_editor()) |editor| if (editor.buffer == buffer)
            editor.close_file(.{}) catch |e| return e;
        _ = self.buffer_manager.delete_buffer(file_path);
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
        if (tp.env.get().str("project").len == 0) {
            try open_project_cwd(self, .{});
        }
        try self.create_editor();
        try self.read_restore_info();
        tui.need_render();
    }
    pub const restore_session_meta: Meta = .{};

    pub fn toggle_panel(self: *Self, _: Ctx) Result {
        if (self.is_panel_view_showing(logview))
            try self.toggle_panel_view(logview, false)
        else if (self.is_panel_view_showing(info_view))
            try self.toggle_panel_view(info_view, false)
        else if (self.is_panel_view_showing(filelist_view))
            try self.toggle_panel_view(filelist_view, false)
        else
            try self.toggle_panel_view(logview, false);
    }
    pub const toggle_panel_meta: Meta = .{ .description = "Toggle panel" };

    pub fn toggle_logview(self: *Self, _: Ctx) Result {
        try self.toggle_panel_view(logview, false);
    }
    pub const toggle_logview_meta: Meta = .{};

    pub fn show_logview(self: *Self, _: Ctx) Result {
        try self.toggle_panel_view(logview, true);
    }
    pub const show_logview_meta: Meta = .{ .description = "View log" };

    pub fn toggle_inputview(self: *Self, _: Ctx) Result {
        try self.toggle_panel_view(@import("inputview.zig"), false);
    }
    pub const toggle_inputview_meta: Meta = .{ .description = "Toggle raw input log" };

    pub fn toggle_inspector_view(self: *Self, _: Ctx) Result {
        try self.toggle_panel_view(@import("inspector_view.zig"), false);
    }
    pub const toggle_inspector_view_meta: Meta = .{ .description = "Toggle inspector view" };

    pub fn show_inspector_view(self: *Self, _: Ctx) Result {
        try self.toggle_panel_view(@import("inspector_view.zig"), true);
    }
    pub const show_inspector_view_meta: Meta = .{};

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
    pub const add_split_meta: Meta = .{};

    pub fn gutter_mode_next(self: *Self, _: Ctx) Result {
        const config = tui.config_mut();
        var ln = config.gutter_line_numbers;
        var lnr = config.gutter_line_numbers_relative;
        if (ln and !lnr) {
            ln = true;
            lnr = true;
        } else if (ln and lnr) {
            ln = false;
            lnr = false;
        } else {
            ln = true;
            lnr = false;
        }
        config.gutter_line_numbers = ln;
        config.gutter_line_numbers_relative = lnr;
        try tui.save_config();
        if (self.widgets.get("editor_gutter")) |gutter_widget| {
            const gutter = gutter_widget.dynamic_cast(@import("editor_gutter.zig")) orelse return;
            gutter.linenum = ln;
            gutter.relative = lnr;
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
        if (self.get_active_editor()) |editor| if (std.mem.eql(u8, file_path, editor.file_path orelse ""))
            try editor.add_diagnostic(file_path, source, code, message, severity, sel)
        else
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

    pub fn rename_symbol_item(self: *Self, ctx: Ctx) Result {
        const editor = self.get_active_editor() orelse return;
        // because the incoming message is an array of Renames, we manuallly
        // parse instead of using ctx.args.match() which doesn't seem to return
        // the parsed length needed to correctly advance iter.
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
        if (self.file_list_type == .diagnostics and self.is_panel_view_showing(filelist_view))
            try self.toggle_panel_view(filelist_view, false);
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
        self.show_file_async(self.get_next_mru_buffer() orelse return error.Stop);
    }
    pub const open_previous_file_meta: Meta = .{ .description = "Open the previous file" };

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
        if (self.get_active_editor()) |editor| if (editor.buffer) |eb| if (eb == buffer) {
            editor.move_buffer_end(.{}) catch {};
            editor.insert_chars(command.fmt(.{output})) catch {};
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
};

pub fn handle_editor_event(self: *Self, _: tp.pid_ref, m: tp.message) tp.result {
    const editor = self.get_active_editor() orelse return;
    var sel: ed.Selection = undefined;

    if (try m.match(.{ "E", "location", tp.more }))
        return self.location_update(m);

    if (try m.match(.{ "E", "close" })) {
        if (self.get_next_mru_buffer()) |file_path|
            self.show_file_async(file_path)
        else
            self.show_home_async();
        self.active_editor = null;
        return;
    }

    if (try m.match(.{ "E", "sel", tp.more })) {
        if (try m.match(.{ tp.any, tp.any, "none" }))
            return self.clear_auto_find(editor);
        if (try m.match(.{ tp.any, tp.any, tp.extract(&sel.begin.row), tp.extract(&sel.begin.col), tp.extract(&sel.end.row), tp.extract(&sel.end.col) })) {
            sel.normalize();
            if (sel.end.row - sel.begin.row > ed.max_match_lines)
                return self.clear_auto_find(editor);
            const text = editor.get_selection(sel, self.allocator) catch return self.clear_auto_find(editor);
            if (text.len == 0)
                return self.clear_auto_find(editor);
            if (!self.is_last_match_text(text)) {
                tp.self_pid().send(.{ "cmd", "find_query", .{text} }) catch return;
            }
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
    editor.clear_matches();
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
    return self.editors.items[self.active_editor orelse return null];
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

fn add_editor(self: *Self, p: *ed.Editor) !void {
    try self.editors.resize(self.allocator, 1);
    self.editors.items[0] = p;
    self.active_editor = 0;
}

fn remove_editor(self: *Self, idx: usize) void {
    _ = idx;
    self.editors.clearRetainingCapacity();
    self.active_editor = null;
}

fn add_view(self: *Self, widget: Widget) !void {
    try self.views.add(widget);
}

fn delete_active_view(self: *Self) !void {
    const n = self.active_view orelse return;
    self.views.replace(n, try Widget.empty(self.allocator, self.plane, .dynamic));
}

fn replace_active_view(self: *Self, widget: Widget) !void {
    const n = self.active_view orelse return error.NotFound;
    self.remove_editor(0);
    self.views.replace(n, widget);
}

fn create_editor(self: *Self) !void {
    try self.delete_active_view();
    command.executeName("enter_mode_default", .{}) catch {};
    var editor_widget = try ed.create(self.allocator, self.plane, &self.buffer_manager);
    errdefer editor_widget.deinit(self.allocator);
    const editor = editor_widget.get("editor") orelse @panic("mainview editor not found");
    if (self.top_bar) |bar| editor.subscribe(EventHandler.to_unowned(bar)) catch @panic("subscribe unsupported");
    if (self.bottom_bar) |bar| editor.subscribe(EventHandler.to_unowned(bar)) catch @panic("subscribe unsupported");
    editor.subscribe(EventHandler.bind(self, handle_editor_event)) catch @panic("subscribe unsupported");
    try self.replace_active_view(editor_widget);
    if (editor.dynamic_cast(ed.EditorWidget)) |p|
        try self.add_editor(&p.editor);
    tui.resize();
}

fn toggle_logview_async(_: *Self) void {
    tp.self_pid().send(.{ "cmd", "toggle_logview" }) catch return;
}

fn toggle_inputview_async(_: *Self) void {
    tp.self_pid().send(.{ "cmd", "toggle_inputview" }) catch return;
}

fn show_file_async_and_free(self: *Self, file_path: []const u8) void {
    defer self.allocator.free(file_path);
    self.show_file_async(file_path);
}

fn show_file_async(_: *Self, file_path: []const u8) void {
    tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_path } }) catch return;
}

fn show_home_async(_: *Self) void {
    tp.self_pid().send(.{ "cmd", "show_home" }) catch return;
}

fn create_home(self: *Self) !void {
    tui.reset_drag_context();
    if (self.active_editor) |_| return;
    try self.delete_active_view();
    try self.replace_active_view(try home.create(self.allocator, Widget.to(self)));
    tui.resize();
}

fn create_home_split(self: *Self) !void {
    tui.reset_drag_context();
    try self.add_view(try home.create(self.allocator, Widget.to(self)));
    tui.resize();
}

pub fn write_restore_info(self: *Self) void {
    const editor = self.get_active_editor() orelse return;
    var sfa = std.heap.stackFallback(512, self.allocator);
    const a = sfa.get();
    var meta = std.ArrayList(u8).init(a);
    editor.write_state(meta.writer()) catch return;
    const file_name = root.get_restore_file_name() catch return;
    var file = std.fs.createFileAbsolute(file_name, .{ .truncate = true }) catch return;
    defer file.close();
    file.writeAll(meta.items) catch return;
}

fn read_restore_info(self: *Self) !void {
    const editor = self.get_active_editor() orelse return;
    const file_name = try root.get_restore_file_name();
    const file = try std.fs.cwd().openFile(file_name, .{ .mode = .read_only });
    defer file.close();
    const stat = try file.stat();
    var buf = try self.allocator.alloc(u8, @intCast(stat.size));
    defer self.allocator.free(buf);
    const size = try file.readAll(buf);
    try editor.extract_state(buf[0..size], .open_file);
}

fn get_next_mru_buffer(self: *Self) ?[]const u8 {
    const buffers = self.buffer_manager.list_most_recently_used(self.allocator) catch return null;
    defer self.allocator.free(buffers);
    const active_file_path = self.get_active_file_path();
    for (buffers) |buffer| {
        if (active_file_path) |fp| if (std.mem.eql(u8, fp, buffer.file_path))
            continue;
        if (buffer.hidden)
            continue;
        return buffer.file_path;
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
    if (!self.is_panel_view_showing(filelist_view))
        _ = self.toggle_panel_view(filelist_view, false) catch |e| return tp.exit_error(e, @errorReturnTrace());
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

fn add_info_content(self: *Self, content: []const u8) tp.result {
    if (content.len == 0) return;
    if (!self.is_panel_view_showing(info_view))
        _ = self.toggle_panel_view(info_view, false) catch |e| return tp.exit_error(e, @errorReturnTrace());
    const info = self.get_panel_view(info_view) orelse @panic("info_view missing");
    info.set_content(content) catch |e| return tp.exit_error(e, @errorReturnTrace());
    tui.need_render();
}
