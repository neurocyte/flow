//! The files of a project that were recently used in flow, with the cursor
//! positions to restore. This is the part of a project's file list that is
//! persisted; the full list belongs to the project's file finder.

const std = @import("std");

const is_in_subtree = @import("file_finder").is_in_subtree;

const Self = @This();
const OutOfMemoryError = error{OutOfMemory};

pub const FilePos = struct {
    row: usize = 0,
    col: usize = 0,
};

pub const File = struct {
    path: []const u8,
    mtime: i128,
    pos: FilePos = .{},
    visited: bool = false,
};

allocator: std.mem.Allocator,
files: std.ArrayList(File) = .empty,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    for (self.files.items) |file| self.allocator.free(file.path);
    self.files.deinit(self.allocator);
}

/// A file was used at `mtime`, and visited at `pos` if it is not null.
pub fn update(self: *Self, path: []const u8, pos: ?FilePos, mtime: i128) OutOfMemoryError!void {
    if (self.find(path)) |i| {
        const file = &self.files.items[i];
        file.mtime = mtime;
        if (pos) |visited_pos| {
            file.pos = visited_pos;
            file.visited = true;
        }
        return;
    }
    const owned_path = try self.allocator.dupe(u8, path);
    errdefer self.allocator.free(owned_path);
    try self.files.append(self.allocator, .{
        .path = owned_path,
        .mtime = mtime,
        .pos = pos orelse .{},
        .visited = pos != null,
    });
}

/// The position to restore for a used file.
pub fn position(self: *const Self, path: []const u8) ?FilePos {
    const i = self.find(path) orelse return null;
    return self.files.items[i].pos;
}

/// A file or directory was renamed outside of flow. A file renamed onto a
/// used file replaces it, but its state is kept, as for a save that renames a
/// temporary file. Files of a directory keep theirs: a directory can only be
/// renamed onto one without files, so a used file at a new path is stale.
pub fn renamed(self: *Self, from_path: []const u8, to_path: []const u8) OutOfMemoryError!void {
    if (std.mem.eql(u8, from_path, to_path)) return;

    // Allocate every replacement before changing the list, so OOM leaves it
    // unchanged. The source paths stay valid until their move is applied.
    const exact_path = if (self.find(to_path) == null and self.find(from_path) != null)
        try self.allocator.dupe(u8, to_path)
    else
        null;
    errdefer if (exact_path) |path| self.allocator.free(path);
    const Move = struct { from: []const u8, to: []u8 };
    var moves: std.ArrayList(Move) = .empty;
    defer moves.deinit(self.allocator);
    errdefer for (moves.items) |move| self.allocator.free(move.to);
    for (self.files.items) |file| {
        if (!is_in_subtree(file.path, from_path)) continue;
        const new_path = try std.mem.concat(self.allocator, u8, &.{ to_path, file.path[from_path.len..] });
        moves.append(self.allocator, .{ .from = file.path, .to = new_path }) catch |e| {
            self.allocator.free(new_path);
            return e;
        };
    }

    // Nothing below can fail.
    if (self.find(to_path) != null) {
        self.remove(from_path);
    } else if (self.find(from_path)) |i| {
        self.allocator.free(self.files.items[i].path);
        self.files.items[i].path = exact_path.?;
    }
    for (moves.items) |move| {
        const i = self.find(move.from).?;
        const file = &self.files.items[i];
        if (self.find(move.to)) |stale| {
            // the moved file takes the place of the stale one
            const target = &self.files.items[stale];
            target.mtime = file.mtime;
            target.pos = file.pos;
            target.visited = file.visited;
            self.remove_at(i);
            self.allocator.free(move.to);
        } else {
            self.allocator.free(file.path);
            file.path = move.to;
        }
    }
}

/// A file or directory was deleted outside of flow.
pub fn deleted(self: *Self, path: []const u8) void {
    self.remove(path);
    var i: usize = 0;
    while (i < self.files.items.len) {
        if (!is_in_subtree(self.files.items[i].path, path)) {
            i += 1;
            continue;
        }
        self.remove_at(i); // fills i with the last entry, so don't advance
    }
}

/// Sort the most recently used files first.
pub fn sort(self: *Self) void {
    std.mem.sort(File, self.files.items, {}, struct {
        fn newer_first(_: void, lhs: File, rhs: File) bool {
            return lhs.mtime > rhs.mtime;
        }
    }.newer_first);
}

fn find(self: *const Self, path: []const u8) ?usize {
    for (self.files.items, 0..) |file, i|
        if (std.mem.eql(u8, file.path, path)) return i;
    return null;
}

fn remove(self: *Self, path: []const u8) void {
    if (self.find(path)) |i| self.remove_at(i);
}

fn remove_at(self: *Self, i: usize) void {
    self.allocator.free(self.files.items[i].path);
    _ = self.files.swapRemove(i);
}

const testing = std.testing;

fn expect_files(files: *Self, expected: []const []const u8) !void {
    files.sort();
    try testing.expectEqual(expected.len, files.files.items.len);
    for (expected, files.files.items) |path, file|
        try testing.expectEqualStrings(path, file.path);
}

test "RecentFiles keeps the position of visited files" {
    var files: Self = .init(testing.allocator);
    defer files.deinit();
    try files.update("a", null, 10);
    try testing.expectEqual(FilePos{}, files.position("a").?);
    try files.update("a", .{ .row = 3, .col = 4 }, 20);
    try files.update("a", null, 30); // opening it again keeps the position
    try testing.expectEqual(FilePos{ .row = 3, .col = 4 }, files.position("a").?);
    try testing.expect(files.files.items[0].visited);
    try testing.expectEqual(@as(i128, 30), files.files.items[0].mtime);
    try testing.expectEqual(@as(?FilePos, null), files.position("b"));
}

test "RecentFiles follows renames and deletes of files and directories" {
    var files: Self = .init(testing.allocator);
    defer files.deinit();
    try files.update("dir/a", .{ .row = 1 }, 40);
    try files.update("dir/sub/b", null, 30);
    try files.update("dirt", null, 20);
    try files.update("c", .{ .row = 2 }, 10);

    try files.renamed("c", "d");
    try testing.expectEqual(FilePos{ .row = 2 }, files.position("d").?);
    try files.renamed("dir", "moved");
    try expect_files(&files, &.{ "moved/a", "moved/sub/b", "dirt", "d" });

    // a rename onto a used file drops the source and keeps the target
    try files.renamed("dirt", "d");
    try expect_files(&files, &.{ "moved/a", "moved/sub/b", "d" });
    try testing.expectEqual(FilePos{ .row = 2 }, files.position("d").?);
    try files.renamed("unknown", "e"); // not a used file
    try expect_files(&files, &.{ "moved/a", "moved/sub/b", "d" });

    files.deleted("moved/sub");
    try expect_files(&files, &.{ "moved/a", "d" });
    files.deleted("d");
    files.deleted("unknown");
    try expect_files(&files, &.{"moved/a"});
}

test "RecentFiles directory rename onto used files replaces them" {
    var files: Self = .init(testing.allocator);
    defer files.deinit();
    try files.update("a/x", .{ .row = 7 }, 30);
    try files.update("b/x", .{ .row = 1 }, 20);
    try files.update("b/y", null, 10);
    try files.renamed("b", "a");
    try expect_files(&files, &.{ "a/x", "a/y" });
    // the moved file keeps its state, not the stale one at its new path
    try testing.expectEqual(FilePos{ .row = 1 }, files.position("a/x").?);
    try testing.expectEqual(@as(i128, 20), files.files.items[0].mtime);
    // a rename onto itself changes nothing
    try files.renamed("a/x", "a/x");
    try expect_files(&files, &.{ "a/x", "a/y" });
}

test "RecentFiles rename that runs out of memory leaves the list unchanged" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var files: Self = .init(failing.allocator());
    defer files.deinit();
    try files.update("dir/a", .{ .row = 1 }, 20);
    try files.update("dir/b", .{ .row = 2 }, 10);

    var failures: usize = 0;
    while (true) : (failures += 1) {
        failing.fail_index = failing.alloc_index + failures;
        if (files.renamed("dir", "moved")) |_| break else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try expect_files(&files, &.{ "dir/a", "dir/b" });
        }
    }
    failing.fail_index = std.math.maxInt(usize);
    try testing.expect(failures > 0);
    try expect_files(&files, &.{ "moved/a", "moved/b" });
}
