const std = @import("std");
const Allocator = std.mem.Allocator;

const tp = @import("thespian");
const cbor = @import("cbor");
const command = @import("command");
const vaxis = @import("renderer").vaxis;
const root = @import("root");

const Vt = @import("Vt.zig");
const Plane = @import("renderer").Plane;
const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const MessageFilter = @import("MessageFilter.zig");
const tui = @import("tui.zig");
const input = @import("input");
const MouseEvent = @import("MouseEvent");
const keybind = @import("keybind");
pub const Mode = keybind.Mode;
const color = @import("color");
const RGB = color.RGB;
const file_link = @import("file_link");

pub const name = @typeName(Self);

const Self = @This();
const widget_type: Widget.Type = .panel;

allocator: Allocator,
plane: Plane,
focused: bool = false,
input_mode: Mode,
hover: bool = false,
vt: *Vt,
commands: Commands = undefined,

hover_pos: ?HoverPos = null,
last_hover_pos: ?HoverPos = null,
file_link_highlight: ?FileLinkHighlight = null,
file_link_: ?file_link.Dest = null,

const HoverPos = struct { row: u16, col: u16 };
const FileLinkHighlight = struct { row: u16, start_col: u16, end_col: u16 };

pub fn create(allocator: Allocator, parent: Plane, ctx: command.Context) !Widget {
    const container = try WidgetList.createHStyled(
        allocator,
        parent,
        "panel_frame",
        .dynamic,
        widget_type,
    );

    var plane = try Plane.init(&(Widget.Box{}).opts(name), parent);
    errdefer plane.deinit();

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .plane = plane,
        .input_mode = try keybind.mode("terminal", allocator, .{ .insert_command = "do_nothing" }),
        .vt = undefined,
    };
    try self.run_cmd(ctx);

    try self.commands.init(self);
    try tui.message_filters().add(MessageFilter.bind(self, receive_filter));

    container.ctx = self;
    try container.add(Widget.to(self));

    return container.widget();
}

pub fn run_cmd(self: *Self, ctx: command.Context) !void {
    const rows: u16 = @intCast(@max(24, self.plane.dim_y()));
    const cols: u16 = @intCast(@max(80, self.plane.dim_x()));
    self.vt = try Vt.Manager.run(root.get_io(), self.allocator, ctx, rows, cols);
}

fn re_run_cmd(self: *Self) !void {
    return if (self.vt.last_cmd) |cmd|
        self.run_cmd(.init(.{ .buf = cmd.bytes }))
    else
        tp.exit("no command to re-run");
}

pub fn receive(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (try m.match(.{ "H", tp.extract(&self.hover) })) {
        tui.rdr().request_mouse_cursor_default(self.hover);
        if (!self.hover) self.reset_hover_pos();
        tui.need_render(@src());
        return true;
    }
    // Mouse button press - set focus first, then forward to terminal if reporting is on
    {
        var btn: MouseEvent.Button = .none;
        var coord: MouseEvent.Coord = undefined;
        var mods: MouseEvent.Modifiers = .{};
        if (try m.match(.{ MouseEvent.Type.press, tp.extract(&btn), tp.extract(&coord), tp.extract(&mods) }) or
            try m.match(.{ MouseEvent.Type.release, tp.extract(&btn), tp.extract(&coord), tp.extract(&mods) }))
        {
            const button = btn.to_vaxis();
            const is_press = try m.match(.{ MouseEvent.Type.press, tp.more });

            if (tui.jump_mode()) if (self.file_link_) |*link| switch (link.*) {
                .file => |*fl| {
                    navigate_to_file_link(fl);
                    return true;
                },
                else => {},
            };

            // Set focus on left/middle/right button press
            if (is_press) switch (button) {
                .left, .middle, .right => switch (tui.set_focus_by_mouse_event()) {
                    .changed => return true,
                    .same, .notfound => {},
                },
                // Scroll wheel: forward to vt if reporting active, else scroll scrollback
                .wheel_up => {
                    if (self.vt.vt.mode.mouse == .none) {
                        if (self.vt.vt.scroll(3)) tui.need_render(@src());
                        return true;
                    }
                },
                .wheel_down => {
                    if (self.vt.vt.mode.mouse == .none) {
                        if (self.vt.vt.scroll(-3)) tui.need_render(@src());
                        return true;
                    }
                },
                else => {},
            };
            // Forward to vt if terminal mouse reporting is active
            if (self.focused and self.vt.vt.mode.mouse != .none) {
                const cell = coord.to_cell(self.plane.mouse_geometry());
                const mouse_event: vaxis.Mouse = .{
                    .col = @intCast(cell.col),
                    .row = @intCast(cell.row),
                    .xoffset = cell.xoffset,
                    .yoffset = cell.yoffset,
                    .button = button,
                    .mods = mods.to_vaxis(),
                    .type = if (is_press) .press else .release,
                };
                self.vt.vt.update(.{ .mouse = mouse_event }) catch {};
                tui.need_render(@src());
                return true;
            }
            return false;
        }
        // Mouse drag
        if (try m.match(.{ MouseEvent.Type.drag, tp.extract(&btn), tp.extract(&coord), tp.extract(&mods) })) {
            if (self.focused and self.vt.vt.mode.mouse != .none) {
                const cell = coord.to_cell(self.plane.mouse_geometry());
                const mouse_event: vaxis.Mouse = .{
                    .col = @intCast(cell.col),
                    .row = @intCast(cell.row),
                    .xoffset = cell.xoffset,
                    .yoffset = cell.yoffset,
                    .button = btn.to_vaxis(),
                    .mods = mods.to_vaxis(),
                    .type = .drag,
                };
                self.vt.vt.update(.{ .mouse = mouse_event }) catch {};
                tui.need_render(@src());
                return true;
            }
            return false;
        }
        // Mouse motion (no button held)
        if (try m.match(.{ MouseEvent.Type.motion, tp.any, tp.extract(&coord), tp.extract(&mods) })) {
            const cell = coord.to_cell(self.plane.mouse_geometry());
            if (self.focused and self.vt.vt.mode.mouse == .any_event) {
                const mouse_event: vaxis.Mouse = .{
                    .col = @intCast(cell.col),
                    .row = @intCast(cell.row),
                    .xoffset = cell.xoffset,
                    .yoffset = cell.yoffset,
                    .button = .none,
                    .mods = mods.to_vaxis(),
                    .type = .motion,
                };
                self.vt.vt.update(.{ .mouse = mouse_event }) catch {};
                tui.need_render(@src());
                return true;
            }
            if (tui.jump_mode()) {
                if (cell.row >= 0 and cell.col >= 0)
                    self.update_hover_pos(@intCast(cell.row), @intCast(cell.col));
            } else {
                self.reset_hover_pos();
            }
            return false;
        }
    }

    if (!(try m.match(.{ "I", tp.more })))
        return false;

    if (!self.focused) return false;

    if (try self.input_mode.bindings.receive(from, m))
        return true;

    var event: input.Event = 0;
    var keypress: input.Key = 0;
    var keypress_shifted: input.Key = 0;
    var text: []const u8 = "";
    var modifiers: u8 = 0;

    if (!try m.match(.{ "I", tp.extract(&event), tp.extract(&keypress), tp.extract(&keypress_shifted), tp.extract(&text), tp.extract(&modifiers) }))
        return false;

    // Only forward press and repeat events; ignore releases.
    if (event != input.event.press and event != input.event.repeat) return true;
    const key: vaxis.Key = .{
        .codepoint = keypress,
        .shifted_codepoint = if (keypress_shifted != keypress) keypress_shifted else null,
        .mods = @bitCast(modifiers),
        .text = if (text.len > 0) text else null,
    };
    if (self.vt.process_exited) {
        if (keypress == input.key.enter and key.mods.shift) {
            self.vt.restart_shell() catch |e|
                std.log.err("terminal_view: shell restart failed: {}", .{e});
            tui.need_render(@src());
            return true;
        }
        if (keypress == input.key.enter) {
            self.re_run_cmd() catch |e|
                std.log.err("terminal_view: restart failed: {}", .{e});
            tui.need_render(@src());
            return true;
        }
        if (keypress == input.key.escape or (keypress == 'd' and key.mods.ctrl)) {
            tp.self_pid().send(.{ "cmd", "close_terminal", .{} }) catch {};
            return true;
        }
    }
    if (!input.is_modifier(keypress))
        self.vt.vt.scrollToBottom();
    self.vt.vt.update(.{ .key_press = key }) catch |e|
        std.log.err("terminal_view: input failed: {}", .{e});
    tui.need_render(@src());
    return true;
}

pub fn toggle_focus(self: *Self) void {
    if (self.focused) self.unfocus() else self.focus();
}

pub fn get_title(self: *Self) []const u8 {
    return self.vt.title.items;
}

pub fn focus(self: *Self) void {
    if (self.focused) return;
    self.focused = true;
    if (tui.mini_mode() != null)
        command.executeName("exit_mini_mode", .empty()) catch {};
    if (tui.input_mode_outer() != null)
        command.executeName("exit_overlay_mode", .empty()) catch {};
    tui.set_keyboard_focus(Widget.to(self));
}

pub fn unfocus(self: *Self) void {
    if (!self.focused) return;
    self.focused = false;
    self.reset_hover_pos();
    self.reset_file_link();
    tui.release_keyboard_focus(Widget.to(self));
}

fn set_file_link(self: *Self, link_: file_link.Dest, hl: FileLinkHighlight) error{OutOfMemory}!void {
    self.reset_file_link();
    var link: file_link.Dest = link_;
    switch (link) {
        .file => |*p| p.path = try self.allocator.dupe(u8, p.path),
        .dir => |*p| p.path = try self.allocator.dupe(u8, p.path),
    }
    self.file_link_ = link;
    self.file_link_highlight = hl;
}

fn reset_file_link(self: *Self) void {
    if (self.file_link_) |link| switch (link) {
        .file => |f| self.allocator.free(f.path),
        .dir => |d| self.allocator.free(d.path),
    };
    self.file_link_ = null;
    self.file_link_highlight = null;
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    tui.message_filters().remove_ptr(self);
    self.reset_file_link();
    if (self.vt.process_exited) self.vt.deinit(allocator);
    if (self.focused) tui.release_keyboard_focus(Widget.to(self));
    self.commands.unregister();
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn shutdown_all() void {
    Vt.Manager.shutdown_all();
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    // Update the terminal's fg/bg color cache from the current theme so that
    // OSC 10/11 colour queries return accurate values.
    if (theme.editor.fg) |fg| self.vt.vt.fg_color = color.u24_to_u8s(fg.color);
    if (theme.editor.bg) |bg| self.vt.vt.bg_color = color.u24_to_u8s(bg.color);
    // Sync themes ANSI colours unless overridden by the terminal application.
    @memcpy(self.vt.vt.palette_default[0..16], &theme.ansi_palette);
    if (!self.vt.vt.palette_modified)
        @memcpy(self.vt.vt.palette[0..16], &theme.ansi_palette);
    // Propagate color scheme so apps can query or subscribe to it.
    self.vt.vt.setColorScheme(switch (theme.type) {
        .dark => .dark,
        .light => .light,
    });

    // Blit the terminal's front screen into our vaxis.Window.
    const focused_view = self.focused and tui.terminal_has_focus();
    self.vt.vt.draw(self.allocator, self.plane.window, focused_view) catch |e| {
        std.log.err("terminal_view: draw failed: {}", .{e});
    };
    if (!focused_view) self.plane.window.setCursorShape(.unfocused);

    // Resolve colour indices against the terminal's palette.
    {
        const palette = &self.vt.vt.palette;
        const win = self.plane.window;
        const scr = win.screen;
        const y_off: usize = @intCast(win.y_off);
        const x_off: usize = @intCast(win.x_off);
        for (0..win.height) |row| {
            const row_base = (y_off + row) * scr.width + x_off;
            if (row_base >= scr.buf.len) break;
            const row_end = @min(row_base + win.width, scr.buf.len);
            for (scr.buf[row_base..row_end]) |*cell| {
                resolve_color(&cell.style.fg, palette);
                resolve_color(&cell.style.bg, palette);
            }
        }
    }

    self.update_file_link_highlight();
    self.render_file_link_highlight(theme);

    return self.vt.vt.dirty;
}

fn resolve_color(c: *vaxis.Cell.Color, palette: *const [256][3]u8) void {
    switch (c.*) {
        .index => |idx| c.* = .{ .rgb = palette[idx] },
        else => {},
    }
}

fn update_hover_pos(self: *Self, row: u16, col: u16) void {
    const pos: HoverPos = .{ .row = row, .col = col };
    self.hover_pos = pos;
    if (self.last_hover_pos) |last| if (last.row == pos.row and last.col == pos.col)
        return;
    tui.need_render(@src());
}

fn reset_hover_pos(self: *Self) void {
    self.hover_pos = null;
    if (self.last_hover_pos) |_|
        tui.need_render(@src());
}

fn update_file_link_highlight(self: *Self) void {
    defer self.last_hover_pos = self.hover_pos;
    if (!tui.jump_mode() or self.vt.vt.back_screen != &self.vt.vt.back_screen_pri) {
        self.reset_file_link();
        return;
    }
    const pos = self.hover_pos orelse {
        self.reset_file_link();
        return;
    };

    if (self.last_hover_pos) |last| if (last.row == pos.row and last.col == pos.col)
        return;

    if (self.file_link_highlight) |hl| {
        if (pos.row == hl.row and pos.col >= hl.start_col and pos.col < hl.end_col)
            return;
        self.reset_file_link();
    }

    const screen = &self.vt.vt.back_screen_pri;
    if (pos.row >= screen.height) return;
    const screen_row: usize = (screen.visible_top -| self.vt.vt.scroll_offset) + pos.row;

    if (self.try_set_osc8_highlight(screen, screen_row, pos)) return;

    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(self.allocator);
    var col_at_byte: std.ArrayList(u16) = .empty;
    defer col_at_byte.deinit(self.allocator);
    screen.extractRowText(self.allocator, screen_row, &row_text, &col_at_byte) catch return;
    if (row_text.items.len == 0) return;

    const byte_offset = byte_offset_for_col(col_at_byte.items, pos.col) orelse return;
    const range = file_link.find_at_point(row_text.items, byte_offset) orelse return;
    const link = file_link.parse(row_text.items[range.start..range.end]) catch return;
    switch (link) {
        .file => |f| if (!f.exists) return,
        .dir => return,
    }
    const start_col = col_at_byte.items[range.start];
    const end_col = col_at_byte.items[range.end];
    if (end_col <= start_col) return;
    self.set_file_link(link, .{ .row = pos.row, .start_col = start_col, .end_col = end_col }) catch @panic("OOM terminal_view.set_file_link");
}

fn try_set_osc8_highlight(self: *Self, screen: *const Vt.Screen, screen_row: usize, pos: HoverPos) bool {
    if (screen.width == 0) return false;
    const total_rows = screen.buf.len / screen.width;
    if (screen_row >= total_rows) return false;
    if (pos.col >= screen.width) return false;
    const row_base = screen_row * screen.width;
    const center = &screen.buf[row_base + pos.col];
    if (center.uri.items.len == 0) return false;
    const uri = center.uri.items;
    const uri_id = center.uri_id.items;

    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(self.allocator);
    const link = file_link.url_parse(uri, &path_buf, self.allocator) catch return false;
    switch (link) {
        .file => |f| if (!f.exists) return false,
        .dir => return false,
    }

    var start_col: u16 = pos.col;
    while (start_col > 0) : (start_col -= 1) {
        const cell = &screen.buf[row_base + start_col - 1];
        if (!std.mem.eql(u8, cell.uri.items, uri)) break;
        if (!std.mem.eql(u8, cell.uri_id.items, uri_id)) break;
    }
    var end_col: u16 = pos.col + 1;
    while (end_col < screen.width) : (end_col += 1) {
        const cell = &screen.buf[row_base + end_col];
        if (!std.mem.eql(u8, cell.uri.items, uri)) break;
        if (!std.mem.eql(u8, cell.uri_id.items, uri_id)) break;
    }

    self.set_file_link(link, .{ .row = pos.row, .start_col = start_col, .end_col = end_col }) catch @panic("OOM terminal_view.set_file_link");
    return true;
}

fn render_file_link_highlight(self: *Self, theme: *const Widget.Theme) void {
    const hl = self.file_link_highlight orelse return;
    var col: u16 = hl.start_col;
    while (col < hl.end_col) : (col += 1) {
        self.plane.cursor_move_yx(@intCast(hl.row), @intCast(col));
        self.render_file_link_highlight_cell(theme.editor_cursor_secondary);
    }
}

inline fn render_file_link_highlight_cell(self: *Self, style: Widget.Theme.Style) void {
    var cell = self.plane.cell_init();
    _ = self.plane.at_cursor_cell(&cell) catch return;
    cell.cell.style.ul_style = .curly;
    if (style.bg) |ul_col| cell.set_under_color(ul_col.color);
    _ = self.plane.putc(&cell) catch {};
}

fn byte_offset_for_col(col_at_byte: []const u16, col: u16) ?usize {
    if (col_at_byte.len == 0) return null;
    // The final entry maps "one past the last byte" to its column. If the
    // hovered column is at or beyond that, the hover is past end-of-line.
    if (col >= col_at_byte[col_at_byte.len - 1]) return null;
    var i: usize = 0;
    while (i < col_at_byte.len - 1) : (i += 1) {
        if (col_at_byte[i] <= col and col < col_at_byte[i + 1]) return i;
    }
    return null;
}

pub fn handle_resize(self: *Self, pos: Widget.Box) void {
    self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
    self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;
    self.vt.resize(pos);
}

fn navigate_to_file_link(dest: *const file_link.FileDest) void {
    tp.self_pid().send(.{ "cmd", "navigate", .{
        .file = dest.path,
        .goto = .{ dest.line orelse 1, dest.column orelse 1, "byte" },
    } }) catch |e| {
        std.log.err("send navigate failed: {t}", .{e});
        return;
    };
}

fn receive_filter(self: *Self, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    // consume paste when focused
    var text: []const u8 = undefined;
    if (self.focused and m.match(.{ "system_clipboard", tp.extract(&text) }) catch false) {
        self.paste(text);
        return true;
    }
    return false;
}

fn paste(self: *Self, text: []const u8) void {
    self.vt.paste(text);
    tui.need_render(@src());
}

pub fn send_text(self: *Self, text: []const u8) void {
    self.paste(text);
    if (tui.config().terminal_newline_after_send) {
        // non-bracketed newline to trigger repl execute
        const pty_writer = self.vt.vt.get_pty_writer();
        pty_writer.writeAll("\n") catch {};
        pty_writer.flush() catch {};
    }
    tui.need_render(@src());
}

fn scroll_command_to_top(self: *Self, target_row: usize) void {
    const screen = &self.vt.vt.back_screen_pri;
    const desired: i64 = @as(i64, @intCast(screen.visible_top)) - @as(i64, @intCast(target_row));
    const current: i64 = @intCast(self.vt.vt.scroll_offset);
    const delta: i64 = desired - current;
    if (self.vt.vt.scroll(@intCast(std.math.clamp(delta, std.math.minInt(i32), std.math.maxInt(i32)))))
        tui.need_render(@src());
}

const Commands = command.Collection(cmds);

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn terminal_scroll_up(self: *Self, _: Ctx) Result {
        const half_page = @max(1, self.vt.vt.front_screen.height / 2);
        if (self.vt.vt.scroll(@intCast(half_page)))
            tui.need_render(@src());
    }
    pub const terminal_scroll_up_meta: Meta = .{ .description = "Terminal: Scroll up" };

    pub fn terminal_scroll_down(self: *Self, _: Ctx) Result {
        const half_page = @max(1, self.vt.vt.front_screen.height / 2);
        if (self.vt.vt.scroll(-@as(i32, @intCast(half_page))))
            tui.need_render(@src());
    }
    pub const terminal_scroll_down_meta: Meta = .{ .description = "Terminal: Scroll down" };

    pub fn terminal_scroll_previous_command(self: *Self, _: Ctx) Result {
        const screen = &self.vt.vt.back_screen_pri;
        const cur_top = screen.visible_top -| self.vt.vt.scroll_offset;
        const target = screen.prevCommandRow(cur_top) orelse return;
        self.scroll_command_to_top(target);
    }
    pub const terminal_scroll_previous_command_meta: Meta = .{ .description = "Terminal: Scroll to previous command" };

    pub fn terminal_scroll_next_command(self: *Self, _: Ctx) Result {
        const screen = &self.vt.vt.back_screen_pri;
        const cur_top = screen.visible_top -| self.vt.vt.scroll_offset;
        if (screen.nextCommandRow(cur_top)) |target| {
            self.scroll_command_to_top(target);
        } else if (screen.historySize() < screen.height) {
            // Less than a screenful of scrollback: keep the last command
            // pinned at the top rather than jumping past it.
            if (screen.lastCommandRow()) |target|
                self.scroll_command_to_top(target);
        } else if (self.vt.vt.scroll_offset != 0) {
            // Past the last command: return to the active terminal position.
            self.vt.vt.scrollToBottom();
            tui.need_render(@src());
        }
    }
    pub const terminal_scroll_next_command_meta: Meta = .{ .description = "Terminal: Scroll to next command" };

    pub fn terminal_open_file_links(self: *Self, _: Ctx) Result {
        const screen = &self.vt.vt.back_screen_pri;
        // When scrolled up, grab the command whose output is currently shown
        const range = (if (self.vt.vt.scroll_offset == 0)
            screen.lastCommandOutputRange()
        else
            screen.commandOutputRangeAt(screen.visible_top -| self.vt.vt.scroll_offset)) orelse {
            std.log.info("terminal: no command output available", .{});
            return;
        };

        // dedupe to avoid multiple entries for the same file position
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var it = seen.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            seen.deinit(self.allocator);
        }

        var sent: usize = 0;
        tp.self_pid().send(.{ "TFL", "begin" }) catch {};
        var row: usize = range.start;
        while (row < range.end) : (row += 1) {
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(self.allocator);
            screen.extractRowText(self.allocator, row, &line, null) catch continue;
            var pos: usize = 0;
            while (file_link.find_in_line(line.items[pos..])) |r| {
                const slice = line.items[pos + r.start .. pos + r.end];
                pos += r.end;
                const link = file_link.parse(slice) catch continue;
                const f = switch (link) {
                    .file => |f| f,
                    .dir => continue,
                };
                if (!f.exists) continue;
                const key = std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ f.path, f.line orelse 0 }) catch continue;
                const gop = seen.getOrPut(self.allocator, key) catch {
                    self.allocator.free(key);
                    continue;
                };
                if (gop.found_existing) {
                    self.allocator.free(key);
                    continue;
                }
                tp.self_pid().send(.{ "TFL", f.path, f.line orelse 0, f.column orelse 0, line.items }) catch {};
                sent += 1;
            }
        }
        tp.self_pid().send(.{ "TFL", "done" }) catch {};
        std.log.info("terminal: {d} file link{s} found", .{ sent, if (sent != 1) "s" else "" });
    }
    pub const terminal_open_file_links_meta: Meta = .{ .description = "Terminal: Open file links" };

    pub fn terminal_open_scrollback_buffer(self: *Self, _: Ctx) Result {
        // Use the active back screen so an alt-screen app (vim/htop/...)
        // gets a screenshot of just the visible viewport, while the
        // primary screen also includes scrollback history.
        const screen = self.vt.vt.back_screen;
        const total_rows = screen.visible_top + screen.height;

        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(self.allocator);
        var row: usize = 0;
        while (row < total_rows) : (row += 1) {
            screen.extractRowText(self.allocator, row, &content, null) catch break;
            content.append(self.allocator, '\n') catch break;
        }

        var buffer_name: std.ArrayList(u8) = .empty;
        defer buffer_name.deinit(self.allocator);
        try buffer_name.append(self.allocator, '*');
        if (self.vt.title.items.len > 0) {
            try buffer_name.appendSlice(self.allocator, self.vt.title.items);
        } else {
            var w: std.Io.Writer.Allocating = .init(self.allocator);
            defer w.deinit();
            self.vt.get_running_cmd(&w.writer) catch {};
            if (w.written().len > 0)
                try buffer_name.appendSlice(self.allocator, w.written())
            else
                try buffer_name.appendSlice(self.allocator, "scrollback");
        }
        try buffer_name.append(self.allocator, '*');

        if (tui.get_buffer_manager()) |bm|
            if (bm.get_buffer_for_file(buffer_name.items)) |buf|
                bm.delete_buffer(buf);

        try command.executeName("create_scratch_buffer", command.fmt(.{
            buffer_name.items, content.items, "text",
        }));

        if (tui.mainview()) |mv| if (mv.panel_maximized)
            try command.executeName("toggle_maximize_panel", .empty());
        self.unfocus();
    }
    pub const terminal_open_scrollback_buffer_meta: Meta = .{ .description = "Terminal: Open scrollback buffer" };

    pub fn terminal_open_last_command_output(self: *Self, _: Ctx) Result {
        const screen = &self.vt.vt.back_screen_pri;
        const range = screen.lastCommandOutputRange() orelse return;

        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(self.allocator);
        var row: u32 = range.start;
        while (row < range.end) : (row += 1) {
            screen.extractRowText(self.allocator, row, &content, null) catch break;
            content.append(self.allocator, '\n') catch break;
        }

        var buffer_name: std.ArrayList(u8) = .empty;
        defer buffer_name.deinit(self.allocator);
        try buffer_name.appendSlice(self.allocator, "*output*");

        if (tui.get_buffer_manager()) |bm|
            if (bm.get_buffer_for_file(buffer_name.items)) |buf|
                bm.delete_buffer(buf);

        try command.executeName("create_scratch_buffer", command.fmt(.{
            buffer_name.items, content.items, "text",
        }));

        if (tui.mainview()) |mv| if (mv.panel_maximized)
            try command.executeName("toggle_maximize_panel", .empty());
        self.unfocus();
    }
    pub const terminal_open_last_command_output_meta: Meta = .{ .description = "Terminal: Open last command output" };
};
