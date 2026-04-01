// wio event-loop + sokol_gfx rendering for the GUI renderer.
//
// Threading model:
//   - start() is called from the tui/actor thread; it clones the caller's
//     thespian PID and spawns the wio loop on a new thread.
//   - The wio thread owns the GL context and all sokol/GPU state.
//   - requestRender() / updateScreen() can be called from any thread; they
//     post data to shared state protected by a mutex and wake the wio thread.

const std = @import("std");
const wio = @import("wio");
const sg = @import("sokol").gfx;
const slog = @import("sokol").log;
const gpu = @import("gpu");
const thespian = @import("thespian");
const cbor = @import("cbor");
const vaxis = @import("vaxis");

const input_translate = @import("input.zig");

const log = std.log.scoped(.wio_app);

// ── Shared state (protected by screen_mutex) ──────────────────────────────

const ScreenSnapshot = struct {
    cells: []gpu.Cell,
    codepoints: []u21,
    // vaxis char.width per cell: 1=normal, 2=double-wide start, 0=continuation
    widths: []u8,
    width: u16,
    height: u16,
};

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var screen_mutex: std.Thread.Mutex = .{};
var screen_pending: std.atomic.Value(bool) = .init(false);
var screen_snap: ?ScreenSnapshot = null;
var tui_pid: thespian.pid = undefined;
var font_size_px: u16 = 16;
var font_name_buf: [256]u8 = undefined;
var font_name_len: usize = 0;
var font_dirty: std.atomic.Value(bool) = .init(true);
var stop_requested: std.atomic.Value(bool) = .init(false);

// HiDPI scale factor (logical → physical pixels). Updated from wio .scale events.
// Only read/written on the wio thread after initialisation.
var dpi_scale: f32 = 1.0;

// Window title (written from TUI thread, applied by wio thread)
var title_mutex: std.Thread.Mutex = .{};
var title_buf: [512]u8 = undefined;
var title_len: usize = 0;
var title_dirty: std.atomic.Value(bool) = .init(false);

// Clipboard write (heap-allocated, transferred to wio thread)
var clipboard_mutex: std.Thread.Mutex = .{};
var clipboard_write: ?[]u8 = null;

// Clipboard read request
var clipboard_read_pending: std.atomic.Value(bool) = .init(false);

// Mouse cursor (stored as wio.Cursor tag value)
var pending_cursor: std.atomic.Value(u8) = .init(@intFromEnum(wio.Cursor.arrow));
var cursor_dirty: std.atomic.Value(bool) = .init(false);

// Window attention request
var attention_pending: std.atomic.Value(bool) = .init(false);

// Current font — written and read only from the wio thread (after gpu.init).
var wio_font: gpu.Font = .{ .cell_size = .{ .x = 8, .y = 16 } };

// ── Public API (called from tui thread) ───────────────────────────────────

pub fn start() !std.Thread {
    tui_pid = thespian.self_pid().clone();
    font_name_len = 0;
    stop_requested.store(false, .release);
    return std.Thread.spawn(.{}, wioLoop, .{});
}

pub fn stop() void {
    stop_requested.store(true, .release);
    wio.cancelWait();
}

/// Called from the tui thread to push a new screen to the GPU thread.
pub fn updateScreen(vx_screen: *const vaxis.Screen) void {
    const allocator = gpa.allocator();
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

    // Convert vaxis cells → gpu.Cell (colours only; glyph indices filled on GPU thread).
    for (vx_screen.buf[0..cell_count], new_cells, new_codepoints, new_widths) |*vc, *gc, *cp, *wt| {
        gc.* = .{
            .glyph_index = 0,
            .background = colorFromVaxis(vc.style.bg),
            .foreground = colorFromVaxis(vc.style.fg),
        };
        // Decode first codepoint from the grapheme cluster.
        const g = vc.char.grapheme;
        cp.* = if (g.len > 0) blk: {
            const seq_len = std.unicode.utf8ByteSequenceLength(g[0]) catch break :blk ' ';
            break :blk std.unicode.utf8Decode(g[0..@min(seq_len, g.len)]) catch ' ';
        } else ' ';
        wt.* = vc.char.width;
    }

    screen_mutex.lock();
    defer screen_mutex.unlock();

    // Free the previous snapshot
    if (screen_snap) |old| {
        allocator.free(old.cells);
        allocator.free(old.codepoints);
        allocator.free(old.widths);
    }
    screen_snap = .{
        .cells = new_cells,
        .codepoints = new_codepoints,
        .widths = new_widths,
        .width = vx_screen.width,
        .height = vx_screen.height,
    };

    screen_pending.store(true, .release);
    wio.cancelWait();
}

pub fn requestRender() void {
    screen_pending.store(true, .release);
    wio.cancelWait();
}

pub fn setFontSize(size_px: f32) void {
    font_size_px = @intFromFloat(@max(4, size_px));
    font_dirty.store(true, .release);
    requestRender();
}

pub fn adjustFontSize(delta: f32) void {
    const new: f32 = @as(f32, @floatFromInt(font_size_px)) + delta;
    setFontSize(new);
}

pub fn setFontFace(name: []const u8) void {
    const copy_len = @min(name.len, font_name_buf.len);
    @memcpy(font_name_buf[0..copy_len], name[0..copy_len]);
    font_name_len = copy_len;
    font_dirty.store(true, .release);
    requestRender();
}

pub fn setWindowTitle(title: []const u8) void {
    title_mutex.lock();
    defer title_mutex.unlock();
    const copy_len = @min(title.len, title_buf.len);
    @memcpy(title_buf[0..copy_len], title[0..copy_len]);
    title_len = copy_len;
    title_dirty.store(true, .release);
    wio.cancelWait();
}

pub fn setClipboard(text: []const u8) void {
    const allocator = gpa.allocator();
    const copy = allocator.dupe(u8, text) catch return;
    clipboard_mutex.lock();
    defer clipboard_mutex.unlock();
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
        .default => .arrow,
        .text => .text,
        .pointer => .hand,
        .help => .arrow,
        .progress => .arrow_busy,
        .wait => .busy,
        .@"ew-resize" => .size_ew,
        .@"ns-resize" => .size_ns,
        .cell => .crosshair,
    };
    pending_cursor.store(@intFromEnum(cursor), .release);
    cursor_dirty.store(true, .release);
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
    const cw: i32 = wio_font.cell_size.x;
    const ch: i32 = wio_font.cell_size.y;
    return .{
        .col = @divTrunc(x, cw),
        .row = @divTrunc(y, ch),
        .xoff = @mod(x, cw),
        .yoff = @mod(y, ch),
    };
}

// Reload wio_font from current settings.  Called only from the wio thread.
fn reloadFont() void {
    const name = if (font_name_len > 0) font_name_buf[0..font_name_len] else "monospace";
    const size_physical: u16 = @intFromFloat(@round(@as(f32, @floatFromInt(font_size_px)) * dpi_scale));
    wio_font = gpu.loadFont(name, @max(size_physical, 4)) catch return;
}

// Check dirty flag and reload if needed.
fn maybeReloadFont(win_size: wio.Size, state: *gpu.WindowState, cell_width: *u16, cell_height: *u16) void {
    if (font_dirty.swap(false, .acq_rel)) {
        reloadFont();
        sendResize(win_size, state, cell_width, cell_height);
    }
}

fn colorFromVaxis(color: vaxis.Cell.Color) gpu.Color {
    return switch (color) {
        .default => gpu.Color.initRgb(0, 0, 0),
        .index => |idx| blk: {
            const xterm = @import("xterm");
            const rgb24 = xterm.colors[idx];
            break :blk gpu.Color.initRgb(
                @truncate(rgb24 >> 16),
                @truncate(rgb24 >> 8),
                @truncate(rgb24),
            );
        },
        .rgb => |rgb| gpu.Color.initRgb(rgb[0], rgb[1], rgb[2]),
    };
}

// ── wio main loop (runs on dedicated thread) ──────────────────────────────

fn wioLoop() void {
    const allocator = gpa.allocator();

    wio.init(allocator, .{}) catch |e| {
        log.err("wio.init failed: {s}", .{@errorName(e)});
        tui_pid.send(.{"quit"}) catch {};
        return;
    };
    defer wio.deinit();

    var window = wio.createWindow(.{
        .title = "flow",
        .size = .{ .width = 1280, .height = 720 },
        .scale = 1.0,
        .opengl = .{
            .major_version = 3,
            .minor_version = 3,
            .profile = .core,
            .forward_compatible = true,
        },
    }) catch |e| {
        log.err("wio.createWindow failed: {s}", .{@errorName(e)});
        tui_pid.send(.{"quit"}) catch {};
        return;
    };
    defer window.destroy();

    window.makeContextCurrent();

    sg.setup(.{
        .logger = .{ .func = slog.func },
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
                    sendResize(sz, &state, &cell_width, &cell_height);
                },
                .button_press => |btn| {
                    held_buttons.press(btn);
                    const mods = input_translate.Mods.fromButtons(held_buttons);
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
                        const base_cp = input_translate.codepointFromButton(btn, .{});
                        const shifted_cp = if (mods.shift) input_translate.codepointFromButton(btn, .{ .shift = true }) else base_cp;
                        if (base_cp != 0) sendKey(1, base_cp, shifted_cp, mods);
                    }
                },
                .button_repeat => |btn| {
                    const mods = input_translate.Mods.fromButtons(held_buttons);
                    if (input_translate.mouseButtonId(btn) == null) {
                        const base_cp = input_translate.codepointFromButton(btn, .{});
                        const shifted_cp = if (mods.shift) input_translate.codepointFromButton(btn, .{ .shift = true }) else base_cp;
                        if (base_cp != 0) sendKey(2, base_cp, shifted_cp, mods);
                    }
                },
                .button_release => |btn| {
                    held_buttons.release(btn);
                    const mods = input_translate.Mods.fromButtons(held_buttons);
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
                        const base_cp = input_translate.codepointFromButton(btn, .{});
                        const shifted_cp = if (mods.shift) input_translate.codepointFromButton(btn, .{ .shift = true }) else base_cp;
                        if (base_cp != 0) sendKey(3, base_cp, shifted_cp, mods);
                    }
                },
                .char => |cp| {
                    // Only handle non-ASCII IME-composed codepoints here.
                    // ASCII keys are fully handled by .button_press with correct
                    // base/shifted codepoints, avoiding double-firing on X11.
                    if (cp > 0x7f) {
                        const mods = input_translate.Mods.fromButtons(held_buttons);
                        sendKey(1, cp, cp, mods);
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
                .focused => window.enableTextInput(.{}),
                .unfocused => window.disableTextInput(),
                else => {},
            }
        }

        // Apply pending cross-thread requests from the TUI thread.
        if (title_dirty.swap(false, .acq_rel)) {
            title_mutex.lock();
            const t = title_buf[0..title_len];
            title_mutex.unlock();
            window.setTitle(t);
        }
        {
            clipboard_mutex.lock();
            const pending = clipboard_write;
            clipboard_write = null;
            clipboard_mutex.unlock();
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
            screen_mutex.lock();
            const snap = screen_snap;
            screen_snap = null; // wio thread now owns this allocation
            screen_mutex.unlock();

            if (snap) |s| {
                defer {
                    allocator.free(s.cells);
                    allocator.free(s.codepoints);
                    allocator.free(s.widths);
                }

                state.size = .{ .x = win_size.width, .y = win_size.height };
                const font = wio_font;

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
                    const kind: gpu.GlyphKind = switch (w) {
                        2 => .left,
                        0 => .right,
                        else => .single,
                    };
                    const glyph_cp = if (w == 0) prev_cp else cp;
                    cell.glyph_index = state.generateGlyph(font, glyph_cp, kind);
                    if (w != 0) prev_cp = cp;
                }

                gpu.paint(
                    &state,
                    .{ .x = win_size.width, .y = win_size.height },
                    font,
                    s.height,
                    s.width,
                    0,
                    cells_with_glyphs,
                );
                sg.commit();
                window.swapBuffers();
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
    cell_width.* = @intCast(@divTrunc(sz.width, wio_font.cell_size.x));
    cell_height.* = @intCast(@divTrunc(sz.height, wio_font.cell_size.y));
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
    const text_len: usize = if (!mods.ctrl and !mods.alt and text_cp >= 0x20 and text_cp != 0x7f)
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
