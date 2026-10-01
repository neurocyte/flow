const std = @import("std");
const builtin = @import("builtin");
const tp = @import("thespian");
const shell = @import("shell");
const bin_path = @import("bin_path");
const root = @import("soft_root").root;

pub const Error = error{ OutOfMemory, GitNotFound, GitCallFailed, WriteFailed };

const log_execute = false;

pub fn workspace_path(context_: usize, dir: []const u8) Error!void {
    const fn_name = @src().fn_name;
    try git(context_, dir, .{ "rev-parse", "--show-toplevel" }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |value| if (value.len > 0)
                parent.send(.{ module_name, context, fn_name, value }) catch {};
        }
    }.result, exit_null_on_error(fn_name));
}

pub fn workspace_files(context: usize, dir: []const u8) Error!void {
    return if (workspace_files_need_full_stat(dir))
        git_chunk_output(
            context,
            dir,
            @src().fn_name,
            .{ "ls-files", "--cached", "--exclude-standard", "--recurse-submodules" },
        )
    else
        git_chunk_output(
            context,
            dir,
            @src().fn_name,
            .{ "ls-files", "--cached", "--others", "--exclude-standard" },
        );
}

/// Recursive submodule listings include missing files inside submodules,
/// which the top-level deleted-files listing cannot identify.
pub fn workspace_files_need_full_stat(dir: []const u8) bool {
    return is_file(dir, ".gitmodules");
}

/// Tracked files that are missing from the workspace.
pub fn workspace_deleted_files(context: usize, dir: []const u8) Error!void {
    return git_chunk_output(context, dir, @src().fn_name, .{ "ls-files", "--deleted" });
}

pub fn workspace_ignored_files(context: usize, dir: []const u8) Error!void {
    return git_line_output(
        context,
        dir,
        @src().fn_name,
        .{ "ls-files", "--cached", "--others", "--exclude-standard", "--ignored" },
    );
}

const StatusRecordType = enum {
    @"#", // header
    @"1", // ordinary file
    @"2", // rename or copy
    u, // unmerged file
    @"?", // untracked file
    @"!", // ignored file
};

pub fn status(context_: usize, dir: []const u8) Error!void {
    const tag = @src().fn_name;
    try git_err(context_, dir, .{
        "--no-optional-locks",
        "status",
        "--porcelain=v2",
        "--branch",
        "--show-stash",
        // "--untracked-files=no",
        "--null",
    }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it_ = std.mem.splitScalar(u8, output, 0);
            while (it_.next()) |line| {
                var it = std.mem.splitScalar(u8, line, ' ');
                const rec_type = if (it.next()) |type_tag|
                    std.meta.stringToEnum(StatusRecordType, type_tag) orelse return
                else
                    return;
                switch (rec_type) {
                    .@"#" => { // header
                        const name = it.next() orelse return;
                        const value1 = it.next() orelse return;
                        if (it.next()) |value2|
                            parent.send(.{ module_name, context, tag, "#", name, value1, value2 }) catch {}
                        else
                            parent.send(.{ module_name, context, tag, "#", name, value1 }) catch {};
                    },
                    .@"1" => { // ordinary file: <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
                        const XY = it.next() orelse return;
                        const sub = it.next() orelse return;
                        const mH = it.next() orelse return;
                        const mI = it.next() orelse return;
                        const mW = it.next() orelse return;
                        const hH = it.next() orelse return;
                        const hI = it.next() orelse return;

                        var path: std.ArrayListUnmanaged(u8) = .empty;
                        defer path.deinit(allocator);
                        while (it.next()) |path_part| {
                            if (path.items.len > 0) path.append(allocator, ' ') catch return;
                            path.appendSlice(allocator, path_part) catch return;
                        }

                        parent.send(.{ module_name, context, tag, "1", XY, sub, mH, mI, mW, hH, hI, path.items }) catch {};
                    },
                    .@"2" => { // rename or copy: <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path><sep><origPath>
                        const XY = it.next() orelse return;
                        const sub = it.next() orelse return;
                        const mH = it.next() orelse return;
                        const mI = it.next() orelse return;
                        const mW = it.next() orelse return;
                        const hH = it.next() orelse return;
                        const hI = it.next() orelse return;
                        const Xscore = it.next() orelse return;

                        var path: std.ArrayListUnmanaged(u8) = .empty;
                        defer path.deinit(allocator);
                        while (it.next()) |path_part| {
                            if (path.items.len > 0) path.append(allocator, ' ') catch return;
                            path.appendSlice(allocator, path_part) catch return;
                        }

                        const origPath = it_.next() orelse return; // NOTE: this is the next zero terminated part

                        parent.send(.{ module_name, context, tag, "2", XY, sub, mH, mI, mW, hH, hI, Xscore, path.items, origPath }) catch {};
                    },
                    .u => { // unmerged file: <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
                        const XY = it.next() orelse return;
                        const sub = it.next() orelse return;
                        const m1 = it.next() orelse return;
                        const m2 = it.next() orelse return;
                        const m3 = it.next() orelse return;
                        const mW = it.next() orelse return;
                        const h1 = it.next() orelse return;
                        const h2 = it.next() orelse return;
                        const h3 = it.next() orelse return;

                        var path: std.ArrayListUnmanaged(u8) = .empty;
                        defer path.deinit(allocator);
                        while (it.next()) |path_part| {
                            if (path.items.len > 0) path.append(allocator, ' ') catch return;
                            path.appendSlice(allocator, path_part) catch return;
                        }

                        parent.send(.{ module_name, context, tag, "u", XY, sub, m1, m2, m3, mW, h1, h2, h3, path.items }) catch {};
                    },
                    .@"?" => { // untracked file: <path>
                        var path: std.ArrayListUnmanaged(u8) = .empty;
                        defer path.deinit(allocator);
                        while (it.next()) |path_part| {
                            if (path.items.len > 0) path.append(allocator, ' ') catch return;
                            path.appendSlice(allocator, path_part) catch return;
                        }
                        parent.send(.{ module_name, context, tag, "?", path.items }) catch {};
                    },
                    .@"!" => { // ignored file: <path>
                        var path: std.ArrayListUnmanaged(u8) = .empty;
                        defer path.deinit(allocator);
                        while (it.next()) |path_part| {
                            if (path.items.len > 0) path.append(allocator, ' ') catch return;
                            path.appendSlice(allocator, path_part) catch return;
                        }
                        parent.send(.{ module_name, context, tag, "!", path.items }) catch {};
                    },
                }
                // parent.send(.{ module_name, context, tag, value }) catch {};
            }
        }
    }.result, log_err, exit_null(tag));
}

pub fn rev_parse(context_: usize, dir: []const u8, rev: []const u8, file_path: []const u8) Error!void {
    const tag = @src().fn_name;
    var arg: std.Io.Writer.Allocating = .init(allocator);
    defer arg.deinit();
    if (file_path.len == 0)
        try arg.writer.print("{s}", .{rev})
    else {
        // <rev>:<path> takes a path relative to the repository root
        try arg.writer.print("{s}:{s}", .{ rev, relative_to(dir, file_path) });
        if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, arg.written(), '\\', '/');
    }
    try git(context_, dir, .{ "rev-parse", arg.written() }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |value| if (value.len > 0)
                parent.send(.{ module_name, context, tag, value }) catch {};
        }
    }.result, exit_null(tag));
}

/// sends the worktree root, the git dir, the common dir and, in a submodule,
/// the superproject root, one per message, then the exit code
pub fn discover(context_: usize, dir: []const u8) Error!void {
    const tag = @src().fn_name;
    try git(context_, dir, .{
        "rev-parse",
        "--path-format=absolute",
        "--show-toplevel",
        "--git-dir",
        "--git-common-dir",
        "--show-superproject-working-tree",
    }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |value| if (value.len > 0)
                parent.send(.{ module_name, context, tag, value }) catch {};
        }
    }.result, exit_result(tag));
}

pub fn cat_file(context_: usize, dir: []const u8, object: []const u8) Error!void {
    const tag = @src().fn_name;
    try git(context_, dir, .{ "cat-file", "-p", object }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            parent.send(.{ module_name, context, tag, output }) catch {};
        }
    }.result, exit_null(tag));
}

pub fn ls_tree(context_: usize, dir: []const u8, rev: []const u8, file_path: []const u8) Error!void {
    const tag = @src().fn_name;
    try git(context_, dir, .{ "ls-tree", "--name-only", rev, "--", file_path }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |value| if (value.len > 0)
                parent.send(.{ module_name, context, tag, value }) catch {};
        }
    }.result, exit_null(tag));
}

pub fn file_status(context_: usize, dir: []const u8, file_path: []const u8) Error!void {
    const tag = @src().fn_name;
    try git(context_, dir, .{ "status", "--porcelain", "--ignored", "--untracked-files=normal", "--", file_path }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |value| if (value.len > 0)
                parent.send(.{ module_name, context, tag, value }) catch {};
        }
    }.result, exit_null(tag));
}

pub fn first_change(context_: usize, dir: []const u8, staged: bool, file_path: []const u8) Error!void {
    const tag = @src().fn_name;
    const pathspec = try literal_pathspec(file_path);
    defer allocator.free(pathspec);
    const handler = struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |line| if (parse_hunk_line(line)) |first_line|
                parent.send(.{ module_name, context, tag, first_line }) catch {};
        }
    }.result;
    if (staged)
        try git(context_, dir, .{ "--no-optional-locks", "diff", "--no-color", "--no-ext-diff", "-U0", "--cached", "--", pathspec }, handler, exit_null(tag))
    else
        try git(context_, dir, .{ "--no-optional-locks", "diff", "--no-color", "--no-ext-diff", "-U0", "--", pathspec }, handler, exit_null(tag));
}

pub const IndexUpdate = enum { stage, unstage, unstage_initial, revert };

pub fn update_index(context_: usize, dir: []const u8, update: IndexUpdate, file_paths: []const []const u8) Error!void {
    const tag = @src().fn_name;
    const cmd: []const []const u8 = switch (update) {
        .stage => &.{ "add", "--" },
        .unstage => &.{ "restore", "--staged", "--" },
        .unstage_initial => &.{ "rm", "--cached", "-q", "--" },
        .revert => &.{ "restore", "--" },
    };
    var args: std.ArrayList([]const u8) = .empty;
    defer {
        for (args.items[cmd.len..]) |arg| allocator.free(arg);
        args.deinit(allocator);
    }
    try args.appendSlice(allocator, cmd);
    for (file_paths) |file_path| {
        const pathspec = try literal_pathspec(file_path);
        args.append(allocator, pathspec) catch |e| {
            allocator.free(pathspec);
            return e;
        };
    }
    try git_err(context_, dir, @as([]const []const u8, args.items), noop, log_err, exit_result(tag));
}

pub const DiffMode = enum { unstaged, staged, untracked };

pub fn diff(context_: usize, dir: []const u8, mode: DiffMode, file_path: []const u8, orig_path: []const u8, context_lines: usize) Error!void {
    const tag = @src().fn_name;
    const pathspec = try literal_pathspec(file_path);
    defer allocator.free(pathspec);
    // a rename needs both paths, or git shows the new path as a new file
    const orig_pathspec = try literal_pathspec(orig_path);
    defer allocator.free(orig_pathspec);
    var unified_buf: [32]u8 = undefined;
    const unified = std.fmt.bufPrint(&unified_buf, "--unified={d}", .{context_lines}) catch unreachable;
    const handler = struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            parent.send(.{ module_name, context, tag, output }) catch {};
        }
    }.result;
    switch (mode) {
        .unstaged => try git_err(context_, dir, .{ "--no-optional-locks", "diff", "--no-color", "--no-ext-diff", unified, "--", pathspec }, handler, log_err, exit_null(tag)),
        .staged => if (orig_path.len > 0)
            try git_err(context_, dir, .{ "--no-optional-locks", "diff", "--no-color", "--no-ext-diff", unified, "--cached", "--find-renames", "--", pathspec, orig_pathspec }, handler, log_err, exit_null(tag))
        else
            try git_err(context_, dir, .{ "--no-optional-locks", "diff", "--no-color", "--no-ext-diff", unified, "--cached", "--", pathspec }, handler, log_err, exit_null(tag)),
        .untracked => try git_err(context_, dir, .{ "--no-optional-locks", "diff", "--no-color", "--no-ext-diff", unified, "--no-index", "--", "/dev/null", relative_to(dir, file_path) }, handler, log_err, exit_null(tag)),
    }
}

/// Returns the first new line of a hunk header: @@ -a[,b] +c[,d] @@
pub fn apply_patch(context_: usize, dir: []const u8, update: IndexUpdate, patch: []const u8) Error!void {
    const tag = @src().fn_name;
    const args: []const []const u8 = switch (update) {
        .stage => &.{ "apply", "--cached", "--unidiff-zero", "-" },
        .unstage, .unstage_initial => &.{ "apply", "--cached", "--unidiff-zero", "--reverse", "-" },
        .revert => &.{ "apply", "--unidiff-zero", "--reverse", "-" },
    };
    try git_input(context_, dir, args, patch, noop, log_err, exit_result(tag));
}

fn parse_hunk_line(line: []const u8) ?usize {
    if (!std.mem.startsWith(u8, line, "@@ -")) return null;
    var it = std.mem.splitScalar(u8, line, ' ');
    _ = it.next();
    _ = it.next();
    const new = it.next() orelse return null;
    if (new.len < 2 or new[0] != '+') return null;
    var range = std.mem.splitScalar(u8, new[1..], ',');
    const start = std.fmt.parseInt(usize, range.next() orelse return null, 10) catch return null;
    const count = std.fmt.parseInt(usize, range.next() orelse "1", 10) catch return null;
    return if (count == 0) start + 1 else @max(start, 1);
}

pub fn check_ignore(context_: usize, dir: []const u8, file_path: []const u8) Error!void {
    const tag = @src().fn_name;
    try git(context_, dir, .{ "check-ignore", "-q", file_path }, struct {
        fn result(_: usize, _: tp.pid_ref, _: []const u8) void {}
    }.result, exit_result(tag));
}

fn git_line_output(context_: usize, dir: []const u8, comptime tag: []const u8, cmd: anytype) Error!void {
    try git_err(context_, dir, cmd, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |value| if (value.len > 0)
                parent.send(.{ module_name, context, tag, value }) catch {};
        }
    }.result, log_err, exit_null(tag));
}

fn git_chunk_output(context_: usize, dir: []const u8, comptime tag: []const u8, cmd: anytype) Error!void {
    try git_err(context_, dir, cmd, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            parent.send(.{ module_name, context, tag, output }) catch {};
        }
    }.result, log_err, exit_status(tag));
}

fn git(
    context: usize,
    dir: []const u8,
    cmd: anytype,
    out: OutputHandler,
    exit: ExitHandler,
) Error!void {
    return git_err(context, dir, cmd, out, noop, exit);
}

fn git_err(
    context: usize,
    dir: []const u8,
    cmd: anytype,
    out: OutputHandler,
    err: OutputHandler,
    exit: ExitHandler,
) Error!void {
    return git_input(context, dir, cmd, null, out, err, exit);
}

/// runs git in dir, so no command depends on the process working directory
fn git_input(
    context: usize,
    dir: []const u8,
    cmd: anytype,
    input: ?[]const u8,
    out: OutputHandler,
    err: OutputHandler,
    exit: ExitHandler,
) Error!void {
    const cbor = @import("cbor");
    const git_binary = get_git() orelse return error.GitNotFound;

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    const writer = &buf.writer;
    const handlers: shell.Handlers = .{
        .context = context,
        .out = to_shell_output_handler(out),
        .err = to_shell_output_handler(err),
        .exit = exit,
        .log_execute = log_execute,
    };
    switch (@typeInfo(@TypeOf(cmd))) {
        .@"struct" => |info| if (info.is_tuple) {
            try cbor.writeArrayHeader(writer, info.field_names.len + 3);
            try cbor.writeValue(writer, git_binary);
            try cbor.writeValue(writer, "-C");
            try cbor.writeValue(writer, dir);
            inline for (info.field_names) |name|
                try cbor.writeValue(writer, @field(cmd, name));
            return execute(.{ .buf = buf.written() }, input, handlers);
        },
        .pointer => {
            const args: []const []const u8 = cmd;
            try cbor.writeArrayHeader(writer, args.len + 3);
            try cbor.writeValue(writer, git_binary);
            try cbor.writeValue(writer, "-C");
            try cbor.writeValue(writer, dir);
            for (args) |arg| try cbor.writeValue(writer, arg);
            return execute(.{ .buf = buf.written() }, input, handlers);
        },
        else => {},
    }
    @compileError("git command should be a tuple: " ++ @typeName(@TypeOf(cmd)));
}

fn execute(argv: tp.message, input: ?[]const u8, handlers: shell.Handlers) Error!void {
    const bytes = input orelse
        return shell.execute(allocator, argv, handlers) catch error.GitCallFailed;
    var sp = shell.execute_pipe(allocator, argv, handlers) catch return error.GitCallFailed;
    defer sp.deinit();
    sp.input(bytes) catch return error.GitCallFailed;
}

fn exit_null(comptime tag: []const u8) shell.ExitHandler {
    return struct {
        fn exit(context: usize, parent: tp.pid_ref, _: []const u8, _: []const u8, _: i64) void {
            parent.send(.{ module_name, context, tag, null }) catch {};
        }
    }.exit;
}

fn exit_status(comptime tag: []const u8) shell.ExitHandler {
    return struct {
        fn exit(context: usize, parent: tp.pid_ref, _: []const u8, _: []const u8, exit_code: i64) void {
            parent.send(.{ module_name, context, tag, null, exit_code }) catch {};
        }
    }.exit;
}

fn exit_null_on_error(comptime tag: []const u8) shell.ExitHandler {
    return struct {
        fn exit(context: usize, parent: tp.pid_ref, _: []const u8, _: []const u8, exit_code: i64) void {
            if (exit_code > 0)
                parent.send(.{ module_name, context, tag, null }) catch {};
        }
    }.exit;
}

fn exit_result(comptime tag: []const u8) shell.ExitHandler {
    return struct {
        fn exit(context: usize, parent: tp.pid_ref, _: []const u8, _: []const u8, exit_code: i64) void {
            parent.send(.{ module_name, context, tag, exit_code }) catch {};
        }
    }.exit;
}

const OutputHandler = fn (context: usize, parent: tp.pid_ref, output: []const u8) void;
const ExitHandler = shell.ExitHandler;

fn to_shell_output_handler(handler: anytype) shell.OutputHandler {
    return struct {
        fn out(context: usize, parent: tp.pid_ref, _: []const u8, output: []const u8) void {
            handler(context, parent, output);
        }
    }.out;
}

fn literal_pathspec(file_path: []const u8) error{OutOfMemory}![]u8 {
    const pathspec = try std.fmt.allocPrint(allocator, ":(literal){s}", .{file_path});
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, pathspec, '\\', '/');
    return pathspec;
}

fn relative_to(dir: []const u8, file_path: []const u8) []const u8 {
    if (file_path.len <= dir.len or !std.mem.startsWith(u8, file_path, dir)) return file_path;
    if (!std.fs.path.isSep(file_path[dir.len])) return file_path;
    return file_path[dir.len + 1 ..];
}

fn log_err(_: usize, _: tp.pid_ref, output: []const u8) void {
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| if (line.len > 0)
        std.log.err("{s}: {s}", .{ module_name, line });
}

fn noop(_: usize, _: tp.pid_ref, _: []const u8) void {}

/// The git binary, found on first use. File finders run git on their own
/// threads, so the lookup is serialized.
var git_path: ?struct {
    path: ?[:0]const u8 = null,
} = null;
var git_path_mutex: std.Io.Mutex = .init;

const allocator = std.heap.c_allocator;

fn get_git() ?[]const u8 {
    const io = root.get_io();
    git_path_mutex.lockUncancelable(io);
    defer git_path_mutex.unlock(io);
    if (git_path) |p| return p.path;
    const path = bin_path.find_binary_in_path(allocator, module_name) catch null;
    git_path = .{ .path = path };
    return path;
}

pub fn is_available() bool {
    return get_git() != null;
}

pub fn blame(context_: usize, file_path: []const u8) !void {
    const tag = @src().fn_name;
    const dir_path = std.fs.path.dirname(file_path) orelse ".";
    const basename = std.fs.path.basename(file_path);
    try git(context_, dir_path, .{
        "blame",
        "--incremental",
        "HEAD",
        "--",
        basename,
    }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            parent.send(.{ module_name, context, tag, output }) catch {};
        }
    }.result, exit_null(tag));
}

fn is_file(dir: []const u8, rel_path: []const u8) bool {
    const io = root.get_io();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}{c}{s}", .{ dir, std.fs.path.sep, rel_path }) catch return false;
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    defer file.close(io);
    return true;
}

/// The first field of the messages that git commands send to their caller.
pub const module_name = @typeName(@This());
