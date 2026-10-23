const std = @import("std");
const tp = @import("thespian");
const root = @import("soft_root").root;
const project_manager = @import("project_manager");

const tui = @import("tui.zig");

/// the name of a diff buffer: *git diff <path>* or *git diff --cached <path>*
/// the path may start with ~
pub const DiffBuffer = struct {
    path: []const u8,
    staged: bool,

    pub fn parse(buffer_name: []const u8) ?DiffBuffer {
        if (buffer_name.len < 2 or buffer_name[0] != '*' or buffer_name[buffer_name.len - 1] != '*') return null;
        const inner = buffer_name[1 .. buffer_name.len - 1];
        const staged = "git diff --cached ";
        const unstaged = "git diff ";
        if (std.mem.startsWith(u8, inner, staged)) return .{ .path = inner[staged.len..], .staged = true };
        if (std.mem.startsWith(u8, inner, unstaged)) return .{ .path = inner[unstaged.len..], .staged = false };
        return null;
    }
};

/// the path that selects the current repository: the file of the active
/// editor or diff buffer, or "" in project context
pub fn current_path(allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    const editor = tui.get_active_editor() orelse return allocator.dupe(u8, "");
    const file_path = editor.file_path orelse return allocator.dupe(u8, "");
    if (DiffBuffer.parse(file_path)) |diff| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        return allocator.dupe(u8, project_manager.expand_home(allocator, &buf, diff.path));
    }
    if (editor.buffer) |buffer| if (buffer.is_ephemeral()) return allocator.dupe(u8, "");
    return allocator.dupe(u8, file_path);
}

pub const TerminalAction = enum { commit, commit_all, amend, fetch, push };

/// runs the configured command for the action in a terminal in the repository root
pub fn run_in_terminal(action: TerminalAction, repo_root: []const u8) tp.result {
    const config = tui.config();
    const cmd = switch (action) {
        .commit => config.vcs_commit_command,
        .commit_all => config.vcs_commit_all_command,
        .amend => config.vcs_amend_command,
        .fetch => config.vcs_fetch_command,
        .push => config.vcs_push_command,
    };
    try tp.self_pid().send(.{ "cmd", "open_terminal", .{ cmd, config.terminal_on_exit, repo_root } });
}

/// the repository root relative to the project, or with ~ for the home directory, whichever is shorter
/// null if the repository root is the project
pub fn display_root(allocator: std.mem.Allocator, repo_root: []const u8) error{OutOfMemory}!?[]const u8 {
    const project = tp.env.get().str("project");
    if (std.mem.eql(u8, project, repo_root)) return null;
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = project_manager.abbreviate_home(&home_buf, repo_root);
    const relative = std.fs.path.relative(allocator, project, root.get_init().environ_map, project, repo_root) catch
        return try allocator.dupe(u8, home);
    if (relative.len <= home.len) return relative;
    allocator.free(relative);
    return try allocator.dupe(u8, home);
}
