const std = @import("std");
const builtin = @import("builtin");
const tp = @import("thespian");
const cbor = @import("cbor");
const root = @import("soft_root").root;
const fetch = @import("fetch");
const ConPTY = @import("Terminal").ConPTY;

const tui = @import("tui.zig");

const log = std.log.scoped(.conpty);
const is_windows = builtin.os.tag == .windows;

const dialog_message =
    \\Download ConPTY from nuget.org for better clipboard support in
    \\terminal apps (1.7 MB)?
;

var running = false;
var not_now = false;

pub fn allow_new_terminal() bool {
    if (!is_windows) return true;
    if (ConPTY.is_loaded() or not_now or !tui.config().conpty_download_ask) return true;
    if (ConPTY.bundled_available(root.get_init().gpa, root.get_io())) return true;
    if (running) {
        tui.message("the ConPTY download is still running", .{});
        return false;
    }
    ask() catch |e| {
        log.err("download dialog failed: {t}", .{e});
        return true;
    };
    return false;
}

fn ask() !void {
    var start_buf: [64]u8 = undefined;
    var decline_buf: [64]u8 = undefined;
    var postpone_buf: [64]u8 = undefined;
    return tui.open_confirm(.{
        .message = dialog_message,
        .choices = &.{
            .{
                .label = "Download",
                .action = .{ .bytes = cbor.fmt(&start_buf, .{ "cmd", "conpty_download", .{Action.start} }) },
            },
            .{
                .label = "Use ConPTY included in Windows",
                .action = .{ .bytes = cbor.fmt(&decline_buf, .{ "cmd", "conpty_download", .{Action.decline} }) },
            },
        },
        .cancel_label = "Not now",
        .on_cancel = .{ .bytes = cbor.fmt(&postpone_buf, .{ "cmd", "conpty_download", .{Action.postpone} }) },
    });
}

pub const Action = enum { start, decline, postpone };

pub fn run(action: Action) !void {
    if (!is_windows) return;
    switch (action) {
        .start => try start(),
        .decline => try decline(),
        .postpone => postpone(),
    }
}

fn start() !void {
    if (running) return;
    const parent = tp.self_pid().clone();
    errdefer parent.deinit();
    const pid = try tp.spawn_link(root.get_init().gpa, parent, Download.start, "conpty_download");
    pid.deinit();
    running = true;
    tui.message("downloading the ConPTY...", .{});
}

fn decline() !void {
    tui.config_mut().conpty_download_ask = false;
    try tui.save_config();
    tui.message("open the terminal again to use the built-in ConPTY", .{});
}

fn postpone() void {
    not_now = true;
    tui.message("open the terminal again to use the built-in ConPTY", .{});
}

pub fn receive(m: tp.message) !void {
    running = false;
    var err: []const u8 = undefined;
    if (try m.match(.{ "conpty_download", "done" }))
        return tui.message("the ConPTY is ready, open the terminal again", .{});
    if (try m.match(.{ "conpty_download", "failed", tp.extract(&err) }))
        return log.err("ConPTY download failed: {s}", .{err});
}

const Download = struct {
    fn start(parent: tp.pid) tp.result {
        defer parent.deinit();
        if (fetch_package()) |_|
            parent.send(.{ "conpty_download", "done" }) catch {}
        else |e|
            parent.send(.{ "conpty_download", "failed", @errorName(e) }) catch {};
        return tp.exit_normal();
    }

    fn fetch_package() !void {
        const allocator = root.get_init().gpa;
        const io = root.get_io();
        const dir_path = try ConPTY.download_dir(allocator);
        defer allocator.free(dir_path);
        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
        defer dir.close(io);
        const package = ConPTY.package;
        try fetch.fetch_zip(io, allocator, package.url, package.sha256, dir, &.{
            .{ .archive_path = package.dll_entry, .dest_filename = "conpty.dll" },
            .{ .archive_path = package.console_entry, .dest_filename = "OpenConsole.exe" },
        });
    }
};
