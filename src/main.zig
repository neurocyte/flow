const std = @import("std");
const tui = @import("tui");
const cbor = @import("cbor");
const thespian = @import("thespian");
const color = @import("color");
const flags = @import("flags");
const builtin = @import("builtin");
const bin_path = @import("bin_path");
const sep = std.fs.path.sep;

const list_languages = @import("list_languages.zig");
const file_link = @import("file_link");

const c = @import("c");

const build_options = @import("build_options");
const log = @import("log");

pub const version = @embedFile("version");
pub const version_info = @embedFile("version_info");
pub const version_number: []const u8 = if (version.len > 0 and version[0] == 'v') version[1..] else version;

pub const max_diff_lines: usize = 50000;
pub const max_syntax_lines: usize = 50000;

pub const application_name = "flow";
pub const application_title = "Flow Control";
pub const application_subtext = "a programmer's text editor";
pub const application_description = application_title ++ ": " ++ application_subtext;

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
    .logFn = log.std_log_function,
};

const crash = @import("crash");

pub const panic = crash.panic;

pub const debug = struct {
    pub const handleSegfault = crash.handle_segfault;
};

pub fn main(init: std.process.Init) anyerror!void {
    global_init = init;
    have_global_init = true;
    const io = init.io;
    const a = init.gpa;

    const console_attached = attach_parent_console();

    if (builtin.os.tag == .linux) {
        // drain stdin so we don't pickup junk from previous application/shell
        _ = std.os.linux.syscall3(.ioctl, @as(usize, @bitCast(@as(isize, std.posix.STDIN_FILENO))), std.os.linux.T.CFLSH, 0);
    }

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
            .log_stdout = "Log to stdout",
            .language = "Force the language of the file to be opened",
            .list_languages = "Show available languages",
            .gui = "Open a GUI window",
            .no_syntax = "Disable syntax highlighting",
            .syntax_report_timing = "Report syntax highlighting time",
            .exec = "Execute a command on startup",
            .literal = "Disable :LINE and +LINE syntax",
            .scratch = "Open a scratch (temporary) buffer on start",
            .new_file = "Create a new untitled file on start",
            .dark = "Use dark color scheme",
            .light = "Use light color scheme",
            .version = "Show build version and exit",
            .class = "Set window class",
        };

        pub const formats = .{ .frame_rate = "num", .trace_level = "num", .exec = "cmds", .class = "name" };

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
        log_stdout: bool,
        language: ?[]const u8,
        list_languages: bool,
        gui: bool,
        no_syntax: bool,
        syntax_report_timing: bool,
        exec: ?[]const u8,
        literal: bool,
        scratch: bool,
        new_file: bool,
        dark: bool,
        light: bool,
        version: bool,
        class: ?[]const u8,

        positional: struct {
            trailing: []const []const u8,
        },
    };

    const args_alloc = try init.minimal.args.toSlice(init.arena.allocator());
    const args = flags.parse(io, init.environ_map, args_alloc, "flow", Flags, .{});

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_file.interface;
    defer stdout.flush() catch {};
    var stderr_buf: [4096]u8 = undefined;
    var stderr_file = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_file.interface;
    defer stderr.flush() catch {};

    if (args.version)
        return stdout.writeAll(version_info);

    if (args.list_languages) {
        const NO_COLOR = if (init.environ_map.get("NO_COLOR")) |v| v.len > 0 else false;
        const CLICOLOR_FORCE = if (init.environ_map.get("CLICOLOR_FORCE")) |v| v.len > 0 else false;
        const tty: std.Io.Terminal = .{
            .writer = stdout,
            .mode = try std.Io.Terminal.Mode.detect(io, std.Io.File.stderr(), NO_COLOR, CLICOLOR_FORCE),
        };
        return list_languages.list(a, tty);
    }

    if (!build_options.gui and args.gui)
        launch_gui();

    if (init.environ_map.get("JITDEBUG")) |_| crash.set_jit_debugger(true);
    crash.set_gui_crash_dialog(build_options.gui and !console_attached);
    crash.install();

    if (args.debug_wait) {
        std.debug.print("press return to start", .{});
        var reader = std.Io.File.stdin().reader(io, &.{});
        var buf: [1]u8 = undefined;
        _ = try reader.interface.readSliceAll(&buf);
    }

    if (c.setlocale(c.LC_ALL, "") == null) {
        try stderr.print("Failed to set locale. Is your locale valid?\n", .{});
        stderr.flush() catch {};
        exit(1);
    }

    thespian.stack_trace_on_errors = args.debug_dump_on_error;

    var ctx = try thespian.context.init(a, .{});
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

    const log_proc = try log.spawn(&ctx, a, env);
    defer log_proc.deinit();
    log.set_std_log_pid(log_proc.ref());
    defer log.set_std_log_pid(null);

    env.set("no-persist", args.no_persist);
    env.set("restore-session", args.restore_session);
    env.set("no-alternate", args.no_alternate);
    env.set("show-input", args.show_input);
    env.set("show-log", args.show_log);
    env.set("log-stdout", args.log_stdout);
    env.set("no-sleep", args.no_sleep);
    env.set("no-syntax", args.no_syntax);
    env.set("syntax-report-timing", args.syntax_report_timing);
    env.set("dump-stack-trace", args.debug_dump_on_error);
    if (args.frame_rate) |s| env.num_set("frame-rate", @intCast(s));
    env.proc_set("log", log_proc.ref());
    if (args.language) |s| env.str_set("language", s);
    if (args.class) |s| env.str_set("window-class", s);

    var eh = thespian.make_exit_handler({}, print_exit_status);
    const tui_proc = try tui.spawn(a, &ctx, &eh, env);
    defer tui_proc.deinit();

    var links: std.ArrayList(file_link.Dest) = .empty;
    defer links.deinit(a);
    var prev: ?*file_link.Dest = null;
    var line_next: ?usize = null;
    var offset_next: ?usize = null;
    for (args.positional.trailing) |arg| {
        if (arg.len == 0) continue;

        if (!args.literal and arg[0] == '+') {
            if (arg.len > 2 and arg[1] == 'b') {
                const offset = try std.fmt.parseInt(usize, arg[2..], 10);
                if (prev) |p| switch (p.*) {
                    .file => |*file| {
                        file.offset = offset;
                        continue;
                    },
                    else => {},
                };
                offset_next = offset;
                line_next = null;
            } else {
                const line = try std.fmt.parseInt(usize, arg[1..], 10);
                if (prev) |p| switch (p.*) {
                    .file => |*file| {
                        file.line = line;
                        continue;
                    },
                    else => {},
                };
                line_next = line;
                offset_next = null;
            }
            continue;
        }

        const curr = try links.addOne(a);
        curr.* = if (!args.literal) try file_link.parse(arg) else .{ .file = .{ .path = arg } };
        prev = curr;

        if (line_next) |line| {
            switch (curr.*) {
                .file => |*file| {
                    file.line = line;
                    line_next = null;
                },
                else => {},
            }
        }
        if (offset_next) |offset| {
            switch (curr.*) {
                .file => |*file| {
                    file.offset = offset;
                    offset_next = null;
                },
                else => {},
            }
        }
    }

    var have_project = false;
    var have_file = false;
    if (args.project) |project| {
        try tui_proc.send(.{ "cmd", "open_project_dir", .{project} });
        have_project = true;
    }
    for (links.items) |link| switch (link) {
        .dir => |dir| {
            if (have_project) {
                std.debug.print("more than one project directory is not allowed\n", .{});
                exit(1);
            }
            try tui_proc.send(.{ "cmd", "open_project_dir", .{dir.path} });
            have_project = true;
        },
        else => {
            have_file = true;
        },
    };

    for (links.items) |link| {
        try file_link.navigate(tui_proc.ref(), &link);
    }

    if (!have_file) {
        if (!have_project)
            try tui_proc.send(.{ "cmd", "open_project_cwd" });
        try tui_proc.send(.{ "cmd", "show_home" });
    }

    if (args.new_file) {
        try tui_proc.send(.{ "cmd", "create_new_file", .{} });
    } else if (args.scratch) {
        try tui_proc.send(.{ "cmd", "create_scratch_buffer", .{} });
    }

    if (args.dark)
        try tui_proc.send(.{ "cmd", "force_color_scheme", .{"dark"} })
    else if (args.light)
        try tui_proc.send(.{ "cmd", "force_color_scheme", .{"light"} });

    if (args.exec) |exec_str| {
        var cmds = std.mem.splitScalar(u8, exec_str, ';');
        while (cmds.next()) |cmd| {
            var count_args_ = std.mem.splitScalar(u8, cmd, ':');
            var count: usize = 0;
            while (count_args_.next()) |_| count += 1;
            if (count == 0) break;

            var msg: std.Io.Writer.Allocating = .init(a);
            defer msg.deinit();
            const writer = &msg.writer;

            var cmd_args = std.mem.splitScalar(u8, cmd, ':');
            const cmd_ = cmd_args.next();
            try cbor.writeArrayHeader(writer, 3);
            try cbor.writeValue(writer, "cmd");
            try cbor.writeValue(writer, cmd_);
            try cbor.writeArrayHeader(writer, count - 1);

            while (cmd_args.next()) |arg| {
                if (std.fmt.parseInt(isize, arg, 10) catch null) |i|
                    try cbor.writeValue(writer, i)
                else
                    try cbor.writeValue(writer, arg);
            }

            try tui_proc.send_raw(.{ .buf = msg.written() });
        }
    }

    ctx.run();

    if (want_restart) if (want_restart_with_sudo) restart_with_sudo() else restart();
    exit(final_exit_status);
}

var final_exit_status: u8 = 0;
var want_restart: bool = false;
var want_restart_with_sudo: bool = false;
var have_global_init = false;
var global_init: std.process.Init = undefined;

pub fn print_exit_status(_: void, msg: []const u8) void {
    if (std.mem.eql(u8, msg, "normal")) {
        return;
    } else if (std.mem.eql(u8, msg, "restart")) {
        want_restart = true;
    } else {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(global_init.io, &stderr_buffer);
        stderr_writer.interface.print("\n" ++ application_name ++ " ERROR: {s}\n", .{msg}) catch {};
        stderr_writer.flush() catch {};
        final_exit_status = 1;
    }
}

pub fn set_restart_with_sudo() void {
    want_restart_with_sudo = true;
}

fn trace(m: thespian.message.c_buffer_type) callconv(.c) void {
    thespian.message.from(m).to_json_cb(trace_json);
}

fn trace_json(json: thespian.message.json_string_view) callconv(.c) void {
    const callstack_depth = 10;
    ___tracy_emit_message(json.base, json.len, callstack_depth);
}
extern fn ___tracy_emit_message(txt: [*]const u8, size: usize, callstack: c_int) void;

var trace_mutex: std.Io.Mutex = .init;

fn trace_to_file(m: thespian.message.c_buffer_type) callconv(.c) void {
    trace_mutex.lockUncancelable(global_init.io);
    defer trace_mutex.unlock(global_init.io);

    const State = struct {
        file: std.Io.File,
        file_writer: std.Io.File.Writer,
        last_time: i64,
        var state: ?@This() = null;
        var trace_buffer: [4096]u8 = undefined;

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
    const a = std.heap.c_allocator;
    var state: *State = &(State.state orelse init: {
        var path: std.Io.Writer.Allocating = .init(a);
        defer path.deinit();
        path.writer.print("{s}{c}trace.log", .{ get_state_dir() catch return, sep }) catch return;
        const file = std.Io.Dir.createFileAbsolute(global_init.io, path.written(), .{}) catch return;
        State.state = .{
            .file = file,
            .file_writer = file.writer(global_init.io, &State.trace_buffer),
            .last_time = get_now().toMicroseconds(),
        };
        break :init State.state.?;
    });
    const writer = &state.file_writer.interface;

    const ts = get_now().toMicroseconds();
    State.write_tdiff(writer, ts - state.last_time) catch {};
    state.last_time = ts;

    var stream: std.json.Stringify = .{ .writer = writer };
    var iter: []const u8 = m.base[0..m.len];
    cbor.JsonWriter.jsonWriteValue(&stream, &iter) catch {};
    _ = writer.write("\n") catch {};
    writer.flush() catch {};
}

pub fn exit(status: u8) noreturn {
    if (builtin.os.tag == .linux) {
        // drain stdin so we don't leave junk at the next prompt
        _ = std.os.linux.syscall3(.ioctl, @as(usize, @bitCast(@as(isize, std.posix.STDIN_FILENO))), std.os.linux.T.CFLSH, 0);
    }
    std.process.exit(status);
}

pub fn free_config(allocator: std.mem.Allocator, bufs: [][]const u8) void {
    for (bufs) |buf| allocator.free(buf);
}

var config_mutex: std.Io.Mutex = .init;

pub fn exists_config(T: type) bool {
    config_mutex.lockUncancelable(global_init.io);
    defer config_mutex.unlock(global_init.io);
    const file_name = get_app_config_file_name(application_name, @typeName(T)) catch return false;
    var file = std.Io.Dir.openFileAbsolute(global_init.io, file_name, .{ .mode = .read_only }) catch return false;
    defer file.close(global_init.io);
    return true;
}

fn get_default(T: type) T {
    return switch (@typeInfo(T)) {
        .array => &.{},
        .pointer => |info| switch (info.size) {
            .slice => &.{},
            else => @compileError("unsupported config type " ++ @typeName(T)),
        },
        else => .{},
    };
}

pub fn read_config(T: type, allocator: std.mem.Allocator) struct { T, [][]const u8 } {
    config_mutex.lockUncancelable(global_init.io);
    defer config_mutex.unlock(global_init.io);
    var bufs: [][]const u8 = &[_][]const u8{};
    const file_name = get_app_config_file_name(application_name, @typeName(T)) catch return .{ get_default(T), bufs };
    var conf: T = get_default(T);
    _ = read_config_file(T, allocator, &conf, &bufs, file_name);
    read_nested_include_files(T, allocator, &conf, &bufs);
    return .{ conf, bufs };
}

// returns true if the file was found
fn read_config_file(T: type, allocator: std.mem.Allocator, conf: *T, bufs: *[][]const u8, file_name: []const u8) bool {
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
    var file = try std.Io.Dir.openFileAbsolute(global_init.io, file_name, .{ .mode = .read_only });
    defer file.close(global_init.io);
    const stat = try file.stat(global_init.io);
    const content = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(content);
    _ = try file.readPositionalAll(global_init.io, content, 0);
    return parse_text_config_file(T, allocator, conf, bufs_, file_name, content);
}

pub fn parse_text_config_file(T: type, allocator: std.mem.Allocator, conf: *T, bufs_: *[][]const u8, file_name: []const u8, content: []const u8) !void {
    var cbor_buf: std.Io.Writer.Allocating = .init(allocator);
    defer cbor_buf.deinit();
    const writer = &cbor_buf.writer;
    var it = std.mem.splitScalar(u8, content, '\n');
    var lineno: u32 = 0;
    while (it.next()) |line| {
        lineno += 1;
        if (line.len == 0 or line[0] == '#')
            continue;
        const spc = std.mem.indexOfScalar(u8, line, ' ') orelse {
            std.log.err("{s}:{}: {s} missing value", .{ file_name, lineno, line });
            continue;
        };
        const name = line[0..spc];
        const value_str = line[spc + 1 ..];
        const cb = cbor.fromJsonAlloc(allocator, value_str) catch {
            std.log.err("{s}:{}: {s} has bad value: {s}", .{ file_name, lineno, name, value_str });
            continue;
        };
        defer allocator.free(cb);
        try cbor.writeValue(writer, name);
        try writer.writeAll(cb);
    }
    const cb = try cbor_buf.toOwnedSlice();
    var bufs = std.ArrayListUnmanaged([]const u8).fromOwnedSlice(bufs_.*);
    bufs.append(allocator, cb) catch @panic("OOM:read_text_config_file");
    bufs_.* = bufs.toOwnedSlice(allocator) catch @panic("OOM:read_text_config_file");
    return read_cbor_config(T, allocator, conf, file_name, cb);
}

fn read_json_config_file(T: type, allocator: std.mem.Allocator, conf: *T, bufs_: *[][]const u8, file_name: []const u8) !void {
    var file = try std.Io.Dir.openFileAbsolute(global_init.io, file_name, .{ .mode = .read_only });
    defer file.close(global_init.io);
    const stat = try file.stat(global_init.io);
    const json = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(json);
    _ = try file.readPositionalAll(global_init.io, json, 0);
    const cbor_buf: []u8 = try allocator.alloc(u8, json.len);
    var bufs = std.ArrayListUnmanaged([]const u8).fromOwnedSlice(bufs_.*);
    bufs.append(allocator, cbor_buf) catch @panic("OOM:read_json_config_file");
    bufs_.* = bufs.toOwnedSlice(allocator) catch @panic("OOM:read_json_config_file");
    const cb = try cbor.fromJson(json, cbor_buf);
    var iter = cb;
    _ = try cbor.decodeMapHeader(&iter);
    return read_cbor_config(T, allocator, conf, file_name, iter);
}

fn read_cbor_config(
    T: type,
    allocator: std.mem.Allocator,
    conf: *T,
    file_name: []const u8,
    cb: []const u8,
) !void {
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
                switch (field_info.type) {
                    u24, ?u24 => {
                        var value: []const u8 = undefined;
                        if (try cbor.matchValue(&iter, cbor.extract(&value))) {
                            const color_ = color.RGB.from_string(value);
                            if (color_) |color__|
                                @field(conf, field_info.name) = color__.to_u24()
                            else
                                std.log.err("invalid value for key '{s}'", .{field_name});
                        } else {
                            try cbor.skipValue(&iter);
                            std.log.err("invalid value for key '{s}'", .{field_name});
                        }
                    },
                    else => {
                        var value: field_info.type = undefined;
                        if (try cbor.matchValue(&iter, cbor.extractAlloc(&value, allocator))) {
                            @field(conf, field_info.name) = value;
                        } else {
                            try cbor.skipValue(&iter);
                            std.log.err("invalid value for key '{s}'", .{field_name});
                        }
                    },
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

pub const ConfigWriteError = error{ CreateConfigFileFailed, WriteConfigFileFailed, WriteFailed };

pub fn write_config(data: anytype, allocator: std.mem.Allocator) (ConfigDirError || ConfigWriteError)!void {
    const T = @TypeOf(data);
    config_mutex.lockUncancelable(global_init.io);
    defer config_mutex.unlock(global_init.io);
    _ = allocator;
    const file_name = try get_app_config_file_name(application_name, @typeName(T));
    var file = std.Io.Dir.createFileAbsolute(global_init.io, file_name, .{}) catch |e| {
        std.log.err("createFileAbsolute failed with {any} for: {s}", .{ e, file_name });
        return error.CreateConfigFileFailed;
    };
    defer file.close(global_init.io);
    var buf: [4096]u8 = undefined;
    var writer = file.writer(global_init.io, &buf);

    try writer.interface.print(
        \\# This file is written by flow when settings are changed interactively. You may
        \\# edit values by hand, but not comments. Comments will be overwritten. Values
        \\# configured to the default value will be automatically commented and possibly
        \\# updated if the default value changes. To store values that cannot be changed
        \\# by flow, put them in a new file and reference it in the include_files
        \\# configuration option at the end of this file. include_files are never
        \\# modified by flow.
        \\
        \\
    , .{});

    write_config_to_writer_internal(T, data, &writer.interface) catch |e| {
        std.log.err("write file failed with {any} for: {s}", .{ e, file_name });
        return error.WriteConfigFileFailed;
    };
    writer.flush() catch return error.WriteFailed;
}

pub fn write_config_to_writer(comptime T: type, data: T, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print(
        \\# This file is generated by flow and updated when opened by an interactive
        \\# command. You may edit values by hand, but not comments. Comments will be
        \\# overwritten. Values configured to the default value will be automatically
        \\# commented and possibly updated if the default value changes. To store
        \\# values that cannot be changed by flow, put them in a new file and reference
        \\# it in the include_files configuration option at the end of this file.
        \\# include_files are never modified by flow.
        \\
        \\
    , .{});
    return write_config_to_writer_internal(T, data, writer);
}

fn write_config_to_writer_internal(comptime T: type, data: T, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const default: T = .{};
    inline for (@typeInfo(T).@"struct".fields) |field_info| {
        var is_default = false;
        if (config_eql(
            T,
            field_info.type,
            @field(data, field_info.name),
            @field(default, field_info.name),
        )) {
            try writer.print("# {s} ", .{field_info.name});
            is_default = true;
        } else {
            try writer.print("{s} ", .{field_info.name});
        }
        try write_config_value(field_info.type, @field(data, field_info.name), writer);
        try writer.print("\n", .{});
        if (!is_default) {
            try writer.print("# default value: ", .{});
            try write_config_value(field_info.type, @field(default, field_info.name), writer);
            try writer.print("\n", .{});
        }
        try writer.print("# value type: ", .{});
        try write_config_value_description(T, field_info.type, field_info.name, writer);
        try writer.print("\n", .{});
        try writer.print("\n", .{});
    }
}

fn write_config_value(T: type, value: T, writer: *std.Io.Writer) !void {
    switch (T) {
        u24 => try write_color_value(value, writer),
        ?u24 => if (value) |v|
            try write_color_value(v, writer)
        else
            try writer.writeAll("null"),
        f32, f64 => try writer.print("{:.2}", .{value}),
        else => {
            var s: std.json.Stringify = .{ .writer = writer, .options = .{ .whitespace = .minified } };
            try s.write(value);
        },
    }
}

fn write_config_value_description(T: type, field_type: type, comptime field_name: []const u8, writer: *std.Io.Writer) !void {
    switch (@typeInfo(field_type)) {
        .int => switch (field_type) {
            u24 => try writer.print("24 bit hex color value in quotes", .{}),
            usize => try writer.print("positive integer", .{}),
            u8 => try writer.print("positive integer up to 255", .{}),
            u16 => try writer.print("positive integer up to {d}", .{std.math.maxInt(u16)}),
            else => unsupported_error(T, field_type),
        },
        .bool => try writer.print("true or false", .{}),
        .float => try writer.print("fractional number", .{}),
        .@"enum" => {
            var first = true;
            try writer.print("one of ", .{});
            for (std.meta.tags(field_type)) |tag| {
                if (first) first = false else try writer.print(", ", .{});
                try writer.print("\"{t}\"", .{tag});
            }
        },
        .optional => |info| switch (@typeInfo(info.child)) {
            else => {
                try write_config_value_description(T, info.child, field_name, writer);
                try writer.print(" or null", .{});
            },
        },
        .pointer => |info| switch (info.size) {
            .slice => if (info.child == u8) {
                if (std.mem.eql(u8, field_name, "include_files"))
                    try writer.print("quoted string of {c} separated paths", .{std.fs.path.delimiter})
                else
                    try writer.print("quoted string", .{});
            } else if (info.child == u16)
                try writer.print("quoted string (u16)", .{})
            else if (info.child == []const u8)
                try writer.print("list of quoted strings", .{})
            else if (info.child == @import("config").IdleAction) {
                try writer.print("list of idle actions (available actions: ", .{});
                var first = true;
                for (std.meta.tags(@import("config").IdleAction)) |tag| {
                    if (first) first = false else try writer.print(", ", .{});
                    try writer.print("\"{t}\"", .{tag});
                }
                try writer.print(")", .{});
            } else unsupported_error(T, info.child),
            else => unsupported_error(T, info.child),
        },
        else => unsupported_error(T, field_type),
    }
}

fn unsupported_error(config_type: type, value_type: type) void {
    @compileError("unsupported config type in " ++ @typeName(config_type) ++ ": " ++ @typeName(value_type));
}

fn write_color_value(value: u24, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var hex: [7]u8 = undefined;
    try writer.writeByte('"');
    try writer.writeAll(color.RGB.to_string(color.RGB.from_u24(value), &hex));
    try writer.writeByte('"');
}

fn config_eql(config_type: type, T: type, a: T, b: T) bool {
    switch (T) {
        []const u8 => return std.mem.eql(u8, a, b),
        []const []const u8 => {
            if (a.len != b.len) return false;
            for (a, 0..) |x, i| if (!config_eql(config_type, []const u8, x, b[i])) return false;
            return true;
        },
        else => {},
    }
    switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum" => return a == b,
        .optional => |info| {
            if (a == null and b == null)
                return true;
            if (a == null or b == null)
                return false;
            return config_eql(config_type, info.child, a.?, b.?);
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                if (a.len != b.len) return false;
                for (a, 0..) |x, i| if (!config_eql(config_type, info.child, x, b[i])) return false;
                return true;
            },
            else => unsupported_error(config_type, T),
        },
        else => {},
    }
    unsupported_error(config_type, T);
}

pub fn read_keybind_namespace(allocator: std.mem.Allocator, namespace_name: []const u8) ?[]const u8 {
    const file_name = get_keybind_namespace_file_name(namespace_name) catch return null;
    var file = std.Io.Dir.openFileAbsolute(global_init.io, file_name, .{ .mode = .read_only }) catch return null;
    defer file.close(global_init.io);
    const stat = file.stat(global_init.io) catch return null;
    const buf = allocator.alloc(u8, @intCast(stat.size)) catch return null;
    const size = file.readPositionalAll(global_init.io, buf, 0) catch {
        allocator.free(buf);
        return null;
    };
    return buf[0..size];
}

pub fn write_keybind_namespace(namespace_name: []const u8, content: []const u8) !void {
    const file_name = try get_keybind_namespace_file_name(namespace_name);
    var file = try std.Io.Dir.createFileAbsolute(global_init.io, file_name, .{});
    defer file.close(global_init.io);
    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(global_init.io, &buf);
    defer file_writer.flush() catch {};
    try file_writer.interface.writeAll(content);
}

pub fn list_keybind_namespaces(allocator: std.mem.Allocator) ![]const []const u8 {
    var dir = try std.Io.Dir.openDirAbsolute(global_init.io, try get_keybind_namespaces_directory(), .{ .iterate = true });
    defer dir.close(global_init.io);
    var result: std.ArrayList([]const u8) = .empty;
    var iter = dir.iterate();
    while (try iter.next(global_init.io)) |entry| {
        switch (entry.kind) {
            .file, .sym_link => try result.append(allocator, try allocator.dupe(u8, std.fs.path.stem(entry.name))),
            else => continue,
        }
    }
    return result.toOwnedSlice(allocator);
}

pub fn read_theme(allocator: std.mem.Allocator, theme_name: []const u8) ?[]const u8 {
    const file_name = get_theme_file_name(theme_name) catch return null;
    var file = std.Io.Dir.openFileAbsolute(global_init.io, file_name, .{ .mode = .read_only }) catch return null;
    defer file.close(global_init.io);
    const stat = file.stat(global_init.io) catch return null;
    const buf = allocator.alloc(u8, @intCast(stat.size)) catch return null;
    const size = file.readPositionalAll(global_init.io, buf, 0) catch |e| {
        std.log.err("Error reading theme file: {t}", .{e});
        allocator.free(buf);
        return null;
    };
    return buf[0..size];
}

pub fn write_theme(theme_name: []const u8, content: []const u8) !void {
    const file_name = try get_theme_file_name(theme_name);
    var file = try std.Io.Dir.createFileAbsolute(global_init.io, file_name, .{});
    defer file.close(global_init.io);
    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(global_init.io, &buf);
    defer file_writer.flush() catch {};
    try file_writer.interface.writeAll(content);
}

pub fn list_themes(allocator: std.mem.Allocator) ![]const []const u8 {
    var dir = try std.Io.Dir.openDirAbsolute(global_init.io, try get_theme_directory(), .{ .iterate = true });
    defer dir.close(global_init.io);
    var result: std.ArrayList([]const u8) = .empty;
    var iter = dir.iterate();
    while (try iter.next(global_init.io)) |entry| {
        switch (entry.kind) {
            .file, .sym_link => try result.append(allocator, try allocator.dupe(u8, std.fs.path.stem(entry.name))),
            else => continue,
        }
    }
    return result.toOwnedSlice(allocator);
}

pub fn get_config_dir() ConfigDirError![]const u8 {
    return get_app_config_dir(application_name);
}

pub const ConfigDirError = error{
    NoSpaceLeft,
    MakeConfigDirFailed,
    MakeHomeConfigDirFailed,
    MakeAppConfigDirFailed,
    AppConfigDirUnavailable,
};

fn make_dir_error(path: []const u8, err: anytype) @TypeOf(err) {
    std.log.err("failed to create directory: '{s}'", .{path});
    return err;
}

fn get_app_config_dir(appname: []const u8) ConfigDirError![]const u8 {
    const local = struct {
        var config_dir_buffer: [std.posix.PATH_MAX]u8 = undefined;
        var config_dir: ?[]const u8 = null;
    };
    const io = get_io();
    const environ = get_init().environ_map;
    const config_dir = if (local.config_dir) |dir|
        dir
    else if (environ.get("FLOW_CONFIG_DIR")) |dir| ret: {
        break :ret try std.fmt.bufPrint(&local.config_dir_buffer, "{s}", .{dir});
    } else if (environ.get("XDG_CONFIG_HOME")) |xdg| ret: {
        break :ret try std.fmt.bufPrint(&local.config_dir_buffer, "{s}{c}{s}", .{ xdg, sep, appname });
    } else if (environ.get("HOME")) |home| ret: {
        const dir = try std.fmt.bufPrint(&local.config_dir_buffer, "{s}{c}.config", .{ home, sep });
        std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return make_dir_error(dir, error.MakeHomeConfigDirFailed),
        };
        break :ret try std.fmt.bufPrint(&local.config_dir_buffer, "{s}{c}.config{c}{s}", .{ home, sep, sep, appname });
    } else if (builtin.os.tag == .windows) ret: {
        if (environ.get("APPDATA")) |appdata| {
            const dir = try std.fmt.bufPrint(&local.config_dir_buffer, "{s}{c}{s}", .{ appdata, sep, appname });
            std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return make_dir_error(dir, error.MakeAppConfigDirFailed),
            };
            break :ret dir;
        } else return error.AppConfigDirUnavailable;
    } else return error.AppConfigDirUnavailable;

    local.config_dir = config_dir;
    std.Io.Dir.createDirAbsolute(io, config_dir, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return make_dir_error(config_dir, error.MakeConfigDirFailed),
    };

    var keybind_dir_buffer: [std.posix.PATH_MAX]u8 = undefined;
    std.Io.Dir.createDirAbsolute(io, try std.fmt.bufPrint(&keybind_dir_buffer, "{s}{c}{s}", .{ config_dir, sep, keybind_dir }), .default_dir) catch {};

    var theme_dir_buffer: [std.posix.PATH_MAX]u8 = undefined;
    std.Io.Dir.createDirAbsolute(io, try std.fmt.bufPrint(&theme_dir_buffer, "{s}{c}{s}", .{ config_dir, sep, theme_dir }), .default_dir) catch {};

    return config_dir;
}

pub fn get_cache_dir() ![]const u8 {
    return get_app_cache_dir(application_name);
}

fn get_app_cache_dir(appname: []const u8) ![]const u8 {
    const local = struct {
        var cache_dir_buffer: [std.posix.PATH_MAX]u8 = undefined;
        var cache_dir: ?[]const u8 = null;
    };
    const io = get_io();
    const environ = get_init().environ_map;
    const cache_dir = if (local.cache_dir) |dir|
        dir
    else if (environ.get("XDG_CACHE_HOME")) |xdg| ret: {
        break :ret try std.fmt.bufPrint(&local.cache_dir_buffer, "{s}{c}{s}", .{ xdg, sep, appname });
    } else if (environ.get("HOME")) |home| ret: {
        const dir = try std.fmt.bufPrint(&local.cache_dir_buffer, "{s}{c}.cache", .{ home, sep });
        std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return make_dir_error(dir, e),
        };
        break :ret try std.fmt.bufPrint(&local.cache_dir_buffer, "{s}{c}.cache{c}{s}", .{ home, sep, sep, appname });
    } else if (builtin.os.tag == .windows) ret: {
        if (environ.get("APPDATA")) |appdata| {
            const dir = try std.fmt.bufPrint(&local.cache_dir_buffer, "{s}{c}{s}", .{ appdata, sep, appname });
            std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return make_dir_error(dir, e),
            };
            break :ret dir;
        } else return error.AppCacheDirUnavailable;
    } else return error.AppCacheDirUnavailable;

    local.cache_dir = cache_dir;
    std.Io.Dir.createDirAbsolute(io, cache_dir, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return make_dir_error(cache_dir, e),
    };
    return cache_dir;
}

pub fn get_init() std.process.Init {
    if (!have_global_init) @panic("pre-init io call");
    return global_init;
}

pub fn get_io() std.Io {
    return get_init().io;
}

pub fn get_now() std.Io.Timestamp {
    return std.Io.Clock.real.now(get_io());
}

pub fn get_state_dir() ![]const u8 {
    return get_app_state_dir(application_name);
}

fn get_app_state_dir(appname: []const u8) ![]const u8 {
    const local = struct {
        var state_dir_buffer: [std.posix.PATH_MAX]u8 = undefined;
        var state_dir: ?[]const u8 = null;
    };
    const io = get_io();
    const environ = get_init().environ_map;
    const state_dir = if (local.state_dir) |dir|
        dir
    else if (environ.get("XDG_STATE_HOME")) |xdg| ret: {
        break :ret try std.fmt.bufPrint(&local.state_dir_buffer, "{s}{c}{s}", .{ xdg, sep, appname });
    } else if (environ.get("HOME")) |home| ret: {
        var dir = try std.fmt.bufPrint(&local.state_dir_buffer, "{s}{c}.local", .{ home, sep });
        std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return make_dir_error(dir, e),
        };
        dir = try std.fmt.bufPrint(&local.state_dir_buffer, "{s}{c}.local{c}state", .{ home, sep, sep });
        std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return make_dir_error(dir, e),
        };
        break :ret try std.fmt.bufPrint(&local.state_dir_buffer, "{s}{c}.local{c}state{c}{s}", .{ home, sep, sep, sep, appname });
    } else if (builtin.os.tag == .windows) ret: {
        if (environ.get("APPDATA")) |appdata| {
            const dir = try std.fmt.bufPrint(&local.state_dir_buffer, "{s}{c}{s}", .{ appdata, sep, appname });
            std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return make_dir_error(dir, e),
            };
            break :ret dir;
        } else return error.AppCacheDirUnavailable;
    } else return error.AppCacheDirUnavailable;

    local.state_dir = state_dir;
    std.Io.Dir.createDirAbsolute(io, state_dir, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return make_dir_error(state_dir, e),
    };
    return state_dir;
}

fn get_app_config_file_name(appname: []const u8, comptime base_name: []const u8) ConfigDirError![]const u8 {
    return get_app_config_dir_file_name(appname, base_name);
}

fn get_app_config_dir_file_name(appname: []const u8, comptime config_file_name: []const u8) ConfigDirError![]const u8 {
    const local = struct {
        var config_file_buffer: [std.posix.PATH_MAX]u8 = undefined;
    };
    return std.fmt.bufPrint(&local.config_file_buffer, "{s}{c}{s}", .{ try get_app_config_dir(appname), sep, config_file_name });
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
        try std.fmt.bufPrint(&local.restore_file_buffer, "{s}{c}{s}", .{ try get_app_state_dir(application_name), sep, restore_file_name });
    local.restore_file = restore_file;
    return restore_file;
}

const keybind_dir = "keys";

fn get_keybind_namespaces_directory() ![]const u8 {
    const local = struct {
        var dir_buffer: [std.posix.PATH_MAX]u8 = undefined;
    };
    if (get_init().environ_map.get("FLOW_KEYS_DIR")) |dir| {
        return try std.fmt.bufPrint(&local.dir_buffer, "{s}", .{dir});
    }
    return try std.fmt.bufPrint(&local.dir_buffer, "{s}{c}{s}", .{ try get_app_config_dir(application_name), sep, keybind_dir });
}

pub fn get_keybind_namespace_file_name(namespace_name: []const u8) ![]const u8 {
    const dir = try get_keybind_namespaces_directory();
    const local = struct {
        var file_buffer: [std.posix.PATH_MAX]u8 = undefined;
    };
    return try std.fmt.bufPrint(&local.file_buffer, "{s}{c}{s}.json", .{ dir, sep, namespace_name });
}

const theme_dir = "themes";

fn get_theme_directory() ![]const u8 {
    const local = struct {
        var dir_buffer: [std.posix.PATH_MAX]u8 = undefined;
    };
    if (get_init().environ_map.get("FLOW_THEMES_DIR")) |dir| {
        return try std.fmt.bufPrint(&local.dir_buffer, "{s}", .{dir});
    }
    return try std.fmt.bufPrint(&local.dir_buffer, "{s}{c}{s}", .{ try get_app_config_dir(application_name), sep, theme_dir });
}

pub fn get_theme_file_name(theme_name: []const u8) ![]const u8 {
    const dir = try get_theme_directory();
    const local = struct {
        var file_buffer: [std.posix.PATH_MAX]u8 = undefined;
    };
    return try std.fmt.bufPrint(&local.file_buffer, "{s}{c}{s}.json", .{ dir, sep, theme_name });
}

fn resolve_executable(executable: [:0]const u8) [:0]const u8 {
    return bin_path.resolve_executable(get_init().gpa, executable);
}

fn current_argv0() [:0]const u8 {
    if (builtin.os.tag == .windows) {
        var iter = std.process.Args.Iterator.initAllocator(get_init().minimal.args, std.heap.c_allocator) catch return "flow";
        return iter.next() orelse "flow";
    }
    return std.mem.span(get_init().minimal.args.vector[0]);
}

fn flow_gui_executable(gpa: std.mem.Allocator) ?[:0]const u8 {
    const name = if (builtin.os.tag == .windows) "flow-gui.exe" else "flow-gui";
    // prefer flow-gui in the same path as flow, fall back to PATH
    const self = resolve_executable(current_argv0());
    if (std.fs.path.dirname(self)) |dir| {
        const candidate = std.fs.path.joinZ(gpa, &.{ dir, name }) catch @panic("OOM");
        if (bin_path.can_execute(gpa, candidate)) return candidate;
        gpa.free(candidate);
    }
    if (bin_path.can_execute(gpa, "flow-gui")) return resolve_executable("flow-gui");
    return null;
}

fn launch_gui() noreturn {
    const gpa = get_init().gpa;
    const flow_gui = flow_gui_executable(gpa) orelse
        fatal("flow-gui not found. Is the GUI build installed and in your PATH?", .{});
    if (builtin.os.tag == .windows) return launch_gui_win32(flow_gui, gpa);

    const vector = get_init().minimal.args.vector;
    const argv = gpa.allocSentinel(?[*:0]const u8, vector.len, null) catch @panic("OOM");
    argv[0] = flow_gui.ptr;
    for (1..vector.len) |i| argv[i] = vector[i];
    const ret = std.c.execve(flow_gui, @ptrCast(argv.ptr), @ptrCast(get_init().minimal.environ.block.slice.ptr));
    fatal("failed to execute {s}: E{t}", .{ flow_gui, std.posix.errno(ret) });
}

fn launch_gui_win32(flow_gui: [:0]const u8, gpa: std.mem.Allocator) noreturn {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(gpa, flow_gui) catch @panic("OOM");
    var iter = std.process.Args.Iterator.initAllocator(get_init().minimal.args, gpa) catch |e|
        fatal("failed to read arguments: {s}", .{@errorName(e)});
    _ = iter.next(); // skip argv0
    while (iter.next()) |arg| argv.append(gpa, arg) catch @panic("OOM");

    var child = std.process.spawn(get_io(), .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |e| fatal("failed to launch {s}: {s}", .{ flow_gui, @errorName(e) });
    const term = child.wait(get_io()) catch |e| fatal("failed to wait for {s}: {s}", .{ flow_gui, @errorName(e) });
    switch (term) {
        .exited => |code| exit(code),
        else => exit(1),
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writer(get_init().io, &buf);
    w.interface.print(fmt ++ "\n", args) catch {};
    w.flush() catch {};
    exit(1);
}

fn restart() noreturn {
    if (builtin.os.tag == .windows) return restart_win32();
    const executable = resolve_executable(std.mem.span(get_init().minimal.args.vector[0]));
    const argv = [_]?[*:0]const u8{
        executable,
        "--restore-session",
        null,
    };
    const ret = std.c.execve(executable, @ptrCast(&argv), @ptrCast(get_init().minimal.environ.block.slice.ptr));
    restart_failed(ret);
}

fn restart_with_sudo() noreturn {
    if (builtin.os.tag == .windows) return restart_win32();
    const sudo_executable = resolve_executable("sudo");
    const flow_executable = resolve_executable(std.mem.span(get_init().minimal.args.vector[0]));
    const argv = [_]?[*:0]const u8{
        sudo_executable,
        "--preserve-env",
        flow_executable,
        "--restore-session",
        null,
    };
    const ret = std.c.execve(sudo_executable, @ptrCast(&argv), @ptrCast(get_init().minimal.environ.block.slice.ptr));
    restart_failed(ret);
}

fn restart_win32() noreturn {
    const argv0 = blk: {
        const a = std.heap.c_allocator;
        var iter = std.process.Args.Iterator.initAllocator(get_init().minimal.args, a) catch break :blk "flow";
        break :blk iter.next() orelse "flow";
    };

    if (!build_options.gui) return restart_manual();
    const executable = resolve_executable(argv0);
    const argv = [_][]const u8{
        executable,
        "--restore-session",
    };
    _ = std.process.spawn(get_io(), .{
        .argv = &argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch {
        std.os.windows.ntdll.RtlExitUserProcess(1);
    };
    std.os.windows.ntdll.RtlExitUserProcess(0);
}

/// Returns true if a parent console was adopted
fn attach_parent_console() bool {
    if (builtin.os.tag == .windows) return attach_parent_console_win32();
    return false;
}

fn attach_parent_console_win32() bool {
    const w = std.os.windows;
    const ATTACH_PARENT_PROCESS: w.DWORD = 0xFFFFFFFF;
    const CP_UTF8: w.DWORD = 65001;
    if (!win32.AttachConsole(ATTACH_PARENT_PROCESS).toBool()) return false; // no parent console

    // Point any std stream that isn't already redirected at the console.
    const STD_INPUT_HANDLE: w.DWORD = 0xFFFFFFF6; // -10
    const STD_OUTPUT_HANDLE: w.DWORD = 0xFFFFFFF5; // -11
    const STD_ERROR_HANDLE: w.DWORD = 0xFFFFFFF4; // -12
    reopen_std_handle_win32(STD_OUTPUT_HANDLE, std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$"));
    reopen_std_handle_win32(STD_ERROR_HANDLE, std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$"));
    reopen_std_handle_win32(STD_INPUT_HANDLE, std.unicode.utf8ToUtf16LeStringLiteral("CONIN$"));
    _ = win32.SetConsoleOutputCP(CP_UTF8);
    return true;
}

fn reopen_std_handle_win32(which: std.os.windows.DWORD, name: [*:0]const u16) void {
    const w = std.os.windows;
    const FILE_TYPE_DISK: w.DWORD = 0x0001;
    const FILE_TYPE_CHAR: w.DWORD = 0x0002;
    const FILE_TYPE_PIPE: w.DWORD = 0x0003;
    const GENERIC_READ: w.DWORD = 0x80000000;
    const GENERIC_WRITE: w.DWORD = 0x40000000;
    const FILE_SHARE_READ: w.DWORD = 0x0001;
    const FILE_SHARE_WRITE: w.DWORD = 0x0002;
    const OPEN_EXISTING: w.DWORD = 3;

    // Leave a stream that is already connected to something alone.
    if (win32.GetStdHandle(which)) |cur| {
        if (cur != w.INVALID_HANDLE_VALUE) switch (win32.GetFileType(cur)) {
            FILE_TYPE_DISK, FILE_TYPE_PIPE, FILE_TYPE_CHAR => return,
            else => {},
        };
    }
    const h = win32.CreateFileW(name, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
    if (h == w.INVALID_HANDLE_VALUE) return;
    _ = win32.SetStdHandle(which, h);
}

const win32 = struct {
    const w = std.os.windows;
    extern "kernel32" fn AttachConsole(dwProcessId: w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn GetStdHandle(nStdHandle: w.DWORD) callconv(.winapi) ?w.HANDLE;
    extern "kernel32" fn SetStdHandle(nStdHandle: w.DWORD, hHandle: w.HANDLE) callconv(.winapi) w.BOOL;
    extern "kernel32" fn GetFileType(hFile: w.HANDLE) callconv(.winapi) w.DWORD;
    extern "kernel32" fn CreateFileW(lpFileName: w.LPCWSTR, dwDesiredAccess: w.DWORD, dwShareMode: w.DWORD, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: w.DWORD, dwFlagsAndAttributes: w.DWORD, hTemplateFile: ?w.HANDLE) callconv(.winapi) w.HANDLE;
    extern "kernel32" fn SetConsoleOutputCP(wCodePageID: w.DWORD) callconv(.winapi) w.BOOL;
};

fn restart_manual() noreturn {
    const argv0 =
        if (builtin.os.tag == .windows) blk: {
            const a = std.heap.c_allocator;
            var iter = std.process.Args.Iterator.initAllocator(get_init().minimal.args, a) catch break :blk "flow";
            break :blk iter.next() orelse "flow";
        } else std.mem.span(get_init().minimal.args.vector[0]);
    const executable = resolve_executable(argv0);

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global_init.io, &stderr_buffer);
    stderr_writer.interface.print(
        \\
        \\ Manual restart required. Run:
        \\ > {s} --restore-session
        \\ to restart now.
        \\
        \\
    , .{executable}) catch {};
    stderr_writer.flush() catch {};
    exit(234);
}

fn restart_failed(ret: c_int) noreturn {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global_init.io, &stderr_buffer);
    stderr_writer.interface.print("\nRestart failed: E{t}\n", .{std.posix.errno(ret)}) catch {};
    stderr_writer.interface.print(
        \\
        \\ To restart manually run:
        \\ > {s} --restore-session
        \\
        \\
    , .{resolve_executable(std.mem.span(get_init().minimal.args.vector[0]))}) catch {};
    stderr_writer.flush() catch {};
    exit(234);
}

pub fn is_directory(rel_path: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.cwd().realPathFile(global_init.io, rel_path, &path_buf) catch return false;
    const abs_path = path_buf[0..len];
    var dir = std.Io.Dir.openDirAbsolute(global_init.io, abs_path, .{}) catch return false;
    dir.close(global_init.io);
    return true;
}

pub fn is_file(rel_path: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.cwd().realPathFile(global_init.io, rel_path, &path_buf) catch return false;
    const abs_path = path_buf[0..len];
    var file = std.Io.Dir.openFileAbsolute(global_init.io, abs_path, .{ .mode = .read_only }) catch return false;
    defer file.close(global_init.io);
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
