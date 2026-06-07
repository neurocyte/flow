const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const Allocator = std.mem.Allocator;

const tp = @import("thespian");
const cbor = @import("cbor");
const command = @import("command");
const vaxis = @import("renderer").vaxis;
const shell = @import("shell");
const argv = @import("argv");
const config = @import("config");

const Plane = @import("renderer").Plane;
const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const MessageFilter = @import("MessageFilter.zig");
const tui = @import("tui.zig");
const input = @import("input");
const keybind = @import("keybind");
pub const Mode = keybind.Mode;
const color = @import("color");
const RGB = color.RGB;
const file_link = @import("file_link");

pub const name = @typeName(Self);

const Self = @This();
const widget_type: Widget.Type = .panel;

const Terminal = @import("Terminal");
const TerminalOnExit = config.TerminalOnExit;

allocator: Allocator,
plane: Plane,
focused: bool = false,
input_mode: Mode,
hover: bool = false,
vt: *Vt,
last_cmd: ?[]const u8,
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
        .last_cmd = null,
    };
    try self.run_cmd(ctx);

    try self.commands.init(self);
    try tui.message_filters().add(MessageFilter.bind(self, receive_filter));

    container.ctx = self;
    try container.add(Widget.to(self));

    return container.widget();
}

pub fn run_cmd(self: *Self, ctx: command.Context) !void {
    const init = root.get_init();
    var env = try init.environ_map.clone(self.allocator);
    errdefer env.deinit();
    if (env.get("TERM") == null)
        try env.put("TERM", "xterm-256color");
    try env.put("COLORTERM", "truecolor");
    // COLORFGBG tells apps whether the terminal background is dark or light
    try env.put("COLORFGBG", switch (tui.active_color_scheme()) {
        .dark => "15;0",
        .light => "0;15",
    });

    var cmd_arg: []const u8 = "";
    var on_exit: TerminalOnExit = tui.config().terminal_on_exit;
    const argv_msg: ?tp.message = if (ctx.args.match(.{tp.extract(&cmd_arg)}) catch false and cmd_arg.len > 0)
        try shell.parse_arg0_to_argv(self.allocator, &cmd_arg)
    else if (ctx.args.match(.{ tp.extract(&cmd_arg), tp.extract(&on_exit) }) catch false and cmd_arg.len > 0)
        try shell.parse_arg0_to_argv(self.allocator, &cmd_arg)
    else
        null;
    defer if (argv_msg) |msg| self.allocator.free(msg.buf);

    var argv_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv_list.deinit(self.allocator);
    var have_cmd = false;
    if (argv_msg) |msg| {
        var iter = msg.buf;
        var len = try cbor.decodeArrayHeader(&iter);
        while (len > 0) : (len -= 1) {
            var arg: []const u8 = undefined;
            if (try cbor.matchValue(&iter, cbor.extract(&arg)))
                try argv_list.append(self.allocator, arg);
            have_cmd = true;
        }
    } else {
        const default_shell = if (builtin.os.tag == .windows)
            env.get("COMSPEC") orelse "cmd.exe"
        else
            env.get("SHELL") orelse "/bin/sh";
        try argv_list.append(self.allocator, default_shell);
    }

    // Use the current plane dimensions for the initial pty size. The plane
    // starts at 0×0 before the first resize, so use a sensible fallback
    // so the pty isn't created with a zero-cell screen.
    const cols: u16 = @intCast(@max(80, self.plane.dim_x()));
    const rows: u16 = @intCast(@max(24, self.plane.dim_y()));

    if (global_vt) |*vt| {
        if (!vt.process_exited and have_cmd) {
            var msg: std.Io.Writer.Allocating = .init(self.allocator);
            defer msg.deinit();
            try msg.writer.writeAll("terminal is already running '");
            try get_running_cmd(&msg.writer);
            try msg.writer.writeAll("'");
            return tp.exit(msg.written());
        }
    } else {
        try Vt.init(init.io, self.allocator, argv_list.items, env, rows, cols, on_exit);
    }
    self.vt = &global_vt.?;

    if (self.last_cmd) |cmd| {
        self.allocator.free(cmd);
        self.last_cmd = null;
    }
    self.last_cmd = try self.allocator.dupe(u8, ctx.args.buf);
}

fn re_run_cmd(self: *Self) !void {
    return if (self.last_cmd) |cmd|
        self.run_cmd(.init(.{ .buf = cmd }))
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
        var btn: i64 = 0;
        var col: i64 = 0;
        var row: i64 = 0;
        var xoffset: i64 = 0;
        var yoffset: i64 = 0;
        if (try m.match(.{ "B", input.event.press, tp.extract(&btn), tp.any, tp.extract(&col), tp.extract(&row), tp.extract(&xoffset), tp.extract(&yoffset) }) or
            try m.match(.{ "B", input.event.release, tp.extract(&btn), tp.any, tp.extract(&col), tp.extract(&row), tp.extract(&xoffset), tp.extract(&yoffset) }))
        {
            const button: vaxis.Mouse.Button = @enumFromInt(btn);
            const is_press = try m.match(.{ "B", input.event.press, tp.more });

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
                const rel = self.plane.abs_yx_to_rel(@intCast(row), @intCast(col));
                const mouse_event: vaxis.Mouse = .{
                    .col = @intCast(rel[1]),
                    .row = @intCast(rel[0]),
                    .xoffset = @intCast(xoffset),
                    .yoffset = @intCast(yoffset),
                    .button = button,
                    .mods = .{},
                    .type = if (is_press) .press else .release,
                };
                self.vt.vt.update(.{ .mouse = mouse_event }) catch {};
                tui.need_render(@src());
                return true;
            }
            return false;
        }
        // Mouse drag
        if (try m.match(.{ "D", input.event.press, tp.extract(&btn), tp.any, tp.extract(&col), tp.extract(&row), tp.extract(&xoffset), tp.extract(&yoffset) })) {
            if (self.focused and self.vt.vt.mode.mouse != .none) {
                const rel = self.plane.abs_yx_to_rel(@intCast(row), @intCast(col));
                const mouse_event: vaxis.Mouse = .{
                    .col = @intCast(rel[1]),
                    .row = @intCast(rel[0]),
                    .xoffset = @intCast(xoffset),
                    .yoffset = @intCast(yoffset),
                    .button = @enumFromInt(btn),
                    .mods = .{},
                    .type = .drag,
                };
                self.vt.vt.update(.{ .mouse = mouse_event }) catch {};
                tui.need_render(@src());
                return true;
            }
            return false;
        }
        // Mouse motion (no button held)
        if (try m.match(.{ "M", tp.extract(&col), tp.extract(&row), tp.extract(&xoffset), tp.extract(&yoffset) })) {
            if (self.focused and self.vt.vt.mode.mouse == .any_event) {
                const rel = self.plane.abs_yx_to_rel(@intCast(row), @intCast(col));
                const mouse_event: vaxis.Mouse = .{
                    .col = @intCast(rel[1]),
                    .row = @intCast(rel[0]),
                    .xoffset = @intCast(xoffset),
                    .yoffset = @intCast(yoffset),
                    .button = .none,
                    .mods = .{},
                    .type = .motion,
                };
                self.vt.vt.update(.{ .mouse = mouse_event }) catch {};
                tui.need_render(@src());
                return true;
            }
            if (tui.jump_mode()) {
                const rel = self.plane.abs_yx_to_rel(@intCast(row), @intCast(col));
                if (rel[0] >= 0 and rel[1] >= 0)
                    self.update_hover_pos(@intCast(rel[0]), @intCast(rel[1]));
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
        if (keypress == input.key.enter) {
            self.re_run_cmd() catch |e|
                std.log.err("terminal_view: restart failed: {}", .{e});
            tui.need_render(@src());
            return true;
        }
        if (keypress == input.key.escape) {
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

pub fn focus(self: *Self) void {
    if (self.focused) return;
    self.focused = true;
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
    if (self.last_cmd) |cmd| {
        self.allocator.free(cmd);
        self.last_cmd = null;
    }
    if (global_vt) |*vt| if (vt.process_exited) {
        vt.deinit(allocator);
        global_vt = null;
    };
    if (self.focused) tui.release_keyboard_focus(Widget.to(self));
    self.commands.unregister();
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn shutdown(allocator: Allocator) void {
    if (global_vt) |*vt| {
        vt.deinit(allocator);
        global_vt = null;
    }
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    // Update the terminal's fg/bg color cache from the current theme so that
    // OSC 10/11 colour queries return accurate values.
    if (theme.editor.fg) |fg| self.vt.vt.fg_color = color.u24_to_u8s(fg.color);
    if (theme.editor.bg) |bg| self.vt.vt.bg_color = color.u24_to_u8s(bg.color);

    // Blit the terminal's front screen into our vaxis.Window.
    const focused_view = self.focused and tui.terminal_has_focus();
    self.vt.vt.draw(self.allocator, self.plane.window, focused_view) catch |e| {
        std.log.err("terminal_view: draw failed: {}", .{e});
    };
    if (!focused_view) self.plane.window.setCursorShape(.unfocused);

    // Resolve ANSI colour indices 0–15 to theme RGB values
    {
        const palette = theme.ansi_palette;
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

    return false;
}

fn resolve_color(c: *vaxis.Cell.Color, palette: [16][3]u8) void {
    switch (c.*) {
        .index => |idx| if (idx < 16) {
            c.* = .{ .rgb = palette[idx] };
        },
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

fn try_set_osc8_highlight(self: *Self, screen: *const Terminal.Screen, screen_row: usize, pos: HoverPos) bool {
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

fn handle_child_exit(self: *Self, code: u8) void {
    switch (self.vt.on_exit) {
        .hold => self.show_exit_message(code),
        .hold_on_error => if (code == 0)
            tp.self_pid().send(.{ "cmd", "close_terminal", .{} }) catch {}
        else
            self.show_exit_message(code),
        .close => tp.self_pid().send(.{ "cmd", "close_terminal", .{} }) catch {},
    }
}

fn show_exit_message(self: *Self, code: u8) void {
    var msg: std.Io.Writer.Allocating = .init(self.allocator);
    defer msg.deinit();
    const w = &msg.writer;
    w.writeAll("\r\n") catch {};
    w.writeAll("\x1b[0m\x1b[2m") catch {};
    w.writeAll("[process exited") catch {};
    if (code != 0)
        w.print(" with code {d}", .{code}) catch {};
    w.writeAll("]") catch {};
    // Re-run prompt
    const cmd_argv = self.vt.vt.cmd.argv;
    if (cmd_argv.len > 0) {
        w.writeAll(" Press enter to re-run '") catch {};
        _ = argv.write(w, cmd_argv) catch {};
        w.writeAll("' or escape to close") catch {};
    } else {
        w.writeAll(" Press esc to close") catch {};
    }
    w.writeAll("\x1b[0m\r\n") catch {};
    var parser: pty.Parser = .{ .buf = .init(self.allocator) };
    defer parser.buf.deinit();
    _ = self.vt.vt.processOutput(&parser, msg.written(), self, process_terminal_event) catch {};
}

pub fn handle_resize(self: *Self, pos: Widget.Box) void {
    self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
    self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;
    self.vt.resize(pos);
}

fn navigate_to_file_link(dest: *const file_link.FileDest) void {
    tp.self_pid().send(.{ "cmd", "navigate", .{
        .file = dest.path,
        .goto = .{ dest.line orelse 1, dest.column orelse 1 },
    } }) catch |e| {
        std.log.err("send navigate failed: {t}", .{e});
        return;
    };
}

fn receive_filter(self: *Self, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    var event: Terminal.Event = undefined;
    if (m.match(.{ "VT", tp.extract(&event) }) catch false) {
        try self.process_event(event);
        return true;
    }
    return false;
}

fn process_terminal_event(ctx: *Terminal.Event.HandlerContext, event: Terminal.Event) error{TerminalHandlerFailed}!void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    return self.process_event(event) catch error.TerminalHandlerFailed;
}

fn process_event(self: *Self, event: Terminal.Event) MessageFilter.Error!void {
    switch (event) {
        .exited => |code| {
            self.vt.process_exited = true;
            self.handle_child_exit(code);
            tui.need_render(@src());
        },
        .redraw, .bell => {
            tui.need_render(@src());
        },
        .pwd_change => |path| {
            self.vt.cwd.clearRetainingCapacity();
            self.vt.cwd.appendSlice(self.allocator, path) catch {};
        },
        .title_change => |t| {
            self.vt.title.clearRetainingCapacity();
            self.vt.title.appendSlice(self.allocator, t) catch {};
        },
        .color_change => |cc| {
            self.vt.app_fg = cc.fg;
            self.vt.app_bg = cc.bg;
            self.vt.app_cursor = cc.cursor;
        },
        .osc_copy => |text| {
            // Terminal app wrote to clipboard via OSC 52.
            // Add to flow clipboard history and forward to system clipboard.
            const owned = try tui.clipboard_allocator().dupe(u8, text);
            tui.clipboard_clear_all();
            tui.clipboard_start_group();
            tui.clipboard_add_chunk(owned);
            tui.clipboard_send_to_system() catch {};
        },
        .osc_paste_request => {
            // Terminal app requested clipboard contents via OSC 52.
            // Assemble from flow clipboard history and respond.
            if (tui.clipboard_get_history()) |history| {
                var buf: std.Io.Writer.Allocating = .init(self.allocator);
                defer buf.deinit();
                var first = true;
                for (history) |chunk| {
                    if (first) first = false else buf.writer.writeByte('\n') catch break;
                    buf.writer.writeAll(chunk.text) catch break;
                }
                self.vt.vt.respondOsc52Paste(buf.written());
            }
        },
        .shell_state_change => {},
    }
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
            get_running_cmd(&w.writer) catch {};
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

const Vt = struct {
    vt: Terminal,
    env: std.process.Environ.Map,
    write_buf: [4096]u8,
    pty_pid: ?tp.pid = null,
    cwd: std.ArrayListUnmanaged(u8) = .empty,
    title: std.ArrayListUnmanaged(u8) = .empty,
    /// App-specified override colours (from OSC 10/11/12). null = use theme.
    app_fg: ?[3]u8 = null,
    app_bg: ?[3]u8 = null,
    app_cursor: ?[3]u8 = null,
    process_exited: bool = false,
    on_exit: TerminalOnExit,

    fn init(io: std.Io, allocator: std.mem.Allocator, cmd_argv: []const []const u8, env: std.process.Environ.Map, rows: u16, cols: u16, on_exit: TerminalOnExit) !void {
        const home = env.get("HOME") orelse "/tmp";

        global_vt = .{
            .vt = undefined,
            .env = env,
            .write_buf = undefined, // managed via self.vt's pty_writer pointer
            .pty_pid = null,
            .on_exit = on_exit,
        };
        const self = &global_vt.?;
        self.vt = try Terminal.init(
            io,
            allocator,
            cmd_argv,
            &env,
            .{
                .winsize = .{ .rows = rows, .cols = cols, .x_pixel = 0, .y_pixel = 0 },
                .scrollback_size = tui.config().terminal_scrollback_size,
                .initial_working_directory = blk: {
                    const project = tp.env.get().str("project");
                    break :blk if (project.len > 0) project else home;
                },
            },
            &self.write_buf,
        );

        const theme = tui.active_theme();
        if (theme.editor.fg) |fg| self.vt.fg_color = color.u24_to_u8s(fg.color);
        if (theme.editor.bg) |bg| self.vt.bg_color = color.u24_to_u8s(bg.color);

        try self.vt.spawn();
        self.pty_pid = try pty.spawn(allocator, &self.vt);
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.cwd.deinit(allocator);
        self.title.deinit(allocator);
        if (self.pty_pid) |pid| {
            pid.send(.{"quit"}) catch {};
            pid.deinit();
            self.pty_pid = null;
        }
        self.vt.deinit();
        self.env.deinit();
        std.log.debug("terminal: vt destroyed", .{});
    }

    pub fn resize(self: *@This(), pos: Widget.Box) void {
        const cols: u16 = @intCast(@max(1, pos.w));
        const rows: u16 = @intCast(@max(1, pos.h));
        self.vt.resize(.{
            .rows = rows,
            .cols = cols,
            .x_pixel = 0,
            .y_pixel = 0,
        }) catch |e| {
            std.log.err("terminal: resize failed: {}", .{e});
        };
    }
};
var global_vt: ?Vt = null;

pub fn is_vt_running() bool {
    return if (global_vt) |vt| !vt.process_exited else false;
}

pub fn get_running_cmd(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const cmd_argv = if (global_vt) |vt| vt.vt.cmd.argv else &.{};
    if (cmd_argv.len > 0) {
        _ = argv.write(writer, cmd_argv) catch {};
    }
}

// Platform-specific pty actor: POSIX uses tp.file_descriptor + SIGCHLD,
// Windows uses tp.file_stream with IOCP overlapped reads on the ConPTY output pipe.
const pty = if (builtin.os.tag == .windows) pty_windows else pty_posix;

const pty_posix = struct {
    const Parser = Terminal.Parser;

    const Receiver = tp.Receiver(*@This());

    allocator: std.mem.Allocator,
    vt: *Terminal,
    fd: tp.file_descriptor,
    pty_fd: std.posix.fd_t,
    parser: Parser,
    receiver: Receiver,
    parent: tp.pid,
    err_code: i64 = 0,
    sigchld: ?tp.signal = null,

    pub fn spawn(allocator: std.mem.Allocator, vt: *Terminal) !tp.pid {
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .vt = vt,
            .fd = undefined,
            .pty_fd = vt.ptyFd(),
            .parser = .{ .buf = try .initCapacity(allocator, 128) },
            .receiver = Receiver.init(pty_receive, dtor, self),
            .parent = tp.self_pid().clone(),
        };
        return tp.spawn_link(allocator, self, start, "pty_actor");
    }

    fn dtor(self: *@This()) void {
        self.fd.deinit();
        self.parser.buf.deinit();
        self.parent.deinit();
        self.allocator.destroy(self);
    }

    fn deinit(self: *@This()) void {
        std.log.debug("terminal: pty actor deinit (pid={?})", .{self.vt.cmd.pid});
        if (self.sigchld) |s| s.deinit();
    }

    fn start(self: *@This()) tp.result {
        errdefer self.deinit();
        self.fd = tp.file_descriptor.init("pty", self.pty_fd) catch |e| {
            std.log.debug("terminal: pty fd init failed: {}", .{e});
            return tp.exit_error(e, @errorReturnTrace());
        };
        self.fd.wait_read() catch |e| {
            std.log.debug("terminal: pty initial wait_read failed: {}", .{e});
            return tp.exit_error(e, @errorReturnTrace());
        };
        self.sigchld = tp.signal.init(@intFromEnum(std.posix.SIG.CHLD), tp.message.fmt(.{"sigchld"})) catch |e| {
            std.log.debug("terminal: SIGCHLD signal init failed: {}", .{e});
            return tp.exit_error(e, @errorReturnTrace());
        };
        tp.receive(&self.receiver);
    }

    fn pty_process_terminal_event(ctx: *Terminal.Event.HandlerContext, event: Terminal.Event) error{TerminalHandlerFailed}!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.send_event(event) catch error.TerminalHandlerFailed;
    }

    fn send_event(self: *@This(), event: Terminal.Event) error{TerminalHandlerFailed}!void {
        self.parent.send(.{ "VT", event }) catch return error.TerminalHandlerFailed;
    }

    fn send_event_result(self: *@This(), event: Terminal.Event) tp.result {
        self.parent.send(.{ "VT", event }) catch return tp.exit_error(error.TerminalHandlerFailed, @errorReturnTrace());
    }

    fn pty_receive(self: *@This(), _: tp.pid_ref, m: tp.message) tp.result {
        errdefer self.deinit();

        if (try m.match(.{ "fd", "pty", "read_ready" })) {
            self.read_and_process() catch |e| return switch (e) {
                error.Terminated => {
                    std.log.debug("terminal: pty exiting: read loop terminated (process exited)", .{});
                    return tp.exit_normal();
                },
                error.InputOutput => {
                    std.log.debug("terminal: pty exiting: EIO on read (process exited)", .{});
                    return tp.exit_normal();
                },
                error.TerminalHandlerFailed => {
                    std.log.debug("terminal: pty exiting: send to parent failed", .{});
                    return tp.exit_normal();
                },
                error.Unexpected => {
                    std.log.debug("terminal: pty exiting: unexpected error (see preceding log)", .{});
                    return tp.exit_normal();
                },
            };
        } else if (try m.match(.{ "fd", "pty", "read_error", tp.extract(&self.err_code), tp.more })) {
            // thespian fires read_error when the pty fd signals an error condition
            // Treat it the same as EIO: reap the child and signal exit.
            const code = self.vt.cmd.wait();
            std.log.debug("terminal: read_error from fd (err={d}), process exited with code={d}", .{ self.err_code, code });
            try self.send_event_result(.{ .exited = code });
            return tp.exit_normal();
        } else if (try m.match(.{"sigchld"})) {
            // SIGCHLD fires when any child exits. Check if it's our child.
            if (self.vt.cmd.try_wait()) |code| {
                std.log.debug("terminal: child exited (SIGCHLD) with code={d}", .{code});
                try self.send_event_result(.{ .exited = code });
                return tp.exit_normal();
            }
            // Not our child (or already reaped) - re-arm the signal and continue.
            if (self.sigchld) |s| s.deinit();
            self.sigchld = tp.signal.init(@intFromEnum(std.posix.SIG.CHLD), tp.message.fmt(.{"sigchld"})) catch null;
        } else if (try m.match(.{"quit"})) {
            std.log.debug("terminal: pty exiting: received quit", .{});
            return tp.exit_normal();
        } else {
            std.log.debug("terminal: pty exiting: unexpected message", .{});
            return tp.unexpected(m);
        }
    }

    fn read_and_process(self: *@This()) error{ Terminated, InputOutput, TerminalHandlerFailed, Unexpected }!void {
        var buf: [4096]u8 = undefined;

        while (true) {
            const n = std.posix.read(self.vt.ptyFd(), &buf) catch |e| switch (e) {
                error.WouldBlock => {
                    // No more data right now. On Linux, a clean child exit may not
                    // generate a readable event on the pty master - it just starts
                    // returning EIO. Poll for exit here before sleeping in wait_read.
                    // On macOS/FreeBSD the pty master raises EIO directly, so the
                    // try_wait check here is just an extra safety net.
                    if (self.vt.cmd.try_wait()) |code| {
                        std.log.debug("terminal: child exited (detected via try_wait) with code={d}", .{code});
                        try self.send_event(.{ .exited = code });
                        return error.InputOutput;
                    }
                    break;
                },
                error.InputOutput => {
                    const code = self.vt.cmd.wait();
                    std.log.debug("terminal: read EIO, process exited with code={d}", .{code});
                    try self.send_event(.{ .exited = code });
                    return error.InputOutput;
                },
                error.SystemResources,
                error.IsDir,
                error.ConnectionResetByPeer,
                error.NotOpenForReading,
                error.SocketUnconnected,
                error.Canceled,
                error.AccessDenied,
                error.LockViolation,
                error.Unexpected,
                => {
                    std.log.debug("terminal: read unexpected error: {} (pid={?})", .{ e, self.vt.cmd.pid });
                    return error.Unexpected;
                },
            };
            if (n == 0) {
                const code = self.vt.cmd.wait();
                std.log.debug("terminal: read returned 0 bytes (EOF), process exited with code={d}", .{code});
                try self.send_event(.{ .exited = code });
                return error.Terminated;
            }

            switch (self.vt.processOutput(&self.parser, buf[0..n], self, pty_process_terminal_event) catch |e| switch (e) {
                error.WriteFailed,
                error.ReadFailed,
                error.OutOfMemory,
                error.Canceled,
                error.TerminalHandlerFailed,
                => {
                    std.log.debug("terminal: processOutput error: {} (pid={?})", .{ e, self.vt.cmd.pid });
                    return error.Unexpected;
                },
            }) {
                .exited => {
                    std.log.debug("terminal: processOutput returned .exited (process EOF)", .{});
                    return error.Terminated;
                },
                .running => {},
            }
        }

        // Check for child exit once more before sleeping in wait_read.
        // A clean exit with no final output will never make the pty fd readable,
        // so we must detect it here rather than waiting forever.
        if (self.vt.cmd.try_wait()) |code| {
            std.log.debug("terminal: child exited (pre-wait_read check) with code={d}", .{code});
            try self.send_event(.{ .exited = code });
            return error.InputOutput;
        }

        self.fd.wait_read() catch |e| switch (e) {
            error.ThespianFileDescriptorWaitReadFailed => {
                std.log.debug("terminal: wait_read failed: {} (pid={?})", .{ e, self.vt.cmd.pid });
                return error.Unexpected;
            },
        };
    }
};

/// Windows pty actor: reads ConPTY output pipe via tp.file_stream (IOCP overlapped I/O).
///
/// Exit detection: ConPTY does NOT close the output pipe when the child process exits -
/// it keeps it open until ClosePseudoConsole is called. So a pending async read would
/// block forever. Instead we use RegisterWaitForSingleObject on the process handle;
/// when it fires the threadpool callback posts "child_exited" to this actor, which
/// cancels the stream and tears down cleanly.
const pty_windows = struct {
    const Parser = Terminal.Parser;
    const Receiver = tp.Receiver(*@This());
    const windows = std.os.windows;

    // Context struct allocated on the heap and passed to the wait callback.
    // Heap-allocated so its lifetime is independent of the actor.
    const WaitCtx = struct {
        self_pid: tp.pid,
        allocator: std.mem.Allocator,
    };

    allocator: std.mem.Allocator,
    vt: *Terminal,
    stream: ?tp.file_stream = null,
    parser: Parser,
    receiver: Receiver,
    parent: tp.pid,
    wait_handle: ?windows.HANDLE = null,

    pub fn spawn(allocator: std.mem.Allocator, vt: *Terminal) !tp.pid {
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .vt = vt,
            .parser = .{ .buf = try .initCapacity(allocator, 128) },
            .receiver = Receiver.init(pty_receive, dtor, self),
            .parent = tp.self_pid().clone(),
        };
        return tp.spawn_link(allocator, self, start, "pty_actor");
    }

    fn dtor(self: *@This()) void {
        if (self.wait_handle) |wh| {
            _ = UnregisterWait(wh);
            self.wait_handle = null;
        }
        if (self.stream) |s| s.deinit();
        self.parser.buf.deinit();
        self.parent.deinit();
        self.allocator.destroy(self);
    }

    fn deinit(_: *@This()) void {
        std.log.debug("terminal: pty actor (windows) deinit", .{});
    }

    fn start(self: *@This()) tp.result {
        errdefer self.deinit();
        self.stream = tp.file_stream.init("pty_out", self.vt.ptyOutputHandle()) catch |e| {
            std.log.debug("terminal: pty stream init failed: {}", .{e});
            return tp.exit_error(e, @errorReturnTrace());
        };
        self.stream.?.start_read() catch |e| {
            std.log.debug("terminal: pty stream start_read failed: {}", .{e});
            return tp.exit_error(e, @errorReturnTrace());
        };

        // Register a one-shot wait on the process handle. When the child exits
        // the threadpool fires on_child_exit, which sends "child_exited" to us.
        // This is the only reliable way to detect ConPTY child exit without polling,
        // since ConPTY keeps the output pipe open until ClosePseudoConsole.
        const process_handle = self.vt.cmd.process_handle orelse {
            std.log.debug("terminal: pty actor: no process handle to wait on", .{});
            return tp.exit_error(error.NoProcessHandle, @errorReturnTrace());
        };
        const ctx = self.allocator.create(WaitCtx) catch |e|
            return tp.exit_error(e, @errorReturnTrace());
        ctx.* = .{
            .self_pid = tp.self_pid().clone(),
            .allocator = self.allocator,
        };
        var wh: windows.HANDLE = undefined;
        // WT_EXECUTEONLYONCE: callback fires once then the wait is auto-unregistered.
        const WT_EXECUTEONLYONCE: windows.ULONG = 0x00000008;
        if (RegisterWaitForSingleObject(&wh, process_handle, on_child_exit, ctx, INFINITE, WT_EXECUTEONLYONCE) == .FALSE) {
            ctx.self_pid.deinit();
            self.allocator.destroy(ctx);
            std.log.debug("terminal: RegisterWaitForSingleObject failed", .{});
            return tp.exit_error(error.RegisterWaitFailed, @errorReturnTrace());
        }
        self.wait_handle = wh;

        tp.receive(&self.receiver);
    }

    /// Threadpool callback - called when the process handle becomes signaled.
    /// Must be fast and non-blocking. Sends "child_exited" to the pty actor.
    fn on_child_exit(ctx_ptr: ?*anyopaque, _: windows.BOOLEAN) callconv(.winapi) void {
        const ctx: *WaitCtx = @ptrCast(@alignCast(ctx_ptr orelse return));
        defer {
            ctx.self_pid.deinit();
            ctx.allocator.destroy(ctx);
        }
        ctx.self_pid.send(.{"child_exited"}) catch {};
    }

    fn pty_process_terminal_event(ctx: *Terminal.Event.HandlerContext, event: Terminal.Event) error{TerminalHandlerFailed}!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.send_event(event) catch error.TerminalHandlerFailed;
    }

    fn send_event(self: *@This(), event: Terminal.Event) error{TerminalHandlerFailed}!void {
        self.parent.send(.{ "VT", event }) catch return error.TerminalHandlerFailed;
    }

    fn send_event_result(self: *@This(), event: Terminal.Event) tp.result {
        self.parent.send(.{ "VT", event }) catch return tp.exit_error(error.TerminalHandlerFailed, @errorReturnTrace());
    }

    fn pty_receive(self: *@This(), _: tp.pid_ref, m: tp.message) tp.result {
        errdefer self.deinit();

        var bytes: []const u8 = "";
        var err_code: i64 = 0;
        var err_msg: []const u8 = "";

        if (try m.match(.{"child_exited"})) {
            self.wait_handle = null;
            if (self.stream) |s| s.cancel() catch {};
            const code = self.vt.cmd.wait();
            std.log.debug("terminal: child exited (process wait), code={d}", .{code});
            try self.send_event_result(.{ .exited = code });
            return tp.exit_normal();
        } else if (try m.match(.{ "stream", "pty_out", "read_complete", tp.extract(&bytes) })) {
            switch (self.vt.processOutput(&self.parser, bytes, self, pty_process_terminal_event) catch |e| {
                std.log.debug("terminal: processOutput error: {}", .{e});
                return tp.exit_normal();
            }) {
                .exited => {
                    std.log.debug("terminal: processOutput returned .exited", .{});
                    return tp.exit_normal();
                },
                .running => {},
            }
            self.stream.?.start_read() catch |e| {
                std.log.debug("terminal: pty stream re-arm failed: {}", .{e});
                return tp.exit_normal();
            };
        } else if (try m.match(.{ "stream", "pty_out", "read_error", tp.extract(&err_code), tp.extract(&err_msg) })) {
            std.log.debug("terminal: ConPTY stream error: {d} {s}", .{ err_code, err_msg });
            const code = self.vt.cmd.wait();
            try self.send_event_result(.{ .exited = code });
            return tp.exit_normal();
        } else if (try m.match(.{"quit"})) {
            std.log.debug("terminal: pty actor (windows) received quit", .{});
            return tp.exit_normal();
        } else {
            std.log.debug("terminal: pty actor (windows) unexpected message", .{});
            return tp.unexpected(m);
        }
    }

    // Win32 extern declarations
    extern "kernel32" fn RegisterWaitForSingleObject(
        phNewWaitObject: *windows.HANDLE,
        hObject: windows.HANDLE,
        Callback: *const fn (?*anyopaque, windows.BOOLEAN) callconv(.winapi) void,
        Context: ?*anyopaque,
        dwMilliseconds: windows.DWORD,
        dwFlags: windows.ULONG,
    ) callconv(.winapi) windows.BOOL;

    extern "kernel32" fn UnregisterWait(
        WaitHandle: windows.HANDLE,
    ) callconv(.winapi) windows.BOOL;

    const INFINITE: windows.DWORD = 0xFFFFFFFF;
};
