const std = @import("std");
const tp = @import("thespian");

const EventHandler = @import("EventHandler");
const Plane = @import("renderer").Plane;
const command = @import("command");
const project_manager = @import("project_manager");
const VcsStatus = @import("VcsStatus");

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
status: VcsStatus = .{},

const Self = @This();
const ButtonType = Button.Options(Self).ButtonType;

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
        .on_receive = receive,
        .on_event = event_handler,
    });
}

pub fn ctx_init(self: *Self) error{OutOfMemory}!void {
    try tui.message_filters().add(MessageFilter.bind(self, receive_filter));
    project_manager.request_vcs_status() catch {};
}

pub fn ctx_deinit(self: *Self) void {
    tui.message_filters().remove_ptr(self);
    self.status.reset(self.allocator);
}

fn on_click(self: *Self, _: *ButtonType, _: Widget.Pos) void {
    self.refresh_vcs_status();
    command.executeName("show_vcs_status", .{}) catch {};
}

fn refresh_vcs_status(self: *Self) void {
    if (self.status.branch) |_| project_manager.request_vcs_status() catch {};
}

pub fn receive(self: *Self, _: *ButtonType, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (try m.match(.{ "E", tp.more }))
        return self.process_event(m);
    if (try m.match(.{ "PRJ", "open" }))
        project_manager.request_vcs_status() catch {};
    return false;
}

fn process_event(self: *Self, m: tp.message) error{Exit}!bool {
    if (try m.match(.{ tp.any, "dirty", tp.more }) or
        try m.match(.{ tp.any, "save", tp.more }) or
        try m.match(.{ tp.any, "open", tp.more }) or
        try m.match(.{ tp.any, "close" }))
        self.refresh_vcs_status();
    return false;
}

fn receive_filter(self: *Self, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    return if (try match(m.buf, .{ "vcs_status", tp.more }))
        self.process_vcs_status(m)
    else if (try match(m.buf, .{"focus_in"}))
        self.process_focus_in()
    else
        false;
}

fn process_focus_in(self: *Self) MessageFilter.Error!bool {
    self.refresh_vcs_status();
    return false;
}

fn process_vcs_status(self: *Self, m: tp.message) MessageFilter.Error!bool {
    defer if (tui.frames_rendered() > 0)
        Widget.need_render();

    var status: VcsStatus = .{};
    self.status.reset(self.allocator);
    if (!try match(m.buf, .{ any, extract(&status) })) return true;

    if (status.branch) |branch| self.status.branch = try self.allocator.dupe(u8, branch);
    if (status.ahead) |ahead| self.status.ahead = try self.allocator.dupe(u8, ahead);
    if (status.behind) |behind| self.status.behind = try self.allocator.dupe(u8, behind);
    if (status.stash) |stash| self.status.stash = try self.allocator.dupe(u8, stash);

    return true;
}

fn format(self: *Self, buf: []u8) []const u8 {
    const branch = self.status.branch orelse return "";
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    writer.print("   {s}{s}", .{ branch_symbol, branch }) catch {};
    if (self.status.ahead) |ahead| if (ahead.len > 1 and ahead[1] != '0')
        writer.print(" {s}{s}", .{ ahead_symbol, ahead[1..] }) catch {};
    if (self.status.behind) |behind| if (behind.len > 1 and behind[1] != '0')
        writer.print(" {s}{s}", .{ behind_symbol, behind[1..] }) catch {};
    if (self.status.stash) |stash| if (stash.len > 0 and stash[0] != '0')
        writer.print(" {s}{s}", .{ stash_symbol, stash }) catch {};
    if (self.status.changed > 0)
        writer.print(" {s}{d}", .{ changed_symbol, self.status.changed }) catch {};
    if (self.status.untracked > 0)
        writer.print(" {s}{d}", .{ untracked_symbol, self.status.untracked }) catch {};
    writer.print("   ", .{}) catch {};
    return fbs.getWritten();
}

pub fn layout(self: *Self, btn: *ButtonType) Widget.Layout {
    var buf: [256]u8 = undefined;
    const text = self.format(&buf);
    const len = btn.plane.egc_chunk_width(text, 0, 1);
    return .{ .static = len };
}

pub fn render(self: *Self, btn: *ButtonType, theme: *const Widget.Theme) bool {
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
