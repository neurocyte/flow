const std = @import("std");
const win32 = @import("win32").everything;

// todo: these should be available in zigwin32
fn xFromLparam(lparam: win32.LPARAM) i16 {
    return @bitCast(win32.loword(lparam));
}
fn yFromLparam(lparam: win32.LPARAM) i16 {
    return @bitCast(win32.hiword(lparam));
}
pub fn pointFromLparam(lparam: win32.LPARAM) win32.POINT {
    return win32.POINT{ .x = xFromLparam(lparam), .y = yFromLparam(lparam) };
}

// TODO: update zigwin32 with a way to get the corresponding IID for any COM interface
pub fn queryInterface(obj: anytype, comptime Interface: type) *Interface {
    const obj_basename_start: usize = comptime if (std.mem.lastIndexOfScalar(u8, @typeName(@TypeOf(obj)), '.')) |i| (i + 1) else 0;
    const obj_basename = @typeName(@TypeOf(obj))[obj_basename_start..];
    const iface_basename_start: usize = comptime if (std.mem.lastIndexOfScalar(u8, @typeName(Interface), '.')) |i| (i + 1) else 0;
    const iface_basename = @typeName(Interface)[iface_basename_start..];

    const iid_name = "IID_" ++ iface_basename;
    const iid = @field(win32, iid_name);

    var iface: *Interface = undefined;
    const hr = obj.IUnknown.QueryInterface(iid, @ptrCast(&iface));
    if (hr < 0) std.debug.panic(
        "QueryInferface on " ++ obj_basename ++ " as " ++ iface_basename ++ " failed, hresult={}",
        .{@as(u32, @bitCast(hr))},
    );
    return iface;
}
