const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const project_manager = @import("project_manager");
const command = @import("command");

const tui = @import("../../tui.zig");
const MessageFilter = @import("../../MessageFilter.zig");
pub const Type = @import("palette.zig").Create(@This());
const module_name = @typeName(@This());
const Widget = @import("../../Widget.zig");

pub const label = "Git Status";
pub const name = " status";
pub const description = "git status";
pub const icon = "  ";
pub const modal_dim = false;
pub const placement = .top_right;
pub const no_query = true;
pub const keybind_mode = "overlay/vcs_status";
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
    orig_path: []const u8 = "",
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
    pending_open: ?[]const u8 = null,
    pending_diff: ?Diff = null,
    shown_diff: ?Diff = null,
    shown_diff_hash: u64 = 0,
    diff_stale: bool = false,
    pending_target: ?Target = null,
    pending_target_done: bool = false,
    restore_target: ?Target = null,
};
pub const defaultValue: ValueType = .{};

const Diff = struct {
    path: []const u8,
    mode: project_manager.VcsDiffMode,

    fn eql(self: *const Diff, path: []const u8, mode: project_manager.VcsDiffMode) bool {
        return self.mode == mode and std.mem.eql(u8, self.path, path);
    }

    fn buffer_name(self: *const Diff, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
        const cmd = switch (self.mode) {
            .staged => "git diff --cached",
            .unstaged, .untracked => "git diff",
        };
        return std.fmt.allocPrint(allocator, "*{s} {s}*", .{ cmd, self.path });
    }
};

pub fn load_entries_with_args(palette: *Type, ctx: command.Context) !usize {
    tui.message_filters().add(MessageFilter.bind(palette, receive_project_manager)) catch {};
    if (ctx.args.buf.len != 0) try restore(palette, ctx);
    try project_manager.request_vcs_status_files();
    project_manager.request_vcs_status() catch {};
    return 6;
}

pub fn clear_entries(palette: *Type) void {
    for (palette.entries.items) |entry| if (entry.kind == .file) {
        palette.allocator.free(entry.label);
        palette.allocator.free(entry.path);
        palette.allocator.free(entry.orig_path);
        palette.allocator.free(entry.file_icon);
    };
    palette.entries.clearRetainingCapacity();
}

fn clear_files(palette: *Type) void {
    for (palette.value.files.items) |*file| file.deinit(palette.allocator);
    palette.value.files.clearRetainingCapacity();
}

pub fn deinit(palette: *Type) void {
    save(palette);
    tui.message_filters().remove_ptr(palette);
    clear_entries(palette);
    clear_files(palette);
    palette.value.files.deinit(palette.allocator);
    if (palette.value.pending_open) |path| palette.allocator.free(path);
    if (palette.value.pending_diff) |diff| palette.allocator.free(diff.path);
    if (palette.value.shown_diff) |diff| palette.allocator.free(diff.path);
    clear_pending_target(palette);
    clear_restore_target(palette);
}

fn clear_restore_target(palette: *Type) void {
    if (palette.value.restore_target) |t| palette.allocator.free(t.path);
    palette.value.restore_target = null;
}

fn save(palette: *Type) void {
    var data: std.Io.Writer.Allocating = .init(palette.allocator);
    defer data.deinit();
    const writer = &data.writer;
    if (selected_index(palette)) |idx| {
        const entry = &palette.entries.items[idx];
        cbor.writeValue(writer, .{ entry.kind, entry.section, entry.path, idx }) catch return;
    }
    tui.set_last_palette(.vcs_status, .init(.{ .buf = data.written() }));
}

fn restore(palette: *Type, ctx: command.Context) !void {
    var kind: Kind = undefined;
    var section: Section = undefined;
    var path: []const u8 = undefined;
    var index: usize = undefined;
    if (!try ctx.args.match(.{ tp.extract(&kind), tp.extract(&section), tp.extract(&path), tp.extract(&index) })) return;
    clear_restore_target(palette);
    palette.value.restore_target = .{
        .kind = kind,
        .section = section,
        .path = try palette.allocator.dupe(u8, path),
        .index = index,
    };
}

fn clear_pending_target(palette: *Type) void {
    if (palette.value.pending_target) |t| palette.allocator.free(t.path);
    palette.value.pending_target = null;
    palette.value.pending_target_done = false;
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
    var line: usize = undefined;
    var exit_code: i64 = undefined;
    var diff_mode: project_manager.VcsDiffMode = undefined;
    var diff_output: []const u8 = undefined;

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
    } else if (try cbor.match(m.buf, .{ "PRJ", "vcs_diff", tp.extract(&file_path), tp.extract(&diff_mode), tp.extract(&diff_output) })) {
        show_pending_diff(palette, file_path, diff_mode, diff_output);
    } else if (try cbor.match(m.buf, .{ "PRJ", "vcs_first_change", tp.extract(&file_path), tp.extract(&line) })) {
        open_pending(palette, file_path, line);
    } else if (try cbor.match(m.buf, .{ "PRJ", "vcs_first_change", tp.extract(&file_path), tp.null_ })) {
        open_pending(palette, file_path, null);
    } else if (try cbor.match(m.buf, .{ "PRJ", "vcs_update_index_done", tp.extract(&exit_code) })) {
        if (exit_code == 0)
            palette.value.pending_target_done = true
        else
            clear_pending_target(palette);
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

    const select_idx = if (palette.value.pending_target) |*t|
        find_target(palette, t)
    else if (target) |*t|
        find_target(palette, t)
    else if (palette.value.restore_target) |*t|
        find_target(palette, t)
    else
        first_file(palette);
    if (palette.value.pending_target_done) clear_pending_target(palette);
    clear_restore_target(palette);
    palette.value.diff_stale = true;
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
    const orig_path = try allocator.dupe(u8, file.orig_path);
    errdefer allocator.free(orig_path);
    const file_icon = try allocator.dupe(u8, file.file_icon);
    errdefer allocator.free(file_icon);
    (try palette.entries.addOne(allocator)).* = .{
        .label = display,
        .path = path,
        .orig_path = orig_path,
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
    try cbor.writeValue(writer, entry.section);
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
    section: Section,
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
        if (!(cbor.matchValue(&iter, tp.extract(&item.section)) catch false)) return null;
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
    const palette = list_box.*.opts.ctx;
    const activate = palette.activate;
    palette.activate = .normal;
    const item = Item.decode(button) orelse return;
    if (item.kind != .file) return;
    switch (activate) {
        .normal => show_diff(palette, &item),
        .alternate => open_file(palette, &item),
    }
}

pub fn updated(palette: *Type, button_: ?*Type.ButtonType) !void {
    if (palette.value.shown_diff == null) return;
    const button = button_ orelse return;
    const item = Item.decode(button) orelse return;
    if (item.kind != .file) return;
    show_diff(palette, &item);
}

fn show_diff(palette: *Type, item: *const Item) void {
    const mode: project_manager.VcsDiffMode = switch (item.section) {
        .staged => .staged,
        .unstaged => .unstaged,
        .untracked => .untracked,
    };
    const stale = palette.value.diff_stale;
    palette.value.diff_stale = false;
    if (palette.value.pending_diff) |*diff| if (diff.eql(item.path, mode)) return;
    if (!stale) if (palette.value.shown_diff) |*diff| if (diff.eql(item.path, mode)) return;
    const path = palette.allocator.dupe(u8, item.path) catch |e| return palette.logger.err(module_name, e);
    if (palette.value.pending_diff) |diff| palette.allocator.free(diff.path);
    palette.value.pending_diff = .{ .path = path, .mode = mode };
    project_manager.request_vcs_diff(path, mode) catch |e| palette.logger.err(module_name, e);
}

fn show_pending_diff(palette: *Type, file_path: []const u8, mode: project_manager.VcsDiffMode, output: []const u8) void {
    const pending = palette.value.pending_diff orelse return;
    if (!pending.eql(file_path, mode)) return;
    palette.value.pending_diff = null;
    const allocator = palette.allocator;
    const hash = std.hash.Wyhash.hash(0, output);

    const previous = palette.value.shown_diff;
    palette.value.shown_diff = pending;
    defer if (previous) |diff| allocator.free(diff.path);
    if (previous) |*diff| if (diff.eql(file_path, mode) and palette.value.shown_diff_hash == hash) return;
    palette.value.shown_diff_hash = hash;

    const buffer_name = pending.buffer_name(allocator) catch |e| return palette.logger.err(module_name, e);
    defer allocator.free(buffer_name);
    if (previous) |*diff| {
        const previous_name = diff.buffer_name(allocator) catch |e| return palette.logger.err(module_name, e);
        defer allocator.free(previous_name);
        if (!std.mem.eql(u8, previous_name, buffer_name))
            send(palette, .{ "cmd", "delete_buffer", .{previous_name} });
    }
    send(palette, .{ "cmd", "delete_buffer", .{buffer_name} });
    send(palette, .{ "cmd", "create_scratch_buffer", .{ buffer_name, output, "diff" } });
}

fn send(palette: *Type, m: anytype) void {
    tp.self_pid().send(m) catch |e| palette.logger.err(module_name, e);
}

fn open_file(palette: *Type, item: *const Item) void {
    if (item.status == 'D') {
        palette.logger.print("{s} is deleted", .{item.path});
        return;
    }
    if (item.section == .untracked) return navigate(palette, item.path, 1);
    const path = palette.allocator.dupe(u8, item.path) catch |e| return palette.logger.err(module_name, e);
    if (palette.value.pending_open) |p| palette.allocator.free(p);
    palette.value.pending_open = path;
    project_manager.request_vcs_first_change(path, item.section == .staged) catch |e| {
        palette.logger.err(module_name, e);
        navigate(palette, path, null);
    };
}

fn open_pending(palette: *Type, file_path: []const u8, line: ?usize) void {
    const pending = palette.value.pending_open orelse return;
    if (!std.mem.eql(u8, pending, file_path)) return;
    navigate(palette, pending, line);
}

fn navigate(palette: *Type, file_path: []const u8, line: ?usize) void {
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| palette.logger.err(module_name, e);
    const result = if (line) |l|
        tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_path, .line = l } })
    else
        tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_path } });
    result catch |e| palette.logger.err(module_name, e);
}

const TerminalAction = enum { commit, fetch, push };

pub fn action(palette: *Type, _: ?*Type.ButtonType, ctx: command.Context) !void {
    var terminal_action: TerminalAction = undefined;
    if (try ctx.args.match(.{tp.extract(&terminal_action)}))
        return run_in_terminal(terminal_action);

    const idx = selected_index(palette) orelse return;
    const entries = palette.entries.items;
    const entry = &entries[idx];
    if (entry.kind == .empty) return;

    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(palette.allocator);
    for (entries, 0..) |*e, i| {
        if (e.kind != .file or e.section != entry.section) continue;
        if (entry.kind == .file and i != idx) continue;
        try paths.append(palette.allocator, e.path);
        if (entry.section == .staged and e.orig_path.len > 0)
            try paths.append(palette.allocator, e.orig_path);
    }
    if (paths.items.len == 0) return;

    if (entry.kind == .file) try set_pending_target(palette, idx);
    const update: project_manager.VcsIndexUpdate = switch (entry.section) {
        .staged => .unstage,
        .unstaged, .untracked => .stage,
    };
    try project_manager.request_vcs_update_index(update, paths.items);
}

fn set_pending_target(palette: *Type, idx: usize) !void {
    const entries = palette.entries.items;
    const section = entries[idx].section;
    const target_idx = blk: {
        var i = idx + 1;
        while (i < entries.len and entries[i].section == section) : (i += 1)
            if (entries[i].kind == .file) break :blk i;
        i = idx;
        while (i > 0 and entries[i - 1].section == section) : (i -= 1)
            if (entries[i - 1].kind == .file) break :blk i - 1;
        while (i > 0 and entries[i].kind != .header) i -= 1;
        break :blk i;
    };
    const target = &entries[target_idx];
    clear_pending_target(palette);
    palette.value.pending_target = .{
        .kind = target.kind,
        .section = target.section,
        .path = try palette.allocator.dupe(u8, target.path),
        .index = target_idx,
    };
}

fn run_in_terminal(terminal_action: TerminalAction) !void {
    const config = tui.config();
    const cmd = switch (terminal_action) {
        .commit => config.vcs_commit_command,
        .fetch => config.vcs_fetch_command,
        .push => config.vcs_push_command,
    };
    try tp.self_pid().send(.{ "cmd", "exit_overlay_mode" });
    try tp.self_pid().send(.{ "cmd", "open_terminal", .{ cmd, config.terminal_on_exit } });
}
