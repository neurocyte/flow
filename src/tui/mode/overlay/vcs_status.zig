const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const project_manager = @import("project_manager");
const root = @import("soft_root").root;
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

pub const Kind = enum { header, empty, file, hunk };
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
    hunk: usize = 0,
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
    files_next: std.ArrayList(File) = .empty,
    hunks: std.ArrayList(Hunk) = .empty,
    pending_open: ?[]const u8 = null,
    pending_diff: ?Diff = null,
    shown_diff: ?Diff = null,
    shown_diff_hash: u64 = 0,
    diff_stale: bool = false,
    pending_target: ?Target = null,
    pending_target_done: bool = false,
    restore_target: ?Target = null,
    initial_path: ?[]const u8 = null,
    goto_hunk: ?GotoHunk = null,
    context_lines: usize = 3,
};

const GotoHunk = struct {
    path: []const u8,
    line: usize,
};
pub const defaultValue: ValueType = .{};

const Hunk = struct {
    label: []const u8,
    line: usize,
    new_line: usize,
    patch: []const u8,

    fn deinit(self: *const Hunk, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.patch);
    }
};

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
    if (ctx.args.buf.len != 0)
        try restore(palette, ctx)
    else if (tui.get_active_editor()) |editor| if (editor.file_path) |file_path| {
        palette.value.initial_path = try palette.allocator.dupe(u8, file_path);
    };
    try project_manager.request_vcs_status_files();
    project_manager.request_vcs_status() catch {};
    return 6;
}

pub fn clear_entries(palette: *Type) void {
    for (palette.entries.items) |entry| switch (entry.kind) {
        .file => {
            palette.allocator.free(entry.label);
            palette.allocator.free(entry.path);
            palette.allocator.free(entry.orig_path);
            palette.allocator.free(entry.file_icon);
        },
        .hunk => palette.allocator.free(entry.path),
        .header, .empty => {},
    };
    palette.entries.clearRetainingCapacity();
}

fn clear_files(palette: *Type, files: *std.ArrayList(File)) void {
    for (files.items) |*file| file.deinit(palette.allocator);
    files.clearRetainingCapacity();
}

fn clear_hunks(palette: *Type) void {
    for (palette.value.hunks.items) |*hunk| hunk.deinit(palette.allocator);
    palette.value.hunks.clearRetainingCapacity();
}

pub fn deinit(palette: *Type) void {
    save(palette);
    tui.message_filters().remove_ptr(palette);
    clear_entries(palette);
    clear_files(palette, &palette.value.files);
    clear_files(palette, &palette.value.files_next);
    clear_hunks(palette);
    palette.value.files.deinit(palette.allocator);
    palette.value.files_next.deinit(palette.allocator);
    palette.value.hunks.deinit(palette.allocator);
    if (palette.value.pending_open) |path| palette.allocator.free(path);
    if (palette.value.pending_diff) |diff| palette.allocator.free(diff.path);
    if (palette.value.shown_diff) |diff| palette.allocator.free(diff.path);
    clear_goto_hunk(palette);
    clear_pending_target(palette);
    clear_restore_target(palette);
}

fn clear_restore_target(palette: *Type) void {
    if (palette.value.restore_target) |t| palette.allocator.free(t.path);
    palette.value.restore_target = null;
    if (palette.value.initial_path) |path| palette.allocator.free(path);
    palette.value.initial_path = null;
}

fn save(palette: *Type) void {
    var data: std.Io.Writer.Allocating = .init(palette.allocator);
    defer data.deinit();
    const writer = &data.writer;
    if (selected_index(palette)) |idx| {
        const entry = &palette.entries.items[idx];
        const kind: Kind = if (entry.kind == .hunk) .file else entry.kind;
        cbor.writeValue(writer, .{ kind, entry.section, entry.path, idx }) catch return;
    }
    tui.set_last_palette(.vcs_status, .init(.{ .buf = data.written() }));
}

fn restore(palette: *Type, ctx: command.Context) !void {
    var kind: Kind = undefined;
    var section: Section = undefined;
    var path: []const u8 = undefined;
    var index: usize = undefined;
    var line: usize = undefined;
    if (try ctx.args.match(.{ tp.extract(&path), tp.extract(&line) })) {
        clear_restore_target(palette);
        clear_goto_hunk(palette);
        palette.value.initial_path = try palette.allocator.dupe(u8, path);
        palette.value.goto_hunk = .{ .path = try palette.allocator.dupe(u8, path), .line = line };
        return;
    }
    if (!try ctx.args.match(.{ tp.extract(&kind), tp.extract(&section), tp.extract(&path), tp.extract(&index) })) return;
    clear_restore_target(palette);
    palette.value.restore_target = .{
        .kind = kind,
        .section = section,
        .path = try palette.allocator.dupe(u8, path),
        .index = index,
    };
}

fn clear_goto_hunk(palette: *Type) void {
    if (palette.value.goto_hunk) |goto| palette.allocator.free(goto.path);
    palette.value.goto_hunk = null;
}

fn request_goto_diff(palette: *Type) void {
    const goto = palette.value.goto_hunk orelse return;
    if (palette.value.pending_diff != null) return;
    const section = goto_section(palette, goto.path) orelse return clear_goto_hunk(palette);
    request_diff(palette, goto.path, section_diff_mode(section));
}

/// unstaged changes are closer to the editor's content, so they come first
fn goto_section(palette: *Type, path: []const u8) ?Section {
    for (palette.value.files.items) |*file| if (std.mem.eql(u8, file.path, path)) {
        if (file.status(.unstaged)) |_| return .unstaged;
        if (file.status(.staged)) |_| return .staged;
    };
    return null;
}

fn select_goto_hunk(palette: *Type, mode: project_manager.VcsDiffMode) !void {
    const goto = palette.value.goto_hunk orelse return;
    const diff = palette.value.shown_diff orelse return;
    if (!diff.eql(goto.path, mode)) return;
    defer clear_goto_hunk(palette);
    var best: ?usize = null;
    var best_distance: usize = std.math.maxInt(usize);
    for (palette.value.hunks.items, 0..) |*hunk, i| {
        const distance = hunk_distance(hunk.label, goto.line);
        if (distance < best_distance) {
            best = i;
            best_distance = distance;
        }
    }
    const idx = best orelse return;
    clear_pending_target(palette);
    palette.value.pending_target = .{
        .kind = .hunk,
        .section = mode_section(mode),
        .path = try palette.allocator.dupe(u8, goto.path),
        .index = 0,
        .hunk = idx,
    };
    palette.value.pending_target_done = true;
    send(palette, .{ "cmd", "goto_line", .{palette.value.hunks.items[idx].line} });
    send(palette, .{ "cmd", "scroll_view_top" });
}

/// the number of lines between a line and the new side of a hunk, 0 if the hunk contains it
fn hunk_distance(hunk_header: []const u8, line: usize) usize {
    const start_pos = (std.mem.indexOf(u8, hunk_header, " +") orelse return std.math.maxInt(usize)) + 2;
    var pos = start_pos;
    while (pos < hunk_header.len and std.ascii.isDigit(hunk_header[pos])) pos += 1;
    const start = std.fmt.parseInt(usize, hunk_header[start_pos..pos], 10) catch return std.math.maxInt(usize);
    var count: usize = 1;
    if (pos < hunk_header.len and hunk_header[pos] == ',') {
        const count_pos = pos + 1;
        pos = count_pos;
        while (pos < hunk_header.len and std.ascii.isDigit(hunk_header[pos])) pos += 1;
        count = std.fmt.parseInt(usize, hunk_header[count_pos..pos], 10) catch 1;
    }
    const end = start + @max(count, 1);
    return if (line < start) start - line else if (line >= end) line - end + 1 else 0;
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
        clear_files(palette, &palette.value.files);
        std.mem.swap(std.ArrayList(File), &palette.value.files, &palette.value.files_next);
        palette.value.diff_stale = true;
        try update_entries(palette);
        request_goto_diff(palette);
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
    (try palette.value.files_next.addOne(allocator)).* = .{
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
    hunk: usize = 0,

    fn matches(self: *const Target, entry: *const Entry) bool {
        return self.kind == entry.kind and self.section == entry.section and self.hunk == entry.hunk and
            std.mem.eql(u8, self.path, entry.path);
    }

    fn matches_file(self: *const Target, entry: *const Entry) bool {
        return (entry.kind == .file or entry.kind == .hunk) and self.section == entry.section and
            std.mem.eql(u8, self.path, entry.path);
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
            .hunk = entry.hunk,
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
            try append_hunk_entries(palette, file.path, section.section);
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
    else if (palette.value.initial_path) |path|
        find_file(palette, path) orelse first_file(palette)
    else
        first_file(palette);
    if (palette.value.pending_target_done) clear_pending_target(palette);
    clear_restore_target(palette);
    palette.initial_selected = select_idx + 1;
    try palette.start_query(0);
}

fn find_target(palette: *Type, target: *const Target) usize {
    const entries = palette.entries.items;
    for (entries, 0..) |*entry, i| if (target.matches(entry)) return i;
    if (target.kind == .hunk) {
        var last: ?usize = null;
        for (entries, 0..) |*entry, i| if (target.matches_file(entry)) {
            last = i;
        };
        if (last) |i| return i;
        for (entries, 0..) |*entry, i| if (entry.kind == .header and entry.section == target.section) return i;
    }
    var idx = @min(target.index, entries.len - 1);
    while (idx > 0 and entries[idx].kind == .empty) idx -= 1;
    return idx;
}

fn find_file(palette: *Type, path: []const u8) ?usize {
    for (palette.entries.items, 0..) |*entry, i|
        if (entry.kind == .file and std.mem.eql(u8, entry.path, path)) return i;
    return null;
}

fn first_file(palette: *Type) usize {
    for (palette.entries.items, 0..) |*entry, i| if (entry.kind == .file) return i;
    return 0;
}

fn append_entry(palette: *Type, file: *const File, section: Section, status: u8) !void {
    const allocator = palette.allocator;
    const display = try allocator.dupe(u8, file.path);
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

fn append_hunk_entries(palette: *Type, path: []const u8, section: Section) !void {
    const diff = palette.value.shown_diff orelse return;
    if (diff.mode != section_diff_mode(section) or !std.mem.eql(u8, diff.path, path)) return;
    for (0..palette.value.hunks.items.len) |i| {
        const path_ = try palette.allocator.dupe(u8, path);
        errdefer palette.allocator.free(path_);
        // hunk entries have no label so the palette width stays the same
        (try palette.entries.addOne(palette.allocator)).* = .{
            .label = "",
            .path = path_,
            .kind = .hunk,
            .section = section,
            .hunk = i,
        };
    }
}

fn hunk_for(palette: *Type, path: []const u8, section: Section, index: usize) ?*const Hunk {
    const diff = palette.value.shown_diff orelse return null;
    if (diff.mode != section_diff_mode(section) or !std.mem.eql(u8, diff.path, path)) return null;
    return if (index < palette.value.hunks.items.len) &palette.value.hunks.items[index] else null;
}

fn mode_section(mode: project_manager.VcsDiffMode) Section {
    return switch (mode) {
        .staged => .staged,
        .unstaged => .unstaged,
        .untracked => .untracked,
    };
}

fn section_diff_mode(section: Section) project_manager.VcsDiffMode {
    return switch (section) {
        .staged => .staged,
        .unstaged => .unstaged,
        .untracked => .untracked,
    };
}

pub fn add_list_box_entry(palette: *Type, entry: *Entry, _: ?[]const usize) !void {
    var value: std.Io.Writer.Allocating = .init(palette.allocator);
    defer value.deinit();
    const writer = &value.writer;
    try cbor.writeValue(writer, entry.kind);
    try cbor.writeValue(writer, entry.section);
    try cbor.writeValue(writer, entry.status);
    try cbor.writeValue(writer, entry.path);
    try cbor.writeValue(writer, if (entry.kind == .hunk) palette.value.hunks.items[entry.hunk].label else entry.label);
    try cbor.writeValue(writer, entry.file_icon);
    try cbor.writeValue(writer, entry.file_color);
    try cbor.writeValue(writer, entry.hunk);
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
    hunk: usize,

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
        if (!(cbor.matchValue(&iter, tp.extract(&item.hunk)) catch false)) return null;
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
            _ = tui.render_file_icon(plane, item.file_icon, item.file_color);
            plane.set_style(style_label);
            _ = plane.print("{s} ", .{item.label}) catch {};
            plane.set_style(.{ .fg = status_style(theme, item.status).fg });
            _ = plane.print_aligned_right(0, "{c} ", .{item.status}) catch {};
        },
        .hunk => {
            const end = if (std.mem.indexOfPos(u8, item.label, 2, "@@")) |pos| pos + 2 else item.label.len;
            plane.set_style(style_hint);
            _ = plane.print("  {s}", .{item.label[0..end]}) catch {};
            plane.set_style(style_label);
            _ = plane.print("{s}", .{item.label[end..]}) catch {};
        },
    }
    return false;
}

fn select(list_box: **Type.ListBoxType, button: *Type.ButtonType, _: Type.Pos) void {
    const palette = list_box.*.opts.ctx;
    const activate = palette.activate;
    palette.activate = .normal;
    const item = Item.decode(button) orelse return;
    switch (item.kind) {
        .file => switch (activate) {
            // close_diff rebuilds the list and would free this button while it is still in use
            .normal => if (is_shown_diff(palette, &item))
                send(palette, .{ "cmd", "palette_menu_action", .{"close_diff"} })
            else
                show_diff(palette, &item),
            .alternate => open_file(palette, &item),
        },
        .hunk => switch (activate) {
            .normal => show_hunk(palette, &item),
            .alternate => open_hunk(palette, &item),
        },
        .header, .empty => {},
    }
}

pub fn scroll_background(palette: *Type, direction: Type.ScrollDirection) void {
    if (palette.value.shown_diff == null) return;
    const editor = tui.get_active_editor() orelse return;
    switch (direction) {
        .up => editor.mouse_scroll_up(root.get_now()),
        .down => editor.mouse_scroll_down(root.get_now()),
    }
}

pub fn updated(palette: *Type, button_: ?*Type.ButtonType) !void {
    if (palette.value.shown_diff == null) return;
    const button = button_ orelse return;
    const item = Item.decode(button) orelse return;
    switch (item.kind) {
        .file => show_diff(palette, &item),
        .hunk => show_hunk(palette, &item),
        .header, .empty => {},
    }
}

fn is_shown_diff(palette: *Type, item: *const Item) bool {
    if (palette.value.pending_diff != null) return false;
    const diff = palette.value.shown_diff orelse return false;
    return diff.eql(item.path, section_diff_mode(item.section));
}

fn close_diff(palette: *Type) void {
    if (palette.value.pending_diff) |diff| palette.allocator.free(diff.path);
    palette.value.pending_diff = null;
    const diff = palette.value.shown_diff orelse return;
    palette.value.shown_diff = null;
    defer palette.allocator.free(diff.path);
    clear_hunks(palette);
    update_entries(palette) catch |e| palette.logger.err(module_name, e);
    const buffer_name = diff.buffer_name(palette.allocator) catch |e| return palette.logger.err(module_name, e);
    defer palette.allocator.free(buffer_name);
    send(palette, .{ "cmd", "close_buffer", .{buffer_name} });
}

fn show_hunk(palette: *Type, item: *const Item) void {
    show_diff(palette, item);
    const hunk = hunk_for(palette, item.path, item.section, item.hunk) orelse return;
    send(palette, .{ "cmd", "goto_line", .{hunk.line} });
    send(palette, .{ "cmd", "scroll_view_top" });
}

fn open_hunk(palette: *Type, item: *const Item) void {
    const hunk = hunk_for(palette, item.path, item.section, item.hunk) orelse return;
    navigate(palette, item.path, hunk.new_line);
}

fn show_diff(palette: *Type, item: *const Item) void {
    const mode = section_diff_mode(item.section);
    const stale = palette.value.diff_stale;
    palette.value.diff_stale = false;
    if (palette.value.pending_diff) |*diff| if (diff.eql(item.path, mode)) return;
    if (!stale) if (palette.value.shown_diff) |*diff| if (diff.eql(item.path, mode)) return;
    request_diff(palette, item.path, mode);
}

fn request_diff(palette: *Type, file_path: []const u8, mode: project_manager.VcsDiffMode) void {
    const path = palette.allocator.dupe(u8, file_path) catch |e| return palette.logger.err(module_name, e);
    if (palette.value.pending_diff) |diff| palette.allocator.free(diff.path);
    palette.value.pending_diff = .{ .path = path, .mode = mode };
    project_manager.request_vcs_diff(path, mode, palette.value.context_lines) catch |e| palette.logger.err(module_name, e);
}

const ContextChange = enum { more_context, less_context };

fn change_context(palette: *Type, change: ContextChange) void {
    palette.value.context_lines = switch (change) {
        .more_context => palette.value.context_lines + 1,
        .less_context => palette.value.context_lines -| 1,
    };
    const diff = palette.value.shown_diff orelse return;
    request_diff(palette, diff.path, diff.mode);
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
    defer update_hunks(palette, mode, output);

    const buffer_name = pending.buffer_name(allocator) catch |e| return palette.logger.err(module_name, e);
    defer allocator.free(buffer_name);
    send(palette, .{ "cmd", "replace_scratch_buffer", .{ buffer_name, output, "diff" } });
    if (previous) |*diff| {
        const previous_name = diff.buffer_name(allocator) catch |e| return palette.logger.err(module_name, e);
        defer allocator.free(previous_name);
        if (!std.mem.eql(u8, previous_name, buffer_name))
            send(palette, .{ "cmd", "close_buffer", .{previous_name} });
    }
}

fn update_hunks(palette: *Type, mode: project_manager.VcsDiffMode, output: []const u8) void {
    clear_hunks(palette);
    if (mode != .untracked) parse_hunks(palette, output) catch |e| palette.logger.err(module_name, e);
    select_goto_hunk(palette, mode) catch |e| palette.logger.err(module_name, e);
    update_entries(palette) catch |e| palette.logger.err(module_name, e);
}

fn parse_hunks(palette: *Type, output: []const u8) !void {
    var header: []const u8 = output;
    var hunk_start: ?usize = null;
    var hunk_line: usize = 0;
    var line_no: usize = 1;
    var pos: usize = 0;
    while (pos < output.len) : (line_no += 1) {
        const end = if (std.mem.indexOfScalarPos(u8, output, pos, '\n')) |nl| nl + 1 else output.len;
        if (std.mem.startsWith(u8, output[pos..end], "@@ ")) {
            if (hunk_start) |start|
                try add_hunk(palette, header, output[start..pos], hunk_line)
            else
                header = output[0..pos];
            hunk_start = pos;
            hunk_line = line_no;
        }
        pos = end;
    }
    if (hunk_start) |start| try add_hunk(palette, header, output[start..], hunk_line);
}

fn add_hunk(palette: *Type, header: []const u8, text: []const u8, line: usize) !void {
    const allocator = palette.allocator;
    const first_line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    const hunk_label = try allocator.dupe(u8, std.mem.trimEnd(u8, first_line, "\r"));
    errdefer allocator.free(hunk_label);
    const patch = try std.mem.concat(allocator, u8, &.{ header, text });
    errdefer allocator.free(patch);
    (try palette.value.hunks.addOne(allocator)).* = .{
        .label = hunk_label,
        .line = line,
        .new_line = first_changed_line(text),
        .patch = patch,
    };
}

fn first_changed_line(text: []const u8) usize {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const hunk_header = lines.first();
    const start = (std.mem.indexOf(u8, hunk_header, " +") orelse return 1) + 2;
    var end = start;
    while (end < hunk_header.len and std.ascii.isDigit(hunk_header[end])) end += 1;
    var line = std.fmt.parseInt(usize, hunk_header[start..end], 10) catch return 1;
    while (lines.next()) |l| {
        if (!std.mem.startsWith(u8, l, " ")) break;
        line += 1;
    }
    return @max(1, line);
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

const TerminalAction = enum { commit, amend, fetch, push };

pub fn action(palette: *Type, _: ?*Type.ButtonType, ctx: command.Context) !void {
    if (try ctx.args.match(.{"close_diff"})) return close_diff(palette);
    if (try ctx.args.match(.{"revert"})) return revert(palette);
    if (try ctx.args.match(.{"cancel"})) {
        if (palette.value.shown_diff != null or palette.value.pending_diff != null)
            close_diff(palette)
        else
            send(palette, .{ "cmd", "palette_menu_cancel" });
        return;
    }
    var terminal_action: TerminalAction = undefined;
    if (try ctx.args.match(.{tp.extract(&terminal_action)}))
        return run_in_terminal(palette, terminal_action);
    var context_change: ContextChange = undefined;
    if (try ctx.args.match(.{tp.extract(&context_change)}))
        return change_context(palette, context_change);

    const idx = selected_index(palette) orelse return;
    const entries = palette.entries.items;
    const entry = &entries[idx];
    if (entry.kind == .empty) return;
    if (entry.kind == .hunk) return apply_hunk(palette, idx);

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

fn apply_hunk(palette: *Type, idx: usize) !void {
    const entry = &palette.entries.items[idx];
    const hunk = hunk_for(palette, entry.path, entry.section, entry.hunk) orelse return;
    const update: project_manager.VcsIndexUpdate = switch (entry.section) {
        .staged => .unstage,
        .unstaged => .stage,
        .untracked => return,
    };
    clear_pending_target(palette);
    palette.value.pending_target = .{
        .kind = entry.kind,
        .section = entry.section,
        .path = try palette.allocator.dupe(u8, entry.path),
        .index = idx,
        .hunk = entry.hunk,
    };
    try project_manager.request_vcs_apply_patch(update, hunk.patch);
}

fn revert(palette: *Type) !void {
    const idx = selected_index(palette) orelse return;
    const entry = &palette.entries.items[idx];
    if (entry.kind == .header or entry.kind == .empty) return;
    if (entry.section == .staged) {
        palette.logger.print("staged changes can not be reverted, unstage them first", .{});
        return;
    }
    const kind: tui.VcsRevert, const arg: []const u8, const choice_label: []const u8 = switch (entry.kind) {
        .file => if (entry.section == .untracked) .{ .untracked, entry.path, "Delete" } else .{ .file, entry.path, "Revert" },
        .hunk => .{ .hunk, (hunk_for(palette, entry.path, entry.section, entry.hunk) orelse return).patch, "Revert" },
        .header, .empty => return,
    };
    var message_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    const message = switch (kind) {
        .file => std.fmt.bufPrint(&message_buf, "Revert all unstaged changes?\n{s}", .{entry.path}),
        .hunk => std.fmt.bufPrint(&message_buf, "Revert this hunk?\n{s}", .{entry.path}),
        .untracked => std.fmt.bufPrint(&message_buf, "Delete untracked {s}?\n{s}", .{
            if (std.mem.endsWith(u8, entry.path, "/")) "directory" else "file",
            entry.path,
        }),
    } catch entry.path;

    var confirmed: std.Io.Writer.Allocating = .init(palette.allocator);
    defer confirmed.deinit();
    try cbor.writeValue(&confirmed.writer, .{ "cmd", "vcs_revert", .{ kind, arg } });
    var cancelled_buf: [64]u8 = undefined;
    const cancelled = cbor.fmt(&cancelled_buf, .{ "cmd", "last_palette" });
    var confirm: std.Io.Writer.Allocating = .init(palette.allocator);
    defer confirm.deinit();
    try cbor.writeValue(&confirm.writer, .{ "cmd", "confirm", .{
        message,
        .{.{ choice_label, cbor.Raw{ .bytes = confirmed.written() }, tui.Confirm.Severity.err }},
        cbor.Raw{ .bytes = cancelled },
    } });

    // the confirm dialog replaces this palette, so close the diff view and open the dialog after returning
    close_diff(palette);
    try tp.self_pid().send_raw(.{ .buf = confirm.written() });
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

fn run_in_terminal(palette: *Type, terminal_action: TerminalAction) !void {
    close_diff(palette);
    const config = tui.config();
    const cmd = switch (terminal_action) {
        .commit => config.vcs_commit_command,
        .amend => config.vcs_amend_command,
        .fetch => config.vcs_fetch_command,
        .push => config.vcs_push_command,
    };
    try tp.self_pid().send(.{ "cmd", "exit_overlay_mode" });
    try tp.self_pid().send(.{ "cmd", "open_terminal", .{ cmd, config.terminal_on_exit } });
}
