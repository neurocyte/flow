const std = @import("std");
const root = @import("root");
const cbor = @import("cbor");
const log = @import("log");
const Style = @import("theme").Style;
const Color = @import("theme").Color;
const ColorScheme = @import("theme").Type;
pub const vaxis = @import("vaxis");
const input = @import("input");
const builtin = @import("builtin");
const RGB = @import("color").RGB;

pub const Plane = @import("Plane.zig");
pub const Layer = @import("Layer.zig");
pub const Cell = @import("Cell.zig");
pub const CursorShape = vaxis.Cell.CursorShape;
pub const MouseCursorShape = vaxis.Mouse.Shape;

pub const style = @import("style.zig").StyleBits;
pub const styles = @import("style.zig");
pub const GraphemeCache = @import("GraphemeCache.zig");

const Self = @This();
pub const log_name = "vaxis";

allocator: std.mem.Allocator,

tty: vaxis.Tty,
vx: vaxis.Vaxis,
tty_buffer: []u8,
cache_storage: *GraphemeCache.Storage,
targets: std.ArrayList(Layer.Target) = .empty,

no_alternate: bool,
config_enable_terminal_cursor: bool,
cursor_color: RGB = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF },
secondary_color: RGB = .{ .r = 0x80, .g = 0x80, .b = 0x80 },
enable_sgr_pixel_mode_support: bool = true,
event_buffer: std.Io.Writer.Allocating,
input_buffer: std.Io.Writer.Allocating,
mods: vaxis.Key.Modifiers = .{},
queries_done: bool,

bracketed_paste: bool = false,
bracketed_paste_buffer: std.Io.Writer.Allocating,

handler_ctx: *anyopaque,
dispatch_input: ?*const fn (ctx: *anyopaque, cbor_msg: []const u8) void = null,
dispatch_mouse: ?*const fn (ctx: *anyopaque, y: i32, x: i32, cbor_msg: []const u8) void = null,
dispatch_mouse_drag: ?*const fn (ctx: *anyopaque, y: i32, x: i32, cbor_msg: []const u8) void = null,
dispatch_event: ?*const fn (ctx: *anyopaque, cbor_msg: []const u8) void = null,

logger: log.Logger,

loop: Loop,

pub const Error = error{
    UnexpectedRendererEvent,
    OutOfMemory,
    IntegerTooLarge,
    IntegerTooSmall,
    InvalidType,
    TooShort,
    Utf8CannotEncodeSurrogateHalf,
    CodepointTooLarge,
    TtyInitError,
    TtyWriteError,
    InvalidFloatType,
    InvalidArrayType,
    InvalidPIntType,
    JsonIncompatibleType,
    NotAnObject,
    BadArrayAllocExtract,
    InvalidMapType,
    InvalidUnion,
    WriteFailed,
} || std.Thread.SpawnError;

pub fn init(allocator: std.mem.Allocator, handler_ctx: *anyopaque, no_alternate: bool, enable_terminal_cursor: bool, _: *const fn (ctx: *anyopaque) void) Error!Self {
    const opts: vaxis.Vaxis.Options = .{
        .kitty_keyboard_flags = .{
            .disambiguate = true,
            .report_events = true,
            .report_alternate_keys = true,
            .report_all_as_ctl_seqs = true,
            .report_text = true,
        },
        .system_clipboard_allocator = allocator,
    };
    const tty_buffer = try allocator.alloc(u8, 4096);
    return .{
        .allocator = allocator,
        .tty = vaxis.Tty.init(root.get_io(), tty_buffer) catch |e| {
            var stderr_buffer: [1024]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writer(std.Options.debug_io, &stderr_buffer);
            stderr_writer.interface.print("\n" ++ root.application_name ++ " ERROR: {s}\n", .{@errorName(e)}) catch {};
            stderr_writer.flush() catch {};
            return error.TtyInitError;
        },
        .tty_buffer = tty_buffer,
        .cache_storage = try allocator.create(GraphemeCache.Storage),
        .vx = try vaxis.init(root.get_io(), allocator, root.get_init().environ_map, opts),
        .no_alternate = no_alternate,
        .config_enable_terminal_cursor = enable_terminal_cursor,
        .event_buffer = .init(allocator),
        .input_buffer = .init(allocator),
        .bracketed_paste_buffer = .init(allocator),
        .handler_ctx = handler_ctx,
        .logger = log.logger(log_name),
        .loop = undefined,
        .queries_done = false,
    };
}

pub fn deinit(self: *Self) void {
    self.allocator.destroy(self.cache_storage);
    panic_cleanup = null;
    self.loop.stop();
    self.vx.deinit(self.allocator, self.tty.writer());
    self.tty.deinit();
    self.allocator.free(self.tty_buffer);
    self.bracketed_paste_buffer.deinit();
    self.input_buffer.deinit();
    self.event_buffer.deinit();
    self.targets.deinit(self.allocator);
}

pub fn submit_layer(self: *Self, target: Layer.Target) Layer.Handle {
    const handle: Layer.Handle = @enumFromInt(self.targets.items.len);
    if (target.parent) |p| std.debug.assert(@intFromEnum(p) < @intFromEnum(handle));
    resolve_layer_origin(self.stdplane(), &target.src.surface, target, self.targets.items);
    self.targets.append(self.allocator, target) catch |e| switch (e) {
        error.OutOfMemory => @panic("OOM vaxis.submit_layer"),
    };
    return handle;
}

fn resolve_layer_origin(std_plane: Plane, surface: *Layer.Surface, target: Layer.Target, prior_targets: []const Layer.Target) void {
    const cw = std_plane.cell_x();
    const ch = std_plane.cell_y();
    var dst_x: i32 = 0;
    var dst_y: i32 = 0;
    if (target.parent) |h| {
        const parent_layer = prior_targets[@intFromEnum(h)].src;
        dst_x, dst_y = parent_layer.global_origin_px();
    }
    surface.origin_px_x = dst_x + target.x * cw + @as(i32, target.xoffset);
    surface.origin_px_y = dst_y + target.y * ch + @as(i32, target.yoffset);
}

var in_panic: std.atomic.Value(bool) = .init(false);
var panic_cleanup: ?struct {
    allocator: std.mem.Allocator,
    tty: *vaxis.Tty,
    vx: *vaxis.Vaxis,
} = null;

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    in_panic.store(true, .release);
    const cleanup = panic_cleanup;
    panic_cleanup = null;
    if (cleanup) |self| {
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
    }
    return std.debug.defaultPanic(msg, ret_addr orelse @returnAddress());
}

pub fn panic_in_progress() bool {
    return in_panic.load(.acquire);
}

pub fn install_crash_handler() void {
    if (!std.debug.have_segfault_handling_support) {
        @compileError("segfault handler not supported for this target");
    }
    const act = std.posix.Sigaction{
        .handler = .{ .sigaction = handle_crash },
        .mask = std.posix.sigemptyset(),
        .flags = (std.posix.SA.SIGINFO | std.posix.SA.RESTART),
    };

    std.posix.sigaction(std.posix.SIG.BUS, &act, null);
    std.posix.sigaction(std.posix.SIG.SEGV, &act, null);
    std.posix.sigaction(std.posix.SIG.ABRT, &act, null);
    std.posix.sigaction(std.posix.SIG.FPE, &act, null);
    std.posix.sigaction(std.posix.SIG.ILL, &act, null);
}

pub var jit_debugger_enabled: bool = false;

fn handle_crash(sig: std.posix.SIG, info: *const std.posix.siginfo_t, ctx_ptr: ?*anyopaque) callconv(.c) void {
    const debug = @import("std/debug.zig");
    debug.lockStdErr();

    if (panic_in_progress())
        std.c.abort();

    in_panic.store(true, .release);
    const cleanup = panic_cleanup;
    panic_cleanup = null;

    if (cleanup) |self| {
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
    }
    if (builtin.os.tag == .linux and jit_debugger_enabled) {
        var buf: [4096]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(std.Options.debug_io, &buf);
        defer stderr.flush() catch {};
        handleSegfaultPosixNoAbort(&stderr.interface, sig, info, ctx_ptr);
        @import("thespian").sighdl_debugger(@as(c_int, @intCast(@intFromEnum(sig))), @ptrCast(@constCast(info)), ctx_ptr);
        std.c.abort();
    } else {
        debug.handleSegfaultPosix(sig, info, ctx_ptr);
    }
}

fn handleSegfaultPosixNoAbort(stderr: *std.Io.Writer, sig: std.posix.SIG, info: *const std.posix.siginfo_t, ctx_ptr: ?*anyopaque) void {
    const debug = @import("std/debug.zig");
    debug.resetSegfaultHandler();
    const addr = switch (builtin.os.tag) {
        .linux => @intFromPtr(info.fields.sigfault.addr),
        .freebsd, .macos => @intFromPtr(info.addr),
        .netbsd => @intFromPtr(info.info.reason.fault.addr),
        .openbsd => @intFromPtr(info.data.fault.addr),
        .illumos => @intFromPtr(info.reason.fault.addr),
        else => unreachable,
    };
    const code = if (builtin.os.tag == .netbsd) info.info.code else info.code;
    debug.dumpSegfaultInfoPosix(stderr, sig, code, addr, ctx_ptr);
}

pub fn run(self: *Self, render_pid: ?@import("thespian").pid_ref) Error!void {
    _ = render_pid;
    self.vx.sgr = .legacy;
    self.vx.enable_workarounds = true;

    Layer.set_root_caps(&self.vx.caps);

    panic_cleanup = .{ .allocator = self.allocator, .tty = &self.tty, .vx = &self.vx };
    if (!self.no_alternate) self.vx.enterAltScreen(self.tty.writer()) catch return error.TtyWriteError;
    if (builtin.os.tag == .windows) {
        try self.resize(.{ .rows = 25, .cols = 80, .x_pixel = 0, .y_pixel = 0 }); // dummy resize to fully init vaxis
    } else {
        self.sigwinch() catch return error.TtyWriteError;
    }
    self.vx.setBracketedPaste(self.tty.writer(), true) catch return error.TtyWriteError;
    self.vx.queryTerminalSend(self.tty.writer()) catch return error.TtyWriteError;

    if (!self.config_enable_terminal_cursor)
        self.tty.writer().writeAll(vaxis.ctlseqs.hide_cursor) catch return error.TtyWriteError;

    self.loop = Loop.init(&self.tty, &self.vx);
    try self.loop.start();
}

fn draw_target(target: *const Layer.Target) void {
    if (target.x >= target.dst.width) return;
    if (target.y >= target.dst.height) return;

    const src_y = 0;
    const src_x = 0;
    const src_h: usize = target.src.screen.height;
    const src_w = target.src.screen.width;

    const dst_dim_y: i32 = @intCast(target.dst.height);
    const dst_dim_x: i32 = @intCast(target.dst.width);
    const dst_y = target.y;
    const dst_x = target.x;
    const dst_w = @min(src_w, dst_dim_x - dst_x);

    for (src_y..src_h) |src_row_| {
        const src_row: i32 = @intCast(src_row_);
        const src_row_offset = src_row * src_w;
        const dst_row_offset = (dst_y + src_row) * target.dst.screen.width;
        if (dst_y + src_row >= dst_dim_y) return;
        @memcpy(
            target.dst.screen.buf[@intCast(dst_row_offset + dst_x)..@intCast(dst_row_offset + dst_x + dst_w)],
            target.src.screen.buf[@intCast(src_row_offset + src_x)..@intCast(src_row_offset + dst_w)],
        );
    }
}

pub fn render(self: *Self) !?i64 {
    if (in_panic.load(.acquire)) return null;
    const order = build_draw_order(self.allocator, self.targets.items);
    defer self.allocator.free(order);
    for (order) |idx| draw_target(&self.targets.items[idx]);

    self.downgrade_cursor_shape();
    if (self.config_enable_terminal_cursor) {
        self.paint_unfocused_cell_cursors();
        self.propagate_focused_cursors_to_root();
    } else {
        self.paint_all_cell_cursors();
    }

    self.targets.clearRetainingCapacity();
    try self.vx.render(self.tty.writer());
    try self.tty.writer().flush();
    return null;
}

fn build_draw_order(allocator: std.mem.Allocator, targets: []const Layer.Target) []u32 {
    const order = allocator.alloc(u32, targets.len) catch @panic("OOM vaxis.build_draw_order");
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u32, order, targets, struct {
        fn lt(t: []const Layer.Target, a: u32, b: u32) bool {
            if (t[a].z_index != t[b].z_index) return @intFromEnum(t[a].z_index) < @intFromEnum(t[b].z_index);
            return a > b;
        }
    }.lt);
    return order;
}

fn downgrade_cursor_shape(self: *Self) void {
    if (self.vx.caps.multi_cursor) return;
    for (self.targets.items) |*t| {
        const src = &t.src.screen;
        if (src.cursor_secondary.len == 0) continue;
        src.cursor_shape = switch (src.cursor_shape) {
            .beam => .block,
            .beam_blink => .block_blink,
            .underline => .block,
            .underline_blink => .block_blink,
            else => src.cursor_shape,
        };
    }
}

fn cursor_root_pos(self: *Self, src_row: u16, src_col: u16, surface: *const Layer.Surface) ?struct { row: u16, col: u16 } {
    const std_plane = self.stdplane();
    const cw = std_plane.cell_x();
    const ch = std_plane.cell_y();
    const dst_x_cells = @divFloor(surface.origin_px_x, cw);
    const dst_y_cells = @divFloor(surface.origin_px_y, ch);
    const r = dst_y_cells + @as(i32, @intCast(src_row));
    const c = dst_x_cells + @as(i32, @intCast(src_col));
    const scr = &self.vx.screen;
    if (r < 0 or c < 0) return null;
    if (r >= scr.height or c >= scr.width) return null;
    return .{ .row = @intCast(r), .col = @intCast(c) };
}

fn propagate_focused_cursors_to_root(self: *Self) void {
    const scr = &self.vx.screen;
    for (self.targets.items) |*t| {
        const src = &t.src.screen;
        if (!src.cursor_vis) continue;
        if (src.cursor_shape == .unfocused) continue;
        const pos = self.cursor_root_pos(src.cursor.row, src.cursor.col, &t.src.surface) orelse continue;
        scr.cursor_vis = true;
        scr.cursor.row = pos.row;
        scr.cursor.col = pos.col;
        scr.cursor_shape = src.cursor_shape;

        self.allocator.free(scr.cursor_secondary);
        scr.cursor_secondary = &.{};
        if (src.cursor_secondary.len == 0) continue;
        if (self.vx.caps.multi_cursor) {
            const grown = self.allocator.alloc(@TypeOf(scr.cursor_secondary[0]), src.cursor_secondary.len) catch continue;
            scr.cursor_secondary = grown;
            for (src.cursor_secondary, 0..) |sc, i| {
                const spos = self.cursor_root_pos(sc.row, sc.col, &t.src.surface) orelse {
                    scr.cursor_secondary[i] = .{ .row = 0, .col = 0 };
                    continue;
                };
                scr.cursor_secondary[i] = .{ .row = spos.row, .col = spos.col };
            }
        } else {
            for (src.cursor_secondary) |sc|
                if (self.cursor_root_pos(sc.row, sc.col, &t.src.surface)) |spos|
                    self.paint_solid_cell(spos.row, spos.col, self.secondary_color);
        }
    }
}

fn paint_unfocused_cell_cursors(self: *Self) void {
    for (self.targets.items) |*t| {
        const src = &t.src.screen;
        if (!src.cursor_vis) continue;
        if (src.cursor_shape != .unfocused) continue;
        if (self.cursor_root_pos(src.cursor.row, src.cursor.col, &t.src.surface)) |pos|
            self.paint_dim_cell(pos.row, pos.col, self.cursor_color);
        for (src.cursor_secondary) |sc|
            if (self.cursor_root_pos(sc.row, sc.col, &t.src.surface)) |spos|
                self.paint_dim_cell(spos.row, spos.col, self.secondary_color);
    }
    const scr = &self.vx.screen;
    if (scr.cursor_vis and scr.cursor_shape == .unfocused) {
        self.paint_dim_cell(scr.cursor.row, scr.cursor.col, self.cursor_color);
        for (scr.cursor_secondary) |sc|
            self.paint_dim_cell(sc.row, sc.col, self.secondary_color);
        scr.cursor_vis = false;
        self.allocator.free(scr.cursor_secondary);
        scr.cursor_secondary = &.{};
    }
}

fn paint_all_cell_cursors(self: *Self) void {
    for (self.targets.items) |*t| {
        const src = &t.src.screen;
        if (!src.cursor_vis) continue;
        const dim_primary = src.cursor_shape == .unfocused;
        if (self.cursor_root_pos(src.cursor.row, src.cursor.col, &t.src.surface)) |pos| {
            if (dim_primary)
                self.paint_dim_cell(pos.row, pos.col, self.cursor_color)
            else
                self.paint_solid_cell(pos.row, pos.col, self.cursor_color);
        }
        for (src.cursor_secondary) |sc|
            if (self.cursor_root_pos(sc.row, sc.col, &t.src.surface)) |spos|
                self.paint_dim_cell(spos.row, spos.col, self.secondary_color);
    }
    self.vx.screen.cursor_vis = false;
}

fn paint_solid_cell(self: *Self, row: u16, col: u16, color: RGB) void {
    const scr = &self.vx.screen;
    var cell = scr.readCell(col, row) orelse return;
    const old_bg = cell.style.bg;
    cell.style.bg = .{ .rgb = .{ color.r, color.g, color.b } };
    cell.style.fg = old_bg;
    cell.style.reverse = false;
    scr.writeCell(col, row, cell);
}

fn paint_dim_cell(self: *Self, row: u16, col: u16, color: RGB) void {
    const scr = &self.vx.screen;
    var cell = scr.readCell(col, row) orelse return;
    cell.style.bg = switch (cell.style.bg) {
        .rgb => |bg| .{ .rgb = .{
            @intCast((@as(u16, color.r) + @as(u16, bg[0])) / 2),
            @intCast((@as(u16, color.g) + @as(u16, bg[1])) / 2),
            @intCast((@as(u16, color.b) + @as(u16, bg[2])) / 2),
        } },
        else => .{ .rgb = .{ color.r, color.g, color.b } },
    };
    scr.writeCell(col, row, cell);
}

pub fn sigwinch(self: *Self) !void {
    if (builtin.os.tag == .windows or self.vx.state.in_band_resize) return;
    try self.resize(try self.tty.getWinsize());
}

fn resize(self: *Self, ws: vaxis.Winsize) error{ TtyWriteError, OutOfMemory, WriteFailed }!void {
    self.vx.resize(self.allocator, self.tty.writer(), ws) catch return error.TtyWriteError;
    self.vx.queueRefresh();
    if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{"resize"}));
}

pub fn stop(self: *Self) void {
    _ = self;
}

pub fn stdplane(self: *Self) Plane {
    const name = "root";
    var plane: Plane = .{
        .window = self.vx.window(),
        .cache = self.cache_storage.cache(),
        .name_buf = undefined,
        .name_len = name.len,
    };
    @memcpy(plane.name_buf[0..name.len], name);
    return plane;
}

pub fn input_fd_blocking(self: Self) std.posix.fd_t {
    return self.tty.fd.handle;
}

pub fn process_renderer_event(self: *Self, msg: []const u8) Error!void {
    var input_: []const u8 = undefined;
    var text_: []const u8 = undefined;
    if (!try cbor.match(msg, .{ "RDR", cbor.extract(&input_), cbor.extract(&text_) }))
        return error.UnexpectedRendererEvent;
    const text = if (text_.len > 0) text_ else null;
    const event = std.mem.bytesAsValue(vaxis.Event, input_);
    switch (event.*) {
        .key_press => |key__| {
            // Check for a cursor position response for our explicit width query. This will
            // always be an F3 key with shift = true, and we must be looking for queries
            if (key__.codepoint == vaxis.Key.f3 and key__.mods.shift and !self.queries_done) {
                self.logger.print("explicit width capability detected", .{});
                self.vx.caps.explicit_width = true;
                self.vx.caps.unicode = .unicode;
                self.vx.screen.width_method = .unicode;
                return;
            }
            // Check for a cursor position response for our scaled text query. This will
            // always be an F3 key with alt = true, and we must be looking for queries
            if (key__.codepoint == vaxis.Key.f3 and key__.mods.alt and !self.queries_done) {
                self.logger.print("scaled text capability detected", .{});
                self.vx.caps.scaled_text = true;
                return;
            }
            const key_ = filter_mods(normalize_shifted_alphas(key__));
            try self.sync_mod_state(key_.codepoint, key_.mods);
            const cbor_msg = try self.fmtmsg(.{
                "I",
                input.event.press,
                key_.codepoint,
                key_.shifted_codepoint orelse key_.codepoint,
                text orelse "",
                @as(u8, @bitCast(key_.mods)),
            });
            if (self.bracketed_paste and self.handle_bracketed_paste_input(cbor_msg) catch |e| return self.handle_bracketed_paste_error(e)) {
                // we have stored it to handle on .paste_end, so do nothing more here
            } else if (self.dispatch_input) |f| f(self.handler_ctx, cbor_msg);
        },
        .key_release => |key__| {
            const key_ = filter_mods(normalize_shifted_alphas(key__));
            const cbor_msg = try self.fmtmsg(.{
                "I",
                input.event.release,
                key_.codepoint,
                key_.shifted_codepoint orelse key_.codepoint,
                text orelse "",
                @as(u8, @bitCast(key_.mods)),
            });
            if (self.bracketed_paste) {} else if (self.dispatch_input) |f| f(self.handler_ctx, cbor_msg);
        },
        .mouse => |mouse__| {
            var mouse_ = mouse__;
            if (self.vx.state.pixel_mouse) {
                // translate back to 0,0 coords
                // vaxis translates SGR pixel mode's 1,1 origin coords to 0,0 origin coords,
                // but we translate them back because our preferred terminals (kitty and ghostty)
                // actually send 0,0 origin coordinates
                mouse_.col += 1;
                mouse_.row += 1;
            }

            const mouse = self.vx.translateMouse(mouse_);
            try self.sync_mod_state(0, .{ .ctrl = mouse.mods.ctrl, .shift = mouse.mods.shift, .alt = mouse.mods.alt });
            if (self.dispatch_mouse) |f| switch (mouse.type) {
                .motion => f(self.handler_ctx, @intCast(mouse.row), @intCast(mouse.col), try self.fmtmsg(.{
                    "M",
                    mouse.col,
                    mouse.row,
                    mouse.xoffset,
                    mouse.yoffset,
                })),
                .press => f(self.handler_ctx, @intCast(mouse.row), @intCast(mouse.col), try self.fmtmsg(.{
                    "B",
                    input.event.press,
                    @intFromEnum(mouse.button),
                    input.utils.button_id_string(mouse.button),
                    mouse.col,
                    mouse.row,
                    mouse.xoffset,
                    mouse.yoffset,
                })),
                .release => f(self.handler_ctx, @intCast(mouse.row), @intCast(mouse.col), try self.fmtmsg(.{
                    "B",
                    input.event.release,
                    @intFromEnum(mouse.button),
                    input.utils.button_id_string(mouse.button),
                    mouse.col,
                    mouse.row,
                    mouse.xoffset,
                    mouse.yoffset,
                })),
                .drag => if (self.dispatch_mouse_drag) |f_|
                    f_(self.handler_ctx, @intCast(mouse.row), @intCast(mouse.col), try self.fmtmsg(.{
                        "D",
                        input.event.press,
                        @intFromEnum(mouse.button),
                        input.utils.button_id_string(mouse.button),
                        mouse.col,
                        mouse.row,
                        mouse.xoffset,
                        mouse.yoffset,
                    })),
            };
        },
        .mouse_leave => {
            if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{"mouse_leave"}));
        },
        .focus_in => {
            if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{"focus_in"}));
        },
        .focus_out => {
            if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{"focus_out"}));
        },
        .paste_start => try self.handle_bracketed_paste_start(),
        .paste_end => try self.handle_bracketed_paste_end(),
        .paste => {
            if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{ "system_clipboard", text }));
        },
        .color_report => {},
        .color_scheme => |scheme| {
            if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{ "color_scheme", scheme }));
        },
        .winsize => |ws| {
            if (!self.vx.state.in_band_resize) {
                self.vx.state.in_band_resize = true;
                self.logger.print("in band resize capability detected", .{});
            }
            try self.resize(ws);
        },

        .cap_unicode => {
            self.logger.print("unicode capability detected", .{});
            self.vx.caps.unicode = .unicode;
            self.vx.screen.width_method = .unicode;
        },
        .cap_sgr_pixels => {
            self.logger.print("pixel mouse capability detected", .{});
            self.vx.caps.sgr_pixels = self.enable_sgr_pixel_mode_support;
        },
        .cap_da1 => {
            self.queries_done = true;
            self.vx.enableDetectedFeatures(self.tty.writer()) catch |e| self.logger.err("enable features", e);
            self.vx.setMouseMode(self.tty.writer(), true) catch return error.TtyWriteError;
            self.logger.print("capability queries complete", .{});
            if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{"capability_detection_complete"}));
        },
        .cap_kitty_keyboard => {
            self.logger.print("kitty keyboard capability detected", .{});
            self.vx.caps.kitty_keyboard = true;
        },
        .cap_kitty_graphics => {
            if (!self.vx.caps.kitty_graphics) {
                self.vx.caps.kitty_graphics = true;
            }
        },
        .cap_rgb => {
            self.logger.print("rgb capability detected", .{});
            self.vx.caps.rgb = true;
        },
        .cap_color_scheme_updates => {
            self.logger.print("color scheme updates capability detected", .{});
            self.vx.caps.color_scheme_updates = true;
            self.vx.subscribeToColorSchemeUpdates(self.tty.writer()) catch return error.TtyWriteError;
        },
        .cap_multi_cursor => {
            self.logger.print("multi cursor capability detected", .{});
            self.vx.caps.multi_cursor = true;
        },
    }
}

fn fmtmsg(self: *Self, value: anytype) std.Io.Writer.Error![]const u8 {
    self.event_buffer.clearRetainingCapacity();
    try cbor.writeValue(&self.event_buffer.writer, value);
    return self.event_buffer.written();
}

fn handle_bracketed_paste_input(self: *Self, cbor_msg: []const u8) !bool {
    var keypress: input.Key = undefined;
    var egc_: input.Key = undefined;
    var mods: usize = undefined;
    var text: []const u8 = undefined;
    const writer = &self.bracketed_paste_buffer.writer;
    if (try cbor.match(cbor_msg, .{ "I", cbor.number, cbor.extract(&keypress), cbor.extract(&egc_), cbor.extract(&text), cbor.extract(&mods) })) {
        switch (keypress) {
            106 => if (mods == 4) try writer.writeAll("\n") else try writer.writeAll("j"),
            input.key.enter => try writer.writeAll("\n"),
            input.key.tab => try writer.writeAll("\t"),
            else => {
                if (keypress == vaxis.Key.multicodepoint) {
                    try writer.writeAll(text);
                } else if (!input.is_non_input_key(keypress)) {
                    var buf: [6]u8 = undefined;
                    const bytes = try input.ucs32_to_utf8_scalar(egc_, &buf);
                    try writer.writeAll(buf[0..bytes]);
                } else {
                    var buf: [1024]u8 = undefined;
                    self.logger.print("unexpected codepoint in paste event: {s}", .{cbor.toJson(cbor_msg, &buf) catch "cbor.toJson failed"});
                }
            },
        }
        return true;
    }
    return false;
}

fn handle_bracketed_paste_start(self: *Self) !void {
    self.bracketed_paste = true;
    self.bracketed_paste_buffer.clearRetainingCapacity();
}

fn handle_bracketed_paste_end(self: *Self) !void {
    defer {
        self.bracketed_paste_buffer.clearRetainingCapacity();
        self.bracketed_paste = false;
    }
    if (!self.bracketed_paste) return;
    if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{ "system_clipboard", self.bracketed_paste_buffer.written() }));
}

fn handle_bracketed_paste_error(self: *Self, e: Error) !void {
    self.logger.err("bracketed paste", e);
    self.bracketed_paste_buffer.clearRetainingCapacity();
    self.bracketed_paste = false;
    return e;
}

pub fn set_sgr_pixel_mode_support(self: *Self, enable_sgr_pixel_mode_support: bool) void {
    self.enable_sgr_pixel_mode_support = enable_sgr_pixel_mode_support;
}

pub fn set_terminal_title(self: *Self, text: []const u8) void {
    self.vx.setTitle(self.tty.writer(), text) catch {};
}

pub fn set_terminal_style(self: *Self, style_: Style) void {
    if (style_.fg) |color|
        self.vx.setTerminalForegroundColor(self.tty.writer(), vaxis.Cell.Color.rgbFromUint(@intCast(color.color)).rgb) catch {};
    if (style_.bg) |color|
        self.vx.setTerminalBackgroundColor(self.tty.writer(), vaxis.Cell.Color.rgbFromUint(@intCast(color.color)).rgb) catch {};
}

pub fn set_color_scheme(self: *Self, scheme: ColorScheme) void {
    _ = self;
    _ = scheme;
}

pub fn set_terminal_cursor_color(self: *Self, color: Color) void {
    self.cursor_color = RGB.from_u24(color.color);
    self.vx.setTerminalCursorColor(self.tty.writer(), vaxis.Cell.Color.rgbFromUint(color.color).rgb) catch {};
}

pub fn set_terminal_secondary_cursor_color(self: *Self, color: Color) void {
    self.secondary_color = RGB.from_u24(color.color);
    self.vx.setTerminalCursorSecondaryColor(self.tty.writer(), vaxis.Cell.Color.rgbFromUint(color.color).rgb) catch {};
}

pub fn set_terminal_working_directory(self: *Self, absolute_path: []const u8) void {
    const hostname = switch (builtin.os.tag) {
        .windows => null,
        else => root.get_init().environ_map.get("HOSTNAME"),
    } orelse null;
    self.vx.setTerminalWorkingDirectory(self.tty.writer(), absolute_path, hostname) catch {};
}

pub fn copy_to_system_clipboard(self: *Self, text: []const u8) void {
    var writer = self.tty.writer();
    self.vx.copyToSystemClipboard(writer, text, self.allocator) catch |e| log.logger(log_name).err("copy_to_system_clipboard", e);
    writer.flush() catch @panic("flush failed");
}

pub fn request_system_clipboard(self: *Self) void {
    self.vx.requestSystemClipboard(self.tty.writer()) catch |e| log.logger(log_name).err("request_system_clipboard", e);
}

const win32 = struct {
    const windows = std.os.windows;
    pub extern "user32" fn OpenClipboard(hWndNewOwner: ?windows.HWND) callconv(.winapi) windows.BOOL;
    pub extern "user32" fn CloseClipboard() callconv(.winapi) windows.BOOL;
    pub extern "user32" fn SetClipboardData(uFormat: windows.UINT, hMem: windows.HANDLE) callconv(.winapi) ?windows.HANDLE;
    pub extern "user32" fn GetClipboardData(uFormat: windows.UINT) callconv(.winapi) ?windows.HANDLE;
    pub extern "user32" fn EmptyClipboard() windows.BOOL;
    pub extern "kernel32" fn GlobalAlloc(flags: c_int, size: usize) ?windows.HANDLE;
    pub extern "kernel32" fn GlobalFree(hMem: windows.HANDLE) windows.BOOL;
    pub extern "kernel32" fn GlobalLock(hMem: windows.HANDLE) ?windows.LPVOID;
    pub extern "kernel32" fn GlobalUnlock(hMem: windows.HANDLE) windows.BOOL;
    const CF_TEXT = @as(c_int, 1);
    const GMEM_MOVEABLE = @as(c_int, 2);
};

pub fn copy_to_windows_clipboard(text: []const u8) !void {
    const mem = win32.GlobalAlloc(win32.GMEM_MOVEABLE, text.len + 1) orelse return error.GlobalAllocFalied;
    const data: [*c]u8 = @ptrCast(win32.GlobalLock(mem) orelse return error.ClipboardDataLockFailed);
    @memcpy(data[0..text.len], text);
    data[text.len] = 0;
    _ = win32.GlobalUnlock(mem);

    if (win32.OpenClipboard(null) == .FALSE) {
        _ = win32.GlobalFree(mem);
        return error.OpenClipBoardFailed;
    }
    defer _ = win32.CloseClipboard();

    _ = win32.EmptyClipboard();
    if (win32.SetClipboardData(win32.CF_TEXT, mem) == null) {
        _ = win32.GlobalFree(mem);
    }
}

pub fn request_windows_clipboard(allocator: std.mem.Allocator) ![]u8 {
    if (win32.OpenClipboard(null) == .FALSE)
        return error.OpenClipBoardFailed;
    defer _ = win32.CloseClipboard();

    const mem = win32.GetClipboardData(win32.CF_TEXT) orelse return error.ClipboardDataRetrievalFailed;
    const data: [*c]u8 = @ptrCast(win32.GlobalLock(mem) orelse return error.ClipboardDataLockFailed);
    const text = std.mem.span(data);
    defer _ = win32.GlobalUnlock(mem);

    return allocator.dupe(u8, text);
}

pub fn request_mouse_cursor(self: *Self, shape: MouseCursorShape, push_or_pop: bool) void {
    if (push_or_pop) self.vx.setMouseShape(shape) else self.vx.setMouseShape(.default);
}

pub fn request_mouse_cursor_text(self: *Self, push_or_pop: bool) void {
    if (push_or_pop) self.vx.setMouseShape(.text) else self.vx.setMouseShape(.default);
}

pub fn request_mouse_cursor_pointer(self: *Self, push_or_pop: bool) void {
    if (push_or_pop) self.vx.setMouseShape(.pointer) else self.vx.setMouseShape(.default);
}

pub fn request_mouse_cursor_default(self: *Self, push_or_pop: bool) void {
    if (push_or_pop) self.vx.setMouseShape(.default) else self.vx.setMouseShape(.default);
}

fn sync_mod_state(self: *Self, keypress: u32, modifiers: vaxis.Key.Modifiers) !void {
    if (modifiers.ctrl and !self.mods.ctrl and !(keypress == input.key.left_control or keypress == input.key.right_control))
        try self.send_sync_key(input.event.press, input.key.left_control, "", modifiers);
    if (!modifiers.ctrl and self.mods.ctrl and !(keypress == input.key.left_control or keypress == input.key.right_control))
        try self.send_sync_key(input.event.release, input.key.left_control, "", modifiers);
    if (modifiers.alt and !self.mods.alt and !(keypress == input.key.left_alt or keypress == input.key.right_alt))
        try self.send_sync_key(input.event.press, input.key.left_alt, "", modifiers);
    if (!modifiers.alt and self.mods.alt and !(keypress == input.key.left_alt or keypress == input.key.right_alt))
        try self.send_sync_key(input.event.release, input.key.left_alt, "", modifiers);
    if (modifiers.shift and !self.mods.shift and !(keypress == input.key.left_shift or keypress == input.key.right_shift))
        try self.send_sync_key(input.event.press, input.key.left_shift, "", modifiers);
    if (!modifiers.shift and self.mods.shift and !(keypress == input.key.left_shift or keypress == input.key.right_shift))
        try self.send_sync_key(input.event.release, input.key.left_shift, "", modifiers);
    self.mods = modifiers;
}

fn send_sync_key(self: *Self, event: input.Event, keypress: u32, key_string: []const u8, modifiers: vaxis.Key.Modifiers) !void {
    if (self.dispatch_input) |f| f(
        self.handler_ctx,
        try self.fmtmsg(.{
            "I",
            event,
            keypress,
            keypress,
            key_string,
            @as(u8, @bitCast(modifiers)),
        }),
    );
}

fn filter_mods(key_: vaxis.Key) vaxis.Key {
    var key__ = key_;
    key__.mods = .{
        .shift = key_.mods.shift,
        .alt = key_.mods.alt,
        .ctrl = key_.mods.ctrl,
        .super = key_.mods.super,
        .hyper = key_.mods.hyper,
        .meta = key_.mods.meta,
    };
    return key__;
}

fn normalize_shifted_alphas(key_: vaxis.Key) vaxis.Key {
    if (!key_.mods.shift) return key_;
    var key = key_;
    const shifted_codepoint = key.shifted_codepoint orelse key.codepoint;
    const base_layout_codepoint = key.base_layout_codepoint orelse key.codepoint;
    if (shifted_codepoint == base_layout_codepoint and 'a' <= shifted_codepoint and shifted_codepoint <= 'z')
        key.shifted_codepoint = shifted_codepoint - 0x20;
    return key;
}

const Loop = struct {
    tty: *vaxis.Tty,
    vaxis: *vaxis.Vaxis,
    pid: tp.pid,

    thread: ?std.Thread = null,
    should_quit: bool = false,

    const tp = @import("thespian");

    pub fn init(tty: *vaxis.Tty, vaxis_: *vaxis.Vaxis) Loop {
        return .{
            .tty = tty,
            .vaxis = vaxis_,
            .pid = tp.self_pid().clone(),
        };
    }

    pub fn deinit(self: *Loop) void {
        self.pid.deinit();
    }

    /// spawns the input thread to read input from the tty
    pub fn start(self: *Loop) std.Thread.SpawnError!void {
        if (self.thread) |_| return;
        self.thread = try std.Thread.spawn(.{}, Loop.ttyRun, .{self});
    }

    /// stops reading from the tty.
    pub fn stop(self: *Loop) void {
        self.should_quit = true;
        // trigger a read
        self.vaxis.deviceStatusReport(self.tty.writer()) catch {};

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
            self.should_quit = false;
        }
    }

    fn postEvent(self: *Loop, event: vaxis.Event) void {
        var text: []const u8 = "";
        var free_text: bool = false;
        switch (event) {
            .key_press => |key_| {
                if (key_.text) |text_| text = text_;
            },
            .key_release => |key_| {
                if (key_.text) |text_| text = text_;
            },
            .paste => |text_| {
                text = text_;
                free_text = true;
            },
            else => {},
        }
        self.pid.send(.{ "RDR", std.mem.asBytes(&event), text }) catch @panic("send RDR event failed");
        if (free_text)
            self.vaxis.opts.system_clipboard_allocator.?.free(text);
    }

    fn ttyRun(self: *Loop) !void {
        switch (builtin.os.tag) {
            .windows => {
                var parser: vaxis.Parser = .{};
                const a = self.vaxis.opts.system_clipboard_allocator orelse @panic("no tty allocator");
                while (!self.should_quit) {
                    self.postEvent(try self.tty.nextEvent(&parser, a));
                }
            },
            else => {
                var parser: vaxis.Parser = .{};

                const a = self.vaxis.opts.system_clipboard_allocator orelse @panic("no tty allocator");

                var buf = try a.alloc(u8, 512);
                defer a.free(buf);
                var n: usize = 0;
                var need_read = false;

                while (!self.should_quit) {
                    if (n >= buf.len) {
                        const buf_grow = try a.alloc(u8, buf.len * 2);
                        @memcpy(buf_grow[0..buf.len], buf);
                        a.free(buf);
                        buf = buf_grow;
                    }
                    if (n == 0 or need_read) {
                        const n_ = try self.tty.read(buf[n..]);
                        n = n + n_;
                        need_read = false;
                    }
                    const result = try parser.parse(buf[0..n], a);
                    if (result.n == 0) {
                        need_read = true;
                        continue;
                    }
                    if (result.event) |event| {
                        self.postEvent(event);
                    }
                    if (result.n < n) {
                        const buf_move = try a.alloc(u8, buf.len);
                        @memcpy(buf_move[0 .. n - result.n], buf[result.n..n]);
                        a.free(buf);
                        buf = buf_move;
                        n = n - result.n;
                    } else {
                        n = 0;
                    }
                }
            },
        }
    }
};
