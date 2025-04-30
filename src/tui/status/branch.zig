const std = @import("std");
const tp = @import("thespian");

const EventHandler = @import("EventHandler");
const Plane = @import("renderer").Plane;
const command = @import("command");
const git = @import("git");

const Widget = @import("../Widget.zig");
const Button = @import("../Button.zig");
const MessageFilter = @import("../MessageFilter.zig");
const tui = @import("../tui.zig");

const branch_symbol = "󰘬 ";
const ahead_symbol = "⇡";
const behind_symbol = "⇣";
const stash_symbol = "*";
const changed_symbol = "+";
const untracked_symbol = "?";

allocator: std.mem.Allocator,
workspace_path: ?[]const u8 = null,
branch: ?[]const u8 = null,
ahead: ?[]const u8 = null,
behind: ?[]const u8 = null,
stash: ?[]const u8 = null,
changed: usize = 0,
untracked: usize = 0,
done: bool = true,

const Self = @This();

pub fn create(
    allocator: std.mem.Allocator,
    parent: Plane,
    event_handler: ?EventHandler,
    _: ?[]const u8,
) @import("widget.zig").CreateError!Widget {
    return Button.create_widget(Self, allocator, parent, .{
        .ctx = .{
            .allocator = allocator,
        },
        .label = "",
        .on_click = on_click,
        .on_layout = layout,
        .on_render = render,
        .on_event = event_handler,
    });
}

pub fn ctx_init(self: *Self) error{OutOfMemory}!void {
    try tui.message_filters().add(MessageFilter.bind(self, receive_git));
    git.workspace_path(0) catch {};
}

pub fn ctx_deinit(self: *Self) void {
    tui.message_filters().remove_ptr(self);
    if (self.branch) |p| self.allocator.free(p);
    if (self.ahead) |p| self.allocator.free(p);
    if (self.behind) |p| self.allocator.free(p);
}

fn on_click(_: *Self, _: *Button.State(Self)) void {
    git.status(0) catch {};
    command.executeName("show_git_status", .{}) catch {};
}

fn receive_git(self: *Self, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    return if (try match(m.buf, .{ "git", more }))
        self.process_git(m)
    else
        false;
}

fn process_git(self: *Self, m: tp.message) MessageFilter.Error!bool {
    var value: []const u8 = undefined;
    if (try match(m.buf, .{ any, any, "workspace_path", null_ })) {
        // do nothing, we do not have a git workspace
    } else if (try match(m.buf, .{ any, any, "workspace_path", extract(&value) })) {
        if (self.workspace_path) |p| self.allocator.free(p);
        self.workspace_path = try self.allocator.dupe(u8, value);
        // git.current_branch(0) catch {};
        git.status(0) catch {};
    } else if (try match(m.buf, .{ any, any, "current_branch", extract(&value) })) {
        if (self.branch) |p| self.allocator.free(p);
        self.branch = try self.allocator.dupe(u8, value);
    } else if (try match(m.buf, .{ any, any, "status", tp.more })) {
        return self.process_status(m);
    } else {
        return false;
    }
    return true;
}

fn process_status(self: *Self, m: tp.message) MessageFilter.Error!bool {
    defer if (tui.frames_rendered() > 0)
        Widget.need_render();

    var value: []const u8 = undefined;
    var ahead: []const u8 = undefined;
    var behind: []const u8 = undefined;

    if (self.done) {
        self.done = false;
        self.changed = 0;
        self.untracked = 0;
        if (self.ahead) |p| self.allocator.free(p);
        self.ahead = null;
        if (self.behind) |p| self.allocator.free(p);
        self.behind = null;
        if (self.stash) |p| self.allocator.free(p);
        self.stash = null;
    }

    if (try match(m.buf, .{ any, any, "status", "#", "branch.oid", extract(&value) })) {
        // commit | (initial)
    } else if (try match(m.buf, .{ any, any, "status", "#", "branch.head", extract(&value) })) {
        if (self.branch) |p| self.allocator.free(p);
        self.branch = try self.allocator.dupe(u8, value);
    } else if (try match(m.buf, .{ any, any, "status", "#", "branch.upstream", extract(&value) })) {
        // upstream-branch
    } else if (try match(m.buf, .{ any, any, "status", "#", "branch.ab", extract(&ahead), extract(&behind) })) {
        if (self.ahead) |p| self.allocator.free(p);
        self.ahead = try self.allocator.dupe(u8, ahead);
        if (self.behind) |p| self.allocator.free(p);
        self.behind = try self.allocator.dupe(u8, behind);
    } else if (try match(m.buf, .{ any, any, "status", "#", "stash", extract(&value) })) {
        if (self.stash) |p| self.allocator.free(p);
        self.stash = try self.allocator.dupe(u8, value);
    } else if (try match(m.buf, .{ any, any, "status", "1", tp.more })) {
        // ordinary file: <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
        self.changed += 1;
    } else if (try match(m.buf, .{ any, any, "status", "2", tp.more })) {
        // rename or copy: <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path><sep><origPath>
        self.changed += 1;
    } else if (try match(m.buf, .{ any, any, "status", "u", tp.more })) {
        // unmerged file: <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
        self.changed += 1;
    } else if (try match(m.buf, .{ any, any, "status", "?", tp.more })) {
        // untracked file: <path>
        self.untracked += 1;
    } else if (try match(m.buf, .{ any, any, "status", "!", tp.more })) {
        // ignored file: <path>
    } else if (try match(m.buf, .{ any, any, "status", null_ })) {
        self.done = true;
    } else return false;
    return true;
}

fn format(self: *Self, buf: []u8) []const u8 {
    const branch = self.branch orelse return "";
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    writer.print("   {s}{s}", .{ branch_symbol, branch }) catch {};
    if (self.ahead) |ahead| if (ahead.len > 1 and ahead[1] != '0')
        writer.print(" {s}{s}", .{ ahead_symbol, ahead[1..] }) catch {};
    if (self.behind) |behind| if (behind.len > 1 and behind[1] != '0')
        writer.print(" {s}{s}", .{ behind_symbol, behind[1..] }) catch {};
    if (self.stash) |stash| if (stash.len > 0 and stash[0] != '0')
        writer.print(" {s}{s}", .{ stash_symbol, stash }) catch {};
    if (self.changed > 0)
        writer.print(" {s}{d}", .{ changed_symbol, self.changed }) catch {};
    if (self.untracked > 0)
        writer.print(" {s}{d}", .{ untracked_symbol, self.untracked }) catch {};
    writer.print("   ", .{}) catch {};
    return fbs.getWritten();
}

pub fn layout(self: *Self, btn: *Button.State(Self)) Widget.Layout {
    var buf: [256]u8 = undefined;
    const text = self.format(&buf);
    const len = btn.plane.egc_chunk_width(text, 0, 1);
    return .{ .static = len };
}

pub fn render(self: *Self, btn: *Button.State(Self), theme: *const Widget.Theme) bool {
    var buf: [256]u8 = undefined;
    const text = self.format(&buf);
    if (text.len == 0) return false;
    const bg_style = if (btn.active) theme.editor_cursor else if (btn.hover) theme.statusbar_hover else theme.statusbar;
    btn.plane.set_base_style(theme.editor);
    btn.plane.erase();
    btn.plane.home();
    btn.plane.set_style(bg_style);
    btn.plane.fill(" ");
    btn.plane.home();
    _ = btn.plane.putstr(text) catch {};
    return false;
}

const match = cbor.match;
const more = cbor.more;
const null_ = cbor.null_;
const string = cbor.string;
const extract = cbor.extract;
const any = cbor.any;

const cbor = @import("cbor");
