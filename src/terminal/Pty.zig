//! A PTY pair
const Pty = @This();

const std = @import("std");
const builtin = @import("builtin");
const Winsize = @import("../../main.zig").Winsize;

const posix = std.posix;

pty: posix.fd_t,
tty: posix.fd_t,

/// opens a new tty/pty pair
pub fn init() !Pty {
    switch (builtin.os.tag) {
        .linux => return openPtyLinux(),
        else => @compileError("unsupported os"),
    }
}

/// closes the tty and pty
pub fn deinit(self: Pty) void {
    posix.close(self.pty);
    posix.close(self.tty);
}

/// sets the size of the pty
pub fn setSize(self: Pty, ws: Winsize) !void {
    const _ws: posix.winsize = .{
        .row = @truncate(ws.rows),
        .col = @truncate(ws.cols),
        .xpixel = @truncate(ws.x_pixel),
        .ypixel = @truncate(ws.y_pixel),
    };
    if (posix.system.ioctl(self.pty, posix.T.IOCSWINSZ, @intFromPtr(&_ws)) != 0)
        return error.SetWinsizeError;
}

fn openPtyLinux() !Pty {
    const p = try posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
    errdefer posix.close(p);

    // unlockpt
    var n: c_uint = 0;
    if (posix.system.ioctl(p, posix.T.IOCSPTLCK, @intFromPtr(&n)) != 0) return error.IoctlError;

    // ptsname
    if (posix.system.ioctl(p, posix.T.IOCGPTN, @intFromPtr(&n)) != 0) return error.IoctlError;
    var buf: [16]u8 = undefined;
    const sname = try std.fmt.bufPrint(&buf, "/dev/pts/{d}", .{n});
    std.log.debug("pts: {s}", .{sname});

    const t = try posix.open(sname, .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);

    return .{
        .pty = p,
        .tty = t,
    };
}
