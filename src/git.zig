const std = @import("std");
const tp = @import("thespian");
const shell = @import("shell");
const bin_path = @import("bin_path");

pub const Error = error{ OutOfMemory, GitNotFound, GitCallFailed };

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
            while (it.next()) |value| if (value.len > 0)
                parent.send(.{ module_name, context, fn_name, value }) catch {};
        }
    }.result, exit_null_on_error(fn_name));
}

pub fn workspace_files(context_: usize) Error!void {
    const fn_name = @src().fn_name;
    try git_err(context_, .{ "ls-files", "--cached", "--others", "--exclude-standard" }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |value| if (value.len > 0)
                parent.send(.{ module_name, context, fn_name, value }) catch {};
        }
    }.result, struct {
        fn result(_: usize, _: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |line| std.log.err("{s}: {s}", .{ module_name, line });
        }
    }.result, exit_null_on_error(fn_name));
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
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const writer = buf.writer(allocator);
    switch (@typeInfo(@TypeOf(cmd))) {
        .@"struct" => |info| if (info.is_tuple) {
            try cbor.writeArrayHeader(writer, info.fields.len + 1);
            try cbor.writeValue(writer, git_binary);
            inline for (info.fields) |f|
                try cbor.writeValue(writer, @field(cmd, f.name));
            return shell.execute(allocator, .{ .buf = buf.items }, .{
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

fn exit_null_on_error(comptime tag: []const u8) shell.ExitHandler {
    return struct {
        fn exit(_: usize, parent: tp.pid_ref, _: []const u8, _: []const u8, exit_code: i64) void {
            if (exit_code > 0)
                parent.send(.{ module_name, tag, null }) catch {};
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
