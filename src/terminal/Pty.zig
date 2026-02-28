//! A PTY pair
const Pty = @This();

const std = @import("std");
const builtin = @import("builtin");
const Winsize = @import("../../main.zig").Winsize;

const posix = std.posix;

pty: std.fs.File,
tty: std.fs.File,

/// opens a new tty/pty pair
pub fn init() !Pty {
    switch (builtin.os.tag) {
        .linux => return openPtyLinux(),
        .macos => return openPtyMacos(),
        .freebsd, .netbsd, .openbsd, .dragonfly => return openPtyBsd(),
        else => @compileError("unsupported os"),
    }
}

/// closes the tty and pty
pub fn deinit(self: Pty) void {
    self.pty.close();
    self.tty.close();
}

/// sets the size of the pty
pub fn setSize(self: Pty, ws: Winsize) !void {
    const _ws: posix.winsize = .{
        .row = @truncate(ws.rows),
        .col = @truncate(ws.cols),
        .xpixel = @truncate(ws.x_pixel),
        .ypixel = @truncate(ws.y_pixel),
    };
    // TIOCSWINSZ: _IOW('t', 103, struct winsize) = 0x80087467
    // Cast via @bitCast to c_int since macOS ioctl takes c_int for the request arg.
    const TIOCSWINSZ: c_int = switch (builtin.os.tag) {
        .linux => @bitCast(@as(u32, posix.T.IOCSWINSZ)),
        else => @bitCast(@as(u32, 0x80087467)),
    };
    if (posix.system.ioctl(self.pty.handle, TIOCSWINSZ, @intFromPtr(&_ws)) != 0)
        return error.SetWinsizeError;
}

/// Linux: uses /dev/ptmx with Linux-specific TIOCSPTLCK/IOCGPTN ioctls
fn openPtyLinux() !Pty {
    const p = try posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
    errdefer posix.close(p);

    // unlockpt: clear the lock flag
    var n: c_uint = 0;
    if (posix.system.ioctl(p, @as(c_int, @bitCast(posix.T.IOCSPTLCK)), @intFromPtr(&n)) != 0)
        return error.IoctlError;

    // ptsname: get the slave device number
    if (posix.system.ioctl(p, @as(c_int, @bitCast(posix.T.IOCGPTN)), @intFromPtr(&n)) != 0)
        return error.IoctlError;
    var buf: [16]u8 = undefined;
    const sname = try std.fmt.bufPrint(&buf, "/dev/pts/{d}", .{n});
    std.log.debug("pts: {s}", .{sname});

    const t = try posix.open(sname, .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);

    return .{
        .pty = .{ .handle = p },
        .tty = .{ .handle = t },
    };
}

/// macOS: uses posix_openpt + grantpt + unlockpt + ptsname (not thread-safe but fine here)
fn openPtyMacos() !Pty {
    const p = posix_openpt(posix.O{ .ACCMODE = .RDWR, .NOCTTY = true });
    if (p < 0) return error.OpenPtyFailed;
    errdefer posix.close(p);

    if (grantpt(p) != 0) return error.GrantPtFailed;
    if (unlockpt(p) != 0) return error.UnlockPtFailed;

    // ptsname returns a pointer to a static buffer on macOS
    const sname_ptr = ptsname(p) orelse return error.PtsnameFailed;
    const sname = std.mem.sliceTo(sname_ptr, 0);
    std.log.debug("pts: {s}", .{sname});

    const t = try posix.open(sname, .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);

    return .{
        .pty = .{ .handle = p },
        .tty = .{ .handle = t },
    };
}

/// FreeBSD/NetBSD/OpenBSD: uses posix_openpt + grantpt + unlockpt + ptsname_r
fn openPtyBsd() !Pty {
    const p = posix_openpt(posix.O{ .ACCMODE = .RDWR, .NOCTTY = true });
    if (p < 0) return error.OpenPtyFailed;
    errdefer posix.close(p);

    if (grantpt(p) != 0) return error.GrantPtFailed;
    if (unlockpt(p) != 0) return error.UnlockPtFailed;

    var sname_buf: [64]u8 = undefined;
    if (ptsname_r(p, &sname_buf, sname_buf.len) != 0) return error.PtsnameFailed;
    const sname = std.mem.sliceTo(&sname_buf, 0);
    std.log.debug("pts: {s}", .{sname});

    const t = try posix.open(sname, .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);

    return .{
        .pty = .{ .handle = p },
        .tty = .{ .handle = t },
    };
}

// POSIX pty functions not wrapped by Zig stdlib
extern fn posix_openpt(flags: posix.O) posix.fd_t;
extern fn grantpt(fd: posix.fd_t) c_int;
extern fn unlockpt(fd: posix.fd_t) c_int;
/// macOS: returns pointer to static buffer (not thread-safe)
extern fn ptsname(fd: posix.fd_t) ?[*:0]u8;
/// FreeBSD/NetBSD/OpenBSD: thread-safe variant
extern fn ptsname_r(fd: posix.fd_t, buf: [*]u8, len: usize) c_int;
