const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const project_manager = @import("project_manager");

const tui = @import("../../tui.zig");
const MessageFilter = @import("../../MessageFilter.zig");
pub const Type = @import("palette.zig").Create(@This());
const module_name = @typeName(@This());
const Widget = @import("../../Widget.zig");

pub const label = "Status";
pub const name = " status";
pub const description = "vcs status";
pub const icon = "󰈞  ";
pub const placement = .top_center;
pub const no_query = true;
pub const preserve_entry_order = true;

pub const Kind = enum { header, empty, file };
pub const Section = enum { staged, unstaged, untracked };

const sections = [_]struct { section: Section, label: []const u8 }{
    .{ .section = .staged, .label = "Changes to be committed:" },
    .{ .section = .unstaged, .label = "Changes not staged for commit:" },
    .{ .section = .untracked, .label = "Untracked files:" },
};
const empty_label = "  (no files)";

pub const Entry = struct {
    label: []const u8,
    path: []const u8 = "",
    file_icon: []const u8 = "",
    file_color: u24 = 0,
    kind: Kind,
    section: Section,
    status: u8 = ' ',
};

const File = struct {
    path: []const u8,
    orig_path: []const u8,
    file_icon: []const u8,
    file_color: u24,
    x: u8,
    y: u8,

    fn deinit(self: *const File, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.orig_path);
        allocator.free(self.file_icon);
    }

    fn is_unmerged(self: *const File) bool {
        return self.x == 'U' or self.y == 'U' or
            (self.x == 'A' and self.y == 'A') or
            (self.x == 'D' and self.y == 'D');
    }

    fn status(self: *const File, section: Section) ?u8 {
        return switch (section) {
            .staged => if (self.x == '.' or self.x == '?' or self.is_unmerged()) null else self.x,
            .unstaged => if (self.is_unmerged()) 'U' else if (self.y == '.' or self.y == '?') null else self.y,
            .untracked => if (self.x == '?') '?' else null,
        };
    }
};

pub const ValueType = struct {
    files: std.ArrayList(File) = .empty,
};
pub const defaultValue: ValueType = .{};

pub fn load_entries(palette: *Type) !usize {
    tui.message_filters().add(MessageFilter.bind(palette, receive_project_manager)) catch {};
    try project_manager.request_vcs_status_files();
    project_manager.request_vcs_status() catch {};
    return 6;
}

pub fn clear_entries(palette: *Type) void {
    for (palette.entries.items) |entry| if (entry.kind == .file) {
        palette.allocator.free(entry.label);
        palette.allocator.free(entry.path);
        palette.allocator.free(entry.file_icon);
    };
    palette.entries.clearRetainingCapacity();
}

fn clear_files(palette: *Type) void {
    for (palette.value.files.items) |*file| file.deinit(palette.allocator);
    palette.value.files.clearRetainingCapacity();
}

pub fn deinit(palette: *Type) void {
    tui.message_filters().remove_ptr(palette);
    clear_entries(palette);
    clear_files(palette);
    palette.value.files.deinit(palette.allocator);
}

pub fn update_count_hint(palette: *Type) void {
    palette.inputbox.hint.clearRetainingCapacity();
}

fn receive_project_manager(palette: *Type, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    if (try cbor.match(m.buf, .{ "vcs_status", tp.more })) {
        project_manager.request_vcs_status_files() catch {};
        return false;
    }
    if (!(cbor.match(m.buf, .{ "PRJ", tp.more }) catch false)) return false;

    var file_path: []const u8 = undefined;
    var file_type: []const u8 = undefined;
    var file_icon: []const u8 = undefined;
    var file_color: u24 = undefined;
    var x: []const u8 = undefined;
    var y: []const u8 = undefined;
    var orig_path: []const u8 = undefined;

    if (try cbor.match(m.buf, .{
        "PRJ",
        "vcs_status_files",
        tp.extract(&file_path),
        tp.extract(&file_type),
        tp.extract(&file_icon),
        tp.extract(&file_color),
        tp.extract(&x),
        tp.extract(&y),
        tp.extract(&orig_path),
    })) {
        if (x.len != 1 or y.len != 1) return true;
        try append_file(palette, file_path, orig_path, file_icon, file_color, x[0], y[0]);
    } else if (try cbor.match(m.buf, .{ "PRJ", "vcs_status_files_done" })) {
        try update_entries(palette);
        clear_files(palette);
        tui.need_render(@src());
    } else return false;
    return true;
}

fn append_file(palette: *Type, path: []const u8, orig_path: []const u8, file_icon: []const u8, file_color: u24, x: u8, y: u8) !void {
    const allocator = palette.allocator;
    const path_ = try allocator.dupe(u8, path);
    errdefer allocator.free(path_);
    const orig_path_ = try allocator.dupe(u8, orig_path);
    errdefer allocator.free(orig_path_);
    const file_icon_ = try allocator.dupe(u8, file_icon);
    errdefer allocator.free(file_icon_);
    (try palette.value.files.addOne(allocator)).* = .{
        .path = path_,
        .orig_path = orig_path_,
        .file_icon = file_icon_,
        .file_color = file_color,
        .x = x,
        .y = y,
    };
}

const Target = struct {
    kind: Kind,
    section: Section,
    path: []const u8,
    index: usize,

    fn matches(self: *const Target, entry: *const Entry) bool {
        return self.kind == entry.kind and self.section == entry.section and std.mem.eql(u8, self.path, entry.path);
    }
};

fn selected_index(palette: *Type) ?usize {
    const idx = palette.view_pos + (palette.list_box.selected orelse return null);
    return if (idx < palette.entries.items.len) idx else null;
}

fn update_entries(palette: *Type) !void {
    const allocator = palette.allocator;
    var target: ?Target = null;
    if (selected_index(palette)) |idx| {
        const entry = &palette.entries.items[idx];
        target = .{
            .kind = entry.kind,
            .section = entry.section,
            .path = try allocator.dupe(u8, entry.path),
            .index = idx,
        };
    }
    defer if (target) |t| allocator.free(t.path);

    clear_entries(palette);
    for (sections) |section| {
        (try palette.entries.addOne(allocator)).* = .{ .label = section.label, .kind = .header, .section = section.section };
        var count: usize = 0;
        for (palette.value.files.items) |*file| {
            const status = file.status(section.section) orelse continue;
            try append_entry(palette, file, section.section, status);
            count += 1;
        }
        if (count == 0)
            (try palette.entries.addOne(allocator)).* = .{ .label = empty_label, .kind = .empty, .section = section.section };
    }

    const select_idx = if (target) |*t| find_target(palette, t) else first_file(palette);
    palette.initial_selected = select_idx + 1;
    try palette.start_query(0);
}

fn find_target(palette: *Type, target: *const Target) usize {
    const entries = palette.entries.items;
    for (entries, 0..) |*entry, i| if (target.matches(entry)) return i;
    var idx = @min(target.index, entries.len - 1);
    while (idx > 0 and entries[idx].kind == .empty) idx -= 1;
    return idx;
}

fn first_file(palette: *Type) usize {
    for (palette.entries.items, 0..) |*entry, i| if (entry.kind == .file) return i;
    return 0;
}

fn append_entry(palette: *Type, file: *const File, section: Section, status: u8) !void {
    const allocator = palette.allocator;
    const display = if (file.orig_path.len > 0)
        try std.fmt.allocPrint(allocator, "{s} -> {s}", .{ file.orig_path, file.path })
    else
        try allocator.dupe(u8, file.path);
    errdefer allocator.free(display);
    const path = try allocator.dupe(u8, file.path);
    errdefer allocator.free(path);
    const file_icon = try allocator.dupe(u8, file.file_icon);
    errdefer allocator.free(file_icon);
    (try palette.entries.addOne(allocator)).* = .{
        .label = display,
        .path = path,
        .file_icon = file_icon,
        .file_color = file.file_color,
        .kind = .file,
        .section = section,
        .status = status,
    };
}

pub fn add_list_box_entry(palette: *Type, entry: *Entry, _: ?[]const usize) !void {
    var value: std.Io.Writer.Allocating = .init(palette.allocator);
    defer value.deinit();
    const writer = &value.writer;
    const indicator = if (entry.kind == .file)
        if (tui.get_buffer_manager()) |bm| tui.get_file_state_indicator(bm, entry.path) else ""
    else
        "";
    try cbor.writeValue(writer, entry.kind);
    try cbor.writeValue(writer, entry.status);
    try cbor.writeValue(writer, entry.path);
    try cbor.writeValue(writer, entry.label);
    try cbor.writeValue(writer, entry.file_icon);
    try cbor.writeValue(writer, entry.file_color);
    try cbor.writeValue(writer, indicator);
    try palette.list_box.add_item_with_handler(value.written(), select);
    palette.items += 1;
}

const Item = struct {
    kind: Kind,
    status: u8,
    path: []const u8,
    label: []const u8,
    file_icon: []const u8,
    file_color: u24,
    indicator: []const u8,

    fn decode(button: *Type.ButtonType) ?Item {
        var item: Item = undefined;
        var iter = button.opts.label;
        if (!(cbor.matchValue(&iter, tp.extract(&item.kind)) catch false)) return null;
        if (!(cbor.matchValue(&iter, tp.extract(&item.status)) catch false)) return null;
        if (!(cbor.matchString(&iter, &item.path) catch false)) return null;
        if (!(cbor.matchString(&iter, &item.label) catch false)) return null;
        if (!(cbor.matchString(&iter, &item.file_icon) catch false)) return null;
        if (!(cbor.matchValue(&iter, tp.extract(&item.file_color)) catch false)) return null;
        if (!(cbor.matchString(&iter, &item.indicator) catch false)) return null;
        return item;
    }
};

pub fn is_selectable(button: *Type.ButtonType) bool {
    const item = Item.decode(button) orelse return false;
    return item.kind != .empty;
}

fn status_style(theme: *const Widget.Theme, status: u8) Widget.Theme.Style {
    return switch (status) {
        'A', '?' => theme.editor_gutter_added,
        'D' => theme.editor_gutter_deleted,
        else => theme.editor_gutter_modified,
    };
}

pub fn on_render_list_box(_: *Type, button: *Type.ButtonType, theme: *const Widget.Theme, selected_: bool) bool {
    const item = Item.decode(button) orelse return false;
    const selectable = item.kind != .empty;
    const selected = selectable and selected_;
    const hover = selectable and button.hover;
    const active = selectable and button.active;
    const style_base = theme.editor_widget;
    const style_label = if (active) theme.editor_cursor else if (hover or selected) theme.editor_selection else theme.editor_widget;
    const style_hint = if (tui.find_scope_style(theme, "entity.name")) |sty| sty.style else style_label;
    const plane = &button.plane;
    plane.set_base_style(style_base);
    plane.erase();
    plane.home();
    plane.set_style(style_label);
    if (active or hover or selected) {
        plane.fill(" ");
        plane.home();
    }
    plane.set_style(style_hint);
    tui.render_pointer(plane, selected);
    switch (item.kind) {
        .header => {
            _ = plane.print("{s}", .{item.label}) catch {};
        },
        .empty => {
            plane.set_style(theme.input_placeholder);
            _ = plane.print("{s}", .{item.label}) catch {};
        },
        .file => {
            plane.set_style(style_label);
            plane.set_style(.{ .fg = status_style(theme, item.status).fg });
            _ = plane.print("{c} ", .{item.status}) catch {};
            _ = tui.render_file_icon(plane, item.file_icon, item.file_color);
            plane.set_style(style_label);
            _ = plane.print("{s} ", .{item.label}) catch {};
            plane.set_style(style_hint);
            _ = plane.print_aligned_right(0, "{s} ", .{item.indicator}) catch {};
        },
    }
    return false;
}

fn select(list_box: **Type.ListBoxType, button: *Type.ButtonType, _: Type.Pos) void {
    const item = Item.decode(button) orelse return;
    if (item.kind != .file) return;
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| list_box.*.opts.ctx.logger.err(module_name, e);
    tp.self_pid().send(.{ "cmd", "navigate", .{ .file = item.path } }) catch |e| list_box.*.opts.ctx.logger.err(module_name, e);
}
