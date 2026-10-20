const std = @import("std");
const builtin = @import("builtin");
const tp = @import("thespian");
const shell = @import("shell");
const bin_path = @import("bin_path");
const root = @import("soft_root").root;

pub const Error = error{ OutOfMemory, GitNotFound, GitCallFailed, WriteFailed };

const log_execute = false;

pub fn workspace_path(context_: usize) Error!void {
    const fn_name = @src().fn_name;
    try git(context_, .{ "rev-parse", "--show-toplevel" }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |value| if (value.len > 0)
                parent.send(.{ module_name, context, fn_name, value }) catch {};
        }
    }.result, exit_null_on_error(fn_name));
}

pub fn current_branch(context_: usize) Error!void {
    const fn_name = @src().fn_name;
    try git(context_, .{ "rev-parse", "--abbrev-ref", "HEAD" }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |value| if (value.len > 0) {
                parent.send(.{ module_name, context, fn_name, value }) catch {};
                return;
            };
        }
    }.result, exit_null_on_error(fn_name));
}

pub fn workspace_files(context: usize) Error!void {
    return if (is_file(".gitmodules"))
        git_chunk_output(
            context,
            @src().fn_name,
            .{ "ls-files", "--cached", "--exclude-standard", "--recurse-submodules" },
        )
    else
        git_chunk_output(
            context,
            @src().fn_name,
            .{ "ls-files", "--cached", "--others", "--exclude-standard" },
        );
}

pub fn workspace_ignored_files(context: usize) Error!void {
    return git_line_output(
        context,
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

pub fn status(context_: usize) Error!void {
    const tag = @src().fn_name;
    try git_err(context_, .{
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

pub fn rev_parse(context_: usize, rev: []const u8, file_path: []const u8) Error!void {
    const tag = @src().fn_name;
    var arg: std.Io.Writer.Allocating = .init(allocator);
    defer arg.deinit();
    if (file_path.len == 0)
        try arg.writer.print("{s}", .{rev})
    else
        try arg.writer.print("{s}:{s}", .{ rev, file_path });
    try git(context_, .{ "rev-parse", arg.written() }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |value| if (value.len > 0)
                parent.send(.{ module_name, context, tag, value }) catch {};
        }
    }.result, exit_null(tag));
}

pub fn git_dirs(context_: usize) Error!void {
    const tag = @src().fn_name;
    try git(context_, .{ "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir" }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |value| if (value.len > 0)
                parent.send(.{ module_name, context, tag, value }) catch {};
        }
    }.result, exit_null(tag));
}

pub fn cat_file(context_: usize, object: []const u8) Error!void {
    const tag = @src().fn_name;
    try git(context_, .{ "cat-file", "-p", object }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            parent.send(.{ module_name, context, tag, output }) catch {};
        }
    }.result, exit_null(tag));
}

pub fn ls_tree(context_: usize, rev: []const u8, file_path: []const u8) Error!void {
    const tag = @src().fn_name;
    try git(context_, .{ "ls-tree", "--name-only", rev, "--", file_path }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |value| if (value.len > 0)
                parent.send(.{ module_name, context, tag, value }) catch {};
        }
    }.result, exit_null(tag));
}

pub fn file_status(context_: usize, file_path: []const u8) Error!void {
    const tag = @src().fn_name;
    try git(context_, .{ "status", "--porcelain", "--ignored", "--untracked-files=normal", "--", file_path }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |value| if (value.len > 0)
                parent.send(.{ module_name, context, tag, value }) catch {};
        }
    }.result, exit_null(tag));
}

pub fn first_change(context_: usize, staged: bool, file_path: []const u8) Error!void {
    const tag = @src().fn_name;
    var pathspec: std.Io.Writer.Allocating = .init(allocator);
    defer pathspec.deinit();
    try pathspec.writer.print(":(top,literal){s}", .{file_path});
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, pathspec.written(), '\\', '/');
    const handler = struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |line| if (parse_hunk_line(line)) |first_line|
                parent.send(.{ module_name, context, tag, first_line }) catch {};
        }
    }.result;
    if (staged)
        try git(context_, .{ "--no-optional-locks", "diff", "--no-color", "--no-ext-diff", "-U0", "--cached", "--", pathspec.written() }, handler, exit_null(tag))
    else
        try git(context_, .{ "--no-optional-locks", "diff", "--no-color", "--no-ext-diff", "-U0", "--", pathspec.written() }, handler, exit_null(tag));
}

pub const IndexUpdate = enum { stage, unstage, unstage_initial };

pub fn update_index(context_: usize, update: IndexUpdate, file_paths: []const []const u8) Error!void {
    const tag = @src().fn_name;
    const cmd: []const []const u8 = switch (update) {
        .stage => &.{ "add", "--" },
        .unstage => &.{ "restore", "--staged", "--" },
        .unstage_initial => &.{ "rm", "--cached", "-q", "--" },
    };
    var args: std.ArrayList([]const u8) = .empty;
    defer {
        for (args.items[cmd.len..]) |arg| allocator.free(arg);
        args.deinit(allocator);
    }
    try args.appendSlice(allocator, cmd);
    for (file_paths) |file_path| {
        const pathspec = try std.fmt.allocPrint(allocator, ":(top,literal){s}", .{file_path});
        if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, pathspec, '\\', '/');
        args.append(allocator, pathspec) catch |e| {
            allocator.free(pathspec);
            return e;
        };
    }
    try git_err(context_, @as([]const []const u8, args.items), noop, log_err, exit_result(tag));
}

pub const DiffMode = enum { unstaged, staged, untracked };

pub fn diff(context_: usize, mode: DiffMode, file_path: []const u8) Error!void {
    const tag = @src().fn_name;
    var pathspec: std.Io.Writer.Allocating = .init(allocator);
    defer pathspec.deinit();
    try pathspec.writer.print(":(top,literal){s}", .{file_path});
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, pathspec.written(), '\\', '/');
    const handler = struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            parent.send(.{ module_name, context, tag, output }) catch {};
        }
    }.result;
    switch (mode) {
        .unstaged => try git_err(context_, .{ "--no-optional-locks", "diff", "--no-color", "--no-ext-diff", "--", pathspec.written() }, handler, log_err, exit_null(tag)),
        .staged => try git_err(context_, .{ "--no-optional-locks", "diff", "--no-color", "--no-ext-diff", "--cached", "--", pathspec.written() }, handler, log_err, exit_null(tag)),
        .untracked => try git_err(context_, .{ "--no-optional-locks", "diff", "--no-color", "--no-ext-diff", "--no-index", "--", "/dev/null", file_path }, handler, log_err, exit_null(tag)),
    }
}

/// Returns the first new line of a hunk header: @@ -a[,b] +c[,d] @@
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

pub fn check_ignore(context_: usize, file_path: []const u8) Error!void {
    const tag = @src().fn_name;
    try git(context_, .{ "check-ignore", "-q", file_path }, struct {
        fn result(_: usize, _: tp.pid_ref, _: []const u8) void {}
    }.result, exit_result(tag));
}

fn git_line_output(context_: usize, comptime tag: []const u8, cmd: anytype) Error!void {
    try git_err(context_, cmd, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |value| if (value.len > 0)
                parent.send(.{ module_name, context, tag, value }) catch {};
        }
    }.result, log_err, exit_null(tag));
}

fn git_chunk_output(context_: usize, comptime tag: []const u8, cmd: anytype) Error!void {
    try git_err(context_, cmd, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            parent.send(.{ module_name, context, tag, output }) catch {};
        }
    }.result, log_err, exit_null(tag));
}

fn git(
    context: usize,
    cmd: anytype,
    out: OutputHandler,
    exit: ExitHandler,
) Error!void {
    return git_err(context, cmd, out, noop, exit);
}

fn git_err(
    context: usize,
    cmd: anytype,
    out: OutputHandler,
    err: OutputHandler,
    exit: ExitHandler,
) Error!void {
    const cbor = @import("cbor");
    const git_binary = get_git() orelse return error.GitNotFound;

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    const writer = &buf.writer;
    switch (@typeInfo(@TypeOf(cmd))) {
        .@"struct" => |info| if (info.is_tuple) {
            try cbor.writeArrayHeader(writer, info.field_names.len + 1);
            try cbor.writeValue(writer, git_binary);
            inline for (info.field_names) |name|
                try cbor.writeValue(writer, @field(cmd, name));
            return shell.execute(allocator, .{ .buf = buf.written() }, .{
                .context = context,
                .out = to_shell_output_handler(out),
                .err = to_shell_output_handler(err),
                .exit = exit,
                .log_execute = log_execute,
            }) catch error.GitCallFailed;
        },
        .pointer => {
            const args: []const []const u8 = cmd;
            try cbor.writeArrayHeader(writer, args.len + 1);
            try cbor.writeValue(writer, git_binary);
            for (args) |arg| try cbor.writeValue(writer, arg);
            return shell.execute(allocator, .{ .buf = buf.written() }, .{
                .context = context,
                .out = to_shell_output_handler(out),
                .err = to_shell_output_handler(err),
                .exit = exit,
                .log_execute = log_execute,
            }) catch error.GitCallFailed;
        },
        else => {},
    }
    @compileError("git command should be a tuple: " ++ @typeName(@TypeOf(cmd)));
}

fn exit_null(comptime tag: []const u8) shell.ExitHandler {
    return struct {
        fn exit(context: usize, parent: tp.pid_ref, _: []const u8, _: []const u8, _: i64) void {
            parent.send(.{ module_name, context, tag, null }) catch {};
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

fn log_err(_: usize, _: tp.pid_ref, output: []const u8) void {
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| if (line.len > 0)
        std.log.err("{s}: {s}", .{ module_name, line });
}

fn noop(_: usize, _: tp.pid_ref, _: []const u8) void {}

var git_path: ?struct {
    path: ?[:0]const u8 = null,
} = null;

const allocator = std.heap.c_allocator;

fn get_git() ?[]const u8 {
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

    var arg: std.Io.Writer.Allocating = .init(allocator);
    var arg2: std.Io.Writer.Allocating = .init(allocator);
    defer arg.deinit();
    defer arg2.deinit();

    try arg.writer.print("{s}", .{basename});
    try arg2.writer.print("{s}", .{dir_path});

    try git(context_, .{
        "-C",
        arg2.written(),
        "blame",
        "--incremental",
        "HEAD",
        "--",
        arg.written(),
    }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            parent.send(.{ module_name, context, tag, output }) catch {};
        }
    }.result, exit_null(tag));
}

fn is_file(rel_path: []const u8) bool {
    const io = root.get_io();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.cwd().realPathFile(io, rel_path, &path_buf) catch return false;
    const abs_path = path_buf[0..len];
    const file = std.Io.Dir.openFileAbsolute(io, abs_path, .{}) catch return false;
    defer file.close(io);
    return true;
}

const module_name = @typeName(@This());
