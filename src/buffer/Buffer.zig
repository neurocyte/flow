const std = @import("std");
const builtin = @import("builtin");
const cbor = @import("cbor");
const TypedInt = @import("TypedInt");
const VcsBlame = @import("VcsBlame");
const file_type_config = @import("file_type_config");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const cwd = std.fs.cwd;

const Self = @This();

const max_imbalance = 7;
pub const Root = *const Node;
pub const unicode = @import("unicode.zig");
pub const reflow = @import("reflow.zig").reflow;

pub const Manager = @import("Manager.zig");
pub const Cursor = @import("Cursor.zig");
pub const View = @import("View.zig");
pub const Selection = @import("Selection.zig");

pub const FindMode = enum { exact, case_folded };

pub const Metrics = struct {
    ctx: *const anyopaque,
    egc_length: egc_length_func,
    egc_chunk_width: egc_chunk_width_func,
    egc_last: egc_last_func,
    tab_width: usize,
    pub const egc_length_func = *const fn (self: Metrics, egcs: []const u8, colcount: *usize, abs_col: usize) usize;
    pub const egc_chunk_width_func = *const fn (self: Metrics, chunk_: []const u8, abs_col_: usize) usize;
    pub const egc_last_func = *const fn (self: Metrics, egcs: []const u8) []const u8;
};

pub const BlameLine = struct {
    author_name: []const u8,
    author_stamp: usize,
};

pub var retain_symlinks: bool = true;

arena: std.heap.ArenaAllocator,
allocator: Allocator,
external_allocator: Allocator,
root: Root,
leaves_buf: ?[]Node = null,
file_buf: ?[]const u8 = null,
file_path_buf: std.ArrayListUnmanaged(u8) = .empty,
last_save: ?Root = null,
file_exists: bool = true,
file_eol_mode: EolMode = .lf,
last_save_eol_mode: EolMode = .lf,
file_utf8_sanitized: bool = false,
hidden: bool = false,
ephemeral: bool = false,
auto_save: bool = false,
meta: ?[]const u8 = null,
lsp_version: usize = 1,
vcs_id: ?[]const u8 = null,
vcs_content: ?ArrayList(u8) = null,
vcs_blame: VcsBlame = .{},
last_view: ?usize = null,

cache: ?StringCache = null,
last_save_cache: ?StringCache = null,

undo_head: ?*UndoNode = null,
redo_head: ?*UndoNode = null,

mtime: i64,
utime: i64,

file_type_name: ?[]const u8 = null,
file_type_icon: ?[]const u8 = null,
file_type_color: ?u24 = null,

pub const EolMode = enum { lf, crlf };
pub const EolModeTag = @typeInfo(EolMode).@"enum".tag_type;

const UndoNode = struct {
    root: Root,
    next_undo: ?*UndoNode = null,
    next_redo: ?*UndoNode = null,
    branches: ?*UndoBranch = null,
    meta: []const u8,
    file_eol_mode: EolMode,
};

const UndoBranch = struct {
    redo_head: *UndoNode,
    next: ?*UndoBranch,
};

pub const WalkerMut = struct {
    keep_walking_: bool = false,
    found_: bool = false,
    replace: ?Root = null,
    err: ?anyerror = null,

    pub const keep_walking = WalkerMut{ .keep_walking_ = true };
    pub const stop = WalkerMut{ .keep_walking_ = false };
    pub const found = WalkerMut{ .found_ = true };

    const F = *const fn (ctx: *anyopaque, leaf: *const Leaf, metrics: Metrics) WalkerMut;
};

pub const Walker = struct {
    keep_walking_: bool = false,
    found_: bool = false,
    err: ?anyerror = null,

    pub const keep_walking = Walker{ .keep_walking_ = true };
    pub const stop = Walker{ .keep_walking_ = false };
    pub const found = Walker{ .found_ = true };

    const F = *const fn (ctx: *anyopaque, leaf: *const Leaf, metrics: Metrics) Walker;
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
        result.keep_walking_ = left.keep_walking_ and right.keep_walking_;
        result.found_ = left.found_ or right.found_;
        return result;
    }

    fn merge_results(self: *const Branch, allocator: Allocator, left: WalkerMut, right: WalkerMut) WalkerMut {
        var result = WalkerMut{};
        result.err = if (left.err) |_| left.err else right.err;
        if (left.replace != null or right.replace != null) {
            const new_left = left.replace orelse self.left;
            const new_right = right.replace orelse self.right;
            result.replace = if (new_left.is_empty())
                new_right
            else if (new_right.is_empty())
                new_left
            else
                Node.new(allocator, new_left, new_right) catch |e| return .{ .err = e };
        }
        result.keep_walking_ = left.keep_walking_ and right.keep_walking_;
        result.found_ = left.found_ or right.found_;
        return result;
    }
};

pub const Leaf = struct {
    buf: []const u8,
    bol: bool = true,
    eol: bool = true,

    fn new(allocator: Allocator, piece: []const u8, bol: bool, eol: bool) error{OutOfMemory}!*const Node {
        if (piece.len == 0)
            return if (!bol and !eol) &empty_leaf else if (bol and !eol) &empty_bol_leaf else if (!bol and eol) &empty_eol_leaf else &empty_line_leaf;
        const node = try allocator.create(Node);
        errdefer allocator.destroy(node);
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

    fn pos_to_width(self: *const Leaf, pos: *usize, abs_col_: usize, metrics: Metrics) usize {
        var col: usize = 0;
        var abs_col = abs_col_;
        var cols: usize = 0;
        var buf = self.buf;
        while (buf.len > 0 and pos.* > 0) {
            if (buf[0] == '\t') {
                cols = @intCast(metrics.tab_width - (abs_col % metrics.tab_width));
                buf = buf[1..];
                pos.* -= 1;
            } else {
                const bytes = metrics.egc_length(metrics, buf, &cols, abs_col);
                buf = buf[bytes..];
                if (pos.* >= bytes)
                    pos.* -= bytes
                else
                    pos.* = 0;
            }
            col += @intCast(cols);
            abs_col += @intCast(cols);
        }
        return col;
    }

    fn width(self: *const Leaf, abs_col: usize, metrics: Metrics) usize {
        var pos: usize = std.math.maxInt(usize);
        return self.pos_to_width(&pos, abs_col, metrics);
    }

    inline fn width_to_pos(self: *const Leaf, col_: usize, abs_col_: usize, metrics: Metrics) !usize {
        var abs_col = abs_col_;
        var col = col_;
        var cols: usize = 0;
        var buf = self.buf;
        return while (buf.len > 0) {
            if (col == 0)
                break @intFromPtr(buf.ptr) - @intFromPtr(self.buf.ptr);
            const bytes = metrics.egc_length(metrics, buf, &cols, abs_col);
            buf = buf[bytes..];
            if (col < cols)
                break @intFromPtr(buf.ptr) - @intFromPtr(self.buf.ptr);
            col -= @intCast(cols);
            abs_col += @intCast(cols);
        } else error.BufferUnderrun;
    }

    inline fn dump(self: *const Leaf, l: *std.Io.Writer, abs_col: usize, metrics: Metrics) !void {
        var buf: [16]u8 = undefined;
        const wcwidth = try std.fmt.bufPrint(&buf, "{d}", .{self.width(abs_col, metrics)});
        if (self.bol)
            try l.writeAll("BOL ");
        try l.writeAll(wcwidth);
        try l.writeAll("\"");
        try debug_render_chunk(self.buf, l, metrics);
        try l.writeAll("\" ");
        if (self.eol)
            try l.writeAll("EOL ");
    }

    fn debug_render_chunk(chunk: []const u8, l: *std.Io.Writer, metrics: Metrics) !void {
        var cols: usize = 0;
        var buf = chunk;
        while (buf.len > 0) {
            switch (buf[0]) {
                '\x00'...(' ' - 1) => {
                    const control = unicode.control_code_to_unicode(buf[0]);
                    try l.writeAll(control);
                    buf = buf[1..];
                },
                else => {
                    const bytes = metrics.egc_length(metrics, buf, &cols, 0);
                    var buf_: [4096]u8 = undefined;
                    try l.writeAll(try std.fmt.bufPrint(&buf_, "{f}", .{std.ascii.hexEscape(buf[0..bytes], .lower)}));
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

    pub const Ref = TypedInt.Tagged(usize, "NREF");

    pub fn to_ref(self: *const Node) Node.Ref {
        return @enumFromInt(@intFromPtr(self));
    }

    fn new(allocator: Allocator, l: *const Node, r: *const Node) !*const Node {
        const node = try allocator.create(Node);
        errdefer allocator.destroy(node);
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

    pub fn rebalance(self: *const Node, allocator: Allocator, tmp_allocator: Allocator) !Root {
        return if (self.is_balanced()) self else bal: {
            const leaves = try self.collect_leaves(tmp_allocator);
            defer tmp_allocator.free(leaves);
            break :bal self.merge(leaves, allocator);
        };
    }

    fn merge(self: *const Node, leaves: []*const Node, allocator: Allocator) !Root {
        const len = leaves.len;
        if (len == 1) {
            return leaves[0];
        }
        if (len == 2) {
            return Node.new(allocator, leaves[0], leaves[1]);
        }
        const mid = len / 2;
        return Node.new(allocator, try self.merge(leaves[0..mid], allocator), try self.merge(leaves[mid..], allocator));
    }

    fn is_empty(self: *const Node) bool {
        return switch (self.*) {
            .node => |*n| n.left.is_empty() and n.right.is_empty(),
            .leaf => |*l| if (self == &empty_leaf) true else l.is_empty(),
        };
    }

    fn collect(self: *const Node, allocator: Allocator, l: *ArrayList(*const Node)) !void {
        switch (self.*) {
            .node => |*node| {
                try node.left.collect(allocator, l);
                try node.right.collect(allocator, l);
            },
            .leaf => (try l.addOne(allocator)).* = self,
        }
    }

    fn collect_leaves(self: *const Node, allocator: Allocator) ![]*const Node {
        var leaves: ArrayList(*const Node) = .empty;
        try leaves.ensureTotalCapacity(allocator, self.lines());
        try self.collect(allocator, &leaves);
        return leaves.toOwnedSlice(allocator);
    }

    fn walk_const(self: *const Node, f: Walker.F, ctx: *anyopaque, metrics: Metrics) Walker {
        switch (self.*) {
            .node => |*node| {
                const left = node.left.walk_const(f, ctx, metrics);
                if (!left.keep_walking_) {
                    var result = Walker{};
                    result.err = left.err;
                    result.found_ = left.found_;
                    return result;
                }
                const right = node.right.walk_const(f, ctx, metrics);
                return node.merge_results_const(left, right);
            },
            .leaf => |*l| return f(ctx, l, metrics),
        }
    }

    fn walk(self: *const Node, allocator: Allocator, f: WalkerMut.F, ctx: *anyopaque, metrics: Metrics) WalkerMut {
        switch (self.*) {
            .node => |*node| {
                const left = node.left.walk(allocator, f, ctx, metrics);
                if (!left.keep_walking_) {
                    var result = WalkerMut{};
                    result.err = left.err;
                    result.found_ = left.found_;
                    if (left.replace) |p| {
                        result.replace = Node.new(allocator, p, node.right) catch |e| return .{ .err = e };
                    }
                    return result;
                }
                const right = node.right.walk(allocator, f, ctx, metrics);
                return node.merge_results(allocator, left, right);
            },
            .leaf => |*l| return f(ctx, l, metrics),
        }
    }

    fn walk_from_line_begin_const_internal(self: *const Node, line: usize, f: Walker.F, ctx: *anyopaque, metrics: Metrics) Walker {
        switch (self.*) {
            .node => |*node| {
                const left_bols = node.weights.bols;
                if (line >= left_bols)
                    return node.right.walk_from_line_begin_const_internal(line - left_bols, f, ctx, metrics);
                const left_result = node.left.walk_from_line_begin_const_internal(line, f, ctx, metrics);
                const right_result = if (left_result.found_ and left_result.keep_walking_) node.right.walk_const(f, ctx, metrics) else Walker{};
                return node.merge_results_const(left_result, right_result);
            },
            .leaf => |*l| {
                if (line == 0) {
                    var result = f(ctx, l, metrics);
                    if (result.err) |_| return result;
                    result.found_ = true;
                    return result;
                }
                return Walker.keep_walking;
            },
        }
    }

    pub fn walk_from_line_begin_const(self: *const Node, line: usize, f: Walker.F, ctx: *anyopaque, metrics: Metrics) anyerror!bool {
        const result = self.walk_from_line_begin_const_internal(line, f, ctx, metrics);
        if (result.err) |e| return e;
        return result.found_;
    }

    fn walk_from_line_begin_internal(self: *const Node, allocator: Allocator, line: usize, f: WalkerMut.F, ctx: *anyopaque, metrics: Metrics) WalkerMut {
        switch (self.*) {
            .node => |*node| {
                const left_bols = node.weights.bols;
                if (line >= left_bols) {
                    const right_result = node.right.walk_from_line_begin_internal(allocator, line - left_bols, f, ctx, metrics);
                    if (right_result.replace) |p| {
                        var result = WalkerMut{};
                        result.err = right_result.err;
                        result.found_ = right_result.found_;
                        result.keep_walking_ = right_result.keep_walking_;
                        result.replace = if (p.is_empty())
                            node.left
                        else
                            Node.new(allocator, node.left, p) catch |e| return .{ .err = e };
                        return result;
                    } else {
                        return right_result;
                    }
                }
                const left_result = node.left.walk_from_line_begin_internal(allocator, line, f, ctx, metrics);
                const right_result = if (left_result.found_ and left_result.keep_walking_) node.right.walk(allocator, f, ctx, metrics) else WalkerMut{};
                return node.merge_results(allocator, left_result, right_result);
            },
            .leaf => |*l| {
                if (line == 0) {
                    var result = f(ctx, l, metrics);
                    if (result.err) |_| {
                        result.replace = null;
                        return result;
                    }
                    result.found_ = true;
                    return result;
                }
                return WalkerMut.keep_walking;
            },
        }
    }

    pub fn walk_from_line_begin(self: *const Node, allocator: Allocator, line: usize, f: WalkerMut.F, ctx: *anyopaque, metrics: Metrics) !struct { bool, ?Root } {
        const result = self.walk_from_line_begin_internal(allocator, line, f, ctx, metrics);
        if (result.err) |e| return e;
        return .{ result.found_, result.replace };
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

    fn debug_render_tree(self: *const Node, l: *std.Io.Writer, d: usize) void {
        switch (self.*) {
            .node => |*node| {
                l.writeAll("(") catch {};
                node.left.debug_render_tree(l, d + 1);
                l.writeAll(" ") catch {};
                node.right.debug_render_tree(l, d + 1);
                l.writeAll(")") catch {};
            },
            .leaf => |*leaf| {
                l.writeAll("\"") catch {};
                l.writeAll(leaf.buf) catch {};
                if (leaf.eol)
                    l.writeAll("\\n") catch {};
                l.writeAll("\"") catch {};
            },
        }
    }

    const EgcF = *const fn (ctx: *anyopaque, egc: []const u8, wcwidth: usize, metrics: Metrics) Walker;

    pub fn walk_egc_forward(self: *const Node, line: usize, walker_f: EgcF, walker_ctx: *anyopaque, metrics_: Metrics) anyerror!void {
        const Ctx = struct {
            walker_f: EgcF,
            walker_ctx: @TypeOf(walker_ctx),
            abs_col: usize = 0,
            fn walker(ctx_: *anyopaque, leaf: *const Self.Leaf, metrics: Metrics) Walker {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                var buf: []const u8 = leaf.buf;
                while (buf.len > 0) {
                    var cols: usize = undefined;
                    const bytes = metrics.egc_length(metrics, buf, &cols, ctx.abs_col);
                    const ret = ctx.walker_f(ctx.walker_ctx, buf[0..bytes], @intCast(cols), metrics);
                    if (ret.err) |e| return .{ .err = e };
                    buf = buf[bytes..];
                    ctx.abs_col += @intCast(cols);
                    if (!ret.keep_walking_) return Walker.stop;
                }
                if (leaf.eol) {
                    const ret = ctx.walker_f(ctx.walker_ctx, "\n", 1, metrics);
                    if (ret.err) |e| return .{ .err = e };
                    if (!ret.keep_walking_) return Walker.stop;
                    ctx.abs_col = 0;
                }
                return Walker.keep_walking;
            }
        };
        var ctx: Ctx = .{ .walker_f = walker_f, .walker_ctx = walker_ctx };
        const found = try self.walk_from_line_begin_const(line, Ctx.walker, &ctx, metrics_);
        if (!found) return error.NotFound;
    }

    pub fn egc_at(self: *const Node, line: usize, col: usize, metrics: Metrics) error{NotFound}!struct { []const u8, usize, usize } {
        const ctx_ = struct {
            col: usize,
            at: ?[]const u8 = null,
            wcwidth: usize = 0,
            fn walker(ctx_: *anyopaque, egc: []const u8, wcwidth: usize, _: Metrics) Walker {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                ctx.at = egc;
                ctx.wcwidth = wcwidth;
                if (wcwidth > 0 and (ctx.col == 0 or egc[0] == '\n' or ctx.col < wcwidth))
                    return Walker.stop;
                ctx.col -= wcwidth;
                return Walker.keep_walking;
            }
        };
        var ctx: ctx_ = .{ .col = col };
        self.walk_egc_forward(line, ctx_.walker, &ctx, metrics) catch return .{ "?", 1, 0 };
        return if (ctx.at) |at| .{ at, ctx.wcwidth, ctx.col } else error.NotFound;
    }

    pub fn test_at(self: *const Node, pred: *const fn (c: []const u8) bool, line: usize, col: usize, metrics: Metrics) bool {
        const egc, _, _ = self.egc_at(line, col, metrics) catch return false;
        return pred(egc);
    }

    pub fn get_line_width_map(self: *const Node, line: usize, map: *ArrayList(usize), allocator: Allocator, metrics: Metrics) error{ Stop, NoSpaceLeft }!void {
        const Ctx = struct {
            allocator: Allocator,
            map: *ArrayList(usize),
            wcwidth: usize = 0,
            fn walker(ctx_: *anyopaque, egc: []const u8, wcwidth: usize, _: Metrics) Walker {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                var n = egc.len;
                while (n > 0) : (n -= 1) {
                    const p = ctx.map.addOne(ctx.allocator) catch |e| return .{ .err = e };
                    p.* = ctx.wcwidth;
                }
                ctx.wcwidth += wcwidth;
                return if (egc[0] == '\n') Walker.stop else Walker.keep_walking;
            }
        };
        var ctx: Ctx = .{ .allocator = allocator, .map = map };
        self.walk_egc_forward(line, Ctx.walker, &ctx, metrics) catch |e| return switch (e) {
            error.NoSpaceLeft => error.NoSpaceLeft,
            else => error.Stop,
        };
    }

    pub fn get_line_width_to_pos(self: *const Node, line: usize, col: usize, metrics: Metrics) error{Stop}!usize {
        const Ctx = struct {
            col: usize,
            wcwidth: usize = 0,
            pos: usize = 0,
            fn walker(ctx_: *anyopaque, egc: []const u8, wcwidth: usize, _: Metrics) Walker {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                if (ctx.wcwidth >= ctx.col) return Walker.stop;
                ctx.pos += egc.len;
                ctx.wcwidth += wcwidth;
                return if (egc[0] == '\n') Walker.stop else Walker.keep_walking;
            }
        };
        var ctx: Ctx = .{ .col = col };
        self.walk_egc_forward(line, Ctx.walker, &ctx, metrics) catch return error.Stop;
        return ctx.pos;
    }

    pub fn get_range(self: *const Node, sel: Selection, copy_buf: ?[]u8, size: ?*usize, wcwidth_: ?*usize, metrics_: Metrics) error{ Stop, NoSpaceLeft }!?[]u8 {
        const Ctx = struct {
            col: usize = 0,
            sel: Selection,
            out: ?[]u8,
            bytes: usize = 0,
            wcwidth: usize = 0,
            fn walker(ctx_: *anyopaque, egc: []const u8, wcwidth: usize, _: Metrics) Walker {
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
        if (ctx.sel.begin.eql(ctx.sel.end))
            return if (copy_buf) |_| "" else null;
        self.walk_egc_forward(ctx.sel.begin.row, Ctx.walker, &ctx, metrics_) catch |e| return switch (e) {
            error.NoSpaceLeft => error.NoSpaceLeft,
            error.Stop => if (copy_buf) |buf_| buf_[0..ctx.bytes] else null,
            else => error.Stop,
        };
        if (size) |p| p.* = ctx.bytes;
        if (wcwidth_) |p| p.* = ctx.wcwidth;
        return if (copy_buf) |buf_| buf_[0..ctx.bytes] else null;
    }

    pub fn get_from_pos(self: *const Node, start: Cursor, result_buf: []u8, metrics: Metrics) []const u8 {
        var end: Cursor = .{};
        end.move_buffer_end(self, metrics);
        const result = self.get_range(.{ .begin = start, .end = end }, result_buf, null, null, metrics) catch |e| switch (e) {
            error.NoSpaceLeft => result_buf,
            else => @panic("buffer overflow in get_from_start_pos"),
        };
        return result orelse "";
    }

    pub fn delete_range(self: *const Node, sel: Selection, allocator: Allocator, size_: ?*usize, metrics: Metrics) error{Stop}!Root {
        var size: usize = 0;
        defer if (size_) |p| {
            p.* = size;
        };
        _ = self.get_range(sel, null, &size, null, metrics) catch return error.Stop;
        const pos = try self.get_line_width_to_pos(sel.begin.row, sel.begin.col, metrics);
        return self.delete_bytes(sel.begin.row, pos, size, allocator, metrics) catch return error.Stop;
    }

    pub fn delete_range_char(self: *const Node, sel: Selection, allocator: Allocator, size_: ?*usize, metrics: Metrics) error{Stop}!struct { Root, ?u8 } {
        var size: usize = 0;
        defer if (size_) |p| {
            p.* = size;
        };
        _ = self.get_range(sel, null, &size, null, metrics) catch return error.Stop;
        const char = if (size == 1) blk: {
            var result_buf: [6]u8 = undefined;
            const result = self.get_range(sel, &result_buf, null, null, metrics) catch break :blk null;
            break :blk (result orelse break :blk null)[0];
        } else null;
        const pos = try self.get_line_width_to_pos(sel.begin.row, sel.begin.col, metrics);
        const root = self.delete_bytes(sel.begin.row, pos, size, allocator, metrics) catch return error.Stop;
        return .{ root, char };
    }

    pub fn delete_bytes(self: *const Node, line: usize, pos_: usize, bytes: usize, allocator: Allocator, metrics_: Metrics) !Root {
        const Ctx = struct {
            allocator: Allocator,
            pos: usize,
            bytes: usize,
            delete_next_bol: bool = false,
            fn walker(Ctx: *anyopaque, leaf: *const Leaf, _: Metrics) WalkerMut {
                const ctx = @as(*@This(), @ptrCast(@alignCast(Ctx)));
                var result = WalkerMut.keep_walking;
                if (ctx.delete_next_bol and ctx.bytes == 0) {
                    result.replace = Leaf.new(ctx.allocator, leaf.buf, false, leaf.eol) catch |e| return .{ .err = e };
                    result.keep_walking_ = false;
                    ctx.delete_next_bol = false;
                    return result;
                }
                const leaf_bytes = leaf.buf.len;
                const leaf_bol = leaf.bol and !ctx.delete_next_bol;
                ctx.delete_next_bol = false;
                if (ctx.pos > leaf_bytes) {
                    // next node
                    ctx.pos -= leaf_bytes;
                    if (leaf.eol)
                        ctx.pos -= 1;
                } else {
                    // this node
                    if (ctx.pos == 0) {
                        if (ctx.bytes > leaf_bytes) {
                            ctx.bytes -= leaf_bytes;
                            result.replace = Leaf.new(ctx.allocator, "", leaf_bol, false) catch |e| return .{ .err = e };
                            if (leaf.eol) {
                                ctx.bytes -= 1;
                                ctx.delete_next_bol = true;
                            }
                        } else if (ctx.bytes == leaf_bytes) {
                            result.replace = Leaf.new(ctx.allocator, "", leaf_bol, leaf.eol) catch |e| return .{ .err = e };
                            ctx.bytes = 0;
                        } else {
                            result.replace = Leaf.new(ctx.allocator, leaf.buf[ctx.bytes..], leaf_bol, leaf.eol) catch |e| return .{ .err = e };
                            ctx.bytes = 0;
                        }
                    } else if (ctx.pos == leaf_bytes) {
                        if (leaf.eol) {
                            ctx.bytes -= 1;
                            result.replace = Leaf.new(ctx.allocator, leaf.buf, leaf_bol, false) catch |e| return .{ .err = e };
                            ctx.delete_next_bol = true;
                        }
                        ctx.pos -= leaf_bytes;
                    } else {
                        if (ctx.pos + ctx.bytes >= leaf_bytes) {
                            ctx.bytes -= leaf_bytes - ctx.pos;
                            const leaf_eol = if (leaf.eol and ctx.bytes > 0) leaf_eol: {
                                ctx.bytes -= 1;
                                ctx.delete_next_bol = true;
                                break :leaf_eol false;
                            } else leaf.eol;
                            result.replace = Leaf.new(ctx.allocator, leaf.buf[0..ctx.pos], leaf_bol, leaf_eol) catch |e| return .{ .err = e };
                            ctx.pos = 0;
                        } else {
                            const left = Leaf.new(ctx.allocator, leaf.buf[0..ctx.pos], leaf_bol, false) catch |e| return .{ .err = e };
                            const right = Leaf.new(ctx.allocator, leaf.buf[ctx.pos + ctx.bytes ..], false, leaf.eol) catch |e| return .{ .err = e };
                            result.replace = Node.new(ctx.allocator, left, right) catch |e| return .{ .err = e };
                            ctx.bytes = 0;
                        }
                    }
                    if (ctx.bytes == 0 and !ctx.delete_next_bol)
                        result.keep_walking_ = false;
                }
                return result;
            }
        };
        var ctx: Ctx = .{ .allocator = allocator, .pos = pos_, .bytes = bytes };
        const found, const root = try self.walk_from_line_begin(allocator, line, Ctx.walker, &ctx, metrics_);
        return if (found) (root orelse error.Stop) else error.NotFound;
    }

    fn merge_in_place(leaves: []const Node, allocator: Allocator) !Root {
        const len = leaves.len;
        if (len == 1) {
            return &leaves[0];
        }
        if (len == 2) {
            return Node.new(allocator, &leaves[0], &leaves[1]);
        }
        const mid = len / 2;
        return Node.new(allocator, try merge_in_place(leaves[0..mid], allocator), try merge_in_place(leaves[mid..], allocator));
    }

    pub fn get_line(self: *const Node, line: usize, result: *std.Io.Writer, metrics: Metrics) !void {
        const Ctx = struct {
            line: *std.Io.Writer,
            fn walker(ctx_: *anyopaque, leaf: *const Leaf, _: Metrics) Walker {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                ctx.line.writeAll(leaf.buf) catch |e| return .{ .err = e };
                return if (!leaf.eol) Walker.keep_walking else Walker.stop;
            }
        };
        var ctx: Ctx = .{ .line = result };
        const found = self.walk_from_line_begin_const(line, Ctx.walker, &ctx, metrics) catch false;
        return if (!found) error.NotFound;
    }

    pub fn line_width(self: *const Node, line: usize, metrics_: Metrics) !usize {
        const do = struct {
            result: usize = 0,
            fn walker(ctx: *anyopaque, leaf: *const Leaf, metrics: Metrics) Walker {
                const do = @as(*@This(), @ptrCast(@alignCast(ctx)));
                do.result += leaf.width(do.result, metrics);
                return if (!leaf.eol) Walker.keep_walking else Walker.stop;
            }
        };
        var ctx: do = .{};
        const found = self.walk_from_line_begin_const(line, do.walker, &ctx, metrics_) catch true;
        return if (found) ctx.result else error.NotFound;
    }

    pub fn pos_to_width(self: *const Node, line: usize, pos: usize, metrics_: Metrics) error{NotFound}!usize {
        const do = struct {
            result: usize = 0,
            pos: usize,
            fn walker(ctx: *anyopaque, leaf: *const Leaf, metrics: Metrics) Walker {
                const do = @as(*@This(), @ptrCast(@alignCast(ctx)));
                do.result += leaf.pos_to_width(&do.pos, do.result, metrics);
                return if (!(leaf.eol or do.pos == 0)) Walker.keep_walking else Walker.stop;
            }
        };
        var ctx: do = .{ .pos = pos };
        const found = self.walk_from_line_begin_const(line, do.walker, &ctx, metrics_) catch true;
        return if (found) ctx.result else error.NotFound;
    }

    pub fn byte_offset_to_line_and_col(self: *const Node, pos: usize, metrics: Metrics, eol_mode: EolMode) Cursor {
        const ctx_ = struct {
            pos: usize,
            line: usize = 0,
            col: usize = 0,
            eol_mode: EolMode,
            fn walker(ctx_: *anyopaque, egc: []const u8, wcwidth: usize, _: Metrics) Walker {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                if (egc[0] == '\n') {
                    ctx.pos -= switch (ctx.eol_mode) {
                        .lf => 1,
                        .crlf => @min(2, ctx.pos),
                    };
                    if (ctx.pos == 0) return Walker.stop;
                    ctx.line += 1;
                    ctx.col = 0;
                } else {
                    ctx.pos -= @min(egc.len, ctx.pos);
                    if (ctx.pos == 0) return Walker.stop;
                    ctx.col += wcwidth;
                }
                return Walker.keep_walking;
            }
        };
        var ctx: ctx_ = .{ .pos = pos + 1, .eol_mode = eol_mode };
        self.walk_egc_forward(0, ctx_.walker, &ctx, metrics) catch {};
        return .{ .row = ctx.line, .col = ctx.col };
    }

    pub fn insert_chars(
        self_: *const Node,
        line_: usize,
        col_: usize,
        chars: []const u8,
        allocator: Allocator,
        metrics_: Metrics,
    ) !struct { usize, usize, Root } {
        var self = self_;
        var s = chars;
        if (!std.unicode.utf8ValidateSlice(chars))
            s = try unicode.utf8_sanitize(allocator, chars);
        const Ctx = struct {
            allocator: Allocator,
            col: usize,
            abs_col: usize = 0,
            s: []const u8,
            eol: bool,

            fn walker(ctx: *anyopaque, leaf: *const Leaf, metrics: Metrics) WalkerMut {
                const Ctx = @as(*@This(), @ptrCast(@alignCast(ctx)));
                const leaf_wcwidth = leaf.width(Ctx.abs_col, metrics);
                const base_col = Ctx.abs_col;
                Ctx.abs_col += leaf_wcwidth;

                if (Ctx.col == 0) {
                    const left = Leaf.new(Ctx.allocator, Ctx.s, leaf.bol, Ctx.eol) catch |e| return .{ .err = e };
                    const right = Leaf.new(Ctx.allocator, leaf.buf, Ctx.eol, leaf.eol) catch |e| return .{ .err = e };
                    return .{ .replace = Node.new(Ctx.allocator, left, right) catch |e| return .{ .err = e } };
                }

                if (leaf_wcwidth == Ctx.col) {
                    if (leaf.eol and Ctx.eol and Ctx.s.len == 0) {
                        const left = Leaf.new(Ctx.allocator, leaf.buf, leaf.bol, true) catch |e| return .{ .err = e };
                        const right = Leaf.new(Ctx.allocator, Ctx.s, true, true) catch |e| return .{ .err = e };
                        return .{ .replace = Node.new(Ctx.allocator, left, right) catch |e| return .{ .err = e } };
                    }
                    const left = Leaf.new(Ctx.allocator, leaf.buf, leaf.bol, false) catch |e| return .{ .err = e };
                    if (Ctx.eol) {
                        const middle = Leaf.new(Ctx.allocator, Ctx.s, false, Ctx.eol) catch |e| return .{ .err = e };
                        const right = Leaf.new(Ctx.allocator, "", Ctx.eol, leaf.eol) catch |e| return .{ .err = e };
                        return .{ .replace = Node.new(
                            Ctx.allocator,
                            left,
                            Node.new(Ctx.allocator, middle, right) catch |e| return .{ .err = e },
                        ) catch |e| return .{ .err = e } };
                    } else {
                        const right = Leaf.new(Ctx.allocator, Ctx.s, false, leaf.eol) catch |e| return .{ .err = e };
                        return .{ .replace = Node.new(Ctx.allocator, left, right) catch |e| return .{ .err = e } };
                    }
                }

                if (leaf_wcwidth > Ctx.col) {
                    const pos = leaf.width_to_pos(Ctx.col, base_col, metrics) catch |e| return .{ .err = e };
                    if (Ctx.eol and Ctx.s.len == 0) {
                        const left = Leaf.new(Ctx.allocator, leaf.buf[0..pos], leaf.bol, Ctx.eol) catch |e| return .{ .err = e };
                        const right = Leaf.new(Ctx.allocator, leaf.buf[pos..], Ctx.eol, leaf.eol) catch |e| return .{ .err = e };
                        return .{ .replace = Node.new(Ctx.allocator, left, right) catch |e| return .{ .err = e } };
                    }
                    const left = Leaf.new(Ctx.allocator, leaf.buf[0..pos], leaf.bol, false) catch |e| return .{ .err = e };
                    const middle = Leaf.new(Ctx.allocator, Ctx.s, false, Ctx.eol) catch |e| return .{ .err = e };
                    const right = Leaf.new(Ctx.allocator, leaf.buf[pos..], Ctx.eol, leaf.eol) catch |e| return .{ .err = e };
                    return .{ .replace = Node.new(
                        Ctx.allocator,
                        left,
                        Node.new(Ctx.allocator, middle, right) catch |e| return .{ .err = e },
                    ) catch |e| return .{ .err = e } };
                }

                Ctx.col -= leaf_wcwidth;
                return if (leaf.eol) WalkerMut.stop else WalkerMut.keep_walking;
            }
        };
        if (s.len == 0) return error.Stop;
        var rest = try allocator.dupe(u8, s);
        var chunk = rest;
        var line = line_;
        var col = col_;
        var need_eol = false;
        while (rest.len > 0) {
            if (std.mem.indexOfScalar(u8, rest, '\n')) |eol| {
                chunk = rest[0..eol];
                chunk = if (chunk.len > 0 and chunk[chunk.len - 1] == '\r') chunk[0 .. chunk.len - 1] else chunk;
                rest = rest[eol + 1 ..];
                need_eol = true;
            } else {
                chunk = rest;
                rest = &[_]u8{};
                need_eol = false;
            }
            var ctx: Ctx = .{ .allocator = allocator, .col = col, .s = chunk, .eol = need_eol };
            const found, const replace = try self.walk_from_line_begin(allocator, line, Ctx.walker, &ctx, metrics_);
            if (!found) return error.NotFound;
            if (replace) |root| self = root;
            if (need_eol) {
                line += 1;
                col = 0;
            } else {
                col += metrics_.egc_chunk_width(metrics_, chunk, col);
            }
        }
        return .{ line, col, self };
    }

    pub fn store_node(self: *const Node, writer: *std.Io.Writer, eol_mode: EolMode) !void {
        return self.store(writer, eol_mode);
    }

    fn store(self: *const Node, writer: *std.Io.Writer, eol_mode: EolMode) !void {
        switch (self.*) {
            .node => |*node| {
                try node.left.store(writer, eol_mode);
                try node.right.store(writer, eol_mode);
            },
            .leaf => |*leaf| {
                try writer.writeAll(leaf.buf);
                if (leaf.eol) switch (eol_mode) {
                    .lf => try writer.writeByte('\n'),
                    .crlf => try writer.writeAll("\r\n"),
                };
            },
        }
    }

    pub const FindAllCallback = fn (data: *anyopaque, begin_row: usize, begin_col: usize, end_row: usize, end_col: usize) error{Stop}!void;
    pub fn find_all_ranges(self: *const Node, pattern: []const u8, data: *anyopaque, callback: *const FindAllCallback, mode: FindMode, allocator: Allocator) error{ OutOfMemory, Stop }!void {
        const Ctx = struct {
            allocator: std.mem.Allocator,
            pattern: []const u8,
            data: *anyopaque,
            callback: *const FindAllCallback,
            line: usize = 0,
            pos: usize = 0,
            buf: []u8,
            rest: []u8 = "",
            writer: std.Io.Writer,
            mode: FindMode,

            const Ctx = @This();
            fn drain(w: *std.Io.Writer, data_: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
                const ctx: *Ctx = @alignCast(@fieldParentPtr("writer", w));
                if (data_.len == 0) return 0;
                var written: usize = 0;
                for (data_[0 .. data_.len - 1]) |bytes| {
                    written += try ctx.write(bytes);
                }
                const pattern_ = data_[data_.len - 1];
                switch (pattern_.len) {
                    0 => return written,
                    else => for (0..splat) |_| {
                        written += try ctx.write(pattern_);
                    },
                }
                return written;
            }
            fn write(ctx: *Ctx, bytes: []const u8) std.Io.Writer.Error!usize {
                var input = bytes;
                while (true) {
                    switch (ctx.mode) {
                        .exact => {
                            const input_consume_size = @min(ctx.buf.len - ctx.rest.len, input.len);
                            @memcpy(ctx.buf[ctx.rest.len .. ctx.rest.len + input_consume_size], input[0..input_consume_size]);
                            ctx.rest = ctx.buf[0 .. ctx.rest.len + input_consume_size];
                            input = input[input_consume_size..];
                        },
                        .case_folded => {
                            const input_consume_size = @min(ctx.buf.len - ctx.rest.len, input.len);
                            var writer = std.Io.Writer.fixed(ctx.buf[ctx.rest.len..]);
                            var folded = unicode.case_folded_write_partial(&writer, input[0..input_consume_size]) catch return error.WriteFailed;
                            if (folded.len == 0) {
                                try writer.writeByte(input[0]);
                                folded = input[0..1];
                            }
                            ctx.rest = ctx.buf[0 .. ctx.rest.len + folded.len];
                            input = input[folded.len..];
                        },
                    }

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
                            ctx.callback(ctx.data, begin_row, begin_pos, end_row, end_pos) catch return error.WriteFailed;
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
        };
        const pattern_ = switch (mode) {
            .exact => pattern,
            .case_folded => unicode.case_fold(allocator, pattern) catch
                allocator.dupe(u8, pattern) catch
                @panic("OOM find_all_ranges"),
        };
        defer switch (mode) {
            .exact => {},
            .case_folded => allocator.free(pattern_),
        };
        var ctx: Ctx = .{
            .allocator = allocator,
            .pattern = pattern_,
            .data = data,
            .callback = callback,
            .buf = try allocator.alloc(u8, pattern.len * 2),
            .writer = .{
                .vtable = &.{
                    .drain = Ctx.drain,
                },
                .buffer = &.{},
            },
            .mode = mode,
        };
        defer allocator.free(ctx.buf);
        return self.store(&ctx.writer, .lf) catch |e| switch (e) {
            error.WriteFailed => error.Stop,
        };
    }

    pub fn get_byte_pos(self: *const Node, pos_: Cursor, metrics: Metrics, eol_mode: EolMode) !usize {
        const ctx_ = struct {
            pos: usize = 0,
            line: usize = 0,
            col: usize = 0,
            target_line: usize,
            target_col: usize,
            eol_mode: EolMode,
            fn walker(ctx_: *anyopaque, egc: []const u8, wcwidth: usize, _: Metrics) Walker {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                if (ctx.line == ctx.target_line and ctx.col == ctx.target_col) return Walker.stop;
                if (egc[0] == '\n') {
                    ctx.pos += switch (ctx.eol_mode) {
                        .lf => 1,
                        .crlf => 2,
                    };
                    ctx.line += 1;
                    ctx.col = 0;
                } else {
                    ctx.pos += egc.len;
                    ctx.col += wcwidth;
                }
                return Walker.keep_walking;
            }
        };
        var ctx: ctx_ = .{ .target_line = pos_.row, .target_col = pos_.col, .eol_mode = eol_mode };
        self.walk_egc_forward(0, ctx_.walker, &ctx, metrics) catch {};
        return ctx.pos;
    }

    pub fn debug_render_chunks(self: *const Node, allocator: std.mem.Allocator, line: usize, metrics_: Metrics) ![]const u8 {
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        const ctx_ = struct {
            l: *std.Io.Writer,
            wcwidth: usize = 0,
            fn walker(ctx_: *anyopaque, leaf: *const Leaf, metrics: Metrics) Walker {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                leaf.dump(ctx.l, ctx.wcwidth, metrics) catch |e| return .{ .err = e };
                ctx.wcwidth += leaf.width(ctx.wcwidth, metrics);
                return if (!leaf.eol) Walker.keep_walking else Walker.stop;
            }
        };
        var ctx: ctx_ = .{ .l = &output.writer };
        const found = self.walk_from_line_begin_const(line, ctx_.walker, &ctx, metrics_) catch true;
        if (!found) return error.NotFound;

        var buf: [16]u8 = undefined;
        const wcwidth = try std.fmt.bufPrint(&buf, "{d}", .{ctx.wcwidth});
        try output.writer.writeAll(wcwidth);
        return output.toOwnedSlice();
    }

    pub fn debug_line_render_tree(self: *const Node, allocator: std.mem.Allocator, line: usize) ![]const u8 {
        return if (self.find_line_node(line)) |n| blk: {
            var l: std.Io.Writer.Allocating = .init(allocator);
            defer l.deinit();
            n.debug_render_tree(&l.writer, 0);
            break :blk l.toOwnedSlice();
        } else error.NotFound;
    }

    pub fn write_range(
        self: *const Node,
        sel: Selection,
        writer: *std.Io.Writer,
        wcwidth_: ?*usize,
        metrics: Metrics,
    ) std.Io.Writer.Error!void {
        const Ctx = struct {
            col: usize = 0,
            sel: Selection,
            writer: *std.Io.Writer,
            wcwidth: usize = 0,
            fn walker(ctx_: *anyopaque, egc: []const u8, wcwidth: usize, _: Metrics) Walker {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                if (ctx.col < ctx.sel.begin.col) {
                    ctx.col += wcwidth;
                    return Walker.keep_walking;
                }
                _ = ctx.writer.write(egc) catch |e| return Walker{ .err = e };
                ctx.wcwidth += wcwidth;
                if (egc[0] == '\n') {
                    ctx.col = 0;
                    ctx.sel.begin.col = 0;
                    ctx.sel.begin.row += 1;
                } else {
                    ctx.col += wcwidth;
                    ctx.sel.begin.col += wcwidth;
                }
                return if (ctx.sel.begin.eql(ctx.sel.end))
                    Walker.stop
                else
                    Walker.keep_walking;
            }
        };

        var ctx: Ctx = .{ .sel = sel, .writer = writer };
        ctx.sel.normalize();
        if (sel.begin.eql(sel.end))
            return;
        self.walk_egc_forward(sel.begin.row, Ctx.walker, &ctx, metrics) catch return error.WriteFailed;
        if (wcwidth_) |p| p.* = ctx.wcwidth;
    }
};

pub fn create(allocator: Allocator) error{OutOfMemory}!*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    const arena_a = if (builtin.is_test) allocator else std.heap.page_allocator;
    self.* = .{
        .arena = std.heap.ArenaAllocator.init(arena_a),
        .allocator = self.arena.allocator(),
        .external_allocator = allocator,
        .root = try Node.new(self.allocator, &empty_leaf, &empty_leaf),
        .mtime = std.time.milliTimestamp(),
        .utime = std.time.milliTimestamp(),
    };
    return self;
}

pub fn deinit(self: *Self) void {
    self.clear_vcs_content();
    self.clear_vcs_blame();
    self.vcs_blame.reset(self.external_allocator);
    if (self.cache) |*cache| cache.deinit(self.external_allocator);
    if (self.last_save_cache) |*cache| cache.deinit(self.external_allocator);
    if (self.vcs_id) |buf| self.external_allocator.free(buf);
    if (self.meta) |buf| self.external_allocator.free(buf);
    if (self.file_buf) |buf| self.external_allocator.free(buf);
    if (self.leaves_buf) |buf| self.external_allocator.free(buf);
    self.file_path_buf.deinit(self.external_allocator);
    self.arena.deinit();
    self.external_allocator.destroy(self);
}

pub fn set_meta(self: *Self, meta_: []const u8) error{OutOfMemory}!void {
    const meta = try self.external_allocator.dupe(u8, meta_);
    if (self.meta) |buf| self.external_allocator.free(buf);
    self.meta = meta;
}

pub fn get_meta(self: *Self) ?[]const u8 {
    return self.meta;
}

pub fn set_file_path(self: *Self, file_path: []const u8) void {
    if (file_path.ptr == self.file_path_buf.items.ptr) return;
    self.file_path_buf.clearRetainingCapacity();
    self.file_path_buf.appendSlice(self.external_allocator, file_path) catch |e| switch (e) {
        error.OutOfMemory => @panic("OOM in Buffer.set_file_path"),
    };
}

pub inline fn get_file_path(self: *const Self) []const u8 {
    return self.file_path_buf.items;
}

pub fn set_last_view(self: *Self, last_view: ?usize) void {
    self.last_view = last_view;
}

pub fn get_last_view(self: *Self) ?usize {
    return self.last_view;
}

pub fn set_vcs_id(self: *Self, vcs_id: []const u8) error{OutOfMemory}!bool {
    if (self.vcs_id) |old_id| {
        if (std.mem.eql(u8, old_id, vcs_id)) return false;
        self.external_allocator.free(old_id);
    }
    self.clear_vcs_content();
    self.clear_vcs_blame();
    self.vcs_id = try self.external_allocator.dupe(u8, vcs_id);
    return true;
}

pub fn get_vcs_id(self: *const Self) ?[]const u8 {
    return self.vcs_id;
}

pub fn set_vcs_content(self: *Self, vcs_id: []const u8, vcs_content: []const u8) error{OutOfMemory}!void {
    _ = try self.set_vcs_id(vcs_id);
    if (self.vcs_content) |*al| {
        try al.appendSlice(self.external_allocator, vcs_content);
    } else {
        var al: ArrayList(u8) = .empty;
        try al.appendSlice(self.external_allocator, vcs_content);
        self.vcs_content = al;
    }
}

pub fn clear_vcs_content(self: *Self) void {
    if (self.vcs_content) |*buf| {
        buf.deinit(self.external_allocator);
        self.vcs_content = null;
    }
}

pub fn get_vcs_content(self: *const Self) ?[]const u8 {
    return if (self.vcs_content) |*buf| buf.items else null;
}

pub fn clear_vcs_blame(self: *Self) void {
    self.vcs_blame.reset(self.external_allocator);
}

pub fn get_vcs_blame(self: *const Self, line: usize) ?*const VcsBlame.Commit {
    return self.vcs_blame.getLine(line);
}

pub fn set_vcs_blame(self: *Self, vcs_blame: []const u8) error{OutOfMemory}!void {
    return self.vcs_blame.addContent(self.external_allocator, vcs_blame);
}

pub fn parse_vcs_blame(self: *Self) VcsBlame.Error!void {
    return self.vcs_blame.parse(self.external_allocator);
}

pub fn update_last_used_time(self: *Self) void {
    self.utime = std.time.milliTimestamp();
}

fn new_file(self: *const Self, file_exists: *bool) error{OutOfMemory}!Root {
    file_exists.* = false;
    return Leaf.new(self.allocator, "", true, false);
}

pub const LoadError =
    error{
        OutOfMemory,
        BufferUnderrun,
        DanglingSurrogateHalf,
        ExpectedSecondSurrogateHalf,
        UnexpectedSecondSurrogateHalf,
        Unexpected,
    } || std.Io.Reader.Error;

pub fn load(self: *const Self, reader: *std.Io.Reader, eol_mode: *EolMode, utf8_sanitized: *bool) LoadError!Root {
    const lf = '\n';
    const cr = '\r';
    const self_ = @constCast(self);
    var read_buffer: ArrayList(u8) = .empty;
    defer read_buffer.deinit(self.external_allocator);
    try reader.appendRemainingUnlimited(self.external_allocator, &read_buffer);
    var buf = try read_buffer.toOwnedSlice(self.external_allocator);

    if (!std.unicode.utf8ValidateSlice(buf)) {
        const converted = try unicode.utf8_sanitize(self.external_allocator, buf);
        self.external_allocator.free(buf);
        buf = converted;
        utf8_sanitized.* = true;
    }
    self_.file_buf = buf;

    eol_mode.* = .lf;
    var leaf_count: usize = 1;
    for (0..buf.len) |i| {
        if (buf[i] == lf) {
            leaf_count += 1;
            if (i > 0 and buf[i - 1] == cr)
                eol_mode.* = .crlf;
        }
    }

    var leaves = try self.external_allocator.alloc(Node, leaf_count);
    self_.leaves_buf = leaves;
    var cur_leaf: usize = 0;
    var b: usize = 0;
    for (0..buf.len) |i| {
        if (buf[i] == lf) {
            const line_end = if (i > 0 and buf[i - 1] == cr) i - 1 else i;
            const line = buf[b..line_end];
            leaves[cur_leaf] = .{ .leaf = .{ .buf = line, .bol = true, .eol = true } };
            cur_leaf += 1;
            b = i + 1;
        }
    }
    const line = buf[b..];
    leaves[cur_leaf] = .{ .leaf = .{ .buf = line, .bol = true, .eol = false } };
    if (leaves.len != cur_leaf + 1)
        return error.Unexpected;
    return Node.merge_in_place(leaves, self.allocator);
}

pub fn load_from_string(self: *const Self, s: []const u8, eol_mode: *EolMode, utf8_sanitized: *bool) LoadError!Root {
    var reader = std.Io.Reader.fixed(s);
    return self.load(&reader, eol_mode, utf8_sanitized);
}

pub fn load_from_string_and_update(self: *Self, file_path: []const u8, s: []const u8) LoadError!void {
    self.root = try self.load_from_string(s, &self.file_eol_mode, &self.file_utf8_sanitized);
    self.set_file_path(file_path);
    self.last_save = self.root;
    self.last_save_eol_mode = self.file_eol_mode;
    self.file_exists = false;
    self.mtime = std.time.milliTimestamp();
}

pub fn reset_from_string_and_update(self: *Self, s: []const u8) LoadError!void {
    self.root = try self.load_from_string(s, &self.file_eol_mode, &self.file_utf8_sanitized);
    self.last_save = self.root;
    self.last_save_eol_mode = self.file_eol_mode;
    self.mtime = std.time.milliTimestamp();
}

pub const LoadFromFileError = error{
    OutOfMemory,
    Unexpected,
    FileTooBig,
    NoSpaceLeft,
    DeviceBusy,
    AccessDenied,
    SystemResources,
    WouldBlock,
    IsDir,
    SharingViolation,
    PathAlreadyExists,
    FileNotFound,
    PipeBusy,
    NameTooLong,
    InvalidUtf8,
    InvalidWtf8,
    BadPathName,
    NetworkNotFound,
    AntivirusInterference,
    SymLinkLoop,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoDevice,
    NotDir,
    FileLocksNotSupported,
    FileBusy,
    InputOutput,
    BrokenPipe,
    OperationAborted,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    NotOpenForReading,
    SocketNotConnected,
    BufferUnderrun,
    DanglingSurrogateHalf,
    ExpectedSecondSurrogateHalf,
    UnexpectedSecondSurrogateHalf,
    LockViolation,
    ProcessNotFound,
    Canceled,
    PermissionDenied,
} || LoadError;

pub fn load_from_file(
    self: *const Self,
    file_path: []const u8,
    file_exists: *bool,
    eol_mode: *EolMode,
    utf8_sanitized: *bool,
) LoadFromFileError!Root {
    const file = cwd().openFile(file_path, .{ .mode = .read_only }) catch |e| switch (e) {
        error.FileNotFound => return self.new_file(file_exists),
        else => return e,
    };

    file_exists.* = true;
    defer file.close();
    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(&read_buf);
    return self.load(&file_reader.interface, eol_mode, utf8_sanitized);
}

pub fn load_from_file_and_update(self: *Self, file_path: []const u8) LoadFromFileError!void {
    var file_exists: bool = false;
    var eol_mode: EolMode = .lf;
    var utf8_sanitized: bool = false;
    self.root = try self.load_from_file(file_path, &file_exists, &eol_mode, &utf8_sanitized);
    self.set_file_path(file_path);
    self.last_save = self.root;
    self.file_exists = file_exists;
    self.file_eol_mode = eol_mode;
    self.file_utf8_sanitized = utf8_sanitized;
    self.last_save_eol_mode = eol_mode;
    self.mtime = std.time.milliTimestamp();
}

pub fn reset_to_last_saved(self: *Self) void {
    if (self.last_save) |last_save| {
        self.store_undo(&[_]u8{}) catch {};
        self.root = last_save;
        self.file_eol_mode = self.last_save_eol_mode;
        self.mtime = std.time.milliTimestamp();
    }
}

pub fn refresh_from_file(self: *Self) LoadFromFileError!void {
    try self.load_from_file_and_update(self.get_file_path());
    self.update_last_used_time();
}

pub fn store_to_string_cached(self: *Self, root: *const Node, eol_mode: EolMode) [:0]const u8 {
    if (get_cached_text(self.cache, root.to_ref(), eol_mode)) |text| return text;
    var s: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(self.external_allocator, root.weights_sum().len) catch @panic("OOM store_to_string_cached");
    root.store(&s.writer, eol_mode) catch @panic("store_to_string_cached");
    return self.store_cached_text(&self.cache, root.to_ref(), eol_mode, s.toOwnedSliceSentinel(0) catch @panic("OOM store_to_string_cached"));
}

pub fn store_last_save_to_string_cached(self: *Self, eol_mode: EolMode) ?[]const u8 {
    const root = self.last_save orelse return null;
    if (get_cached_text(self.last_save_cache, root.to_ref(), eol_mode)) |text| return text;
    var s: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(self.external_allocator, root.weights_sum().len) catch @panic("OOM store_last_save_to_string_cached");
    root.store(&s.writer, eol_mode) catch @panic("store_last_save_to_string_cached");
    return self.store_cached_text(&self.last_save_cache, root.to_ref(), eol_mode, s.toOwnedSliceSentinel(0) catch @panic("OOM store_last_save_to_string_cached"));
}

fn get_cached_text(cache_: ?StringCache, ref: Node.Ref, eol_mode: EolMode) ?[:0]const u8 {
    const cache = cache_ orelse return null;
    return if (cache.ref == ref and cache.eol_mode == eol_mode) cache.text else null;
}

fn store_cached_text(self: *Self, cache: *?StringCache, ref: Node.Ref, eol_mode: EolMode, text: [:0]const u8) [:0]const u8 {
    if (cache.*) |*c|
        c.deinit(self.external_allocator);
    cache.* = .{
        .ref = ref,
        .eol_mode = eol_mode,
        .text = text,
    };
    return text;
}

const StringCache = struct {
    ref: Node.Ref,
    eol_mode: EolMode,
    text: [:0]const u8,
    code_folded: ?[:0]const u8 = null,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.code_folded) |text| allocator.free(text);
    }
};

fn store_to_file_const(self: *const Self, writer: *std.Io.Writer) StoreToFileError!void {
    try self.root.store(writer, self.file_eol_mode);
    try writer.flush();
}

pub const StoreToFileError = error{
    AccessDenied,
    AntivirusInterference,
    BadPathName,
    BrokenPipe,
    ConnectionResetByPeer,
    DeviceBusy,
    DiskQuota,
    FileBusy,
    FileLocksNotSupported,
    FileNotFound,
    FileTooBig,
    InputOutput,
    InvalidArgument,
    InvalidUtf8,
    InvalidWtf8,
    IsDir,
    LinkQuotaExceeded,
    LockViolation,
    NameTooLong,
    NetworkNotFound,
    NoDevice,
    NoSpaceLeft,
    NotDir,
    NotOpenForWriting,
    OperationAborted,
    OutOfMemory,
    PathAlreadyExists,
    PipeBusy,
    ProcessFdQuotaExceeded,
    ProcessNotFound,
    ReadOnlyFileSystem,
    RenameAcrossMountPoints,
    SharingViolation,
    SymLinkLoop,
    SystemFdQuotaExceeded,
    SystemResources,
    Unexpected,
    WouldBlock,
    PermissionDenied,
    MessageTooBig,
    WriteFailed,
};

pub fn store_to_existing_file_const(self: *const Self, file_path_: []const u8) StoreToFileError!void {
    var file_path = file_path_;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (retain_symlinks) blk: {
        const link = cwd().readLink(file_path, &link_buf) catch break :blk;
        file_path = link;
    }

    var atomic = blk: {
        var write_buffer: [4096]u8 = undefined;
        const stat = cwd().statFile(file_path) catch
            break :blk try cwd().atomicFile(file_path, .{ .write_buffer = &write_buffer });
        break :blk try cwd().atomicFile(file_path, .{ .mode = stat.mode, .write_buffer = &write_buffer });
    };
    defer atomic.deinit();
    try self.store_to_file_const(&atomic.file_writer.interface);
    try atomic.finish();
}

pub fn store_to_new_file_const(self: *const Self, file_path: []const u8) StoreToFileError!void {
    if (std.fs.path.dirname(file_path)) |dir_name|
        try cwd().makePath(dir_name);
    const file = try cwd().createFile(file_path, .{ .read = true, .truncate = true });
    defer file.close();
    var write_buffer: [4096]u8 = undefined;
    var writer = file.writer(&write_buffer);
    try self.store_to_file_const(&writer.interface);
}

pub fn store_to_file_and_clean(self: *Self, file_path: []const u8) StoreToFileError!void {
    self.store_to_existing_file_const(file_path) catch |e| switch (e) {
        error.FileNotFound => try self.store_to_new_file_const(file_path),
        else => return e,
    };
    self.last_save = self.root;
    self.last_save_eol_mode = self.file_eol_mode;
    self.file_exists = true;
    self.file_utf8_sanitized = false;
    if (self.ephemeral) {
        self.ephemeral = false;
        self.set_file_path(file_path);
    }
}

pub fn mark_clean(self: *Self) void {
    self.last_save = self.root;
}

pub fn mark_dirty(self: *Self) void {
    self.last_save = null;
}

pub fn is_hidden(self: *const Self) bool {
    return self.hidden;
}

pub fn is_ephemeral(self: *const Self) bool {
    return self.ephemeral;
}

pub fn mark_not_ephemeral(self: *Self) void {
    self.ephemeral = false;
}

pub fn enable_auto_save(self: *Self) void {
    self.auto_save = true;
}

pub fn disable_auto_save(self: *Self) void {
    self.auto_save = false;
}

pub fn is_auto_save(self: *const Self) bool {
    return self.auto_save;
}

pub fn is_dirty(self: *const Self) bool {
    return if (!self.file_exists)
        self.root.length() > 0
    else if (self.last_save) |p|
        self.root != p or self.last_save_eol_mode != self.file_eol_mode
    else
        true;
}

pub fn version(self: *const Self) usize {
    return @intFromPtr(self.root);
}

pub fn update(self: *Self, root: Root) void {
    self.root = root;
    self.mtime = std.time.milliTimestamp();
}

pub fn store_undo(self: *Self, meta: []const u8) error{OutOfMemory}!void {
    try self.push_redo_branch();
    self.push_undo(try self.create_undo(self.root, meta));
}

fn create_undo(self: *const Self, root: Root, meta_: []const u8) error{OutOfMemory}!*UndoNode {
    const h = try self.allocator.create(UndoNode);
    const meta = try self.allocator.dupe(u8, meta_);
    h.* = UndoNode{
        .root = root,
        .meta = meta,
        .file_eol_mode = self.file_eol_mode,
    };
    return h;
}

fn push_undo(self: *Self, node: *UndoNode) void {
    node.next_undo = self.undo_head;
    self.undo_head = node;
}

fn pop_undo(self: *Self) ?*UndoNode {
    const node = self.undo_head orelse return null;
    self.undo_head = node.next_undo;
    return node;
}

fn push_redo(self: *Self, node: *UndoNode) void {
    node.next_redo = self.redo_head;
    self.redo_head = node;
}

fn pop_redo(self: *Self) ?*UndoNode {
    const node = self.redo_head orelse return null;
    self.redo_head = node.next_redo;
    return node;
}

fn push_redo_branch(self: *Self) !void {
    const redo_head = self.redo_head orelse return;
    const undo_head = self.undo_head orelse return;
    const branch = try self.allocator.create(UndoBranch);
    branch.* = .{
        .redo_head = redo_head,
        .next = undo_head.branches,
    };
    undo_head.branches = branch;
    self.redo_head = null;
}

pub fn undo(self: *Self) error{Stop}![]const u8 {
    const node = self.pop_undo() orelse return error.Stop;
    if (self.redo_head == null) blk: {
        self.push_redo(self.create_undo(self.root, &.{}) catch break :blk);
    }
    self.push_redo(node);
    self.root = node.root;
    self.file_eol_mode = node.file_eol_mode;
    self.mtime = std.time.milliTimestamp();
    return node.meta;
}

pub fn redo(self: *Self) error{Stop}![]const u8 {
    if (self.redo_head) |redo_head| if (self.root != redo_head.root)
        return error.Stop;
    const node = self.pop_redo() orelse return error.Stop;
    self.push_undo(node);
    if (self.redo_head) |head| {
        self.root = head.root;
        self.file_eol_mode = head.file_eol_mode;
        if (head.next_redo == null)
            self.redo_head = null;
    }
    self.mtime = std.time.milliTimestamp();
    return node.meta;
}

pub fn write_state(self: *const Self, writer: *std.Io.Writer) error{ Stop, OutOfMemory, WriteFailed }!void {
    var content: std.Io.Writer.Allocating = .init(self.external_allocator);
    defer content.deinit();
    try self.root.store(&content.writer, self.file_eol_mode);
    const dirty = self.is_dirty();

    try cbor.writeValue(writer, .{
        self.get_file_path(),
        self.file_exists,
        self.file_eol_mode,
        self.hidden,
        self.ephemeral,
        self.auto_save,
        self.last_view,
        dirty,
        self.meta,
        self.file_type_name,
        self.vcs_id,
        content.written(),
    });
}

pub const ExtractStateOperation = enum { none, open_file };

pub fn extract_state(self: *Self, iter: *[]const u8) !void {
    var file_path: []const u8 = undefined;
    var file_type_name: []const u8 = undefined;
    var dirty: bool = undefined;
    var meta: ?[]const u8 = null;
    var vcs_id: ?[]const u8 = null;
    var content: []const u8 = undefined;

    if (!try cbor.matchValue(iter, .{
        cbor.extract(&file_path),
        cbor.extract(&self.file_exists),
        cbor.extract(&self.file_eol_mode),
        cbor.extract(&self.hidden),
        cbor.extract(&self.ephemeral),
        cbor.extract(&self.auto_save),
        cbor.extract(&self.last_view),
        cbor.extract(&dirty),
        cbor.extract(&meta),
        cbor.extract(&file_type_name),
        cbor.extract(&vcs_id),
        cbor.extract(&content),
    }))
        return error.Stop;

    self.set_file_path(file_path);

    if (try file_type_config.get(try self.allocator.dupe(u8, file_type_name))) |config| {
        self.file_type_name = config.name;
        self.file_type_icon = config.icon;
        self.file_type_color = config.color;
    } else {
        self.file_type_name = file_type_config.default.name;
        self.file_type_icon = file_type_config.default.icon;
        self.file_type_color = file_type_config.default.color;
    }

    if (meta) |buf| {
        if (self.meta) |old_buf| self.external_allocator.free(old_buf);
        self.meta = try self.external_allocator.dupe(u8, buf);
    }
    try self.reset_from_string_and_update(content);
    if (dirty) self.mark_dirty();
}

pub fn to_ref(self: *Self) Ref {
    return @enumFromInt(@intFromPtr(self));
}

pub const Ref = TypedInt.Tagged(usize, "BREF");
