//! A list of project files ordered by recency, matched by name.
//!
//! A file's recency is the newer of the last time it was used in flow and its
//! modification time on disk. An update that makes a file newer moves it up,
//! which keeps the list in order without sorting it, as frequent updates
//! (every edit reports a use) mostly concern the files at the top. Changes
//! that would move entries far are left to a sort before the list is read.

const std = @import("std");
const tp = @import("thespian");

const file_finder = @import("file_finder.zig");
const file_type = @import("file_type.zig");

const Self = @This();
const OutOfMemoryError = error{OutOfMemory};

pub const File = struct {
    path: []const u8,
    type: []const u8 = "",
    icon: []const u8 = "",
    color: u24 = 0,
    mtime: i128 = 0,
    /// Whether `mtime` is recency rather than the placeholder above.
    mtime_known: bool = false,
    /// The stat request allowed to update or remove this entry.
    stat_generation: usize = 0,
    /// Reported as used by the owner, and therefore kept when a later
    /// enumeration of the project no longer lists it.
    used: bool = false,
    /// Retained despite being absent from the latest enumeration.
    needs_stat: bool = false,
    meta_resolved: bool = false,
};

/// What `merge` does with listed files that are missing from a new
/// enumeration.
pub const Unlisted = enum {
    /// Keep them all. Used for the initial enumeration, when the list only
    /// holds restored or already used files.
    keep_all,
    /// Keep only used files, so that deleted files leave the list.
    keep_used,
};

allocator: std.mem.Allocator,
/// Borrowed for the lifetime of the list.
root_path: []const u8,
files: std.ArrayList(File) = .empty,
/// Path to position in `files`, kept current on every structural change.
/// The keys are owned by the entries in `files`.
index: std.StringHashMapUnmanaged(u32) = .empty,
/// `files` must be sorted by recency before it is read.
unsorted: bool = false,
longest: usize = 0,

/// How far an update moves a file up to keep the list in order. Moving
/// further leaves the order to the next sort, so that bursts of updates, like
/// the modification times of a new listing, stay cheap.
pub const max_reorder: usize = 1024;

pub fn init(allocator: std.mem.Allocator, root_path: []const u8) Self {
    return .{ .allocator = allocator, .root_path = root_path };
}

pub fn deinit(self: *Self) void {
    for (self.files.items) |file| self.allocator.free(file.path);
    self.files.deinit(self.allocator);
    self.index.deinit(self.allocator);
}

pub fn count(self: *const Self) usize {
    return self.files.items.len;
}

pub fn contains(self: *const Self, path: []const u8) bool {
    return self.index.contains(path);
}

pub fn is_used(self: *const Self, path: []const u8) bool {
    const i = self.index.get(path) orelse return false;
    return self.files.items[i].used;
}

/// A file was opened or visited at `mtime`.
pub fn update_mru(self: *Self, path: []const u8, mtime: i128) OutOfMemoryError!void {
    if (self.index.get(path)) |i| {
        const file = &self.files.items[i];
        const was_known = file.mtime_known;
        _ = set_mtime(file, mtime);
        file.stat_generation = 0;
        file.used = true;
        self.reorder_after_mtime(i, was_known, mtime);
        return;
    }
    return self.append_owned(try self.allocator.dupe(u8, path), mtime, true);
}

/// Apply the result of the current stat request.
pub fn stat_succeeded(self: *Self, path: []const u8, generation: usize, mtime: i128) void {
    const i = self.index.get(path) orelse return;
    const file = &self.files.items[i];
    if (file.stat_generation != generation) return;
    file.stat_generation = 0;
    const was_known = file.mtime_known;
    if (!set_mtime(file, mtime)) return;
    self.reorder_after_mtime(i, was_known, mtime);
}

/// Clear a failed stat request without changing the file.
pub fn stat_errored(self: *Self, path: []const u8, generation: usize) void {
    const i = self.index.get(path) orelse return;
    const file = &self.files.items[i];
    if (file.stat_generation == generation) file.stat_generation = 0;
}

/// A file was created at `mtime`.
pub fn add(self: *Self, path: []const u8, mtime: i128) OutOfMemoryError!void {
    if (self.contains(path)) return self.modified(path, mtime);
    return self.append_owned(try self.allocator.dupe(u8, path), mtime, false);
}

/// A file was modified at `mtime`.
pub fn modified(self: *Self, path: []const u8, mtime: i128) void {
    const i = self.index.get(path) orelse return;
    const file = &self.files.items[i];
    file.stat_generation = 0;
    const was_known = file.mtime_known;
    if (!set_mtime(file, mtime)) return;
    self.reorder_after_mtime(i, was_known, mtime);
}

/// A file was deleted. Returns whether it was listed.
pub fn remove(self: *Self, path: []const u8) bool {
    const i = self.index.get(path) orelse return false;
    self.remove_at(i);
    return true;
}

/// Remove a file when its current stat request reports that it is missing.
pub fn stat_failed(self: *Self, path: []const u8, generation: usize) bool {
    const i = self.index.get(path) orelse return false;
    if (self.files.items[i].stat_generation != generation) return false;
    self.remove_at(i);
    return true;
}

/// A file was renamed at `mtime`. A file already listed at `to_path` is kept
/// and `from_path` is dropped, as the rename replaced it. Returns whether
/// `from_path` was listed.
pub fn rename(self: *Self, from_path: []const u8, to_path: []const u8, mtime: i128) OutOfMemoryError!bool {
    const source_i = self.index.get(from_path);
    const source_used = if (source_i) |i| self.files.items[i].used else false;
    const source_mtime = if (source_i) |i| self.files.items[i].mtime else 0;
    const source_mtime_known = if (source_i) |i| self.files.items[i].mtime_known else false;
    if (self.get(to_path)) |replaced| {
        // Update before removing, which may move entries. The destination was
        // modified by the replacement and inherits the source's recency.
        _ = set_mtime(replaced, mtime);
        if (source_mtime_known) _ = set_mtime(replaced, source_mtime);
        replaced.stat_generation = 0;
        replaced.used = replaced.used or source_used;
        replaced.meta_resolved = false;
        self.unsorted = true;
        if (std.mem.eql(u8, from_path, to_path)) return true;
        return self.remove(from_path);
    }
    const i = source_i orelse {
        try self.add(to_path, mtime);
        return false;
    };
    const new_path = try self.allocator.dupe(u8, to_path);
    errdefer self.allocator.free(new_path);
    try self.index.ensureUnusedCapacity(self.allocator, 1);
    const file = &self.files.items[i];
    // re-key before freeing the old path, which the old key points into
    _ = self.index.remove(file.path);
    self.allocator.free(file.path);
    file.path = new_path;
    _ = set_mtime(file, mtime);
    file.stat_generation = 0;
    file.meta_resolved = false;
    self.index.putAssumeCapacity(file.path, @intCast(i));
    self.longest = @max(self.longest, new_path.len);
    self.reorder_after_mtime(i, source_mtime_known, mtime);
    return true;
}

/// A directory was deleted. Returns the number of files removed.
pub fn remove_subtree(self: *Self, dir_path: []const u8) usize {
    var removed: usize = 0;
    var i: usize = 0;
    while (i < self.files.items.len) {
        if (!is_in_subtree(self.files.items[i].path, dir_path)) {
            i += 1;
            continue;
        }
        self.remove_at(i); // fills i with the last entry, so don't advance
        removed += 1;
    }
    return removed;
}

/// A directory was renamed. Returns the number of files renamed. A renamed
/// file replaces a file that was listed at its new path, like a renamed file
/// does in `rename`, so that no path is listed twice. On error, the list is
/// unchanged.
pub fn rename_subtree(self: *Self, from_path: []const u8, to_path: []const u8) OutOfMemoryError!usize {
    // all new paths first, so that running out of memory changes nothing
    var new_paths: std.ArrayList([]const u8) = .empty;
    defer new_paths.deinit(self.allocator);
    errdefer for (new_paths.items) |path| self.allocator.free(path);
    for (self.files.items) |file| {
        if (!is_in_subtree(file.path, from_path)) continue;
        const new_path = try std.mem.concat(self.allocator, u8, &.{ to_path, file.path[from_path.len..] });
        new_paths.append(self.allocator, new_path) catch |e| {
            self.allocator.free(new_path);
            return e;
        };
    }
    if (new_paths.items.len == 0) return 0;

    // nothing below can fail
    var next: usize = 0;
    for (self.files.items) |*file| {
        if (!is_in_subtree(file.path, from_path)) continue;
        self.allocator.free(file.path);
        file.path = new_paths.items[next];
        file.stat_generation = 0;
        next += 1;
        self.longest = @max(self.longest, file.path.len);
    }
    // The old keys point into freed paths, so rebuild the index. A path now
    // listed twice keeps its first file, which is the newer one in a sorted
    // list, so that the order holds, and gets what the other one adds.
    self.index.clearRetainingCapacity();
    var kept: usize = 0;
    for (self.files.items) |file| {
        const entry = self.index.getOrPutAssumeCapacity(file.path);
        if (entry.found_existing) {
            const first = &self.files.items[entry.value_ptr.*];
            if (file.mtime_known) {
                if (!first.mtime_known and file.mtime < 0) self.unsorted = true;
                _ = set_mtime(first, file.mtime);
            }
            first.stat_generation = 0;
            first.used = first.used or file.used;
            first.meta_resolved = false;
            self.allocator.free(file.path);
            continue;
        }
        entry.value_ptr.* = @intCast(kept);
        self.files.items[kept] = file;
        kept += 1;
    }
    self.files.shrinkRetainingCapacity(kept);
    return new_paths.items.len;
}

/// Replace the list with a fresh enumeration of the project, carrying the
/// recency of files that are still listed over. `listed` maps every unique
/// pending path to its first position. Takes ownership of the paths in
/// `pending` and leaves both inputs empty. On error, all are unchanged.
pub fn merge(
    self: *Self,
    pending: *std.ArrayList([]const u8),
    listed: *std.StringHashMapUnmanaged(u32),
    unlisted: Unlisted,
) OutOfMemoryError!void {
    var kept: usize = 0;
    for (self.files.items) |file| {
        if (!listed.contains(file.path) and (unlisted == .keep_all or file.used)) kept += 1;
    }
    // Reserve exactly the merged list and its index, see `reindex`. A re-sync
    // of the same files then needs no more room than the list already has.
    const merged = listed.count() + kept;
    var fresh: std.ArrayList(File) = .empty;
    errdefer fresh.deinit(self.allocator);
    try fresh.ensureTotalCapacityPrecise(self.allocator, merged);
    try self.index.ensureTotalCapacity(self.allocator, @intCast(merged));

    // nothing below can fail
    var longest: usize = 0;
    for (pending.items, 0..) |path, i| {
        const position = listed.getPtr(path).?;
        // Not the first listing of the path: the position is that of its
        // first listing, or already the one in `fresh`, both before `i`.
        if (position.* != i) {
            self.allocator.free(path);
            continue;
        }
        position.* = @intCast(fresh.items.len);
        fresh.appendAssumeCapacity(.{ .path = path });
        longest = @max(longest, path.len);
    }
    pending.clearRetainingCapacity();

    for (self.files.items) |file| {
        if (listed.get(file.path)) |i| {
            const listed_file = &fresh.items[i];
            listed_file.mtime = file.mtime;
            listed_file.mtime_known = file.mtime_known;
            listed_file.stat_generation = file.stat_generation;
            listed_file.used = file.used;
            listed_file.type = file.type;
            listed_file.icon = file.icon;
            listed_file.color = file.color;
            listed_file.meta_resolved = file.meta_resolved;
            self.allocator.free(file.path);
        } else if (unlisted == .keep_all or file.used) {
            var retained = file;
            retained.needs_stat = true;
            fresh.appendAssumeCapacity(retained);
            longest = @max(longest, file.path.len);
        } else {
            self.allocator.free(file.path);
        }
    }

    self.files.deinit(self.allocator);
    self.files = fresh;
    self.longest = longest;
    self.reindex();
    self.unsorted = true;
    listed.clearRetainingCapacity();
}

/// The path of the `n`th most recent file.
pub fn nth_most_recent(self: *Self, n: usize) ?[]const u8 {
    self.refresh_order();
    return if (n < self.files.items.len) self.files.items[n].path else null;
}

/// Send the most recent files to `to`.
pub fn send_recent(self: *Self, to: tp.pid_ref, max: usize) void {
    self.refresh_order();
    defer file_finder.send_recent_done(to, self.longest, "", self.files.items.len);
    const recipient: Recipient = .{ .list = self, .to = to };
    for (self.files.items, 0..) |*file, i| {
        if (!recipient.send(file, null)) return;
        if (i >= max) return;
    }
}

/// Send the best matches for `query` to `to`. Returns the number sent.
pub fn send_query(self: *Self, to: tp.pid_ref, max: usize, query: []const u8) OutOfMemoryError!usize {
    self.refresh_order();
    defer file_finder.send_recent_done(to, self.longest, query, self.files.items.len);
    return file_finder.send_matches(self.allocator, self.files.items, max, query, Recipient{ .list = self, .to = to });
}

/// Sends files of the list as the results of a request or query.
const Recipient = struct {
    list: *const Self,
    to: tp.pid_ref,

    pub fn send(self: Recipient, file: *File, matches: ?[]const usize) bool {
        self.list.resolve_meta(file);
        file_finder.send_recent(self.to, self.list.longest, file.path, file.type, file.icon, file.color, matches) catch |e| {
            std.log.err("send recent failed: {t}", .{e});
            return false;
        };
        return true;
    }
};

/// Sort by recency if anything changed since the last sort.
pub fn refresh_order(self: *Self) void {
    if (!self.unsorted) return;
    self.unsorted = false;
    // stable, so files of equal recency keep their relative order
    std.mem.sort(File, self.files.items, {}, struct {
        fn newer_first(_: void, lhs: File, rhs: File) bool {
            return lhs.mtime > rhs.mtime;
        }
    }.newer_first);
    self.reindex();
}

fn get(self: *Self, path: []const u8) ?*File {
    const i = self.index.get(path) orelse return null;
    return &self.files.items[i];
}

fn append_owned(self: *Self, owned_path: []const u8, mtime: i128, used: bool) OutOfMemoryError!void {
    errdefer self.allocator.free(owned_path);
    try self.files.ensureUnusedCapacity(self.allocator, 1);
    try self.index.put(self.allocator, owned_path, @intCast(self.files.items.len));
    self.files.appendAssumeCapacity(.{ .path = owned_path, .mtime = mtime, .mtime_known = true, .used = used });
    self.longest = @max(self.longest, owned_path.len);
    self.reorder(self.files.items.len - 1);
}

/// The file at `i` became newer. Move it up to keep the list in order, unless
/// it is unsorted anyway or the move would be longer than `max_reorder`.
fn reorder(self: *Self, i: usize) void {
    if (self.unsorted) return;
    const items = self.files.items;
    const file = items[i];
    // The first position before `i` with an older file. Files of the same
    // recency stay before it, as they would in a stable sort.
    var to: usize = 0;
    var end: usize = i;
    while (to < end) {
        const mid = to + (end - to) / 2;
        if (items[mid].mtime >= file.mtime) to = mid + 1 else end = mid;
    }
    if (to == i) return;
    if (i - to > max_reorder) {
        self.unsorted = true;
        return;
    }
    @memmove(items[to + 1 .. i + 1], items[to..i]);
    items[to] = file;
    for (items[to .. i + 1], to..) |moved, position|
        self.index.getPtr(moved.path).?.* = @intCast(position);
}

fn set_mtime(file: *File, mtime: i128) bool {
    if (file.mtime_known and mtime <= file.mtime) return false;
    file.mtime = mtime;
    file.mtime_known = true;
    return true;
}

fn reorder_after_mtime(self: *Self, i: usize, was_known: bool, mtime: i128) void {
    if (!was_known and mtime < 0)
        self.unsorted = true
    else
        self.reorder(i);
}

fn remove_at(self: *Self, i: usize) void {
    const file = self.files.swapRemove(i);
    // drop the key before freeing the path it points into
    _ = self.index.remove(file.path);
    self.allocator.free(file.path);
    if (i < self.files.items.len)
        self.index.getPtr(self.files.items[i].path).?.* = @intCast(i);
    self.unsorted = true;
}

/// Rebuild `index` after `files` was reordered or replaced. This cannot
/// fail, so the index never silently loses files: it already has room for
/// all of them, as every change that adds files reserves it first.
fn reindex(self: *Self) void {
    self.index.clearRetainingCapacity();
    for (self.files.items, 0..) |file, i|
        self.index.putAssumeCapacity(file.path, @intCast(i));
}

fn resolve_meta(self: *const Self, file: *File) void {
    if (file.meta_resolved) return;
    const file_type_name, const file_icon, const file_color = file_type.guess_path_file_type(self.root_path, file.path);
    file.type = file_type_name;
    file.icon = file_icon;
    file.color = file_color;
    file.meta_resolved = true;
}

pub const is_in_subtree = file_finder.is_in_subtree;

const testing = std.testing;

fn expect_order(list: *Self, expected: []const []const u8) !void {
    list.refresh_order();
    try testing.expectEqual(expected.len, list.count());
    for (expected, list.files.items, 0..) |path, file, i| {
        try testing.expectEqualStrings(path, file.path);
        try testing.expectEqual(@as(u32, @intCast(i)), list.index.get(path).?);
    }
}

fn pending_list(paths: []const []const u8) !std.ArrayList([]const u8) {
    var pending: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (pending.items) |path| testing.allocator.free(path);
        pending.deinit(testing.allocator);
    }
    for (paths) |path| try pending.append(testing.allocator, try testing.allocator.dupe(u8, path));
    return pending;
}

fn merge_pending(list: *Self, pending: *std.ArrayList([]const u8), unlisted: Unlisted) !void {
    var listed: std.StringHashMapUnmanaged(u32) = .empty;
    defer listed.deinit(testing.allocator);
    try listed.ensureTotalCapacity(testing.allocator, @intCast(pending.items.len));
    for (pending.items, 0..) |path, i| {
        const entry = listed.getOrPutAssumeCapacity(path);
        if (!entry.found_existing) entry.value_ptr.* = @intCast(i);
    }
    return list.merge(pending, &listed, unlisted);
}

test "FileList orders by the newer of use and disk modification" {
    var list: Self = .init(testing.allocator, ".");
    defer list.deinit();
    try list.update_mru("a", 10);
    try list.update_mru("b", 20);
    try expect_order(&list, &.{ "b", "a" });

    list.get("a").?.stat_generation = 1;
    list.stat_succeeded("a", 1, 30);
    try expect_order(&list, &.{ "a", "b" });
    list.get("a").?.stat_generation = 2;
    list.stat_succeeded("a", 2, 5); // older times never move a file back
    try expect_order(&list, &.{ "a", "b" });
    try list.add("a", 35); // a create event also refreshes an existing path
    try expect_order(&list, &.{ "a", "b" });

    try list.add("missing", 0);
    list.get("missing").?.stat_generation = 3;
    try testing.expect(list.stat_failed("missing", 3));
    try list.add("created", 0);
    list.get("created").?.stat_generation = 4;
    try list.add("created", 1);
    try testing.expect(!list.stat_failed("created", 4));
    list.stat_succeeded("created", 4, 100); // the stale success is ignored too
    try testing.expectEqual(@as(i128, 1), list.get("created").?.mtime);
    try testing.expect(list.remove("created"));

    try list.add("old", -10);
    list.get("old").?.stat_generation = 5;
    list.stat_errored("old", 5);
    try testing.expectEqual(@as(i128, -10), list.get("old").?.mtime);
    try testing.expectEqual(@as(usize, 0), list.get("old").?.stat_generation);
    try testing.expect(list.remove("old"));

    try list.update_mru("b", 40);
    try testing.expectEqualStrings("b", list.nth_most_recent(0).?);
    try testing.expectEqualStrings("a", list.nth_most_recent(1).?);
    try testing.expectEqual(@as(?[]const u8, null), list.nth_most_recent(2));
}

test "FileList records zero and negative stat mtimes" {
    var list: Self = .init(testing.allocator, ".");
    defer list.deinit();
    var pending = try pending_list(&.{ "zero", "negative" });
    defer pending.deinit(testing.allocator);
    try merge_pending(&list, &pending, .keep_all);
    try expect_order(&list, &.{ "zero", "negative" });

    list.get("zero").?.stat_generation = 1;
    list.stat_succeeded("zero", 1, 0);
    list.get("negative").?.stat_generation = 1;
    list.stat_succeeded("negative", 1, -1);
    try testing.expect(list.get("zero").?.mtime_known);
    try testing.expect(list.get("negative").?.mtime_known);
    try testing.expectEqual(@as(i128, -1), list.get("negative").?.mtime);
    try expect_order(&list, &.{ "zero", "negative" });
}

test "FileList merge carries recency and keeps unlisted files as asked" {
    var list: Self = .init(testing.allocator, ".");
    defer list.deinit();
    try list.update_mru("restored", 50);
    try list.add("created", 40);

    var pending = try pending_list(&.{ "listed", "restored", "listed" });
    defer pending.deinit(testing.allocator);
    try merge_pending(&list, &pending, .keep_all);
    try testing.expectEqual(@as(usize, 0), pending.items.len);
    try expect_order(&list, &.{ "restored", "created", "listed" });
    try testing.expect(list.is_used("restored"));
    try testing.expect(!list.is_used("created"));
    try testing.expectEqual("restored".len, list.longest);

    // a re-sync drops files that are no longer listed, unless they were used
    var resync = try pending_list(&.{"listed"});
    defer resync.deinit(testing.allocator);
    try merge_pending(&list, &resync, .keep_used);
    try expect_order(&list, &.{ "restored", "listed" });

    // A successful empty re-sync is authoritative, but preserves used files.
    var empty: std.ArrayList([]const u8) = .empty;
    defer empty.deinit(testing.allocator);
    try merge_pending(&list, &empty, .keep_used);
    try expect_order(&list, &.{"restored"});
}

test "FileList merge that runs out of memory leaves the list unchanged" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var list: Self = .init(failing.allocator(), ".");
    defer list.deinit();
    try list.update_mru("a", 10);
    try list.update_mru("b", 20);
    try expect_order(&list, &.{ "b", "a" });

    // Fail each allocation of the merge in turn, until it succeeds. The
    // listing outgrows the index, so reserving the index allocates too.
    const listing = [_][]const u8{ "a", "c", "d", "e", "f", "g", "h", "i" };
    var failures: usize = 0;
    while (true) {
        var pending: std.ArrayList([]const u8) = .empty;
        defer {
            for (pending.items) |path| testing.allocator.free(path);
            pending.deinit(testing.allocator);
        }
        for (listing) |path| try pending.append(testing.allocator, try testing.allocator.dupe(u8, path));

        failing.fail_index = failing.alloc_index + failures;
        if (merge_pending(&list, &pending, .keep_used)) |_| break else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            // unchanged, consistently indexed, and the paths not taken over
            try expect_order(&list, &.{ "b", "a" });
            try testing.expectEqual(listing.len, pending.items.len);
            failures += 1;
        }
    }
    failing.fail_index = std.math.maxInt(usize);
    try testing.expect(failures > 0);
    try expect_order(&list, &.{ "b", "a", "c", "d", "e", "f", "g", "h", "i" });
}

test "FileList merge reserves only the merged list" {
    var list: Self = .init(testing.allocator, ".");
    defer list.deinit();
    const listing = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" };
    var first = try pending_list(&listing);
    defer first.deinit(testing.allocator);
    try merge_pending(&list, &first, .keep_all);
    const index_capacity = list.index.capacity();

    // a re-sync of the same files, one listed twice, needs no more room
    var resync = try pending_list(&(listing ++ [_][]const u8{"a"}));
    defer resync.deinit(testing.allocator);
    try merge_pending(&list, &resync, .keep_used);
    try testing.expectEqual(listing.len, list.count());
    try testing.expectEqual(list.files.items.len, list.files.capacity);
    try testing.expectEqual(index_capacity, list.index.capacity());
}

test "FileList keeps its order on updates without sorting it again" {
    var list: Self = .init(testing.allocator, ".");
    defer list.deinit();
    try list.update_mru("a", 10);
    try list.add("b", 20);
    try list.add("c", 30);
    try expect_order(&list, &.{ "c", "b", "a" });

    // checked before reading, as a read would sort the list
    try list.update_mru("a", 40);
    try testing.expect(!list.unsorted);
    try expect_order(&list, &.{ "a", "c", "b" });
    list.get("b").?.stat_generation = 5;
    list.stat_succeeded("b", 5, 35);
    try testing.expect(!list.unsorted);
    try expect_order(&list, &.{ "a", "b", "c" });
    // of equal recency, the file that was first stays first
    list.modified("c", 40);
    try testing.expect(!list.unsorted);
    try expect_order(&list, &.{ "a", "c", "b" });
    try testing.expect(try list.rename("b", "renamed", 50));
    try testing.expect(!list.unsorted);
    try expect_order(&list, &.{ "renamed", "a", "c" });
    try list.add("d", 60);
    try testing.expect(!list.unsorted);
    try expect_order(&list, &.{ "d", "renamed", "a", "c" });
}

test "FileList leaves a longer move to the next sort" {
    var list: Self = .init(testing.allocator, ".");
    defer list.deinit();
    var buf: [16]u8 = undefined;
    const files = max_reorder + 2;
    for (0..files) |n|
        try list.add(try std.fmt.bufPrint(&buf, "f{d}", .{n}), @intCast(files - n));
    list.refresh_order();
    try testing.expect(!list.unsorted);

    // the oldest file becomes the newest: further than max_reorder
    const oldest = try std.fmt.bufPrint(&buf, "f{d}", .{files - 1});
    try list.update_mru(oldest, files + 1);
    try testing.expect(list.unsorted);
    try testing.expectEqualStrings(oldest, list.nth_most_recent(0).?);
    try testing.expect(!list.unsorted);
}

test "FileList directory rename onto listed files replaces them" {
    var list: Self = .init(testing.allocator, ".");
    defer list.deinit();
    // a used file in the directory to rename onto, e.g. an unsaved buffer
    try list.update_mru("a/x", 30);
    try list.add("m", 20);
    try list.add("b/x", 10);
    try list.add("b/y", 5);
    try testing.expectEqual(@as(usize, 2), try list.rename_subtree("b", "a"));
    // each path once, with the newer recency and the use of the two
    try testing.expectEqual(@as(usize, 3), list.count());
    try testing.expectEqual(@as(usize, 3), list.index.count());
    try testing.expect(list.is_used("a/x"));
    try testing.expectEqual(@as(i128, 30), list.get("a/x").?.mtime);
    try testing.expect(list.contains("a/y"));
    try testing.expect(!list.contains("b/x"));
    try testing.expect(!list.unsorted);
    // the sequence that crashed: a use that moves files up, then a removal
    try list.update_mru("m", 40);
    try testing.expect(list.remove("a/x"));
    try testing.expect(!list.contains("a/x"));
    try expect_order(&list, &.{ "m", "a/y" });
}

test "FileList follows renames and deletes" {
    var list: Self = .init(testing.allocator, ".");
    defer list.deinit();
    try list.update_mru("dir/a", 10);
    try list.add("dir/b", 20);
    try list.add("other", 30);
    try list.add("dirt", 40);

    try testing.expect(try list.rename("other", "renamed", 50));
    try expect_order(&list, &.{ "renamed", "dirt", "dir/b", "dir/a" });

    // a rename onto a listed file replaces it, records the replacement time,
    // invalidates metadata, and keeps it if the source was used
    list.get("renamed").?.meta_resolved = true;
    try testing.expect(try list.rename("dirt", "renamed", 60));
    try expect_order(&list, &.{ "renamed", "dir/b", "dir/a" });
    try testing.expectEqual(@as(i128, 60), list.get("renamed").?.mtime);
    try testing.expect(!list.get("renamed").?.meta_resolved);
    try testing.expect(!list.is_used("renamed"));
    try list.add("used", 5);
    try list.update_mru("used", 5);
    list.get("renamed").?.meta_resolved = true;
    try testing.expect(try list.rename("used", "renamed", 65));
    try testing.expectEqual(@as(i128, 65), list.get("renamed").?.mtime);
    try testing.expect(!list.get("renamed").?.meta_resolved);
    try testing.expect(list.is_used("renamed"));
    try expect_order(&list, &.{ "renamed", "dir/b", "dir/a" });

    // a rename of an unlisted file lists its new path
    try testing.expect(!try list.rename("unlisted", "new", 70));
    try testing.expect(list.contains("new"));
    try testing.expect(list.remove("new"));
    try testing.expect(!list.remove("new"));

    try testing.expectEqual(@as(usize, 2), try list.rename_subtree("dir", "moved"));
    try expect_order(&list, &.{ "renamed", "moved/b", "moved/a" });
    try testing.expect(list.is_used("moved/a"));

    try testing.expectEqual(@as(usize, 2), list.remove_subtree("moved"));
    try expect_order(&list, &.{"renamed"});
}
