//! File type detection for project file lists: by path, falling back to
//! the first line of the file's content.

const std = @import("std");
const builtin = @import("builtin");
const root = @import("soft_root").root;
const file_type_config = @import("file_type_config");

fn default_ft() struct { []const u8, []const u8, u24 } {
    return .{
        file_type_config.default.name,
        file_type_config.default.icon,
        file_type_config.default.color,
    };
}

pub fn guess_path_file_type(path: []const u8, file_name: []const u8) struct { []const u8, []const u8, u24 } {
    var buf: [4096]u8 = undefined;
    return guess_file_type(resolve_file_path(path, file_name, &buf) orelse return default_ft());
}

fn resolve_file_path(path: []const u8, file_name: []const u8, buf: []u8) ?[]const u8 {
    if (std.fs.path.isAbsolute(file_name)) return file_name;
    return std.fmt.bufPrint(buf, "{s}{c}{s}", .{ path, std.fs.path.sep, file_name }) catch null;
}

pub fn guess_file_type(file_path: []const u8) struct { []const u8, []const u8, u24 } {
    // file types are configured in the config directory, which test binaries lack
    if (builtin.is_test) return default_ft();
    var buf: [1024]u8 = undefined;
    const content: []const u8 = blk: {
        const io = root.get_io();
        const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch break :blk &.{};
        defer file.close(io);
        const size = safe_file_read(file, &buf) catch break :blk &.{};
        break :blk buf[0..size];
    };
    return if (file_type_config.guess_file_type(file_path, content)) |ft| .{
        ft.name,
        ft.icon orelse file_type_config.default.icon,
        ft.color orelse file_type_config.default.color,
    } else default_ft();
}

fn safe_file_read(self: std.Io.File, buffer: []u8) (error{ FileHandleInvalidForReading, ProcessNotFound, ConnectionTimedOut } || std.Io.File.ReadStreamingError)!usize {
    return switch (builtin.os.tag) {
        .windows => safe_windows_read(self.handle, buffer),
        else => safe_posix_read(self.handle, buffer),
    };
}

fn safe_windows_read(handle: std.os.windows.HANDLE, buffer: []u8) (error{ FileHandleInvalidForReading, ProcessNotFound, ConnectionTimedOut } || std.Io.File.ReadStreamingError)!usize {
    const windows = std.os.windows;
    const ReadFile = struct {
        extern "kernel32" fn ReadFile(hFile: windows.HANDLE, lpBuffer: ?[*]u8, nNumberOfBytesToRead: windows.DWORD, lpNumberOfBytesRead: ?*windows.DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;
    }.ReadFile;
    var bytes_read: windows.DWORD = 0;
    const len: windows.DWORD = @intCast(@min(buffer.len, std.math.maxInt(windows.DWORD)));
    if (ReadFile(handle, buffer.ptr, len, &bytes_read, null) == .FALSE)
        return windows.unexpectedError(windows.GetLastError());
    return @intCast(bytes_read);
}

fn safe_posix_read(fd: std.posix.fd_t, buf: []u8) (error{ FileHandleInvalidForReading, ConnectionTimedOut, ProcessNotFound } || std.Io.File.ReadStreamingError)!usize {
    const native_os = builtin.os.tag;
    const unexpectedErrno = safe_unexpectedErrno;
    const maxInt = std.math.maxInt;
    const system = std.posix.system;
    const errno = std.posix.errno;
    if (buf.len == 0) return 0;
    if (native_os == .wasi and !builtin.link_libc) {
        const iovec = std.os.posix.iovec;
        const wasi = std.os.wasi;
        const iovs = [1]iovec{iovec{
            .base = buf.ptr,
            .len = buf.len,
        }};

        var nread: usize = undefined;
        switch (wasi.fd_read(fd, &iovs, iovs.len, &nread)) {
            .SUCCESS => return nread,
            .INTR => unreachable,
            .INVAL => return error.FileHandleInvalidForReading,
            .FAULT => unreachable,
            .AGAIN => unreachable,
            .BADF => return error.NotOpenForReading, // Can be a race condition.
            .IO => return error.InputOutput,
            .ISDIR => return error.IsDir,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .NOTCONN => return error.SocketUnconnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .NOTCAPABLE => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }

    // Prevents EINVAL.
    const max_count = switch (native_os) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos, .visionos => maxInt(i32),
        else => maxInt(isize),
    };
    while (true) {
        const rc = system.read(fd, buf.ptr, @min(buf.len, max_count));
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL => return error.FileHandleInvalidForReading,
            .FAULT => unreachable,
            .SRCH => return error.ProcessNotFound,
            .AGAIN => return error.WouldBlock,
            .CANCELED => return error.Canceled,
            .BADF => return error.NotOpenForReading, // Can be a race condition.
            .IO => return error.InputOutput,
            .ISDIR => return error.IsDir,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .NOTCONN => return error.SocketUnconnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn safe_unexpectedErrno(_: std.posix.system.E) std.posix.UnexpectedError {
    return error.Unexpected;
}

test "absolute file names are not prefixed with the project path" {
    const absolute = if (builtin.os.tag == .windows) "C:\\tmp\\script" else "/tmp/script";
    var buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(absolute, resolve_file_path("project", absolute, &buf).?);

    const expected = if (builtin.os.tag == .windows) "project\\relative" else "project/relative";
    try std.testing.expectEqualStrings(expected, resolve_file_path("project", "relative", &buf).?);
}
