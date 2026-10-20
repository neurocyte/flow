branch: ?[]const u8 = null,
ahead: ?[]const u8 = null,
behind: ?[]const u8 = null,
stash: ?[]const u8 = null,
changed: usize = 0,
untracked: usize = 0,
commit: ?[]const u8 = null,
upstream: ?[]const u8 = null,

pub fn reset(self: *@This(), allocator: std.mem.Allocator) void {
    if (self.branch) |p| allocator.free(p);
    if (self.ahead) |p| allocator.free(p);
    if (self.behind) |p| allocator.free(p);
    if (self.stash) |p| allocator.free(p);
    if (self.commit) |p| allocator.free(p);
    if (self.upstream) |p| allocator.free(p);
    self.* = .{};
}

pub fn eql(a: *const @This(), b: *const @This()) bool {
    return eql_opt(a.branch, b.branch) and
        eql_opt(a.ahead, b.ahead) and
        eql_opt(a.behind, b.behind) and
        eql_opt(a.stash, b.stash) and
        eql_opt(a.commit, b.commit) and
        eql_opt(a.upstream, b.upstream) and
        a.changed == b.changed and
        a.untracked == b.untracked;
}

fn eql_opt(a: ?[]const u8, b: ?[]const u8) bool {
    const a_ = a orelse return b == null;
    const b_ = b orelse return false;
    return std.mem.eql(u8, a_, b_);
}

const std = @import("std");
