const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const tracy = @import("tracy");
const ripgrep = @import("ripgrep");
const root = @import("root");
const location_history = @import("location_history");
const project_manager = @import("project_manager");
const log = @import("log");
const builtin = @import("builtin");

const Plane = @import("renderer").Plane;
const input = @import("input");
const command = @import("command");

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
panels: ?*WidgetList = null,
last_match_text: ?[]const u8 = null,
location_history: location_history,
file_stack: std.ArrayList([]const u8),
find_in_files_done: bool = false,
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
        .plane = tui.current().stdplane(),
        .widgets = undefined,
        .widgets_widget = undefined,
        .floating_views = WidgetStack.init(allocator),
        .location_history = try location_history.create(),
        .file_stack = std.ArrayList([]const u8).init(allocator),
        .view_widget_idx = 0,
    };
    try self.commands.init(self);
    const w = Widget.to(self);
    const widgets = try WidgetList.createV(allocator, w, @typeName(Self), .dynamic);
    self.widgets = widgets;
    self.widgets_widget = widgets.widget();
    if (tui.current().config.top_bar.len > 0) {
        self.top_bar = try widgets.addP(try @import("status/bar.zig").create(allocator, w, tui.current().config.top_bar, .none, null));
        self.view_widget_idx += 1;
    }
    try widgets.add(try Widget.empty(allocator, self.widgets_widget.plane.*, .dynamic));
    if (tui.current().config.bottom_bar.len > 0) {
        self.bottom_bar = try widgets.addP(try @import("status/bar.zig").create(allocator, w, tui.current().config.bottom_bar, .grip, EventHandler.bind(self, handle_bottom_bar_event)));
    }
    if (tp.env.get().is("show-input"))
        self.toggle_inputview_async();
    if (tp.env.get().is("show-log"))
        self.toggle_logview_async();
    return w;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.close_all_panel_views();
    self.clear_file_stack();
    self.file_stack.deinit();
    self.commands.deinit();
    self.widgets.deinit(allocator);
    self.floating_views.deinit();
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
        self.find_in_files_done = true;
        return true;
    } else if (try m.match(.{ "FIF", "done" })) {
        self.find_in_files_done = true;
        return true;
    } else if (try m.match(.{ "hover", tp.extract(&path), tp.string, tp.extract(&lines), tp.extract(&begin_line), tp.extract(&begin_pos), tp.extract(&end_line), tp.extract(&end_pos) })) {
        try self.add_info_content(begin_line, begin_pos, end_line, end_pos, lines);
        return true;
    } else if (try m.match(.{"write_restore_info"})) {
        self.write_restore_info();
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
    self.plane = tui.current().stdplane();
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
    panels.layout = .{ .static = self.panel_height.? };
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
        const panels = try WidgetList.createH(self.allocator, self.widgets.widget(), "panel", .{ .static = self.panel_height orelse self.box().h / 5 });
        try self.widgets.add(panels.widget());
        try panels.add(try view.create(self.allocator, self.widgets.plane));
        self.panels = panels;
    }
    tui.current().resize();
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
    tui.current().resize();
}

fn toggle_view(self: *Self, view: anytype) !void {
    if (self.widgets.get(@typeName(view))) |w| {
        self.widgets.remove(w.*);
    } else {
        try self.widgets.add(try view.create(self.allocator, self.plane));
    }
    tui.current().resize();
}

fn check_all_not_dirty(self: *const Self) command.Result {
    for (self.editors.items) |editor|
        if (editor.is_dirty())
            return tp.exit("unsaved changes");
}

fn check_active_not_dirty(self: *const Self) command.Result {
    if (self.active_editor) |idx|
        if (self.editors.items[idx].is_dirty())
            return tp.exit("unsaved changes");
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Result = command.Result;

    pub fn quit(self: *Self, _: Ctx) Result {
        try self.check_all_not_dirty();
        try tp.self_pid().send("quit");
    }
    pub const quit_meta = .{ .description = "Quit (exit) Flow Control" };

    pub fn quit_without_saving(_: *Self, _: Ctx) Result {
        try tp.self_pid().send("quit");
    }
    pub const quit_without_saving_meta = .{ .description = "Quit without saving" };

    pub fn open_project_cwd(self: *Self, _: Ctx) Result {
        try project_manager.open(".");
        if (self.top_bar) |bar| _ = try bar.msg(.{ "PRJ", "open" });
        if (self.bottom_bar) |bar| _ = try bar.msg(.{ "PRJ", "open" });
    }
    pub const open_project_cwd_meta = .{};

    pub fn open_project_dir(self: *Self, ctx: Ctx) Result {
        var project_dir: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&project_dir)}))
            return;
        try project_manager.open(project_dir);
        const project = tp.env.get().str("project");
        tui.current().rdr.set_terminal_working_directory(project);
        if (self.top_bar) |bar| _ = try bar.msg(.{ "PRJ", "open" });
        if (self.bottom_bar) |bar| _ = try bar.msg(.{ "PRJ", "open" });
    }
    pub const open_project_dir_meta = .{ .arguments = &.{.string} };

    pub fn change_project(self: *Self, ctx: Ctx) Result {
        var project_dir: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&project_dir)}))
            return;
        try self.check_all_not_dirty();
        for (self.editors.items) |editor| {
            editor.clear_diagnostics();
            try editor.close_file(.{});
        }
        self.clear_file_stack();
        self.clear_find_in_files_results(.diagnostics);
        if (self.file_list_type == .diagnostics and self.is_panel_view_showing(filelist_view))
            try self.toggle_panel_view(filelist_view, false);
        try project_manager.open(project_dir);
        const project = tp.env.get().str("project");
        tui.current().rdr.set_terminal_working_directory(project);
        if (self.top_bar) |bar| _ = try bar.msg(.{ "PRJ", "open" });
        if (self.bottom_bar) |bar| _ = try bar.msg(.{ "PRJ", "open" });
        if (try project_manager.request_most_recent_file(self.allocator)) |file_path|
            self.show_file_async_and_free(file_path);
    }
    pub const change_project_meta = .{ .arguments = &.{.string} };

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
                    return error.InvalidArgument;
                if (std.mem.eql(u8, field_name, "line")) {
                    if (!try cbor.matchValue(&iter, cbor.extract(&line)))
                        return error.InvalidArgument;
                } else if (std.mem.eql(u8, field_name, "column")) {
                    if (!try cbor.matchValue(&iter, cbor.extract(&column)))
                        return error.InvalidArgument;
                } else if (std.mem.eql(u8, field_name, "file")) {
                    if (!try cbor.matchValue(&iter, cbor.extract(&file)))
                        return error.InvalidArgument;
                } else if (std.mem.eql(u8, field_name, "goto")) {
                    if (!try cbor.matchValue(&iter, cbor.extract_cbor(&goto_args)))
                        return error.InvalidArgument;
                } else {
                    try cbor.skipValue(&iter);
                }
            }
        } else |_| if (ctx.args.match(tp.extract(&file_name)) catch false) {
            file = file_name;
        } else return error.InvalidArgument;

        if (tp.env.get().str("project").len == 0) {
            try open_project_cwd(self, .{});
        }

        const f = project_manager.normalize_file_path(file orelse return);
        const same_file = if (self.get_active_file_path()) |fp| std.mem.eql(u8, fp, f) else false;

        if (!same_file) {
            if (self.get_active_editor()) |editor| {
                try self.check_active_not_dirty();
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
            if (!same_file)
                try project_manager.get_mru_position(f);
        }
        tui.need_render();
    }
    pub const navigate_meta = .{ .arguments = &.{.object} };

    pub fn open_help(self: *Self, _: Ctx) Result {
        tui.reset_drag_context();
        try self.create_editor();
        try command.executeName("open_scratch_buffer", command.fmt(.{ "help.md", @embedFile("help.md") }));
        tui.need_render();
    }
    pub const open_help_meta = .{ .description = "Open help" };

    pub fn open_config(_: *Self, _: Ctx) Result {
        const file_name = try root.get_config_file_name();
        try tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_name } });
    }
    pub const open_config_meta = .{ .description = "Edit configuration file" };

    pub fn restore_session(self: *Self, _: Ctx) Result {
        if (tp.env.get().str("project").len == 0) {
            try open_project_cwd(self, .{});
        }
        try self.create_editor();
        try self.read_restore_info();
        tui.need_render();
    }
    pub const restore_session_meta = .{};

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
    pub const toggle_panel_meta = .{ .description = "Toggle panel" };

    pub fn toggle_logview(self: *Self, _: Ctx) Result {
        try self.toggle_panel_view(logview, false);
    }
    pub const toggle_logview_meta = .{};

    pub fn show_logview(self: *Self, _: Ctx) Result {
        try self.toggle_panel_view(logview, true);
    }
    pub const show_logview_meta = .{ .description = "View log" };

    pub fn toggle_inputview(self: *Self, _: Ctx) Result {
        try self.toggle_panel_view(@import("inputview.zig"), false);
    }
    pub const toggle_inputview_meta = .{ .description = "Toggle raw input log" };

    pub fn toggle_inspector_view(self: *Self, _: Ctx) Result {
        try self.toggle_panel_view(@import("inspector_view.zig"), false);
    }
    pub const toggle_inspector_view_meta = .{ .description = "Toggle inspector view" };

    pub fn show_inspector_view(self: *Self, _: Ctx) Result {
        try self.toggle_panel_view(@import("inspector_view.zig"), true);
    }
    pub const show_inspector_view_meta = .{};

    pub fn jump_back(self: *Self, _: Ctx) Result {
        try self.location_history.back(location_jump);
    }
    pub const jump_back_meta = .{ .description = "Navigate back to previous history location" };

    pub fn jump_forward(self: *Self, _: Ctx) Result {
        try self.location_history.forward(location_jump);
    }
    pub const jump_forward_meta = .{ .description = "Navigate forward to next history location" };

    pub fn show_home(self: *Self, _: Ctx) Result {
        return self.create_home();
    }
    pub const show_home_meta = .{};

    pub fn gutter_mode_next(self: *Self, _: Ctx) Result {
        const tui_ = tui.current();
        var ln = tui_.config.gutter_line_numbers;
        var lnr = tui_.config.gutter_line_numbers_relative;
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
        tui_.config.gutter_line_numbers = ln;
        tui_.config.gutter_line_numbers_relative = lnr;
        try tui_.save_config();
        if (self.widgets.get("editor_gutter")) |gutter_widget| {
            const gutter = gutter_widget.dynamic_cast(@import("editor_gutter.zig")) orelse return;
            gutter.linenum = ln;
            gutter.relative = lnr;
        }
    }
    pub const gutter_mode_next_meta = .{ .description = "Next gutter mode" };

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
    pub const goto_next_file_or_diagnostic_meta = .{ .description = "Navigate to next file or diagnostic location" };

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
    pub const goto_prev_file_or_diagnostic_meta = .{ .description = "Navigate to previous file or diagnostic location" };

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
        })) return error.InvalidArgument;
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
    pub const add_diagnostic_meta = .{ .arguments = &.{ .string, .string, .string, .string, .integer, .integer, .integer, .integer, .integer } };

    pub fn clear_diagnostics(self: *Self, ctx: Ctx) Result {
        var file_path: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&file_path)})) return error.InvalidArgument;
        file_path = project_manager.normalize_file_path(file_path);
        if (self.get_active_editor()) |editor| if (std.mem.eql(u8, file_path, editor.file_path orelse ""))
            editor.clear_diagnostics();

        self.clear_find_in_files_results(.diagnostics);
        if (self.file_list_type == .diagnostics and self.is_panel_view_showing(filelist_view))
            try self.toggle_panel_view(filelist_view, false);
    }
    pub const clear_diagnostics_meta = .{ .arguments = &.{.string} };

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
    pub const show_diagnostics_meta = .{ .description = "Show diagnostics panel" };

    pub fn open_previous_file(self: *Self, _: Ctx) Result {
        const file_path = try project_manager.request_n_most_recent_file(self.allocator, 1);
        self.show_file_async_and_free(file_path orelse return error.Stop);
    }
    pub const open_previous_file_meta = .{ .description = "Open the previous file" };

    pub fn system_paste(_: *Self, _: Ctx) Result {
        if (builtin.os.tag == .windows)
            return command.executeName("paste", .{}) catch {};
        tui.current().rdr.request_system_clipboard();
    }
    pub const system_paste_meta = .{ .description = "Paste from system clipboard" };

    pub fn find_in_files_query(self: *Self, ctx: Ctx) Result {
        var query: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&query)})) return error.InvalidArgument;
        log.logger("find").print("finding files...", .{});
        const find_f = ripgrep.find_in_files;
        if (std.mem.indexOfScalar(u8, query, '\n')) |_| return;
        var rg = try find_f(self.allocator, query, "FIF");
        defer rg.deinit();
    }
    pub const find_in_files_query_meta = .{ .arguments = &.{.string} };
};

pub fn handle_editor_event(self: *Self, _: tp.pid_ref, m: tp.message) tp.result {
    const editor = self.get_active_editor() orelse return;
    var sel: ed.Selection = undefined;

    if (try m.match(.{ "E", "location", tp.more }))
        return self.location_update(m);

    if (try m.match(.{ "E", "close" })) {
        if (self.pop_file_stack(editor.file_path)) |file_path|
            self.show_file_async_and_free(file_path)
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

    if (try m.match(.{ tp.any, tp.any, tp.any, tp.extract(&row), tp.extract(&col) })) {
        if (row == 0 and col == 0) return;
        project_manager.update_mru(file_path, row, col) catch {};
        return self.location_history.update(file_path, .{ .row = row + 1, .col = col + 1 }, null);
    }

    var sel: location_history.Selection = .{};
    if (try m.match(.{ tp.any, tp.any, tp.any, tp.extract(&row), tp.extract(&col), tp.extract(&sel.begin.row), tp.extract(&sel.begin.col), tp.extract(&sel.end.row), tp.extract(&sel.end.col) })) {
        project_manager.update_mru(file_path, row, col) catch {};
        return self.location_history.update(file_path, .{ .row = row + 1, .col = col + 1 }, sel);
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

pub fn walk(self: *Self, ctx: *anyopaque, f: Widget.WalkFn, w: *Widget) bool {
    return self.floating_views.walk(ctx, f) or self.widgets.walk(ctx, f, &self.widgets_widget) or f(ctx, w);
}

fn create_editor(self: *Self) !void {
    if (self.editor) |editor| if (editor.file_path) |file_path| self.push_file_stack(file_path) catch {};
    self.widgets.replace(self.view_widget_idx, try Widget.empty(self.allocator, self.plane, .dynamic));
    command.executeName("enter_mode_default", .{}) catch {};
    var editor_widget = try ed.create(self.allocator, Widget.to(self));
    errdefer editor_widget.deinit(self.allocator);
    if (editor_widget.get("editor")) |editor| {
        if (self.top_bar) |bar| editor.subscribe(EventHandler.to_unowned(bar)) catch @panic("subscribe unsupported");
        if (self.bottom_bar) |bar| editor.subscribe(EventHandler.to_unowned(bar)) catch @panic("subscribe unsupported");
        editor.subscribe(EventHandler.bind(self, handle_editor_event)) catch @panic("subscribe unsupported");
        self.editor = if (editor.dynamic_cast(ed.EditorWidget)) |p| &p.editor else null;
    } else @panic("mainview editor not found");
    self.widgets.replace(self.view_widget_idx, editor_widget);
    tui.current().resize();
}

fn toggle_logview_async(_: *Self) void {
    tp.self_pid().send(.{ "cmd", "toggle_logview" }) catch return;
}

fn toggle_inputview_async(_: *Self) void {
    tp.self_pid().send(.{ "cmd", "toggle_inputview" }) catch return;
}

fn show_file_async_and_free(self: *Self, file_path: []const u8) void {
    defer self.allocator.free(file_path);
    tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_path } }) catch return;
}

fn show_home_async(_: *Self) void {
    tp.self_pid().send(.{ "cmd", "show_home" }) catch return;
}

fn create_home(self: *Self) !void {
    tui.reset_drag_context();
    if (self.editor) |_| return;
    self.widgets.replace(
        self.view_widget_idx,
        try Widget.empty(self.allocator, self.widgets_widget.plane.*, .dynamic),
    );
    self.widgets.replace(
        self.view_widget_idx,
        try home.create(self.allocator, Widget.to(self)),
    );
    tui.current().resize();
}

fn write_restore_info(self: *Self) void {
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
    try editor.extract_state(buf[0..size]);
}

fn push_file_stack(self: *Self, file_path: []const u8) !void {
    for (self.file_stack.items, 0..) |file_path_, i|
        if (std.mem.eql(u8, file_path, file_path_))
            self.allocator.free(self.file_stack.orderedRemove(i));
    (try self.file_stack.addOne()).* = try self.allocator.dupe(u8, file_path);
}

fn pop_file_stack(self: *Self, closed: ?[]const u8) ?[]const u8 {
    if (closed) |file_path|
        for (self.file_stack.items, 0..) |file_path_, i|
            if (std.mem.eql(u8, file_path, file_path_))
                self.allocator.free(self.file_stack.orderedRemove(i));
    return self.file_stack.popOrNull();
}

fn clear_file_stack(self: *Self) void {
    for (self.file_stack.items) |file_path| self.allocator.free(file_path);
    self.file_stack.clearRetainingCapacity();
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
    if (self.find_in_files_done or self.file_list_type != file_list_type) {
        self.clear_find_in_files_results(self.file_list_type);
        self.file_list_type = file_list_type;
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
    self.find_in_files_done = false;
    self.file_list_type = file_list_type;
    fl.reset();
}

fn add_info_content(
    self: *Self,
    begin_line: usize,
    begin_pos: usize,
    end_line: usize,
    end_pos: usize,
    content: []const u8,
) tp.result {
    if (content.len == 0) return;
    if (!self.is_panel_view_showing(info_view))
        _ = self.toggle_panel_view(info_view, false) catch |e| return tp.exit_error(e, @errorReturnTrace());
    const info = self.get_panel_view(info_view) orelse @panic("info_view missing");
    info.set_content(content) catch |e| return tp.exit_error(e, @errorReturnTrace());

    const match: ed.Match = .{ .begin = .{ .row = begin_line, .col = begin_pos }, .end = .{ .row = end_line, .col = end_pos } };
    if (self.get_active_editor()) |editor|
        switch (editor.matches.items.len) {
            0 => {
                (editor.matches.addOne() catch return).* = match;
            },
            1 => {
                editor.matches.items[0] = match;
            },
            else => {},
        };
    tui.need_render();
}
