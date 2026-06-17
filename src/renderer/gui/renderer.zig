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

cursor_color: RGBA = .init(255, 255, 255, 255),
secondary_color: RGBA = .init(255, 255, 255, 255),
secondary_cursors_buf: std.ArrayList(app.CursorInfo) = .empty,

blink_on: bool = true,
blink_epoch: i64 = 0,
blink_period_us: i64 = 500_000,
blink_idle_us: i64 = 15_000_000,
blink_last_change: i64 = 0,
prev_cursors_hash: u64 = 0,

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
    _: bool, // no_alternate
    _: bool, // enable_terminal_cursor
    dispatch_initialized: *const fn (ctx: *anyopaque) void,
) Error!Self {
    std.debug.assert(!global.init_called);
    global.init_called = true;

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
    result.vx.screen.width_method = .unicode;
    std.log.info("unicode capability detected", .{});
    result.vx.caps.multi_cursor = true;
    std.log.info("multi cursor capability detected", .{});
    result.vx.caps.explicit_width = true;
    std.log.info("explicit width capability enabled", .{});
    result.vx.caps.kitty_keyboard = true;
    std.log.info("kitty keyboard capability detected", .{});
    result.vx.caps.sgr_pixels = true;
    std.log.info("pixel mouse capability detected", .{});
    result.vx.state.in_band_resize = true;
    std.log.info("in band resize capability detected", .{});
    // TODO
    // result.vx.caps.color_scheme_updates = true;
    // std.log.info("color scheme updates capability detected", .{});
    return result;
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.thread == null);
    var drop: std.Io.Writer.Discarding = .init(&.{});
    self.vx.deinit(self.allocator, &drop.writer);
    self.event_buffer.deinit();
    self.secondary_cursors_buf.deinit(self.allocator);
    self.targets.deinit(self.allocator);
}

pub fn submit_layer(self: *Self, target: Layer.Target) Layer.Handle {
    const handle: Layer.Handle = @enumFromInt(self.targets.items.len);
    if (target.parent) |p| std.debug.assert(@intFromEnum(p) < @intFromEnum(handle));
    resolve_layer_origin(self.stdplane(), &target.src.surface, target, self.targets.items);
    self.targets.append(self.allocator, target) catch |e| switch (e) {
        error.OutOfMemory => @panic("OOM gui.submit_layer"),
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

pub fn render(self: *Self) error{}!?i64 {
    if (!self.window_ready) return null;

    var layers_buf: std.ArrayList(app.LayerView) = .empty;
    defer layers_buf.deinit(self.allocator);
    var targets_buf: std.ArrayList(app.TargetView) = .empty;
    defer targets_buf.deinit(self.allocator);
    var layer_index_by_ptr: std.AutoHashMap(*Layer, u32) = .init(self.allocator);
    defer layer_index_by_ptr.deinit();

    layers_buf.append(self.allocator, .{
        .id = self.stdplane_id,
        .screen = &self.vx.screen,
    }) catch @panic("OOM render");

    for (self.targets.items) |*t| {
        const src_gop = layer_index_by_ptr.getOrPut(t.src) catch @panic("OOM render");
        if (!src_gop.found_existing) {
            src_gop.value_ptr.* = @intCast(layers_buf.items.len);
            layers_buf.append(self.allocator, .{
                .id = t.src.id,
                .screen = &t.src.screen,
            }) catch @panic("OOM render");
        }

        const parent_idx: u32 = if (t.parent) |h| blk: {
            const parent_target = &self.targets.items[@intFromEnum(h)];
            break :blk layer_index_by_ptr.get(parent_target.src) orelse @panic("parent layer not registered");
        } else 0; // stdplane

        targets_buf.append(self.allocator, .{
            .src_index = src_gop.value_ptr.*,
            .parent = parent_idx,
            .y = t.y,
            .x = t.x,
            .yoffset = t.yoffset,
            .xoffset = t.xoffset,
            .blend = t.blend,
            .alpha = t.alpha,
            .dst_x_off = t.dst.x_off,
            .dst_y_off = t.dst.y_off,
            .dst_width = t.dst.width,
            .dst_height = t.dst.height,
            .z_index = @intFromEnum(t.z_index),
        }) catch @panic("OOM render");
    }

    // hash visible cursor state across all layers
    var hasher = std.hash.Wyhash.init(0);
    var any_blink: bool = false;
    for (layers_buf.items) |lv| {
        const s = lv.screen;
        hasher.update(&[_]u8{@intFromBool(s.cursor_vis)});
        if (!s.cursor_vis) continue;
        if (isBlink(s.cursor_shape)) any_blink = true;
        hasher.update(std.mem.asBytes(&s.cursor.row));
        hasher.update(std.mem.asBytes(&s.cursor.col));
        hasher.update(std.mem.asBytes(&s.cursor_shape));
        for (s.cursor_secondary) |sc| {
            hasher.update(std.mem.asBytes(&sc.row));
            hasher.update(std.mem.asBytes(&sc.col));
        }
    }
    const cursors_hash = hasher.final();

    // any cursor change resets global blink phase
    const now = root.get_now().toMicroseconds();
    if (cursors_hash != self.prev_cursors_hash) {
        self.blink_epoch = now;
        self.blink_on = true;
        self.blink_last_change = now;
    }
    self.prev_cursors_hash = cursors_hash;

    if (any_blink) {
        const idle = now - self.blink_last_change;
        if (idle < self.blink_idle_us) {
            const elapsed = @mod(now - self.blink_epoch, self.blink_period_us * 2);
            self.blink_on = elapsed < self.blink_period_us;
        } else {
            self.blink_on = true; // freeze visible after idle timeout
        }
    } else {
        self.blink_on = true;
    }

    // emit all cursors
    self.secondary_cursors_buf.clearRetainingCapacity();
    var sec_ranges: std.ArrayList(struct { start: usize, end: usize }) = .empty;
    defer sec_ranges.deinit(self.allocator);

    for (layers_buf.items) |*lv| {
        const s = lv.screen;
        const sec_start = self.secondary_cursors_buf.items.len;
        if (s.cursor_vis) {
            const shape = vaxisCursorShape(s.cursor_shape);
            const blinks = isBlink(s.cursor_shape);
            const vis = if (blinks) self.blink_on else true;
            lv.cursor = .{
                .vis = vis,
                .row = s.cursor.row,
                .col = s.cursor.col,
                .shape = shape,
                .color = self.cursor_color,
            };
            for (s.cursor_secondary) |sc| {
                self.secondary_cursors_buf.append(self.allocator, .{
                    .vis = vis,
                    .row = sc.row,
                    .col = sc.col,
                    .shape = shape,
                    .color = self.secondary_color,
                }) catch break;
            }
        }
        sec_ranges.append(self.allocator, .{
            .start = sec_start,
            .end = self.secondary_cursors_buf.items.len,
        }) catch @panic("OOM render");
    }
    for (layers_buf.items, sec_ranges.items) |*lv, rng| {
        lv.secondary_cursors = self.secondary_cursors_buf.items[rng.start..rng.end];
    }

    app.updateScreen(layers_buf.items, targets_buf.items);
    self.targets.clearRetainingCapacity();

    if (!any_blink) return null;
    if (now - self.blink_last_change >= self.blink_idle_us) return null;
    const elapsed = @mod(now - self.blink_epoch, self.blink_period_us * 2);
    return now + (self.blink_period_us - @mod(elapsed, self.blink_period_us));
}

pub fn sigwinch(self: *Self) !void {
    _ = self;
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

pub fn set_background_opacity(self: *Self, value: f32) void {
    _ = self;
    app.setBackgroundOpacity(value);
}

pub fn adjust_background_opacity(self: *Self, delta: f32) void {
    _ = self;
    app.adjustBackgroundOpacity(delta);
}

pub fn reset_background_opacity(self: *Self) void {
    _ = self;
    app.resetBackgroundOpacity();
}

pub fn toggle_ignore_theme_alpha(self: *Self) void {
    _ = self;
    app.toggleIgnoreThemeAlpha();
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
        .block, .beam, .underline, .unfocused => false,
    };
}

fn vaxisCursorShape(shape: CursorShape) app.CursorShape {
    return switch (shape) {
        .default, .block, .block_blink => .block,
        .beam, .beam_blink => .beam,
        .underline, .underline_blink => .underline,
        .unfocused => .unfocused,
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
