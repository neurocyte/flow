const std = @import("std");
const Widget = @import("../Widget.zig");
const Plane = @import("renderer").Plane;

const widgets = std.static_string_map.StaticStringMap(CreateFunction).initComptime(.{
    .{ "mode", @import("modestate.zig").create },
    .{ "file", @import("filestate.zig").create },
    .{ "log", @import("minilog.zig").create },
    .{ "selection", @import("selectionstate.zig").create },
    .{ "diagnostics", @import("diagstate.zig").create },
    .{ "linenumber", @import("linenumstate.zig").create },
    .{ "modifiers", @import("modstate.zig").create },
    .{ "keystate", @import("keystate.zig").create },
    .{ "expander", @import("blank.zig").Create(.dynamic) },
    .{ "spacer", @import("blank.zig").Create(.{ .static = 1 }) },
    .{ "clock", @import("clock.zig").create },
});
pub const CreateError = error{ OutOfMemory, Exit };
pub const CreateFunction = *const fn (allocator: std.mem.Allocator, parent: Plane, event_handler: ?Widget.EventHandler) CreateError!Widget;

pub fn create(name: []const u8, allocator: std.mem.Allocator, parent: Plane, event_handler: ?Widget.EventHandler) CreateError!?Widget {
    const create_ = widgets.get(name) orelse return null;
    return try create_(allocator, parent, event_handler);
}
