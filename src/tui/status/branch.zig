const std = @import("std");
const tp = @import("thespian");

const EventHandler = @import("EventHandler");
const Plane = @import("renderer").Plane;
const git = @import("git");

const Widget = @import("../Widget.zig");
const MessageFilter = @import("../MessageFilter.zig");
const tui = @import("../tui.zig");

const branch_symbol = "󰘬";

allocator: std.mem.Allocator,
plane: Plane,
branch: ?[]const u8 = null,

const Self = @This();

pub fn create(
    allocator: std.mem.Allocator,
    parent: Plane,
    _: ?EventHandler,
    _: ?[]const u8,
) @import("widget.zig").CreateError!Widget {
    const self: *Self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .plane = try Plane.init(&(Widget.Box{}).opts(@typeName(Self)), parent),
    };
    try tui.message_filters().add(MessageFilter.bind(self, receive_git));
    git.workspace_path() catch {};
    return Widget.to(self);
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    if (self.branch) |p| self.allocator.free(p);
    self.plane.deinit();
    allocator.destroy(self);
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
    if (try match(m.buf, .{ any, "workspace_path", null_ })) {
        self.branch = try self.allocator.dupe(u8, "null");
    } else if (try match(m.buf, .{ any, "workspace_path", string })) {
        git.current_branch() catch {};
    } else if (try match(m.buf, .{ any, "current_branch", extract(&branch) })) {
        if (self.branch) |p| self.allocator.free(p);
        self.branch = try self.allocator.dupe(u8, branch);
    } else {
        return false;
    }
    return true;
}

pub fn layout(self: *Self) Widget.Layout {
    const branch = self.branch orelse return .{ .static = 0 };
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    writer.print("{s} {s}", .{ branch_symbol, branch }) catch {};
    const len = self.plane.egc_chunk_width(fbs.getWritten(), 0, 1);
    return .{ .static = len };
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    const branch = self.branch orelse return false;
    self.plane.set_base_style(theme.editor);
    self.plane.erase();
    self.plane.home();
    self.plane.set_style(theme.statusbar);
    self.plane.fill(" ");
    self.plane.home();
    _ = self.plane.print("{s} {s}", .{ branch_symbol, branch }) catch {};
    return false;
}

const match = cbor.match;
const more = cbor.more;
const null_ = cbor.null_;
const string = cbor.string;
const extract = cbor.extract;
const any = cbor.any;

const cbor = @import("cbor");
