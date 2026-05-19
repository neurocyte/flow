const Self = @This();
pub const log_name = "renderer";

const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const RGBA = @import("color").RGBA;
pub const vaxis = @import("vaxis");
const Style = @import("theme").Style;
const Color = @import("theme").Color;
const ColorScheme = @import("theme").Type;
pub const CursorShape = vaxis.Cell.CursorShape;
pub const MouseCursorShape = vaxis.Mouse.Shape;

const GraphemeCache = @import("tuirenderer").GraphemeCache;
pub const Plane = @import("tuirenderer").Plane;
pub const Layer = @import("tuirenderer").Layer;
const input = @import("input");
const app = @import("app");
const root = @import("soft_root").root;

pub const Cell = @import("tuirenderer").Cell;
pub const StyleBits = @import("tuirenderer").style;
pub const style = StyleBits;
pub const styles = @import("tuirenderer").styles;

pub const Error = error{
    UnexpectedRendererEvent,
    OutOfMemory,
    IntegerTooLarge,
    IntegerTooSmall,
    InvalidType,
    TooShort,
    Utf8CannotEncodeSurrogateHalf,
    CodepointTooLarge,
    VaxisResizeError,
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

const keepalive = std.time.us_per_day * 365; // one year

allocator: std.mem.Allocator,
vx: vaxis.Vaxis,
cache_storage: GraphemeCache.Storage = .{},
event_buffer: std.Io.Writer.Allocating,
targets: std.ArrayList(Layer.Target) = .empty,
stdplane_id: Layer.Id,

handler_ctx: *anyopaque,
dispatch_initialized: *const fn (ctx: *anyopaque) void,
dispatch_input: ?*const fn (ctx: *anyopaque, cbor_msg: []const u8) void = null,
dispatch_mouse: ?*const fn (ctx: *anyopaque, y: i32, x: i32, cbor_msg: []const u8) void = null,
dispatch_mouse_drag: ?*const fn (ctx: *anyopaque, y: i32, x: i32, cbor_msg: []const u8) void = null,
dispatch_event: ?*const fn (ctx: *anyopaque, cbor_msg: []const u8) void = null,

thread: ?std.Thread = null,
window_ready: bool = false,

cursor_info: app.CursorInfo = .{},
cursor_color: RGBA = .init(255, 255, 255, 255),
secondary_cursors: std.ArrayList(app.CursorInfo) = .empty,
secondary_color: RGBA = .init(255, 255, 255, 255),

cursor_blink: bool = false,
blink_on: bool = true,
blink_epoch: i64 = 0,
blink_period_us: i64 = 500_000,
blink_idle_us: i64 = 15_000_000,
blink_last_change: i64 = 0,
prev_cursor: app.CursorInfo = .{},
prev_cursor_blink: bool = false,

const global = struct {
    var init_called: bool = false;
};

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

pub fn spawn(io: std.Io, a: std.mem.Allocator) error{
    SystemResources,
    LockedMemoryLimitExceeded,
    OutOfMemory,
    ThreadQuotaExceeded,
    ThespianSpawnFailed,
    ThespianContextCreateFailed,
}!tp.pid {
    return try tp.spawn_pinned(
        io,
        a,
        RenderActor.StartArgs{
            .allocator = a,
            .parent = tp.self_pid().clone(),
        },
        RenderActor.start,
        "render",
        null,
    );
}

const RenderActor = struct {
    allocator: std.mem.Allocator,
    parent: tp.pid,
    receiver: tp.Receiver(*@This()),
    initialized: bool = false,
    keepalive_timer: ?tp.Cancellable = null,

    const StartArgs = struct {
        allocator: std.mem.Allocator,
        parent: tp.pid,
    };

    fn start(args: StartArgs) tp.result {
        const self = args.allocator.create(@This()) catch |e| return tp.exit_error(e, @errorReturnTrace());
        errdefer args.allocator.destroy(self);
        self.* = .{
            .allocator = args.allocator,
            .parent = args.parent,
            .receiver = undefined,
        };
        self.receiver = .init(receive, dtor, self);
        self.keepalive_timer = tp.self_pid().delay_send_cancellable(self.allocator, "render.keepalive", keepalive, .{"keepalive"}) catch |e| return tp.exit_error(e, @errorReturnTrace());
        tp.receive(&self.receiver);
    }

    fn receive(self: *@This(), _: tp.pid_ref, m: tp.message) tp.result {
        errdefer self.deinit();
        if (try m.match(.{ "tick", tp.more })) {
            if (self.initialized) app.renderActorTick();
            return;
        }
        var w: u32 = 0;
        var h: u32 = 0;
        if (try m.match(.{ "window_ready", tp.extract(&w), tp.extract(&h) })) {
            app.renderActorWindowReady(w, h);
            self.initialized = true;
            return;
        }
        if (try m.match(.{ "resize", tp.extract(&w), tp.extract(&h) })) {
            app.renderActorResize(w, h);
            return;
        }
        var refresh_mhz: u32 = 0;
        if (try m.match(.{ "refresh_rate", tp.extract(&refresh_mhz) })) {
            if (refresh_mhz == 0) return;
            const hz = refresh_mhz / 1000;
            try self.parent.send(.{ "render", "frame_rate", hz });
            std.log.info("frame rate (Hz): {}", .{hz});
            return;
        }
        if (try m.match(.{"shutdown"})) {
            app.renderActorShutdown();
            self.initialized = false;
            return tp.exit_normal();
        }
        return tp.unexpected(m);
    }

    fn dtor(self: *@This()) void {
        self.parent.deinit();
    }

    fn deinit(self: *@This()) void {
        if (self.keepalive_timer) |*t| {
            t.cancel() catch {};
            t.deinit();
            self.keepalive_timer = null;
        }
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    handler_ctx: *anyopaque,
    no_alternate: bool,
    dispatch_initialized: *const fn (ctx: *anyopaque) void,
) Error!Self {
    std.debug.assert(!global.init_called);
    global.init_called = true;
    _ = no_alternate;

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
    var result: Self = .{
        .allocator = allocator,
        .vx = try vaxis.init(root.get_io(), allocator, root.get_init().environ_map, opts),
        .event_buffer = .init(allocator),
        .handler_ctx = handler_ctx,
        .dispatch_initialized = dispatch_initialized,
        .stdplane_id = Layer.next_id(),
    };
    result.vx.caps.unicode = .unicode;
    result.vx.caps.multi_cursor = true;
    result.vx.screen.width_method = .unicode;
    return result;
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.thread == null);
    var drop: std.Io.Writer.Discarding = .init(&.{});
    self.vx.deinit(self.allocator, &drop.writer);
    self.event_buffer.deinit();
    self.secondary_cursors.deinit(self.allocator);
    self.targets.deinit(self.allocator);
}

pub fn submit_layer(self: *Self, target: Layer.Target) Layer.Handle {
    const handle: Layer.Handle = @enumFromInt(self.targets.items.len);
    if (target.parent) |p| std.debug.assert(@intFromEnum(p) < @intFromEnum(handle));
    self.targets.append(self.allocator, target) catch |e| switch (e) {
        error.OutOfMemory => @panic("OOM gui.submit_layer"),
    };
    return handle;
}

pub fn run(self: *Self, render_pid: ?tp.pid_ref) Error!void {
    if (self.thread) |_| return;
    // Do a dummy resize to fully initialise vaxis internal state
    var drop: std.Io.Writer.Discarding = .init(&.{});
    self.vx.resize(
        self.allocator,
        &drop.writer,
        .{ .rows = 25, .cols = 80, .x_pixel = 0, .y_pixel = 0 },
    ) catch return error.VaxisResizeError;
    self.thread = try app.start(render_pid);
}

fn fmtmsg(self: *Self, value: anytype) std.Io.Writer.Error![]const u8 {
    self.event_buffer.clearRetainingCapacity();
    try cbor.writeValue(&self.event_buffer.writer, value);
    return self.event_buffer.written();
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

pub fn render(self: *Self) error{}!?i64 {
    if (!self.window_ready) return null;

    var i = self.targets.items.len;
    while (i > 0) {
        i -= 1;
        draw_target(&self.targets.items[i]);
    }
    self.targets.clearRetainingCapacity();

    var cursor = self.cursor_info;

    // Detect changes since the last rendered frame. Reset blink epoch and idle
    // timer on any meaningful change so the cursor snaps to visible immediately.
    if (cursor.vis != self.prev_cursor.vis or
        cursor.row != self.prev_cursor.row or
        cursor.col != self.prev_cursor.col or
        cursor.shape != self.prev_cursor.shape or
        self.cursor_blink != self.prev_cursor_blink)
    {
        const now = root.get_now().toMicroseconds();
        if (cursor.vis) {
            self.blink_epoch = now;
            self.blink_on = true;
        }
        self.blink_last_change = now;
    }
    self.prev_cursor = cursor;
    self.prev_cursor_blink = self.cursor_blink;

    // Apply blink unless the cursor has been idle for too long.
    if (cursor.vis and self.cursor_blink) {
        const now = root.get_now().toMicroseconds();
        const idle = now - self.blink_last_change;
        if (idle < self.blink_idle_us) {
            const elapsed = @mod(now - self.blink_epoch, self.blink_period_us * 2);
            self.blink_on = elapsed < self.blink_period_us;
            cursor.vis = self.blink_on;
        } else {
            cursor.vis = true; // freeze visible after idle timeout
        }
    }

    const stdplane_view: app.LayerView = .{
        .id = self.stdplane_id,
        .screen = &self.vx.screen,
        .cursor = cursor,
        .secondary_cursors = self.secondary_cursors.items,
    };
    app.updateScreen(&.{stdplane_view}, &.{});

    if (!self.cursor_info.vis or !self.cursor_blink) return null;
    const now_check = root.get_now().toMicroseconds();
    if (now_check - self.blink_last_change >= self.blink_idle_us) return null;
    const elapsed = @mod(now_check - self.blink_epoch, self.blink_period_us * 2);
    const deadline = now_check + (self.blink_period_us - @mod(elapsed, self.blink_period_us));
    return deadline;
}

pub fn sigwinch(self: *Self) !void {
    _ = self;
    // TODO: implement
}

pub fn stop(self: *Self) void {
    app.stop();
    if (self.thread) |thread| {
        thread.join();
        self.thread = null;
    }
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

pub fn process_renderer_event(self: *Self, msg: []const u8) Error!void {
    const Input = struct {
        kind: u8,
        codepoint: u21,
        shifted_codepoint: u21,
        text: []const u8,
        mods: u8,
    };
    const MousePos = struct {
        col: i32,
        row: i32,
        xoffset: i32,
        yoffset: i32,
    };
    const Winsize = struct {
        cell_width: u16,
        cell_height: u16,
        pixel_width: u16,
        pixel_height: u16,
    };

    {
        var args: Input = undefined;
        if (try cbor.match(msg, .{
            cbor.any,
            "I",
            cbor.extract(&args.kind),
            cbor.extract(&args.codepoint),
            cbor.extract(&args.shifted_codepoint),
            cbor.extract(&args.text),
            cbor.extract(&args.mods),
        })) {
            const cbor_msg = try self.fmtmsg(.{
                "I",
                args.kind,
                args.codepoint,
                args.shifted_codepoint,
                args.text,
                args.mods,
            });
            if (self.dispatch_input) |f| f(self.handler_ctx, cbor_msg);
            return;
        }
    }

    {
        var args: Winsize = undefined;
        if (try cbor.match(msg, .{
            cbor.any,
            "Resize",
            cbor.extract(&args.cell_width),
            cbor.extract(&args.cell_height),
            cbor.extract(&args.pixel_width),
            cbor.extract(&args.pixel_height),
        })) {
            var drop: std.Io.Writer.Discarding = .init(&.{});
            self.vx.resize(self.allocator, &drop.writer, .{
                .rows = @intCast(args.cell_height),
                .cols = @intCast(args.cell_width),
                .x_pixel = @intCast(args.pixel_width),
                .y_pixel = @intCast(args.pixel_height),
            }) catch |err| std.debug.panic("resize failed with {s}", .{@errorName(err)});
            self.vx.queueRefresh();
            if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{"resize"}));
            return;
        }
    }

    {
        var args: MousePos = undefined;
        if (try cbor.match(msg, .{
            cbor.any,
            "M",
            cbor.extract(&args.col),
            cbor.extract(&args.row),
            cbor.extract(&args.xoffset),
            cbor.extract(&args.yoffset),
        })) {
            if (self.dispatch_mouse) |f| f(
                self.handler_ctx,
                @intCast(args.row),
                @intCast(args.col),
                try self.fmtmsg(.{
                    "M",
                    args.col,
                    args.row,
                    args.xoffset,
                    args.yoffset,
                }),
            );
            return;
        }
    }

    {
        var args: struct {
            pos: MousePos,
            button_id: u8,
        } = undefined;
        if (try cbor.match(msg, .{
            cbor.any,
            "D",
            cbor.extract(&args.button_id),
            cbor.extract(&args.pos.col),
            cbor.extract(&args.pos.row),
            cbor.extract(&args.pos.xoffset),
            cbor.extract(&args.pos.yoffset),
        })) {
            if (self.dispatch_mouse_drag) |f| f(
                self.handler_ctx,
                @intCast(args.pos.row),
                @intCast(args.pos.col),
                try self.fmtmsg(.{
                    "D",
                    input.event.press,
                    args.button_id,
                    input.utils.button_id_string(@enumFromInt(args.button_id)),
                    args.pos.col,
                    args.pos.row,
                    args.pos.xoffset,
                    args.pos.yoffset,
                }),
            );
            return;
        }
    }

    {
        var args: struct {
            pos: MousePos,
            button: struct { press: u8, id: u8 },
        } = undefined;
        if (try cbor.match(msg, .{
            cbor.any,
            "B",
            cbor.extract(&args.button.press),
            cbor.extract(&args.button.id),
            cbor.extract(&args.pos.col),
            cbor.extract(&args.pos.row),
            cbor.extract(&args.pos.xoffset),
            cbor.extract(&args.pos.yoffset),
        })) {
            if (self.dispatch_mouse) |f| f(
                self.handler_ctx,
                @intCast(args.pos.row),
                @intCast(args.pos.col),
                try self.fmtmsg(.{
                    "B",
                    args.button.press,
                    args.button.id,
                    input.utils.button_id_string(@enumFromInt(args.button.id)),
                    args.pos.col,
                    args.pos.row,
                    args.pos.xoffset,
                    args.pos.yoffset,
                }),
            );
            return;
        }
    }

    {
        var hwnd: usize = undefined;
        if (try cbor.match(msg, .{
            cbor.any,
            "WindowCreated",
            cbor.extract(&hwnd),
        })) {
            self.window_ready = true;
            self.dispatch_initialized(self.handler_ctx);
            if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{"capability_detection_complete"}));
            return;
        }
    }

    {
        var text: []const u8 = undefined;
        if (try cbor.match(msg, .{
            cbor.any,
            "system_clipboard",
            cbor.extract(&text),
        })) {
            if (self.dispatch_event) |f| f(self.handler_ctx, try self.fmtmsg(.{ "system_clipboard", text }));
            return;
        }
    }

    return error.UnexpectedRendererEvent;
}

pub fn set_sgr_pixel_mode_support(self: *Self, enable: bool) void {
    _ = self;
    _ = enable;
}

pub fn set_terminal_title(self: *Self, text: []const u8) void {
    _ = self;
    app.setWindowTitle(text);
}

pub fn set_terminal_style(self: *Self, style_: Style) void {
    _ = self;
    if (style_.bg) |bg| app.setBackground(themeColorToGpu(bg));
}

pub fn set_color_scheme(self: *Self, scheme: ColorScheme) void {
    _ = self;
    app.enableDarkMode(scheme == .dark);
}

pub fn adjust_fontsize(self: *Self, amount: f32) void {
    _ = self;
    app.adjustFontSize(amount);
}

pub fn set_fontsize(self: *Self, fontsize: f32) void {
    _ = self;
    app.setFontSize(fontsize);
}

pub fn reset_fontsize(self: *Self) void {
    _ = self;
    app.resetFontSize();
}

pub fn set_fontface(self: *Self, fontface: []const u8) void {
    _ = self;
    app.setFontFace(fontface);
}

pub fn reset_fontface(self: *Self) void {
    _ = self;
    app.resetFontFace();
}

pub fn set_symbol_rasterizer(self: *Self, sr: app.SymbolRasterizer) void {
    _ = self;
    app.setSymbolRasterizer(sr);
}

pub fn get_symbol_rasterizer(self: *Self) app.SymbolRasterizer {
    _ = self;
    return app.getSymbolRasterizer();
}

pub fn get_fontfaces(self: *Self) void {
    const font_finder = @import("rasterizer").font_finder;
    const dispatch = self.dispatch_event orelse return;

    // Report the current font first.
    if (self.fmtmsg(.{ "fontface", "current", app.getFontName() })) |msg|
        dispatch(self.handler_ctx, msg)
    else |_| {}

    // Enumerate all available monospace fonts and report each one.
    const names = font_finder.listFonts(self.allocator) catch {
        // If enumeration fails, still close the palette with "done".
        if (self.fmtmsg(.{ "fontface", "done" })) |msg|
            dispatch(self.handler_ctx, msg)
        else |_| {}
        return;
    };
    defer {
        for (names) |n| self.allocator.free(n);
        self.allocator.free(names);
    }

    for (names) |name| {
        if (self.fmtmsg(.{ "fontface", name })) |msg|
            dispatch(self.handler_ctx, msg)
        else |_| {}
    }

    if (self.fmtmsg(.{ "fontface", "done" })) |msg|
        dispatch(self.handler_ctx, msg)
    else |_| {}
}

pub fn set_terminal_cursor_color(self: *Self, color: Color) void {
    self.cursor_color = themeColorToGpu(color);
}

pub fn set_terminal_secondary_cursor_color(self: *Self, color: Color) void {
    self.secondary_color = themeColorToGpu(color);
}

pub fn set_terminal_working_directory(self: *Self, absolute_path: []const u8) void {
    _ = self;
    _ = absolute_path;
}

pub const copy_to_windows_clipboard = @import("tuirenderer").copy_to_windows_clipboard;
pub const request_windows_clipboard = @import("tuirenderer").request_windows_clipboard;

pub fn request_mouse_cursor(self: *Self, shape: MouseCursorShape, push_or_pop: bool) void {
    _ = self;
    _ = push_or_pop;
    app.setMouseCursor(shape);
}

pub fn request_mouse_cursor_text(self: *Self, push_or_pop: bool) void {
    _ = self;
    _ = push_or_pop;
    app.setMouseCursor(.text);
}

pub fn request_mouse_cursor_pointer(self: *Self, push_or_pop: bool) void {
    _ = self;
    _ = push_or_pop;
    app.setMouseCursor(.pointer);
}

pub fn request_mouse_cursor_default(self: *Self, push_or_pop: bool) void {
    _ = self;
    _ = push_or_pop;
    app.setMouseCursor(.default);
}

pub fn cursor_enable(self: *Self, y: i32, x: i32, shape: CursorShape) !void {
    self.cursor_blink = isBlink(shape);
    self.cursor_info = .{
        .vis = true,
        .row = if (y < 0) 0 else @intCast(y),
        .col = if (x < 0) 0 else @intCast(x),
        .shape = vaxisCursorShape(shape),
        .color = self.cursor_color,
    };
}

pub fn cursor_disable(self: *Self) void {
    self.cursor_info.vis = false;
}

pub fn clear_all_multi_cursors(self: *Self) !void {
    self.secondary_cursors.clearRetainingCapacity();
}

pub fn show_multi_cursor_yx(self: *Self, y: i32, x: i32) !void {
    try self.secondary_cursors.append(self.allocator, .{
        .vis = true,
        .row = if (y < 0) 0 else @intCast(y),
        .col = if (x < 0) 0 else @intCast(x),
        .shape = self.cursor_info.shape,
        .color = self.secondary_color,
    });
}

fn themeColorToGpu(color: Color) RGBA {
    return .{
        .r = @truncate(color.color >> 16),
        .g = @truncate(color.color >> 8),
        .b = @truncate(color.color),
        .a = color.alpha,
    };
}

fn isBlink(shape: CursorShape) bool {
    return switch (shape) {
        .default, .block_blink, .beam_blink, .underline_blink => true,
        else => false,
    };
}

fn vaxisCursorShape(shape: CursorShape) app.CursorShape {
    return switch (shape) {
        .default, .block, .block_blink => .block,
        .beam, .beam_blink => .beam,
        .underline, .underline_blink => .underline,
    };
}

pub fn copy_to_system_clipboard(self: *Self, text: []const u8) void {
    _ = self;
    app.setClipboard(text);
}

pub fn request_system_clipboard(self: *Self) void {
    _ = self;
    app.requestClipboard();
}
