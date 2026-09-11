const std = @import("std");
const Plane = @import("renderer").Plane;
const Panel = @import("Panel.zig");

const modules = .{
    @import("filelist_view.zig"),
    @import("logview.zig"),
    @import("inspector_view.zig"),
    @import("inputview.zig"),
    @import("keybindview.zig"),
};

pub fn restore(allocator: std.mem.Allocator, parent: Plane, tag: []const u8, state: []const u8) ?Panel {
    inline for (modules) |m| if (std.mem.eql(u8, tag, m.panel_tag)) {
        if (@hasDecl(m, "panel_restore"))
            return m.panel_restore(allocator, parent, state) catch |e| {
                std.log.debug("panel_registry: restore {s} failed: {}", .{ tag, e });
                return null;
            };
        return m.create(allocator, parent, .empty()) catch |e| {
            std.log.debug("panel_registry: create {s} failed: {}", .{ tag, e });
            return null;
        };
    };
    return null;
}
