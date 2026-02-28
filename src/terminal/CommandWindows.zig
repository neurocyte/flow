//! Windows process spawn/wait/kill using ConPTY.
//! Mirrors the Command.zig interface so Terminal.zig can use it uniformly.
const CommandWindows = @This();

const std = @import("std");
const windows = std.os.windows;
const posix = std.posix;
const ConPTY = @import("ConPTY.zig");

// STARTUPINFOEXW - not in Zig stdlib yet, declared manually.
// Must use this instead of STARTUPINFOW when attaching a pseudo-console.
const STARTUPINFOEXW = extern struct {
    StartupInfo: windows.STARTUPINFOW,
    lpAttributeList: windows.LPVOID,
};

argv: []const []const u8,
working_directory: ?[]const u8,
env_map: *const std.process.EnvMap,

// Set after spawn()
process_handle: ?windows.HANDLE = null,
thread_handle: ?windows.HANDLE = null,

pub fn spawn(self: *CommandWindows, allocator: std.mem.Allocator, conpty: *ConPTY) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Build wide command line
    const cmd_line_w = try buildCommandLine(a, self.argv);

    // Build wide environment block
    const env_block = try std.process.createWindowsEnvBlock(a, self.env_map);

    // Build wide working directory (if set)
    const cwd_w: ?[:0]u16 = if (self.working_directory) |cwd|
        try std.unicode.wtf8ToWtf16LeAllocZ(a, cwd)
    else
        null;

    var si_ex = std.mem.zeroes(STARTUPINFOEXW);
    si_ex.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
    si_ex.lpAttributeList = conpty.attrList();

    var pi: windows.PROCESS_INFORMATION = undefined;

    // EXTENDED_STARTUPINFO_PRESENT = 0x00080000
    // CREATE_UNICODE_ENVIRONMENT   = 0x00000400
    const flags: windows.DWORD = 0x00080000 | 0x00000400;

    const ok = windows.kernel32.CreateProcessW(
        null,
        cmd_line_w.ptr,
        null,
        null,
        windows.FALSE, // don't inherit handles - ConPTY manages that
        @bitCast(flags),
        @as(?*anyopaque, @ptrCast(env_block.ptr)),
        if (cwd_w) |c| c.ptr else null,
        @ptrCast(&si_ex.StartupInfo),
        &pi,
    );
    if (ok == windows.FALSE) {
        switch (windows.kernel32.GetLastError()) {
            else => |err| return windows.unexpectedError(err),
        }
    }

    self.process_handle = pi.hProcess;
    self.thread_handle = pi.hThread;

    // Close the child-side pipe ends now that the process is running.
    conpty.closChildSidePipes();
}

pub fn kill(self: *CommandWindows) void {
    if (self.process_handle) |h|
        windows.TerminateProcess(h, 1) catch {};
}

/// Non-blocking check: returns exit code if the process has exited, null if still running.
pub fn try_wait(self: *CommandWindows) ?u8 {
    const h = self.process_handle orelse return null;
    // WaitForSingleObjectEx with timeout=0: returns error.WaitTimeOut if still running.
    windows.WaitForSingleObjectEx(h, 0, false) catch return null;
    return self.reap();
}

/// Blocking wait: reap the process and return its exit code.
pub fn wait(self: *CommandWindows) u8 {
    const h = self.process_handle orelse return 0;
    windows.WaitForSingleObjectEx(h, windows.INFINITE, false) catch {};
    return self.reap();
}

fn reap(self: *CommandWindows) u8 {
    const h = self.process_handle orelse return 0;
    var exit_code: windows.DWORD = 0;
    _ = windows.kernel32.GetExitCodeProcess(h, &exit_code);
    windows.CloseHandle(h);
    if (self.thread_handle) |th| windows.CloseHandle(th);
    self.process_handle = null;
    self.thread_handle = null;
    return @truncate(exit_code);
}

/// Build a properly quoted Windows command line from an argv slice.
fn buildCommandLine(allocator: std.mem.Allocator, argv: []const []const u8) ![:0]u16 {
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    for (argv, 0..) |arg, i| {
        if (i != 0) try buf.append(' ');

        // Quote if contains spaces, tabs, or is empty
        const needs_quotes = arg.len == 0 or
            std.mem.indexOfAny(u8, arg, " \t\"") != null;

        if (needs_quotes) {
            try buf.append('"');
            var j: usize = 0;
            while (j < arg.len) : (j += 1) {
                if (arg[j] == '\\') {
                    // Count consecutive backslashes
                    var num_bs: usize = 0;
                    while (j + num_bs < arg.len and arg[j + num_bs] == '\\')
                        num_bs += 1;
                    if (j + num_bs < arg.len and arg[j + num_bs] == '"') {
                        // Backslashes before a quote: double them + escape the quote
                        try buf.appendNTimes('\\', num_bs * 2);
                        try buf.append('\\');
                        try buf.append('"');
                        j += num_bs; // the inner loop will +1 for the '"'
                    } else {
                        try buf.appendNTimes('\\', num_bs);
                        j += num_bs - 1;
                    }
                } else if (arg[j] == '"') {
                    try buf.append('\\');
                    try buf.append('"');
                } else {
                    try buf.append(arg[j]);
                }
            }
            try buf.append('"');
        } else {
            try buf.appendSlice(arg);
        }
    }

    return std.unicode.wtf8ToWtf16LeAllocZ(allocator, buf.items);
}
