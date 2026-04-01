const Self = @This();
pub const log_name = "renderer";

const std = @import("std");
const cbor = @import("cbor");
const vaxis = @import("vaxis");
const Style = @import("theme").Style;
const Color = @import("theme").Color;
pub const CursorShape = vaxis.Cell.CursorShape;
pub const MouseCursorShape = vaxis.Mouse.Shape;

const GraphemeCache = @import("tuirenderer").GraphemeCache;
pub const Plane = @import("tuirenderer").Plane;
pub const Layer = @import("tuirenderer").Layer;
const input = @import("input");
const app = @import("app");

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

allocator: std.mem.Allocator,
vx: vaxis.Vaxis,
cache_storage: GraphemeCache.Storage = .{},
event_buffer: std.Io.Writer.Allocating,

handler_ctx: *anyopaque,
dispatch_initialized: *const fn (ctx: *anyopaque) void,
dispatch_input: ?*const fn (ctx: *anyopaque, cbor_msg: []const u8) void = null,
dispatch_mouse: ?*const fn (ctx: *anyopaque, y: i32, x: i32, cbor_msg: []const u8) void = null,
dispatch_mouse_drag: ?*const fn (ctx: *anyopaque, y: i32, x: i32, cbor_msg: []const u8) void = null,
dispatch_event: ?*const fn (ctx: *anyopaque, cbor_msg: []const u8) void = null,

thread: ?std.Thread = null,
window_ready: bool = false,

const global = struct {
    var init_called: bool = false;
};

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

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
        .vx = try vaxis.init(allocator, opts),
        .event_buffer = .init(allocator),
        .handler_ctx = handler_ctx,
        .dispatch_initialized = dispatch_initialized,
    };
    result.vx.caps.unicode = .unicode;
    result.vx.screen.width_method = .unicode;
    return result;
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.thread == null);
    var drop: std.Io.Writer.Discarding = .init(&.{});
    self.vx.deinit(self.allocator, &drop.writer);
    self.event_buffer.deinit();
}

pub fn run(self: *Self) Error!void {
    if (self.thread) |_| return;
    // Do a dummy resize to fully initialise vaxis internal state
    var drop: std.Io.Writer.Discarding = .init(&.{});
    self.vx.resize(
        self.allocator,
        &drop.writer,
        .{ .rows = 25, .cols = 80, .x_pixel = 0, .y_pixel = 0 },
    ) catch return error.VaxisResizeError;
    self.thread = try app.start();
}

fn fmtmsg(self: *Self, value: anytype) std.Io.Writer.Error![]const u8 {
    self.event_buffer.clearRetainingCapacity();
    try cbor.writeValue(&self.event_buffer.writer, value);
    return self.event_buffer.written();
}

pub fn render(self: *Self) error{}!void {
    if (!self.window_ready) return;
    app.updateScreen(&self.vx.screen);
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
    _ = style_;
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
    _ = self;
    _ = color;
}

pub fn set_terminal_secondary_cursor_color(self: *Self, color: Color) void {
    _ = self;
    _ = color;
}

pub fn set_terminal_working_directory(self: *Self, absolute_path: []const u8) void {
    _ = self;
    _ = absolute_path;
}

pub fn copy_to_windows_clipboard(self: *Self, text: []const u8) void {
    _ = self;
    _ = text;
}

pub fn request_windows_clipboard(self: *Self) void {
    _ = self;
}

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
    _ = self;
    _ = y;
    _ = x;
    _ = shape;
}

pub fn cursor_disable(self: *Self) void {
    _ = self;
}

pub fn clear_all_multi_cursors(self: *Self) !void {
    _ = self;
}

pub fn show_multi_cursor_yx(self: *Self, y: i32, x: i32) !void {
    _ = self;
    _ = y;
    _ = x;
}

pub fn copy_to_system_clipboard(self: *Self, text: []const u8) void {
    _ = self;
    app.setClipboard(text);
}

pub fn request_system_clipboard(self: *Self) void {
    _ = self;
    app.requestClipboard();
}
