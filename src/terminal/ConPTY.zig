//! Windows ConPTY (pseudo-console) implementation.
//! Provides the same interface as Pty.zig so Terminal.zig can use it uniformly.
const ConPTY = @This();

const std = @import("std");
const windows = std.os.windows;
const Winsize = @import("../../main.zig").Winsize;

// ConPTY API types and functions - not yet in Zig stdlib so declared as extern.
// Available since Windows 1809 (build 17763).
const HPCON = *anyopaque;

extern "kernel32" fn CreatePseudoConsole(
    size: COORD,
    hInput: windows.HANDLE,
    hOutput: windows.HANDLE,
    dwFlags: windows.DWORD,
    phPC: *HPCON,
) callconv(.winapi) windows.HRESULT;

extern "kernel32" fn ResizePseudoConsole(
    hPC: HPCON,
    size: COORD,
) callconv(.winapi) windows.HRESULT;

extern "kernel32" fn ClosePseudoConsole(
    hPC: HPCON,
) callconv(.winapi) void;

// PROC_THREAD_ATTRIBUTE_LIST helpers
extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?windows.LPVOID,
    dwAttributeCount: windows.DWORD,
    dwFlags: windows.DWORD,
    lpSize: *usize,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: windows.LPVOID,
    dwFlags: windows.DWORD,
    Attribute: usize,
    lpValue: windows.LPVOID,
    cbSize: usize,
    lpPreviousValue: ?windows.LPVOID,
    lpReturnSize: ?*usize,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn DeleteProcThreadAttributeList(
    lpAttributeList: windows.LPVOID,
) callconv(.winapi) void;

const COORD = extern struct {
    X: i16,
    Y: i16,
};

// PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016
const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;

/// The pseudo-console handle (terminal side).
hpc: HPCON,
/// Read end of the output pipe - child writes here, we read terminal output from here.
/// Owned by this struct; passed to tp.file_stream in the pty actor.
pipe_out_read: windows.HANDLE,
/// Write end of the input pipe - we write keystrokes here, child reads from it.
/// Used as the pty_writer target.
pipe_in_write: windows.HANDLE,
/// Write end of output pipe - passed to child via ConPTY; we close after spawn.
pipe_out_write: windows.HANDLE,
/// Read end of the input pipe - passed to child via ConPTY; we close after spawn.
pipe_in_read: windows.HANDLE,

/// The attribute list buffer - allocated and freed by init/deinit.
/// Kept alive for the process lifetime.
attr_list_buf: []u8,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, ws: Winsize) !ConPTY {
    var saAttr = windows.SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .bInheritHandle = windows.TRUE,
        .lpSecurityDescriptor = null,
    };

    // Create the input pipe: our write end -> child's stdin via ConPTY
    var pipe_in_read: windows.HANDLE = undefined;
    var pipe_in_write: windows.HANDLE = undefined;
    try windows.CreatePipe(&pipe_in_read, &pipe_in_write, &saAttr);
    errdefer {
        windows.CloseHandle(pipe_in_read);
        windows.CloseHandle(pipe_in_write);
    }
    // Don't inherit our write end - only the child side is inherited via ConPTY
    try windows.SetHandleInformation(pipe_in_write, windows.HANDLE_FLAG_INHERIT, 0);

    // Create the output pipe: child's stdout via ConPTY -> our read end
    // Use an overlapped (async) pipe so tp.file_stream can do IOCP reads.
    var pipe_out_read: windows.HANDLE = undefined;
    var pipe_out_write: windows.HANDLE = undefined;
    try makeAsyncPipe(&pipe_out_read, &pipe_out_write, &saAttr);
    errdefer {
        windows.CloseHandle(pipe_out_read);
        windows.CloseHandle(pipe_out_write);
    }
    // Don't inherit our read end
    try windows.SetHandleInformation(pipe_out_read, windows.HANDLE_FLAG_INHERIT, 0);

    // Create the pseudo-console
    const size: COORD = .{
        .X = @intCast(ws.cols),
        .Y = @intCast(ws.rows),
    };
    var hpc: HPCON = undefined;
    const hr = CreatePseudoConsole(size, pipe_in_read, pipe_out_write, 0, &hpc);
    if (hr != 0) return error.CreatePseudoConsoleFailed; // S_OK = 0
    errdefer ClosePseudoConsole(hpc);

    // Build the PROC_THREAD_ATTRIBUTE_LIST with one attribute (PSEUDOCONSOLE).
    var attr_list_size: usize = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_list_size);
    // attr_list_size is now the required buffer size
    const attr_list_buf = try allocator.alloc(u8, attr_list_size);
    errdefer allocator.free(attr_list_buf);

    if (InitializeProcThreadAttributeList(attr_list_buf.ptr, 1, 0, &attr_list_size) == windows.FALSE)
        return error.InitProcThreadAttributeListFailed;
    errdefer DeleteProcThreadAttributeList(attr_list_buf.ptr);

    if (UpdateProcThreadAttribute(
        attr_list_buf.ptr,
        0,
        PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        hpc,
        @sizeOf(HPCON),
        null,
        null,
    ) == windows.FALSE)
        return error.UpdateProcThreadAttributeFailed;

    return .{
        .hpc = hpc,
        .pipe_out_read = pipe_out_read,
        .pipe_in_write = pipe_in_write,
        .pipe_out_write = pipe_out_write,
        .pipe_in_read = pipe_in_read,
        .attr_list_buf = attr_list_buf,
        .allocator = allocator,
    };
}

/// Call after the child process is spawned to close the pipe ends the child
/// has inherited. Keeping them open would prevent EOF detection.
pub fn closChildSidePipes(self: *ConPTY) void {
    windows.CloseHandle(self.pipe_out_write);
    windows.CloseHandle(self.pipe_in_read);
    self.pipe_out_write = windows.INVALID_HANDLE_VALUE;
    self.pipe_in_read = windows.INVALID_HANDLE_VALUE;
}

pub fn deinit(self: *ConPTY) void {
    ClosePseudoConsole(self.hpc);
    if (self.pipe_out_read != windows.INVALID_HANDLE_VALUE) windows.CloseHandle(self.pipe_out_read);
    if (self.pipe_in_write != windows.INVALID_HANDLE_VALUE) windows.CloseHandle(self.pipe_in_write);
    if (self.pipe_out_write != windows.INVALID_HANDLE_VALUE) windows.CloseHandle(self.pipe_out_write);
    if (self.pipe_in_read != windows.INVALID_HANDLE_VALUE) windows.CloseHandle(self.pipe_in_read);
    DeleteProcThreadAttributeList(self.attr_list_buf.ptr);
    self.allocator.free(self.attr_list_buf);
}

pub fn setSize(self: *ConPTY, ws: Winsize) !void {
    const size: COORD = .{
        .X = @intCast(ws.cols),
        .Y = @intCast(ws.rows),
    };
    const hr = ResizePseudoConsole(self.hpc, size);
    if (hr != 0) return error.ResizePseudoConsoleFailed;
}

/// Returns a std.fs.File wrapping the write end of the input pipe,
/// suitable for writerStreaming() to produce our pty_writer.
pub fn inputFile(self: *const ConPTY) std.fs.File {
    return .{ .handle = self.pipe_in_write };
}

/// Returns the HANDLE for reading terminal output, to pass to tp.file_stream.
pub fn outputHandle(self: *const ConPTY) *anyopaque {
    return self.pipe_out_read;
}

/// Returns a pointer to the PROC_THREAD_ATTRIBUTE_LIST buffer for CreateProcess.
pub fn attrList(self: *const ConPTY) windows.LPVOID {
    return self.attr_list_buf.ptr;
}

/// Create an overlapped (async/IOCP-compatible) read pipe using a named pipe.
/// This mirrors the makeAsyncPipe pattern from subprocess_windows.zig.
var pipe_name_counter = std.atomic.Value(u32).init(1);

fn makeAsyncPipe(
    rd: *windows.HANDLE,
    wr: *windows.HANDLE,
    sattr: *const windows.SECURITY_ATTRIBUTES,
) !void {
    var tmp_bufw: [128]u16 = undefined;
    const pipe_path = blk: {
        var tmp_buf: [128]u8 = undefined;
        const pipe_path = std.fmt.bufPrintZ(
            &tmp_buf,
            "\\\\.\\pipe\\flow-terminal-conpty-{d}-{d}",
            .{ windows.GetCurrentProcessId(), pipe_name_counter.fetchAdd(1, .monotonic) },
        ) catch unreachable;
        const len = std.unicode.wtf8ToWtf16Le(&tmp_bufw, pipe_path) catch unreachable;
        tmp_bufw[len] = 0;
        break :blk tmp_bufw[0..len :0];
    };

    const read_handle = windows.kernel32.CreateNamedPipeW(
        pipe_path.ptr,
        windows.PIPE_ACCESS_INBOUND | windows.FILE_FLAG_OVERLAPPED,
        windows.PIPE_TYPE_BYTE,
        1,
        4096,
        4096,
        0,
        sattr,
    );
    if (read_handle == windows.INVALID_HANDLE_VALUE) {
        switch (windows.kernel32.GetLastError()) {
            else => |err| return windows.unexpectedError(err),
        }
    }
    errdefer windows.CloseHandle(read_handle);

    var sattr_copy = sattr.*;
    const write_handle = windows.kernel32.CreateFileW(
        pipe_path.ptr,
        windows.GENERIC_WRITE,
        0,
        &sattr_copy,
        windows.OPEN_EXISTING,
        windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (write_handle == windows.INVALID_HANDLE_VALUE) {
        switch (windows.kernel32.GetLastError()) {
            else => |err| return windows.unexpectedError(err),
        }
    }
    errdefer windows.CloseHandle(write_handle);

    try windows.SetHandleInformation(read_handle, windows.HANDLE_FLAG_INHERIT, 0);

    rd.* = read_handle;
    wr.* = write_handle;
}
