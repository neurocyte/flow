const std = @import("std");
const tp = @import("thespian");
const shell = @import("shell");

const git_binary = "git";

pub fn get_current_branch(allocator: std.mem.Allocator) !void {
    const git_current_branch_cmd = tp.message.fmt(.{ git_binary, "rev-parse", "--abbrev-ref", "HEAD" });
    const handlers = struct {
        fn out(_: usize, parent: tp.pid_ref, _: []const u8, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |line| if (line.len > 0)
                parent.send(.{ "git", "current_branch", line }) catch {};
        }
    };
    try shell.execute(allocator, git_current_branch_cmd, .{
        .out = handlers.out,
        .err = shell.log_err_handler,
        .exit = shell.log_exit_err_handler,
    });
}
