const std = @import("std");
const tp = @import("thespian");
const shell = @import("shell");
const bin_path = @import("bin_path");

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
    return git_line_output(
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

pub fn new_or_modified_files(context_: usize) Error!void {
    const tag = @src().fn_name;
    try git_err(context_, .{
        "--no-optional-locks",
        "status",
        "--porcelain=v2",
        "--null",
    }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it_ = std.mem.splitScalar(u8, output, 0);

            while (it_.next()) |line| {
                var it = std.mem.splitScalar(u8, line, ' ');
                const rec_type = if (it.next()) |type_tag|
                    std.meta.stringToEnum(StatusRecordType, type_tag) orelse {
                        if (type_tag.len > 0)
                            std.log.debug("found {s}, it happens when a file is renamed and not modified. Check `git --no-optional-locks status --porcelain=v2`", .{type_tag});
                        continue;
                    }
                else
                    return;
                switch (rec_type) {
                    .@"1" => { // ordinary file: <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
                        const sub = it.next() orelse return;
                        const mH = it.next() orelse return;
                        var vcs_status: u8 = undefined;
                        if (sub[0] == 'A') {
                            // New staged file is shown as new
                            vcs_status = '+';
                        } else if (sub[0] == 'M' or sub[1] == 'M') {
                            if (mH[0] == 'S') {
                                // We do not handle submodules, yet
                                continue;
                            }
                            vcs_status = '~';
                        } else {
                            // We will not edit deleted files
                            continue;
                        }

                        for (0..5) |_| {
                            _ = it.next() orelse return;
                        }
                        var path: std.ArrayListUnmanaged(u8) = .empty;
                        defer path.deinit(allocator);
                        while (it.next()) |path_part| {
                            if (path.items.len > 0) path.append(allocator, ' ') catch return;
                            path.appendSlice(allocator, path_part) catch return;
                        }

                        parent.send(.{ module_name, context, tag, vcs_status, path.items }) catch {};
                    },
                    .@"2" => {
                        const sub = it.next() orelse return;
                        if (sub[0] != 'R') {
                            continue;
                        }
                        // An staged file is editable
                        // renamed: <XY> <sub> <mH> <mI> <mW> <hH> <hI> <rn> <path>
                        for (0..7) |_| {
                            _ = it.next() orelse return;
                        }
                        var path: std.ArrayListUnmanaged(u8) = .empty;
                        defer path.deinit(allocator);
                        while (it.next()) |path_part| {
                            if (path.items.len > 0) path.append(allocator, ' ') catch return;
                            path.appendSlice(allocator, path_part) catch return;
                        }
                        parent.send(.{ module_name, context, tag, '+', path.items }) catch {};
                    },
                    .@"?" => { // untracked file: <path>
                        var path: std.ArrayListUnmanaged(u8) = .empty;
                        defer path.deinit(allocator);
                        while (it.next()) |path_part| {
                            if (path.items.len > 0) path.append(allocator, ' ') catch return;
                            path.appendSlice(allocator, path_part) catch return;
                        }
                        parent.send(.{ module_name, context, tag, '+', path.items }) catch {};
                    },
                    else => {
                        // Omit showing other statuses
                    },
                }
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

pub fn cat_file(context_: usize, object: []const u8) Error!void {
    const tag = @src().fn_name;
    try git(context_, .{ "cat-file", "-p", object }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            parent.send(.{ module_name, context, tag, output }) catch {};
        }
    }.result, exit_null(tag));
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
            try cbor.writeArrayHeader(writer, info.fields.len + 1);
            try cbor.writeValue(writer, git_binary);
            inline for (info.fields) |f|
                try cbor.writeValue(writer, @field(cmd, f.name));
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

const module_name = @typeName(@This());
