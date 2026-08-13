const std = @import("std");

pub const wildmatch = @import("wildmatch.zig");
pub const Pattern = @import("Pattern.zig");
pub const PatternList = @import("PatternList.zig");
pub const Matcher = @import("Matcher.zig");
pub const Sources = @import("Sources.zig");

pub const Precedence = Matcher.Precedence;
pub const Decision = Matcher.Decision;
pub const MatchInfo = Matcher.MatchInfo;
pub const DType = Matcher.DType;
pub const Options = Matcher.Options;

pub const per_directory_file_name = ".gitignore";

const vcs_metadata_dirs = [_][]const u8{ ".git", ".jj" };

pub fn is_vcs_metadata_dir(name: []const u8) bool {
    for (vcs_metadata_dirs) |dir|
        if (std.mem.eql(u8, dir, name)) return true;
    return false;
}

pub fn in_vcs_metadata_dir(rel_path: []const u8) bool {
    var it = std.mem.splitAny(u8, rel_path, "/\\");
    while (it.next()) |comp|
        if (is_vcs_metadata_dir(comp)) return true;
    return false;
}

test "vcs metadata dirs" {
    try std.testing.expect(is_vcs_metadata_dir(".git"));
    try std.testing.expect(!is_vcs_metadata_dir(".gitignore"));
    try std.testing.expect(in_vcs_metadata_dir(".git/config"));
    try std.testing.expect(in_vcs_metadata_dir("sub/.git/refs/heads/main"));
    try std.testing.expect(in_vcs_metadata_dir(".jj/repo/store"));
    try std.testing.expect(!in_vcs_metadata_dir(".gitignore"));
    try std.testing.expect(!in_vcs_metadata_dir("src/git/main.zig"));
}

pub const builtin_patterns: []const u8 = @embedFile("builtin.gitignore");

test {
    _ = wildmatch;
    _ = Sources;
    _ = Pattern;
    _ = PatternList;
    _ = Matcher;
}
