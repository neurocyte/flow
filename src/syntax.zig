const std = @import("std");
const treez = @import("treez");

const Self = @This();

pub const Edit = treez.InputEdit;
pub const FileType = @import("file_type.zig");
pub const Range = treez.Range;
pub const Point = treez.Point;
const Language = treez.Language;
const Parser = treez.Parser;
const Query = treez.Query;
const Tree = treez.Tree;
pub const Node = treez.Node;

a: std.mem.Allocator,
lang: *const Language,
file_type: *const FileType,
parser: *Parser,
query: *Query,
injections: *Query,
tree: ?*Tree = null,

pub fn create(file_type: *const FileType, a: std.mem.Allocator, content: []const u8) !*Self {
    const self = try a.create(Self);
    self.* = .{
        .a = a,
        .lang = file_type.lang_fn() orelse std.debug.panic("tree-sitter parser function failed for language: {d}", .{file_type.name}),
        .file_type = file_type,
        .parser = try Parser.create(),
        .query = try Query.create(self.lang, file_type.highlights),
        .injections = try Query.create(self.lang, file_type.highlights),
    };
    errdefer self.destroy();
    try self.parser.setLanguage(self.lang);
    try self.parse(content);
    return self;
}

pub fn create_file_type(a: std.mem.Allocator, content: []const u8, lang_name: []const u8) !*Self {
    const file_type = FileType.get_by_name(lang_name) orelse return error.NotFound;
    return create(file_type, a, content);
}

pub fn create_guess_file_type(a: std.mem.Allocator, content: []const u8, file_path: ?[]const u8) !*Self {
    const file_type = FileType.guess(file_path, content) orelse return error.NotFound;
    return create(file_type, a, content);
}

pub fn destroy(self: *Self) void {
    if (self.tree) |tree| tree.destroy();
    self.query.destroy();
    self.parser.destroy();
    self.a.destroy(self);
}

fn parse(self: *Self, content: []const u8) !void {
    if (self.tree) |tree| tree.destroy();
    self.tree = try self.parser.parseString(null, content);
}

pub fn refresh_full(self: *Self, content: []const u8) !void {
    return self.parse(content);
}

pub fn edit(self: *Self, ed: Edit) void {
    if (self.tree) |tree| tree.edit(&ed);
}

pub fn refresh(self: *Self, content: []const u8) !void {
    const old_tree = self.tree;
    defer if (old_tree) |tree| tree.destroy();
    self.tree = try self.parser.parseString(old_tree, content);
}

fn CallBack(comptime T: type) type {
    return fn (ctx: T, sel: Range, scope: []const u8, id: u32, capture_idx: usize, node: *const Node) error{Stop}!void;
}

pub fn render(self: *const Self, ctx: anytype, comptime cb: CallBack(@TypeOf(ctx)), range: ?Range) !void {
    const cursor = try Query.Cursor.create();
    defer cursor.destroy();
    const tree = if (self.tree) |p| p else return;
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
    const tree = if (self.tree) |p| p else return;
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
