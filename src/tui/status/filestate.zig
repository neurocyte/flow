const std = @import("std");
const Allocator = std.mem.Allocator;
const nc = @import("notcurses");
const tp = @import("thespian");
const tracy = @import("tracy");
const root = @import("root");

const Widget = @import("../Widget.zig");
const command = @import("../command.zig");
const tui = @import("../tui.zig");

a: Allocator,
parent: nc.Plane,
plane: nc.Plane,
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

const Self = @This();

pub fn create(a: Allocator, parent: nc.Plane) !Widget {
    const self: *Self = try a.create(Self);
    self.* = try init(a, parent);
    self.show_cwd();
    return Widget.to(self);
}

fn init(a: Allocator, parent: nc.Plane) !Self {
    var n = try nc.Plane.init(&(Widget.Box{}).opts(@typeName(Self)), parent);
    errdefer n.deinit();

    return .{
        .a = a,
        .parent = parent,
        .plane = n,
        .name = "",
        .file_type = "",
        .lines = 0,
        .line = 0,
        .column = 0,
        .file_exists = true,
    };
}

pub fn deinit(self: *Self, a: Allocator) void {
    self.plane.deinit();
    a.destroy(self);
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    const frame = tracy.initZone(@src(), .{ .name = @typeName(@This()) ++ " render" });
    defer frame.deinit();
    tui.set_base_style(&self.plane, " ", theme.statusbar);
    self.plane.erase();
    self.plane.home();
    if (tui.current().mini_mode) |_|
        self.render_mini_mode(theme)
    else if (self.detailed)
        self.render_detailed(theme)
    else
        self.render_normal(theme);
    self.render_terminal_title();
    return false;
}

fn render_mini_mode(self: *Self, theme: *const Widget.Theme) void {
    self.plane.off_styles(nc.style.italic);
    const mini_mode = if (tui.current().mini_mode) |m| m else return;
    _ = self.plane.print(" {s}", .{mini_mode.text}) catch {};
    if (mini_mode.cursor) |cursor| {
        const pos: c_int = @intCast(cursor);
        self.plane.cursor_move_yx(0, pos + 1) catch return;
        var cell = self.plane.cell_init();
        _ = self.plane.at_cursor_cell(&cell) catch return;
        tui.set_cell_style(&cell, theme.editor_cursor);
        _ = self.plane.putc(&cell) catch {};
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
fn render_normal(self: *Self, theme: *const Widget.Theme) void {
    self.plane.on_styles(nc.style.italic);
    _ = self.plane.putstr(" ") catch {};
    if (self.file_icon.len > 0) {
        self.render_file_icon(theme);
        _ = self.plane.print(" ", .{}) catch {};
    }
    _ = self.plane.putstr(if (!self.file_exists) "󰽂 " else if (self.file_dirty) "󰆓 " else "") catch {};
    _ = self.plane.print("{s}", .{self.name}) catch {};
    return;
}

fn render_detailed(self: *Self, theme: *const Widget.Theme) void {
    self.plane.on_styles(nc.style.italic);
    _ = self.plane.putstr(" ") catch {};
    if (self.file_icon.len > 0) {
        self.render_file_icon(theme);
        _ = self.plane.print(" ", .{}) catch {};
    }
    _ = self.plane.putstr(if (!self.file_exists) "󰽂" else if (self.file_dirty) "󰆓" else "󱣪") catch {};
    _ = self.plane.print(" {s}:{d}:{d}", .{ self.name, self.line + 1, self.column + 1 }) catch {};
    _ = self.plane.print(" of {d} lines", .{self.lines}) catch {};
    if (self.file_type.len > 0)
        _ = self.plane.print(" ({s})", .{self.file_type}) catch {};
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
    tui.set_terminal_title(self.title);
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
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
    } else if (try m.match(.{ "E", "close" })) {
        self.name = "";
        self.lines = 0;
        self.line = 0;
        self.column = 0;
        self.file_exists = true;
        self.show_cwd();
    }
    if (try m.match(.{ "B", nc.event_type.PRESS, nc.key.BUTTON1, tp.any, tp.any, tp.any, tp.any, tp.any })) {
        self.detailed = !self.detailed;
        return true;
    }
    return false;
}

fn render_file_icon(self: *Self, _: *const Widget.Theme) void {
    var cell = self.plane.cell_init();
    _ = self.plane.at_cursor_cell(&cell) catch return;
    if (self.file_color != 0x000001) {
        nc.channels_set_fg_rgb(&cell.channels, self.file_color) catch {};
        nc.channels_set_fg_alpha(&cell.channels, nc.ALPHA_OPAQUE) catch {};
    }
    _ = self.plane.cell_load(&cell, self.file_icon) catch {};
    _ = self.plane.putc(&cell) catch {};
    self.plane.cursor_move_rel(0, 1) catch {};
}

fn show_cwd(self: *Self) void {
    self.file_icon = "";
    self.file_color = 0x000001;
    self.name = std.fs.cwd().realpath(".", &self.name_buf) catch "(none)";
    self.abbrv_home();
}

fn abbrv_home(self: *Self) void {
    if (std.fs.path.isAbsolute(self.name)) {
        if (std.os.getenv("HOME")) |homedir| {
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
    }
}
