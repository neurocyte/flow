const std = @import("std");
const tp = @import("thespian");
const shell = @import("shell");
const bin_path = @import("bin_path");

var git_path: ?struct {
    path: ?[:0]const u8 = null,
} = null;

fn get_git() ?[]const u8 {
    if (git_path) |p| return p.path;
    const path = bin_path.find_binary_in_path(std.heap.c_allocator, "git") catch null;
    git_path = .{ .path = path };
    return path;
}

pub fn get_current_branch(allocator: std.mem.Allocator) !void {
    const git_binary = get_git() orelse return error.GitBinaryNotFound;
    const git_current_branch_cmd = tp.message.fmt(.{ git_binary, "rev-parse", "--abbrev-ref", "HEAD" });
    const handlers = struct {
        fn out(_: usize, parent: tp.pid_ref, _: []const u8, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |branch| if (branch.len > 0)
                parent.send(.{ "git", "current_branch", branch }) catch {};
        }
    };
    try shell.execute(allocator, git_current_branch_cmd, .{
        .out = handlers.out,
        .err = shell.log_err_handler,
        .exit = shell.log_exit_err_handler,
    });
}
