const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const command = @import("command");
const project_manager = @import("project_manager");

const tui = @import("../../tui.zig");
const MessageFilter = @import("../../MessageFilter.zig");
pub const Type = @import("palette.zig").Create(@This());
const module_name = @typeName(@This());
const Widget = @import("../../Widget.zig");

pub const label = "Filter tree";
pub const name = "󰙅 tree";
pub const description = "file tree";
pub const icon = "  ";

const max_path_entries = 1024;

pub const NodeType = enum {
    file,
    folder,
};

pub const Node = struct {
    name: []const u8,
    type_: NodeType,
    expanded: bool = false,
    children: ?std.ArrayList(Node) = null,
    parent: ?*Node = null,
    path: []const u8,
    icon: []const u8,
    color: u24,
};

pub const Entry = struct {
    label: []const u8,
    indent: usize,
    file_icon: []const u8,
    file_color: u24,
    node: *Node,
};

pub fn deinit(palette: *Type) void {
    tui.message_filters().remove_ptr(palette);
    palette.value.pending_node = null;
    if (palette.value.follow_path) |path| {
        palette.allocator.free(path);
        palette.value.follow_path = null;
    }
    if (palette.value.root_node) |node| {
        deinit_root_node(palette.allocator, node);
        palette.value.root_node = null;
    }
}

fn deinit_root_node(allocator: std.mem.Allocator, node: *Node) void {
    deinit_node(allocator, node);
    allocator.destroy(node);
}

fn deinit_node(allocator: std.mem.Allocator, node: *Node) void {
    allocator.free(node.name);
    allocator.free(node.path);
    allocator.free(node.icon);
    if (node.children) |*children| {
        for (children.items) |*child| {
            deinit_node(allocator, child);
        }
        children.deinit(allocator);
    }
}

pub const ValueType = struct {
    root_node: ?*Node = null,
    pending_node: ?*Node = null,
    follow_path: ?[]const u8 = null,
};
pub const defaultValue: ValueType = .{};

fn get_node_icon_and_color(node: *const Node) struct { []const u8, u24 } {
    if (node.type_ == .folder)
        return if (node.expanded) .{ "󰝰", 0 } else .{ "󰉋", 0 };
    return .{ node.icon, node.color };
}

fn build_visible_list(palette: *Type, node: *Node, depth: usize) !void {
    const file_icon, const file_color = get_node_icon_and_color(node);
    try palette.entries.append(palette.allocator, .{
        .label = node.name,
        .indent = depth,
        .file_icon = file_icon,
        .file_color = file_color,
        .node = node,
    });

    if (node.type_ == .folder and node.expanded) {
        if (node.children) |children| {
            for (children.items) |*child| {
                try build_visible_list(palette, child, depth + 1);
            }
        }
    }
}

fn request_node_children(palette: *Type, node: *Node) !void {
    palette.value.pending_node = node;
    try project_manager.request_path_files(max_path_entries, node.path);
}

fn receive_project_manager(palette: *Type, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    if (!(cbor.match(m.buf, .{ "PRJ", tp.more }) catch false)) return false;

    var file_name: []const u8 = undefined;
    var file_type_name: []const u8 = undefined;
    var icon_: []const u8 = undefined;
    var color_: u24 = undefined;

    if (try cbor.match(m.buf, .{ "PRJ", "path_entry", tp.any, tp.any, "DIR", tp.extract(&file_name), tp.extract(&file_type_name), tp.extract(&icon_), tp.extract(&color_) })) {
        try append_pending_child(palette, file_name, .folder, icon_, color_);
    } else if (try cbor.match(m.buf, .{ "PRJ", "path_entry", tp.any, tp.any, "FILE", tp.extract(&file_name), tp.extract(&file_type_name), tp.extract(&icon_), tp.extract(&color_) })) {
        try append_pending_child(palette, file_name, .file, icon_, color_);
    } else if (try cbor.match(m.buf, .{ "PRJ", "path_entry", tp.any, tp.any, "LINK", tp.extract(&file_name), tp.extract(&file_type_name), tp.extract(&icon_), tp.extract(&color_) })) {
        try append_pending_child(palette, file_name, .file, icon_, color_);
    } else if (try cbor.match(m.buf, .{ "PRJ", "path_done", tp.any, tp.any, tp.any })) {
        const pending = palette.value.pending_node;
        palette.value.pending_node = null;
        palette.entries.clearRetainingCapacity();
        if (palette.value.root_node) |root| try build_visible_list(palette, root, 0);
        palette.longest_hint = max_entry_overhead(palette);
        try follow_path(palette, pending);
        palette.start_query(0) catch {};
        tui.need_render(@src());
    } else if (try cbor.match(m.buf, .{ "PRJ", "path_error", tp.any, tp.any, tp.any })) {
        palette.value.pending_node = null;
    }

    return true;
}

fn append_pending_child(palette: *Type, file_name: []const u8, node_type: NodeType, icon_: []const u8, color_: u24) !void {
    const node = palette.value.pending_node orelse return;
    if (node.children == null)
        node.children = .empty;

    const path = try std.fs.path.join(palette.allocator, &.{ node.path, file_name });
    errdefer palette.allocator.free(path);

    const node_name = try palette.allocator.dupe(u8, file_name);
    errdefer palette.allocator.free(node_name);
    const icon_copy = try palette.allocator.dupe(u8, icon_);
    errdefer palette.allocator.free(icon_copy);

    (try node.children.?.addOne(palette.allocator)).* = .{
        .name = node_name,
        .path = path,
        .type_ = node_type,
        .expanded = false,
        .children = null,
        .parent = node,
        .icon = icon_copy,
        .color = color_,
    };
}

fn max_entry_overhead(palette: *Type) usize {
    var max_overhead: usize = 0;
    for (palette.entries.items) |entry| max_overhead = @max(max_overhead, entry.indent + 3);
    return max_overhead;
}

fn follow_path(palette: *Type, pending_: ?*Node) !void {
    const pending = pending_ orelse return;
    const target = palette.value.follow_path orelse return;
    const children = pending.children orelse return;

    for (children.items) |*child| {
        if (child.type_ == .folder and std.mem.startsWith(u8, target, child.path) and
            (target.len == child.path.len or target[child.path.len] == std.fs.path.sep))
        {
            child.expanded = true;
            try request_node_children(palette, child);
            return;
        } else if (child.type_ == .file and std.mem.eql(u8, target, child.path)) {
            select_child(palette, child);
            palette.allocator.free(palette.value.follow_path.?);
            palette.value.follow_path = null;
            return;
        }
    }
    palette.allocator.free(palette.value.follow_path.?);
    palette.value.follow_path = null;
}

fn select_child(palette: *Type, child: *Node) void {
    const idx = for (palette.entries.items, 0..) |entry, i| {
        if (entry.node == child) break i;
    } else return;
    palette.initial_selected = idx + 1;
}

pub fn load_entries(palette: *Type) !usize {
    palette.quick_activate_enabled = false;
    palette.entries.clearRetainingCapacity();

    tui.message_filters().add(MessageFilter.bind(palette, receive_project_manager)) catch {};

    const project_path = tp.env.get().str("project");
    if (project_path.len == 0) return 0;

    if (palette.value.root_node == null) {
        const node = try palette.allocator.create(Node);
        errdefer palette.allocator.destroy(node);
        const basename = std.fs.path.basename(project_path);
        const node_name = try palette.allocator.dupe(u8, basename);
        errdefer palette.allocator.free(node_name);
        const path = try palette.allocator.dupe(u8, "");
        errdefer palette.allocator.free(path);
        const node_icon = try palette.allocator.dupe(u8, "󰝰");
        errdefer palette.allocator.free(node_icon);
        node.* = .{
            .name = node_name,
            .path = path,
            .type_ = .folder,
            .expanded = true,
            .children = null,
            .parent = null,
            .icon = node_icon,
            .color = 0,
        };
        palette.value.root_node = node;
        if (tui.get_active_editor()) |editor| if (editor.file_path) |file_path| {
            palette.value.follow_path = try palette.allocator.dupe(u8, file_path);
        };
        try request_node_children(palette, node);
        return 0;
    }

    try build_visible_list(palette, palette.value.root_node.?, 0);
    return max_entry_overhead(palette);
}

pub fn on_render_menu(_: *Type, button: *Type.ButtonType, theme: *const Widget.Theme, selected: bool) bool {
    const style_base = theme.editor_widget;
    const style_label = if (button.active) theme.editor_cursor else if (button.hover or selected) theme.editor_selection else theme.editor_widget;
    const style_hint = if (tui.find_scope_style(theme, "entity.name")) |sty| sty.style else style_label;
    button.plane.set_base_style(style_base);
    button.plane.erase();
    button.plane.home();
    button.plane.set_style(style_label);
    if (button.active or button.hover or selected) {
        button.plane.fill(" ");
        button.plane.home();
    }
    var label_str: []const u8 = undefined;
    var file_icon: []const u8 = undefined;
    var indent: usize = 0;
    var entry_index: usize = 0;
    var icon_color: u24 = 0;

    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &label_str) catch false)) return false;
    if (!(cbor.matchInt(usize, &iter, &entry_index) catch false)) return false;
    if (!(cbor.matchInt(usize, &iter, &indent) catch false)) return false;
    if (!(cbor.matchString(&iter, &file_icon) catch false)) return false;
    if (!(cbor.matchInt(u24, &iter, &icon_color) catch false)) return false;

    button.plane.set_style(style_hint);
    tui.render_pointer(&button.plane, selected);
    for (0..indent) |_| _ = button.plane.print(" ", .{}) catch {};

    const icon_width = tui.render_file_icon(&button.plane, file_icon, icon_color);

    button.plane.set_style(style_label);
    _ = button.plane.print("{s} ", .{label_str}) catch {};
    button.plane.set_style(style_hint);
    var index: usize = 0;
    var len = cbor.decodeArrayHeader(&iter) catch return false;
    while (len > 0) : (len -= 1) {
        if (cbor.matchValue(&iter, cbor.extract(&index)) catch break) {
            tui.render_match_cell(&button.plane, 0, index + 2 + icon_width + indent, theme) catch break;
        } else break;
    }
    return false;
}

fn select(menu: **Type.MenuType, button: *Type.ButtonType, _: Type.Pos) void {
    const palette = menu.*.opts.ctx;

    var label_str: []const u8 = undefined;
    var entry_idx: usize = undefined;
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &label_str) catch false)) return;
    if (!(cbor.matchValue(&iter, cbor.extract(&entry_idx)) catch false)) return;

    if (entry_idx >= palette.entries.items.len) return;

    const entry = palette.entries.items[entry_idx];
    const node = entry.node;

    if (node.type_ == .folder) {
        node.expanded = !node.expanded;

        palette.inputbox.text.shrinkRetainingCapacity(0);
        palette.inputbox.cursor = tui.egc_chunk_width(palette.inputbox.text.items, 0, 8);

        if (node.expanded and node.children == null) {
            request_node_children(palette, node) catch |e| {
                palette.logger.err("request_node_children", e);
                return;
            };
            return;
        }

        palette.entries.clearRetainingCapacity();
        if (palette.value.root_node) |root| build_visible_list(palette, root, 0) catch return;

        const new_idx = for (palette.entries.items, 0..) |e, i| {
            if (e.node == node) break i + 1;
        } else 0;

        palette.initial_selected = new_idx;
        palette.start_query(0) catch {};
        tui.need_render(@src());
    } else {
        tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| palette.logger.err(module_name, e);
        tp.self_pid().send(.{ "cmd", "navigate", .{ .file = node.path } }) catch |e| palette.logger.err(module_name, e);
    }
}

pub fn add_menu_entry(palette: *Type, entry: *Entry, matches: ?[]const usize) !void {
    var value: std.Io.Writer.Allocating = .init(palette.allocator);
    defer value.deinit();
    const writer = &value.writer;
    try cbor.writeValue(writer, entry.label);
    const entry_idx = for (palette.entries.items, 0..) |existing_entry, idx| {
        if (existing_entry.node == entry.node) break idx;
    } else palette.entries.items.len;
    try cbor.writeValue(writer, entry_idx);
    try cbor.writeValue(writer, entry.indent);
    try cbor.writeValue(writer, entry.file_icon);
    try cbor.writeValue(writer, entry.file_color);
    try cbor.writeValue(writer, matches orelse &[_]usize{});
    try palette.menu.add_item_with_handler(value.written(), select);
    palette.items += 1;
}

pub fn clear_entries(palette: *Type) void {
    palette.entries.clearRetainingCapacity();
}
