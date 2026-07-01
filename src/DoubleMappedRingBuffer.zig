const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

pub const page_align = std.heap.page_size_min;

backing: Backing,

pub const InitError = Backing.Error;

pub fn init(byte_len: usize) InitError!@This() {
    assert(byte_len != 0);
    assert(byte_len % std.heap.pageSize() == 0);
    return .{ .backing = try Backing.init(byte_len) };
}

pub fn deinit(self: *@This()) void {
    self.backing.deinit();
    self.* = undefined;
}

pub fn len(self: @This()) usize {
    return self.backing.base.len / 2;
}

pub fn data(self: @This()) []u8 {
    return self.backing.base[0..self.len()];
}

pub fn slice(self: @This(), offset: usize, length: usize) []u8 {
    const l = self.len();
    assert(length <= l);
    const real = offset % l;
    return self.backing.base[real .. real + length];
}

const Backing = switch (builtin.os.tag) {
    .linux => LinuxBacking,
    .freebsd, .macos, .ios, .tvos, .watchos, .visionos => PosixShmBacking,
    .windows => WindowsBacking,
    else => @compileError("@This(): unsupported OS " ++ @tagName(builtin.os.tag)),
};

const LinuxBacking = struct {
    const posix = std.posix;
    const linux = std.os.linux;

    fd: posix.fd_t,
    base: []align(page_align) u8,

    pub const Error = posix.MMapError || posix.MemFdCreateError || error{ Truncate, MappingMoved };

    pub fn init(byte_len: usize) Error!LinuxBacking {
        const fd = try posix.memfd_create("flow-double-ring", linux.MFD.CLOEXEC);
        errdefer _ = linux.close(fd);

        switch (linux.errno(linux.ftruncate(fd, @intCast(byte_len)))) {
            .SUCCESS => {},
            else => return error.Truncate,
        }

        const base = try mapDouble(fd, byte_len);
        return .{ .fd = fd, .base = base };
    }

    pub fn deinit(self: *LinuxBacking) void {
        posix.munmap(self.base);
        _ = linux.close(self.fd);
    }
};

const PosixShmBacking = struct {
    const posix = std.posix;
    const c = std.c;

    fd: posix.fd_t,
    base: []align(page_align) u8,

    pub const Error = posix.MMapError || error{ ShmOpen, Truncate, MappingMoved };

    var name_counter: std.atomic.Value(u32) = .init(0);

    pub fn init(byte_len: usize) Error!PosixShmBacking {
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrintZ(
            &name_buf,
            "/flow-double-ring-{d}-{d}",
            .{ c.getpid(), name_counter.fetchAdd(1, .monotonic) },
        ) catch unreachable;

        const O_RDWR: c_int = 0x0002;
        const O_CREAT: c_int = 0x0200;
        const O_EXCL: c_int = 0x0800;
        const rc = c.shm_open(name.ptr, O_RDWR | O_CREAT | O_EXCL, @as(c.mode_t, 0o600));
        if (rc < 0) return error.ShmOpen;
        const fd: posix.fd_t = @intCast(rc);
        _ = c.shm_unlink(name.ptr);
        errdefer _ = c.close(fd);

        if (c.ftruncate(fd, @intCast(byte_len)) != 0) return error.Truncate;

        const base = try mapDouble(fd, byte_len);
        return .{ .fd = fd, .base = base };
    }

    pub fn deinit(self: *PosixShmBacking) void {
        posix.munmap(self.base);
        _ = c.close(self.fd);
    }
};

fn mapDouble(fd: std.posix.fd_t, byte_len: usize) std.posix.MMapError![]align(page_align) u8 {
    const posix = std.posix;

    const reservation = try posix.mmap(
        null,
        byte_len * 2,
        .{}, // PROT_NONE: just reserve address space
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    errdefer posix.munmap(reservation);

    const lo = try posix.mmap(
        @alignCast(reservation.ptr),
        byte_len,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED, .FIXED = true },
        fd,
        0,
    );
    if (lo.ptr != reservation.ptr) return error.MappingAlreadyExists;

    const hi = try posix.mmap(
        @alignCast(reservation.ptr + byte_len),
        byte_len,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED, .FIXED = true },
        fd,
        0,
    );
    if (hi.ptr != reservation.ptr + byte_len) return error.MappingAlreadyExists;

    return reservation;
}

const WindowsBacking = struct {
    const windows = std.os.windows;

    section: windows.HANDLE,
    base: []align(page_align) u8,

    pub const Error = error{ CreateSection, ReserveFailed, SplitFailed, MapFailed };

    pub fn init(byte_len: usize) Error!WindowsBacking {
        const section = CreateFileMappingW(
            windows.INVALID_HANDLE_VALUE,
            null,
            PAGE_READWRITE,
            @intCast(byte_len >> 32),
            @truncate(byte_len),
            null,
        );
        if (section == null) return error.CreateSection;
        errdefer _ = windows.CloseHandle(section.?);

        // reserve a 2*byte_len placeholder
        const placeholder = VirtualAlloc2(
            null,
            null,
            byte_len * 2,
            MEM_RESERVE | MEM_RESERVE_PLACEHOLDER,
            PAGE_NOACCESS,
            null,
            0,
        );
        if (placeholder == null) return error.ReserveFailed;
        const base: [*]align(page_align) u8 = @ptrCast(@alignCast(placeholder.?));
        errdefer _ = VirtualFree(placeholder.?, 0, MEM_RELEASE);

        // split the placeholder into two
        if (VirtualFree(placeholder.?, byte_len, MEM_RELEASE | MEM_PRESERVE_PLACEHOLDER) == 0)
            return error.SplitFailed;

        const lo = MapViewOfFile3(section.?, null, placeholder.?, 0, byte_len, MEM_REPLACE_PLACEHOLDER, PAGE_READWRITE, null, 0);
        if (lo == null) return error.MapFailed;
        errdefer _ = UnmapViewOfFileEx(lo.?, 0);

        const hi_addr: *anyopaque = @ptrFromInt(@intFromPtr(placeholder.?) + byte_len);
        const hi = MapViewOfFile3(section.?, null, hi_addr, 0, byte_len, MEM_REPLACE_PLACEHOLDER, PAGE_READWRITE, null, 0);
        if (hi == null) return error.MapFailed;

        return .{ .section = section.?, .base = base[0 .. byte_len * 2] };
    }

    pub fn deinit(self: *WindowsBacking) void {
        const half = self.base.len / 2;
        _ = UnmapViewOfFileEx(self.base.ptr, 0);
        _ = UnmapViewOfFileEx(self.base.ptr + half, 0);
        _ = windows.CloseHandle(self.section);
    }

    const PAGE_NOACCESS: windows.DWORD = 0x01;
    const PAGE_READWRITE: windows.DWORD = 0x04;
    const MEM_RESERVE: windows.DWORD = 0x2000;
    const MEM_RELEASE: windows.DWORD = 0x8000;
    const MEM_RESERVE_PLACEHOLDER: windows.DWORD = 0x0004_0000;
    const MEM_REPLACE_PLACEHOLDER: windows.DWORD = 0x0000_4000;
    const MEM_PRESERVE_PLACEHOLDER: windows.DWORD = 0x0000_0002;

    extern "kernel32" fn CreateFileMappingW(
        hFile: ?windows.HANDLE,
        lpAttributes: ?*anyopaque,
        flProtect: windows.DWORD,
        dwMaximumSizeHigh: windows.DWORD,
        dwMaximumSizeLow: windows.DWORD,
        lpName: ?windows.LPCWSTR,
    ) callconv(.winapi) ?windows.HANDLE;

    extern "api-ms-win-core-memory-l1-1-6" fn VirtualAlloc2(
        Process: ?windows.HANDLE,
        BaseAddress: ?*anyopaque,
        Size: usize,
        AllocationType: windows.DWORD,
        PageProtection: windows.DWORD,
        ExtendedParameters: ?*anyopaque,
        ParameterCount: windows.DWORD,
    ) callconv(.winapi) ?*anyopaque;

    extern "api-ms-win-core-memory-l1-1-6" fn MapViewOfFile3(
        FileMapping: windows.HANDLE,
        Process: ?windows.HANDLE,
        BaseAddress: ?*anyopaque,
        Offset: u64,
        ViewSize: usize,
        AllocationType: windows.DWORD,
        PageProtection: windows.DWORD,
        ExtendedParameters: ?*anyopaque,
        ParameterCount: windows.DWORD,
    ) callconv(.winapi) ?*anyopaque;

    extern "kernel32" fn VirtualFree(
        lpAddress: *anyopaque,
        dwSize: usize,
        dwFreeType: windows.DWORD,
    ) callconv(.winapi) c_int;

    extern "kernel32" fn UnmapViewOfFileEx(
        BaseAddress: *anyopaque,
        UnmapFlags: windows.ULONG,
    ) callconv(.winapi) c_int;
};

test "slice wraps contiguously across the mirror boundary" {
    const page = std.heap.pageSize();
    var buf = try @This().init(page);
    defer buf.deinit();

    try std.testing.expectEqual(page, buf.len());

    for (buf.data(), 0..) |*b, i| b.* = @truncate(i);

    const straddle = buf.slice(page - 3, 6);
    try std.testing.expectEqual(@as(u8, @truncate(page - 3)), straddle[0]);
    try std.testing.expectEqual(@as(u8, @truncate(page - 1)), straddle[2]);
    try std.testing.expectEqual(@as(u8, 0), straddle[3]); // wrapped to index 0
    try std.testing.expectEqual(@as(u8, 2), straddle[5]);

    const w = buf.slice(page - 2, 4);
    w[0] = 0xAA;
    w[1] = 0xBB;
    w[2] = 0xCC; // index 0 via mirror
    w[3] = 0xDD; // index 1 via mirror
    try std.testing.expectEqual(@as(u8, 0xCC), buf.data()[0]);
    try std.testing.expectEqual(@as(u8, 0xDD), buf.data()[1]);
    try std.testing.expectEqual(@as(u8, 0xAA), buf.data()[page - 2]);
    try std.testing.expectEqual(@as(u8, 0xBB), buf.data()[page - 1]);
}
