const std = @import("std");
const tui = @import("tui");
const thespian = @import("thespian");
const clap = @import("clap");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("locale.h");
});

const build_options = @import("build_options");
const log = @import("log");

pub const application_name = "flow";
pub const application_logo = "󱞏 ";

pub fn main() anyerror!void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help               Display this help and exit.
        \\-f, --frame-rate <usize> Set target frame rate. (default: 60)
        \\--debug-wait             Wait for key press before starting UI.
        \\--debug-dump-on-error    Dump stack traces on errors.
        \\--no-sleep               Do not sleep the main loop when idle.
        \\--no-alternate           Do not use the alternate terminal screen.
        \\--no-trace               Do not enable internal tracing.
        \\--restore-session        Restore restart session.
        \\--show-input             Open the input view on start.
        \\-l, --language <str>     Force the language of the file to be opened.
        \\<str>...                 File to open.
        \\                         Add +<LINE> to the command line or append
        \\                         :LINE or :LINE:COL to the file name to jump
        \\                         to a location in the file.
        \\
    );

    if (builtin.os.tag == .linux) {
        // drain stdin so we don't pickup junk from previous application/shell
        _ = std.os.linux.syscall3(.ioctl, @as(usize, @bitCast(@as(isize, std.os.STDIN_FILENO))), std.os.linux.T.CFLSH, 0);
    }

    const a = std.heap.c_allocator;

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = a,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{}) catch {};
        exit(1);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0)
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});

    if (std.os.getenv("JITDEBUG")) |_| thespian.install_debugger();

    if (res.args.@"debug-wait" != 0) {
        std.debug.print("press return to start", .{});
        var buf: [10]u8 = undefined;
        _ = std.c.read(0, &buf, @sizeOf(@TypeOf(buf)));
    }

    if (c.setlocale(c.LC_ALL, "") == null) {
        return error.SetLocaleFailed;
    }

    var ctx = try thespian.context.init(a);
    defer ctx.deinit();

    const env = thespian.env.init();
    defer env.deinit();
    if (build_options.enable_tracy) {
        if (res.args.@"no-trace" == 0) {
            env.enable_all_channels();
            env.on_trace(trace);
        }
    }

    const log_proc = try log.spawn(&ctx, a, &env);
    defer log_proc.deinit();

    env.set("restore-session", (res.args.@"restore-session" != 0));
    env.set("no-alternate", (res.args.@"no-alternate" != 0));
    env.set("show-input", (res.args.@"show-input" != 0));
    env.set("no-sleep", (res.args.@"no-sleep" != 0));
    env.set("dump-stack-trace", (res.args.@"debug-dump-on-error" != 0));
    if (res.args.@"frame-rate") |s| env.num_set("frame-rate", @intCast(s));
    env.proc_set("log", log_proc.ref());
    if (res.args.language) |s| env.str_set("language", s);

    var eh = thespian.make_exit_handler({}, print_exit_status);
    const tui_proc = try tui.spawn(a, &ctx, &eh, &env);
    defer tui_proc.deinit();

    const Dest = struct {
        file: []const u8 = "",
        line: ?usize = null,
        column: ?usize = null,
        end_column: ?usize = null,
    };
    var dests = std.ArrayList(Dest).init(a);
    defer dests.deinit();
    var prev: ?*Dest = null;
    var line_next: ?usize = null;
    for (res.positionals) |arg| {
        if (arg.len == 0) continue;

        if (arg[0] == '+') {
            const line = try std.fmt.parseInt(usize, arg[1..], 10);
            if (prev) |p| {
                p.line = line;
            } else {
                line_next = line;
            }
            continue;
        }

        const curr = try dests.addOne();
        curr.* = .{};
        prev = curr;
        if (line_next) |line| {
            curr.line = line;
            line_next = null;
        }
        var it = std.mem.splitScalar(u8, arg, ':');
        curr.file = it.first();
        if (it.next()) |line_|
            curr.line = std.fmt.parseInt(usize, line_, 10) catch null;
        if (it.next()) |col_|
            curr.column = std.fmt.parseInt(usize, col_, 10) catch null;
        if (it.next()) |col_|
            curr.end_column = std.fmt.parseInt(usize, col_, 10) catch null;
    }

    for (dests.items) |dest| {
        if (dest.file.len == 0) continue;
        if (dest.line) |l| {
            if (dest.column) |col| {
                try tui_proc.send(.{ "cmd", "navigate", .{ .file = dest.file, .line = l, .column = col } });
                if (dest.end_column) |end|
                    try tui_proc.send(.{ "A", l, col - 1, end - 1 });
            } else {
                try tui_proc.send(.{ "cmd", "navigate", .{ .file = dest.file, .line = l } });
            }
        } else {
            try tui_proc.send(.{ "cmd", "navigate", .{ .file = dest.file } });
        }
    } else {
        try tui_proc.send(.{ "cmd", "show_home" });
    }
    ctx.run();

    if (want_restart) restart();
    exit(final_exit_status);
}

var final_exit_status: u8 = 0;
var want_restart: bool = false;

fn print_exit_status(_: void, msg: []const u8) void {
    if (std.mem.eql(u8, msg, "normal")) {
        return;
    } else if (std.mem.eql(u8, msg, "restart")) {
        want_restart = true;
    } else {
        std.io.getStdErr().writer().print("\n" ++ application_name ++ " ERROR: {s}\n", .{msg}) catch {};
        final_exit_status = 1;
    }
}

fn count_args() usize {
    var args = std.process.args();
    _ = args.next();
    var count: usize = 0;
    while (args.next()) |_| {
        count += 1;
    }
    return count;
}

fn trace(m: thespian.message.c_buffer_type) callconv(.C) void {
    thespian.message.from(m).to_json_cb(trace_json);
}

fn trace_json(json: thespian.message.json_string_view) callconv(.C) void {
    const callstack_depth = 10;
    ___tracy_emit_message(json.base, json.len, callstack_depth);
}
extern fn ___tracy_emit_message(txt: [*]const u8, size: usize, callstack: c_int) void;

fn exit(status: u8) noreturn {
    if (builtin.os.tag == .linux) {
        // drain stdin so we don't leave junk at the next prompt
        _ = std.os.linux.syscall3(.ioctl, @as(usize, @bitCast(@as(isize, std.os.STDIN_FILENO))), std.os.linux.T.CFLSH, 0);
    }
    std.os.exit(status);
}

const config = @import("config");

pub fn read_config(a: std.mem.Allocator, buf: *?[]const u8) config {
    const file_name = get_app_config_file_name(application_name) catch return .{};
    return read_json_config_file(a, file_name, buf) catch .{};
}

fn read_json_config_file(a: std.mem.Allocator, file_name: []const u8, buf: *?[]const u8) !config {
    const cbor = @import("cbor");
    var file = std.fs.openFileAbsolute(file_name, .{ .mode = .read_only }) catch |e| switch (e) {
        error.FileNotFound => return .{},
        else => return e,
    };
    defer file.close();
    const json = try file.readToEndAlloc(a, 64 * 1024);
    defer a.free(json);
    const cbor_buf: []u8 = try a.alloc(u8, json.len);
    buf.* = cbor_buf;
    const cb = try cbor.fromJson(json, cbor_buf);
    var iter = cb;
    var len = try cbor.decodeMapHeader(&iter);
    var data: config = .{};
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidConfig;
        inline for (@typeInfo(config).Struct.fields) |field_info| {
            if (std.mem.eql(u8, field_name, field_info.name)) {
                var value: field_info.type = undefined;
                if (!(try cbor.matchValue(&iter, cbor.extract(&value)))) return error.InvalidConfig;
                @field(data, field_info.name) = value;
            }
        }
    }
    return data;
}

pub fn write_config(conf: config, a: std.mem.Allocator) !void {
    return write_json_file(config, conf, a, try get_app_config_file_name(application_name));
}

fn write_json_file(comptime T: type, data: T, a: std.mem.Allocator, file_name: []const u8) !void {
    const cbor = @import("cbor");
    var file = try std.fs.createFileAbsolute(file_name, .{ .truncate = true });
    defer file.close();

    var cb = std.ArrayList(u8).init(a);
    defer cb.deinit();
    try cbor.writeValue(cb.writer(), data);

    var s = std.json.writeStream(file.writer(), .{ .whitespace = .indent_4 });
    var iter: []const u8 = cb.items;
    try cbor.JsonStream(std.fs.File).jsonWriteValue(&s, &iter);
}

pub fn get_config_dir() ![]const u8 {
    return get_app_config_dir(application_name);
}

fn get_app_config_dir(appname: []const u8) ![]const u8 {
    const local = struct {
        var config_dir_buffer: [std.os.PATH_MAX]u8 = undefined;
        var config_dir: ?[]const u8 = null;
    };
    const config_dir = if (local.config_dir) |dir|
        dir
    else if (std.os.getenv("XDG_CONFIG_HOME")) |xdg|
        try std.fmt.bufPrint(&local.config_dir_buffer, "{s}/{s}", .{ xdg, appname })
    else if (std.os.getenv("HOME")) |home|
        try std.fmt.bufPrint(&local.config_dir_buffer, "{s}/.config/{s}", .{ home, appname })
    else
        return error.AppConfigDirUnavailable;
    local.config_dir = config_dir;
    std.fs.makeDirAbsolute(config_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    return config_dir;
}

fn get_app_config_file_name(appname: []const u8) ![]const u8 {
    const local = struct {
        var config_file_buffer: [std.os.PATH_MAX]u8 = undefined;
        var config_file: ?[]const u8 = null;
    };
    const config_file_name = "config.json";
    const config_file = if (local.config_file) |file|
        file
    else
        try std.fmt.bufPrint(&local.config_file_buffer, "{s}/{s}", .{ try get_app_config_dir(appname), config_file_name });
    local.config_file = config_file;
    return config_file;
}

pub fn get_config_file_name() ![]const u8 {
    return get_app_config_file_name(application_name);
}

pub fn get_restore_file_name() ![]const u8 {
    const local = struct {
        var restore_file_buffer: [std.os.PATH_MAX]u8 = undefined;
        var restore_file: ?[]const u8 = null;
    };
    const restore_file_name = "restore";
    const restore_file = if (local.restore_file) |file|
        file
    else
        try std.fmt.bufPrint(&local.restore_file_buffer, "{s}/{s}", .{ try get_app_config_dir(application_name), restore_file_name });
    local.restore_file = restore_file;
    return restore_file;
}

fn restart() noreturn {
    const argv = [_]?[*:0]const u8{
        std.os.argv[0],
        "--restore-session",
        null,
    };
    const ret = std.c.execve(std.os.argv[0], @ptrCast(&argv), @ptrCast(std.os.environ));
    std.io.getStdErr().writer().print("\nrestart failed: {d}", .{ret}) catch {};
    exit(234);
}
