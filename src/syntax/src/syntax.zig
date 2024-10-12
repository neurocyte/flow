const std = @import("std");
const build_options = @import("build_options");

const treez = if (build_options.use_tree_sitter)
    @import("treez")
else
    @import("treez_dummy.zig");

const Self = @This();

pub const Edit = treez.InputEdit;
pub const FileType = @import("file_type.zig");
pub const Range = treez.Range;
pub const Point = treez.Point;
const Input = treez.Input;
const Language = treez.Language;
const Parser = treez.Parser;
const Query = treez.Query;
pub const Node = treez.Node;

allocator: std.mem.Allocator,
lang: *const Language,
file_type: *const FileType,
parser: *Parser,
query: *Query,
injections: *Query,
tree: ?*treez.Tree = null,

pub fn create(file_type: *const FileType, allocator: std.mem.Allocator) !*Self {
    const self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .lang = file_type.lang_fn() orelse std.debug.panic("tree-sitter parser function failed for language: {s}", .{file_type.name}),
        .file_type = file_type,
        .parser = try Parser.create(),
        .query = try Query.create(self.lang, file_type.highlights),
        .injections = try Query.create(self.lang, file_type.highlights),
    };
    errdefer self.destroy();
    try self.parser.setLanguage(self.lang);
    return self;
}

pub fn create_file_type(allocator: std.mem.Allocator, lang_name: []const u8) !*Self {
    const file_type = FileType.get_by_name(lang_name) orelse return error.NotFound;
    return create(file_type, allocator);
}

pub fn create_guess_file_type(allocator: std.mem.Allocator, content: []const u8, file_path: ?[]const u8) !*Self {
    const file_type = FileType.guess(file_path, content) orelse return error.NotFound;
    return create(file_type, allocator);
}

pub fn destroy(self: *Self) void {
    if (self.tree) |tree| tree.destroy();
    self.query.destroy();
    self.parser.destroy();
    self.allocator.destroy(self);
}

pub fn refresh_full(self: *Self, content: []const u8) !void {
    if (self.tree) |tree| tree.destroy();
    self.tree = try self.parser.parseString(null, content);
}

pub fn edit(self: *Self, ed: Edit) void {
    if (self.tree) |tree| tree.edit(&ed);
}

pub fn refresh(self: *Self, content: []const u8) !void {
    const old_tree = self.tree;
    defer if (old_tree) |tree| tree.destroy();
    self.tree = try self.parser.parseString(old_tree, content);
}

pub fn refresh_from_buffer(self: *Self, buffer: anytype, metrics: anytype) !void {
    const old_tree = self.tree;
    defer if (old_tree) |tree| tree.destroy();

    const State = struct {
        buffer: @TypeOf(buffer),
        metrics: @TypeOf(metrics),
        syntax: *Self,
        result_buf: [1024]u8 = undefined,
    };
    var state: State = .{
        .buffer = buffer,
        .metrics = metrics,
        .syntax = self,
    };

    const input: Input = .{
        .payload = &state,
        .read = struct {
            fn read(payload: ?*anyopaque, _: u32, position: treez.Point, bytes_read: *u32) callconv(.C) [*:0]const u8 {
                const ctx: *State = @ptrCast(@alignCast(payload orelse return ""));
                const result = ctx.buffer.get_from_pos(.{ .row = position.row, .col = position.column }, &ctx.result_buf, ctx.metrics);
                bytes_read.* = @intCast(result.len);
                return @ptrCast(result.ptr);
            }
        }.read,
        .encoding = .utf_8,
    };
    self.tree = try self.parser.parse(old_tree, input);
}

fn CallBack(comptime T: type) type {
    return fn (ctx: T, sel: Range, scope: []const u8, id: u32, capture_idx: usize, node: *const Node) error{Stop}!void;
}

pub fn render(self: *const Self, ctx: anytype, comptime cb: CallBack(@TypeOf(ctx)), range: ?Range) !void {
    const cursor = try Query.Cursor.create();
    defer cursor.destroy();
    const tree = self.tree orelse return;
    cursor.execute(self.query, tree.getRootNode());
    if (range) |r| cursor.setPointRange(r.start_point, r.end_point);
    while (cursor.nextMatch()) |match| {
        var idx: usize = 0;
        for (match.captures()) |capture| {
            try cb(ctx, capture.node.getRange(), self.query.getCaptureNameForId(capture.id), capture.id, idx, &capture.node);
            idx += 1;
        }
    }
}

pub fn highlights_at_point(self: *const Self, ctx: anytype, comptime cb: CallBack(@TypeOf(ctx)), point: Point) void {
    const cursor = Query.Cursor.create() catch return;
    defer cursor.destroy();
    const tree = self.tree orelse return;
    cursor.execute(self.query, tree.getRootNode());
    cursor.setPointRange(.{ .row = point.row, .column = 0 }, .{ .row = point.row + 1, .column = 0 });
    while (cursor.nextMatch()) |match| {
        for (match.captures()) |capture| {
            const range = capture.node.getRange();
            const start = range.start_point;
            const end = range.end_point;
            const scope = self.query.getCaptureNameForId(capture.id);
            if (start.row == point.row and start.column <= point.column and point.column < end.column)
                cb(ctx, range, scope, capture.id, 0, &capture.node) catch return;
            break;
        }
    }
    return;
}
