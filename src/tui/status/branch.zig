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

const branch_symbol = "󰘬";

allocator: std.mem.Allocator,
branch: ?[]const u8 = null,
branch_buf: [512]u8 = undefined,

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
}

fn on_click(_: *Self, _: *Button.State(Self)) void {
    command.executeName("show_git_status", .{}) catch {};
}

fn receive_git(self: *Self, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    return if (try match(m.buf, .{ "git", more }))
        self.process_git(m)
    else
        false;
}

fn process_git(
    self: *Self,
    m: tp.message,
) MessageFilter.Error!bool {
    var branch: []const u8 = undefined;
    if (try match(m.buf, .{ any, any, "workspace_path", null_ })) {
        // do nothing, we do not have a git workspace
    } else if (try match(m.buf, .{ any, any, "workspace_path", string })) {
        git.current_branch(0) catch {};
    } else if (try match(m.buf, .{ any, any, "current_branch", extract(&branch) })) {
        if (self.branch) |p| self.allocator.free(p);
        self.branch = try self.allocator.dupe(u8, branch);
    } else {
        return false;
    }
    return true;
}

const format = "   {s} {s}   ";

pub fn layout(self: *Self, btn: *Button.State(Self)) Widget.Layout {
    const branch = self.branch orelse return .{ .static = 0 };
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    writer.print(format, .{ branch_symbol, branch }) catch {};
    const len = btn.plane.egc_chunk_width(fbs.getWritten(), 0, 1);
    return .{ .static = len };
}

pub fn render(self: *Self, btn: *Button.State(Self), theme: *const Widget.Theme) bool {
    const branch = self.branch orelse return false;
    const bg_style = if (btn.active) theme.editor_cursor else if (btn.hover) theme.statusbar_hover else theme.statusbar;
    btn.plane.set_base_style(theme.editor);
    btn.plane.erase();
    btn.plane.home();
    btn.plane.set_style(bg_style);
    btn.plane.fill(" ");
    btn.plane.home();
    _ = btn.plane.print(format, .{ branch_symbol, branch }) catch {};
    return false;
}

const match = cbor.match;
const more = cbor.more;
const null_ = cbor.null_;
const string = cbor.string;
const extract = cbor.extract;
const any = cbor.any;

const cbor = @import("cbor");
