const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const root = @import("soft_root").root;
const command = @import("command");

const tui = @import("../../tui.zig");
pub const Type = @import("palette.zig").Create(@This());
const module_name = @typeName(@This());
const Widget = @import("../../Widget.zig");

pub const label = "File Explorer";
pub const name = "File Explorer";
pub const description = "Project file explorer";
pub const icon = "🗂️ ";
pub const modal_dim = true;
pub const placement = .top_center;

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
};

pub const Entry = struct {
    label: []const u8,
    node: *Node,
};

fn createNodeFromPath(allocator: std.mem.Allocator, path: []const u8) !*Node {
    const node = try allocator.create(Node);
    errdefer allocator.destroy(node);

    const basename = std.fs.path.basename(path);
    node.* = .{
        .name = try allocator.dupe(u8, basename),
        .path = try allocator.dupe(u8, path),
        .type_ = undefined,
        .expanded = false,
        .children = null,
        .parent = null,
    };

    var dir = std.fs.cwd().openDir(path, .{}) catch |err| {
        if (err == error.NotDir or err == error.FileNotFound) {
            node.*.type_ = .file;
            return node;
        }
        return err;
    };
    defer dir.close();
    node.*.type_ = .folder;
    return node;
}

fn loadNodeChildren(allocator: std.mem.Allocator, node: *Node, recursive: bool) !void {
    if (node.type_ != .folder) return;
    if (node.children != null) return;

    var children: std.ArrayList(Node) = .empty;
    errdefer children.deinit(allocator);

    var dir = try std.fs.cwd().openDir(node.path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterateAssumeFirstIteration();
    while (try iter.next()) |entry| {
        const child_path = try std.fs.path.join(allocator, &[_][]const u8{ node.path, entry.name });
        errdefer allocator.free(child_path);

        var child_node = Node{
            .name = try allocator.dupe(u8, entry.name),
            .path = child_path,
            .type_ = if (entry.kind == .directory) .folder else .file,
            .expanded = false,
            .children = null,
            .parent = node,
        };

        if (recursive) {
            try loadNodeChildren(allocator, &child_node, recursive);
        }

        try children.append(allocator, child_node);
    }

    node.children = children;
}

fn deinitNode(allocator: std.mem.Allocator, node: *Node) void {
    allocator.free(node.name);
    allocator.free(node.path);
    if (node.children) |*children| {
        for (children.items) |*child| {
            deinitNode(allocator, child);
        }
        children.deinit(allocator);
    }
}

fn deinitRootNode(allocator: std.mem.Allocator, node: *Node) void {
    deinitNode(allocator, node);
    allocator.destroy(node);
}

var root_node: ?*Node = null;

pub fn load_entries(palette: *Type) !usize {
    palette.entries.clearRetainingCapacity();

    const project_path = tp.env.get().str("project");
    if (project_path.len == 0) {
        return 0;
    }

    if (root_node == null) {
        root_node = try createNodeFromPath(palette.allocator, project_path);
        try loadNodeChildren(palette.allocator, root_node.?, false);
        root_node.?.expanded = true;
    }

    try buildVisibleList(palette, root_node.?, 0);

    return palette.entries.items.len;
}

fn buildVisibleList(palette: *Type, node: *Node, depth: usize) !void {
    const node_label = try createNodeLabel(palette.allocator, node, depth);
    try palette.entries.append(palette.allocator, .{
        .label = node_label,
        .node = node,
    });

    if (node.type_ == .folder and node.expanded) {
        if (node.children) |children| {
            for (children.items) |*child| {
                try buildVisibleList(palette, child, depth + 1);
            }
        }
    }
}

fn isNodeVisible(node: *const Node, root_ptr: *const Node) bool {
    var current: ?*const Node = node;
    while (current) |c| {
        if (c == root_ptr) return true;
        if (!c.expanded) return false;
        current = c.parent;
    }
    return false;
}

fn createNodeLabel(allocator: std.mem.Allocator, node: *const Node, depth: usize) ![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;

    // Add indentation
    for (0..depth) |_| {
        try buffer.append(allocator, ' ');
    }

    // Add folder icon or file icon
    if (node.type_ == .folder) {
        if (node.expanded) {
            try buffer.appendSlice(allocator, "🗁");
        } else {
            try buffer.appendSlice(allocator, "🗀");
        }
    } else {
        // @TODO: Add here file icon
        try buffer.append(allocator, '>');
    }
    try buffer.append(allocator, ' ');

    try buffer.appendSlice(allocator, node.name);
    return buffer.toOwnedSlice(allocator);
}

pub fn updated(palette: *Type, button_: ?*Type.ButtonType) !void {
    _ = palette;
    _ = button_;
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
    var iter = button.opts.label;
    if (!(cbor.matchString(&iter, &label_str) catch false)) return false;
    button.plane.set_style(style_hint);
    tui.render_pointer(&button.plane, selected);
    button.plane.set_style(style_label);
    _ = button.plane.print("{s} ", .{label_str}) catch {};
    button.plane.set_style(style_hint);
    var index: usize = 0;
    var len = cbor.decodeArrayHeader(&iter) catch return false;
    while (len > 0) : (len -= 1) {
        if (cbor.matchValue(&iter, cbor.extract(&index)) catch break) {
            tui.render_match_cell(&button.plane, 0, index + 2, theme) catch break;
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
        if (!node.expanded and node.children == null) {
            loadNodeChildren(palette.allocator, node, false) catch |e| {
                palette.logger.err("loadNodeChildren", e);
                return;
            };
        }
        node.expanded = !node.expanded;
        _ = load_entries(palette) catch unreachable;

        palette.inputbox.text.shrinkRetainingCapacity(0);
        palette.inputbox.cursor = tui.egc_chunk_width(palette.inputbox.text.items, 0, 8);

        const new_idx = for (palette.entries.items, 0..) |e, i| {
            if (e.node == node) break i + 1;
        } else 0;

        palette.initial_selected = new_idx;
        palette.start_query(0) catch unreachable;

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
    try cbor.writeValue(writer, matches orelse &[_]usize{});
    try palette.menu.add_item_with_handler(value.written(), select);
    palette.items += 1;
}

pub fn clear_entries(palette: *Type) void {
    palette.entries.clearRetainingCapacity();
}

pub fn deinit(palette: *Type) void {
    if (root_node) |node| {
        deinitRootNode(palette.allocator, node);
        root_node = null;
    }
}
