// wio event-loop + sokol_gfx rendering for the GUI renderer.
//
// Threading model:
//   - start() is called from the tui/actor thread; it clones the caller's
//     thespian PID and spawns the wio loop on a new thread.
//   - The wio thread owns the wio.Window, runs the OS message pump, and
//     forwards events to either the tui (input) or the render actor (size,
//     refresh_rate). It does NOT touch the GL context, sokol, gpu, or the
//     D3D11 swapchain. Those all live on the render actor's thread.
//   - The render actor owns the GL/D3D context, sokol, gpu state, and the
//     paint loop. It ticks on a frame metronome at the screen refresh rate
//     and pulls the latest screen snapshot from screen_snap on each tick.
//   - updateScreen() can be called from any thread; it stashes a snapshot
//     under screen_mutex and sets screen_pending. The render actor reads
//     these on its next tick.

const std = @import("std");
const builtin = @import("builtin");
const wio = @import("wio");
const sg = @import("sokol").gfx;
const slog = @import("sokol").log;
const gpu = @import("gpu");
const thespian = @import("thespian");
const cbor = @import("cbor");
const vaxis = @import("vaxis");
const RGBA = @import("color").RGBA;

const input_translate = @import("input.zig");
const root = @import("soft_root").root;
const gui_config = @import("gui_config");

const D3D11Swapchain = if (builtin.os.tag == .windows) @import("d3d11_swapchain") else void;
const win32 = if (builtin.os.tag == .windows) @import("win32").everything else void;

const default_rasterizer: gpu.RasterizerBackend = if (builtin.os.tag == .windows)
    .dwrite
else
    .freetype;
const rasterizer_font: gpu.RasterizerFont = if (builtin.os.tag == .windows)
    .{ .dwrite = .{} }
else
    .{ .freetype = .{} };

const log = std.log.scoped(.wio_app);

const press: u8 = 1;
const repeat: u8 = 2;
const release: u8 = 3;

// Re-export cursor types so renderer.zig (which imports 'app' but not 'gpu')
// can use them without a direct dependency on the gpu module.
pub const CursorInfo = gpu.CursorInfo;
pub const CursorShape = gpu.CursorShape;

// ── Shared state (protected by screen_mutex) ──────────────────────────────

const ScreenSnapshot = struct {
    cells: []gpu.Cell,
    codepoints: []u21,
    // vaxis char.width per cell: 1=normal, 2=double-wide start, 0=continuation
    widths: []u8,
    width: u16,
    height: u16,
    // Cursor state (set by renderer thread, consumed by wio thread)
    cursor: gpu.CursorInfo,
    secondary_cursors: []gpu.CursorInfo, // heap-allocated, freed with snapshot
};

var screen_mutex: std.Io.Mutex = .init;
var screen_pending: std.atomic.Value(bool) = .init(false);
var screen_snap: ?ScreenSnapshot = null;
var tui_pid: thespian.pid = undefined;
var render_pid: ?thespian.pid = null;
var last_mods: input_translate.Mods = .{};
var font_size_pt: u16 = 16;
var font_name_buf: [256]u8 = undefined;
var font_name_len: usize = 0;
var font_weight: u16 = 400;
var font_weight_bold_offset: u16 = 300;
var font_backend: gpu.RasterizerBackend = default_rasterizer;
var font_hinting: gpu.Hinting = .normal;
var font_line_height: u8 = 100;
var font_dirty: std.atomic.Value(bool) = .init(true);
var stop_requested: std.atomic.Value(bool) = .init(false);

// Background color (written from TUI thread, applied by wio thread on each paint).
// Stored as packed RGBA u32 to allow atomic reads/writes.
var background_color: std.atomic.Value(u32) = .init(RGBA.init(0, 255, 255, 255).to_u32()); // warning yellow, we should never see the default
var background_dirty: std.atomic.Value(bool) = .init(false);

var dark_mode: std.atomic.Value(bool) = .init(true);
var dark_mode_dirty: std.atomic.Value(bool) = .init(true);

// Set by the wio thread after createWindow; read by the render actor.
var gui_window: ?*wio.Window = null;
// Set by the render actor's shutdown handler; awaited by stop().
var render_shutdown_done: std.atomic.Value(bool) = .init(false);

var config_arena_instance: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const config_arena = config_arena_instance.allocator();

// HiDPI scale factor (logical → physical pixels). Updated from wio .scale events.
// Only read/written on the wio thread after initialisation.
var dpi_scale: f32 = 1.0;

// Window title (written from TUI thread, applied by wio thread)
var title_mutex: std.Io.Mutex = .init;
var title_buf: [512]u8 = undefined;
var title_len: usize = 0;
var title_dirty: std.atomic.Value(bool) = .init(false);

// Window class / app_id - read on wio thread during window creation
var window_class_buf: [256]u8 = undefined;
var window_class_len: usize = 0;

// Clipboard write (heap-allocated, transferred to wio thread)
var clipboard_mutex: std.Io.Mutex = .init;
var clipboard_write: ?[]u8 = null;

// Clipboard read request
var clipboard_read_pending: std.atomic.Value(bool) = .init(false);

// Mouse cursor (stored as wio.Cursor tag value)
var pending_cursor: std.atomic.Value(u8) = .init(@intFromEnum(wio.Cursor.pointer));
var cursor_dirty: std.atomic.Value(bool) = .init(false);

// Window attention request
var attention_pending: std.atomic.Value(bool) = .init(false);

// Current font set — written and read only from the wio thread (after gpu.init).
var wio_font_set: gpu.FontSet = .{
    .cell_size = .{ .x = 8, .y = 16 },
    .underline_position = 0,
    .underline_thickness = 1,
    .faces = .{
        .{ .cell_size = .{ .x = 8, .y = 16 }, .backend = rasterizer_font },
        .{ .cell_size = .{ .x = 8, .y = 16 }, .backend = rasterizer_font },
        .{ .cell_size = .{ .x = 8, .y = 16 }, .backend = rasterizer_font },
        .{ .cell_size = .{ .x = 8, .y = 16 }, .backend = rasterizer_font },
    },
    .synth = .{ false, false, false, false },
};

// ── Public API (called from tui thread) ───────────────────────────────────

pub fn start(render_pid_ref: ?thespian.pid_ref) !std.Thread {
    tui_pid = thespian.self_pid().clone();
    if (render_pid) |*p| {
        p.deinit();
        render_pid = null;
    }
    if (render_pid_ref) |r| {
        render_pid = r.clone();
    } else {
        @panic("wio.app no renderer");
    }
    font_name_len = 0;
    window_class_len = 0;
    stop_requested.store(false, .release);
    loadConfig();
    const class = thespian.env.get().str("window-class");
    const copy_len = @min(class.len, window_class_buf.len);
    @memcpy(window_class_buf[0..copy_len], class[0..copy_len]);
    window_class_len = copy_len;
    return std.Thread.spawn(.{}, wioLoop, .{});
}

pub fn stop() void {
    stop_requested.store(true, .release);
    wio.cancelWait();
}

/// Called from the tui thread to push a new screen to the GPU thread.
pub fn updateScreen(
    vx_screen: *const vaxis.Screen,
    cursor: gpu.CursorInfo,
    secondary_cursors: []const gpu.CursorInfo,
) void {
    const allocator = root.get_init().gpa;
    const cell_count: usize = @as(usize, vx_screen.width) * @as(usize, vx_screen.height);

    const new_cells = allocator.alloc(gpu.Cell, cell_count) catch return;
    const new_codepoints = allocator.alloc(u21, cell_count) catch {
        allocator.free(new_cells);
        return;
    };
    const new_widths = allocator.alloc(u8, cell_count) catch {
        allocator.free(new_cells);
        allocator.free(new_codepoints);
        return;
    };
    const new_sec = allocator.alloc(gpu.CursorInfo, secondary_cursors.len) catch {
        allocator.free(new_cells);
        allocator.free(new_codepoints);
        allocator.free(new_widths);
        return;
    };
    @memcpy(new_sec, secondary_cursors);

    // Convert vaxis cells → gpu.Cell (colours only; glyph indices filled on GPU thread).
    for (vx_screen.buf[0..cell_count], new_cells, new_codepoints, new_widths) |*vc, *gc, *cp, *wt| {
        const ul_color: RGBA = switch (vc.style.ul) {
            .default => RGBA.init(0, 0, 0, 0),
            else => colorFromVaxis(vc.style.ul),
        };
        const face: u8 = (@as(u8, @intFromBool(vc.style.bold)) << 0) |
            (@as(u8, @intFromBool(vc.style.italic)) << 1);
        gc.* = .{
            .glyph_index = 0,
            .background = colorFromVaxis(if (vc.style.reverse) vc.style.fg else vc.style.bg),
            .foreground = colorFromVaxis(if (vc.style.reverse) vc.style.bg else vc.style.fg),
            .underline = ul_color,
            .ul_style = @intFromEnum(vc.style.ul_style),
            .strikethrough = if (vc.style.strikethrough) 1 else 0,
            .face = face,
        };
        // Decode first codepoint from the grapheme cluster.
        const g = vc.char.grapheme;
        cp.* = if (g.len > 0) blk: {
            const seq_len = std.unicode.utf8ByteSequenceLength(g[0]) catch break :blk ' ';
            break :blk std.unicode.utf8Decode(g[0..@min(seq_len, g.len)]) catch ' ';
        } else ' ';
        wt.* = vc.char.width;
    }

    const io = root.get_io();
    screen_mutex.lockUncancelable(io);
    defer screen_mutex.unlock(io);

    // Free the previous snapshot
    if (screen_snap) |old| {
        allocator.free(old.cells);
        allocator.free(old.codepoints);
        allocator.free(old.widths);
        allocator.free(old.secondary_cursors);
    }
    screen_snap = .{
        .cells = new_cells,
        .codepoints = new_codepoints,
        .widths = new_widths,
        .width = vx_screen.width,
        .height = vx_screen.height,
        .cursor = cursor,
        .secondary_cursors = new_sec,
    };

    screen_pending.store(true, .release);
    if (render_pid) |*rp| rp.send(.{ "tick", @as(usize, 0) }) catch {};
}

pub fn requestRender() void {
    screen_pending.store(true, .release);
    if (render_pid) |*rp| rp.send(.{ "tick", @as(usize, 0) }) catch {};
}

pub fn setFontSize(size_px: f32) void {
    font_size_pt = @intFromFloat(@max(4, size_px));
    saveConfig();
    font_dirty.store(true, .release);
    requestRender();
}

pub fn adjustFontSize(delta: f32) void {
    const new: f32 = @as(f32, @floatFromInt(font_size_pt)) + delta;
    setFontSize(new);
}

pub fn resetFontSize() void {
    const default = comptime blk: {
        const field = std.meta.fieldInfo(gui_config, .fontsize);
        const ptr: *const field.type = @ptrCast(@alignCast(field.default_value_ptr.?));
        break :blk ptr.*;
    };
    setFontSize(@floatFromInt(default));
}

pub fn resetFontFace() void {
    const default = comptime blk: {
        const field = std.meta.fieldInfo(gui_config, .fontface);
        const ptr: *const field.type = @ptrCast(@alignCast(field.default_value_ptr.?));
        break :blk ptr.*;
    };
    setFontFace(default);
}

pub fn setFontFace(name: []const u8) void {
    const copy_len = @min(name.len, font_name_buf.len);
    @memcpy(font_name_buf[0..copy_len], name[0..copy_len]);
    font_name_len = copy_len;
    saveConfig();
    font_dirty.store(true, .release);
    requestRender();
}

pub fn setFontWeight(weight: u16) void {
    font_weight = weight;
    saveConfig();
    font_dirty.store(true, .release);
    requestRender();
}

pub fn getFontWeight() u16 {
    return font_weight;
}

pub fn setFontWeightBoldOffset(offset: u16) void {
    font_weight_bold_offset = offset;
    saveConfig();
    font_dirty.store(true, .release);
    requestRender();
}

pub fn getFontWeightBoldOffset() u16 {
    return font_weight_bold_offset;
}

pub fn setRasterizerBackend(backend: gpu.RasterizerBackend) void {
    font_backend = backend;
    saveConfig();
    font_dirty.store(true, .release);
    requestRender();
}

pub fn getRasterizerBackend() gpu.RasterizerBackend {
    return font_backend;
}

pub fn setHinting(h: gpu.Hinting) void {
    font_hinting = h;
    saveConfig();
    font_dirty.store(true, .release);
    requestRender();
}

pub fn getHinting() gpu.Hinting {
    return font_hinting;
}

pub fn setLineHeight(pct: u8) void {
    font_line_height = pct;
    saveConfig();
    font_dirty.store(true, .release);
    requestRender();
}

pub fn getLineHeight() u8 {
    return font_line_height;
}

pub fn setWindowTitle(title: []const u8) void {
    const io = root.get_io();
    title_mutex.lockUncancelable(io);
    defer title_mutex.unlock(io);
    const copy_len = @min(title.len, title_buf.len);
    @memcpy(title_buf[0..copy_len], title[0..copy_len]);
    title_len = copy_len;
    title_dirty.store(true, .release);
    wio.cancelWait();
}

pub fn setClipboard(text: []const u8) void {
    const io = root.get_io();
    const allocator = root.get_init().gpa;
    const copy = allocator.dupe(u8, text) catch return;
    clipboard_mutex.lockUncancelable(io);
    defer clipboard_mutex.unlock(io);
    if (clipboard_write) |old| allocator.free(old);
    clipboard_write = copy;
    wio.cancelWait();
}

pub fn requestClipboard() void {
    clipboard_read_pending.store(true, .release);
    wio.cancelWait();
}

pub fn setMouseCursor(shape: vaxis.Mouse.Shape) void {
    const cursor: wio.Cursor = switch (shape) {
        .default => .default,
        .text => .text,
        .pointer => .pointer,
        .help => .help,
        .progress => .progress,
        .wait => .wait,
        .@"ew-resize" => .ew_resize,
        .@"ns-resize" => .ns_resize,
        .cell => .cell,
    };
    pending_cursor.store(@intFromEnum(cursor), .release);
    cursor_dirty.store(true, .release);
    wio.cancelWait();
}

pub fn getFontName() []const u8 {
    return if (font_name_len > 0) font_name_buf[0..font_name_len] else "monospace";
}

pub fn loadConfig() void {
    const conf, _ = root.read_config(gui_config, config_arena);
    root.write_config(conf, config_arena) catch
        log.err("failed to write gui config file", .{});
    font_size_pt = conf.fontsize;
    font_weight = if (conf.fontweight < 100) 400 else conf.fontweight; // fallback for old gui_config files
    font_weight_bold_offset = conf.fontweight_bold_offset;
    font_backend = conf.fontbackend;
    font_hinting = conf.fonthinting;
    font_line_height = if (conf.lineheight == 0) 100 else conf.lineheight;
    const name = conf.fontface;
    const copy_len = @min(name.len, font_name_buf.len);
    @memcpy(font_name_buf[0..copy_len], name[0..copy_len]);
    font_name_len = copy_len;
}

fn saveConfig() void {
    var conf, _ = root.read_config(gui_config, config_arena);
    conf.fontsize = @truncate(font_size_pt);
    conf.fontweight = font_weight;
    conf.fontweight_bold_offset = font_weight_bold_offset;
    conf.fontbackend = font_backend;
    conf.fonthinting = font_hinting;
    conf.lineheight = font_line_height;
    conf.fontface = getFontName();
    root.write_config(conf, config_arena) catch
        log.err("failed to write gui config file", .{});
}

pub fn setBackground(color: RGBA) void {
    const color_u32: u32 = (@as(u32, color.r) << 24) | (@as(u32, color.g) << 16) | (@as(u32, color.b) << 8) | color.a;
    background_color.store(color_u32, .release);
    background_dirty.store(true, .release);
}

pub fn enableDarkMode(enabled: bool) void {
    dark_mode.store(enabled, .release);
    dark_mode_dirty.store(true, .release);
}

pub fn requestAttention() void {
    attention_pending.store(true, .release);
    wio.cancelWait();
}

// ── Internal helpers (wio thread only) ────────────────────────────────────

const CellPos = struct {
    col: i32,
    row: i32,
    xoff: i32,
    yoff: i32,
};

fn pixelToCellPos(pos: wio.Position) CellPos {
    // win32 backend reports mouse coords in physical pixels
    // wayland and x11 backends report logical pixels
    const x: i32 = if (builtin.os.tag == .windows)
        @intCast(pos.x)
    else
        @intFromFloat(@as(f32, @floatFromInt(pos.x)) * dpi_scale);
    const y: i32 = if (builtin.os.tag == .windows)
        @intCast(pos.y)
    else
        @intFromFloat(@as(f32, @floatFromInt(pos.y)) * dpi_scale);
    const cw: i32 = wio_font_set.cell_size.x;
    const ch: i32 = wio_font_set.cell_size.y;
    return .{
        .col = @divTrunc(x, cw),
        .row = @divTrunc(y, ch),
        .xoff = @mod(x, cw),
        .yoff = @mod(y, ch),
    };
}

// Reload wio_font_set from current settings.  Called only from the render
// actor's thread (sg/gpu state is owned by the render actor).
fn reloadFont() void {
    const name = if (font_name_len > 0) font_name_buf[0..font_name_len] else "monospace";
    const size_physical: u16 = @intFromFloat(@round(@as(f32, @floatFromInt(font_size_pt)) * (4.0 / 3.0) * dpi_scale));
    gpu.setRasterizerBackend(font_backend);
    gpu.setHinting(font_hinting);
    const set = gpu.loadFontSet(.{
        .name = name,
        .size_px = @max(size_physical, 4),
        .weight = font_weight,
        .bold_offset = font_weight_bold_offset,
        .line_height_pct = font_line_height,
    }) catch return;
    wio_font_set = set;
}

fn colorFromVaxis(color: vaxis.Cell.Color) RGBA {
    return switch (color) {
        .default => gpu.getBackground(),
        .index => |idx| .from_u24(@import("xterm").colors[idx]),
        .rgb => |rgb| .from_u8s(rgb),
    };
}

// ── wio main loop (runs on dedicated thread) ──────────────────────────────
//
// Only the OS message pump runs here. GL/D3D/sg/gpu/paint all live on the
// render actor's thread. This thread forwards size_physical/refresh_rate to
// the render actor and input/focus/etc. to tui.

fn wioLoop() void {
    const io = root.get_io();
    const allocator = root.get_init().gpa;

    if (builtin.os.tag == .windows) {
        // force PerMonitorV2 DPI awareness regardless of manifest
        _ = win32.SetProcessDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }

    wio.init(allocator, io, .{}) catch |e| {
        log.err("wio.init failed: {s}", .{@errorName(e)});
        tui_pid.send(.{"quit"}) catch {};
        return;
    };
    defer wio.deinit();

    var window = wio.createWindow(.{
        .title = "flow",
        .app_id = if (window_class_len > 0) window_class_buf[0..window_class_len] else "flow-control",
        .size = .{ .width = 1280, .height = 720 },
        .scale = 1.0,
        .gl_options = if (builtin.os.tag == .windows) null else gl_options(),
    }) catch |e| {
        log.err("wio.createWindow failed: {s}", .{@errorName(e)});
        tui_pid.send(.{"quit"}) catch {};
        return;
    };
    defer window.destroy();

    if (builtin.os.tag == .windows) {
        // FIXME: wio uses a different zigwin32 instance
        const hwnd: win32.HWND = @ptrCast(window.backend.window);
        applyWindowIcons(hwnd);
    }

    gui_window = &window;

    // Initial wio events (scale, size_physical, refresh_rate) are queued
    // synchronously during createWindow. Forward them to the render actor so
    // it has the correct initial state. The render actor will handle font
    // load + GPU init in its window_ready handler.
    var initial_size: wio.Size = .{ .width = 1280, .height = 720 };
    while (window.getEvent()) |event| {
        switch (event) {
            .scale => |s| dpi_scale = s,
            .size_physical => |sz| initial_size = sz,
            .refresh_rate => |r| if (render_pid) |*rp| rp.send(.{ "refresh_rate", r }) catch {},
            else => {},
        }
    }

    if (render_pid) |*rp| rp.send(.{
        "window_ready",
        @as(u32, @intCast(initial_size.width)),
        @as(u32, @intCast(initial_size.height)),
    }) catch {};

    var held_buttons = input_translate.ButtonSet{};
    var mouse_pos: wio.Position = .{ .x = 0, .y = 0 };
    var running = true;

    while (running) {
        wio.wait(.{});
        if (stop_requested.load(.acquire)) break;

        while (window.getEvent()) |event| {
            switch (event) {
                .close => {
                    running = false;
                },
                .scale => |s| {
                    dpi_scale = s;
                    font_dirty.store(true, .release);
                },
                .refresh_rate => |r| {
                    if (render_pid) |*rp| rp.send(.{ "refresh_rate", r }) catch {};
                },
                .size_physical => |sz| {
                    if (render_pid) |*rp| rp.send(.{
                        "resize",
                        @as(u32, @intCast(sz.width)),
                        @as(u32, @intCast(sz.height)),
                    }) catch {};
                },
                .button_press => |btn| {
                    held_buttons.press(btn);
                    const mods = syncModifiers();
                    if (input_translate.mouseButtonId(btn)) |mb_id| {
                        const cp = pixelToCellPos(mouse_pos);
                        tui_pid.send(.{
                            "RDR", "B",
                            @as(u8, 1), // press
                            mb_id,
                            cp.col,
                            cp.row,
                            cp.xoff,
                            cp.yoff,
                        }) catch {};
                    } else {
                        if (input_translate.codepointFromButton(btn, .{})) |base_cp| {
                            const shifted_cp = if (mods.shift) input_translate.codepointFromButton(btn, .{ .shift = true }) else base_cp;
                            sendKey(press, base_cp, shifted_cp orelse base_cp, mods);
                        } else {
                            if (input_translate.modifierCodepoint(btn)) |mod_cp|
                                sendKey(press, mod_cp, mod_cp, mods);
                        }
                    }
                },
                .button_repeat => |btn| {
                    const mods = syncModifiers();
                    if (input_translate.mouseButtonId(btn) == null) {
                        if (input_translate.codepointFromButton(btn, .{})) |base_cp| {
                            const shifted_cp = if (mods.shift) input_translate.codepointFromButton(btn, .{ .shift = true }) else base_cp;
                            sendKey(2, base_cp, shifted_cp orelse base_cp, mods);
                        }
                    }
                },
                .button_release => |btn| {
                    held_buttons.release(btn);
                    const mods = syncModifiers();
                    if (input_translate.mouseButtonId(btn)) |mb_id| {
                        const cp = pixelToCellPos(mouse_pos);
                        tui_pid.send(.{
                            "RDR", "B",
                            @as(u8, 3), // release
                            mb_id,
                            cp.col,
                            cp.row,
                            cp.xoff,
                            cp.yoff,
                        }) catch {};
                    } else {
                        if (input_translate.codepointFromButton(btn, .{})) |base_cp| {
                            const shifted_cp = if (mods.shift) input_translate.codepointFromButton(btn, .{ .shift = true }) else base_cp;
                            sendKey(3, base_cp, shifted_cp orelse base_cp, mods);
                        } else if (input_translate.modifierCodepoint(btn)) |mod_cp| {
                            sendKey(3, mod_cp, mod_cp, mods);
                        }
                    }
                },
                .char => |cp| {
                    // Only handle non-ASCII IME-composed codepoints here.
                    // ASCII keys are fully handled by .button_press with correct
                    // base/shifted codepoints, avoiding double-firing on X11.
                    if (cp > 0x7f) {
                        const mods = syncModifiers();
                        sendKey(press, cp, cp, mods);
                    }
                },
                .mouse => |pos| {
                    mouse_pos = pos;
                    const cp = pixelToCellPos(pos);
                    if (input_translate.heldMouseButtonId(held_buttons)) |mb_id| {
                        tui_pid.send(.{ "RDR", "D", mb_id, cp.col, cp.row, cp.xoff, cp.yoff }) catch {};
                    } else {
                        tui_pid.send(.{ "RDR", "M", cp.col, cp.row, cp.xoff, cp.yoff }) catch {};
                    }
                },
                .scroll_vertical => |dy| {
                    const btn_id: u8 = if (dy < 0) 64 else 65; // up / down scroll
                    const cp = pixelToCellPos(mouse_pos);
                    tui_pid.send(.{ "RDR", "B", @as(u8, 1), btn_id, cp.col, cp.row, cp.xoff, cp.yoff }) catch {};
                },
                .scroll_horizontal => |dx| {
                    const btn_id: u8 = if (dx < 0) 66 else 67; // left / right scroll
                    const cp = pixelToCellPos(mouse_pos);
                    tui_pid.send(.{ "RDR", "B", @as(u8, 1), btn_id, cp.col, cp.row, cp.xoff, cp.yoff }) catch {};
                },
                .focused => {
                    _ = syncModifiers();
                    window.enableTextInput(.{});
                    tui_pid.send(.{"focus_in"}) catch {};
                },
                .unfocused => {
                    window.disableTextInput();
                    tui_pid.send(.{"focus_out"}) catch {};
                },
                else => {
                    std.log.debug("wio unhandled event: {}", .{event});
                },
            }
        }

        // Apply pending cross-thread requests from the TUI thread.
        if (title_dirty.swap(false, .acq_rel)) {
            title_mutex.lockUncancelable(io);
            const t = title_buf[0..title_len];
            title_mutex.unlock(io);
            window.setTitle(t);
        }
        {
            clipboard_mutex.lockUncancelable(io);
            const pending = clipboard_write;
            clipboard_write = null;
            clipboard_mutex.unlock(io);
            if (pending) |text| {
                defer allocator.free(text);
                window.setClipboardText(text);
            }
        }
        if (clipboard_read_pending.swap(false, .acq_rel)) {
            if (window.getClipboardText(allocator)) |text| {
                defer allocator.free(text);
                tui_pid.send(.{ "RDR", "system_clipboard", text }) catch {};
            }
        }
        if (cursor_dirty.swap(false, .acq_rel)) {
            window.setCursor(@enumFromInt(pending_cursor.load(.acquire)));
        }
        if (attention_pending.swap(false, .acq_rel)) {
            window.requestAttention();
        }
    }

    if (render_pid) |*rp| rp.send(.{"shutdown"}) catch {};
    while (!render_shutdown_done.load(.acquire)) {
        std.atomic.spinLoopHint();
        std.Thread.yield() catch break;
    }

    tui_pid.send(.{"quit"}) catch {};
}

fn gl_options() wio.GlOptions {
    return .{
        .major_version = 3,
        .minor_version = 3,
        .profile = .core,
        .forward_compatible = true,
    };
}

// ── Render actor worker functions (run on the render actor's thread) ──────
//
// The render actor calls these from its message handlers. The wio thread
// must not touch any state set up here.

const RenderCtx = struct {
    state: gpu.WindowState,
    swapchain: if (builtin.os.tag == .windows) D3D11Swapchain else void,
    hwnd: if (builtin.os.tag == .windows) win32.HWND else void,
    win_size: wio.Size,
    target_size: wio.Size,
    cell_width: u16,
    cell_height: u16,
};

var render_ctx: ?RenderCtx = null;

pub fn renderActorWindowReady(initial_w: u32, initial_h: u32) void {
    const allocator = root.get_init().gpa;
    const window = gui_window orelse {
        log.err("renderActorWindowReady: gui_window is null", .{});
        tui_pid.send(.{"quit"}) catch {};
        return;
    };

    if (builtin.os.tag != .windows) {
        const ctx = window.glCreateContext(.{ .options = gl_options() }) catch |e| {
            log.err("wio.glCreateContext failed: {s}", .{@errorName(e)});
            tui_pid.send(.{"quit"}) catch {};
            return;
        };
        window.glMakeContextCurrent(ctx);

        // Disable EGL vsync throttling so eglSwapBuffers() returns immediately.
        // Without this, eglSwapBuffers() blocks waiting for a frame callback
        // from the compositor. Compositors do not send frame callbacks for
        // surfaces on background virtual desktops, so any paint while the
        // window is hidden causes eglSwapBuffers() to stall indefinitely.
        window.glSwapInterval(0);
    }

    const hwnd: if (builtin.os.tag == .windows) win32.HWND else void =
        if (builtin.os.tag == .windows) @ptrCast(window.backend.window) else {};

    var swapchain: if (builtin.os.tag == .windows) D3D11Swapchain else void = undefined;
    if (builtin.os.tag == .windows) {
        swapchain = D3D11Swapchain.init(hwnd, @intCast(@max(1, initial_w)), @intCast(@max(1, initial_h))) catch |e| {
            log.err("d3d11_swapchain.init failed: {s}", .{@errorName(e)});
            tui_pid.send(.{"quit"}) catch {};
            return;
        };
    }

    const sg_env: sg.Environment = if (builtin.os.tag == .windows) .{
        .defaults = .{ .color_format = .RGBA8, .depth_format = .NONE, .sample_count = 1 },
        .d3d11 = .{ .device = swapchain.device, .device_context = swapchain.context },
    } else .{};

    sg.setup(.{
        .logger = .{ .func = slog.func },
        .environment = sg_env,
    });

    gpu.init(allocator) catch |e| {
        log.err("gpu.init failed: {s}", .{@errorName(e)});
        sg.shutdown();
        tui_pid.send(.{"quit"}) catch {};
        return;
    };

    const initial_size: wio.Size = .{ .width = @intCast(initial_w), .height = @intCast(initial_h) };
    render_ctx = .{
        .state = gpu.WindowState.init(),
        .swapchain = swapchain,
        .hwnd = hwnd,
        .win_size = initial_size,
        .target_size = initial_size,
        .cell_width = 80,
        .cell_height = 24,
    };

    reloadFont();
    sendResize(initial_size, &render_ctx.?.state, &render_ctx.?.cell_width, &render_ctx.?.cell_height);
    tui_pid.send(.{ "RDR", "WindowCreated", @as(usize, 0) }) catch {};
}

pub fn renderActorResize(w: u32, h: u32) void {
    if (render_ctx) |*ctx| {
        ctx.target_size = .{ .width = @intCast(w), .height = @intCast(h) };
    }
}

pub fn renderActorTick() void {
    const ctx = if (render_ctx) |*c| c else return;
    const allocator = root.get_init().gpa;
    const io = root.get_io();

    // On Windows the wio thread can be parked inside DefWindowProc's modal
    // resize/move loop, so the ("resize", w, h) message from the wio thread
    // doesn't arrive until the user releases the mouse. Poll the live client
    // rect directly so we keep repainting during the drag.
    if (builtin.os.tag == .windows) {
        var rect: win32.RECT = undefined;
        if (win32.GetClientRect(ctx.hwnd, &rect) != 0) {
            const w: u16 = @intCast(@max(1, rect.right - rect.left));
            const h: u16 = @intCast(@max(1, rect.bottom - rect.top));
            ctx.target_size = .{ .width = w, .height = h };
        }
    }

    // Resize the swapchain (Win32) and WindowState if the target changed.
    if (ctx.target_size.width != ctx.win_size.width or ctx.target_size.height != ctx.win_size.height) {
        ctx.win_size = ctx.target_size;
        if (builtin.os.tag == .windows) {
            ctx.swapchain.resize(@intCast(ctx.win_size.width), @intCast(ctx.win_size.height)) catch |e| {
                log.err("swapchain.resize failed: {s}", .{@errorName(e)});
            };
        }
        sendResize(ctx.win_size, &ctx.state, &ctx.cell_width, &ctx.cell_height);
    }

    // Reload font if settings changed (font_dirty set from any thread).
    if (font_dirty.swap(false, .acq_rel)) {
        reloadFont();
        sendResize(ctx.win_size, &ctx.state, &ctx.cell_width, &ctx.cell_height);
    }

    // Apply dark titlebar (Win32). This is a window attribute API; it's safe
    // from any thread but conceptually belongs near the paint.
    if (builtin.os.tag == .windows and dark_mode_dirty.swap(false, .acq_rel)) {
        applyDarkTitlebar(ctx.hwnd, dark_mode.load(.acquire));
    }

    // Only paint when there's a new screen snapshot.
    if (!screen_pending.swap(false, .acq_rel)) return;

    screen_mutex.lockUncancelable(io);
    const snap_opt = screen_snap;
    screen_snap = null;
    screen_mutex.unlock(io);

    const s = snap_opt orelse return;
    defer {
        allocator.free(s.cells);
        allocator.free(s.codepoints);
        allocator.free(s.widths);
        allocator.free(s.secondary_cursors);
    }

    ctx.state.size = .{ .x = ctx.win_size.width, .y = ctx.win_size.height };
    const font_set = wio_font_set;

    if (background_dirty.swap(false, .acq_rel)) {
        const color_u32 = background_color.load(.acquire);
        gpu.setBackground(.{
            .r = @truncate(color_u32 >> 24),
            .g = @truncate(color_u32 >> 16),
            .b = @truncate(color_u32 >> 8),
            .a = @truncate(color_u32),
        });
    }

    const cells_with_glyphs = allocator.alloc(gpu.Cell, s.cells.len) catch return;
    defer allocator.free(cells_with_glyphs);
    @memcpy(cells_with_glyphs, s.cells);

    var prev_cp: u21 = ' ';
    for (cells_with_glyphs, s.codepoints, s.widths) |*cell, cp, w| {
        const split: gpu.GlyphSplit = switch (w) {
            2 => .left,
            0 => .right,
            else => .single,
        };
        const glyph_cp = if (w == 0) prev_cp else cp;
        const face: gpu.Face = @enumFromInt(@as(u2, @truncate(cell.face)));
        const per_face = font_set.faces[@intFromEnum(face)];
        cell.glyph_index = ctx.state.generateGlyph(per_face, face, glyph_cp, split);
        if (w != 0) prev_cp = cp;
    }

    const render_view: ?*const anyopaque = if (builtin.os.tag == .windows) ctx.swapchain.rtv else null;
    gpu.paint(
        &ctx.state,
        .{ .x = ctx.win_size.width, .y = ctx.win_size.height },
        font_set,
        s.height,
        s.width,
        0,
        cells_with_glyphs,
        s.cursor,
        s.secondary_cursors,
        render_view,
    );
    sg.commit();
    if (builtin.os.tag == .windows) {
        ctx.swapchain.present();
    } else if (gui_window) |w| {
        w.glSwapBuffers();
    }
}

pub fn renderActorShutdown() void {
    if (render_ctx) |*ctx| {
        ctx.state.deinit();
        if (builtin.os.tag == .windows) ctx.swapchain.deinit();
        gpu.deinit();
        sg.shutdown();
        render_ctx = null;
    }
    render_shutdown_done.store(true, .release);
}

fn sendResize(
    sz: wio.Size,
    state: *gpu.WindowState,
    cell_width: *u16,
    cell_height: *u16,
) void {
    cell_width.* = @intCast(@divTrunc(sz.width, wio_font_set.cell_size.x));
    cell_height.* = @intCast(@divTrunc(sz.height, wio_font_set.cell_size.y));
    state.size = .{ .x = sz.width, .y = sz.height };
    tui_pid.send(.{
        "RDR",                        "Resize",
        cell_width.*,                 cell_height.*,
        @as(u16, @intCast(sz.width)), @as(u16, @intCast(sz.height)),
    }) catch {};
}

fn sendKey(kind: u8, codepoint: u21, shifted_codepoint: u21, mods: input_translate.Mods) void {
    var text_buf: [4]u8 = undefined;
    // Text is the character that would be typed: empty when ctrl/alt active,
    // shifted_codepoint when shift is held, otherwise codepoint.
    const text_cp: u21 = if (mods.shift) shifted_codepoint else codepoint;
    const text_len: usize = if (!mods.ctrl and !mods.alt and text_cp >= 0x20 and text_cp != 0x7f and text_cp < 0xE000)
        std.unicode.utf8Encode(text_cp, &text_buf) catch 0
    else
        0;
    tui_pid.send(.{
        "RDR",                       "I",
        kind,                        @as(u21, codepoint),
        @as(u21, shifted_codepoint), text_buf[0..text_len],
        @as(u8, @bitCast(mods)),
    }) catch {};
}

fn syncModifiers() input_translate.Mods {
    const mods = input_translate.fromWioModifiers(wio.getModifiers());
    // Synthesize release events for any modifier keys no
    // longer held so they don't appear stuck.
    if (mods.shift != last_mods.shift) {
        last_mods.shift = mods.shift;
        sendKey(if (last_mods.shift) press else release, vaxis.Key.left_shift, vaxis.Key.left_shift, last_mods);
    }
    if (mods.alt != last_mods.alt) {
        last_mods.alt = mods.alt;
        sendKey(if (last_mods.alt) press else release, vaxis.Key.left_alt, vaxis.Key.left_alt, last_mods);
    }
    if (mods.ctrl != last_mods.ctrl) {
        last_mods.ctrl = mods.ctrl;
        sendKey(if (last_mods.ctrl) press else release, vaxis.Key.left_control, vaxis.Key.left_control, last_mods);
    }
    if (mods.super != last_mods.super) {
        last_mods.super = mods.super;
        sendKey(if (last_mods.super) press else release, vaxis.Key.left_super, vaxis.Key.left_super, last_mods);
    }
    last_mods = mods;
    return mods;
}

const ID_ICON_FLOW = 1; // must match src/win32/flow.rc

fn applyDarkTitlebar(hwnd: win32.HWND, dark: bool) void {
    if (builtin.os.tag != .windows) return;
    const value: c_int = if (dark) 1 else 0;
    const hr = win32.DwmSetWindowAttribute(
        hwnd,
        win32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        &value,
        @sizeOf(@TypeOf(value)),
    );
    if (hr < 0) log.warn("DwmSetWindowAttribute(dark={}) failed", .{dark});
}

fn applyWindowIcons(hwnd: win32.HWND) void {
    if (builtin.os.tag != .windows) return;
    const hinst = win32.GetModuleHandleW(null);
    const dpi = win32.GetDpiForWindow(hwnd);
    const small_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXSMICON), dpi);
    const small_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYSMICON), dpi);
    const large_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXICON), dpi);
    const large_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYICON), dpi);
    const small = win32.LoadImageW(hinst, @ptrFromInt(ID_ICON_FLOW), .ICON, small_x, small_y, win32.LR_SHARED) orelse {
        log.warn("LoadImage small icon failed", .{});
        return;
    };
    const large = win32.LoadImageW(hinst, @ptrFromInt(ID_ICON_FLOW), .ICON, large_x, large_y, win32.LR_SHARED) orelse {
        log.warn("LoadImage large icon failed", .{});
        return;
    };
    _ = win32.SendMessageW(hwnd, win32.WM_SETICON, win32.ICON_SMALL, @bitCast(@intFromPtr(small)));
    _ = win32.SendMessageW(hwnd, win32.WM_SETICON, win32.ICON_BIG, @bitCast(@intFromPtr(large)));
}
