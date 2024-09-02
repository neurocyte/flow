const std = @import("std");
const Allocator = std.mem.Allocator;
const tp = @import("thespian");
const tracy = @import("tracy");

const Plane = @import("renderer").Plane;
const utils = @import("renderer").input.utils;
const key_ = @import("renderer").input.key;
const event_type = @import("renderer").input.event_type;

const Widget = @import("../Widget.zig");
const command = @import("../command.zig");
const tui = @import("../tui.zig");
const EventHandler = @import("../EventHandler.zig");

const history = 8;

plane: Plane,
frame: u64 = 0,
idle_frame: u64 = 0,
key_active_frame: u64 = 0,
wipe_after_frames: i64 = 60,
hover: bool = false,

keys: [history]Key = [_]Key{.{}} ** history,

const Key = struct { id: u32 = 0, mod: u32 = 0 };

const Self = @This();

const idle_msg = "🐶";
pub const width = idle_msg.len + 20;

pub fn create(allocator: Allocator, parent: Plane, _: ?Widget.EventHandler) @import("widget.zig").CreateError!Widget {
    var frame_rate = tp.env.get().num("frame-rate");
    if (frame_rate == 0) frame_rate = 60;
    const self: *Self = try allocator.create(Self);
    self.* = .{
        .plane = try Plane.init(&(Widget.Box{}).opts(@typeName(Self)), parent),
        .wipe_after_frames = @divTrunc(frame_rate, 2),
    };
    try tui.current().input_listeners.add(EventHandler.bind(self, listen));
    return self.widget();
}

pub fn widget(self: *Self) Widget {
    return Widget.to(self);
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    tui.current().input_listeners.remove_ptr(self);
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn layout(_: *Self) Widget.Layout {
    return .{ .static = width };
}

fn render_active(self: *Self) bool {
    var c: usize = 0;
    for (self.keys) |k| {
        if (k.id == 0)
            return true;
        if (c > 0)
            _ = self.plane.putstr(" ") catch {};
        if (utils.isSuper(k.mod))
            _ = self.plane.putstr("H-") catch {};
        if (utils.isCtrl(k.mod))
            _ = self.plane.putstr("C-") catch {};
        if (utils.isShift(k.mod))
            _ = self.plane.putstr("S-") catch {};
        if (utils.isAlt(k.mod))
            _ = self.plane.putstr("A-") catch {};
        _ = self.plane.print("{s}", .{utils.key_id_string(k.id)}) catch {};
        c += 1;
    }
    return true;
}

const idle_spinner = [_][]const u8{ "🞻", "✳", "🞼", "🞽", "🞾", "🞿", "🞾", "🞽", "🞼", "✳" };

fn render_idle(self: *Self) bool {
    self.idle_frame += 1;
    if (self.idle_frame > 180) {
        return self.animate();
    } else {
        const i = @mod(self.idle_frame / 8, idle_spinner.len);
        _ = self.plane.print_aligned_center(0, "{s} {s} {s}", .{ idle_spinner[@intCast(i)], idle_msg, idle_spinner[@intCast(i)] }) catch {};
    }
    return true;
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    const frame = tracy.initZone(@src(), .{ .name = @typeName(@This()) ++ " render" });
    defer frame.deinit();
    self.plane.set_base_style(" ", if (self.hover) theme.statusbar_hover else theme.statusbar);
    self.frame += 1;
    if (self.frame - self.key_active_frame > self.wipe_after_frames)
        self.unset_key_all();

    self.plane.erase();
    self.plane.home();
    return if (self.keys[0].id > 0) self.render_active() else self.render_idle();
}

fn set_nkey(self: *Self, key: Key) void {
    for (self.keys, 0..) |k, i| {
        if (k.id == 0) {
            self.keys[i].id = key.id;
            self.keys[i].mod = key.mod;
            return;
        }
    }
    for (self.keys, 0.., 1..) |_, i, j| {
        if (j < self.keys.len)
            self.keys[i] = self.keys[j];
    }
    self.keys[self.keys.len - 1].id = key.id;
    self.keys[self.keys.len - 1].mod = key.mod;
}

fn unset_nkey_(self: *Self, key: u32) void {
    for (self.keys, 0..) |k, i| {
        if (k.id == key) {
            for (i..self.keys.len, (i + 1)..) |i_, j| {
                if (j < self.keys.len)
                    self.keys[i_] = self.keys[j];
            }
            self.keys[self.keys.len - 1].id = 0;
            return;
        }
    }
}

const upper_offset: u32 = 'a' - 'A';
fn unset_nkey(self: *Self, key: Key) void {
    self.unset_nkey_(key.id);
    if (key.id >= 'a' and key.id <= 'z')
        self.unset_nkey_(key.id - upper_offset);
    if (key.id >= 'A' and key.id <= 'Z')
        self.unset_nkey_(key.id + upper_offset);
}

fn unset_key_all(self: *Self) void {
    for (0..self.keys.len) |i| {
        self.keys[i].id = 0;
        self.keys[i].mod = 0;
    }
}

fn set_key(self: *Self, key: Key, val: bool) void {
    self.idle_frame = 0;
    self.key_active_frame = self.frame;
    (if (val) &set_nkey else &unset_nkey)(self, key);
}

pub fn listen(self: *Self, _: tp.pid_ref, m: tp.message) tp.result {
    var key: u32 = 0;
    var mod: u32 = 0;
    if (try m.match(.{ "I", event_type.PRESS, tp.extract(&key), tp.any, tp.any, tp.extract(&mod), tp.more })) {
        self.set_key(.{ .id = key, .mod = mod }, true);
    } else if (try m.match(.{ "I", event_type.RELEASE, tp.extract(&key), tp.any, tp.any, tp.extract(&mod), tp.more })) {
        self.set_key(.{ .id = key, .mod = mod }, false);
    }
}

pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (try m.match(.{ "B", event_type.PRESS, key_.BUTTON1, tp.any, tp.any, tp.any, tp.any, tp.any })) {
        command.executeName("toggle_inputview", .{}) catch {};
        return true;
    }
    if (try m.match(.{ "H", tp.extract(&self.hover) })) {
        tui.current().rdr.request_mouse_cursor_pointer(self.hover);
        return true;
    }

    return false;
}

fn animate(self: *Self) bool {
    const positions = eighths_c * (width - 1);
    const frame = @mod(self.frame, positions * 2);
    const pos = if (frame > eighths_c * (width - 1))
        positions * 2 - frame
    else
        frame;

    smooth_block_at(&self.plane, pos);
    return false;
    // return pos != 0;
}

const eighths_l = [_][]const u8{ "█", "▉", "▊", "▋", "▌", "▍", "▎", "▏" };
const eighths_r = [_][]const u8{ " ", "▕", "🮇", "🮈", "▐", "🮉", "🮊", "🮋" };
const eighths_c = eighths_l.len;

fn smooth_block_at(plane: *Plane, pos: u64) void {
    const blk: u32 = @intCast(@mod(pos, eighths_c) + 1);
    const l = eighths_l[eighths_c - blk];
    const r = eighths_r[eighths_c - blk];
    plane.erase();
    plane.cursor_move_yx(0, @as(c_int, @intCast(@divFloor(pos, eighths_c)))) catch return;
    _ = plane.putstr(@ptrCast(r)) catch return;
    _ = plane.putstr(@ptrCast(l)) catch return;
}
