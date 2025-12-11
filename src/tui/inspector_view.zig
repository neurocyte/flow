const Allocator = @import("std").mem.Allocator;

const tp = @import("thespian");
const Buffer = @import("Buffer");
const color = @import("color");
const syntax = @import("syntax");

const Plane = @import("renderer").Plane;
const style = @import("renderer").style;
const styles = @import("renderer").styles;
const EventHandler = @import("EventHandler");

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const ed = @import("editor.zig");

pub const name = @typeName(Self);

plane: Plane,
editor: *ed.Editor,
theme: ?*const Widget.Theme = null,
last_node: usize = 0,

const Self = @This();
const widget_type: Widget.Type = .panel;

pub fn create(allocator: Allocator, parent: Plane) !Widget {
    const editor = tui.get_active_editor() orelse return error.NotFound;
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    const container = try WidgetList.createHStyled(allocator, parent, "panel_frame", .dynamic, widget_type);
    self.* = .{
        .plane = try Plane.init(&(Widget.Box{}).opts_vscroll(name), parent),
        .editor = editor,
    };
    try editor.handlers.add(EventHandler.bind(self, ed_receive));
    container.ctx = self;
    try container.add(Widget.to(self));
    return container.widget();
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.editor.handlers.remove_ptr(self);
    tui.message_filters().remove_ptr(self);
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
    if (!syn.highlights_at_point(self, dump_highlight, .{ .row = @intCast(row), .column = @intCast(col_pos) }))
        self.ast_at_point(syn, row, col_pos, root);
}

fn get_buffer_text(self: *Self, buf: []u8, sel: Buffer.Selection) ?[]const u8 {
    const root = self.editor.get_current_root() orelse return null;
    return root.get_range(sel, buf, null, null, self.plane.metrics(self.editor.tab_width)) catch return null;
}

fn ast_at_point(self: *Self, syn: anytype, row: usize, col_pos: usize, root: Buffer.Root) void {
    const node = syn.node_at_point_range(.{
        .start_point = .{
            .row = @intCast(row),
            .column = @intCast(col_pos),
        },
        .end_point = .{
            .row = @intCast(row),
            .column = @intCast(col_pos),
        },
        .start_byte = 0,
        .end_byte = 0,
    }) catch return;
    if (node.isNull()) return;

    const sel = ed.CurSel.selection_from_node(node, root, self.editor.metrics);

    self.dump_ast_node(sel, &node);
}

fn dump_highlight(self: *Self, range: syntax.Range, scope: []const u8, id: u32, _: usize, ast_node: *const syntax.Node) error{Stop}!void {
    const sel = Buffer.Selection.from_range(range, self.editor.get_current_root() orelse return, self.editor.metrics);

    self.dump_ast_node(sel, ast_node);

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

fn dump_ast_node(self: *Self, sel: Buffer.Selection, ast_node: *const syntax.Node) void {
    var update_match: enum { no, add, set } = .no;
    var match = ed.Match.from_selection(sel);
    if (self.theme) |theme| match.style = .{ .bg = theme.editor_gutter_modified.fg };
    switch (self.editor.matches.items.len) {
        0 => {
            (self.editor.matches.addOne(self.editor.allocator) catch return).* = match;
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
            const sel_parent = Buffer.Selection.from_range(parent.getRange(), self.editor.get_current_root() orelse return, self.editor.metrics);
            var match_parent = ed.Match.from_selection(sel_parent);
            if (self.theme) |theme| match_parent.style = .{ .bg = theme.editor_gutter_added.fg };
            switch (update_match) {
                .add => (self.editor.matches.addOne(self.editor.allocator) catch return).* = match_parent,
                .set => self.editor.matches.items[1] = match_parent,
                .no => {},
            }
        }
    }
    self.last_node = @intFromPtr(ast_node);
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
            self.plane.set_styles(styles.normal);
            _ = self.plane.print(" normal", .{}) catch return;
        },
        .bold => {
            self.plane.set_styles(styles.bold);
            _ = self.plane.print(" bold", .{}) catch return;
        },
        .italic => {
            self.plane.set_styles(styles.italic);
            _ = self.plane.print(" italic", .{}) catch return;
        },
        .underline => {
            self.plane.set_styles(styles.underline);
            _ = self.plane.print(" underline", .{}) catch return;
        },
        .undercurl => {
            self.plane.set_styles(styles.undercurl);
            _ = self.plane.print(" undercurl", .{}) catch return;
        },
        .strikethrough => {
            self.plane.set_styles(styles.struck);
            _ = self.plane.print(" strikethrough", .{}) catch return;
        },
    };
    self.plane.set_styles(styles.normal);
}

fn reset_style(self: *Self) void {
    self.plane.set_base_style((self.theme orelse return).panel);
}
