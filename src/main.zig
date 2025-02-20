const std = @import("std");
const tui = @import("tui");
const thespian = @import("thespian");
const flags = @import("flags");
const builtin = @import("builtin");

const bin_path = @import("bin_path.zig");
const list_languages = @import("list_languages.zig");

const c = @cImport({
    @cInclude("locale.h");
});

const build_options = @import("build_options");
const log = @import("log");

pub const version_info = @embedFile("version_info");

pub var max_diff_lines: usize = 50000;
pub var max_syntax_lines: usize = 50000;

pub const application_name = "flow";
pub const application_title = "Flow Control";
pub const application_subtext = "a programmer's text editor";
pub const application_description = application_title ++ ": " ++ application_subtext;

pub const std_options: std.Options = .{
    // .log_level = if (builtin.mode == .Debug) .debug else .warn,
    .log_level = if (builtin.mode == .Debug) .info else .warn,
    .logFn = log.std_log_function,
};

const renderer = @import("renderer");

pub const panic = if (@hasDecl(renderer, "panic")) renderer.panic else default_panic;

fn default_panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    return std.debug.defaultPanic(msg, ret_addr);
}

pub fn main() anyerror!void {
    if (builtin.os.tag == .linux) {
        // drain stdin so we don't pickup junk from previous application/shell
        _ = std.os.linux.syscall3(.ioctl, @as(usize, @bitCast(@as(isize, std.posix.STDIN_FILENO))), std.os.linux.T.CFLSH, 0);
    }

    const a = std.heap.c_allocator;
    const case_data = @import("Buffer").unicode.get_case_data();
    _ = case_data; // no need to free case_data as it is globally static

    const Flags = struct {
        pub const description =
            application_title ++ ": " ++ application_subtext ++
            \\
            \\
            \\Pass in file names to be opened with an optional :LINE or :LINE:COL appended to the
            \\file name to specify a specific location, or pass +<LINE> separately to set the line.
        ;

        pub const descriptions = .{
            .project = "Set project directory (default: cwd)",
            .no_persist = "Do not persist new projects",
            .frame_rate = "Set target frame rate (default: 60)",
            .debug_wait = "Wait for key press before starting UI",
            .debug_dump_on_error = "Dump stack traces on errors",
            .no_sleep = "Do not sleep the main loop when idle",
            .no_alternate = "Do not use the alternate terminal screen",
            .trace_level = "Enable internal tracing (level of detail from 1-5)",
            .no_trace = "Do not enable internal tracing",
            .restore_session = "Restore restart session",
            .show_input = "Open the input view on start",
            .show_log = "Open the log view on start",
            .language = "Force the language of the file to be opened",
            .list_languages = "Show available languages",
            .no_syntax = "Disable syntax highlighting",
            .syntax_report_timing = "Report syntax highlighting time",
            .exec = "Execute a command on startup",
            .literal = "Disable :LINE and +LINE syntax",
            .scratch = "Open a scratch (temporary) buffer on start",
            .new_file = "Create a new untitled file on start",
            .version = "Show build version and exit",
        };

        pub const formats = .{ .frame_rate = "num", .trace_level = "num", .exec = "cmds" };

        pub const switches = .{
            .project = 'p',
            .no_persist = 'N',
            .frame_rate = 'f',
            .trace_level = 't',
            .language = 'l',
            .exec = 'e',
            .literal = 'L',
            .scratch = 'S',
            .new_file = 'n',
            .version = 'v',
        };

        project: ?[]const u8,
        no_persist: bool,
        frame_rate: ?usize,
        debug_wait: bool,
        debug_dump_on_error: bool,
        no_sleep: bool,
        no_alternate: bool,
        trace_level: u8 = 0,
        no_trace: bool,
        restore_session: bool,
        show_input: bool,
        show_log: bool,
        language: ?[]const u8,
        list_languages: bool,
        no_syntax: bool,
        syntax_report_timing: bool,
        exec: ?[]const u8,
        literal: bool,
        scratch: bool,
        new_file: bool,
        version: bool,
    };

    var arg_iter = try std.process.argsWithAllocator(a);
    defer arg_iter.deinit();

    var diag: flags.Diagnostics = undefined;
    var positional_args = std.ArrayList([]const u8).init(a);
    defer positional_args.deinit();

    const args = flags.parse(&arg_iter, "flow", Flags, .{
        .diagnostics = &diag,
        .trailing_list = &positional_args,
    }) catch |err| {
        if (err == error.PrintedHelp) exit(0);
        diag.help.generated.render(std.io.getStdOut(), flags.ColorScheme.default) catch {};
        exit(1);
        return err;
    };

    if (args.version)
        return std.io.getStdOut().writeAll(version_info);

    if (args.list_languages) {
        const stdout = std.io.getStdOut();
        const tty_config = std.io.tty.detectConfig(stdout);
        return list_languages.list(a, stdout.writer(), tty_config);
    }

    if (builtin.os.tag != .windows)
        if (std.posix.getenv("JITDEBUG")) |_| thespian.install_debugger();

    if (args.debug_wait) {
        std.debug.print("press return to start", .{});
        var buf: [1]u8 = undefined;
        _ = try std.io.getStdIn().read(&buf);
    }

    if (c.setlocale(c.LC_ALL, "") == null) {
        try std.io.getStdErr().writer().print("Failed to set locale. Is your locale valid?\n", .{});
        exit(1);
    }

    thespian.stack_trace_on_errors = args.debug_dump_on_error;

    var ctx = try thespian.context.init(a);
    defer ctx.deinit();

    const env = thespian.env.init();
    defer env.deinit();
    if (build_options.enable_tracy) {
        if (!args.no_trace) {
            env.enable_all_channels();
            env.on_trace(trace);
        }
    } else {
        if (args.trace_level != 0) {
            var threshold: usize = 1;
            if (args.trace_level >= threshold) {
                env.enable(thespian.channel.debug);
            }
            threshold += 1;
            if (args.trace_level >= threshold) {
                env.enable(thespian.channel.widget);
            }
            threshold += 1;
            if (args.trace_level >= threshold) {
                env.enable(thespian.channel.event);
            }
            threshold += 1;
            if (args.trace_level >= threshold) {
                env.enable(thespian.channel.input);
            }
            threshold += 1;
            if (args.trace_level >= threshold) {
                env.enable(thespian.channel.receive);
            }
            threshold += 1;
            if (args.trace_level >= threshold) {
                env.enable(thespian.channel.metronome);
                env.enable(thespian.channel.execute);
                env.enable(thespian.channel.link);
            }
            threshold += 1;
            if (args.trace_level >= threshold) {
                env.enable(thespian.channel.send);
            }
            threshold += 1;
            if (args.trace_level >= threshold) {
                env.enable_all_channels();
            }

            env.on_trace(trace_to_file);
        }
    }

    const log_proc = try log.spawn(&ctx, a, &env);
    defer log_proc.deinit();
    log.set_std_log_pid(log_proc.ref());
    defer log.set_std_log_pid(null);

    env.set("no-persist", args.no_persist);
    env.set("restore-session", args.restore_session);
    env.set("no-alternate", args.no_alternate);
    env.set("show-input", args.show_input);
    env.set("show-log", args.show_log);
    env.set("no-sleep", args.no_sleep);
    env.set("no-syntax", args.no_syntax);
    env.set("syntax-report-timing", args.syntax_report_timing);
    env.set("dump-stack-trace", args.debug_dump_on_error);
    if (args.frame_rate) |s| env.num_set("frame-rate", @intCast(s));
    env.proc_set("log", log_proc.ref());
    if (args.language) |s| env.str_set("language", s);

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
    for (positional_args.items) |arg| {
        if (arg.len == 0) continue;

        if (!args.literal and arg[0] == '+') {
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
        if (!args.literal) {
            var it = std.mem.splitScalar(u8, arg, ':');
            curr.file = it.first();
            if (it.next()) |line_|
                curr.line = std.fmt.parseInt(usize, line_, 10) catch blk: {
                    curr.file = arg;
                    break :blk null;
                };
            if (curr.line) |_| {
                if (it.next()) |col_|
                    curr.column = std.fmt.parseInt(usize, col_, 10) catch null;
                if (it.next()) |col_|
                    curr.end_column = std.fmt.parseInt(usize, col_, 10) catch null;
            }
        } else {
            curr.file = arg;
        }
    }

    var have_project = false;
    var files = std.ArrayList(Dest).init(a);
    defer files.deinit();
    if (args.project) |project| {
        try tui_proc.send(.{ "cmd", "open_project_dir", .{project} });
        have_project = true;
    }
    for (dests.items) |dest| {
        if (dest.file.len == 0) continue;
        if (is_directory(dest.file)) {
            if (have_project) {
                std.debug.print("more than one project directory is not allowed\n", .{});
                exit(1);
            }
            try tui_proc.send(.{ "cmd", "open_project_dir", .{dest.file} });

            have_project = true;
        } else {
            const curr = try files.addOne();
            curr.* = dest;
        }
    }

    for (files.items) |dest| {
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
        if (!have_project)
            try tui_proc.send(.{ "cmd", "open_project_cwd" });
        try tui_proc.send(.{ "cmd", "show_home" });
    }

    if (args.new_file) {
        try tui_proc.send(.{ "cmd", "create_new_file", .{} });
    } else if (args.scratch) {
        try tui_proc.send(.{ "cmd", "create_scratch_buffer", .{} });
    }

    if (args.exec) |exec_str| {
        var cmds = std.mem.splitScalar(u8, exec_str, ';');
        while (cmds.next()) |cmd| try tui_proc.send(.{ "cmd", cmd, .{} });
    }

    ctx.run();

    if (want_restart) restart();
    exit(final_exit_status);
}

var final_exit_status: u8 = 0;
var want_restart: bool = false;

pub fn print_exit_status(_: void, msg: []const u8) void {
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

fn trace_to_file(m: thespian.message.c_buffer_type) callconv(.C) void {
    const cbor = @import("cbor");
    const State = struct {
        file: std.fs.File,
        last_time: i64,
        var state: ?@This() = null;

        fn write_tdiff(writer: anytype, tdiff: i64) !void {
            const msi = @divFloor(tdiff, std.time.us_per_ms);
            if (msi < 10) {
                const d: f64 = @floatFromInt(tdiff);
                const ms = d / std.time.us_per_ms;
                _ = try writer.print("{d:6.2} ", .{ms});
            } else {
                const ms: u64 = @intCast(msi);
                _ = try writer.print("{d:6} ", .{ms});
            }
        }
    };
    var state: *State = &(State.state orelse init: {
        const a = std.heap.c_allocator;
        var path = std.ArrayList(u8).init(a);
        defer path.deinit();
        path.writer().print("{s}/trace.log", .{get_state_dir() catch return}) catch return;
        const file = std.fs.createFileAbsolute(path.items, .{ .truncate = true }) catch return;
        State.state = .{
            .file = file,
            .last_time = std.time.microTimestamp(),
        };
        break :init State.state.?;
    });
    const file_writer = state.file.writer();
    var buffer = std.io.bufferedWriter(file_writer);
    const writer = buffer.writer();

    const ts = std.time.microTimestamp();
    State.write_tdiff(writer, ts - state.last_time) catch {};
    state.last_time = ts;

    var stream = std.json.writeStream(writer, .{});
    var iter: []const u8 = m.base[0..m.len];
    cbor.JsonStream(@TypeOf(buffer)).jsonWriteValue(&stream, &iter) catch {};
    _ = writer.write("\n") catch {};
    buffer.flush() catch {};
}

pub fn exit(status: u8) noreturn {
    if (builtin.os.tag == .linux) {
        // drain stdin so we don't leave junk at the next prompt
        _ = std.os.linux.syscall3(.ioctl, @as(usize, @bitCast(@as(isize, std.posix.STDIN_FILENO))), std.os.linux.T.CFLSH, 0);
    }
    std.posix.exit(status);
}

pub fn free_config(allocator: std.mem.Allocator, bufs: [][]const u8) void {
    for (bufs) |buf| allocator.free(buf);
}

var config_mutex: std.Thread.Mutex = .{};

pub fn exists_config(T: type) bool {
    config_mutex.lock();
    defer config_mutex.unlock();
    const json_file_name = get_app_config_file_name(application_name, @typeName(T)) catch return false;
    const text_file_name = json_file_name[0 .. json_file_name.len - ".json".len];
    var file = std.fs.openFileAbsolute(text_file_name, .{ .mode = .read_only }) catch return false;
    defer file.close();
    return true;
}

pub fn read_config(T: type, allocator: std.mem.Allocator) struct { T, [][]const u8 } {
    config_mutex.lock();
    defer config_mutex.unlock();
    var bufs: [][]const u8 = &[_][]const u8{};
    const json_file_name = get_app_config_file_name(application_name, @typeName(T)) catch return .{ .{}, bufs };
    const text_file_name = json_file_name[0 .. json_file_name.len - ".json".len];
    var conf: T = .{};
    if (!read_config_file(T, allocator, &conf, &bufs, text_file_name)) {
        _ = read_config_file(T, allocator, &conf, &bufs, json_file_name);
    }
    read_nested_include_files(T, allocator, &conf, &bufs);
    return .{ conf, bufs };
}

// returns true if the file was found
fn read_config_file(T: type, allocator: std.mem.Allocator, conf: *T, bufs: *[][]const u8, file_name: []const u8) bool {
    std.log.info("loading {s}", .{file_name});
    const err: anyerror = blk: {
        if (std.mem.endsWith(u8, file_name, ".json")) if (read_json_config_file(T, allocator, conf, bufs, file_name)) return true else |e| break :blk e;
        if (read_text_config_file(T, allocator, conf, bufs, file_name)) return true else |e| break :blk e;
    };
    switch (err) {
        error.FileNotFound => return false,
        else => |e| std.log.err("error reading config file '{s}': {s}", .{ file_name, @errorName(e) }),
    }
    return true;
}

fn read_text_config_file(T: type, allocator: std.mem.Allocator, conf: *T, bufs_: *[][]const u8, file_name: []const u8) !void {
    const cbor = @import("cbor");
    var file = try std.fs.openFileAbsolute(file_name, .{ .mode = .read_only });
    defer file.close();
    const text = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(text);
    var cbor_buf = std.ArrayList(u8).init(allocator);
    defer cbor_buf.deinit();
    const writer = cbor_buf.writer();
    var it = std.mem.splitScalar(u8, text, '\n');
    var lineno: u32 = 0;
    while (it.next()) |line| {
        lineno += 1;
        if (line.len == 0 or line[0] == '#')
            continue;
        const sep = std.mem.indexOfScalar(u8, line, ' ') orelse {
            std.log.err("{s}:{}: {s} missing value", .{ file_name, lineno, line });
            continue;
        };
        const name = line[0..sep];
        const value_str = line[sep + 1 ..];
        const cb = cbor.fromJsonAlloc(allocator, value_str) catch {
            std.log.err("{s}:{}: {s} has bad value: {s}", .{ file_name, lineno, name, value_str });
            continue;
        };
        defer allocator.free(cb);
        try cbor.writeValue(writer, name);
        try cbor_buf.appendSlice(cb);
    }
    const cb = try cbor_buf.toOwnedSlice();
    var bufs = std.ArrayListUnmanaged([]const u8).fromOwnedSlice(bufs_.*);
    bufs.append(allocator, cb) catch @panic("OOM:read_text_config_file");
    bufs_.* = bufs.toOwnedSlice(allocator) catch @panic("OOM:read_text_config_file");
    return read_cbor_config(T, conf, file_name, cb);
}

fn read_json_config_file(T: type, allocator: std.mem.Allocator, conf: *T, bufs_: *[][]const u8, file_name: []const u8) !void {
    const cbor = @import("cbor");
    var file = try std.fs.openFileAbsolute(file_name, .{ .mode = .read_only });
    defer file.close();
    const json = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(json);
    const cbor_buf: []u8 = try allocator.alloc(u8, json.len);
    var bufs = std.ArrayListUnmanaged([]const u8).fromOwnedSlice(bufs_.*);
    bufs.append(allocator, cbor_buf) catch @panic("OOM:read_json_config_file");
    bufs_.* = bufs.toOwnedSlice(allocator) catch @panic("OOM:read_json_config_file");
    const cb = try cbor.fromJson(json, cbor_buf);
    var iter = cb;
    _ = try cbor.decodeMapHeader(&iter);
    return read_cbor_config(T, conf, file_name, iter);
}

fn read_cbor_config(
    T: type,
    conf: *T,
    file_name: []const u8,
    cb: []const u8,
) !void {
    const cbor = @import("cbor");
    var iter = cb;
    var field_name: []const u8 = undefined;
    while (cbor.matchString(&iter, &field_name) catch |e| switch (e) {
        error.TooShort => return,
        else => return e,
    }) {
        var known = false;
        inline for (@typeInfo(T).@"struct".fields) |field_info|
            if (comptime std.mem.eql(u8, "include_files", field_info.name)) {
                if (std.mem.eql(u8, field_name, field_info.name)) {
                    known = true;
                    var value: field_info.type = undefined;
                    if (try cbor.matchValue(&iter, cbor.extract(&value))) {
                        if (conf.include_files.len > 0) {
                            std.log.err("{s}: ignoring nested 'include_files' value '{s}'", .{ file_name, value });
                        } else {
                            @field(conf, field_info.name) = value;
                        }
                    } else {
                        try cbor.skipValue(&iter);
                        std.log.err("invalid value for key '{s}'", .{field_name});
                    }
                }
            } else if (std.mem.eql(u8, field_name, field_info.name)) {
                known = true;
                var value: field_info.type = undefined;
                if (try cbor.matchValue(&iter, cbor.extract(&value))) {
                    @field(conf, field_info.name) = value;
                } else {
                    try cbor.skipValue(&iter);
                    std.log.err("invalid value for key '{s}'", .{field_name});
                }
            };
        if (!known) {
            try cbor.skipValue(&iter);
            std.log.err("unknown config value '{s}' ignored", .{field_name});
        }
    }
}

fn read_nested_include_files(T: type, allocator: std.mem.Allocator, conf: *T, bufs: *[][]const u8) void {
    if (conf.include_files.len == 0) return;
    var it = std.mem.splitScalar(u8, conf.include_files, std.fs.path.delimiter);
    while (it.next()) |path| if (!read_config_file(T, allocator, conf, bufs, path)) {
        std.log.err("config include file '{s}' is not found", .{path});
    };
}

pub fn write_config(conf: anytype, allocator: std.mem.Allocator) !void {
    config_mutex.lock();
    defer config_mutex.unlock();
    _ = allocator;
    const file_name = try get_app_config_file_name(application_name, @typeName(@TypeOf(conf)));
    return write_text_config_file(@TypeOf(conf), conf, file_name[0 .. file_name.len - 5]);
    // return write_json_file(@TypeOf(conf), conf, allocator, try get_app_config_file_name(application_name, @typeName(@TypeOf(conf))));
}

fn write_text_config_file(comptime T: type, data: T, file_name: []const u8) !void {
    var file = try std.fs.createFileAbsolute(file_name, .{ .truncate = true });
    defer file.close();
    const writer = file.writer();
    return write_config_to_writer(T, data, writer);
}

pub fn write_config_to_writer(comptime T: type, data: T, writer: anytype) !void {
    const default: T = .{};
    inline for (@typeInfo(T).@"struct".fields) |field_info| {
        if (config_eql(
            field_info.type,
            @field(data, field_info.name),
            @field(default, field_info.name),
        )) {
            try writer.print("# {s} ", .{field_info.name});
        } else {
            try writer.print("{s} ", .{field_info.name});
        }
        var s = std.json.writeStream(writer, .{ .whitespace = .indent_4 });
        try s.write(@field(data, field_info.name));
        try writer.print("\n", .{});
    }
}

fn config_eql(comptime T: type, a: T, b: T) bool {
    switch (T) {
        []const u8 => return std.mem.eql(u8, a, b),
        else => {},
    }
    switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum" => return a == b,
        .optional => |info| {
            if (a == null and b == null)
                return true;
            if (a == null or b == null)
                return false;
            return config_eql(info.child, a.?, b.?);
        },
        else => {},
    }
    @compileError("unsupported config type " ++ @typeName(T));
}

fn write_json_file(comptime T: type, data: T, allocator: std.mem.Allocator, file_name: []const u8) !void {
    const cbor = @import("cbor");
    var file = try std.fs.createFileAbsolute(file_name, .{ .truncate = true });
    defer file.close();

    var cb = std.ArrayList(u8).init(allocator);
    defer cb.deinit();
    try cbor.writeValue(cb.writer(), data);

    var s = std.json.writeStream(file.writer(), .{ .whitespace = .indent_4 });
    var iter: []const u8 = cb.items;
    try cbor.JsonStream(std.fs.File).jsonWriteValue(&s, &iter);
}

pub fn read_keybind_namespace(allocator: std.mem.Allocator, namespace_name: []const u8) ?[]const u8 {
    const file_name = get_keybind_namespace_file_name(namespace_name) catch return null;
    var file = std.fs.openFileAbsolute(file_name, .{ .mode = .read_only }) catch return null;
    defer file.close();
    return file.readToEndAlloc(allocator, 64 * 1024) catch null;
}

pub fn write_keybind_namespace(namespace_name: []const u8, content: []const u8) !void {
    const file_name = try get_keybind_namespace_file_name(namespace_name);
    var file = try std.fs.createFileAbsolute(file_name, .{ .truncate = true });
    defer file.close();
    return file.writeAll(content);
}

pub fn list_keybind_namespaces(allocator: std.mem.Allocator) ![]const []const u8 {
    var dir = try std.fs.openDirAbsolute(try get_keybind_namespaces_directory(), .{ .iterate = true });
    defer dir.close();
    var result = std.ArrayList([]const u8).init(allocator);
    var iter = dir.iterateAssumeFirstIteration();
    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .file, .sym_link => try result.append(try allocator.dupe(u8, std.fs.path.stem(entry.name))),
            else => continue,
        }
    }
    return result.toOwnedSlice();
}

pub fn get_config_dir() ![]const u8 {
    return get_app_config_dir(application_name);
}

fn get_app_config_dir(appname: []const u8) ![]const u8 {
    const a = std.heap.c_allocator;
    const local = struct {
        var config_dir_buffer: [std.posix.PATH_MAX]u8 = undefined;
        var config_dir: ?[]const u8 = null;
    };
    const config_dir = if (local.config_dir) |dir|
        dir
    else if (std.process.getEnvVarOwned(a, "XDG_CONFIG_HOME") catch null) |xdg| ret: {
        defer a.free(xdg);
        break :ret try std.fmt.bufPrint(&local.config_dir_buffer, "{s}/{s}", .{ xdg, appname });
    } else if (std.process.getEnvVarOwned(a, "HOME") catch null) |home| ret: {
        defer a.free(home);
        const dir = try std.fmt.bufPrint(&local.config_dir_buffer, "{s}/.config", .{home});
        std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        break :ret try std.fmt.bufPrint(&local.config_dir_buffer, "{s}/.config/{s}", .{ home, appname });
    } else if (builtin.os.tag == .windows) ret: {
        if (std.process.getEnvVarOwned(a, "APPDATA") catch null) |appdata| {
            defer a.free(appdata);
            const dir = try std.fmt.bufPrint(&local.config_dir_buffer, "{s}/{s}", .{ appdata, appname });
            std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
            break :ret dir;
        } else return error.AppConfigDirUnavailable;
    } else return error.AppConfigDirUnavailable;

    local.config_dir = config_dir;
    std.fs.makeDirAbsolute(config_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    var keybind_dir_buffer: [std.posix.PATH_MAX]u8 = undefined;
    std.fs.makeDirAbsolute(try std.fmt.bufPrint(&keybind_dir_buffer, "{s}/{s}", .{ config_dir, keybind_dir })) catch {};

    return config_dir;
}

pub fn get_cache_dir() ![]const u8 {
    return get_app_cache_dir(application_name);
}

fn get_app_cache_dir(appname: []const u8) ![]const u8 {
    const a = std.heap.c_allocator;
    const local = struct {
        var cache_dir_buffer: [std.posix.PATH_MAX]u8 = undefined;
        var cache_dir: ?[]const u8 = null;
    };
    const cache_dir = if (local.cache_dir) |dir|
        dir
    else if (std.process.getEnvVarOwned(a, "XDG_CACHE_HOME") catch null) |xdg| ret: {
        defer a.free(xdg);
        break :ret try std.fmt.bufPrint(&local.cache_dir_buffer, "{s}/{s}", .{ xdg, appname });
    } else if (std.process.getEnvVarOwned(a, "HOME") catch null) |home| ret: {
        defer a.free(home);
        const dir = try std.fmt.bufPrint(&local.cache_dir_buffer, "{s}/.cache", .{home});
        std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        break :ret try std.fmt.bufPrint(&local.cache_dir_buffer, "{s}/.cache/{s}", .{ home, appname });
    } else if (builtin.os.tag == .windows) ret: {
        if (std.process.getEnvVarOwned(a, "APPDATA") catch null) |appdata| {
            defer a.free(appdata);
            const dir = try std.fmt.bufPrint(&local.cache_dir_buffer, "{s}/{s}", .{ appdata, appname });
            std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
            break :ret dir;
        } else return error.AppCacheDirUnavailable;
    } else return error.AppCacheDirUnavailable;

    local.cache_dir = cache_dir;
    std.fs.makeDirAbsolute(cache_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    return cache_dir;
}

pub fn get_state_dir() ![]const u8 {
    return get_app_state_dir(application_name);
}

fn get_app_state_dir(appname: []const u8) ![]const u8 {
    const a = std.heap.c_allocator;
    const local = struct {
        var state_dir_buffer: [std.posix.PATH_MAX]u8 = undefined;
        var state_dir: ?[]const u8 = null;
    };
    const state_dir = if (local.state_dir) |dir|
        dir
    else if (std.process.getEnvVarOwned(a, "XDG_STATE_HOME") catch null) |xdg| ret: {
        defer a.free(xdg);
        break :ret try std.fmt.bufPrint(&local.state_dir_buffer, "{s}/{s}", .{ xdg, appname });
    } else if (std.process.getEnvVarOwned(a, "HOME") catch null) |home| ret: {
        defer a.free(home);
        var dir = try std.fmt.bufPrint(&local.state_dir_buffer, "{s}/.local", .{home});
        std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        dir = try std.fmt.bufPrint(&local.state_dir_buffer, "{s}/.local/state", .{home});
        std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        break :ret try std.fmt.bufPrint(&local.state_dir_buffer, "{s}/.local/state/{s}", .{ home, appname });
    } else if (builtin.os.tag == .windows) ret: {
        if (std.process.getEnvVarOwned(a, "APPDATA") catch null) |appdata| {
            defer a.free(appdata);
            const dir = try std.fmt.bufPrint(&local.state_dir_buffer, "{s}/{s}", .{ appdata, appname });
            std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
            break :ret dir;
        } else return error.AppCacheDirUnavailable;
    } else return error.AppCacheDirUnavailable;

    local.state_dir = state_dir;
    std.fs.makeDirAbsolute(state_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    return state_dir;
}

fn get_app_config_file_name(appname: []const u8, comptime base_name: []const u8) ![]const u8 {
    return get_app_config_dir_file_name(appname, base_name ++ ".json");
}

fn get_app_config_dir_file_name(appname: []const u8, comptime config_file_name: []const u8) ![]const u8 {
    const local = struct {
        var config_file_buffer: [std.posix.PATH_MAX]u8 = undefined;
    };
    return std.fmt.bufPrint(&local.config_file_buffer, "{s}/{s}", .{ try get_app_config_dir(appname), config_file_name });
}

pub fn get_config_file_name(T: type) ![]const u8 {
    return get_app_config_file_name(application_name, @typeName(T));
}

pub fn get_restore_file_name() ![]const u8 {
    const local = struct {
        var restore_file_buffer: [std.posix.PATH_MAX]u8 = undefined;
        var restore_file: ?[]const u8 = null;
    };
    const restore_file_name = "restore";
    const restore_file = if (local.restore_file) |file|
        file
    else
        try std.fmt.bufPrint(&local.restore_file_buffer, "{s}/{s}", .{ try get_app_cache_dir(application_name), restore_file_name });
    local.restore_file = restore_file;
    return restore_file;
}

const keybind_dir = "keys";

fn get_keybind_namespaces_directory() ![]const u8 {
    const local = struct {
        var dir_buffer: [std.posix.PATH_MAX]u8 = undefined;
    };
    const a = std.heap.c_allocator;
    if (std.process.getEnvVarOwned(a, "FLOW_KEYS_DIR") catch null) |dir| {
        defer a.free(dir);
        return try std.fmt.bufPrint(&local.dir_buffer, "{s}", .{dir});
    }
    return try std.fmt.bufPrint(&local.dir_buffer, "{s}/{s}", .{ try get_app_config_dir(application_name), keybind_dir });
}

pub fn get_keybind_namespace_file_name(namespace_name: []const u8) ![]const u8 {
    const dir = try get_keybind_namespaces_directory();
    const local = struct {
        var file_buffer: [std.posix.PATH_MAX]u8 = undefined;
    };
    return try std.fmt.bufPrint(&local.file_buffer, "{s}/{s}.json", .{ dir, namespace_name });
}

fn restart() noreturn {
    var executable: [:0]const u8 = std.mem.span(std.os.argv[0]);
    var is_basename = true;
    for (executable) |char| if (std.fs.path.isSep(char)) {
        is_basename = false;
    };
    if (is_basename) {
        const a = std.heap.c_allocator;
        executable = bin_path.find_binary_in_path(a, executable) catch executable orelse executable;
    }
    const argv = [_]?[*:0]const u8{
        executable,
        "--restore-session",
        null,
    };
    const ret = std.c.execve(executable, @ptrCast(&argv), @ptrCast(std.os.environ));
    std.io.getStdErr().writer().print("\nrestart failed: {d}", .{ret}) catch {};
    exit(234);
}

pub fn is_directory(rel_path: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = std.fs.cwd().realpath(rel_path, &path_buf) catch return false;
    var dir = std.fs.openDirAbsolute(abs_path, .{}) catch return false;
    dir.close();
    return true;
}

pub fn shorten_path(buf: []u8, path: []const u8, removed_prefix: *usize, max_len: usize) []const u8 {
    removed_prefix.* = 0;
    if (path.len <= max_len) return path;
    const ellipsis = "…";
    const prefix = path.len - max_len;
    defer removed_prefix.* = prefix - 1;
    @memcpy(buf[0..ellipsis.len], ellipsis);
    @memcpy(buf[ellipsis.len .. max_len + ellipsis.len], path[prefix..]);
    return buf[0 .. max_len + ellipsis.len];
}

pub fn abbreviate_home(buf: []u8, path: []const u8) []const u8 {
    const a = std.heap.c_allocator;
    if (builtin.os.tag == .windows) return path;
    if (!std.fs.path.isAbsolute(path)) return path;
    const homedir = std.posix.getenv("HOME") orelse return path;
    const homerelpath = std.fs.path.relative(a, homedir, path) catch return path;
    defer a.free(homerelpath);
    if (homerelpath.len == 0) {
        return "~";
    } else if (homerelpath.len > 3 and std.mem.eql(u8, homerelpath[0..3], "../")) {
        return path;
    } else {
        buf[0] = '~';
        buf[1] = '/';
        @memcpy(buf[2 .. homerelpath.len + 2], homerelpath);
        return buf[0 .. homerelpath.len + 2];
    }
}
