const Allocator = @import("std").mem.Allocator;

const tp = @import("thespian");
const Buffer = @import("Buffer");
const color = @import("color");
const syntax = @import("syntax");

const Plane = @import("renderer").Plane;
const style = @import("renderer").style;
const EventHandler = @import("EventHandler");

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const mainview = @import("mainview.zig");
const ed = @import("editor.zig");

pub const name = @typeName(Self);

plane: Plane,
editor: *ed.Editor,
theme: ?*const Widget.Theme = null,
pos_cache: ed.PosToWidthCache,
last_node: usize = 0,

const Self = @This();

pub fn create(allocator: Allocator, parent: Plane) !Widget {
    if (tui.current().mainview.dynamic_cast(mainview)) |mv_| if (mv_.get_editor()) |editor| {
        const self: *Self = try allocator.create(Self);
        self.* = .{
            .plane = try Plane.init(&(Widget.Box{}).opts_vscroll(name), parent),
            .editor = editor,
            .pos_cache = try ed.PosToWidthCache.init(allocator),
        };

        try editor.handlers.add(EventHandler.bind(self, ed_receive));
        return Widget.to(self);
    };
    return error.NotFound;
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.editor.handlers.remove_ptr(self);
    tui.current().message_filters.remove_ptr(self);
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    self.reset_style();
    self.theme = theme;
    self.plane.erase();
    self.plane.home();
    const cursor = self.editor.get_primary().cursor;
    self.inspect_location(cursor.row, cursor.col);
    return false;
}

pub fn handle_resize(self: *Self, pos: Widget.Box) void {
    self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
    self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;
}

fn ed_receive(self: *Self, _: tp.pid_ref, m: tp.message) tp.result {
    if (try m.match(.{ "E", "close" }))
        return self.clear();
}

fn clear(self: *Self) void {
    self.plane.erase();
    self.plane.home();
}

fn inspect_location(self: *Self, row: usize, col: usize) void {
    const syn = self.editor.syntax orelse return;
    const root = (self.editor.buffer orelse return).root;
    const col_pos = root.get_line_width_to_pos(row, col, self.editor.metrics) catch return;
    syn.highlights_at_point(self, dump_highlight, .{ .row = @intCast(row), .column = @intCast(col_pos) });
}

fn get_buffer_text(self: *Self, buf: []u8, sel: Buffer.Selection) ?[]const u8 {
    const root = self.editor.get_current_root() orelse return null;
    return root.get_range(sel, buf, null, null, self.plane.metrics(self.editor.tab_width)) catch return null;
}

fn dump_highlight(self: *Self, range: syntax.Range, scope: []const u8, id: u32, _: usize, ast_node: *const syntax.Node) error{Stop}!void {
    const sel = self.pos_cache.range_to_selection(range, self.editor.get_current_root() orelse return, self.editor.metrics) orelse return;

    var update_match: enum { no, add, set } = .no;
    var match = ed.Match.from_selection(sel);
    if (self.theme) |theme| match.style = .{ .bg = theme.editor_gutter_modified.fg };
    switch (self.editor.matches.items.len) {
        0 => {
            (self.editor.matches.addOne() catch return).* = match;
            update_match = .add;
        },
        1 => {
            self.editor.matches.items[0] = match;
            update_match = .add;
        },
        2 => {
            self.editor.matches.items[0] = match;
            update_match = .set;
        },
        else => {},
    }

    const node_token = @intFromPtr(ast_node);
    if (node_token != self.last_node) {
        const ast = ast_node.asSExpressionString();
        _ = self.plane.print("node: {s}\n", .{ast}) catch {};
        syntax.Node.freeSExpressionString(ast);
        const parent = ast_node.getParent();
        if (!parent.isNull()) {
            const ast_parent = parent.asSExpressionString();
            _ = self.plane.print("parent: {s}\n", .{ast_parent}) catch {};
            syntax.Node.freeSExpressionString(ast_parent);
            const sel_parent = self.pos_cache.range_to_selection(parent.getRange(), self.editor.get_current_root() orelse return, self.editor.metrics) orelse return;
            var match_parent = ed.Match.from_selection(sel_parent);
            if (self.theme) |theme| match_parent.style = .{ .bg = theme.editor_gutter_added.fg };
            switch (update_match) {
                .add => (self.editor.matches.addOne() catch return).* = match_parent,
                .set => self.editor.matches.items[1] = match_parent,
                .no => {},
            }
        }
    }
    self.last_node = @intFromPtr(ast_node);

    var buf: [1024]u8 = undefined;
    const text = self.get_buffer_text(&buf, sel) orelse "";
    if (self.editor.style_lookup(self.theme, scope, id)) |token| {
        if (text.len > 14) {
            _ = self.plane.print("scope: {s} -> \"{s}...\" matched: {s}", .{
                scope,
                text[0..15],
                Widget.scopes[token.id],
            }) catch {};
        } else {
            _ = self.plane.print("scope: {s} -> \"{s}\" matched: {s}", .{
                scope,
                text,
                Widget.scopes[token.id],
            }) catch {};
        }
        self.show_color("fg", token.style.fg);
        self.show_color("bg", token.style.bg);
        self.show_font(token.style.fs);
        _ = self.plane.print("\n", .{}) catch {};
        return;
    }
    _ = self.plane.print("scope: {s} -> \"{s}\"\n", .{ scope, text }) catch return;
}

fn show_color(self: *Self, tag: []const u8, c_: ?Widget.Theme.Color) void {
    const theme = self.theme orelse return;
    if (c_) |c| {
        _ = self.plane.print(" {s}:", .{tag}) catch return;
        self.plane.set_bg_rgb(c) catch {};
        self.plane.set_fg_rgb(.{ .color = color.max_contrast(
            c.color,
            (theme.panel.fg orelse Widget.Theme.Color{ .color = 0xFFFFFF }).color,
            (theme.panel.bg orelse Widget.Theme.Color{ .color = 0x000000 }).color,
        ) }) catch {};
        _ = self.plane.print("#{x}", .{c.color}) catch return;
        self.reset_style();
        if (c.alpha != 0xff)
            _ = self.plane.print(" ɑ{x}", .{c.alpha}) catch return;
    }
}

fn show_font(self: *Self, font: ?Widget.Theme.FontStyle) void {
    if (font) |fs| switch (fs) {
        .normal => {
            self.plane.set_styles(style.normal);
            _ = self.plane.print(" normal", .{}) catch return;
        },
        .bold => {
            self.plane.set_styles(style.bold);
            _ = self.plane.print(" bold", .{}) catch return;
        },
        .italic => {
            self.plane.set_styles(style.italic);
            _ = self.plane.print(" italic", .{}) catch return;
        },
        .underline => {
            self.plane.set_styles(style.underline);
            _ = self.plane.print(" underline", .{}) catch return;
        },
        .undercurl => {
            self.plane.set_styles(style.undercurl);
            _ = self.plane.print(" undercurl", .{}) catch return;
        },
        .strikethrough => {
            self.plane.set_styles(style.struck);
            _ = self.plane.print(" strikethrough", .{}) catch return;
        },
    };
    self.plane.set_styles(style.normal);
}

fn reset_style(self: *Self) void {
    self.plane.set_base_style((self.theme orelse return).panel);
}
