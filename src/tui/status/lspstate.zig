const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");

const EventHandler = @import("EventHandler");
const Plane = @import("renderer").Plane;
const command = @import("command");
const project_manager = @import("project_manager");

const Widget = @import("../Widget.zig");
const Button = @import("../Button.zig");
const MessageFilter = @import("../MessageFilter.zig");
const tui = @import("../tui.zig");

const LspStatus = project_manager.LspStatus;

allocator: std.mem.Allocator,
servers: std.StringHashMapUnmanaged(LspStatus) = .empty,

const Self = @This();
const ButtonType = Button.Options(Self).ButtonType;

pub fn create(
    allocator: std.mem.Allocator,
    parent: Plane,
    event_handler: ?EventHandler,
    _: ?[]const u8,
) @import("widget.zig").CreateError!Widget {
    return Button.create_widget(Self, allocator, parent, .{
        .ctx = .{ .allocator = allocator },
        .label = "",
        .on_click = on_click,
        .on_layout = layout,
        .on_render = render,
        .on_event = event_handler,
    });
}

pub fn ctx_init(self: *Self) error{OutOfMemory}!void {
    try tui.message_filters().add(MessageFilter.bind(self, receive_filter));
    project_manager.subscribe_lsp_status() catch {};
}

pub fn ctx_deinit(self: *Self) void {
    project_manager.unsubscribe_lsp_status() catch {};
    tui.message_filters().remove_ptr(self);
    var i = self.servers.iterator();
    while (i.next()) |p| self.allocator.free(p.key_ptr.*);
    self.servers.deinit(self.allocator);
}

fn on_click(_: *Self, _: *ButtonType, _: Widget.Pos) void {
    command.executeName("restart_language_server", .empty()) catch {};
}

fn receive_filter(self: *Self, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    var lsp_name: []const u8 = undefined;
    var status: LspStatus = undefined;
    if (try cbor.match(m.buf, .{ "lsp_status", tp.any, tp.extract(&lsp_name), tp.extract(&status) })) {
        try self.set(lsp_name, status);
        if (tui.frames_rendered() > 0)
            Widget.need_render();
        return true;
    }
    if (try cbor.match(m.buf, .{ "PRJ", "open_done", tp.more })) {
        project_manager.subscribe_lsp_status() catch {};
        return false;
    }
    return false;
}

fn set(self: *Self, lsp_name: []const u8, status: LspStatus) error{OutOfMemory}!void {
    const gop = try self.servers.getOrPut(self.allocator, lsp_name);
    if (!gop.found_existing)
        gop.key_ptr.* = try self.allocator.dupe(u8, lsp_name);
    gop.value_ptr.* = status;
}

const Overall = struct { status: ?LspStatus = null, name: []const u8 = "", problems: usize = 0 };

fn overall(self: *Self) Overall {
    var result: Overall = .{};
    var i = self.servers.iterator();
    while (i.next()) |p| {
        const status = p.value_ptr.*;
        switch (status) {
            .running => {},
            else => result.problems += 1,
        }
        if (@intFromEnum(status) > @intFromEnum(result.status orelse .starting)) {
            result.status = status;
            result.name = p.key_ptr.*;
        }
    }
    return result;
}

fn symbol(status: LspStatus) []const u8 {
    return switch (status) {
        .running, .starting => "󰒋 ",
        else => "󰅚 ",
    };
}

fn format(self: *Self, buf: []u8) []const u8 {
    const o = self.overall();
    const status = o.status orelse return "";
    var writer: std.Io.Writer = .fixed(buf);
    const sym = symbol(status);
    switch (status) {
        .running => writer.print(" {s}", .{sym}) catch {},
        .starting => writer.print(" {s}{s}", .{ sym, o.name }) catch {},
        else => {
            writer.print(" {s}{s}", .{ sym, o.name }) catch {};
            if (o.problems > 1) writer.print(" +{d}", .{o.problems - 1}) catch {};
        },
    }
    writer.print(" ", .{}) catch {};
    return writer.buffered();
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
    switch (self.overall().status orelse .running) {
        .starting => btn.plane.set_style(.{ .fg = theme.editor_warning.fg }),
        .running => btn.plane.set_style(.{ .fg = theme.editor_information.fg }),
        .not_found => {},
        .crashed, .unavailable => btn.plane.set_style(.{ .fg = theme.editor_error.fg }),
    }
    _ = btn.plane.putstr(text) catch {};
    return false;
}
