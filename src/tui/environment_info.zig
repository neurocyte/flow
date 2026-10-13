const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const tp = @import("thespian");
const root = @import("soft_root").root;
const file_watcher = @import("file_watcher");
const cbor = @import("cbor");
const project_manager = @import("project_manager");

const tui = @import("tui.zig");

const Platform = enum { all, posix, windows };

const Variable = struct { []const u8, Platform };

const variables = [_]Variable{
    .{ "XDG_CONFIG_HOME", .all },
    .{ "XDG_CACHE_HOME", .all },
    .{ "XDG_STATE_HOME", .all },
    .{ "XDG_RUNTIME_DIR", .all },
    .{ "XDG_DATA_HOME", .posix },
    .{ "HOME", .all },
    .{ "USERPROFILE", .windows },
    .{ "APPDATA", .windows },
    .{ "LOCALAPPDATA", .windows },
    .{ "PATH", .all },
    .{ "PATHEXT", .windows },
    .{ "SHELL", .posix },
    .{ "COMSPEC", .windows },
    .{ "HOSTNAME", .posix },
    .{ "XDG_SESSION_TYPE", .posix },
    .{ "XDG_CURRENT_DESKTOP", .posix },
    .{ "WAYLAND_DISPLAY", .posix },
    .{ "DISPLAY", .posix },
    .{ "XAUTHORITY", .posix },
    .{ "DBUS_SESSION_BUS_ADDRESS", .posix },
};

pub fn write(allocator: std.mem.Allocator, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try write_system(writer);
    try write_runtime(allocator, writer);
    try write_configuration(allocator, writer);
    try write_language_servers(allocator, writer);
    try writer.writeAll("\nconfig files:\n\n");
    try root.write_loaded_files_to_writer(writer);
    try write_environment(writer);
}

fn write_system(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("\nsystem:\n\n");
    if (builtin.os.tag == .windows) {
        var info: std.os.windows.RTL_OSVERSIONINFOW = undefined;
        info.dwOSVersionInfoSize = @sizeOf(@TypeOf(info));
        _ = std.os.windows.ntdll.RtlGetVersion(&info);
        try writer.print("os: Windows {d}.{d}.{d}\n", .{ info.dwMajorVersion, info.dwMinorVersion, info.dwBuildNumber });
        return;
    }
    const uts = std.posix.uname();
    try writer.print("os: {s} {s} {s} {s}\n", .{
        std.mem.sliceTo(&uts.sysname, 0),
        std.mem.sliceTo(&uts.release, 0),
        std.mem.sliceTo(&uts.version, 0),
        std.mem.sliceTo(&uts.machine, 0),
    });
    var buffer: [16 * 1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    const os_release = for ([_][]const u8{ "/etc/os-release", "/usr/lib/os-release" }) |path| {
        break std.Io.Dir.cwd().readFileAlloc(root.get_io(), path, fba.allocator(), .unlimited) catch continue;
    } else return;
    var lines = std.mem.tokenizeScalar(u8, os_release, '\n');
    while (lines.next()) |line| {
        const key = "PRETTY_NAME=";
        if (!std.mem.startsWith(u8, line, key)) continue;
        try writer.print("distribution: {s}\n", .{std.mem.trim(u8, line[key.len..], "\"'")});
        return;
    }
}

fn write_language_servers(allocator: std.mem.Allocator, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("\nlanguage servers:\n\n");
    const rsp = project_manager.request_language_servers(allocator) catch |e|
        return writer.print("({t})\n", .{e});
    defer allocator.free(rsp.buf);
    var iter = rsp.buf;
    var count = cbor.decodeArrayHeader(&iter) catch return;
    if (count == 0) return writer.writeAll("(none)\n");
    while (count > 0) : (count -= 1) {
        var project: []const u8 = undefined;
        _ = cbor.decodeArrayHeader(&iter) catch return;
        if (!(cbor.matchString(&iter, &project) catch return)) return;
        var resolved: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &resolved) catch return)) return;
        var name: []const u8 = undefined;
        var version: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &name) catch return)) return;
        if (!(cbor.matchString(&iter, &version) catch return)) return;
        var args = cbor.decodeArrayHeader(&iter) catch return;
        while (args > 0) : (args -= 1) {
            var arg: []const u8 = undefined;
            if (!(cbor.matchString(&iter, &arg) catch return)) return;
            try writer.print("{s} ", .{arg});
        }
        try writer.print("-> {s} ", .{if (resolved.len > 0) resolved else "(not found in PATH)"});
        if (name.len > 0 or version.len > 0)
            try writer.print("[{s}{s}{s}] ", .{ name, if (name.len > 0 and version.len > 0) " " else "", version });
        try writer.print("({s})\n", .{project});
    }
}

fn write_configuration(allocator: std.mem.Allocator, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("\nconfiguration:\n\n");
    try root.write_non_default_config_to_writer(@import("config"), tui.config().*, writer);
    if (!build_options.gui) return;
    const gui_config = @import("gui_config");
    const conf, const bufs = root.read_config(gui_config, allocator);
    defer root.free_config(allocator, bufs);
    try writer.writeAll("\ngui configuration:\n\n");
    try root.write_non_default_config_to_writer(gui_config, conf, writer);
}

fn write_arguments(allocator: std.mem.Allocator, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var iter = std.process.Args.Iterator.initAllocator(root.get_init().minimal.args, allocator) catch return;
    defer iter.deinit();
    try writer.writeAll("arguments:");
    _ = iter.next();
    while (iter.next()) |arg|
        if (arg.len == 0 or std.mem.indexOfAny(u8, arg, " \t\"'") != null)
            try writer.print(" \"{f}\"", .{std.zig.fmtString(arg)})
        else
            try writer.print(" {s}", .{arg});
    try writer.writeAll("\n");
}

fn write_runtime(allocator: std.mem.Allocator, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const conf = tui.config();
    const screen = tui.screen();
    try writer.writeAll("\nruntime:\n\n");
    if (std.process.executablePath(root.get_io(), &buffer)) |len|
        try writer.print("executable: {s}\n", .{buffer[0..len]})
    else |e|
        try writer.print("executable: ({t})\n", .{e});
    try write_arguments(allocator, writer);
    try writer.print("pid: {d}\n", .{root.get_pid()});
    try writer.print("project: {s}\n", .{tp.env.get().str("project")});
    try write_dir(writer, "state-dir", root.get_state_dir());
    try write_dir(writer, "cache-dir", root.get_cache_dir());
    try writer.print("screen: {d}x{d} cells\n", .{ screen.w, screen.h });
    try writer.print("frame-rate: {d}\n", .{tp.env.get().num("frame-rate")});
    try writer.print("theme: {s} ({t})\n", .{ tui.theme().name, tui.active_color_scheme() });
    try writer.print("input-mode: {s}\n", .{conf.input_mode});
    try writer.print("file-watcher: {s}{s}\n", .{ file_watcher.backend_name, if (conf.enable_file_watcher) "" else " (disabled)" });
    try tui.rdr().write_runtime_info(writer);
}

fn write_dir(writer: *std.Io.Writer, name: []const u8, dir: anyerror![]const u8) std.Io.Writer.Error!void {
    if (dir) |value|
        try writer.print("{s}: {s}\n", .{ name, value })
    else |e|
        try writer.print("{s}: ({t})\n", .{ name, e });
}

fn write_environment(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const environ = root.get_init().environ_map;
    var buffer: [std.posix.PATH_MAX]u8 = undefined;
    try writer.writeAll("\nenvironment:\n\n");
    try write_effective(writer, "FLOW_CONFIG_DIR", root.get_config_dir() catch null);
    try write_effective(writer, "FLOW_KEYS_DIR", root.get_keybind_namespaces_directory(&buffer) catch null);
    try write_effective(writer, "FLOW_THEMES_DIR", root.get_theme_directory(&buffer) catch null);
    for (variables) |variable| {
        const name, const platform = variable;
        switch (platform) {
            .all => {},
            .posix => if (builtin.os.tag == .windows) continue,
            .windows => if (builtin.os.tag != .windows) continue,
        }
        if (environ.get(name)) |value|
            try writer.print("{s}: {s}\n", .{ name, value })
        else
            try writer.print("{s}: (not set)\n", .{name});
    }
}

fn write_effective(writer: *std.Io.Writer, name: []const u8, effective: ?[]const u8) std.Io.Writer.Error!void {
    if (root.get_init().environ_map.get(name)) |value|
        try writer.print("{s}: {s}\n", .{ name, value })
    else if (effective) |value|
        try writer.print("{s}: {s} (default)\n", .{ name, value })
    else
        try writer.print("{s}: (unavailable)\n", .{name});
}
