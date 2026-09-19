//! Project file finders.
//!
//! A file finder is an actor that finds the files of one project by name. Its
//! owner talks to it only through the messages below, so that the owner does
//! not depend on how a finder finds files. Which implementation runs behind a
//! finder's pid is decided when it is spawned.
//!
//! Requests, owner -> finder:
//!
//!   {"request_recent_files", reply_to: piid, max: usize}
//!   {"query_recent_files", reply_to: piid, max: usize, query: string}
//!       Reply to reply_to with zero or more results, most relevant first,
//!         {"PRJ", "recent", longest, path, type, icon, color}            request
//!         {"PRJ", "recent", longest, path, type, icon, color, matches}   query
//!       followed, unless the finder exits, by exactly one
//!         {"PRJ", "recent_done", longest, query, total}
//!       `matches` are byte offsets into `path`. A request lists the most
//!       recently used files. The owner cancels outstanding requests if the
//!       finder exits.
//!
//!   {"request_n_most_recent_file", reply_to: piid, n: usize}
//!       Reply to reply_to with {path} or {null}.
//!
//!   {"update_mru", path: string, mtime: i128}
//!       A project file was opened or visited at `mtime` (real-clock
//!       nanoseconds). Also replays the restored list of recently used
//!       files. No reply.
//!
//!   {"sync"}
//!       (Re)build the finder's view of the project. The first sync starts
//!       indexing, later ones refresh it. A sync asked for while one runs, or
//!       a change of the tree while it runs, makes another run after it. No
//!       reply.
//!
//!   {"shutdown"}
//!
//! Notifications, finder -> owner (the actor that spawned the finder):
//!
//!   {"FF", "ready", longest: usize, count: usize}
//!       Sent once, when the first sync has completed.
//!
//!   {"FF", "renamed", from_path: string, to_path: string}
//!   {"FF", "deleted", path: string}
//!       A listed file or directory was renamed or deleted outside of flow.
//!       Paths inside the project are relative to it; others are absolute.
//!       For a directory, this applies to everything below it. A rename onto
//!       a known file replaces it. Finders may send these while watching or
//!       refreshing the project.

const std = @import("std");
const tp = @import("thespian");
const fuzzig = @import("fuzzig");

pub const builtin_finder = @import("builtin_finder.zig");
pub const external_finder = @import("external_finder.zig");
pub const FileList = @import("FileList.zig");

const file_type = @import("file_type.zig");
pub const guess_file_type = file_type.guess_file_type;
pub const guess_path_file_type = file_type.guess_path_file_type;

pub fn is_in_subtree(file_path: []const u8, dir_path: []const u8) bool {
    if (!std.mem.startsWith(u8, file_path, dir_path)) return false;
    if (file_path.len <= dir_path.len) return false;
    return file_path[dir_path.len] == '/' or file_path[dir_path.len] == '\\';
}

pub const Error = error{FileFinderSendFailed};

/// The owner's handle to a file finder actor.
pub const Handle = struct {
    pid: tp.pid,

    /// Shut the finder down and release the handle.
    pub fn deinit(self: *Handle) void {
        self.pid.send(.{"shutdown"}) catch {};
        self.pid.deinit();
    }

    /// Whether `pid` is this finder, e.g. the sender of a notification.
    pub fn is(self: *const Handle, pid: tp.pid_ref) bool {
        return self.pid.instance_id() == pid.instance_id();
    }

    pub fn request_recent_files(self: *const Handle, reply_to: tp.pid_ref, max: usize) Error!void {
        return self.send(.{ "request_recent_files", reply_to.instance_id(), max });
    }

    pub fn query_recent_files(self: *const Handle, reply_to: tp.pid_ref, max: usize, query: []const u8) Error!void {
        return self.send(.{ "query_recent_files", reply_to.instance_id(), max, query });
    }

    pub fn request_n_most_recent_file(self: *const Handle, reply_to: tp.pid_ref, n: usize) Error!void {
        return self.send(.{ "request_n_most_recent_file", reply_to.instance_id(), n });
    }

    pub fn update_mru(self: *const Handle, path: []const u8, mtime: i128) Error!void {
        return self.send(.{ "update_mru", path, mtime });
    }

    pub fn sync(self: *const Handle) Error!void {
        return self.send(.{"sync"});
    }

    fn send(self: *const Handle, message: anytype) Error!void {
        return self.pid.send(message) catch error.FileFinderSendFailed;
    }
};

/// Send one result of a recent files request or query.
pub fn send_recent(
    to: tp.pid_ref,
    longest: usize,
    file_path: []const u8,
    file_type_name: []const u8,
    file_icon: []const u8,
    file_color: u24,
    matches: ?[]const usize,
) tp.result {
    return if (matches) |match_indexes|
        to.send(.{ "PRJ", "recent", longest, file_path, file_type_name, file_icon, file_color, match_indexes })
    else
        to.send(.{ "PRJ", "recent", longest, file_path, file_type_name, file_icon, file_color });
}

/// Complete a recent files request or query.
pub fn send_recent_done(to: tp.pid_ref, longest: usize, query: []const u8, total: usize) void {
    to.send(.{ "PRJ", "recent_done", longest, query, total }) catch {};
}

/// Send the files of `files` whose path matches `query_`, best first and at
/// most `max`, with `found.send(file, offsets)`, where `offsets` are the
/// byte offsets of the matched characters in the path. A query of fewer than
/// three characters matches a part of the path, a longer one fuzzily. Files
/// that match equally well stay in the order of `files`. Returns the number
/// sent; `send` returns false to stop.
pub fn send_matches(allocator: std.mem.Allocator, files: anytype, max: usize, query_: []const u8, found: anytype) error{OutOfMemory}!usize {
    if (max == 0) return 0;
    const query = try strip_non_search_chars(allocator, query_);
    defer allocator.free(query);
    if (query.len < 3) {
        var offsets: [2]usize = undefined;
        var sent: usize = 0;
        for (files) |*file| {
            if (sent >= max) break;
            const start = std.mem.indexOf(u8, file.path, query) orelse continue;
            for (offsets[0..query.len], start..) |*offset, n| offset.* = n;
            if (!found.send(file, offsets[0..query.len])) break;
            sent += 1;
        }
        return sent;
    }

    var searcher = try fuzzig.Ascii.init(
        allocator,
        4096, // haystack max size
        4096, // needle max size
        .{ .case_sensitive = false },
    );
    defer searcher.deinit();

    const Match = struct { index: usize, score: i32 };
    var best: std.ArrayList(Match) = .empty;
    defer best.deinit(allocator);
    for (files, 0..) |file, index| {
        const score = searcher.scoreMatches(file.path, query).score orelse continue;
        var at: usize = 0;
        while (at < best.items.len and best.items[at].score >= score) : (at += 1) {}
        if (at >= max) continue;
        if (best.items.len < max) try best.append(allocator, undefined);
        @memmove(best.items[at + 1 ..], best.items[at .. best.items.len - 1]);
        best.items[at] = .{ .index = index, .score = score };
    }
    for (best.items, 0..) |match, sent| {
        const offsets = searcher.scoreMatches(files[match.index].path, query).matches;
        if (!found.send(&files[match.index], offsets)) return sent;
    }
    return best.items.len;
}

fn strip_non_search_chars(allocator: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]const u8 {
    var stripped: std.ArrayList(u8) = try .initCapacity(allocator, s.len);
    errdefer stripped.deinit(allocator);
    for (s) |c| switch (c) {
        ' ', '\t', '\n' => {},
        else => stripped.appendAssumeCapacity(c),
    };
    return stripped.toOwnedSlice(allocator);
}

test {
    std.testing.refAllDecls(@This());
}

test "query normalization frees its allocation on error" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{
        .fail_index = 1,
        .resize_fail_index = 0,
    });
    try std.testing.expectError(error.OutOfMemory, strip_non_search_chars(failing.allocator(), "a "));
}

test "send_matches finds parts of paths, and fuzzily for longer queries" {
    const a = std.testing.allocator;
    const Item = struct { path: []const u8 };
    var items = [_]Item{ .{ .path = "src/main.zig" }, .{ .path = "docs/readme.md" }, .{ .path = "src/util.zig" } };
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(a);
    var offsets: std.ArrayList(usize) = .empty;
    defer offsets.deinit(a);
    const Found = struct {
        paths: *std.ArrayList([]const u8),
        offsets: *std.ArrayList(usize),
        fn send(self: @This(), item: *Item, at: []const usize) bool {
            self.paths.append(std.testing.allocator, item.path) catch return false;
            self.offsets.appendSlice(std.testing.allocator, at) catch return false;
            return true;
        }
    };
    const found: Found = .{ .paths = &paths, .offsets = &offsets };

    try std.testing.expectEqual(@as(usize, 0), try send_matches(a, &items, 0, "util", found));

    // fewer than three characters: a part of the path, in the given order
    try std.testing.expectEqual(@as(usize, 2), try send_matches(a, &items, 10, "rc", found));
    try std.testing.expectEqualStrings("src/main.zig", paths.items[0]);
    try std.testing.expectEqualStrings("src/util.zig", paths.items[1]);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 1, 2 }, offsets.items);
    paths.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 1), try send_matches(a, &items, 1, "rc", found));

    // longer: fuzzily, best first, ignoring blanks in the query
    paths.clearRetainingCapacity();
    offsets.clearRetainingCapacity();
    try std.testing.expect(try send_matches(a, &items, 10, " ut il ", found) >= 1);
    try std.testing.expectEqualStrings("src/util.zig", paths.items[0]);
    try std.testing.expectEqualSlices(usize, &.{ 4, 5, 6, 7 }, offsets.items[0..4]);
    paths.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 1), try send_matches(a, &items, 1, "src", found));
    try std.testing.expectEqualStrings("src/main.zig", paths.items[0]);
}
