//! Windows ConPTY (pseudo-console) implementation.
//! Provides the same interface as Pty.zig so Terminal.zig can use it uniformly.
const ConPTY = @This();

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const Winsize = @import("vaxis").Winsize;
const root = @import("soft_root").root;

// ConPTY API types and functions - not yet in Zig stdlib so declared as extern.
// Available since Windows 1809 (build 17763).
const HPCON = *anyopaque;
const HRESULT = c_long;

extern "kernel32" fn CreatePseudoConsole(
    size: COORD,
    hInput: windows.HANDLE,
    hOutput: windows.HANDLE,
    dwFlags: windows.DWORD,
    phPC: *HPCON,
) callconv(.winapi) HRESULT;

extern "kernel32" fn ResizePseudoConsole(
    hPC: HPCON,
    size: COORD,
) callconv(.winapi) HRESULT;

extern "kernel32" fn ClosePseudoConsole(
    hPC: HPCON,
) callconv(.winapi) void;

extern "kernel32" fn CreatePipe(
    hReadPipe: *windows.HANDLE,
    hWritePipe: *windows.HANDLE,
    lpPipeAttributes: ?*windows.SECURITY_ATTRIBUTES,
    nSize: windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn SetHandleInformation(
    hObject: windows.HANDLE,
    dwMask: windows.DWORD,
    dwFlags: windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn CreateNamedPipeW(
    lpName: [*:0]const u16,
    dwOpenMode: windows.DWORD,
    dwPipeMode: windows.DWORD,
    nMaxInstances: windows.DWORD,
    nOutBufferSize: windows.DWORD,
    nInBufferSize: windows.DWORD,
    nDefaultTimeOut: windows.DWORD,
    lpSecurityAttributes: ?*const windows.SECURITY_ATTRIBUTES,
) callconv(.winapi) windows.HANDLE;

extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: windows.DWORD,
    dwShareMode: windows.DWORD,
    lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES,
    dwCreationDisposition: windows.DWORD,
    dwFlagsAndAttributes: windows.DWORD,
    hTemplateFile: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;

const HANDLE_FLAG_INHERIT: windows.DWORD = 0x00000001;
const PIPE_ACCESS_INBOUND: windows.DWORD = 0x00000001;
const FILE_FLAG_OVERLAPPED: windows.DWORD = 0x40000000;
const PIPE_TYPE_BYTE: windows.DWORD = 0x00000000;
const GENERIC_WRITE: windows.DWORD = 0x40000000;
const OPEN_EXISTING: windows.DWORD = 3;
const FILE_ATTRIBUTE_NORMAL: windows.DWORD = 0x00000080;

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

extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn FreeLibrary(hLibModule: *anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;

/// pseudo-console functions, from kernel32 or from a conpty.dll
const Api = struct {
    create: *const fn (COORD, windows.HANDLE, windows.HANDLE, windows.DWORD, *HPCON) callconv(.winapi) HRESULT,
    resize: *const fn (HPCON, COORD) callconv(.winapi) HRESULT,
    close: *const fn (HPCON) callconv(.winapi) void,
};

const builtin_api: Api = .{
    .create = &CreatePseudoConsole,
    .resize = &ResizePseudoConsole,
    .close = &ClosePseudoConsole,
};

pub const Package = struct {
    version: []const u8,
    url: []const u8,
    sha256: [32]u8,
    dll_entry: []const u8,
    console_entry: []const u8,
};

pub const package: Package = blk: {
    const version = "1.25.260930003";
    const dll_arch, const console_arch = switch (builtin.cpu.arch) {
        .x86_64 => .{ "win-x64", "x64" },
        .aarch64 => .{ "win-arm64", "arm64" },
        else => @compileError("no ConPTY package for this architecture"),
    };
    var buf: [32]u8 = undefined;
    const sha256 = std.fmt.hexToBytes(&buf, "02b07b349af66d801159bdf9e440d4a1ce78bb951f37fc8609731665afdae7ee") catch unreachable;
    break :blk .{
        .version = version,
        .url = "https://api.nuget.org/v3-flatcontainer/microsoft.windows.console.conpty/" ++ version ++
            "/microsoft.windows.console.conpty." ++ version ++ ".nupkg",
        .sha256 = sha256.*,
        .dll_entry = "runtimes/" ++ dll_arch ++ "/native/conpty.dll",
        .console_entry = "build/native/runtimes/" ++ console_arch ++ "/OpenConsole.exe",
    };
};

pub fn download_dir(allocator: std.mem.Allocator) ![]u8 {
    return std.fs.path.join(allocator, &.{ try root.get_state_dir(), "conpty", package.version });
}

var api_: ?Api = null;
var api_path_buf: [std.fs.max_path_bytes]u8 = undefined;
var api_path: ?[]const u8 = null;

fn api() Api {
    return api_ orelse builtin_api;
}

fn load_api(allocator: std.mem.Allocator, io: std.Io) void {
    if (api_ == null) api_ = load_bundled_api(allocator, io) orelse builtin_api;
}

pub fn is_loaded() bool {
    return api_ != null;
}

pub fn bundled_available(allocator: std.mem.Allocator, io: std.Io) bool {
    const exe_dir = std.process.executableDirPathAlloc(io, allocator) catch return false;
    defer allocator.free(exe_dir);
    if (dll_exists(allocator, io, exe_dir)) return true;
    const dir = download_dir(allocator) catch return false;
    defer allocator.free(dir);
    return dll_exists(allocator, io, dir);
}

fn dll_exists(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) bool {
    const path = std.fs.path.join(allocator, &.{ dir, "conpty.dll" }) catch return false;
    defer allocator.free(path);
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

pub fn dll_path(allocator: std.mem.Allocator, io: std.Io) ?[]const u8 {
    load_api(allocator, io);
    return api_path;
}

fn load_bundled_api(allocator: std.mem.Allocator, io: std.Io) ?Api {
    const log = std.log.scoped(.conpty);
    const module = open_bundled_dll(allocator, io) catch |e| {
        log.debug("conpty.dll not loaded ({t}), using the built-in ConPTY", .{e});
        return null;
    };
    const create = GetProcAddress(module, "ConptyCreatePseudoConsole");
    const resize = GetProcAddress(module, "ConptyResizePseudoConsole");
    const close = GetProcAddress(module, "ConptyClosePseudoConsole");
    if (create == null or resize == null or close == null) {
        log.debug("conpty.dll lacks the Conpty functions, using the built-in ConPTY", .{});
        _ = FreeLibrary(module);
        api_path = null;
        return null;
    }
    log.debug("using the bundled conpty.dll", .{});
    return .{ .create = @ptrCast(@alignCast(create)), .resize = @ptrCast(@alignCast(resize)), .close = @ptrCast(@alignCast(close)) };
}

fn open_bundled_dll(allocator: std.mem.Allocator, io: std.Io) !*anyopaque {
    const exe_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(exe_dir);
    return open_dll_in(allocator, exe_dir) catch |e| switch (e) {
        error.FileNotFound => {
            const dir = try download_dir(allocator);
            defer allocator.free(dir);
            return open_dll_in(allocator, dir);
        },
        else => e,
    };
}

fn open_dll_in(allocator: std.mem.Allocator, dir: []const u8) !*anyopaque {
    const path = try std.fs.path.join(allocator, &.{ dir, "conpty.dll" });
    defer allocator.free(path);
    if (path.len > api_path_buf.len) return error.NameTooLong;
    const path_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, path);
    defer allocator.free(path_w);
    const module = LoadLibraryW(path_w) orelse return error.FileNotFound;
    @memcpy(api_path_buf[0..path.len], path);
    api_path = api_path_buf[0..path.len];
    return module;
}

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

pub fn init(allocator: std.mem.Allocator, io: std.Io, ws: Winsize) !ConPTY {
    load_api(allocator, io);

    var saAttr = windows.SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .bInheritHandle = .TRUE,
        .lpSecurityDescriptor = null,
    };

    // Create the input pipe: our write end -> child's stdin via ConPTY
    var pipe_in_read: windows.HANDLE = undefined;
    var pipe_in_write: windows.HANDLE = undefined;
    if (CreatePipe(&pipe_in_read, &pipe_in_write, &saAttr, 0) == .FALSE)
        return error.CreatePipeFailed;
    errdefer {
        windows.CloseHandle(pipe_in_read);
        windows.CloseHandle(pipe_in_write);
    }
    // Don't inherit our write end - only the child side is inherited via ConPTY
    if (SetHandleInformation(pipe_in_write, HANDLE_FLAG_INHERIT, 0) == .FALSE)
        return error.SetHandleInformationFailed;

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
    if (SetHandleInformation(pipe_out_read, HANDLE_FLAG_INHERIT, 0) == .FALSE)
        return error.SetHandleInformationFailed;

    // Create the pseudo-console
    const size: COORD = .{
        .X = @intCast(ws.cols),
        .Y = @intCast(ws.rows),
    };
    var hpc: HPCON = undefined;
    const hr = api().create(size, pipe_in_read, pipe_out_write, 0, &hpc);
    if (hr != 0) return error.CreatePseudoConsoleFailed; // S_OK = 0
    errdefer api().close(hpc);

    // Build the PROC_THREAD_ATTRIBUTE_LIST with one attribute (PSEUDOCONSOLE).
    var attr_list_size: usize = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_list_size);
    // attr_list_size is now the required buffer size
    const attr_list_buf = try allocator.alloc(u8, attr_list_size);
    errdefer allocator.free(attr_list_buf);

    if (InitializeProcThreadAttributeList(attr_list_buf.ptr, 1, 0, &attr_list_size) == .FALSE)
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
    ) == .FALSE)
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

pub fn deinit(self: *ConPTY, _: std.Io) void {
    api().close(self.hpc);
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
    const hr = api().resize(self.hpc, size);
    if (hr != 0) return error.ResizePseudoConsoleFailed;
}

/// Returns a std.Io.File wrapping the write end of the input pipe,
/// suitable for writerStreaming() to produce our pty_writer.
pub fn inputFile(self: *const ConPTY) std.Io.File {
    return .{ .handle = self.pipe_in_write, .flags = .{ .nonblocking = false } };
}

/// Returns the HANDLE for reading terminal output - transfers ownership
/// The caller will/must close this handle, so ConPTY.deinit()
/// must not. The handle is marked INVALID here to prevent a double-close.
pub fn outputHandle(self: *ConPTY) *anyopaque {
    const h = self.pipe_out_read;
    self.pipe_out_read = windows.INVALID_HANDLE_VALUE;
    return h;
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
        const pipe_path = std.fmt.bufPrintSentinel(
            &tmp_buf,
            "\\\\.\\pipe\\flow-terminal-conpty-{d}-{d}",
            .{ windows.GetCurrentProcessId(), pipe_name_counter.fetchAdd(1, .monotonic) },
            0,
        ) catch unreachable;
        const len = std.unicode.wtf8ToWtf16Le(&tmp_bufw, pipe_path) catch unreachable;
        tmp_bufw[len] = 0;
        break :blk tmp_bufw[0..len :0];
    };

    const read_handle = CreateNamedPipeW(
        pipe_path.ptr,
        PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED,
        PIPE_TYPE_BYTE,
        1,
        4096,
        4096,
        0,
        sattr,
    );
    if (read_handle == windows.INVALID_HANDLE_VALUE) {
        switch (windows.GetLastError()) {
            else => |err| return windows.unexpectedError(err),
        }
    }
    errdefer windows.CloseHandle(read_handle);

    var sattr_copy = sattr.*;
    const write_handle = CreateFileW(
        pipe_path.ptr,
        GENERIC_WRITE,
        0,
        &sattr_copy,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (write_handle == windows.INVALID_HANDLE_VALUE) {
        switch (windows.GetLastError()) {
            else => |err| return windows.unexpectedError(err),
        }
    }
    errdefer windows.CloseHandle(write_handle);

    if (SetHandleInformation(read_handle, HANDLE_FLAG_INHERIT, 0) == .FALSE)
        return error.SetHandleInformationFailed;

    rd.* = read_handle;
    wr.* = write_handle;
}
