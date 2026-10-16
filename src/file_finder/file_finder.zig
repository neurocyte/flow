//! Project file finders. A file finder finds the files of one project by
//! name. It keeps them in a FileList, ordered by recency, and replies to
//! recent files requests and queries in the format below. File lists
//! describe each file by its file type, detected here.

const std = @import("std");
const tp = @import("thespian");

pub const FileList = @import("FileList.zig");

const file_type = @import("file_type.zig");
pub const guess_file_type = file_type.guess_file_type;
pub const guess_path_file_type = file_type.guess_path_file_type;

pub fn is_in_subtree(file_path: []const u8, dir_path: []const u8) bool {
    if (!std.mem.startsWith(u8, file_path, dir_path)) return false;
    if (file_path.len <= dir_path.len) return false;
    return file_path[dir_path.len] == '/' or file_path[dir_path.len] == '\\';
}

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

test {
    std.testing.refAllDecls(@This());
}
