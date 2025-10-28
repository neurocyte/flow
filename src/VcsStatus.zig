branch: ?[]const u8 = null,
ahead: ?[]const u8 = null,
behind: ?[]const u8 = null,
stash: ?[]const u8 = null,
changed: usize = 0,
untracked: usize = 0,

pub fn reset(self: *@This(), allocator: std.mem.Allocator) void {
    if (self.branch) |p| allocator.free(p);
    if (self.ahead) |p| allocator.free(p);
    if (self.behind) |p| allocator.free(p);
    if (self.stash) |p| allocator.free(p);
    self.branch = null;
    self.ahead = null;
    self.behind = null;
    self.stash = null;
    self.changed = 0;
    self.untracked = 0;
}

const std = @import("std");
