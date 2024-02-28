const eql = @import("std").mem.eql;
const fmt = @import("std").fmt;
const time = @import("std").time;
const Allocator = @import("std").mem.Allocator;

const nc = @import("notcurses");
const tp = @import("thespian");
const Buffer = @import("Buffer");
const color = @import("color");
const syntax = @import("syntax");

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");
const EventHandler = @import("EventHandler.zig");
const mainview = @import("mainview.zig");
const ed = @import("editor.zig");

const A = nc.Align;

pub const name = @typeName(Self);

plane: nc.Plane,
editor: *ed.Editor,
need_render: bool = true,
need_clear: bool = false,
theme: ?*const Widget.Theme = null,
theme_name: []const u8 = "",
pos_cache: ed.PosToWidthCache,

const Self = @This();

pub fn create(a: Allocator, parent: nc.Plane) !Widget {
    if (tui.current().mainview.dynamic_cast(mainview)) |mv_| if (mv_.get_editor()) |editor| {
        const self: *Self = try a.create(Self);
        self.* = .{
            .plane = try nc.Plane.init(&(Widget.Box{}).opts_vscroll(name), parent),
            .editor = editor,
            .pos_cache = try ed.PosToWidthCache.init(a),
        };

        try editor.handlers.add(EventHandler.bind(self, ed_receive));
        return Widget.to(self);
    };
    return error.NotFound;
}

pub fn deinit(self: *Self, a: Allocator) void {
    self.editor.handlers.remove_ptr(self);
    tui.current().message_filters.remove_ptr(self);
    self.plane.deinit();
    a.destroy(self);
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    self.reset_style();
    self.theme = theme;
    if (self.theme_name.ptr != theme.name.ptr) {
        self.theme_name = theme.name;
        self.need_render = true;
    }
    if (self.need_render) {
        self.need_render = false;
        const cursor = self.editor.get_primary().cursor;
        self.inspect_location(cursor.row, cursor.col);
    }
    return false;
}

pub fn handle_resize(self: *Self, pos: Widget.Box) void {
    self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
    self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;
    self.need_render = true;
}

fn ed_receive(self: *Self, _: tp.pid_ref, m: tp.message) tp.result {
    var row: usize = 0;
    var col: usize = 0;
    if (try m.match(.{ "E", "pos", tp.any, tp.extract(&row), tp.extract(&col) }))
        return self.inspect_location(row, col);
    if (try m.match(.{ "E", "location", "modified", tp.extract(&row), tp.extract(&col), tp.more })) {
        self.need_render = true;
        return;
    }
    if (try m.match(.{ "E", "close" }))
        return self.clear();
}

fn clear(self: *Self) void {
    self.plane.erase();
    self.plane.home();
}

fn inspect_location(self: *Self, row: usize, col: usize) void {
    self.need_clear = true;
    const syn = if (self.editor.syntax) |p| p else return;
    syn.highlights_at_point(self, dump_highlight, .{ .row = @intCast(row), .column = @intCast(col) });
}

fn get_buffer_text(self: *Self, buf: []u8, sel: Buffer.Selection) ?[]const u8 {
    const root = self.editor.get_current_root() orelse return null;
    return root.get_range(sel, buf, null, null) catch return null;
}

fn dump_highlight(self: *Self, range: syntax.Range, scope: []const u8, id: u32, _: usize) error{Stop}!void {
    const sel = self.pos_cache.range_to_selection(range, self.editor.get_current_root() orelse return) orelse return;
    if (self.need_clear) {
        self.need_clear = false;
        self.clear();
    }

    if (self.editor.matches.items.len == 0) {
        (self.editor.matches.addOne() catch return).* = ed.Match.from_selection(sel);
    } else if (self.editor.matches.items.len == 1) {
        self.editor.matches.items[0] = ed.Match.from_selection(sel);
    }

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
        self.plane.set_fg_rgb(color.max_contrast(c, theme.panel.fg orelse 0xFFFFFF, theme.panel.bg orelse 0x000000)) catch {};
        _ = self.plane.print("#{x}", .{c}) catch return;
        self.reset_style();
    }
}

fn show_font(self: *Self, font: ?Widget.Theme.FontStyle) void {
    if (font) |fs| switch (fs) {
        .normal => {
            self.plane.set_styles(nc.style.none);
            _ = self.plane.print(" normal", .{}) catch return;
        },
        .bold => {
            self.plane.set_styles(nc.style.bold);
            _ = self.plane.print(" bold", .{}) catch return;
        },
        .italic => {
            self.plane.set_styles(nc.style.italic);
            _ = self.plane.print(" italic", .{}) catch return;
        },
        .underline => {
            self.plane.set_styles(nc.style.underline);
            _ = self.plane.print(" underline", .{}) catch return;
        },
        .strikethrough => {
            self.plane.set_styles(nc.style.struck);
            _ = self.plane.print(" strikethrough", .{}) catch return;
        },
    };
    self.plane.set_styles(nc.style.none);
}

fn reset_style(self: *Self) void {
    tui.set_base_style(&self.plane, " ", (self.theme orelse return).panel);
}
