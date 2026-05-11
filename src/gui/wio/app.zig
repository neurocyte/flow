// wio event-loop + sokol_gfx rendering for the GUI renderer.
//
// Threading model:
//   - start() is called from the tui/actor thread; it clones the caller's
//     thespian PID and spawns the wio loop on a new thread.
//   - The wio thread owns the GL context and all sokol/GPU state.
//   - requestRender() / updateScreen() can be called from any thread; they
//     post data to shared state protected by a mutex and wake the wio thread.

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

pub fn start() !std.Thread {
    tui_pid = thespian.self_pid().clone();
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
    wio.cancelWait();
}

pub fn requestRender() void {
    screen_pending.store(true, .release);
    wio.cancelWait();
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
    wio.cancelWait();
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
    // Mouse positions are in logical pixels; cell_size is in physical pixels.
    // Scale up to physical before dividing so that col/row and sub-cell offsets
    // are all expressed in physical pixels, matching the GPU coordinate space.
    const x: i32 = @intFromFloat(@as(f32, @floatFromInt(pos.x)) * dpi_scale);
    const y: i32 = @intFromFloat(@as(f32, @floatFromInt(pos.y)) * dpi_scale);
    const cw: i32 = wio_font_set.cell_size.x;
    const ch: i32 = wio_font_set.cell_size.y;
    return .{
        .col = @divTrunc(x, cw),
        .row = @divTrunc(y, ch),
        .xoff = @mod(x, cw),
        .yoff = @mod(y, ch),
    };
}

// Reload wio_font_set from current settings.  Called only from the wio thread.
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

// Check dirty flag and reload if needed.
fn maybeReloadFont(win_size: wio.Size, state: *gpu.WindowState, cell_width: *u16, cell_height: *u16) void {
    if (font_dirty.swap(false, .acq_rel)) {
        reloadFont();
        sendResize(win_size, state, cell_width, cell_height);
    }
}

fn colorFromVaxis(color: vaxis.Cell.Color) RGBA {
    return switch (color) {
        .default => gpu.getBackground(),
        .index => |idx| .from_u24(@import("xterm").colors[idx]),
        .rgb => |rgb| .from_u8s(rgb),
    };
}

// ── wio main loop (runs on dedicated thread) ──────────────────────────────

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

    const gl_options: wio.GlOptions = .{
        .major_version = 3,
        .minor_version = 3,
        .profile = .core,
        .forward_compatible = true,
    };

    var window = wio.createWindow(.{
        .title = "flow",
        .app_id = if (window_class_len > 0) window_class_buf[0..window_class_len] else "flow",
        .size = .{ .width = 1280, .height = 720 },
        .scale = 1.0,
        .gl_options = if (builtin.os.tag == .windows) null else gl_options,
    }) catch |e| {
        log.err("wio.createWindow failed: {s}", .{@errorName(e)});
        tui_pid.send(.{"quit"}) catch {};
        return;
    };
    defer window.destroy();

    if (builtin.os.tag != .windows) {
        const context = window.glCreateContext(.{ .options = gl_options }) catch |e| {
            log.err("wio.glCreateContext failed: {s}", .{@errorName(e)});
            tui_pid.send(.{"quit"}) catch {};
            return;
        };
        window.glMakeContextCurrent(context);

        // Disable EGL vsync throttling so eglSwapBuffers() returns immediately.
        // Without this, eglSwapBuffers() blocks waiting for a frame callback from
        // the compositor. Compositors do not send frame callbacks for surfaces on
        // background virtual desktops, so any paint while the window is hidden
        // causes eglSwapBuffers() to stall indefinitely, freezing the Wayland
        // event loop and triggering an "Application Not Responding" dialog.
        window.glSwapInterval(0);
    }

    var swapchain: if (builtin.os.tag == .windows) D3D11Swapchain else void = undefined;
    if (builtin.os.tag == .windows) {
        // FIXME: wio uses a different zigwin32 instance
        const hwnd: win32.HWND = @ptrCast(window.backend.window);
        swapchain = D3D11Swapchain.init(hwnd, 1280, 720) catch |e| {
            log.err("d3d11_swapchain.init failed: {s}", .{@errorName(e)});
            tui_pid.send(.{"quit"}) catch {};
            return;
        };
    }
    defer if (builtin.os.tag == .windows) swapchain.deinit();

    const sg_env: sg.Environment = if (builtin.os.tag == .windows) .{
        .defaults = .{ .color_format = .RGBA8, .depth_format = .NONE, .sample_count = 1 },
        .d3d11 = .{ .device = swapchain.device, .device_context = swapchain.context },
    } else .{};

    sg.setup(.{
        .logger = .{ .func = slog.func },
        .environment = sg_env,
    });
    defer sg.shutdown();

    gpu.init(allocator) catch |e| {
        log.err("gpu.init failed: {s}", .{@errorName(e)});
        tui_pid.send(.{"quit"}) catch {};
        return;
    };
    defer gpu.deinit();

    var state = gpu.WindowState.init();
    defer state.deinit();

    // Current window sizes (updated by size_* events).
    var win_size: wio.Size = .{ .width = 1280, .height = 720 };
    // Cell grid dimensions (updated on resize)
    var cell_width: u16 = 80;
    var cell_height: u16 = 24;

    // Drain the initial wio events (scale + size_*) that are queued synchronously
    // during createWindow.  This ensures dpi_scale and win_size are correct before
    // the first reloadFont / sendResize, avoiding a brief render at the wrong scale.
    while (window.getEvent()) |event| {
        switch (event) {
            .scale => |s| dpi_scale = s,
            .size_physical => |sz| win_size = sz,
            else => {},
        }
    }

    if (builtin.os.tag == .windows) {
        swapchain.resize(@intCast(win_size.width), @intCast(win_size.height)) catch {};
    }

    // Notify the tui that the window is ready
    reloadFont();
    sendResize(win_size, &state, &cell_width, &cell_height);
    tui_pid.send(.{ "RDR", "WindowCreated", @as(usize, 0) }) catch {};

    var held_buttons = input_translate.ButtonSet{};
    var mouse_pos: wio.Position = .{ .x = 0, .y = 0 };
    var running = true;

    while (running) {
        wio.wait(.{});
        if (stop_requested.load(.acquire)) break;

        // Reload font if settings changed (font_dirty set by TUI thread).
        maybeReloadFont(win_size, &state, &cell_width, &cell_height);

        while (window.getEvent()) |event| {
            switch (event) {
                .close => {
                    running = false;
                },
                .scale => |s| {
                    dpi_scale = s;
                    font_dirty.store(true, .release);
                },
                .size_physical => |sz| {
                    win_size = sz;
                    if (builtin.os.tag == .windows) {
                        swapchain.resize(@intCast(sz.width), @intCast(sz.height)) catch |e| {
                            log.err("swapchain.resize failed: {s}", .{@errorName(e)});
                        };
                    }
                    sendResize(sz, &state, &cell_width, &cell_height);
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

        // Paint if the tui pushed new screen data.
        // Take ownership of the snap (set screen_snap = null under the mutex)
        // so the TUI thread cannot free the backing memory while we use it.
        if (screen_pending.swap(false, .acq_rel)) {
            screen_mutex.lockUncancelable(io);
            const snap = screen_snap;
            screen_snap = null; // wio thread now owns this allocation
            screen_mutex.unlock(io);

            if (snap) |s| {
                defer {
                    allocator.free(s.cells);
                    allocator.free(s.codepoints);
                    allocator.free(s.widths);
                    allocator.free(s.secondary_cursors);
                }

                state.size = .{ .x = win_size.width, .y = win_size.height };
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

                // Regenerate glyph indices using the GPU state.
                // For double-wide characters vaxis emits width=2 for the left
                // cell and width=0 (continuation) for the right cell.  The
                // right cell has no codepoint of its own; we reuse the one
                // from the preceding wide-start cell.
                const cells_with_glyphs = allocator.alloc(gpu.Cell, s.cells.len) catch continue;
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
                    cell.glyph_index = state.generateGlyph(per_face, face, glyph_cp, split);
                    if (w != 0) prev_cp = cp;
                }

                const render_view: ?*const anyopaque = if (builtin.os.tag == .windows) swapchain.rtv else null;
                gpu.paint(
                    &state,
                    .{ .x = win_size.width, .y = win_size.height },
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
                    swapchain.present();
                } else {
                    window.glSwapBuffers();
                }
            }
        }
    }

    tui_pid.send(.{"quit"}) catch {};
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
