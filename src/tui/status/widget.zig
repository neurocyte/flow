const std = @import("std");
const Widget = @import("../Widget.zig");
const Plane = @import("renderer").Plane;

const widgets = std.static_string_map.StaticStringMap(create_fn).initComptime(.{
    .{ "mode", @import("modestate.zig").create },
    .{ "file", @import("filestate.zig").create },
    .{ "log", @import("minilog.zig").create },
    .{ "selection", @import("selectionstate.zig").create },
    .{ "diagnostics", @import("diagstate.zig").create },
    .{ "linenumber", @import("linenumstate.zig").create },
    .{ "modifiers", @import("modstate.zig").create },
    .{ "keystate", @import("keystate.zig").create },
    .{ "expander", @import("expander.zig").create },
    .{ "spacer", @import("spacer.zig").create },
});
pub const CreateError = error{ OutOfMemory, Exit };
const create_fn = *const fn (a: std.mem.Allocator, parent: Plane, event_handler: ?Widget.EventHandler) CreateError!Widget;

pub fn create(name: []const u8, a: std.mem.Allocator, parent: Plane, event_handler: ?Widget.EventHandler) CreateError!?Widget {
    const create_ = widgets.get(name) orelse return null;
    return try create_(a, parent, event_handler);
}
