const Buffer = @import("Buffer.zig");
const Cursor = @import("Cursor.zig");
const Selection = @import("Selection.zig");
const Metrics = Buffer.Metrics;

sel: Selection,
tabs: ?Tabs = null,

const Self = @This();

const Tabs = struct {
    before: Buffer.Root,
    after: Buffer.Root,
    metrics: Metrics,
    from_pos: usize,
    to_pos: usize,
};

pub fn insert(sel: Selection, before: Buffer.Root, after: Buffer.Root, metrics: Metrics) Self {
    return .{ .sel = sel, .tabs = tabs_after(sel.begin, sel.end, before, after, metrics) };
}

pub fn delete(sel: Selection, before: Buffer.Root, after: Buffer.Root, metrics: Metrics) Self {
    return .{ .sel = sel, .tabs = tabs_after(sel.end, sel.begin, before, after, metrics) };
}

fn tabs_after(from: Cursor, to: Cursor, before: Buffer.Root, after: Buffer.Root, metrics: Metrics) ?Tabs {
    if (!has_tab_after(before, from, metrics)) return null;
    return .{
        .before = before,
        .after = after,
        .metrics = metrics,
        .from_pos = before.get_line_width_to_pos(from.row, from.col, metrics) catch return null,
        .to_pos = after.get_line_width_to_pos(to.row, to.col, metrics) catch return null,
    };
}

fn has_tab_after(root: Buffer.Root, from: Cursor, metrics: Metrics) bool {
    const Ctx = struct {
        col: usize,
        wcwidth: usize = 0,
        found: bool = false,
        fn walker(ctx_: *anyopaque, egc: []const u8, wcwidth: usize, _: Metrics) Buffer.Walker {
            const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
            if (egc[0] == '\n') return Buffer.Walker.stop;
            if (egc[0] == '\t' and ctx.wcwidth >= ctx.col) {
                ctx.found = true;
                return Buffer.Walker.stop;
            }
            ctx.wcwidth += wcwidth;
            return Buffer.Walker.keep_walking;
        }
    };
    var ctx: Ctx = .{ .col = from.col };
    root.walk_egc_forward(from.row, Ctx.walker, &ctx, metrics) catch return false;
    return ctx.found;
}

/// move a cursor that is at or right of `from` on the same row to keep its distance to `to`
pub fn follow(self: Self, cursor: *Cursor, from: Cursor, to: Cursor) void {
    if (self.tabs) |tabs| blk: {
        const pos = tabs.before.get_line_width_to_pos(from.row, cursor.col, tabs.metrics) catch break :blk;
        if (pos < tabs.from_pos) break :blk;
        cursor.col = tabs.after.pos_to_width(to.row, tabs.to_pos + pos - tabs.from_pos, tabs.metrics) catch break :blk;
        cursor.row = to.row;
        return;
    }
    cursor.col = cursor.col - from.col + to.col;
    cursor.row = to.row;
}
