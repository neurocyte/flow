pub const SDoc = @import("SDoc.zig");
pub const RDoc = @import("RDoc.zig");
pub const render = @import("render.zig");
pub const markdown = @import("markdown.zig");
pub const debug = @import("debug.zig");

test {
    _ = @import("markdown_test.zig");
    _ = @import("render_test.zig");
    _ = RDoc;
}
