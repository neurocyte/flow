const std = @import("std");
const Allocator = std.mem.Allocator;
const tp = @import("thespian");
const tracy = @import("tracy");
const root = @import("root");

const Plane = @import("renderer").Plane;
const style = @import("renderer").style;

const Widget = @import("../Widget.zig");
const Button = @import("../Button.zig");
const command = @import("../command.zig");
const tui = @import("../tui.zig");

a: Allocator,
name: []const u8,
name_buf: [512]u8 = undefined,
title: []const u8 = "",
title_buf: [512]u8 = undefined,
file_type: []const u8,
file_type_buf: [64]u8 = undefined,
file_icon: [:0]const u8 = "",
file_icon_buf: [6]u8 = undefined,
file_color: u24 = 0,
line: usize,
lines: usize,
column: usize,
file_exists: bool,
file_dirty: bool = false,
detailed: bool = false,
project: bool = false,

const project_icon = "";
const Self = @This();

pub fn create(a: Allocator, parent: Plane) !Widget {
    const btn = try Button.create(Self, a, parent, .{
        .ctx = .{
            .a = a,
            .name = "",
            .file_type = "",
            .lines = 0,
            .line = 0,
            .column = 0,
            .file_exists = true,
        },
        .label = "",
        .on_click = on_click,
        .on_click2 = on_click2,
        .on_click3 = on_click3,
        .on_layout = layout,
        .on_render = render,
        .on_receive = receive,
    });
    btn.opts.ctx.show_project();
    return Widget.to(btn);
}

fn on_click(_: *Self, _: *Button.State(Self)) void {
    command.executeName("enter_overlay_mode", command.fmt(.{"open_recent"})) catch {};
}

fn on_click2(_: *Self, _: *Button.State(Self)) void {
    command.executeName("close_file", .{}) catch {};
}

fn on_click3(self: *Self, _: *Button.State(Self)) void {
    self.detailed = !self.detailed;
}

pub fn layout(_: *Self, _: *Button.State(Self)) Widget.Layout {
    return .dynamic;
}

pub fn render(self: *Self, btn: *Button.State(Self), theme: *const Widget.Theme) bool {
    const frame = tracy.initZone(@src(), .{ .name = @typeName(@This()) ++ " render" });
    defer frame.deinit();
    btn.plane.set_base_style(" ", if (btn.active) theme.editor_cursor else theme.statusbar);
    btn.plane.erase();
    btn.plane.home();
    if (tui.current().mini_mode) |_|
        render_mini_mode(&btn.plane, theme)
    else if (self.detailed)
        self.render_detailed(&btn.plane, theme)
    else
        self.render_normal(&btn.plane, theme);
    self.render_terminal_title();
    return false;
}

fn render_mini_mode(plane: *Plane, theme: *const Widget.Theme) void {
    plane.off_styles(style.italic);
    const mini_mode = if (tui.current().mini_mode) |m| m else return;
    _ = plane.print(" {s}", .{mini_mode.text}) catch {};
    if (mini_mode.cursor) |cursor| {
        const pos: c_int = @intCast(cursor);
        plane.cursor_move_yx(0, pos + 1) catch return;
        var cell = plane.cell_init();
        _ = plane.at_cursor_cell(&cell) catch return;
        cell.set_style(theme.editor_cursor);
        _ = plane.putc(&cell) catch {};
    }
    return;
}

// 󰆓 Content save
// 󰽂 Content save alert
// 󰳻 Content save edit
// 󰘛 Content save settings
// 󱙃 Content save off
// 󱣪 Content save check
// 󱑛 Content save cog
// 󰆔 Content save all
fn render_normal(self: *Self, plane: *Plane, theme: *const Widget.Theme) void {
    plane.on_styles(style.italic);
    _ = plane.putstr(" ") catch {};
    if (self.file_icon.len > 0) {
        self.render_file_icon(plane, theme);
        _ = plane.print(" ", .{}) catch {};
    }
    _ = plane.putstr(if (!self.file_exists) "󰽂 " else if (self.file_dirty) "󰆓 " else "") catch {};
    _ = plane.print("{s}", .{self.name}) catch {};
    return;
}

fn render_detailed(self: *Self, plane: *Plane, theme: *const Widget.Theme) void {
    plane.on_styles(style.italic);
    _ = plane.putstr(" ") catch {};
    if (self.file_icon.len > 0) {
        self.render_file_icon(plane, theme);
        _ = plane.print(" ", .{}) catch {};
    }
    if (self.project) {
        const project_name = tp.env.get().str("project");
        _ = plane.print("{s} ({s})", .{ self.name, project_name }) catch {};
    } else {
        _ = plane.putstr(if (!self.file_exists) "󰽂" else if (self.file_dirty) "󰆓" else "󱣪") catch {};
        _ = plane.print(" {s}:{d}:{d}", .{ self.name, self.line + 1, self.column + 1 }) catch {};
        _ = plane.print(" of {d} lines", .{self.lines}) catch {};
        if (self.file_type.len > 0)
            _ = plane.print(" ({s})", .{self.file_type}) catch {};
    }
    return;
}

fn render_terminal_title(self: *Self) void {
    const file_name = if (std.mem.lastIndexOfScalar(u8, self.name, '/')) |pos|
        self.name[pos + 1 ..]
    else if (self.name.len == 0)
        root.application_name
    else
        self.name;
    var new_title_buf: [512]u8 = undefined;
    const new_title = std.fmt.bufPrint(&new_title_buf, "{s}{s}", .{ if (!self.file_exists) "◌ " else if (self.file_dirty) " " else "", file_name }) catch return;
    if (std.mem.eql(u8, self.title, new_title)) return;
    @memcpy(self.title_buf[0..new_title.len], new_title);
    self.title = self.title_buf[0..new_title.len];
    tui.current().rdr.set_terminal_title(self.title);
}

pub fn receive(self: *Self, _: *Button.State(Self), _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    var file_path: []const u8 = undefined;
    var file_type: []const u8 = undefined;
    var file_icon: []const u8 = undefined;
    var file_dirty: bool = undefined;
    if (try m.match(.{ "E", "pos", tp.extract(&self.lines), tp.extract(&self.line), tp.extract(&self.column) }))
        return false;
    if (try m.match(.{ "E", "dirty", tp.extract(&file_dirty) })) {
        self.file_dirty = file_dirty;
    } else if (try m.match(.{ "E", "save", tp.extract(&file_path) })) {
        @memcpy(self.name_buf[0..file_path.len], file_path);
        self.name = self.name_buf[0..file_path.len];
        self.file_exists = true;
        self.file_dirty = false;
        self.abbrv_home();
    } else if (try m.match(.{ "E", "open", tp.extract(&file_path), tp.extract(&self.file_exists), tp.extract(&file_type), tp.extract(&file_icon), tp.extract(&self.file_color) })) {
        @memcpy(self.name_buf[0..file_path.len], file_path);
        self.name = self.name_buf[0..file_path.len];
        @memcpy(self.file_type_buf[0..file_type.len], file_type);
        self.file_type = self.file_type_buf[0..file_type.len];
        @memcpy(self.file_icon_buf[0..file_icon.len], file_icon);
        self.file_icon_buf[file_icon.len] = 0;
        self.file_icon = self.file_icon_buf[0..file_icon.len :0];
        self.file_dirty = false;
        self.abbrv_home();
        self.project = false;
    } else if (try m.match(.{ "E", "close" })) {
        self.name = "";
        self.lines = 0;
        self.line = 0;
        self.column = 0;
        self.file_exists = true;
        self.show_project();
    }
    return false;
}

fn render_file_icon(self: *Self, plane: *Plane, _: *const Widget.Theme) void {
    var cell = plane.cell_init();
    _ = plane.at_cursor_cell(&cell) catch return;
    if (!(self.file_color == 0xFFFFFF or self.file_color == 0x000000 or self.file_color == 0x000001)) {
        cell.set_fg_rgb(self.file_color) catch {};
    }
    _ = plane.cell_load(&cell, self.file_icon) catch {};
    _ = plane.putc(&cell) catch {};
    plane.cursor_move_rel(0, 1) catch {};
}

fn show_project(self: *Self) void {
    self.file_icon = project_icon;
    self.file_color = 0x000001;
    const project_name = tp.env.get().str("project");
    @memcpy(self.name_buf[0..project_name.len], project_name);
    self.name = self.name_buf[0..project_name.len];
    self.abbrv_home();
    self.project = true;
}

fn abbrv_home(self: *Self) void {
    if (!std.fs.path.isAbsolute(self.name)) return;
    const homedir = std.posix.getenv("HOME") orelse return;
    const homerelpath = std.fs.path.relative(self.a, homedir, self.name) catch return;
    if (homerelpath.len == 0) {
        self.name = "~";
    } else if (homerelpath.len > 3 and std.mem.eql(u8, homerelpath[0..3], "../")) {
        return;
    } else {
        self.name_buf[0] = '~';
        self.name_buf[1] = '/';
        @memcpy(self.name_buf[2 .. homerelpath.len + 2], homerelpath);
        self.name = self.name_buf[0 .. homerelpath.len + 2];
    }
}
