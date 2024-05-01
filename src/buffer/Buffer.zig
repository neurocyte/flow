const std = @import("std");
const Plane = @import("renderer").Plane;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const cwd = std.fs.cwd;

const Self = @This();

const default_leaf_capacity = 64;
const max_imbalance = 7;
pub const Root = *const Node;
pub const unicode = @import("unicode.zig");

pub const Cursor = @import("Cursor.zig");
pub const View = @import("View.zig");
pub const Selection = @import("Selection.zig");
pub const MetaWriter = std.ArrayList(u8).Writer;

arena: std.heap.ArenaAllocator,
a: Allocator,
external_a: Allocator,
root: Root,
file_path: []const u8 = "",
last_save: ?Root = null,
file_exists: bool = true,

undo_history: ?*UndoNode = null,
redo_history: ?*UndoNode = null,
curr_history: ?*UndoNode = null,

const UndoNode = struct {
    root: Root,
    next: ?*UndoNode = null,
    branches: ?*UndoBranch = null,
    meta: []const u8,
};

const UndoBranch = struct {
    redo: *UndoNode,
    next: ?*UndoBranch,
};

pub const WalkerMut = struct {
    keep_walking: bool = false,
    found: bool = false,
    replace: ?Root = null,
    err: ?anyerror = null,

    pub const keep_walking = WalkerMut{ .keep_walking = true };
    pub const stop = WalkerMut{ .keep_walking = false };
    pub const found = WalkerMut{ .found = true };

    const F = *const fn (ctx: *anyopaque, leaf: *const Leaf, plane: Plane) WalkerMut;
};

pub const Walker = struct {
    keep_walking: bool = false,
    found: bool = false,
    err: ?anyerror = null,

    pub const keep_walking = Walker{ .keep_walking = true };
    pub const stop = Walker{ .keep_walking = false };
    pub const found = Walker{ .found = true };

    const F = *const fn (ctx: *anyopaque, leaf: *const Leaf, plane: Plane) Walker;
};

pub const Weights = struct {
    bols: u32 = 0,
    eols: u32 = 0,
    len: u32 = 0,
    depth: u32 = 1,

    fn add(self: *Weights, other: Weights) void {
        self.bols += other.bols;
        self.eols += other.eols;
        self.len += other.len;
        self.depth = @max(self.depth, other.depth);
    }
};

pub const Branch = struct {
    left: *const Node,
    right: *const Node,
    weights: Weights,
    weights_sum: Weights,

    const walker = *const fn (ctx: *anyopaque, branch: *const Branch) WalkerMut;

    fn is_balanced(self: *const Branch) bool {
        const left: isize = @intCast(self.left.weights_sum().depth);
        const right: isize = @intCast(self.right.weights_sum().depth);
        return @abs(left - right) < max_imbalance;
    }

    fn merge_results_const(_: *const Branch, left: Walker, right: Walker) Walker {
        var result = Walker{};
        result.err = if (left.err) |_| left.err else right.err;
        result.keep_walking = left.keep_walking and right.keep_walking;
        result.found = left.found or right.found;
        return result;
    }

    fn merge_results(self: *const Branch, a: Allocator, left: WalkerMut, right: WalkerMut) WalkerMut {
        var result = WalkerMut{};
        result.err = if (left.err) |_| left.err else right.err;
        if (left.replace != null or right.replace != null) {
            const new_left = if (left.replace) |p| p else self.left;
            const new_right = if (right.replace) |p| p else self.right;
            result.replace = if (new_left.is_empty())
                new_right
            else if (new_right.is_empty())
                new_left
            else
                Node.new(a, new_left, new_right) catch |e| return .{ .err = e };
        }
        result.keep_walking = left.keep_walking and right.keep_walking;
        result.found = left.found or right.found;
        return result;
    }
};

pub const Leaf = struct {
    buf: []const u8,
    bol: bool = true,
    eol: bool = true,

    fn new(a: Allocator, piece: []const u8, bol: bool, eol: bool) !*const Node {
        if (piece.len == 0)
            return if (!bol and !eol) &empty_leaf else if (bol and !eol) &empty_bol_leaf else if (!bol and eol) &empty_eol_leaf else &empty_line_leaf;
        const node = try a.create(Node);
        node.* = .{ .leaf = .{ .buf = piece, .bol = bol, .eol = eol } };
        return node;
    }

    inline fn weights(self: *const Leaf) Weights {
        var len = self.buf.len;
        if (self.eol)
            len += 1;
        return .{ .bols = if (self.bol) 1 else 0, .eols = if (self.eol) 1 else 0, .len = @intCast(len) };
    }

    inline fn is_empty(self: *const Leaf) bool {
        return self.buf.len == 0 and !self.bol and !self.eol;
    }

    fn pos_to_width(self: *const Leaf, pos: *usize, abs_col_: usize, plane: Plane) usize {
        var col: usize = 0;
        var abs_col = abs_col_;
        var cols: c_int = 0;
        var buf = self.buf;
        while (buf.len > 0 and pos.* > 0) {
            if (buf[0] == '\t') {
                cols = @intCast(8 - (abs_col % 8));
                buf = buf[1..];
                pos.* -= 1;
            } else {
                const bytes = plane.egc_length(buf, &cols, abs_col);
                buf = buf[bytes..];
                pos.* -= bytes;
            }
            col += @intCast(cols);
            abs_col += @intCast(cols);
        }
        return col;
    }

    fn width(self: *const Leaf, abs_col: usize, plane: Plane) usize {
        var pos: usize = std.math.maxInt(usize);
        return self.pos_to_width(&pos, abs_col, plane);
    }

    inline fn width_to_pos(self: *const Leaf, col_: usize, abs_col_: usize, plane: Plane) !usize {
        var abs_col = abs_col_;
        var col = col_;
        var cols: c_int = 0;
        var buf = self.buf;
        return while (buf.len > 0) {
            if (col == 0)
                break @intFromPtr(buf.ptr) - @intFromPtr(self.buf.ptr);
            const bytes = plane.egc_length(buf, &cols, abs_col);
            buf = buf[bytes..];
            if (col < cols)
                break @intFromPtr(buf.ptr) - @intFromPtr(self.buf.ptr);
            col -= @intCast(cols);
            abs_col += @intCast(cols);
        } else error.BufferUnderrun;
    }

    inline fn dump(self: *const Leaf, l: *ArrayList(u8), abs_col: usize, plane: Plane) !void {
        var buf: [16]u8 = undefined;
        const wcwidth = try std.fmt.bufPrint(&buf, "{d}", .{self.width(abs_col, plane)});
        if (self.bol)
            try l.appendSlice("BOL ");
        try l.appendSlice(wcwidth);
        try l.append('"');
        try debug_render_chunk(self.buf, l, plane);
        try l.appendSlice("\" ");
        if (self.eol)
            try l.appendSlice("EOL ");
    }

    fn debug_render_chunk(chunk: []const u8, l: *ArrayList(u8), plane: Plane) !void {
        var cols: c_int = 0;
        var buf = chunk;
        while (buf.len > 0) {
            switch (buf[0]) {
                '\x00'...(' ' - 1) => {
                    const control = unicode.control_code_to_unicode(buf[0]);
                    try l.appendSlice(control);
                    buf = buf[1..];
                },
                else => {
                    const bytes = plane.egc_length(buf, &cols, 0);
                    var buf_: [4096]u8 = undefined;
                    try l.appendSlice(try std.fmt.bufPrint(&buf_, "{s}", .{std.fmt.fmtSliceEscapeLower(buf[0..bytes])}));
                    buf = buf[bytes..];
                },
            }
        }
    }
};

const empty_leaf: Node = .{ .leaf = .{ .buf = "", .bol = false, .eol = false } };
const empty_bol_leaf: Node = .{ .leaf = .{ .buf = "", .bol = true, .eol = false } };
const empty_eol_leaf: Node = .{ .leaf = .{ .buf = "", .bol = false, .eol = true } };
const empty_line_leaf: Node = .{ .leaf = .{ .buf = "", .bol = true, .eol = true } };

const Node = union(enum) {
    node: Branch,
    leaf: Leaf,

    const walker = *const fn (ctx: *anyopaque, node: *const Node) WalkerMut;

    fn new(a: Allocator, l: *const Node, r: *const Node) !*const Node {
        const node = try a.create(Node);
        const l_weights_sum = l.weights_sum();
        var weights_sum_ = Weights{};
        weights_sum_.add(l_weights_sum);
        weights_sum_.add(r.weights_sum());
        weights_sum_.depth += 1;
        node.* = .{ .node = .{ .left = l, .right = r, .weights = l_weights_sum, .weights_sum = weights_sum_ } };
        return node;
    }

    fn weights_sum(self: *const Node) Weights {
        return switch (self.*) {
            .node => |*n| n.weights_sum,
            .leaf => |*l| l.weights(),
        };
    }

    fn depth(self: *const Node) usize {
        return self.weights_sum().depth;
    }

    pub fn lines(self: *const Node) usize {
        return self.weights_sum().bols;
    }

    pub fn length(self: *const Node) usize {
        return self.weights_sum().len;
    }

    pub fn is_balanced(self: *const Node) bool {
        return switch (self.*) {
            .node => |*n| n.is_balanced(),
            .leaf => |_| true,
        };
    }

    pub fn rebalance(self: *const Node, a: Allocator, tmp_a: Allocator) !Root {
        return if (self.is_balanced()) self else bal: {
            const leaves = try self.collect_leaves(tmp_a);
            defer tmp_a.free(leaves);
            break :bal self.merge(leaves, a);
        };
    }

    fn merge(self: *const Node, leaves: []*const Node, a: Allocator) !Root {
        const len = leaves.len;
        if (len == 1) {
            return leaves[0];
        }
        if (len == 2) {
            return Node.new(a, leaves[0], leaves[1]);
        }
        const mid = len / 2;
        return Node.new(a, try self.merge(leaves[0..mid], a), try self.merge(leaves[mid..], a));
    }

    fn is_empty(self: *const Node) bool {
        return switch (self.*) {
            .node => |*n| n.left.is_empty() and n.right.is_empty(),
            .leaf => |*l| if (self == &empty_leaf) true else l.is_empty(),
        };
    }

    fn collect(self: *const Node, l: *ArrayList(*const Node)) !void {
        switch (self.*) {
            .node => |*node| {
                try node.left.collect(l);
                try node.right.collect(l);
            },
            .leaf => (try l.addOne()).* = self,
        }
    }

    fn collect_leaves(self: *const Node, a: Allocator) ![]*const Node {
        var leaves = ArrayList(*const Node).init(a);
        try leaves.ensureTotalCapacity(self.lines());
        try self.collect(&leaves);
        return leaves.toOwnedSlice();
    }

    fn walk_const(self: *const Node, f: Walker.F, ctx: *anyopaque, plane: Plane) Walker {
        switch (self.*) {
            .node => |*node| {
                const left = node.left.walk_const(f, ctx, plane);
                if (!left.keep_walking) {
                    var result = Walker{};
                    result.err = left.err;
                    result.found = left.found;
                    return result;
                }
                const right = node.right.walk_const(f, ctx, plane);
                return node.merge_results_const(left, right);
            },
            .leaf => |*l| return f(ctx, l, plane),
        }
    }

    fn walk(self: *const Node, a: Allocator, f: WalkerMut.F, ctx: *anyopaque, plane: Plane) WalkerMut {
        switch (self.*) {
            .node => |*node| {
                const left = node.left.walk(a, f, ctx, plane);
                if (!left.keep_walking) {
                    var result = WalkerMut{};
                    result.err = left.err;
                    result.found = left.found;
                    if (left.replace) |p| {
                        result.replace = Node.new(a, p, node.right) catch |e| return .{ .err = e };
                    }
                    return result;
                }
                const right = node.right.walk(a, f, ctx, plane);
                return node.merge_results(a, left, right);
            },
            .leaf => |*l| return f(ctx, l, plane),
        }
    }

    fn walk_from_line_begin_const_internal(self: *const Node, line: usize, f: Walker.F, ctx: *anyopaque, plane: Plane) Walker {
        switch (self.*) {
            .node => |*node| {
                const left_bols = node.weights.bols;
                if (line >= left_bols)
                    return node.right.walk_from_line_begin_const_internal(line - left_bols, f, ctx, plane);
                const left_result = node.left.walk_from_line_begin_const_internal(line, f, ctx, plane);
                const right_result = if (left_result.found and left_result.keep_walking) node.right.walk_const(f, ctx, plane) else Walker{};
                return node.merge_results_const(left_result, right_result);
            },
            .leaf => |*l| {
                if (line == 0) {
                    var result = f(ctx, l, plane);
                    if (result.err) |_| return result;
                    result.found = true;
                    return result;
                }
                return Walker.keep_walking;
            },
        }
    }

    pub fn walk_from_line_begin_const(self: *const Node, line: usize, f: Walker.F, ctx: *anyopaque, plane: Plane) !bool {
        const result = self.walk_from_line_begin_const_internal(line, f, ctx, plane);
        if (result.err) |e| return e;
        return result.found;
    }

    fn walk_from_line_begin_internal(self: *const Node, a: Allocator, line: usize, f: WalkerMut.F, ctx: *anyopaque, plane: Plane) WalkerMut {
        switch (self.*) {
            .node => |*node| {
                const left_bols = node.weights.bols;
                if (line >= left_bols) {
                    const right_result = node.right.walk_from_line_begin_internal(a, line - left_bols, f, ctx, plane);
                    if (right_result.replace) |p| {
                        var result = WalkerMut{};
                        result.err = right_result.err;
                        result.found = right_result.found;
                        result.keep_walking = right_result.keep_walking;
                        result.replace = if (p.is_empty())
                            node.left
                        else
                            Node.new(a, node.left, p) catch |e| return .{ .err = e };
                        return result;
                    } else {
                        return right_result;
                    }
                }
                const left_result = node.left.walk_from_line_begin_internal(a, line, f, ctx, plane);
                const right_result = if (left_result.found and left_result.keep_walking) node.right.walk(a, f, ctx, plane) else WalkerMut{};
                return node.merge_results(a, left_result, right_result);
            },
            .leaf => |*l| {
                if (line == 0) {
                    var result = f(ctx, l, plane);
                    if (result.err) |_| {
                        result.replace = null;
                        return result;
                    }
                    result.found = true;
                    return result;
                }
                return WalkerMut.keep_walking;
            },
        }
    }

    pub fn walk_from_line_begin(self: *const Node, a: Allocator, line: usize, f: WalkerMut.F, ctx: *anyopaque, plane: Plane) !struct { bool, ?Root } {
        const result = self.walk_from_line_begin_internal(a, line, f, ctx, plane);
        if (result.err) |e| return e;
        return .{ result.found, result.replace };
    }

    fn find_line_node(self: *const Node, line: usize) ?*const Node {
        switch (self.*) {
            .node => |*node| {
                if (node.weights_sum.bols == 1)
                    return self;
                const left_bols = node.weights.bols;
                if (line >= left_bols)
                    return node.right.find_line_node(line - left_bols);
                return node.left.find_line_node(line);
            },
            .leaf => |*l| {
                return if (l.bol) self else null;
            },
        }
    }

    fn debug_render_tree(self: *const Node, l: *ArrayList(u8), d: usize) void {
        switch (self.*) {
            .node => |*node| {
                l.append('(') catch {};
                node.left.debug_render_tree(l, d + 1);
                l.append(' ') catch {};
                node.right.debug_render_tree(l, d + 1);
                l.append(')') catch {};
            },
            .leaf => |*leaf| {
                l.append('"') catch {};
                l.appendSlice(leaf.buf) catch {};
                if (leaf.eol)
                    l.appendSlice("\\n") catch {};
                l.append('"') catch {};
            },
        }
    }

    const EgcF = *const fn (ctx: *anyopaque, egc: []const u8, wcwidth: usize, plane: Plane) Walker;

    pub fn walk_egc_forward(self: *const Node, line: usize, walker_f: EgcF, walker_ctx: *anyopaque, plane_: Plane) !void {
        const Ctx = struct {
            walker_f: EgcF,
            walker_ctx: @TypeOf(walker_ctx),
            abs_col: usize = 0,
            fn walker(ctx_: *anyopaque, leaf: *const Self.Leaf, plane: Plane) Walker {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                var buf: []const u8 = leaf.buf;
                while (buf.len > 0) {
                    var cols: c_int = undefined;
                    const bytes = plane.egc_length(buf, &cols, ctx.abs_col);
                    const ret = ctx.walker_f(ctx.walker_ctx, buf[0..bytes], @intCast(cols), plane);
                    if (ret.err) |e| return .{ .err = e };
                    buf = buf[bytes..];
                    ctx.abs_col += @intCast(cols);
                    if (!ret.keep_walking) return Walker.stop;
                }
                if (leaf.eol) {
                    const ret = ctx.walker_f(ctx.walker_ctx, "\n", 1, plane);
                    if (ret.err) |e| return .{ .err = e };
                    if (!ret.keep_walking) return Walker.stop;
                    ctx.abs_col = 0;
                }
                return Walker.keep_walking;
            }
        };
        var ctx: Ctx = .{ .walker_f = walker_f, .walker_ctx = walker_ctx };
        const found = try self.walk_from_line_begin_const(line, Ctx.walker, &ctx, plane_);
        if (!found) return error.NotFound;
    }

    pub fn ecg_at(self: *const Node, line: usize, col: usize, plane: Plane) error{NotFound}!struct { []const u8, usize, usize } {
        const ctx_ = struct {
            col: usize,
            at: ?[]const u8 = null,
            wcwidth: usize = 0,
            fn walker(ctx_: *anyopaque, egc: []const u8, wcwidth: usize, _: Plane) Walker {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                ctx.at = egc;
                ctx.wcwidth = wcwidth;
                if (ctx.col == 0 or egc[0] == '\n' or ctx.col < wcwidth)
                    return Walker.stop;
                ctx.col -= wcwidth;
                return Walker.keep_walking;
            }
        };
        var ctx: ctx_ = .{ .col = col };
        self.walk_egc_forward(line, ctx_.walker, &ctx, plane) catch return .{ "?", 1, 0 };
        return if (ctx.at) |at| .{ at, ctx.wcwidth, ctx.col } else error.NotFound;
    }

    pub fn test_at(self: *const Node, pred: *const fn (c: []const u8) bool, line: usize, col: usize, plane: Plane) bool {
        const ecg, _, _ = self.ecg_at(line, col, plane) catch return false;
        return pred(ecg);
    }

    pub fn get_line_width_map(self: *const Node, line: usize, map: *ArrayList(u16), plane: Plane) error{ Stop, NoSpaceLeft }!void {
        const Ctx = struct {
            map: *ArrayList(u16),
            wcwidth: usize = 0,
            fn walker(ctx_: *anyopaque, egc: []const u8, wcwidth: usize, _: Plane) Walker {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                var n = egc.len;
                while (n > 0) : (n -= 1) {
                    const p = ctx.map.addOne() catch |e| return .{ .err = e };
                    p.* = @intCast(ctx.wcwidth);
                }
                ctx.wcwidth += wcwidth;
                return if (egc[0] == '\n') Walker.stop else Walker.keep_walking;
            }
        };
        var ctx: Ctx = .{ .map = map };
        self.walk_egc_forward(line, Ctx.walker, &ctx, plane) catch |e| return switch (e) {
            error.NoSpaceLeft => error.NoSpaceLeft,
            else => error.Stop,
        };
    }

    pub fn get_range(self: *const Node, sel: Selection, copy_buf: ?[]u8, size: ?*usize, wcwidth_: ?*usize, plane_: Plane) error{ Stop, NoSpaceLeft }!?[]u8 {
        const Ctx = struct {
            col: usize = 0,
            sel: Selection,
            out: ?[]u8,
            bytes: usize = 0,
            wcwidth: usize = 0,
            fn walker(ctx_: *anyopaque, egc: []const u8, wcwidth: usize, _: Plane) Walker {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                if (ctx.col < ctx.sel.begin.col) {
                    ctx.col += wcwidth;
                    return Walker.keep_walking;
                }
                if (ctx.out) |out| {
                    if (egc.len > out.len)
                        return .{ .err = error.NoSpaceLeft };
                    @memcpy(out[0..egc.len], egc);
                    ctx.out = out[egc.len..];
                }
                ctx.bytes += egc.len;
                ctx.wcwidth += wcwidth;
                if (egc[0] == '\n') {
                    ctx.col = 0;
                    ctx.sel.begin.col = 0;
                    ctx.sel.begin.row += 1;
                } else {
                    ctx.col += wcwidth;
                    ctx.sel.begin.col += wcwidth;
                }
                return if (ctx.sel.begin.eql(ctx.sel.end) or ctx.sel.begin.right_of(ctx.sel.end))
                    Walker.stop
                else
                    Walker.keep_walking;
            }
        };

        var ctx: Ctx = .{ .sel = sel, .out = copy_buf };
        ctx.sel.normalize();
        if (sel.begin.eql(sel.end))
            return error.Stop;
        self.walk_egc_forward(sel.begin.row, Ctx.walker, &ctx, plane_) catch |e| return switch (e) {
            error.NoSpaceLeft => error.NoSpaceLeft,
            else => error.Stop,
        };
        if (size) |p| p.* = ctx.bytes;
        if (wcwidth_) |p| p.* = ctx.wcwidth;
        return if (copy_buf) |buf_| buf_[0..ctx.bytes] else null;
    }

    pub fn delete_range(self: *const Node, sel: Selection, a: Allocator, size: ?*usize, plane: Plane) error{Stop}!Root {
        var wcwidth: usize = 0;
        _ = self.get_range(sel, null, size, &wcwidth, plane) catch return error.Stop;
        return self.del_chars(sel.begin.row, sel.begin.col, wcwidth, a, plane) catch return error.Stop;
    }

    pub fn del_chars(self: *const Node, line: usize, col: usize, count: usize, a: Allocator, plane_: Plane) !Root {
        const Ctx = struct {
            a: Allocator,
            col: usize,
            abs_col: usize = 0,
            count: usize,
            delete_next_bol: bool = false,
            fn walker(Ctx: *anyopaque, leaf: *const Leaf, plane: Plane) WalkerMut {
                const ctx = @as(*@This(), @ptrCast(@alignCast(Ctx)));
                var result = WalkerMut.keep_walking;
                if (ctx.delete_next_bol and ctx.count == 0) {
                    result.replace = Leaf.new(ctx.a, leaf.buf, false, leaf.eol) catch |e| return .{ .err = e };
                    result.keep_walking = false;
                    ctx.delete_next_bol = false;
                    return result;
                }
                const leaf_wcwidth = leaf.width(ctx.abs_col, plane);
                const leaf_bol = leaf.bol and !ctx.delete_next_bol;
                ctx.delete_next_bol = false;
                const base_col = ctx.abs_col;
                ctx.abs_col += leaf_wcwidth;
                if (ctx.col > leaf_wcwidth) {
                    // next node
                    ctx.col -= leaf_wcwidth;
                    if (leaf.eol)
                        ctx.col -= 1;
                } else {
                    // this node
                    if (ctx.col == 0) {
                        if (ctx.count > leaf_wcwidth) {
                            ctx.count -= leaf_wcwidth;
                            result.replace = Leaf.new(ctx.a, "", leaf_bol, false) catch |e| return .{ .err = e };
                            if (leaf.eol) {
                                ctx.count -= 1;
                                ctx.delete_next_bol = true;
                            }
                        } else if (ctx.count == leaf_wcwidth) {
                            result.replace = Leaf.new(ctx.a, "", leaf_bol, leaf.eol) catch |e| return .{ .err = e };
                            ctx.count = 0;
                        } else {
                            const pos = leaf.width_to_pos(ctx.count, base_col, plane) catch |e| return .{ .err = e };
                            result.replace = Leaf.new(ctx.a, leaf.buf[pos..], leaf_bol, leaf.eol) catch |e| return .{ .err = e };
                            ctx.count = 0;
                        }
                    } else if (ctx.col == leaf_wcwidth) {
                        if (leaf.eol) {
                            ctx.count -= 1;
                            result.replace = Leaf.new(ctx.a, leaf.buf, leaf_bol, false) catch |e| return .{ .err = e };
                            ctx.delete_next_bol = true;
                        }
                        ctx.col -= leaf_wcwidth;
                    } else {
                        if (ctx.col + ctx.count >= leaf_wcwidth) {
                            ctx.count -= leaf_wcwidth - ctx.col;
                            const pos = leaf.width_to_pos(ctx.col, base_col, plane) catch |e| return .{ .err = e };
                            const leaf_eol = if (leaf.eol and ctx.count > 0) leaf_eol: {
                                ctx.count -= 1;
                                ctx.delete_next_bol = true;
                                break :leaf_eol false;
                            } else leaf.eol;
                            result.replace = Leaf.new(ctx.a, leaf.buf[0..pos], leaf_bol, leaf_eol) catch |e| return .{ .err = e };
                            ctx.col = 0;
                        } else {
                            const pos = leaf.width_to_pos(ctx.col, base_col, plane) catch |e| return .{ .err = e };
                            const pos_end = leaf.width_to_pos(ctx.col + ctx.count, base_col, plane) catch |e| return .{ .err = e };
                            const left = Leaf.new(ctx.a, leaf.buf[0..pos], leaf_bol, false) catch |e| return .{ .err = e };
                            const right = Leaf.new(ctx.a, leaf.buf[pos_end..], false, leaf.eol) catch |e| return .{ .err = e };
                            result.replace = Node.new(ctx.a, left, right) catch |e| return .{ .err = e };
                            ctx.count = 0;
                        }
                    }
                    if (ctx.count == 0 and !ctx.delete_next_bol)
                        result.keep_walking = false;
                }
                return result;
            }
        };
        var ctx: Ctx = .{ .a = a, .col = col, .count = count };
        const found, const root = try self.walk_from_line_begin(a, line, Ctx.walker, &ctx, plane_);
        return if (found) (if (root) |r| r else error.Stop) else error.NotFound;
    }

    fn merge_in_place(leaves: []const Node, a: Allocator) !Root {
        const len = leaves.len;
        if (len == 1) {
            return &leaves[0];
        }
        if (len == 2) {
            return Node.new(a, &leaves[0], &leaves[1]);
        }
        const mid = len / 2;
        return Node.new(a, try merge_in_place(leaves[0..mid], a), try merge_in_place(leaves[mid..], a));
    }

    pub fn get_line(self: *const Node, line: usize, result: *ArrayList(u8)) !void {
        const Ctx = struct {
            line: *ArrayList(u8),
            fn walker(ctx_: *anyopaque, leaf: *const Leaf) Walker {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                ctx.line.appendSlice(leaf.buf) catch |e| return .{ .err = e };
                return if (!leaf.eol) Walker.keep_walking else Walker.stop;
            }
        };
        var ctx: Ctx = .{ .line = result };
        const found = self.walk_from_line_begin_const(line, Ctx.walker, &ctx) catch false;
        return if (!found) error.NotFound;
    }

    pub fn line_width(self: *const Node, line: usize, plane_: Plane) !usize {
        const do = struct {
            result: usize = 0,
            fn walker(ctx: *anyopaque, leaf: *const Leaf, plane: Plane) Walker {
                const do = @as(*@This(), @ptrCast(@alignCast(ctx)));
                do.result += leaf.width(do.result, plane);
                return if (!leaf.eol) Walker.keep_walking else Walker.stop;
            }
        };
        var ctx: do = .{};
        const found = self.walk_from_line_begin_const(line, do.walker, &ctx, plane_) catch true;
        return if (found) ctx.result else error.NotFound;
    }

    pub fn pos_to_width(self: *const Node, line: usize, pos: usize, plane_: Plane) !usize {
        const do = struct {
            result: usize = 0,
            pos: usize,
            fn walker(ctx: *anyopaque, leaf: *const Leaf, plane: Plane) Walker {
                const do = @as(*@This(), @ptrCast(@alignCast(ctx)));
                do.result += leaf.pos_to_width(&do.pos, do.result, plane);
                return if (!(leaf.eol or do.pos == 0)) Walker.keep_walking else Walker.stop;
            }
        };
        var ctx: do = .{ .pos = pos };
        const found = self.walk_from_line_begin_const(line, do.walker, &ctx, plane_) catch true;
        return if (found) ctx.result else error.NotFound;
    }

    pub fn insert_chars(
        self_: *const Node,
        line_: usize,
        col_: usize,
        s: []const u8,
        a: Allocator,
        plane_: Plane,
    ) !struct { usize, usize, Root } {
        var self = self_;
        const Ctx = struct {
            a: Allocator,
            col: usize,
            abs_col: usize = 0,
            s: []const u8,
            eol: bool,

            fn walker(ctx: *anyopaque, leaf: *const Leaf, plane: Plane) WalkerMut {
                const Ctx = @as(*@This(), @ptrCast(@alignCast(ctx)));
                const leaf_wcwidth = leaf.width(Ctx.abs_col, plane);
                const base_col = Ctx.abs_col;
                Ctx.abs_col += leaf_wcwidth;

                if (Ctx.col == 0) {
                    const left = Leaf.new(Ctx.a, Ctx.s, leaf.bol, Ctx.eol) catch |e| return .{ .err = e };
                    const right = Leaf.new(Ctx.a, leaf.buf, Ctx.eol, leaf.eol) catch |e| return .{ .err = e };
                    return .{ .replace = Node.new(Ctx.a, left, right) catch |e| return .{ .err = e } };
                }

                if (leaf_wcwidth == Ctx.col) {
                    if (leaf.eol and Ctx.eol and Ctx.s.len == 0) {
                        const left = Leaf.new(Ctx.a, leaf.buf, leaf.bol, true) catch |e| return .{ .err = e };
                        const right = Leaf.new(Ctx.a, Ctx.s, true, true) catch |e| return .{ .err = e };
                        return .{ .replace = Node.new(Ctx.a, left, right) catch |e| return .{ .err = e } };
                    }
                    const left = Leaf.new(Ctx.a, leaf.buf, leaf.bol, false) catch |e| return .{ .err = e };
                    if (Ctx.eol) {
                        const middle = Leaf.new(Ctx.a, Ctx.s, false, Ctx.eol) catch |e| return .{ .err = e };
                        const right = Leaf.new(Ctx.a, "", Ctx.eol, leaf.eol) catch |e| return .{ .err = e };
                        return .{ .replace = Node.new(
                            Ctx.a,
                            left,
                            Node.new(Ctx.a, middle, right) catch |e| return .{ .err = e },
                        ) catch |e| return .{ .err = e } };
                    } else {
                        const right = Leaf.new(Ctx.a, Ctx.s, false, leaf.eol) catch |e| return .{ .err = e };
                        return .{ .replace = Node.new(Ctx.a, left, right) catch |e| return .{ .err = e } };
                    }
                }

                if (leaf_wcwidth > Ctx.col) {
                    const pos = leaf.width_to_pos(Ctx.col, base_col, plane) catch |e| return .{ .err = e };
                    if (Ctx.eol and Ctx.s.len == 0) {
                        const left = Leaf.new(Ctx.a, leaf.buf[0..pos], leaf.bol, Ctx.eol) catch |e| return .{ .err = e };
                        const right = Leaf.new(Ctx.a, leaf.buf[pos..], Ctx.eol, leaf.eol) catch |e| return .{ .err = e };
                        return .{ .replace = Node.new(Ctx.a, left, right) catch |e| return .{ .err = e } };
                    }
                    const left = Leaf.new(Ctx.a, leaf.buf[0..pos], leaf.bol, false) catch |e| return .{ .err = e };
                    const middle = Leaf.new(Ctx.a, Ctx.s, false, Ctx.eol) catch |e| return .{ .err = e };
                    const right = Leaf.new(Ctx.a, leaf.buf[pos..], Ctx.eol, leaf.eol) catch |e| return .{ .err = e };
                    return .{ .replace = Node.new(
                        Ctx.a,
                        left,
                        Node.new(Ctx.a, middle, right) catch |e| return .{ .err = e },
                    ) catch |e| return .{ .err = e } };
                }

                Ctx.col -= leaf_wcwidth;
                return if (leaf.eol) WalkerMut.stop else WalkerMut.keep_walking;
            }
        };
        if (s.len == 0) return error.Stop;
        var rest = try a.dupe(u8, s);
        var chunk = rest;
        var line = line_;
        var col = col_;
        var need_eol = false;
        while (rest.len > 0) {
            if (std.mem.indexOfScalar(u8, rest, '\n')) |eol| {
                chunk = rest[0..eol];
                rest = rest[eol + 1 ..];
                need_eol = true;
            } else {
                chunk = rest;
                rest = &[_]u8{};
                need_eol = false;
            }
            var ctx: Ctx = .{ .a = a, .col = col, .s = chunk, .eol = need_eol };
            const found, const replace = try self.walk_from_line_begin(a, line, Ctx.walker, &ctx, plane_);
            if (!found) return error.NotFound;
            if (replace) |root| self = root;
            if (need_eol) {
                line += 1;
                col = 0;
            } else {
                col += plane_.egc_chunk_width(chunk, col);
            }
        }
        return .{ line, col, self };
    }

    pub fn store(self: *const Node, writer: anytype) !void {
        switch (self.*) {
            .node => |*node| {
                try node.left.store(writer);
                try node.right.store(writer);
            },
            .leaf => |*leaf| {
                _ = try writer.write(leaf.buf);
                if (leaf.eol)
                    _ = try writer.write("\n");
            },
        }
    }

    pub const FindAllCallback = fn (data: *anyopaque, begin_row: usize, begin_col: usize, end_row: usize, end_col: usize) error{Stop}!void;
    pub fn find_all_ranges(self: *const Node, pattern: []const u8, data: *anyopaque, callback: *const FindAllCallback, a: Allocator) !void {
        const Ctx = struct {
            pattern: []const u8,
            data: *anyopaque,
            callback: *const FindAllCallback,
            line: usize = 0,
            pos: usize = 0,
            buf: []u8,
            rest: []u8 = "",
            const Ctx = @This();
            const Writer = std.io.Writer(*Ctx, error{Stop}, write);
            fn write(ctx: *Ctx, bytes: []const u8) error{Stop}!usize {
                var input = bytes;
                while (true) {
                    const input_consume_size = @min(ctx.buf.len - ctx.rest.len, input.len);
                    @memcpy(ctx.buf[ctx.rest.len .. ctx.rest.len + input_consume_size], input[0..input_consume_size]);
                    ctx.rest = ctx.buf[0 .. ctx.rest.len + input_consume_size];
                    input = input[input_consume_size..];

                    if (ctx.rest.len < ctx.pattern.len)
                        return bytes.len - input.len;

                    var i: usize = 0;
                    const end = ctx.rest.len - ctx.pattern.len;

                    while (i <= end) {
                        if (std.mem.eql(u8, ctx.rest[i .. i + ctx.pattern.len], ctx.pattern)) {
                            const begin_row = ctx.line + 1;
                            const begin_pos = ctx.pos;
                            ctx.skip(&i, ctx.pattern.len);
                            const end_row = ctx.line + 1;
                            const end_pos = ctx.pos;
                            try ctx.callback(ctx.data, begin_row, begin_pos, end_row, end_pos);
                        } else {
                            ctx.skip(&i, 1);
                        }
                    }
                    std.mem.copyForwards(u8, ctx.buf, ctx.rest[i..]);
                    ctx.rest = ctx.buf[0 .. ctx.rest.len - i];
                    if (input.len == 0)
                        break;
                    if (ctx.rest.len == ctx.buf.len)
                        unreachable;
                }
                return bytes.len - input.len;
            }
            fn skip(ctx: *Ctx, i: *usize, n_: usize) void {
                var n = n_;
                while (n > 0) : (n -= 1) {
                    if (ctx.rest[i.*] == '\n') {
                        ctx.line += 1;
                        ctx.pos = 0;
                    } else {
                        ctx.pos += 1;
                    }
                    i.* += 1;
                }
            }
            fn writer(ctx: *Ctx) Writer {
                return .{ .context = ctx };
            }
        };
        var ctx: Ctx = .{
            .pattern = pattern,
            .data = data,
            .callback = callback,
            .buf = try a.alloc(u8, pattern.len * 2),
        };
        defer a.free(ctx.buf);
        return self.store(ctx.writer());
    }

    pub fn debug_render_chunks(self: *const Node, line: usize, output: *ArrayList(u8), plane_: Plane) !void {
        const ctx_ = struct {
            l: *ArrayList(u8),
            wcwidth: usize = 0,
            fn walker(ctx_: *anyopaque, leaf: *const Leaf, plane: Plane) Walker {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                leaf.dump(ctx.l, ctx.wcwidth, plane) catch |e| return .{ .err = e };
                ctx.wcwidth += leaf.width(ctx.wcwidth, plane);
                return if (!leaf.eol) Walker.keep_walking else Walker.stop;
            }
        };
        var ctx: ctx_ = .{ .l = output };
        const found = self.walk_from_line_begin_const(line, ctx_.walker, &ctx, plane_) catch true;
        if (!found) return error.NotFound;

        var buf: [16]u8 = undefined;
        const wcwidth = try std.fmt.bufPrint(&buf, "{d}", .{ctx.wcwidth});
        try output.appendSlice(wcwidth);
    }

    pub fn debug_line_render_tree(self: *const Node, line: usize, l: *ArrayList(u8)) !void {
        return if (self.find_line_node(line)) |n| n.debug_render_tree(l, 0) else error.NotFound;
    }
};

pub fn create(a: Allocator) !*Self {
    const self = try a.create(Self);
    const arena_a = if (builtin.is_test) a else std.heap.page_allocator;
    self.* = .{
        .arena = std.heap.ArenaAllocator.init(arena_a),
        .a = self.arena.allocator(),
        .external_a = a,
        .root = try Node.new(self.a, &empty_leaf, &empty_leaf),
    };
    return self;
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
    self.external_a.destroy(self);
}

fn new_file(self: *const Self, file_exists: *bool) !Root {
    file_exists.* = false;
    return Leaf.new(self.a, "", true, false);
}

pub fn load(self: *const Self, reader: anytype, size: usize) !Root {
    const eol = '\n';
    var buf = try self.a.alloc(u8, size);
    const read_size = try reader.read(buf);
    if (read_size != size)
        return error.BufferUnderrun;
    const final_read = try reader.read(buf);
    if (final_read != 0)
        @panic("unexpected data in final read");

    var leaf_count: usize = 1;
    for (0..buf.len) |i| {
        if (buf[i] == eol) leaf_count += 1;
    }

    var leaves = try self.a.alloc(Node, leaf_count);
    var cur_leaf: usize = 0;
    var b: usize = 0;
    for (0..buf.len) |i| {
        if (buf[i] == eol) {
            const line = buf[b..i];
            leaves[cur_leaf] = .{ .leaf = .{ .buf = line, .bol = true, .eol = true } };
            cur_leaf += 1;
            b = i + 1;
        }
    }
    const line = buf[b..];
    leaves[cur_leaf] = .{ .leaf = .{ .buf = line, .bol = true, .eol = false } };
    if (leaves.len != cur_leaf + 1)
        return error.Unexpected;
    return Node.merge_in_place(leaves, self.a);
}

pub fn load_from_string(self: *const Self, s: []const u8) !Root {
    var stream = std.io.fixedBufferStream(s);
    return self.load(stream.reader(), s.len);
}

pub fn load_from_string_and_update(self: *Self, file_path: []const u8, s: []const u8) !void {
    self.root = try self.load_from_string(s);
    self.file_path = try self.a.dupe(u8, file_path);
    self.last_save = self.root;
    self.file_exists = false;
}

pub fn load_from_file(self: *const Self, file_path: []const u8, file_exists: *bool) !Root {
    const file = cwd().openFile(file_path, .{ .mode = .read_only }) catch |e| switch (e) {
        error.FileNotFound => return self.new_file(file_exists),
        else => return e,
    };

    file_exists.* = true;
    defer file.close();
    const stat = try file.stat();
    return self.load(file.reader(), stat.size);
}

pub fn load_from_file_and_update(self: *Self, file_path: []const u8) !void {
    var file_exists: bool = false;
    self.root = try self.load_from_file(file_path, &file_exists);
    self.file_path = try self.a.dupe(u8, file_path);
    self.last_save = self.root;
    self.file_exists = file_exists;
}

pub fn store_to_string(self: *const Self, a: Allocator) ![]u8 {
    var s = try ArrayList(u8).initCapacity(a, self.root.weights_sum().len);
    try self.root.store(s.writer());
    return s.toOwnedSlice();
}

fn store_to_file_const(self: *const Self, file: anytype) !void {
    const buffer_size = 4096 * 16; // 64KB
    const BufferedWriter = std.io.BufferedWriter(buffer_size, std.fs.File.Writer);
    const Writer = std.io.Writer(*BufferedWriter, BufferedWriter.Error, BufferedWriter.write);

    const file_writer: std.fs.File.Writer = file.writer();
    var buffered_writer: BufferedWriter = .{ .unbuffered_writer = file_writer };

    try self.root.store(Writer{ .context = &buffered_writer });
    try buffered_writer.flush();
}

pub fn store_to_existing_file_const(self: *const Self, file_path: []const u8) !void {
    const stat = try cwd().statFile(file_path);
    var atomic = try cwd().atomicFile(file_path, .{ .mode = stat.mode });
    defer atomic.deinit();
    try self.store_to_file_const(atomic.file);
    try atomic.finish();
}

pub fn store_to_new_file_const(self: *const Self, file_path: []const u8) !void {
    const file = try cwd().createFile(file_path, .{ .read = true, .truncate = true });
    defer file.close();
    try self.store_to_file_const(file);
}

pub fn store_to_file_and_clean(self: *Self, file_path: []const u8) !void {
    self.store_to_existing_file_const(file_path) catch |e| switch (e) {
        error.FileNotFound => try self.store_to_new_file_const(file_path),
        else => return e,
    };
    self.last_save = self.root;
    self.file_exists = true;
}

pub fn is_dirty(self: *const Self) bool {
    return if (!self.file_exists)
        self.root.length() > 0
    else if (self.last_save) |p|
        self.root != p
    else
        true;
}

pub fn version(self: *const Self) usize {
    return @intFromPtr(self.root);
}

pub fn update(self: *Self, root: Root) void {
    self.root = root;
}

pub fn store_undo(self: *Self, meta: []const u8) !void {
    self.push_undo(try self.create_undo(self.root, meta));
    self.curr_history = null;
    try self.push_redo_branch();
}

fn create_undo(self: *const Self, root: Root, meta_: []const u8) !*UndoNode {
    const h = try self.a.create(UndoNode);
    const meta = try self.a.dupe(u8, meta_);
    h.* = UndoNode{
        .root = root,
        .meta = meta,
    };
    return h;
}

fn push_undo(self: *Self, h: *UndoNode) void {
    const next = self.undo_history;
    self.undo_history = h;
    h.next = next;
}

fn push_redo(self: *Self, h: *UndoNode) void {
    const next = self.redo_history;
    self.redo_history = h;
    h.next = next;
}

fn push_redo_branch(self: *Self) !void {
    const r = self.redo_history orelse return;
    const u = self.undo_history orelse return;
    const next = u.branches;
    const b = try self.a.create(UndoBranch);
    b.* = .{
        .redo = r,
        .next = next,
    };
    u.branches = b;
    self.redo_history = null;
}

pub fn undo(self: *Self, meta: []const u8) error{Stop}![]const u8 {
    const r = self.curr_history orelse self.create_undo(self.root, meta) catch return error.Stop;
    const h = self.undo_history orelse return error.Stop;
    self.undo_history = h.next;
    self.curr_history = h;
    self.root = h.root;
    self.push_redo(r);
    return h.meta;
}

pub fn redo(self: *Self) error{Stop}![]const u8 {
    const u = self.curr_history orelse return error.Stop;
    const h = self.redo_history orelse return error.Stop;
    if (u.root != self.root) return error.Stop;
    self.redo_history = h.next;
    self.curr_history = h;
    self.root = h.root;
    self.push_undo(u);
    return h.meta;
}
