const std = @import("std");
const builtin = @import("builtin");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const Buffer = @import("Buffer");
const ripgrep = @import("ripgrep");
const tracy = @import("tracy");
const text_manip = @import("text_manip");
const syntax = @import("syntax");
const file_type_config = @import("file_type_config");
const project_manager = @import("project_manager");
const root_mod = @import("root");

const Plane = @import("renderer").Plane;
const Cell = @import("renderer").Cell;
const input = @import("input");
const command = @import("command");
const EventHandler = @import("EventHandler");

const scrollbar_v = @import("scrollbar_v.zig");
const editor_gutter = @import("editor_gutter.zig");
const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const tui = @import("tui.zig");
const IndentMode = @import("config").IndentMode;

pub const Cursor = Buffer.Cursor;
pub const View = Buffer.View;
pub const Selection = Buffer.Selection;

const Allocator = std.mem.Allocator;
const time = std.time;

const scroll_step_small = 3;
const scroll_cursor_min_border_distance = 5;

const double_click_time_ms = 350;
const syntax_full_reparse_time_limit = 0; // ms (0 = always use incremental)
const syntax_full_reparse_error_threshold = 3; // number of tree-sitter errors that trigger a full reparse

pub const max_matches = if (builtin.mode == std.builtin.OptimizeMode.Debug) 10_000 else 100_000;
pub const max_match_lines = 15;
pub const max_match_batch = if (builtin.mode == std.builtin.OptimizeMode.Debug) 100 else 1000;
pub const min_diagnostic_view_len = 5;

pub const whitespace = struct {
    pub const char = struct {
        pub const visible = "·";
        pub const blank = " ";
        pub const indent = "│";
        pub const eol = "󰌑"; // alternatives: "$", "⏎", "󰌑", "↩", "↲", "⤶", "󱞱", "󱞲", "⤦", "¬", "␤", "❯", "❮"
        pub const tab_begin = "-";
        pub const tab_end = ">";
    };
};

pub const Match = struct {
    begin: Cursor = Cursor{},
    end: Cursor = Cursor{},
    has_selection: bool = false,
    style: ?Widget.Theme.Style = null,

    const List = std.ArrayListUnmanaged(?Self);
    const Self = @This();

    pub fn from_selection(sel: Selection) Self {
        return .{ .begin = sel.begin, .end = sel.end };
    }

    pub fn to_selection(self: *const Self) Selection {
        return .{ .begin = self.begin, .end = self.end };
    }

    fn nudge_insert(self: *Self, nudge: Selection) void {
        self.begin.nudge_insert(nudge);
        self.end.nudge_insert(nudge);
    }

    fn nudge_delete(self: *Self, nudge: Selection) bool {
        if (!self.begin.nudge_delete(nudge))
            return false;
        return self.end.nudge_delete(nudge);
    }
};

pub const CurSel = struct {
    cursor: Cursor = Cursor{},
    selection: ?Selection = null,

    const List = std.ArrayListUnmanaged(?Self);
    const Self = @This();

    pub inline fn invalid() Self {
        return .{ .cursor = Cursor.invalid() };
    }

    inline fn reset(self: *Self) void {
        self.* = .{};
    }

    pub fn enable_selection(self: *Self, root: Buffer.Root, metrics: Buffer.Metrics) !*Selection {
        return switch (tui.get_selection_style()) {
            .normal => self.enable_selection_normal(),
            .inclusive => try self.enable_selection_inclusive(root, metrics),
        };
    }

    pub fn enable_selection_normal(self: *Self) *Selection {
        return if (self.selection) |*sel|
            sel
        else cod: {
            self.selection = Selection.from_cursor(&self.cursor);
            break :cod &self.selection.?;
        };
    }

    fn enable_selection_inclusive(self: *Self, root: Buffer.Root, metrics: Buffer.Metrics) !*Selection {
        return if (self.selection) |*sel|
            sel
        else cod: {
            self.selection = Selection.from_cursor(&self.cursor);
            try self.selection.?.end.move_right(root, metrics);
            try self.cursor.move_right(root, metrics);
            break :cod &self.selection.?;
        };
    }

    fn to_inclusive_cursor(self: *const Self, root: Buffer.Root, metrics: Buffer.Metrics) !Cursor {
        var res = self.cursor;
        if (self.selection) |sel| if (!sel.is_reversed())
            try res.move_left(root, metrics);
        return res;
    }

    pub fn disable_selection(self: *Self, root: Buffer.Root, metrics: Buffer.Metrics) void {
        switch (tui.get_selection_style()) {
            .normal => self.disable_selection_normal(),
            .inclusive => self.disable_selection_inclusive(root, metrics),
        }
    }

    fn disable_selection_normal(self: *Self) void {
        self.selection = null;
    }

    fn disable_selection_inclusive(self: *Self, root: Buffer.Root, metrics: Buffer.Metrics) void {
        if (self.selection) |sel| {
            if (!sel.is_reversed()) self.cursor.move_left(root, metrics) catch {};
            self.selection = null;
        }
    }

    pub fn check_selection(self: *Self, root: Buffer.Root, metrics: Buffer.Metrics) void {
        if (self.selection) |sel| if (sel.empty()) {
            self.disable_selection(root, metrics);
        };
    }

    fn expand_selection_to_line(self: *Self, root: Buffer.Root, metrics: Buffer.Metrics) !*Selection {
        const sel = try self.enable_selection(root, metrics);
        sel.normalize();
        sel.begin.move_begin();
        if (!(sel.end.row > sel.begin.row and sel.end.col == 0)) {
            sel.end.move_end(root, metrics);
            sel.end.move_right(root, metrics) catch {};
        }
        return sel;
    }

    fn select_node(self: *Self, node: syntax.Node, root: Buffer.Root, metrics: Buffer.Metrics) error{NotFound}!void {
        const range = node.getRange();
        self.selection = .{
            .begin = .{
                .row = range.start_point.row,
                .col = try root.pos_to_width(range.start_point.row, range.start_point.column, metrics),
            },
            .end = .{
                .row = range.end_point.row,
                .col = try root.pos_to_width(range.end_point.row, range.end_point.column, metrics),
            },
        };
        self.cursor = self.selection.?.end;
    }

    fn write(self: *const Self, writer: Buffer.MetaWriter) !void {
        try cbor.writeArrayHeader(writer, 2);
        try self.cursor.write(writer);
        if (self.selection) |sel| {
            try sel.write(writer);
        } else {
            try cbor.writeValue(writer, null);
        }
    }

    fn extract(self: *Self, iter: *[]const u8) !bool {
        var iter2 = iter.*;
        const len = cbor.decodeArrayHeader(&iter2) catch return false;
        if (len != 2) return false;
        if (!try self.cursor.extract(&iter2)) return false;
        var iter3 = iter2;
        if (try cbor.matchValue(&iter3, cbor.null_)) {
            iter2 = iter3;
        } else {
            iter3 = iter2;
            var sel: Selection = .{};
            if (!try sel.extract(&iter3)) return false;
            self.selection = sel;
            iter2 = iter3;
        }
        iter.* = iter2;
        return true;
    }

    fn nudge_insert(self: *Self, nudge: Selection) void {
        if (self.selection) |*sel_| sel_.nudge_insert(nudge);
        self.cursor.nudge_insert(nudge);
    }

    fn nudge_delete(self: *Self, nudge: Selection) bool {
        if (self.selection) |*sel_|
            if (!sel_.nudge_delete(nudge))
                return false;
        return self.cursor.nudge_delete(nudge);
    }
};

pub const Diagnostic = struct {
    source: []const u8,
    code: []const u8,
    message: []const u8,
    severity: i32,
    sel: Selection,

    fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        allocator.free(self.code);
        allocator.free(self.message);
    }

    pub const Severity = enum { Error, Warning, Information, Hint };
    pub fn get_severity(self: Diagnostic) Severity {
        return to_severity(self.severity);
    }

    pub fn to_severity(sev: i32) Severity {
        return switch (sev) {
            1 => .Error,
            2 => .Warning,
            3 => .Information,
            4 => .Hint,
            else => .Error,
        };
    }
};

pub const Editor = struct {
    const SelectMode = enum {
        char,
        word,
        line,
    };
    const Self = @This();
    pub const Target = Self;

    allocator: Allocator,
    plane: Plane,
    metrics: Buffer.Metrics,
    logger: log.Logger,

    file_path: ?[]const u8,
    buffer: ?*Buffer,
    buffer_manager: *Buffer.Manager,
    pause_undo: bool = false,
    pause_undo_root: ?Buffer.Root = null,

    cursels: CurSel.List = .empty,
    cursels_saved: CurSel.List = .empty,
    selection_mode: SelectMode = .char,
    selection_drag_initial: ?Selection = null,
    clipboard: ?[]const u8 = null,
    target_column: ?Cursor = null,
    filter_: ?struct {
        before_root: Buffer.Root,
        work_root: Buffer.Root,
        begin: Cursor,
        pos: CurSel,
        old_primary: CurSel,
        old_primary_reversed: bool,
        whole_file: ?std.ArrayListUnmanaged(u8),
        bytes: usize = 0,
        chunks: usize = 0,
        eol_mode: Buffer.EolMode = .lf,
        utf8_sanitized: bool = false,
    } = null,
    matches: Match.List = .empty,
    match_token: usize = 0,
    match_done_token: usize = 0,
    last_find_query: ?[]const u8 = null,
    find_history: ?std.ArrayListUnmanaged([]const u8) = null,
    find_operation: ?enum { goto_next_match, goto_prev_match } = null,

    prefix_buf: [8]u8 = undefined,
    prefix: []const u8 = &[_]u8{},

    view: View = View{},
    handlers: EventHandler.List,
    scroll_dest: usize = 0,
    fast_scroll: bool = false,
    jump_mode: bool = false,

    animation_step: usize = 0,
    animation_frame_rate: i64,
    animation_lag: f64,
    animation_last_time: i64,

    enable_terminal_cursor: bool,
    render_whitespace: WhitespaceMode,
    indent_size: usize,
    tab_width: usize,
    indent_mode: IndentMode,

    last: struct {
        root: ?Buffer.Root = null,
        primary: CurSel = CurSel.invalid(),
        view: View = View.invalid(),
        lines: usize = 0,
        matches: usize = 0,
        cursels: usize = 0,
        dirty: bool = false,
        eol_mode: Buffer.EolMode = .lf,
        utf8_sanitized: bool = false,
        indent_mode: IndentMode = .spaces,
    } = .{},

    file_type: ?file_type_config = null,
    syntax: ?*syntax = null,
    syntax_no_render: bool = false,
    syntax_report_timing: bool = false,
    syntax_refresh_full: bool = false,
    syntax_last_rendered_root: ?Buffer.Root = null,
    syntax_incremental_reparse: bool = false,

    style_cache: ?StyleCache = null,
    style_cache_theme: []const u8 = "",

    diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty,
    diag_errors: usize = 0,
    diag_warnings: usize = 0,
    diag_info: usize = 0,
    diag_hints: usize = 0,

    completions: std.ArrayListUnmanaged(u8) = .empty,

    enable_auto_save: bool,
    enable_format_on_save: bool,

    restored_state: bool = false,

    need_save_after_filter: ?struct {
        then: ?struct {
            cmd: []const u8,
            args: []const u8,
        } = null,
    } = null,

    const WhitespaceMode = enum { indent, leading, eol, tabs, visible, full, none };
    const StyleCache = std.AutoHashMap(u32, ?Widget.Theme.Token);

    const Context = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    pub fn update_meta(self: *const Self) void {
        var meta = std.ArrayListUnmanaged(u8).empty;
        defer meta.deinit(self.allocator);
        if (self.buffer) |_| self.write_state(meta.writer(self.allocator)) catch {};
        if (self.buffer) |_| self.write_state(meta.writer(self.allocator)) catch {};
        if (self.buffer) |p| p.set_meta(meta.items) catch {};
    }

    pub fn write_state(self: *const Self, writer: Buffer.MetaWriter) !void {
        try cbor.writeArrayHeader(writer, 12);
        try cbor.writeValue(writer, self.file_path orelse "");
        try cbor.writeValue(writer, self.clipboard orelse "");
        try cbor.writeValue(writer, self.last_find_query orelse "");
        try cbor.writeValue(writer, self.enable_format_on_save);
        try cbor.writeValue(writer, self.enable_auto_save);
        try cbor.writeValue(writer, self.indent_size);
        try cbor.writeValue(writer, self.tab_width);
        try cbor.writeValue(writer, self.indent_mode);
        try cbor.writeValue(writer, self.syntax_no_render);
        if (self.find_history) |history| {
            try cbor.writeArrayHeader(writer, history.items.len);
            for (history.items) |item|
                try cbor.writeValue(writer, item);
        } else {
            try cbor.writeArrayHeader(writer, 0);
        }
        try self.view.write(writer);

        var count_cursels: usize = 0;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |_| {
            count_cursels += 1;
        };
        try cbor.writeArrayHeader(writer, count_cursels);
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            try cursel.write(writer);
        };
    }

    pub fn extract_state(self: *Self, iter: *[]const u8, comptime op: Buffer.ExtractStateOperation) !void {
        self.restored_state = true;
        var file_path: []const u8 = undefined;
        var view_cbor: []const u8 = undefined;
        var cursels_cbor: []const u8 = undefined;
        var clipboard: []const u8 = undefined;
        var last_find_query: []const u8 = undefined;
        var find_history: []const u8 = undefined;
        if (!try cbor.matchValue(iter, .{
            tp.extract(&file_path),
            tp.extract(&clipboard),
            tp.extract(&last_find_query),
            tp.extract(&self.enable_format_on_save),
            tp.extract(&self.enable_auto_save),
            tp.extract(&self.indent_size),
            tp.extract(&self.tab_width),
            tp.extract(&self.indent_mode),
            tp.extract(&self.syntax_no_render),
            tp.extract_cbor(&find_history),
            tp.extract_cbor(&view_cbor),
            tp.extract_cbor(&cursels_cbor),
        }))
            return error.RestoreStateMatch;
        self.refresh_tab_width();
        if (op == .open_file)
            try self.open(file_path);
        self.clipboard = if (clipboard.len > 0) try self.allocator.dupe(u8, clipboard) else null;
        self.last_find_query = if (last_find_query.len > 0) try self.allocator.dupe(u8, last_find_query) else null;
        const rows = self.view.rows;
        const cols = self.view.cols;
        if (!try self.view.extract(&view_cbor))
            return error.RestoreView;
        self.scroll_dest = self.view.row;
        self.view.rows = rows;
        self.view.cols = cols;

        if (cursels_cbor.len > 0)
            self.clear_all_cursors();
        var cursels_iter = cursels_cbor;
        var len = cbor.decodeArrayHeader(&cursels_iter) catch return error.RestoreCurSels;
        while (len > 0) : (len -= 1) {
            var cursel: CurSel = .{};
            if (!(cursel.extract(&cursels_iter) catch false)) break;
            (try self.cursels.addOne(self.allocator)).* = cursel;
        }

        len = cbor.decodeArrayHeader(&find_history) catch return error.RestoreFindHistory;
        while (len > 0) : (len -= 1) {
            var value: []const u8 = undefined;
            if (!(cbor.matchValue(&find_history, cbor.extract(&value)) catch return error.RestoreFindHistory))
                return error.RestoreFindHistory;
            self.push_find_history(value);
        }
        if (tui.config().follow_cursor_on_buffer_switch)
            self.clamp();
    }

    fn init(self: *Self, allocator: Allocator, n: Plane, buffer_manager: *Buffer.Manager) void {
        const logger = log.logger("editor");
        const frame_rate = tp.env.get().num("frame-rate");
        const tab_width = tui.get_tab_width();
        const indent_mode = tui.config().indent_mode;
        const indent_size = if (indent_mode == .tabs) tab_width else tui.config().indent_size;
        self.* = Self{
            .allocator = allocator,
            .plane = n,
            .indent_size = indent_size,
            .tab_width = tab_width,
            .indent_mode = indent_mode,
            .metrics = self.plane.metrics(tab_width),
            .logger = logger,
            .file_path = null,
            .buffer = null,
            .buffer_manager = buffer_manager,
            .handlers = EventHandler.List.init(allocator),
            .animation_lag = get_animation_max_lag(),
            .animation_frame_rate = frame_rate,
            .animation_last_time = time.microTimestamp(),
            .enable_auto_save = tui.config().enable_auto_save,
            .enable_format_on_save = tui.config().enable_format_on_save,
            .enable_terminal_cursor = tui.config().enable_terminal_cursor,
            .render_whitespace = from_whitespace_mode(tui.config().whitespace_mode),
        };
    }

    fn deinit(self: *Self) void {
        var meta = std.ArrayListUnmanaged(u8).empty;
        defer meta.deinit(self.allocator);
        if (self.buffer) |_| self.write_state(meta.writer(self.allocator)) catch {};
        for (self.diagnostics.items) |*d| d.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        self.completions.deinit(self.allocator);
        if (self.syntax) |syn| syn.destroy(tui.query_cache());
        self.cursels.deinit(self.allocator);
        self.matches.deinit(self.allocator);
        self.handlers.deinit();
        self.logger.deinit();
        if (self.buffer) |p| self.buffer_manager.retire(p, meta.items);
    }

    fn from_whitespace_mode(whitespace_mode: []const u8) WhitespaceMode {
        return if (std.mem.eql(u8, whitespace_mode, "indent"))
            .indent
        else if (std.mem.eql(u8, whitespace_mode, "leading"))
            .leading
        else if (std.mem.eql(u8, whitespace_mode, "eol"))
            .eol
        else if (std.mem.eql(u8, whitespace_mode, "tabs"))
            .tabs
        else if (std.mem.eql(u8, whitespace_mode, "visible"))
            .visible
        else if (std.mem.eql(u8, whitespace_mode, "full"))
            .full
        else
            .none;
    }

    pub fn need_render(_: *Self) void {
        Widget.need_render();
    }

    pub fn buf_for_update(self: *Self) !*const Buffer {
        if (!self.pause_undo) {
            self.cursels_saved.clearAndFree(self.allocator);
            self.cursels_saved = try self.cursels.clone(self.allocator);
        }
        return self.buffer orelse error.Stop;
    }

    pub fn buf_root(self: *const Self) !Buffer.Root {
        return if (self.buffer) |p| p.root else error.Stop;
    }

    fn buf_eol_mode(self: *const Self) !Buffer.EolMode {
        return if (self.buffer) |p| p.file_eol_mode else error.Stop;
    }

    fn buf_utf8_sanitized(self: *const Self) !bool {
        return if (self.buffer) |p| p.file_utf8_sanitized else error.Stop;
    }

    fn buf_a(self: *const Self) !Allocator {
        return if (self.buffer) |p| p.allocator else error.Stop;
    }

    pub fn get_current_root(self: *const Self) ?Buffer.Root {
        return if (self.buffer) |p| p.root else null;
    }

    pub fn handle_resize(self: *Self, pos: Widget.Box) void {
        self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
        self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;
        self.view.rows = pos.h;
        self.view.cols = pos.w;
    }

    fn open(self: *Self, file_path: []const u8) !void {
        const buffer: *Buffer = blk: {
            const frame = tracy.initZone(@src(), .{ .name = "open_file" });
            defer frame.deinit();
            break :blk try self.buffer_manager.open_file(file_path);
        };
        return self.open_buffer(file_path, buffer, null);
    }

    fn open_scratch(self: *Self, file_path: []const u8, content: []const u8, file_type: ?[]const u8) !void {
        const buffer: *Buffer = blk: {
            const frame = tracy.initZone(@src(), .{ .name = "open_scratch" });
            defer frame.deinit();
            break :blk try self.buffer_manager.open_scratch(file_path, content);
        };
        return self.open_buffer(file_path, buffer, file_type);
    }

    fn open_buffer(self: *Self, file_path: []const u8, new_buf: *Buffer, file_type_: ?[]const u8) !void {
        const frame = tracy.initZone(@src(), .{ .name = "open_buffer" });
        defer frame.deinit();
        errdefer self.buffer_manager.retire(new_buf, null);
        self.cancel_all_selections();
        self.get_primary().reset();
        self.file_path = try self.allocator.dupe(u8, file_path);
        if (self.buffer) |_| try self.close();
        self.buffer = new_buf;
        const file_type = file_type_ orelse new_buf.file_type_name;
        const buffer_meta = if (self.buffer) |buffer| buffer.get_meta() else null;

        if (new_buf.root.lines() > root_mod.max_syntax_lines) {
            self.logger.print("large file threshold {d} lines < file size {d} lines", .{
                root_mod.max_syntax_lines,
                new_buf.root.lines(),
            });
            self.logger.print("syntax highlighting disabled", .{});
            self.syntax_no_render = true;
        }

        var content = std.ArrayListUnmanaged(u8).empty;
        defer content.deinit(std.heap.c_allocator);
        {
            const frame_ = tracy.initZone(@src(), .{ .name = "store" });
            defer frame_.deinit();
            try new_buf.root.store(content.writer(std.heap.c_allocator), new_buf.file_eol_mode);
        }
        if (self.indent_mode == .auto)
            self.detect_indent_mode(content.items);

        self.syntax = syntax: {
            const lang_override = file_type orelse tp.env.get().str("language");

            self.file_type = blk: {
                const frame_ = tracy.initZone(@src(), .{ .name = "guess" });
                defer frame_.deinit();
                break :blk if (lang_override.len > 0)
                    try file_type_config.get(lang_override)
                else
                    file_type_config.guess_file_type(self.file_path, content.items);
            };

            self.maybe_enable_auto_save();

            const syn = blk: {
                const frame_ = tracy.initZone(@src(), .{ .name = "create" });
                defer frame_.deinit();
                break :blk if (self.file_type) |ft|
                    ft.create_syntax(self.allocator, tui.query_cache()) catch null
                else
                    null;
            };

            if (buffer_meta == null) if (self.file_type) |ft| {
                const frame_ = tracy.initZone(@src(), .{ .name = "did_open" });
                defer frame_.deinit();
                project_manager.did_open(
                    file_path,
                    ft,
                    new_buf.lsp_version,
                    try content.toOwnedSlice(std.heap.c_allocator),
                    new_buf.is_ephemeral(),
                ) catch |e|
                    self.logger.print("project_manager.did_open failed: {any}", .{e});
            };
            break :syntax syn;
        };
        self.syntax_no_render = tp.env.get().is("no-syntax");
        self.syntax_report_timing = tp.env.get().is("syntax-report-timing");

        const ftn = if (self.file_type) |ft| ft.name else file_type_config.default.name;
        const fti = if (self.file_type) |ft| ft.icon orelse file_type_config.default.icon else file_type_config.default.icon;
        const ftc = if (self.file_type) |ft| ft.color orelse file_type_config.default.color else file_type_config.default.color;
        if (self.buffer) |buffer| {
            buffer.file_type_name = ftn;
            buffer.file_type_icon = fti;
            buffer.file_type_color = ftc;
        }

        if (buffer_meta) |meta| {
            const frame_ = tracy.initZone(@src(), .{ .name = "extract_state" });
            defer frame_.deinit();
            var iter = meta;
            try self.extract_state(&iter, .none);
        }
        try self.send_editor_open(file_path, new_buf.file_exists, ftn, fti, ftc);
    }

    fn maybe_enable_auto_save(self: *Self) void {
        if (self.restored_state) return;
        self.enable_auto_save = false;
        if (!tui.config().enable_auto_save) return;
        const self_file_type = self.file_type orelse return;

        enable: {
            const file_types = tui.config().limit_auto_save_file_types orelse break :enable;
            for (file_types) |file_type|
                if (std.mem.eql(u8, file_type, self_file_type.name))
                    break :enable;
            return;
        }
        self.enable_auto_save = true;
    }

    fn detect_indent_mode(self: *Self, content: []const u8) void {
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            if (line[0] == '\t') {
                self.indent_size = self.tab_width;
                self.indent_mode = .tabs;
                return;
            }
        }
        self.indent_size = tui.config().indent_size;
        self.indent_mode = .spaces;
        return;
    }

    fn refresh_tab_width(self: *Self) void {
        self.metrics = self.plane.metrics(self.tab_width);
        switch (self.indent_mode) {
            .spaces, .auto => {},
            .tabs => self.indent_size = self.tab_width,
        }
    }

    pub fn set_tab_width(self: *Self, ctx: Context) Result {
        var tab_width: usize = 0;
        if (!try ctx.args.match(.{tp.extract(&tab_width)}))
            return error.InvalidSetTabWidthArgument;
        self.tab_width = tab_width;
        self.refresh_tab_width();
    }
    pub const set_tab_width_meta: Meta = .{ .arguments = &.{.integer} };

    fn close(self: *Self) !void {
        var meta = std.ArrayListUnmanaged(u8).empty;
        defer meta.deinit(self.allocator);
        self.write_state(meta.writer(self.allocator)) catch {};
        if (self.buffer) |b_mut| self.buffer_manager.retire(b_mut, meta.items);
        self.cancel_all_selections();
        self.buffer = null;
        self.plane.erase();
        self.plane.home();
        tui.rdr().cursor_disable();
        _ = try self.handlers.msg(.{ "E", "close" });
        if (self.syntax) |_| if (self.file_path) |file_path|
            project_manager.did_close(file_path) catch {};
    }

    fn save(self: *Self) !void {
        const b = self.buffer orelse return error.Stop;
        if (b.is_ephemeral()) return self.logger.print_err("save", "ephemeral buffer, use save as", .{});
        if (!b.is_dirty()) return self.logger.print("no changes to save", .{});
        if (self.file_path) |file_path| {
            if (self.buffer) |b_mut| try b_mut.store_to_file_and_clean(file_path);
        } else return error.SaveNoFileName;
        try self.send_editor_save(self.file_path.?);
        self.last.dirty = false;
        self.update_event() catch {};
    }

    pub fn push_cursor(self: *Self) !void {
        const primary = self.cursels.getLastOrNull() orelse CurSel{} orelse CurSel{};
        (try self.cursels.addOne(self.allocator)).* = primary;
    }

    pub fn pop_cursor(self: *Self, _: Context) Result {
        if (self.cursels.items.len > 1) {
            const cursel = self.cursels.pop() orelse return orelse return;
            if (cursel.selection) |sel| if (self.find_selection_match(sel)) |match| {
                match.has_selection = false;
            };
        }
        self.clamp();
    }
    pub const pop_cursor_meta: Meta = .{ .description = "Remove last added cursor" };

    pub fn get_primary(self: *const Self) *CurSel {
        var idx = self.cursels.items.len;
        while (idx > 0) : (idx -= 1)
            if (self.cursels.items[idx - 1]) |*primary|
                return primary;
        if (idx == 0) {
            self.logger.print("ERROR: no more cursors", .{});
            (@constCast(self).cursels.addOne(self.allocator) catch |e| switch (e) {
                error.OutOfMemory => @panic("get_primary error.OutOfMemory"),
            }).* = CurSel{};
        }
        return self.get_primary();
    }

    fn store_undo_meta(self: *Self, allocator: Allocator) ![]u8 {
        var meta = std.ArrayListUnmanaged(u8).empty;
        const writer = meta.writer(allocator);
        for (self.cursels_saved.items) |*cursel_| if (cursel_.*) |*cursel|
            try cursel.write(writer);
        return meta.toOwnedSlice(allocator);
    }

    fn store_current_undo_meta(self: *Self, allocator: Allocator) ![]u8 {
        var meta = std.ArrayListUnmanaged(u8).empty;
        const writer = meta.writer(allocator);
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel|
            try cursel.write(writer);
        return meta.toOwnedSlice(allocator);
    }

    pub fn update_buf(self: *Self, root: Buffer.Root) !void {
        const b = self.buffer orelse return error.Stop;
        return self.update_buf_and_eol_mode(root, b.file_eol_mode, b.file_utf8_sanitized);
    }

    fn update_buf_and_eol_mode(self: *Self, root: Buffer.Root, eol_mode: Buffer.EolMode, utf8_sanitized: bool) !void {
        const b = self.buffer orelse return error.Stop;
        var sfa = std.heap.stackFallback(512, self.allocator);
        const allocator = sfa.get();
        if (!self.pause_undo) {
            const meta = try self.store_undo_meta(allocator);
            defer allocator.free(meta);
            try b.store_undo(meta);
        }
        b.update(root);
        b.file_eol_mode = eol_mode;
        b.file_utf8_sanitized = utf8_sanitized;
        try self.send_editor_modified();
    }

    fn restore_undo_redo_meta(self: *Self, meta: []const u8) !void {
        if (meta.len > 0)
            self.clear_all_cursors();
        var iter = meta;
        while (iter.len > 0) {
            var cursel: CurSel = .{};
            if (!try cursel.extract(&iter)) return error.SyntaxError;
            (try self.cursels.addOne(self.allocator)).* = cursel;
        }
    }

    fn restore_undo(self: *Self) !void {
        if (self.pause_undo)
            try self.resume_undo_history(.{});
        if (self.buffer) |b_mut| {
            try self.send_editor_jump_source();
            self.cancel_all_matches();
            var sfa = std.heap.stackFallback(512, self.allocator);
            const allocator = sfa.get();
            const redo_metadata = try self.store_current_undo_meta(allocator);
            defer allocator.free(redo_metadata);
            const meta = b_mut.undo(redo_metadata) catch |e| switch (e) {
                error.Stop => {
                    self.logger.print("nothing to undo", .{});
                    return;
                },
                else => return e,
            };
            try self.restore_undo_redo_meta(meta);
            try self.send_editor_jump_destination();
        }
    }

    fn restore_redo(self: *Self) !void {
        if (self.buffer) |b_mut| {
            try self.send_editor_jump_source();
            self.cancel_all_matches();
            const meta = b_mut.redo() catch |e| switch (e) {
                error.Stop => {
                    self.logger.print("nothing to redo", .{});
                    return;
                },
                else => return e,
            };
            try self.restore_undo_redo_meta(meta);
            try self.send_editor_jump_destination();
        }
    }

    pub fn pause_undo_history(self: *Self, _: Context) Result {
        self.pause_undo = true;
        self.pause_undo_root = self.buf_root() catch return;
        self.cursels_saved.clearAndFree(self.allocator);
        self.cursels_saved = try self.cursels.clone(self.allocator);
    }
    pub const pause_undo_history_meta: Meta = .{ .description = "Pause undo history" };

    pub fn resume_undo_history(self: *Self, _: Context) Result {
        self.pause_undo = false;
        const b = self.buffer orelse return;
        var sfa = std.heap.stackFallback(512, self.allocator);
        const allocator = sfa.get();
        const meta = try self.store_undo_meta(allocator);
        defer allocator.free(meta);
        const root = self.buf_root() catch return;
        if (self.pause_undo_root) |paused_root| b.update(paused_root);
        try b.store_undo(meta);
        b.update(root);
    }
    pub const resume_undo_history_meta: Meta = .{ .description = "Resume undo history" };

    fn collapse_trailing_ws_line(self: *Self, root: Buffer.Root, row: usize, allocator: Allocator) Buffer.Root {
        const last = find_last_non_ws(root, row, self.metrics);
        var cursel: CurSel = .{ .cursor = .{ .row = row, .col = last } };
        with_selection_const(root, move_cursor_end, &cursel, self.metrics) catch return root;
        return self.delete_selection(root, &cursel, allocator) catch root;
    }

    fn find_last_non_ws(root: Buffer.Root, row: usize, metrics: Buffer.Metrics) usize {
        const Ctx = struct {
            col: usize = 0,
            last_non_ws: usize = 0,
            fn walker(ctx_: *anyopaque, egc: []const u8, wcwidth: usize, _: Buffer.Metrics) Buffer.Walker {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                ctx.col += wcwidth;
                switch (egc[0]) {
                    ' ', '\t' => {},
                    '\n' => return Buffer.Walker.stop,
                    else => ctx.last_non_ws = ctx.col,
                }
                return Buffer.Walker.keep_walking;
            }
        };
        var ctx: Ctx = .{};
        root.walk_egc_forward(row, Ctx.walker, &ctx, metrics) catch return 0;
        return ctx.last_non_ws;
    }

    fn find_first_non_ws(root: Buffer.Root, row: usize, metrics: Buffer.Metrics) usize {
        const Ctx = struct {
            col: usize = 0,
            fn walker(ctx_: *anyopaque, egc: []const u8, wcwidth: usize, _: Buffer.Metrics) Buffer.Walker {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                if (egc[0] == ' ' or egc[0] == '\t') {
                    ctx.col += wcwidth;
                    return Buffer.Walker.keep_walking;
                }
                return Buffer.Walker.stop;
            }
        };
        var ctx: Ctx = .{};
        root.walk_egc_forward(row, Ctx.walker, &ctx, metrics) catch return 0;
        return ctx.col;
    }

    fn write_range(
        self: *const Self,
        root: Buffer.Root,
        sel: Selection,
        writer: anytype,
        map_error: fn (e: anyerror, stack_trace: ?*std.builtin.StackTrace) @TypeOf(writer).Error,
        wcwidth_: ?*usize,
    ) @TypeOf(writer).Error!void {
        const Writer = @TypeOf(writer);
        const Ctx = struct {
            col: usize = 0,
            sel: Selection,
            writer: Writer,
            wcwidth: usize = 0,
            fn walker(ctx_: *anyopaque, egc: []const u8, wcwidth: usize, _: Buffer.Metrics) Buffer.Walker {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                if (ctx.col < ctx.sel.begin.col) {
                    ctx.col += wcwidth;
                    return Buffer.Walker.keep_walking;
                }
                _ = ctx.writer.write(egc) catch |e| return Buffer.Walker{ .err = e };
                ctx.wcwidth += wcwidth;
                if (egc[0] == '\n') {
                    ctx.col = 0;
                    ctx.sel.begin.col = 0;
                    ctx.sel.begin.row += 1;
                } else {
                    ctx.col += wcwidth;
                    ctx.sel.begin.col += wcwidth;
                }
                return if (ctx.sel.begin.eql(ctx.sel.end))
                    Buffer.Walker.stop
                else
                    Buffer.Walker.keep_walking;
            }
        };

        var ctx: Ctx = .{ .sel = sel, .writer = writer };
        ctx.sel.normalize();
        if (sel.begin.eql(sel.end))
            return;
        root.walk_egc_forward(sel.begin.row, Ctx.walker, &ctx, self.metrics) catch |e| return map_error(e, @errorReturnTrace());
        if (wcwidth_) |p| p.* = ctx.wcwidth;
    }

    pub fn update(self: *Self) void {
        self.update_scroll();
        self.update_event() catch {};
    }

    pub fn render(self: *Self, theme: *const Widget.Theme) bool {
        const frame = tracy.initZone(@src(), .{ .name = "editor render" });
        defer frame.deinit();
        self.update_syntax() catch |e| switch (e) {
            error.Stop => {},
            else => self.logger.err("update_syntax", e),
        };
        if (self.style_cache) |*cache| {
            if (!std.mem.eql(u8, self.style_cache_theme, theme.name)) {
                cache.deinit();
                self.style_cache = StyleCache.init(self.allocator);
                // self.logger.print("style_cache reset {s} -> {s}", .{ self.style_cache_theme, theme.name });
            }
        } else {
            self.style_cache = StyleCache.init(self.allocator);
        }
        self.style_cache_theme = theme.name;
        const cache: *StyleCache = &self.style_cache.?;
        self.render_screen(theme, cache);
        return self.scroll_dest != self.view.row or self.syntax_refresh_full;
    }

    const CellType = enum {
        empty,
        character,
        space,
        tab,
        eol,
        extension,
    };
    const CellMapEntry = struct {
        cell_type: CellType = .empty,
        cursor: bool = false,
    };
    const CellMap = ViewMap(CellMapEntry, .{});

    fn render_screen(self: *Self, theme: *const Widget.Theme, cache: *StyleCache) void {
        const ctx = struct {
            self: *Self,
            buf_row: usize,
            buf_col: usize = 0,
            y: usize = 0,
            x: usize = 0,
            match_idx: usize = 0,
            theme: *const Widget.Theme,
            hl_row: ?usize,
            leading: bool = true,
            cell_map: CellMap,

            fn walker(ctx_: *anyopaque, leaf: *const Buffer.Leaf, _: Buffer.Metrics) Buffer.Walker {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                const self_ = ctx.self;
                const view = self_.view;
                const n = &self_.plane;

                if (ctx.buf_row > view.row + view.rows)
                    return Buffer.Walker.stop;

                const bufsize = 4095;
                var bufstatic: [bufsize:0]u8 = undefined;
                const len = leaf.buf.len;
                var chunk_alloc: ?[:0]u8 = null;
                var chunk: [:0]u8 = if (len > bufsize) ret: {
                    const ptr = self_.allocator.allocSentinel(u8, len, 0) catch |e| return Buffer.Walker{ .err = e };
                    chunk_alloc = ptr;
                    break :ret ptr;
                } else &bufstatic;
                defer if (chunk_alloc) |p| self_.allocator.free(p);

                @memcpy(chunk[0..leaf.buf.len], leaf.buf);
                chunk[leaf.buf.len] = 0;
                chunk.len = leaf.buf.len;

                while (chunk.len > 0) {
                    if (ctx.buf_col >= view.col + view.cols)
                        break;
                    var cell = n.cell_init();
                    const c = &cell;
                    switch (chunk[0]) {
                        0...8, 10...31, 32, 9 => {},
                        else => ctx.leading = false,
                    }
                    const bytes, const colcount = switch (chunk[0]) {
                        0...8, 10...31 => |code| ctx.self.render_control_code(c, n, code, ctx.theme),
                        32 => ctx.self.render_space(c, n),
                        9 => ctx.self.render_tab(c, n, ctx.buf_col),
                        else => render_egc(c, n, chunk),
                    };
                    if (colcount == 0) {
                        chunk = chunk[bytes..];
                        continue;
                    }
                    var cell_map_val: CellType = switch (chunk[0]) {
                        32 => .space,
                        9 => .tab,
                        else => .character,
                    };
                    if (ctx.hl_row) |hl_row| if (hl_row == ctx.buf_row)
                        self_.render_line_highlight_cell(ctx.theme, c);
                    self_.render_matches(&ctx.match_idx, ctx.theme, c);
                    self_.render_selections(ctx.theme, c);

                    var advance = colcount;
                    if (ctx.buf_col < view.col) {
                        advance = if (ctx.buf_col + advance >= view.col)
                            ctx.buf_col + advance - view.col
                        else
                            0;
                    }
                    if (ctx.buf_col >= view.col) {
                        _ = n.putc(c) catch {};
                        ctx.cell_map.set_yx(ctx.y, ctx.x, .{ .cell_type = cell_map_val });
                        if (cell_map_val == .tab) cell_map_val = .extension;
                        advance -= 1;
                        ctx.x += 1;
                        n.cursor_move_yx(@intCast(ctx.y), @intCast(ctx.x)) catch {};
                    }
                    while (advance > 0) : (advance -= 1) {
                        if (ctx.x >= view.cols) break;
                        var cell_ = n.cell_init();
                        const c_ = &cell_;
                        if (ctx.hl_row) |hl_row| if (hl_row == ctx.buf_row)
                            self_.render_line_highlight_cell(ctx.theme, c_);
                        self_.render_matches(&ctx.match_idx, ctx.theme, c_);
                        self_.render_selections(ctx.theme, c_);
                        _ = n.putc(c_) catch {};
                        ctx.cell_map.set_yx(ctx.y, ctx.x, .{ .cell_type = cell_map_val });
                        if (cell_map_val == .tab) cell_map_val = .extension;
                        ctx.x += 1;
                        n.cursor_move_yx(@intCast(ctx.y), @intCast(ctx.x)) catch {};
                    }
                    ctx.buf_col += colcount;
                    chunk = chunk[bytes..];
                }

                if (leaf.eol) {
                    if (ctx.buf_col >= view.col) {
                        var c = ctx.self.render_eol(n);
                        if (ctx.hl_row) |hl_row| if (hl_row == ctx.buf_row)
                            self_.render_line_highlight_cell(ctx.theme, &c);
                        self_.render_matches(&ctx.match_idx, ctx.theme, &c);
                        self_.render_selections(ctx.theme, &c);
                        _ = n.putc(&c) catch {};
                        var term_cell = render_terminator(n, ctx.theme);
                        if (ctx.hl_row) |hl_row| if (hl_row == ctx.buf_row)
                            self_.render_line_highlight_cell(ctx.theme, &term_cell);
                        _ = n.putc(&term_cell) catch {};
                        ctx.cell_map.set_yx(ctx.y, ctx.x, .{ .cell_type = .eol });
                    }
                    ctx.buf_row += 1;
                    ctx.buf_col = 0;
                    ctx.y += 1;
                    ctx.x = 0;
                    ctx.leading = true;
                    if (ctx.y >= view.rows) return Buffer.Walker.stop;
                    n.cursor_move_yx(@intCast(ctx.y), @intCast(ctx.x)) catch return Buffer.Walker.stop;
                }
                return Buffer.Walker.keep_walking;
            }
        };
        const hl_row: ?usize = if (tui.config().highlight_current_line) blk: {
            if (self.get_primary().selection) |_|
                if (theme.editor_selection.bg) |sel_bg|
                    if (theme.editor_line_highlight.bg) |hl_bg|
                        if (sel_bg.color == hl_bg.color and sel_bg.alpha == hl_bg.alpha)
                            break :blk null;
            break :blk self.get_primary().cursor.row;
        } else null;
        var ctx_: ctx = .{
            .self = self,
            .buf_row = self.view.row,
            .theme = theme,
            .hl_row = hl_row,
            .cell_map = CellMap.init(self.allocator, self.view.rows, self.view.cols) catch @panic("OOM"),
        };
        defer ctx_.cell_map.deinit(self.allocator);
        const root = self.buf_root() catch return;

        {
            const frame = tracy.initZone(@src(), .{ .name = "editor render screen" });
            defer frame.deinit();

            self.plane.set_base_style(theme.editor);
            self.plane.erase();
            if (hl_row) |_|
                self.render_line_highlight(&self.get_primary().cursor, theme) catch {};
            self.plane.home();
            _ = root.walk_from_line_begin_const(self.view.row, ctx.walker, &ctx_, self.metrics) catch {};
        }
        self.render_syntax(theme, cache, root) catch {};
        self.render_whitespace_map(theme, ctx_.cell_map) catch {};
        if (tui.config().inline_diagnostics)
            self.render_diagnostics(theme, hl_row, ctx_.cell_map) catch {};
        self.render_column_highlights() catch {};
        self.render_cursors(theme, ctx_.cell_map) catch {};
    }

    fn render_cursors(self: *Self, theme: *const Widget.Theme, cell_map: CellMap) !void {
        const style = tui.get_selection_style();
        const frame = tracy.initZone(@src(), .{ .name = "editor render cursors" });
        defer frame.deinit();
        for (self.cursels.items[0 .. self.cursels.items.len - 1]) |*cursel_| if (cursel_.*) |*cursel| {
            const cursor = try self.get_rendered_cursor(style, cursel);
            try self.render_cursor_secondary(&cursor, theme, cell_map);
        };
        const cursor = try self.get_rendered_cursor(style, self.get_primary());
        try self.render_cursor_primary(&cursor, theme, cell_map);
    }

    fn get_rendered_cursor(self: *Self, style: anytype, cursel: anytype) !Cursor {
        return switch (style) {
            .normal => cursel.cursor,
            .inclusive => try cursel.to_inclusive_cursor(try self.buf_root(), self.metrics),
        };
    }

    fn render_cursor_primary(self: *Self, cursor: *const Cursor, theme: *const Widget.Theme, cell_map: CellMap) !void {
        if (!tui.is_mainview_focused() or !self.enable_terminal_cursor) {
            if (self.screen_cursor(cursor)) |pos| {
                set_cell_map_cursor(cell_map, pos.row, pos.col);
                self.plane.cursor_move_yx(@intCast(pos.row), @intCast(pos.col)) catch return;
                const style = if (tui.is_mainview_focused()) theme.editor_cursor else theme.editor_cursor_secondary;
                self.render_cursor_cell(style);
            }
        } else {
            if (self.screen_cursor(cursor)) |pos| {
                set_cell_map_cursor(cell_map, pos.row, pos.col);
                const y, const x = self.plane.rel_yx_to_abs(@intCast(pos.row), @intCast(pos.col));
                const configured_shape = tui.get_cursor_shape();
                const cursor_shape = if (self.cursels.items.len > 1) switch (configured_shape) {
                    .beam => .block,
                    .beam_blink => .block_blink,
                    .underline => .block,
                    .underline_blink => .block_blink,
                    else => configured_shape,
                } else configured_shape;
                tui.rdr().cursor_enable(y, x, cursor_shape) catch {};
            } else {
                tui.rdr().cursor_disable();
            }
        }
    }

    fn render_cursor_secondary(self: *Self, cursor: *const Cursor, theme: *const Widget.Theme, cell_map: CellMap) !void {
        if (self.screen_cursor(cursor)) |pos| {
            set_cell_map_cursor(cell_map, pos.row, pos.col);
            self.plane.cursor_move_yx(@intCast(pos.row), @intCast(pos.col)) catch return;
            self.render_cursor_cell(theme.editor_cursor_secondary);
        }
    }

    inline fn render_cursor_cell(self: *Self, style: Widget.Theme.Style) void {
        var cell = self.plane.cell_init();
        _ = self.plane.at_cursor_cell(&cell) catch return;
        cell.set_style(style);
        _ = self.plane.putc(&cell) catch {};
    }

    inline fn set_cell_map_cursor(cell_map: CellMap, y: usize, x: usize) void {
        const cell_type = cell_map.get_yx(y, x).cell_type;
        cell_map.set_yx(y, x, .{ .cursor = true, .cell_type = cell_type });
    }

    fn render_column_highlights(self: *Self) !void {
        const frame = tracy.initZone(@src(), .{ .name = "column highlights" });
        defer frame.deinit();
        const hl_cols: []const u16 = tui.highlight_columns();
        const alpha: u8 = tui.config().highlight_columns_alpha;
        const offset = self.view.col;
        for (hl_cols) |hl_col_| {
            if (hl_col_ < offset) continue;
            const hl_col = hl_col_ - offset;
            if (hl_col > self.view.cols) continue;
            for (0..self.view.rows) |row| for (0..self.view.cols) |col|
                if (hl_col > 0 and hl_col <= col) {
                    self.plane.cursor_move_yx(@intCast(row), @intCast(col)) catch return;
                    var cell = self.plane.cell_init();
                    _ = self.plane.at_cursor_cell(&cell) catch return;
                    cell.dim_bg(alpha);
                    _ = self.plane.putc(&cell) catch {};
                };
        }
    }

    fn render_line_highlight(self: *Self, cursor: *const Cursor, theme: *const Widget.Theme) !void {
        const row_min = self.view.row;
        const row_max = row_min + self.view.rows;
        if (cursor.row < row_min or row_max < cursor.row)
            return;
        const row = cursor.row - self.view.row;
        for (0..self.view.cols) |i| {
            self.plane.cursor_move_yx(@intCast(row), @intCast(i)) catch return;
            var cell = self.plane.cell_init();
            _ = self.plane.at_cursor_cell(&cell) catch return;
            self.render_line_highlight_cell(theme, &cell);
            _ = self.plane.putc(&cell) catch {};
        }
    }

    fn render_matches(self: *const Self, last_idx: *usize, theme: *const Widget.Theme, cell: *Cell) void {
        var y: c_uint = undefined;
        var x: c_uint = undefined;
        self.plane.cursor_yx(&y, &x);
        while (true) {
            if (last_idx.* >= self.matches.items.len)
                return;
            const sel = if (self.matches.items[last_idx.*]) |sel_| sel_ else {
                last_idx.* += 1;
                continue;
            };
            if (self.is_point_before_selection(sel, y, x))
                return;
            if (self.is_point_in_selection(sel, y, x))
                return self.render_match_cell(theme, cell, sel);
            last_idx.* += 1;
        }
    }

    fn render_selections(self: *const Self, theme: *const Widget.Theme, cell: *Cell) void {
        var y: c_uint = undefined;
        var x: c_uint = undefined;
        self.plane.cursor_yx(&y, &x);

        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel|
            if (cursel.selection) |sel_| {
                var sel = sel_;
                sel.normalize();
                if (self.is_point_in_selection(sel, y, x))
                    return self.render_selection_cell(theme, cell);
            };
    }

    fn render_diagnostics(self: *Self, theme: *const Widget.Theme, hl_row: ?usize, cell_map: CellMap) !void {
        for (self.diagnostics.items) |*diag| self.render_diagnostic(diag, theme, hl_row, cell_map);
    }

    fn render_diagnostic(self: *Self, diag: *const Diagnostic, theme: *const Widget.Theme, hl_row: ?usize, cell_map: CellMap) void {
        const screen_width = self.view.cols;
        const pos = self.screen_cursor(&diag.sel.begin) orelse return;
        var style = switch (diag.get_severity()) {
            .Error => theme.editor_error,
            .Warning => theme.editor_warning,
            .Information => theme.editor_information,
            .Hint => theme.editor_hint,
        };
        if (hl_row) |hlr| if (hlr == diag.sel.begin.row) {
            style = .{ .fg = style.fg, .bg = theme.editor_line_highlight.bg };
        };

        self.plane.cursor_move_yx(@intCast(pos.row), @intCast(pos.col)) catch return;
        self.render_diagnostic_cell(style);
        if (diag.sel.begin.row == diag.sel.end.row) {
            var col = pos.col;
            while (col < diag.sel.end.col) : (col += 1) {
                self.plane.cursor_move_yx(@intCast(pos.row), @intCast(col)) catch return;
                self.render_diagnostic_cell(style);
            }
        }
        var space_begin = screen_width;
        while (space_begin > 0) : (space_begin -= 1)
            if (cell_map.get_yx(pos.row, space_begin).cell_type != .empty) break;
        if (screen_width > min_diagnostic_view_len and space_begin < screen_width - min_diagnostic_view_len)
            self.render_diagnostic_message(diag.message, pos.row, screen_width - space_begin, style);
    }

    fn render_diagnostic_message(self: *Self, message_: []const u8, y: usize, max_space: usize, style: Widget.Theme.Style) void {
        self.plane.set_style(style);
        var iter = std.mem.splitScalar(u8, message_, '\n');
        if (iter.next()) |message|
            _ = self.plane.print_aligned_right(@intCast(y), " • {s}", .{message[0..@min(max_space - 3, message.len)]}) catch {};
    }

    inline fn render_diagnostic_cell(self: *Self, style: Widget.Theme.Style) void {
        var cell = self.plane.cell_init();
        _ = self.plane.at_cursor_cell(&cell) catch return;
        cell.set_style(.{ .fs = .undercurl });
        if (style.fg) |ul_col| cell.set_under_color(ul_col.color);
        _ = self.plane.putc(&cell) catch {};
    }

    inline fn render_selection_cell(_: *const Self, theme: *const Widget.Theme, cell: *Cell) void {
        cell.set_style_bg_opaque(theme.editor);
        cell.set_style_bg(theme.editor_selection);
    }

    inline fn render_match_cell(_: *const Self, theme: *const Widget.Theme, cell: *Cell, match: Match) void {
        cell.set_style_bg(if (match.style) |style| style else theme.editor_match);
    }

    inline fn render_line_highlight_cell(_: *const Self, theme: *const Widget.Theme, cell: *Cell) void {
        cell.set_style_bg(theme.editor_line_highlight);
    }

    inline fn render_control_code(self: *const Self, c: *Cell, n: *Plane, code: u8, theme: *const Widget.Theme) struct { usize, usize } {
        const val = Buffer.unicode.control_code_to_unicode(code);
        if (self.render_whitespace == .visible)
            c.set_style(theme.editor_whitespace);
        _ = n.cell_load(c, val) catch {};
        return .{ 1, 1 };
    }

    inline fn render_eol(_: *const Self, n: *Plane) Cell {
        const char = whitespace.char;
        var cell = n.cell_init();
        const c = &cell;
        _ = n.cell_load(c, char.blank) catch {};
        return cell;
    }

    inline fn render_terminator(n: *Plane, theme: *const Widget.Theme) Cell {
        var cell = n.cell_init();
        cell.set_style(theme.editor);
        _ = n.cell_load(&cell, "\u{2003}") catch unreachable;
        return cell;
    }

    inline fn render_space(self: *const Self, c: *Cell, n: *Plane) struct { usize, usize } {
        const char = whitespace.char;
        _ = n.cell_load(c, switch (self.render_whitespace) {
            .visible => char.visible,
            else => char.blank,
        }) catch {};
        return .{ 1, 1 };
    }

    inline fn render_tab(self: *const Self, c: *Cell, n: *Plane, abs_col: usize) struct { usize, usize } {
        const char = whitespace.char;
        const colcount = self.tab_width - (abs_col % self.tab_width);
        _ = n.cell_load(c, char.blank) catch {};
        return .{ 1, colcount };
    }

    inline fn render_egc(c: *Cell, n: *Plane, egc: [:0]const u8) struct { usize, usize } {
        const bytes = n.cell_load(c, egc) catch return .{ 1, 1 };
        const colcount = c.columns();
        return .{ bytes, colcount };
    }

    fn render_syntax(self: *Self, theme: *const Widget.Theme, cache: *StyleCache, root: Buffer.Root) !void {
        const frame = tracy.initZone(@src(), .{ .name = "editor render syntax" });
        defer frame.deinit();
        const syn = self.syntax orelse return;
        const Ctx = struct {
            self: *Self,
            theme: *const Widget.Theme,
            cache: *StyleCache,
            root: Buffer.Root,
            pos_cache: PosToWidthCache,
            last_begin: Cursor = Cursor.invalid(),
            fn cb(ctx: *@This(), range: syntax.Range, scope: []const u8, id: u32, idx: usize, _: *const syntax.Node) error{Stop}!void {
                const sel_ = ctx.pos_cache.range_to_selection(range, ctx.root, ctx.self.metrics) orelse return;

                if (idx > 0) return;
                if (sel_.begin.eql(ctx.last_begin)) return;
                ctx.last_begin = sel_.begin;
                const style_ = style_cache_lookup(ctx.theme, ctx.cache, scope, id);
                const style = if (style_) |sty| sty.style else return;
                var sel = sel_;

                if (sel.end.row < ctx.self.view.row) return;
                if (sel.begin.row > ctx.self.view.row + ctx.self.view.rows) return;
                if (sel.begin.row < ctx.self.view.row) sel.begin.row = ctx.self.view.row;
                if (sel.end.row > ctx.self.view.row + ctx.self.view.rows) sel.end.row = ctx.self.view.row + ctx.self.view.rows;

                if (sel.end.col < ctx.self.view.col) return;
                if (sel.begin.col > ctx.self.view.col + ctx.self.view.cols) return;
                if (sel.begin.col < ctx.self.view.col) sel.begin.col = ctx.self.view.col;
                if (sel.end.col > ctx.self.view.col + ctx.self.view.cols) sel.end.col = ctx.self.view.col + ctx.self.view.cols;

                for (sel.begin.row..sel.end.row + 1) |row| {
                    const begin_col = if (row == sel.begin.row) sel.begin.col else 0;
                    const end_col = if (row == sel.end.row) sel.end.col else ctx.self.view.col + ctx.self.view.cols;
                    const y = @max(ctx.self.view.row, row) - ctx.self.view.row;
                    const x = @max(ctx.self.view.col, begin_col) - ctx.self.view.col;
                    const end_x = @max(ctx.self.view.col, end_col) - ctx.self.view.col;
                    if (x >= end_x) return;
                    for (x..end_x) |x_|
                        try ctx.render_cell(y, x_, style);
                }
            }
            fn render_cell(ctx: *@This(), y: usize, x: usize, style: Widget.Theme.Style) !void {
                ctx.self.plane.cursor_move_yx(@intCast(y), @intCast(x)) catch return;
                var cell = ctx.self.plane.cell_init();
                _ = ctx.self.plane.at_cursor_cell(&cell) catch return;
                cell.set_style(style);
                _ = ctx.self.plane.putc(&cell) catch {};
            }
        };
        var ctx: Ctx = .{
            .self = self,
            .theme = theme,
            .cache = cache,
            .root = root,
            .pos_cache = try PosToWidthCache.init(self.allocator),
        };
        defer ctx.pos_cache.deinit();
        const range: syntax.Range = .{
            .start_point = .{ .row = @intCast(self.view.row), .column = 0 },
            .end_point = .{ .row = @intCast(self.view.row + self.view.rows), .column = 0 },
            .start_byte = 0,
            .end_byte = 0,
        };
        return syn.render(&ctx, Ctx.cb, range);
    }

    fn render_whitespace_map(self: *Self, theme: *const Widget.Theme, cell_map: CellMap) !void {
        const char = whitespace.char;
        const frame = tracy.initZone(@src(), .{ .name = "editor whitespace map" });
        defer frame.deinit();
        for (0..cell_map.rows) |y| {
            var leading = true;
            var leading_space = false;
            var tab_error = false;
            for (0..cell_map.cols) |x| {
                const cell_map_entry = cell_map.get_yx(y, x);
                const cell_type = cell_map_entry.cell_type;
                const next_cell_map_entry = cell_map.get_yx(y, x + 1);
                const next_cell_type = next_cell_map_entry.cell_type;
                switch (cell_type) {
                    .space => {
                        leading_space = true;
                        tab_error = false;
                    },
                    .empty, .character, .eol => {
                        leading = false;
                        leading_space = false;
                        tab_error = false;
                    },
                    .tab => {
                        if (leading_space) tab_error = true;
                    },
                    else => {},
                }
                if (cell_type == .character)
                    continue;
                self.plane.cursor_move_yx(@intCast(y), @intCast(x)) catch return;
                var cell = self.plane.cell_init();
                _ = self.plane.at_cursor_cell(&cell) catch return;
                switch (self.render_whitespace) {
                    .indent => {
                        if (leading and x % self.indent_size == 0)
                            cell.cell.char.grapheme = char.indent;
                    },
                    .leading => {
                        if (leading) {
                            if (get_whitespace_char(cell_type, next_cell_type)) |c|
                                cell.cell.char.grapheme = c;
                        }
                    },
                    .eol => {
                        if (cell_type == .eol)
                            cell.cell.char.grapheme = char.eol;
                    },
                    .tabs => {
                        if (cell_type == .tab or cell_type == .extension) {
                            if (get_whitespace_char(cell_type, next_cell_type)) |c|
                                cell.cell.char.grapheme = c;
                        }
                    },
                    .visible => {
                        if (get_whitespace_char(cell_type, next_cell_type)) |c|
                            cell.cell.char.grapheme = c;
                    },
                    .full => {
                        cell.cell.char.grapheme = get_whitespace_char(cell_type, next_cell_type) orelse switch (cell_type) {
                            .eol => char.eol,
                            .empty => "_",
                            else => "#",
                        };
                    },
                    else => {},
                }
                if (tab_error) {
                    cell.set_style_fg(theme.editor_error);
                    if (get_whitespace_char(cell_type, next_cell_type)) |c|
                        cell.cell.char.grapheme = c;
                } else {
                    cell.set_style_fg(theme.editor_whitespace);
                }
                _ = self.plane.putc(&cell) catch {};
            }
            var eol = cell_map.cols;
            while (eol > 0) : (eol -= 1)
                switch (cell_map.get_yx(y, eol).cell_type) {
                    .empty => continue,
                    .eol => break,
                    else => eol = 1,
                };
            if (eol > 0) {
                var trailing = eol;
                while (trailing > 0) : (trailing -= 1) {
                    const cell_map_entry = cell_map.get_yx(y, trailing);
                    switch (cell_map_entry.cell_type) {
                        .space, .tab, .extension, .eol, .empty => {},
                        .character => {
                            trailing += 1;
                            break;
                        },
                    }
                    if (cell_map_entry.cursor)
                        break;
                }
                for (trailing..eol) |x| {
                    const cell_type = cell_map.get_yx(y, x).cell_type;
                    const next_cell_type = cell_map.get_yx(y, x + 1).cell_type;
                    self.plane.cursor_move_yx(@intCast(y), @intCast(x)) catch return;
                    var cell = self.plane.cell_init();
                    _ = self.plane.at_cursor_cell(&cell) catch return;
                    cell.cell.char.grapheme = get_whitespace_char(cell_type, next_cell_type) orelse continue;
                    cell.set_style_fg(theme.editor_error);
                    _ = self.plane.putc(&cell) catch {};
                }
            }
        }
    }

    fn get_whitespace_char(cell_type: CellType, next_cell_type: CellType) ?[]const u8 {
        const char = whitespace.char;
        return switch (cell_type) {
            .space => char.visible,
            .tab => if (next_cell_type != .extension) char.tab_end else char.tab_begin,
            .extension => if (next_cell_type != .extension) char.tab_end else char.tab_begin,
            else => null,
        };
    }

    fn style_cache_lookup(theme: *const Widget.Theme, cache: *StyleCache, scope: []const u8, id: u32) ?Widget.Theme.Token {
        return if (cache.get(id)) |sty| ret: {
            break :ret sty;
        } else ret: {
            const sty = tui.find_scope_style(theme, scope) orelse null;
            cache.put(id, sty) catch {};
            break :ret sty;
        };
    }

    pub fn style_lookup(self: *Self, theme_: ?*const Widget.Theme, scope: []const u8, id: u32) ?Widget.Theme.Token {
        const theme = theme_ orelse return null;
        const cache = &(self.style_cache orelse return null);
        return style_cache_lookup(theme, cache, scope, id);
    }

    inline fn is_point_in_selection(self: *const Self, sel_: anytype, y: c_uint, x: c_uint) bool {
        const sel = sel_;
        const row = self.view.row + y;
        const col = self.view.col + x;
        const b_col: usize = if (sel.begin.row < row) 0 else sel.begin.col;
        const e_col: usize = if (row < sel.end.row) std.math.maxInt(u32) else sel.end.col;
        return sel.begin.row <= row and row <= sel.end.row and b_col <= col and col < e_col;
    }

    inline fn is_point_before_selection(self: *const Self, sel_: anytype, y: c_uint, x: c_uint) bool {
        const sel = sel_;
        const row = self.view.row + y;
        const col = self.view.col + x;
        return row < sel.begin.row or (row == sel.begin.row and col < sel.begin.col);
    }

    inline fn screen_cursor(self: *const Self, cursor: *const Cursor) ?Cursor {
        return if (self.view.is_visible(cursor)) .{
            .row = cursor.row - self.view.row,
            .col = cursor.col - self.view.col,
        } else null;
    }

    inline fn screen_pos_y(self: *Self) usize {
        return self.primary.row - self.view.row;
    }

    inline fn screen_pos_x(self: *Self) usize {
        return self.primary.col - self.view.col;
    }

    fn update_event(self: *Self) !void {
        const primary = self.get_primary();
        const dirty = if (self.buffer) |buf| buf.is_dirty() else false;

        const root: ?Buffer.Root = self.buf_root() catch null;
        const eol_mode = self.buf_eol_mode() catch .lf;
        const utf8_sanitized = self.buf_utf8_sanitized() catch false;
        const lines = if (root) |root_| root_.lines() else 0;

        if (token_from(self.last.root) != token_from(root)) {
            try self.send_editor_update(self.last.root, root, eol_mode);
            if (self.buffer) |buf|
                buf.lsp_version += 1;
        }

        if (self.last.eol_mode != eol_mode or self.last.utf8_sanitized != utf8_sanitized or self.last.indent_mode != self.indent_mode)
            try self.send_editor_eol_mode(eol_mode, utf8_sanitized, self.indent_mode);

        if (self.last.dirty != dirty)
            try self.send_editor_dirty(dirty);

        if (self.matches.items.len != self.last.matches and self.match_token == self.match_done_token) {
            try self.send_editor_match(self.matches.items.len);
            self.last.matches = self.matches.items.len;
        }

        if (self.cursels.items.len != self.last.cursels) {
            try self.send_editor_cursels(self.cursels.items.len);
            self.last.cursels = self.cursels.items.len;
        }

        if (lines != self.last.lines or !primary.cursor.eql(self.last.primary.cursor))
            try self.send_editor_pos(lines, &primary.cursor);

        if (primary.selection) |primary_selection_| {
            var primary_selection = primary_selection_;
            primary_selection.normalize();
            if (self.last.primary.selection) |last_selection_| {
                var last_selection = last_selection_;
                last_selection.normalize();
                if (!primary_selection.eql(last_selection))
                    try self.send_editor_selection_changed(primary_selection);
            } else try self.send_editor_selection_added(primary_selection);
        } else if (self.last.primary.selection) |_|
            try self.send_editor_selection_removed();

        if (lines != self.last.lines or !self.view.eql(self.last.view))
            try self.send_editor_view(lines, self.view);

        self.last.view = self.view;
        self.last.lines = lines;
        self.last.primary = primary.*;
        self.last.dirty = dirty;
        self.last.root = root;
        self.last.eol_mode = eol_mode;
        self.last.utf8_sanitized = utf8_sanitized;
    }

    fn send_editor_pos(self: *const Self, lines: usize, cursor: *const Cursor) !void {
        _ = try self.handlers.msg(.{ "E", "pos", lines, cursor.row, cursor.col });
    }

    fn send_editor_match(self: *const Self, matches: usize) !void {
        _ = try self.handlers.msg(.{ "E", "match", matches });
    }

    fn send_editor_cursels(self: *const Self, cursels: usize) !void {
        _ = try self.handlers.msg(.{ "E", "cursels", cursels });
    }

    fn send_editor_selection_added(self: *const Self, sel: Selection) !void {
        return self.send_editor_selection_changed(sel);
    }

    fn send_editor_selection_changed(self: *const Self, sel: Selection) !void {
        _ = try self.handlers.msg(.{ "E", "sel", sel.begin.row, sel.begin.col, sel.end.row, sel.end.col });
    }

    fn send_editor_selection_removed(self: *const Self) !void {
        _ = try self.handlers.msg(.{ "E", "sel", "none" });
    }

    fn send_editor_view(self: *const Self, lines: usize, view: View) !void {
        _ = try self.handlers.msg(.{ "E", "view", lines, view.rows, view.row });
    }

    fn send_editor_diagnostics(self: *const Self) !void {
        _ = try self.handlers.msg(.{ "E", "diag", self.diag_errors, self.diag_warnings, self.diag_info, self.diag_hints });
    }

    fn send_editor_modified(self: *Self) !void {
        try self.send_editor_cursel_msg("modified", self.get_primary());
    }

    pub fn send_editor_jump_source(self: *Self) !void {
        try self.send_editor_cursel_msg("jump_source", self.get_primary());
    }

    fn send_editor_jump_destination(self: *Self) !void {
        try self.send_editor_cursel_msg("jump_destination", self.get_primary());
    }

    fn send_editor_cursel_msg(self: *Self, tag: []const u8, cursel: *CurSel) !void {
        const c = cursel.cursor;
        _ = try if (cursel.selection) |s|
            self.handlers.msg(.{ "E", "location", tag, c.row, c.col, s.begin.row, s.begin.col, s.end.row, s.end.col })
        else
            self.handlers.msg(.{ "E", "location", tag, c.row, c.col });
    }

    fn send_editor_open(self: *const Self, file_path: []const u8, file_exists: bool, file_type: []const u8, file_icon: []const u8, file_color: u24) !void {
        _ = try self.handlers.msg(.{ "E", "open", file_path, file_exists, file_type, file_icon, file_color });
    }

    fn send_editor_save(self: *const Self, file_path: []const u8) !void {
        _ = try self.handlers.msg(.{ "E", "save", file_path });
        if (self.syntax) |_| project_manager.did_save(file_path) catch {};
    }

    fn send_editor_dirty(self: *const Self, file_dirty: bool) !void {
        _ = try self.handlers.msg(.{ "E", "dirty", file_dirty });
    }

    fn token_from(p: ?*const anyopaque) usize {
        return if (p) |p_| @intFromPtr(p_) else 0;
    }

    fn text_from_root(root_: ?Buffer.Root, eol_mode: Buffer.EolMode) ![]const u8 {
        const root = root_ orelse return &.{};
        var text = std.ArrayList(u8).init(std.heap.c_allocator);
        defer text.deinit();
        try root.store(text.writer(), eol_mode);
        return text.toOwnedSlice();
    }

    fn send_editor_update(self: *const Self, old_root: ?Buffer.Root, new_root: ?Buffer.Root, eol_mode: Buffer.EolMode) !void {
        _ = try self.handlers.msg(.{ "E", "update", token_from(new_root), token_from(old_root), @intFromEnum(eol_mode) });
        if (self.buffer) |buffer| if (self.syntax) |_| if (self.file_path) |file_path| if (old_root != null and new_root != null)
            project_manager.did_change(file_path, buffer.lsp_version, try text_from_root(new_root, eol_mode), try text_from_root(old_root, eol_mode), eol_mode) catch {};
        if (self.enable_auto_save)
            tp.self_pid().send(.{ "cmd", "save_file", .{} }) catch {};
    }

    fn send_editor_eol_mode(self: *const Self, eol_mode: Buffer.EolMode, utf8_sanitized: bool, indent_mode: IndentMode) !void {
        _ = try self.handlers.msg(.{ "E", "eol_mode", eol_mode, utf8_sanitized, indent_mode });
    }

    fn clamp_abs(self: *Self, abs: bool) void {
        var dest: View = self.view;
        dest.clamp(&self.get_primary().cursor, abs);
        self.update_scroll_dest_abs(dest.row);
        self.view.col = dest.col;
    }

    pub inline fn clamp(self: *Self) void {
        self.clamp_abs(false);
    }

    fn clamp_mouse(self: *Self) void {
        self.clamp_abs(true);
    }

    fn clear_all_cursors(self: *Self) void {
        self.cursels.clearRetainingCapacity();
    }

    fn cursor_count(self: *const Self) usize {
        var count: usize = 0;
        for (self.cursels.items[0..]) |*cursel| if (cursel.*) |_| {
            count += 1;
        };
        return count;
    }

    fn cursor_at(self: *const Self, cursor: Cursor) ?usize {
        for (self.cursels.items[0..], 0..) |*cursel, i| if (cursel.*) |*result|
            if (cursor.eql(result.cursor))
                return i;
        return null;
    }

    fn remove_cursor_at(self: *const Self, cursor: Cursor) bool {
        if (self.cursor_at(cursor)) |i| {
            if (self.cursor_count() > 1) // refuse to remove the last cursor
                self.cursels.items[i] = null;
            return true; // but return true anyway to indicate a cursor was found
        } else return false;
    }

    fn collapse_cursors(self: *Self) void {
        const frame = tracy.initZone(@src(), .{ .name = "collapse cursors" });
        defer frame.deinit();
        var old = self.cursels;
        defer old.deinit(self.allocator);
        self.cursels = CurSel.List.initCapacity(self.allocator, old.items.len) catch return;
        for (old.items[0 .. old.items.len - 1], 0..) |*a_, i| if (a_.*) |*a| {
            for (old.items[i + 1 ..], i + 1..) |*b_, j| if (b_.*) |*b| {
                if (a.cursor.eql(b.cursor))
                    old.items[j] = null;
            };
        };
        for (old.items) |*item_| if (item_.*) |*item| {
            (self.cursels.addOne(self.allocator) catch return).* = item.*;
        };
    }

    fn cancel_all_selections(self: *Self) void {
        var primary = self.get_primary().*;
        primary.disable_selection(self.buf_root() catch return, self.metrics);
        self.cursels.clearRetainingCapacity();
        self.cursels.addOneAssumeCapacity().* = primary;
        for (self.matches.items) |*match_| if (match_.*) |*match| {
            match.has_selection = false;
        };
    }

    fn cancel_all_matches(self: *Self) void {
        self.matches.clearAndFree(self.allocator);
    }

    pub fn clear_matches(self: *Self) void {
        self.cancel_all_matches();
        self.match_token += 1;
        self.match_done_token = self.match_token;
    }

    pub fn init_matches_update(self: *Self) void {
        self.cancel_all_matches();
        self.match_token += 1;
    }

    fn with_cursor_const(root: Buffer.Root, move: cursor_operator_const, cursel: *CurSel, metrics: Buffer.Metrics) error{Stop}!void {
        try move(root, &cursel.cursor, metrics);
    }

    fn with_cursors_const_once(self: *Self, root: Buffer.Root, move: cursor_operator_const) error{Stop}!void {
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            cursel.disable_selection(root, self.metrics);
            try with_cursor_const(root, move, cursel, self.metrics);
        };
        self.collapse_cursors();
    }

    fn with_cursors_const_repeat(self: *Self, root: Buffer.Root, move: cursor_operator_const, ctx: Context) error{Stop}!void {
        var repeat: usize = 1;
        _ = ctx.args.match(.{tp.extract(&repeat)}) catch false;
        while (repeat > 0) : (repeat -= 1) {
            for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
                cursel.disable_selection(root, self.metrics);
                try with_cursor_const(root, move, cursel, self.metrics);
            };
            self.collapse_cursors();
        }
    }

    fn with_cursor_const_arg(root: Buffer.Root, move: cursor_operator_const_arg, cursel: *CurSel, ctx: Context, metrics: Buffer.Metrics) error{Stop}!void {
        try move(root, &cursel.cursor, ctx, metrics);
    }

    fn with_cursors_const_arg(self: *Self, root: Buffer.Root, move: cursor_operator_const_arg, ctx: Context) error{Stop}!void {
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            cursel.disable_selection(root, self.metrics);
            try with_cursor_const_arg(root, move, cursel, ctx, self.metrics);
        };
        self.collapse_cursors();
    }

    fn with_cursor_and_view_const(root: Buffer.Root, move: cursor_view_operator_const, cursel: *CurSel, view: *const View, metrics: Buffer.Metrics) error{Stop}!void {
        try move(root, &cursel.cursor, view, metrics);
    }

    fn with_cursors_and_view_const(self: *Self, root: Buffer.Root, move: cursor_view_operator_const, view: *const View) error{Stop}!void {
        var someone_stopped = false;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel|
            with_cursor_and_view_const(root, move, cursel, view, self.metrics) catch {
                someone_stopped = true;
            };
        self.collapse_cursors();
        return if (someone_stopped) error.Stop else {};
    }

    fn with_cursor(root: Buffer.Root, move: cursor_operator, cursel: *CurSel, allocator: Allocator) error{Stop}!Buffer.Root {
        return try move(root, &cursel.cursor, allocator);
    }

    fn with_selection_const(root: Buffer.Root, move: cursor_operator_const, cursel: *CurSel, metrics: Buffer.Metrics) error{Stop}!void {
        const sel = try cursel.enable_selection(root, metrics);
        try move(root, &sel.end, metrics);
        cursel.cursor = sel.end;
        cursel.check_selection(root, metrics);
    }

    pub fn with_selections_const_once(self: *Self, root: Buffer.Root, move: cursor_operator_const) error{Stop}!void {
        var someone_stopped = false;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel|
            with_selection_const(root, move, cursel, self.metrics) catch {
                someone_stopped = true;
            };
        self.collapse_cursors();
        return if (someone_stopped) error.Stop else {};
    }

    pub fn with_selections_const_repeat(self: *Self, root: Buffer.Root, move: cursor_operator_const, ctx: Context) error{Stop}!void {
        var someone_stopped = false;
        var repeat: usize = 1;
        _ = ctx.args.match(.{tp.extract(&repeat)}) catch false;
        while (repeat > 0) : (repeat -= 1) {
            for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel|
                with_selection_const(root, move, cursel, self.metrics) catch {
                    someone_stopped = true;
                };
            self.collapse_cursors();
            if (someone_stopped) break;
        }
        return if (someone_stopped) error.Stop else {};
    }

    fn with_selection_const_arg(root: Buffer.Root, move: cursor_operator_const_arg, cursel: *CurSel, ctx: Context, metrics: Buffer.Metrics) error{Stop}!void {
        const sel = try cursel.enable_selection(root, metrics);
        try move(root, &sel.end, ctx, metrics);
        cursel.cursor = sel.end;
        cursel.check_selection(root, metrics);
    }

    fn with_selections_const_arg(self: *Self, root: Buffer.Root, move: cursor_operator_const_arg, ctx: Context) error{Stop}!void {
        var someone_stopped = false;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel|
            with_selection_const_arg(root, move, cursel, ctx, self.metrics) catch {
                someone_stopped = true;
            };
        self.collapse_cursors();
        return if (someone_stopped) error.Stop else {};
    }

    fn with_selection_and_view_const(root: Buffer.Root, move: cursor_view_operator_const, cursel: *CurSel, view: *const View, metrics: Buffer.Metrics) error{Stop}!void {
        const sel = try cursel.enable_selection(root, metrics);
        try move(root, &sel.end, view, metrics);
        cursel.cursor = sel.end;
    }

    fn with_selections_and_view_const(self: *Self, root: Buffer.Root, move: cursor_view_operator_const, view: *const View) error{Stop}!void {
        var someone_stopped = false;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel|
            with_selection_and_view_const(root, move, cursel, view, self.metrics) catch {
                someone_stopped = true;
            };
        self.collapse_cursors();
        return if (someone_stopped) error.Stop else {};
    }

    fn with_cursel_mut(self: *Self, root: Buffer.Root, op: cursel_operator_mut, cursel: *CurSel, allocator: Allocator) error{Stop}!Buffer.Root {
        return op(self, root, cursel, allocator);
    }

    fn with_cursels_mut_once(self: *Self, root_: Buffer.Root, move: cursel_operator_mut, allocator: Allocator) error{Stop}!Buffer.Root {
        var root = root_;
        var someone_stopped = false;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            root = self.with_cursel_mut(root, move, cursel, allocator) catch ret: {
                someone_stopped = true;
                break :ret root;
            };
        };
        self.collapse_cursors();
        return if (someone_stopped) error.Stop else root;
    }

    fn with_cursels_mut_repeat(self: *Self, root_: Buffer.Root, move: cursel_operator_mut, allocator: Allocator, ctx: Context) error{Stop}!Buffer.Root {
        var root = root_;
        var someone_stopped = false;
        var repeat: usize = 1;
        _ = ctx.args.match(.{tp.extract(&repeat)}) catch false;
        while (repeat > 0) : (repeat -= 1) {
            for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
                root = self.with_cursel_mut(root, move, cursel, allocator) catch ret: {
                    someone_stopped = true;
                    break :ret root;
                };
            };
            self.collapse_cursors();
            if (someone_stopped) break;
        }
        return if (someone_stopped) error.Stop else root;
    }

    fn with_cursel_const(root: Buffer.Root, op: cursel_operator_const, cursel: *CurSel) error{Stop}!void {
        return op(root, cursel);
    }

    fn with_cursels_const(self: *Self, root: Buffer.Root, move: cursel_operator_const) error{Stop}!void {
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel|
            with_cursel_const(root, move, cursel) catch return error.Stop;
        self.collapse_cursors();
    }

    pub fn nudge_insert(self: *Self, nudge: Selection, exclude: *const CurSel, _: usize) void {
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel|
            if (cursel != exclude)
                cursel.nudge_insert(nudge);
        for (self.matches.items) |*match_| if (match_.*) |*match|
            match.nudge_insert(nudge);
    }

    fn nudge_delete(self: *Self, nudge: Selection, exclude: *const CurSel, _: usize) void {
        for (self.cursels.items, 0..) |*cursel_, i| if (cursel_.*) |*cursel|
            if (cursel != exclude)
                if (!cursel.nudge_delete(nudge)) {
                    self.cursels.items[i] = null;
                };
        for (self.matches.items, 0..) |*match_, i| if (match_.*) |*match|
            if (!match.nudge_delete(nudge)) {
                self.matches.items[i] = null;
            };
    }

    pub fn delete_selection(self: *Self, root: Buffer.Root, cursel: *CurSel, allocator: Allocator) error{Stop}!Buffer.Root {
        var sel: Selection = cursel.selection orelse return error.Stop;
        sel.normalize();
        cursel.cursor = sel.begin;
        cursel.disable_selection_normal();
        var size: usize = 0;
        const root_ = try root.delete_range(sel, allocator, &size, self.metrics);
        self.nudge_delete(sel, cursel, size);
        return root_;
    }

    fn delete_to(self: *Self, move: cursor_operator_const, root_: Buffer.Root, allocator: Allocator) error{Stop}!Buffer.Root {
        var all_stop = true;
        var root = root_;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            if (cursel.selection) |_| {
                root = self.delete_selection(root, cursel, allocator) catch continue;
                all_stop = false;
                continue;
            }
            with_selection_const(root, move, cursel, self.metrics) catch continue;
            root = self.delete_selection(root, cursel, allocator) catch continue;
            all_stop = false;
        };

        if (all_stop)
            return error.Stop;
        return root;
    }

    const cursor_predicate = *const fn (root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) bool;
    const cursor_operator_const = *const fn (root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) error{Stop}!void;
    const cursor_operator_const_arg = *const fn (root: Buffer.Root, cursor: *Cursor, ctx: Context, metrics: Buffer.Metrics) error{Stop}!void;
    const cursor_view_operator_const = *const fn (root: Buffer.Root, cursor: *Cursor, view: *const View, metrics: Buffer.Metrics) error{Stop}!void;
    const cursel_operator_const = *const fn (root: Buffer.Root, cursel: *CurSel) error{Stop}!void;
    const cursor_operator = *const fn (root: Buffer.Root, cursor: *Cursor, allocator: Allocator) error{Stop}!Buffer.Root;
    const cursel_operator = *const fn (root: Buffer.Root, cursel: *CurSel, allocator: Allocator) error{Stop}!Buffer.Root;
    const cursel_operator_mut = *const fn (self: *Self, root: Buffer.Root, cursel: *CurSel, allocator: Allocator) error{Stop}!Buffer.Root;

    pub fn is_not_word_char(c: []const u8) bool {
        if (c.len == 0) return true;
        return switch (c[0]) {
            ' ' => true,
            '=' => true,
            '"' => true,
            '\'' => true,
            '\t' => true,
            '\n' => true,
            '/' => true,
            '\\' => true,
            '*' => true,
            ':' => true,
            '.' => true,
            ',' => true,
            '(' => true,
            ')' => true,
            '{' => true,
            '}' => true,
            '[' => true,
            ']' => true,
            ';' => true,
            '|' => true,
            '!' => true,
            '?' => true,
            '&' => true,
            '-' => true,
            '<' => true,
            '>' => true,
            else => false,
        };
    }

    fn is_word_char(c: []const u8) bool {
        return !is_not_word_char(c);
    }

    fn is_word_char_at_cursor(root: Buffer.Root, cursor: *const Cursor, metrics: Buffer.Metrics) bool {
        return cursor.test_at(root, is_word_char, metrics);
    }

    pub fn is_non_word_char_at_cursor(root: Buffer.Root, cursor: *const Cursor, metrics: Buffer.Metrics) bool {
        return cursor.test_at(root, is_not_word_char, metrics);
    }

    fn is_word_boundary_left(root: Buffer.Root, cursor: *const Cursor, metrics: Buffer.Metrics) bool {
        if (cursor.col == 0)
            return true;
        if (is_non_word_char_at_cursor(root, cursor, metrics))
            return false;
        var next = cursor.*;
        next.move_left(root, metrics) catch return true;
        if (is_non_word_char_at_cursor(root, &next, metrics))
            return true;
        return false;
    }

    fn is_whitespace(c: []const u8) bool {
        return (c.len == 0) or (c[0] == ' ') or (c[0] == '\t');
    }

    fn is_whitespace_or_eol(c: []const u8) bool {
        return is_whitespace(c) or c[0] == '\n';
    }

    pub fn is_whitespace_at_cursor(root: Buffer.Root, cursor: *const Cursor, metrics: Buffer.Metrics) bool {
        return cursor.test_at(root, is_whitespace, metrics);
    }

    fn is_non_whitespace_at_cursor(root: Buffer.Root, cursor: *const Cursor, metrics: Buffer.Metrics) bool {
        return !cursor.test_at(root, is_whitespace_or_eol, metrics);
    }

    pub fn is_word_boundary_left_vim(root: Buffer.Root, cursor: *const Cursor, metrics: Buffer.Metrics) bool {
        if (is_whitespace_at_cursor(root, cursor, metrics)) return false;
        var next = cursor.*;
        next.move_left(root, metrics) catch return true;

        const next_is_whitespace = is_whitespace_at_cursor(root, &next, metrics);
        if (next_is_whitespace) return true;

        const curr_is_non_word = is_non_word_char_at_cursor(root, cursor, metrics);
        const next_is_non_word = is_non_word_char_at_cursor(root, &next, metrics);
        return curr_is_non_word != next_is_non_word;
    }

    fn is_non_word_boundary_left(root: Buffer.Root, cursor: *const Cursor, metrics: Buffer.Metrics) bool {
        if (cursor.col == 0)
            return true;
        if (is_word_char_at_cursor(root, cursor, metrics))
            return false;
        var next = cursor.*;
        next.move_left(root, metrics) catch return true;
        if (is_word_char_at_cursor(root, &next, metrics))
            return true;
        return false;
    }

    fn is_word_boundary_right(root: Buffer.Root, cursor: *const Cursor, metrics: Buffer.Metrics) bool {
        const line_width = root.line_width(cursor.row, metrics) catch return true;
        if (cursor.col >= line_width)
            return true;
        if (is_non_word_char_at_cursor(root, cursor, metrics))
            return false;
        var next = cursor.*;
        next.move_right(root, metrics) catch return true;
        if (is_non_word_char_at_cursor(root, &next, metrics))
            return true;
        return false;
    }

    pub fn is_word_boundary_right_vim(root: Buffer.Root, cursor: *const Cursor, metrics: Buffer.Metrics) bool {
        if (is_whitespace_at_cursor(root, cursor, metrics)) return false;
        var next = cursor.*;
        next.move_right(root, metrics) catch return true;

        const next_is_whitespace = is_whitespace_at_cursor(root, &next, metrics);
        if (next_is_whitespace) return true;

        const curr_is_non_word = is_non_word_char_at_cursor(root, cursor, metrics);
        const next_is_non_word = is_non_word_char_at_cursor(root, &next, metrics);
        return curr_is_non_word != next_is_non_word;
    }

    fn is_non_word_boundary_right(root: Buffer.Root, cursor: *const Cursor, metrics: Buffer.Metrics) bool {
        const line_width = root.line_width(cursor.row, metrics) catch return true;
        if (cursor.col >= line_width)
            return true;
        if (is_word_char_at_cursor(root, cursor, metrics))
            return false;
        var next = cursor.*;
        next.move_right(root, metrics) catch return true;
        if (is_word_char_at_cursor(root, &next, metrics))
            return true;
        return false;
    }

    fn is_eol_left(_: Buffer.Root, cursor: *const Cursor, _: Buffer.Metrics) bool {
        if (cursor.col == 0)
            return true;
        return false;
    }

    fn is_eol_right(root: Buffer.Root, cursor: *const Cursor, metrics: Buffer.Metrics) bool {
        const line_width = root.line_width(cursor.row, metrics) catch return true;
        if (cursor.col >= line_width)
            return true;
        return false;
    }

    fn is_eol_right_vim(root: Buffer.Root, cursor: *const Cursor, metrics: Buffer.Metrics) bool {
        const line_width = root.line_width(cursor.row, metrics) catch return true;
        if (line_width == 0) return true;
        if (cursor.col >= line_width - 1)
            return true;
        return false;
    }

    fn is_eol_vim(root: Buffer.Root, cursor: *const Cursor, metrics: Buffer.Metrics) bool {
        const line_width = root.line_width(cursor.row, metrics) catch return true;
        if (line_width == 0) return true;
        if (cursor.col >= line_width)
            return true;
        return false;
    }

    pub fn move_cursor_left(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) error{Stop}!void {
        try cursor.move_left(root, metrics);
    }

    pub fn move_cursor_left_until(root: Buffer.Root, cursor: *Cursor, pred: cursor_predicate, metrics: Buffer.Metrics) void {
        while (!pred(root, cursor, metrics))
            move_cursor_left(root, cursor, metrics) catch return;
    }

    fn move_cursor_left_unless(root: Buffer.Root, cursor: *Cursor, pred: cursor_predicate, metrics: Buffer.Metrics) void {
        if (!pred(root, cursor, metrics))
            move_cursor_left(root, cursor, metrics) catch return;
    }

    pub fn move_cursor_begin(_: Buffer.Root, cursor: *Cursor, _: Buffer.Metrics) !void {
        cursor.move_begin();
    }

    fn smart_move_cursor_begin(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) !void {
        const first = find_first_non_ws(root, cursor.row, metrics);
        return if (cursor.col == first) cursor.move_begin() else cursor.move_to(root, cursor.row, first, metrics);
    }

    pub fn move_cursor_right(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) error{Stop}!void {
        try cursor.move_right(root, metrics);
    }

    pub fn move_cursor_right_until(root: Buffer.Root, cursor: *Cursor, pred: cursor_predicate, metrics: Buffer.Metrics) void {
        while (!pred(root, cursor, metrics))
            move_cursor_right(root, cursor, metrics) catch return;
    }

    fn move_cursor_right_unless(root: Buffer.Root, cursor: *Cursor, pred: cursor_predicate, metrics: Buffer.Metrics) void {
        if (!pred(root, cursor, metrics))
            move_cursor_right(root, cursor, metrics) catch return;
    }

    pub fn move_cursor_end(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) !void {
        cursor.move_end(root, metrics);
    }

    fn move_cursor_end_vim(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) !void {
        move_cursor_right_until(root, cursor, is_eol_vim, metrics);
    }

    fn move_cursor_up(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) !void {
        cursor.move_up(root, metrics) catch |e| switch (e) {
            error.Stop => cursor.move_begin(),
        };
    }

    fn move_cursor_up_vim(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) !void {
        try cursor.move_up(root, metrics);
        if (is_eol_vim(root, cursor, metrics)) try move_cursor_left_vim(root, cursor, metrics);
    }

    fn move_cursor_down(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) !void {
        cursor.move_down(root, metrics) catch |e| switch (e) {
            error.Stop => cursor.move_end(root, metrics),
        };
    }

    fn move_cursor_down_vim(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) !void {
        try cursor.move_down(root, metrics);
        if (is_eol_vim(root, cursor, metrics)) try move_cursor_left_vim(root, cursor, metrics);
    }

    fn move_cursor_buffer_begin(_: Buffer.Root, cursor: *Cursor, _: Buffer.Metrics) !void {
        cursor.move_buffer_begin();
    }

    fn move_cursor_buffer_end(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) !void {
        cursor.move_buffer_end(root, metrics);
    }

    fn move_cursor_page_up(root: Buffer.Root, cursor: *Cursor, view: *const View, metrics: Buffer.Metrics) !void {
        cursor.move_page_up(root, view, metrics);
    }

    fn move_cursor_page_down(root: Buffer.Root, cursor: *Cursor, view: *const View, metrics: Buffer.Metrics) !void {
        cursor.move_page_down(root, view, metrics);
    }

    fn move_cursor_half_page_up(root: Buffer.Root, cursor: *Cursor, view: *const View, metrics: Buffer.Metrics) !void {
        cursor.move_half_page_up(root, view, metrics);
    }

    fn move_cursor_half_page_up_vim(root: Buffer.Root, cursor: *Cursor, view: *const View, metrics: Buffer.Metrics) !void {
        cursor.move_half_page_up(root, view, metrics);
        if (is_eol_vim(root, cursor, metrics)) try move_cursor_left_vim(root, cursor, metrics);
    }

    fn move_cursor_half_page_down(root: Buffer.Root, cursor: *Cursor, view: *const View, metrics: Buffer.Metrics) !void {
        cursor.move_half_page_down(root, view, metrics);
    }

    fn move_cursor_half_page_down_vim(root: Buffer.Root, cursor: *Cursor, view: *const View, metrics: Buffer.Metrics) !void {
        cursor.move_half_page_down(root, view, metrics);
        if (is_eol_vim(root, cursor, metrics)) try move_cursor_left_vim(root, cursor, metrics);
    }

    pub fn primary_click(self: *Self, y: c_int, x: c_int) !void {
        const root = self.buf_root() catch return;
        if (self.fast_scroll) {
            var at: Cursor = .{};
            at.move_abs(root, &self.view, @intCast(y), @intCast(x), self.metrics) catch return;
            if (self.remove_cursor_at(at))
                return;
            try self.push_cursor();
        } else {
            self.cancel_all_selections();
        }
        const primary = self.get_primary();
        primary.disable_selection(root, self.metrics);
        self.selection_mode = .char;
        try self.send_editor_jump_source();
        primary.cursor.move_abs(root, &self.view, @intCast(y), @intCast(x), self.metrics) catch return;
        self.clamp_mouse();
        try self.send_editor_jump_destination();
        if (self.jump_mode) try self.goto_definition(.{});
    }

    pub fn primary_double_click(self: *Self, y: c_int, x: c_int) !void {
        const primary = self.get_primary();
        const root = self.buf_root() catch return;
        primary.disable_selection(root, self.metrics);
        self.selection_mode = .word;
        primary.cursor.move_abs(root, &self.view, @intCast(y), @intCast(x), self.metrics) catch return;
        _ = try self.select_word_at_cursor(primary);
        self.selection_drag_initial = primary.selection;
        self.clamp_mouse();
    }

    pub fn primary_triple_click(self: *Self, y: c_int, x: c_int) !void {
        const primary = self.get_primary();
        const root = self.buf_root() catch return;
        primary.disable_selection(root, self.metrics);
        self.selection_mode = .line;
        primary.cursor.move_abs(root, &self.view, @intCast(y), @intCast(x), self.metrics) catch return;
        try self.select_line_at_cursor(primary);
        self.selection_drag_initial = primary.selection;
        self.clamp_mouse();
    }

    pub fn primary_drag(self: *Self, y: c_int, x: c_int) void {
        const y_ = if (y < 0) 0 else y;
        const x_ = if (x < 0) 0 else x;
        const primary = self.get_primary();
        const root = self.buf_root() catch return;
        const sel = primary.enable_selection(root, self.metrics) catch return;
        sel.end.move_abs(root, &self.view, @intCast(y_), @intCast(x_), self.metrics) catch return;
        const initial = self.selection_drag_initial orelse sel.*;
        switch (self.selection_mode) {
            .char => {},
            .word => {
                if (sel.begin.right_of(sel.end)) {
                    sel.begin = initial.end;
                    with_selection_const(root, move_cursor_word_begin, primary, self.metrics) catch {};
                } else {
                    sel.begin = initial.begin;
                    with_selection_const(root, move_cursor_word_end, primary, self.metrics) catch {};
                }
            },
            .line => {
                if (sel.begin.right_of(sel.end)) {
                    sel.begin = initial.end;
                    with_selection_const(root, move_cursor_begin, primary, self.metrics) catch {};
                } else {
                    sel.begin = initial.begin;
                    blk: {
                        with_selection_const(root, move_cursor_end, primary, self.metrics) catch break :blk;
                        with_selection_const(root, move_cursor_right, primary, self.metrics) catch {};
                    }
                }
            },
        }
        primary.cursor = sel.end;
        primary.check_selection(root, self.metrics);
        self.clamp_mouse();
    }

    pub fn drag_to(self: *Self, ctx: Context) Result {
        var y: i32 = 0;
        var x: i32 = 0;
        if (!try ctx.args.match(.{ tp.extract(&y), tp.extract(&x) }))
            return error.InvalidDragToArgument;
        return self.primary_drag(y, x);
    }
    pub const drag_to_meta: Meta = .{ .arguments = &.{ .integer, .integer } };

    pub fn secondary_click(self: *Self, y: c_int, x: c_int) !void {
        return self.primary_drag(y, x);
    }

    pub fn secondary_drag(self: *Self, y: c_int, x: c_int) !void {
        return self.primary_drag(y, x);
    }

    fn get_animation_min_lag() f64 {
        const ms: f64 = @floatFromInt(tui.config().animation_min_lag);
        return @max(ms * 0.001, 0.001); // to seconds
    }

    fn get_animation_max_lag() f64 {
        const ms: f64 = @floatFromInt(tui.config().animation_max_lag);
        return @max(ms * 0.001, 0.001); // to seconds
    }

    fn update_animation_lag(self: *Self) void {
        const ts = time.microTimestamp();
        const tdiff = ts - self.animation_last_time;
        const lag: f64 = @as(f64, @floatFromInt(tdiff)) / time.us_per_s;
        self.animation_lag = @max(@min(lag, get_animation_max_lag()), get_animation_min_lag());
        self.animation_last_time = ts;
        // self.logger.print("update_lag: {d} {d:.2}", .{ lag, self.animation_lag }) catch {};
    }

    fn update_animation_step(self: *Self, dest: usize) void {
        const steps_ = @max(dest, self.view.row) - @min(dest, self.view.row);
        self.update_animation_lag();
        const steps: f64 = @floatFromInt(steps_);
        const frame_rate: f64 = @floatFromInt(self.animation_frame_rate);
        const frame_time: f64 = 1.0 / frame_rate;
        const step_frames = self.animation_lag / frame_time;
        const step: f64 = steps / step_frames;
        self.animation_step = @intFromFloat(step);
        if (self.animation_step == 0) self.animation_step = 1;
    }

    fn update_scroll(self: *Self) void {
        const step = self.animation_step;
        const view = self.view.row;
        const dest = self.scroll_dest;
        if (view == dest) return;
        var row = view;
        if (view < dest) {
            row += step;
            if (dest < row) row = dest;
        } else if (dest < view) {
            row -= if (row < step) row else step;
            if (row < dest) row = dest;
        }
        self.view.row = row;
    }

    fn update_scroll_dest_abs(self: *Self, dest: usize) void {
        const root = self.buf_root() catch return;
        const max_view = if (root.lines() <= scroll_cursor_min_border_distance) 0 else root.lines() - scroll_cursor_min_border_distance;
        self.scroll_dest = @min(dest, max_view);
        self.update_animation_step(dest);
    }

    fn scroll_up(self: *Self) void {
        var dest: View = self.view;
        dest.row = if (dest.row > scroll_step_small) dest.row - scroll_step_small else 0;
        self.update_scroll_dest_abs(dest.row);
    }

    fn scroll_down(self: *Self) void {
        var dest: View = self.view;
        dest.row += scroll_step_small;
        self.update_scroll_dest_abs(dest.row);
    }

    fn scroll_pageup(self: *Self) void {
        var dest: View = self.view;
        dest.row = if (dest.row > dest.rows) dest.row - dest.rows else 0;
        self.update_scroll_dest_abs(dest.row);
    }

    fn scroll_pagedown(self: *Self) void {
        var dest: View = self.view;
        dest.row += dest.rows;
        self.update_scroll_dest_abs(dest.row);
    }

    pub fn scroll_up_pageup(self: *Self, _: Context) Result {
        if (self.fast_scroll)
            self.scroll_pageup()
        else
            self.scroll_up();
    }
    pub const scroll_up_pageup_meta: Meta = .{};

    pub fn scroll_down_pagedown(self: *Self, _: Context) Result {
        if (self.fast_scroll)
            self.scroll_pagedown()
        else
            self.scroll_down();
    }
    pub const scroll_down_pagedown_meta: Meta = .{};

    pub fn scroll_to(self: *Self, row: usize) void {
        self.update_scroll_dest_abs(row);
    }

    fn scroll_view_offset(self: *Self, offset: usize) void {
        const primary = self.get_primary();
        const row = if (primary.cursor.row > offset) primary.cursor.row - offset else 0;
        self.update_scroll_dest_abs(row);
    }

    pub fn scroll_view_center(self: *Self, _: Context) Result {
        return self.scroll_view_offset(self.view.rows / 2);
    }
    pub const scroll_view_center_meta: Meta = .{ .description = "Scroll cursor to center of view" };

    pub fn scroll_view_center_cycle(self: *Self, _: Context) Result {
        const cursor_row = self.get_primary().cursor.row;
        return if (cursor_row == self.view.row + scroll_cursor_min_border_distance)
            self.scroll_view_bottom(.{})
        else if (cursor_row == self.view.row + self.view.rows / 2)
            self.scroll_view_top(.{})
        else
            self.scroll_view_offset(self.view.rows / 2);
    }
    pub const scroll_view_center_cycle_meta: Meta = .{ .description = "Scroll cursor to center/top/bottom of view" };

    pub fn scroll_view_top(self: *Self, _: Context) Result {
        return self.scroll_view_offset(scroll_cursor_min_border_distance);
    }
    pub const scroll_view_top_meta: Meta = .{};

    pub fn scroll_view_bottom(self: *Self, _: Context) Result {
        return self.scroll_view_offset(if (self.view.rows > scroll_cursor_min_border_distance) self.view.rows - scroll_cursor_min_border_distance else 0);
    }
    pub const scroll_view_bottom_meta: Meta = .{};

    fn set_clipboard(self: *Self, text: []const u8) void {
        if (self.clipboard) |old|
            self.allocator.free(old);
        self.clipboard = text;
        if (builtin.os.tag == .windows) {
            @import("renderer").copy_to_windows_clipboard(text) catch |e|
                self.logger.print_err("clipboard", "failed to set clipboard: {any}", .{e});
        } else {
            tui.rdr().copy_to_system_clipboard(text);
        }
    }

    pub fn set_clipboard_internal(self: *Self, text: []const u8) void {
        if (self.clipboard) |old|
            self.allocator.free(old);
        self.clipboard = text;
    }

    pub fn copy_selection(root: Buffer.Root, sel: Selection, text_allocator: Allocator, metrics: Buffer.Metrics) ![]u8 {
        var size: usize = 0;
        _ = try root.get_range(sel, null, &size, null, metrics);
        const buf__ = try text_allocator.alloc(u8, size);
        return (try root.get_range(sel, buf__, null, null, metrics)).?;
    }

    pub fn get_selection(self: *const Self, sel: Selection, text_allocator: Allocator) ![]u8 {
        return copy_selection(try self.buf_root(), sel, text_allocator, self.metrics);
    }

    fn copy_word_at_cursor(self: *Self, text_allocator: Allocator) ![]const u8 {
        const root = try self.buf_root();
        const primary = self.get_primary();
        const sel = if (primary.selection) |*sel| sel else try self.select_word_at_cursor(primary);
        return try copy_selection(root, sel.*, text_allocator, self.metrics);
    }

    pub fn cut_selection(self: *Self, root: Buffer.Root, cursel: *CurSel) !struct { []const u8, Buffer.Root } {
        return if (cursel.selection) |sel| ret: {
            var old_selection: Selection = sel;
            old_selection.normalize();
            const cut_text = try copy_selection(root, sel, self.allocator, self.metrics);
            if (cut_text.len > 100) {
                self.logger.print("cut:{s}...", .{std.fmt.fmtSliceEscapeLower(cut_text[0..100])});
            } else {
                self.logger.print("cut:{s}", .{std.fmt.fmtSliceEscapeLower(cut_text)});
            }
            break :ret .{ cut_text, try self.delete_selection(root, cursel, try self.buf_a()) };
        } else error.Stop;
    }

    fn expand_selection_to_all(root: Buffer.Root, sel: *Selection, metrics: Buffer.Metrics) !void {
        try move_cursor_buffer_begin(root, &sel.begin, metrics);
        try move_cursor_buffer_end(root, &sel.end, metrics);
    }

    pub fn insert(self: *Self, root: Buffer.Root, cursel: *CurSel, s: []const u8, allocator: Allocator) !Buffer.Root {
        var root_ = if (cursel.selection) |_| try self.delete_selection(root, cursel, allocator) else root;
        const cursor = &cursel.cursor;
        const begin = cursel.cursor;
        cursor.row, cursor.col, root_ = try root_.insert_chars(cursor.row, cursor.col, s, allocator, self.metrics);
        cursor.target = cursor.col;
        self.nudge_insert(.{ .begin = begin, .end = cursor.* }, cursel, s.len);
        return root_;
    }

    pub fn insert_line_vim(self: *Self, root: Buffer.Root, cursel: *CurSel, s: []const u8, allocator: Allocator) !Buffer.Root {
        var root_ = if (cursel.selection) |_| try self.delete_selection(root, cursel, allocator) else root;
        const cursor = &cursel.cursor;
        const begin = cursel.cursor;
        _, _, root_ = try root_.insert_chars(cursor.row, cursor.col, s, allocator, self.metrics);
        cursor.target = cursor.col;
        self.nudge_insert(.{ .begin = begin, .end = cursor.* }, cursel, s.len);
        return root_;
    }

    pub fn cut_to(self: *Self, move: cursor_operator_const, root_: Buffer.Root) !struct { []const u8, Buffer.Root } {
        var all_stop = true;
        var root = root_;

        var text = std.ArrayListUnmanaged(u8).empty;
        defer text.deinit(self.allocator);
        var first = true;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            if (cursel.selection) |_| {
                const cut_text, root = self.cut_selection(root, cursel) catch continue;
                all_stop = false;
                if (first) {
                    first = false;
                } else {
                    try text.appendSlice(self.allocator, "\n");
                }
                try text.appendSlice(self.allocator, cut_text);
                continue;
            }

            with_selection_const(root, move, cursel, self.metrics) catch continue;
            const cut_text, root = self.cut_selection(root, cursel) catch continue;

            if (first) {
                first = false;
            } else {
                try text.appendSlice(self.allocator, "\n");
            }
            try text.appendSlice(self.allocator, cut_text);
            all_stop = false;
        };

        if (all_stop)
            return error.Stop;
        return .{ try text.toOwnedSlice(self.allocator), root };
    }

    pub fn cut_internal_vim(self: *Self, _: Context) Result {
        const primary = self.get_primary();
        const b = self.buf_for_update() catch return;
        var root = b.root;
        var text = std.ArrayListUnmanaged(u8).empty;
        defer text.deinit(self.allocator);
        if (self.cursels.items.len == 1)
            if (primary.selection) |_| {} else {
                try text.appendSlice(self.allocator, "\n");
                const sel = primary.enable_selection(root, self.metrics) catch return;
                try move_cursor_begin(root, &sel.begin, self.metrics);
                try move_cursor_end(root, &sel.end, self.metrics);
                try move_cursor_right(root, &sel.end, self.metrics);
            };
        var first = true;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            const cut_text, root = try self.cut_selection(root, cursel);
            if (first) {
                first = false;
            } else {
                try text.appendSlice(self.allocator, "\n");
            }
            try text.appendSlice(self.allocator, cut_text);
        };
        try self.update_buf(root);
        self.set_clipboard_internal(try text.toOwnedSlice(self.allocator));
        self.clamp();
    }
    pub const cut_internal_vim_meta: Meta = .{ .description = "Cut selection or current line to internal clipboard (vim)" };

    pub fn cut(self: *Self, _: Context) Result {
        const primary = self.get_primary();
        const b = self.buf_for_update() catch return;
        var root = b.root;
        if (self.cursels.items.len == 1)
            if (primary.selection) |_| {} else {
                const sel = primary.enable_selection(root, self.metrics) catch return;
                try move_cursor_begin(root, &sel.begin, self.metrics);
                move_cursor_end(root, &sel.end, self.metrics) catch |e| switch (e) {
                    error.Stop => {},
                    else => return e,
                };
                move_cursor_right(root, &sel.end, self.metrics) catch |e| switch (e) {
                    error.Stop => {},
                    else => return e,
                };
            };
        var first = true;
        var text = std.ArrayListUnmanaged(u8).empty;
        defer text.deinit(self.allocator);
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            const cut_text, root = try self.cut_selection(root, cursel);
            if (first) {
                first = false;
            } else {
                try text.appendSlice(self.allocator, "\n");
            }
            try text.appendSlice(self.allocator, cut_text);
        };
        try self.update_buf(root);
        self.set_clipboard(try text.toOwnedSlice(self.allocator));
        self.clamp();
    }
    pub const cut_meta: Meta = .{ .description = "Cut selection or current line to clipboard" };

    pub fn copy(self: *Self, _: Context) Result {
        const primary = self.get_primary();
        const root = self.buf_root() catch return;
        var first = true;
        var text = std.ArrayListUnmanaged(u8).empty;
        defer text.deinit(self.allocator);
        if (self.cursels.items.len == 1)
            if (primary.selection) |_| {} else {
                const sel = primary.enable_selection(root, self.metrics) catch return;
                try move_cursor_begin(root, &sel.begin, self.metrics);
                try move_cursor_end(root, &sel.end, self.metrics);
                try move_cursor_right(root, &sel.end, self.metrics);
            };
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            if (cursel.selection) |sel| {
                const copy_text = try copy_selection(root, sel, self.allocator, self.metrics);
                if (first) {
                    first = false;
                } else {
                    try text.appendSlice(self.allocator, "\n");
                }
                try text.appendSlice(self.allocator, copy_text);
            }
        };
        if (text.items.len > 0) {
            if (text.items.len > 100) {
                self.logger.print("copy:{s}...", .{std.fmt.fmtSliceEscapeLower(text.items[0..100])});
            } else {
                self.logger.print("copy:{s}", .{std.fmt.fmtSliceEscapeLower(text.items)});
            }
            self.set_clipboard(try text.toOwnedSlice(self.allocator));
        }
    }
    pub const copy_meta: Meta = .{ .description = "Copy selection to clipboard" };

    fn copy_cursel_file_name(
        self: *const Self,
        writer: anytype,
    ) Result {
        if (self.file_path) |file_path|
            try writer.writeAll(file_path)
        else
            try writer.writeByte('*');
    }

    fn copy_cursel_file_name_and_location(
        self: *const Self,
        cursel: *const CurSel,
        writer: anytype,
    ) Result {
        try self.copy_cursel_file_name(writer);
        if (cursel.selection) |sel_| {
            var sel = sel_;
            sel.normalize();
            if (sel.begin.row == sel.end.row)
                try writer.print(":{d}:{d}:{d}", .{
                    sel.begin.row + 1,
                    sel.begin.col + 1,
                    sel.end.col + 1,
                })
            else
                try writer.print(":{d}:{d}:{d}:{d}", .{
                    sel.begin.row + 1,
                    sel.begin.col + 1,
                    sel.end.row + 1,
                    sel.end.col + 1,
                });
        } else if (cursel.cursor.col != 0)
            try writer.print(":{d}:{d}", .{ cursel.cursor.row + 1, cursel.cursor.col + 1 })
        else
            try writer.print(":{d}", .{cursel.cursor.row + 1});
    }

    pub fn copy_file_name(self: *Self, ctx: Context) Result {
        var mode: enum { all, primary_only, file_name_only } = .all;
        _ = ctx.args.match(.{tp.extract(&mode)}) catch false;
        var text: std.ArrayListUnmanaged(u8) = .empty;
        const writer = text.writer(self.allocator);
        var first = true;
        switch (mode) {
            .file_name_only => try self.copy_cursel_file_name(writer),
            .primary_only => try self.copy_cursel_file_name_and_location(
                self.get_primary(),
                writer,
            ),
            else => for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
                if (first) first = false else try writer.writeByte('\n');
                try self.copy_cursel_file_name_and_location(cursel, writer);
            },
        }
        if (text.items.len > 0) {
            if (text.items.len > 100)
                self.logger.print("copy:{s}...", .{
                    std.fmt.fmtSliceEscapeLower(text.items[0..100]),
                })
            else
                self.logger.print("copy:{s}", .{
                    std.fmt.fmtSliceEscapeLower(text.items),
                });
            self.set_clipboard(try text.toOwnedSlice(self.allocator));
        }
    }
    pub const copy_file_name_meta: Meta = .{
        .description = "Copy file name and location to clipboard",
    };

    pub fn copy_internal_vim(self: *Self, _: Context) Result {
        const root = self.buf_root() catch return;
        var first = true;
        var text = std.ArrayListUnmanaged(u8).empty;
        defer text.deinit(self.allocator);
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            if (cursel.selection) |sel| {
                const copy_text = try copy_selection(root, sel, self.allocator, self.metrics);
                if (first) {
                    first = false;
                } else {
                    try text.appendSlice(self.allocator, "\n");
                }
                try text.appendSlice(self.allocator, copy_text);
            }
        };
        if (text.items.len > 0) {
            if (text.items.len > 100) {
                self.logger.print("copy:{s}...", .{std.fmt.fmtSliceEscapeLower(text.items[0..100])});
            } else {
                self.logger.print("copy:{s}", .{std.fmt.fmtSliceEscapeLower(text.items)});
            }
            self.set_clipboard_internal(try text.toOwnedSlice(self.allocator));
        }
    }
    pub const copy_internal_vim_meta: Meta = .{ .description = "Copy selection to internal clipboard (vim)" };

    pub fn copy_line_internal_vim(self: *Self, _: Context) Result {
        const primary = self.get_primary();
        const root = self.buf_root() catch return;
        var first = true;
        var text = std.ArrayListUnmanaged(u8).empty;
        defer text.deinit(self.allocator);
        try text.appendSlice(self.allocator, "\n");
        if (primary.selection) |_| {} else {
            const sel = primary.enable_selection(root, self.metrics) catch return;
            try move_cursor_begin(root, &sel.begin, self.metrics);
            try move_cursor_end(root, &sel.end, self.metrics);
            try move_cursor_right(root, &sel.end, self.metrics);
        }
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            if (cursel.selection) |sel| {
                const copy_text = try copy_selection(root, sel, self.allocator, self.metrics);
                if (first) {
                    first = false;
                } else {
                    try text.appendSlice(self.allocator, "\n");
                }
                try text.appendSlice(self.allocator, copy_text);
            }
        };
        if (text.items.len > 0) {
            if (text.items.len > 100) {
                self.logger.print("copy:{s}...", .{std.fmt.fmtSliceEscapeLower(text.items[0..100])});
            } else {
                self.logger.print("copy:{s}", .{std.fmt.fmtSliceEscapeLower(text.items)});
            }
            self.set_clipboard_internal(try text.toOwnedSlice(self.allocator));
        }
    }
    pub const copy_line_internal_vim_meta: Meta = .{ .description = "Copy line to internal clipboard (vim)" };

    pub fn paste(self: *Self, ctx: Context) Result {
        var text: []const u8 = undefined;
        if (!(ctx.args.buf.len > 0 and try ctx.args.match(.{tp.extract(&text)}))) {
            if (self.clipboard) |text_| text = text_ else return;
        }
        self.logger.print("paste: {d} bytes", .{text.len});
        const b = try self.buf_for_update();
        var root = b.root;
        if (self.cursels.items.len == 1) {
            const primary = self.get_primary();
            root = try self.insert(root, primary, text, b.allocator);
        } else {
            if (std.mem.indexOfScalar(u8, text, '\n')) |_| {
                var pos: usize = 0;
                for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
                    if (std.mem.indexOfScalarPos(u8, text, pos, '\n')) |next| {
                        root = try self.insert(root, cursel, text[pos..next], b.allocator);
                        pos = next + 1;
                    } else {
                        root = try self.insert(root, cursel, text[pos..], b.allocator);
                        pos = 0;
                    }
                };
            } else {
                for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
                    root = try self.insert(root, cursel, text, b.allocator);
                };
            }
        }
        try self.update_buf(root);
        self.clamp();
        self.need_render();
    }
    pub const paste_meta: Meta = .{ .description = "Paste from internal clipboard" };

    pub fn paste_internal_vim(self: *Self, ctx: Context) Result {
        var text: []const u8 = undefined;
        if (!(ctx.args.buf.len > 0 and try ctx.args.match(.{tp.extract(&text)}))) {
            if (self.clipboard) |text_| text = text_ else return;
        }

        self.logger.print("paste: {d} bytes", .{text.len});
        const b = try self.buf_for_update();
        var root = b.root;

        if (std.mem.eql(u8, text[text.len - 1 ..], "\n")) text = text[0 .. text.len - 1];

        if (std.mem.indexOfScalar(u8, text, '\n')) |idx| {
            if (idx == 0) {
                for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
                    try move_cursor_end(root, &cursel.cursor, self.metrics);
                    root = try self.insert(root, cursel, "\n", b.allocator);
                };
                text = text[1..];
            }
            if (self.cursels.items.len == 1) {
                const primary = self.get_primary();
                root = try self.insert_line_vim(root, primary, text, b.allocator);
            } else {
                for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
                    root = try self.insert_line_vim(root, cursel, text, b.allocator);
                };
            }
        } else {
            if (self.cursels.items.len == 1) {
                const primary = self.get_primary();
                root = try self.insert(root, primary, text, b.allocator);
            } else {
                for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
                    root = try self.insert(root, cursel, text, b.allocator);
                };
            }
        }

        try self.update_buf(root);
        self.clamp();
        self.need_render();
    }
    pub const paste_internal_vim_meta: Meta = .{ .description = "Paste from internal clipboard (vim)" };

    pub fn delete_forward(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.delete_to(move_cursor_right, b.root, b.allocator);
        try self.update_buf(root);
        self.clamp();
    }
    pub const delete_forward_meta: Meta = .{ .description = "Delete next character" };

    pub fn cut_forward_internal(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const text, const root = try self.cut_to(move_cursor_right, b.root);
        self.set_clipboard_internal(text);
        try self.update_buf(root);
        self.clamp();
    }
    pub const cut_forward_internal_meta: Meta = .{ .description = "Cut next character to internal clipboard" };

    pub fn delete_backward(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.delete_to(move_cursor_left, b.root, b.allocator);
        try self.update_buf(root);
        self.clamp();
    }
    pub const delete_backward_meta: Meta = .{ .description = "Delete previous character" };

    pub fn smart_delete_backward(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        var all_stop = true;
        var root = b.root;

        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            if (cursel.selection) |_| {
                // just delete selection
                root = self.delete_selection(root, cursel, b.allocator) catch continue;
                all_stop = false;
                continue;
            }

            // detect indentation
            const first = find_first_non_ws(root, cursel.cursor.row, self.metrics);

            // select char to the left
            with_selection_const(root, move_cursor_left, cursel, self.metrics) catch continue;

            // if we don't have a selection after move_cursor_left there is nothing to delete
            if (cursel.selection) |*sel| {
                if (first > sel.end.col) {
                    // we are inside leading whitespace
                    // select to next indentation boundary
                    while (sel.end.col > 0 and sel.end.col % self.indent_size != 0)
                        with_selection_const(root, move_cursor_left, cursel, self.metrics) catch break;
                } else {
                    // char being deleted
                    const egc_left, _, _ = sel.end.egc_at(root, self.metrics) catch {
                        root = self.delete_selection(root, cursel, b.allocator) catch continue;
                        all_stop = false;
                        continue;
                    };
                    // char to the right of char being deleted
                    const egc_right, _, _ = sel.begin.egc_at(root, self.metrics) catch {
                        root = self.delete_selection(root, cursel, b.allocator) catch continue;
                        all_stop = false;
                        continue;
                    };

                    // if left char is a smart pair left char, also delete smart pair right char
                    for (Buffer.unicode.char_pairs) |pair| if (std.mem.eql(u8, egc_left, pair[0]) and std.mem.eql(u8, egc_right, pair[1])) {
                        sel.begin.move_right(root, self.metrics) catch {};
                        break;
                    };
                }
            }
            root = self.delete_selection(root, cursel, b.allocator) catch continue;
            all_stop = false;
        };

        if (all_stop)
            return error.Stop;

        try self.update_buf(root);
        self.clamp();
    }
    pub const smart_delete_backward_meta: Meta = .{ .description = "Delete previous character (smart)" };

    pub fn delete_word_left(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.delete_to(move_cursor_word_left_space, b.root, b.allocator);
        try self.update_buf(root);
        self.clamp();
    }
    pub const delete_word_left_meta: Meta = .{ .description = "Delete previous word" };

    pub fn cut_buffer_end(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const text, const root = try self.cut_to(move_cursor_buffer_end, b.root);
        self.set_clipboard_internal(text);
        try self.update_buf(root);
        self.clamp();
    }
    pub const cut_buffer_end_meta: Meta = .{ .description = "Cut to the end of the buffer (copies cut text into clipboard)" };

    pub fn cut_buffer_begin(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const text, const root = try self.cut_to(move_cursor_buffer_begin, b.root);
        self.set_clipboard_internal(text);
        try self.update_buf(root);
        self.clamp();
    }
    pub const cut_buffer_begin_meta: Meta = .{ .description = "Cut to the beginning of the buffer (copies cut text into clipboard)" };

    pub fn cut_word_left_vim(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const text, const root = try self.cut_to(move_cursor_word_left_vim, b.root);
        self.set_clipboard_internal(text);
        try self.update_buf(root);
        self.clamp();
    }
    pub const cut_word_left_vim_meta: Meta = .{ .description = "Cut previous word to internal clipboard (vim)" };

    pub fn delete_word_right(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.delete_to(move_cursor_word_right_space, b.root, b.allocator);
        try self.update_buf(root);
        self.clamp();
    }
    pub const delete_word_right_meta: Meta = .{ .description = "Delete next word" };

    pub fn cut_word_right_vim(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const text, const root = try self.cut_to(move_cursor_word_right_vim, b.root);
        self.set_clipboard_internal(text);
        try self.update_buf(root);
        self.clamp();
    }
    pub const cut_word_right_vim_meta: Meta = .{ .description = "Cut next word to internal clipboard (vim)" };

    pub fn delete_to_begin(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.delete_to(move_cursor_begin, b.root, b.allocator);
        try self.update_buf(root);
        self.clamp();
    }
    pub const delete_to_begin_meta: Meta = .{ .description = "Delete to beginning of line" };

    pub fn delete_to_end(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.delete_to(move_cursor_end, b.root, b.allocator);
        try self.update_buf(root);
        self.clamp();
    }
    pub const delete_to_end_meta: Meta = .{ .description = "Delete to end of line" };

    pub fn cut_to_end_vim(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const text, const root = try self.cut_to(move_cursor_end_vim, b.root);
        self.set_clipboard_internal(text);
        try self.update_buf(root);
        self.clamp();
    }
    pub const cut_to_end_vim_meta: Meta = .{ .description = "Cut to end of line (vim)" };

    pub fn join_next_line(self: *Self, ctx: Context) Result {
        const b = try self.buf_for_update();
        try self.with_cursors_const_repeat(b.root, move_cursor_end, ctx);
        var root = try self.delete_to(move_cursor_right_until_non_whitespace, b.root, b.allocator);
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            root = try self.insert(root, cursel, " ", b.allocator);
        };
        try self.update_buf(root);
        self.clamp();
    }
    pub const join_next_line_meta: Meta = .{ .description = "Join next line", .arguments = &.{.integer} };

    fn move_cursors_or_collapse_selection(
        self: *Self,
        direction: enum { left, right },
        ctx: Context,
    ) error{Stop}!void {
        const root = try self.buf_root();
        var repeat: usize = 1;
        _ = ctx.args.match(.{tp.extract(&repeat)}) catch false;
        while (repeat > 0) : (repeat -= 1) {
            for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
                if (cursel.selection) |*sel| {
                    cursel.cursor = switch (direction) {
                        .left => if (sel.is_reversed()) sel.end else sel.begin,
                        .right => if (sel.is_reversed()) sel.begin else sel.end,
                    };
                    cursel.disable_selection(root, self.metrics);
                } else {
                    try with_cursor_const(root, switch (direction) {
                        .left => move_cursor_left,
                        .right => move_cursor_right,
                    }, cursel, self.metrics);
                }
            };
            self.collapse_cursors();
        }
        self.clamp();
    }

    pub fn move_left(self: *Self, ctx: Context) Result {
        self.move_cursors_or_collapse_selection(.left, ctx) catch {};
    }
    pub const move_left_meta: Meta = .{ .description = "Move cursor left", .arguments = &.{.integer} };

    pub fn move_right(self: *Self, ctx: Context) Result {
        self.move_cursors_or_collapse_selection(.right, ctx) catch {};
    }
    pub const move_right_meta: Meta = .{ .description = "Move cursor right", .arguments = &.{.integer} };

    fn move_cursor_left_vim(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) error{Stop}!void {
        move_cursor_left_unless(root, cursor, is_eol_left, metrics);
    }

    fn move_cursor_right_vim(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) error{Stop}!void {
        move_cursor_right_unless(root, cursor, is_eol_right_vim, metrics);
    }

    pub fn move_left_vim(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const_repeat(root, move_cursor_left_vim, ctx) catch {};
        self.clamp();
    }
    pub const move_left_vim_meta: Meta = .{ .description = "Move cursor left (vim)", .arguments = &.{.integer} };

    pub fn move_right_vim(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const_repeat(root, move_cursor_right_vim, ctx) catch {};
        self.clamp();
    }
    pub const move_right_vim_meta: Meta = .{ .description = "Move cursor right (vim)", .arguments = &.{.integer} };

    fn move_cursor_word_begin(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) error{Stop}!void {
        if (is_non_word_char_at_cursor(root, cursor, metrics)) {
            move_cursor_left_until(root, cursor, is_word_boundary_right, metrics);
            try move_cursor_right(root, cursor, metrics);
        } else {
            move_cursor_left_until(root, cursor, is_word_boundary_left, metrics);
        }
    }

    fn move_cursor_word_end(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) error{Stop}!void {
        if (is_non_word_char_at_cursor(root, cursor, metrics)) {
            move_cursor_right_until(root, cursor, is_word_boundary_left, metrics);
            try move_cursor_left(root, cursor, metrics);
        } else {
            move_cursor_right_until(root, cursor, is_word_boundary_right, metrics);
        }
        try move_cursor_right(root, cursor, metrics);
    }

    fn move_cursor_word_left(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) error{Stop}!void {
        try move_cursor_left(root, cursor, metrics);
        move_cursor_left_until(root, cursor, is_word_boundary_left, metrics);
    }

    fn move_cursor_word_left_vim(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) error{Stop}!void {
        try move_cursor_left(root, cursor, metrics);
        move_cursor_left_until(root, cursor, is_word_boundary_left_vim, metrics);
    }

    fn move_cursor_word_left_space(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) error{Stop}!void {
        try move_cursor_left(root, cursor, metrics);
        var next = cursor.*;
        next.move_left(root, metrics) catch
            return move_cursor_left_until(root, cursor, is_word_boundary_left, metrics);
        if (is_non_word_char_at_cursor(root, cursor, metrics) and is_non_word_char_at_cursor(root, &next, metrics))
            move_cursor_left_until(root, cursor, is_non_word_boundary_left, metrics)
        else
            move_cursor_left_until(root, cursor, is_word_boundary_left, metrics);
    }

    pub fn move_cursor_word_right(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) error{Stop}!void {
        move_cursor_right_until(root, cursor, is_word_boundary_right, metrics);
        try move_cursor_right(root, cursor, metrics);
    }

    pub fn move_cursor_word_right_vim(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) error{Stop}!void {
        try move_cursor_right(root, cursor, metrics);
        move_cursor_right_until(root, cursor, is_word_boundary_left_vim, metrics);
    }

    pub fn move_cursor_word_right_end_vim(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) error{Stop}!void {
        try move_cursor_right(root, cursor, metrics);
        move_cursor_right_until(root, cursor, is_word_boundary_right_vim, metrics);
    }

    pub fn move_cursor_word_right_space(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) error{Stop}!void {
        var next = cursor.*;
        next.move_right(root, metrics) catch {
            move_cursor_right_until(root, cursor, is_word_boundary_right, metrics);
            try move_cursor_right(root, cursor, metrics);
            return;
        };
        if (is_non_word_char_at_cursor(root, cursor, metrics) and is_non_word_char_at_cursor(root, &next, metrics))
            move_cursor_right_until(root, cursor, is_non_word_boundary_right, metrics)
        else
            move_cursor_right_until(root, cursor, is_word_boundary_right, metrics);
        try move_cursor_right(root, cursor, metrics);
    }

    pub fn move_cursor_right_until_non_whitespace(root: Buffer.Root, cursor: *Cursor, metrics: Buffer.Metrics) error{Stop}!void {
        move_cursor_right_until(root, cursor, is_non_whitespace_at_cursor, metrics);
    }

    pub fn move_word_left(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const_repeat(root, move_cursor_word_left, ctx) catch {};
        self.clamp();
    }
    pub const move_word_left_meta: Meta = .{ .description = "Move cursor left by word", .arguments = &.{.integer} };

    pub fn move_word_left_vim(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const_repeat(root, move_cursor_word_left_vim, ctx) catch {};
        self.clamp();
    }
    pub const move_word_left_vim_meta: Meta = .{ .description = "Move cursor left by word (vim)", .arguments = &.{.integer} };

    pub fn move_word_right(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const_repeat(root, move_cursor_word_right, ctx) catch {};
        self.clamp();
    }
    pub const move_word_right_meta: Meta = .{ .description = "Move cursor right by word", .arguments = &.{.integer} };

    pub fn move_word_right_vim(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const_repeat(root, move_cursor_word_right_vim, ctx) catch {};
        self.clamp();
    }
    pub const move_word_right_vim_meta: Meta = .{ .description = "Move cursor right by word (vim)", .arguments = &.{.integer} };

    pub fn move_word_right_end_vim(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const_repeat(root, move_cursor_word_right_end_vim, ctx) catch {};
        self.clamp();
    }
    pub const move_word_right_end_vim_meta: Meta = .{ .description = "Move cursor right by end of word (vim)", .arguments = &.{.integer} };

    fn move_cursor_to_char_left(root: Buffer.Root, cursor: *Cursor, ctx: Context, metrics: Buffer.Metrics) error{Stop}!void {
        var egc: []const u8 = undefined;
        if (!(ctx.args.match(.{tp.extract(&egc)}) catch return error.Stop))
            return error.Stop;
        try move_cursor_left(root, cursor, metrics);
        while (true) {
            const curr_egc, _, _ = root.egc_at(cursor.row, cursor.col, metrics) catch return error.Stop;
            if (std.mem.eql(u8, curr_egc, egc))
                return;
            if (is_eol_left(root, cursor, metrics))
                return;
            move_cursor_left(root, cursor, metrics) catch return error.Stop;
        }
    }

    pub fn move_cursor_to_char_right(root: Buffer.Root, cursor: *Cursor, ctx: Context, metrics: Buffer.Metrics) error{Stop}!void {
        var egc: []const u8 = undefined;
        if (!(ctx.args.match(.{tp.extract(&egc)}) catch return error.Stop))
            return error.Stop;
        try move_cursor_right(root, cursor, metrics);
        while (true) {
            const curr_egc, _, _ = root.egc_at(cursor.row, cursor.col, metrics) catch return error.Stop;
            if (std.mem.eql(u8, curr_egc, egc))
                return;
            if (is_eol_right(root, cursor, metrics))
                return;
            move_cursor_right(root, cursor, metrics) catch return error.Stop;
        }
    }

    fn move_cursor_till_char_left(root: Buffer.Root, cursor: *Cursor, ctx: Context, metrics: Buffer.Metrics) error{Stop}!void {
        var egc: []const u8 = undefined;
        if (!(ctx.args.match(.{tp.extract(&egc)}) catch return error.Stop))
            return error.Stop;
        try move_cursor_left(root, cursor, metrics);
        var prev = cursor.*;
        try move_cursor_left(root, &prev, metrics);
        while (true) {
            const prev_egc, _, _ = root.egc_at(prev.row, prev.col, metrics) catch return error.Stop;
            if (std.mem.eql(u8, prev_egc, egc))
                return;
            if (is_eol_left(root, cursor, metrics))
                return;
            move_cursor_left(root, cursor, metrics) catch return error.Stop;
            move_cursor_left(root, &prev, metrics) catch return error.Stop;
        }
    }

    pub fn move_cursor_till_char_right(root: Buffer.Root, cursor: *Cursor, ctx: Context, metrics: Buffer.Metrics) error{Stop}!void {
        var egc: []const u8 = undefined;
        if (!(ctx.args.match(.{tp.extract(&egc)}) catch return error.Stop))
            return error.Stop;
        try move_cursor_right(root, cursor, metrics);
        var next = cursor.*;
        try move_cursor_right(root, &next, metrics);
        while (true) {
            const next_egc, _, _ = root.egc_at(next.row, next.col, metrics) catch return error.Stop;
            if (std.mem.eql(u8, next_egc, egc))
                return;
            if (is_eol_right(root, cursor, metrics))
                return;
            move_cursor_right(root, cursor, metrics) catch return error.Stop;
            move_cursor_right(root, &next, metrics) catch return error.Stop;
        }
    }

    pub fn move_to_char_left(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const_arg(root, move_cursor_to_char_left, ctx) catch {};
        self.clamp();
    }
    pub const move_to_char_left_meta: Meta = .{ .arguments = &.{.integer} };

    pub fn move_to_char_right(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const_arg(root, move_cursor_to_char_right, ctx) catch {};
        self.clamp();
    }
    pub const move_to_char_right_meta: Meta = .{ .arguments = &.{.integer} };

    pub fn move_till_char_left(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const_arg(root, move_cursor_till_char_left, ctx) catch {};
        self.clamp();
    }
    pub const move_till_char_left_meta: Meta = .{ .arguments = &.{.integer} };

    pub fn move_till_char_right(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const_arg(root, move_cursor_till_char_right, ctx) catch {};
        self.clamp();
    }
    pub const move_till_char_right_meta: Meta = .{ .arguments = &.{.integer} };

    pub fn move_or_select_to_char_left(self: *Self, ctx: Context) Result {
        const selected = if (self.get_primary().selection) |_| true else false;
        if (selected) try self.select_to_char_left(ctx) else try self.move_to_char_left(ctx);
    }
    pub const move_or_select_to_char_left_meta: Meta = .{ .arguments = &.{.integer} };

    pub fn move_or_select_to_char_right(self: *Self, ctx: Context) Result {
        const selected = if (self.get_primary().selection) |_| true else false;
        if (selected) try self.select_to_char_right(ctx) else try self.move_to_char_right(ctx);
    }
    pub const move_or_select_to_char_right_meta: Meta = .{ .arguments = &.{.integer} };

    pub fn move_up(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const_repeat(root, move_cursor_up, ctx) catch {};
        self.clamp();
    }
    pub const move_up_meta: Meta = .{ .description = "Move cursor up", .arguments = &.{.integer} };

    pub fn move_up_vim(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const_repeat(root, move_cursor_up_vim, ctx) catch {};
        self.clamp();
    }
    pub const move_up_vim_meta: Meta = .{ .description = "Move cursor up (vim)", .arguments = &.{.integer} };

    pub fn add_cursor_up(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        var repeat: usize = 1;
        _ = ctx.args.match(.{tp.extract(&repeat)}) catch false;
        while (repeat > 0) : (repeat -= 1) {
            try self.push_cursor();
            const primary = self.get_primary();
            move_cursor_up(root, &primary.cursor, self.metrics) catch {};
        }
        self.clamp();
    }
    pub const add_cursor_up_meta: Meta = .{ .description = "Add cursor up", .arguments = &.{.integer} };

    pub fn move_down(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const_repeat(root, move_cursor_down, ctx) catch {};
        self.clamp();
    }
    pub const move_down_meta: Meta = .{ .description = "Move cursor down", .arguments = &.{.integer} };

    pub fn move_down_vim(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const_repeat(root, move_cursor_down_vim, ctx) catch {};
        self.clamp();
    }
    pub const move_down_vim_meta: Meta = .{ .description = "Move cursor down (vim)", .arguments = &.{.integer} };

    pub fn add_cursor_down(self: *Self, ctx: Context) Result {
        var repeat: usize = 1;
        _ = ctx.args.match(.{tp.extract(&repeat)}) catch false;
        while (repeat > 0) : (repeat -= 1) {
            try self.push_cursor();
            const primary = self.get_primary();
            const root = try self.buf_root();
            move_cursor_down(root, &primary.cursor, self.metrics) catch {};
        }
        self.clamp();
    }
    pub const add_cursor_down_meta: Meta = .{ .description = "Add cursor down", .arguments = &.{.integer} };

    pub fn add_cursor_next_match(self: *Self, ctx: Context) Result {
        try self.send_editor_jump_source();
        var repeat: usize = 1;
        _ = ctx.args.match(.{tp.extract(&repeat)}) catch false;
        while (repeat > 0) : (repeat -= 1) {
            if (self.matches.items.len == 0) {
                const root = self.buf_root() catch return;
                self.with_cursors_const_once(root, move_cursor_word_begin) catch {};
                try self.with_selections_const_once(root, move_cursor_word_end);
            } else if (self.get_next_match(self.get_primary().cursor)) |match| {
                try self.push_cursor();
                const primary = self.get_primary();
                const root = self.buf_root() catch return;
                primary.selection = match.to_selection();
                match.has_selection = true;
                primary.cursor.move_to(root, match.end.row, match.end.col, self.metrics) catch return;
            }
        }
        self.clamp();
        try self.send_editor_jump_destination();
    }
    pub const add_cursor_next_match_meta: Meta = .{ .description = "Add cursor at next highlighted match", .arguments = &.{.integer} };

    pub fn add_cursor_all_matches(self: *Self, _: Context) Result {
        if (self.matches.items.len == 0) return;
        try self.send_editor_jump_source();
        while (self.get_next_match(self.get_primary().cursor)) |match| {
            try self.push_cursor();
            const primary = self.get_primary();
            const root = self.buf_root() catch return;
            primary.selection = match.to_selection();
            match.has_selection = true;
            primary.cursor.move_to(root, match.end.row, match.end.col, self.metrics) catch return;
        }
        self.clamp();
        try self.send_editor_jump_destination();
    }
    pub const add_cursor_all_matches_meta: Meta = .{ .description = "Add cursors to all highlighted matches" };

    fn add_cursors_to_cursel_line_ends(self: *Self, root: Buffer.Root, cursel: *CurSel) !void {
        const sel = try cursel.enable_selection(root, self.metrics);
        sel.normalize();
        var row = sel.begin.row;
        while (row <= sel.end.row) : (row += 1) {
            const new_cursel = try self.cursels.addOne(self.allocator);
            new_cursel.* = CurSel{
                .selection = null,
                .cursor = .{
                    .row = row,
                    .col = 0,
                },
            };
            new_cursel.*.?.cursor.move_end(root, self.metrics);
        }
    }

    pub fn add_cursors_to_line_ends(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        const cursels = try self.cursels.toOwnedSlice(self.allocator);
        defer self.allocator.free(cursels);
        for (cursels) |*cursel_| if (cursel_.*) |*cursel|
            try self.add_cursors_to_cursel_line_ends(root, cursel);
        self.collapse_cursors();
        self.clamp();
    }
    pub const add_cursors_to_line_ends_meta: Meta = .{ .description = "Add cursors to all lines in selection" };

    fn pull_cursel_up(self: *Self, root_: Buffer.Root, cursel: *CurSel, allocator: Allocator) error{Stop}!Buffer.Root {
        var root = root_;
        const saved = cursel.*;
        const sel = cursel.expand_selection_to_line(root, self.metrics) catch return error.Stop;
        var sfa = std.heap.stackFallback(4096, self.allocator);
        const cut_text = copy_selection(root, sel.*, sfa.get(), self.metrics) catch return error.Stop;
        defer allocator.free(cut_text);
        root = try self.delete_selection(root, cursel, allocator);
        try cursel.cursor.move_up(root, self.metrics);
        root = self.insert(root, cursel, cut_text, allocator) catch return error.Stop;
        cursel.* = saved;
        try cursel.cursor.move_up(root, self.metrics);
        if (cursel.selection) |*sel_| {
            try sel_.begin.move_up(root, self.metrics);
            try sel_.end.move_up(root, self.metrics);
        }
        return root;
    }

    pub fn pull_up(self: *Self, ctx: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.with_cursels_mut_repeat(b.root, pull_cursel_up, b.allocator, ctx);
        try self.update_buf(root);
        self.clamp();
    }
    pub const pull_up_meta: Meta = .{ .description = "Pull line up", .arguments = &.{.integer} };

    fn pull_cursel_down(self: *Self, root_: Buffer.Root, cursel: *CurSel, allocator: Allocator) error{Stop}!Buffer.Root {
        var root = root_;
        const saved = cursel.*;
        const sel = cursel.expand_selection_to_line(root, self.metrics) catch return error.Stop;
        var sfa = std.heap.stackFallback(4096, self.allocator);
        const cut_text = copy_selection(root, sel.*, sfa.get(), self.metrics) catch return error.Stop;
        defer allocator.free(cut_text);
        root = try self.delete_selection(root, cursel, allocator);
        try cursel.cursor.move_down(root, self.metrics);
        root = self.insert(root, cursel, cut_text, allocator) catch return error.Stop;
        cursel.* = saved;
        try cursel.cursor.move_down(root, self.metrics);
        if (cursel.selection) |*sel_| {
            try sel_.begin.move_down(root, self.metrics);
            try sel_.end.move_down(root, self.metrics);
        }
        return root;
    }

    pub fn pull_down(self: *Self, ctx: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.with_cursels_mut_repeat(b.root, pull_cursel_down, b.allocator, ctx);
        try self.update_buf(root);
        self.clamp();
    }
    pub const pull_down_meta: Meta = .{ .description = "Pull line down", .arguments = &.{.integer} };

    fn dupe_cursel_up(self: *Self, root_: Buffer.Root, cursel: *CurSel, allocator: Allocator) error{Stop}!Buffer.Root {
        var root = root_;
        const sel: Selection = if (cursel.selection) |sel_| sel_ else Selection.line_from_cursor(cursel.cursor, root, self.metrics);
        cursel.disable_selection(root, self.metrics);
        var sfa = std.heap.stackFallback(4096, self.allocator);
        const text = copy_selection(root, sel, sfa.get(), self.metrics) catch return error.Stop;
        defer allocator.free(text);
        cursel.cursor = sel.begin;
        root = self.insert(root, cursel, text, allocator) catch return error.Stop;
        cursel.selection = .{ .begin = sel.begin, .end = sel.end };
        cursel.cursor = sel.begin;
        return root;
    }

    pub fn dupe_up(self: *Self, ctx: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.with_cursels_mut_repeat(b.root, dupe_cursel_up, b.allocator, ctx);
        try self.update_buf(root);
        self.clamp();
    }
    pub const dupe_up_meta: Meta = .{ .description = "Duplicate line or selection up/backwards", .arguments = &.{.integer} };

    fn dupe_cursel_down(self: *Self, root_: Buffer.Root, cursel: *CurSel, allocator: Allocator) error{Stop}!Buffer.Root {
        var root = root_;
        const sel: Selection = if (cursel.selection) |sel_| sel_ else Selection.line_from_cursor(cursel.cursor, root, self.metrics);
        cursel.disable_selection(root, self.metrics);
        var sfa = std.heap.stackFallback(4096, self.allocator);
        const text = copy_selection(root, sel, sfa.get(), self.metrics) catch return error.Stop;
        defer allocator.free(text);
        cursel.cursor = sel.end;
        root = self.insert(root, cursel, text, allocator) catch return error.Stop;
        cursel.selection = .{ .begin = sel.end, .end = cursel.cursor };
        return root;
    }

    pub fn dupe_down(self: *Self, ctx: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.with_cursels_mut_repeat(b.root, dupe_cursel_down, b.allocator, ctx);
        try self.update_buf(root);
        self.clamp();
    }
    pub const dupe_down_meta: Meta = .{ .description = "Duplicate line or selection down/forwards", .arguments = &.{.integer} };

    fn toggle_cursel_prefix(self: *Self, root_: Buffer.Root, cursel: *CurSel, allocator: Allocator) error{Stop}!Buffer.Root {
        var root = root_;
        const saved = cursel.*;
        const sel = cursel.expand_selection_to_line(root, self.metrics) catch return error.Stop;
        var sfa = std.heap.stackFallback(4096, self.allocator);
        const alloc = sfa.get();
        const text = copy_selection(root, sel.*, alloc, self.metrics) catch return error.Stop;
        defer allocator.free(text);
        root = try self.delete_selection(root, cursel, allocator);
        const new_text = text_manip.toggle_prefix_in_text(self.prefix, text, alloc) catch return error.Stop;
        root = self.insert(root, cursel, new_text, allocator) catch return error.Stop;
        cursel.* = saved;
        cursel.cursor.clamp_to_buffer(root, self.metrics);
        return root;
    }

    pub fn toggle_prefix(self: *Self, ctx: Context) Result {
        var prefix: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&prefix)}))
            return;
        @memcpy(self.prefix_buf[0..prefix.len], prefix);
        self.prefix = self.prefix_buf[0..prefix.len];
        const b = try self.buf_for_update();
        const root = try self.with_cursels_mut_once(b.root, toggle_cursel_prefix, b.allocator);
        try self.update_buf(root);
    }
    pub const toggle_prefix_meta: Meta = .{ .arguments = &.{.string} };

    pub fn toggle_comment(self: *Self, _: Context) Result {
        const comment = if (self.file_type) |file_type| file_type.comment else "#";
        return self.toggle_prefix(command.fmt(.{comment}));
    }
    pub const toggle_comment_meta: Meta = .{ .description = "Toggle comment" };

    fn indent_cursor(self: *Self, root: Buffer.Root, cursor: Cursor, allocator: Allocator) error{Stop}!Buffer.Root {
        const space = "                                ";
        var cursel: CurSel = .{};
        cursel.cursor = cursor;
        try move_cursor_begin(root, &cursel.cursor, self.metrics);
        switch (self.indent_mode) {
            .spaces, .auto => {
                const cols = self.indent_size - find_first_non_ws(root, cursel.cursor.row, self.metrics) % self.indent_size;
                return self.insert(root, &cursel, space[0..cols], allocator) catch return error.Stop;
            },
            .tabs => {
                return self.insert(root, &cursel, "\t", allocator) catch return error.Stop;
            },
        }
    }

    fn indent_cursel(self: *Self, root_: Buffer.Root, cursel: *CurSel, allocator: Allocator) error{Stop}!Buffer.Root {
        if (cursel.selection) |*sel_| {
            var root = root_;
            var sel = sel_.*;
            const sel_from_start = sel_.begin.col == 0;
            sel.normalize();
            while (sel.begin.row < sel.end.row) : (sel.begin.row += 1)
                root = try self.indent_cursor(root, sel.begin, allocator);
            if (sel.end.col > 0)
                root = try self.indent_cursor(root, sel.end, allocator);
            if (sel_from_start)
                sel_.begin.col = 0;
            return root;
        } else return try self.indent_cursor(root_, cursel.cursor, allocator);
    }

    pub fn indent(self: *Self, ctx: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.with_cursels_mut_repeat(b.root, indent_cursel, b.allocator, ctx);
        try self.update_buf(root);
    }
    pub const indent_meta: Meta = .{ .description = "Indent current line", .arguments = &.{.integer} };

    fn unindent_cursor(self: *Self, root: Buffer.Root, cursor: *Cursor, cursor_protect: ?*Cursor, allocator: Allocator) error{Stop}!Buffer.Root {
        var newroot = root;
        var cursel: CurSel = .{};
        cursel.cursor = cursor.*;
        const first = find_first_non_ws(root, cursel.cursor.row, self.metrics);
        if (first == 0) return root;
        const off = first % self.indent_size;
        const cols = if (off == 0) self.indent_size else off;
        const sel = cursel.enable_selection(root, self.metrics) catch return error.Stop;
        try sel.begin.move_to(root, sel.begin.row, first, self.metrics);
        try sel.end.move_to(root, sel.end.row, first - cols, self.metrics);
        var saved = false;
        if (cursor_protect) |cp| if (cp.row == cursor.row and cp.col < first and cp.col >= first - cols) {
            cp.col = first + 1;
            saved = true;
        };
        newroot = try self.delete_selection(root, &cursel, allocator);
        if (cursor_protect) |cp| if (saved) {
            try cp.move_to(root, cp.row, first - cols, self.metrics);
            cp.clamp_to_buffer(newroot, self.metrics);
        };
        return newroot;
    }

    fn unindent_cursel(self: *Self, root_: Buffer.Root, cursel: *CurSel, allocator: Allocator) error{Stop}!Buffer.Root {
        if (cursel.selection) |sel_| {
            var root = root_;
            var sel = sel_;
            sel.normalize();
            while (sel.begin.row < sel.end.row) : (sel.begin.row += 1)
                root = try self.unindent_cursor(root, &sel.begin, &cursel.cursor, allocator);
            if (sel.end.col > 0)
                root = try self.unindent_cursor(root, &sel.end, &cursel.cursor, allocator);
            return root;
        } else return self.unindent_cursor(root_, &cursel.cursor, &cursel.cursor, allocator);
    }

    fn restore_cursels(self: *Self) void {
        self.cursels.clearAndFree(self.allocator);
        self.cursels = self.cursels_saved.clone(self.allocator) catch return;
    }

    pub fn unindent(self: *Self, ctx: Context) Result {
        const b = try self.buf_for_update();
        errdefer self.restore_cursels();
        const previous_len = self.cursels.items.len;
        const root = try self.with_cursels_mut_repeat(b.root, unindent_cursel, b.allocator, ctx);
        if (self.cursels.items.len != previous_len)
            self.restore_cursels();
        try self.update_buf(root);
    }
    pub const unindent_meta: Meta = .{ .description = "Unindent current line", .arguments = &.{.integer} };

    pub fn move_scroll_up(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const_repeat(root, move_cursor_up, ctx) catch {};
        self.view.move_up() catch {};
        self.clamp();
    }
    pub const move_scroll_up_meta: Meta = .{ .description = "Move and scroll up", .arguments = &.{.integer} };

    pub fn move_scroll_down(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const_repeat(root, move_cursor_down, ctx) catch {};
        self.view.move_down(root) catch {};
        self.clamp();
    }
    pub const move_scroll_down_meta: Meta = .{ .description = "Move and scroll down", .arguments = &.{.integer} };

    pub fn move_scroll_left(self: *Self, _: Context) Result {
        self.view.move_left() catch {};
    }
    pub const move_scroll_left_meta: Meta = .{ .description = "Scroll left" };

    pub fn move_scroll_right(self: *Self, _: Context) Result {
        self.view.move_right() catch {};
    }
    pub const move_scroll_right_meta: Meta = .{ .description = "Scroll right" };

    pub fn move_scroll_page_up(self: *Self, _: Context) Result {
        if (self.screen_cursor(&self.get_primary().cursor)) |cursor| {
            const root = try self.buf_root();
            self.with_cursors_and_view_const(root, move_cursor_page_up, &self.view) catch {};
            const new_cursor_row = self.get_primary().cursor.row;
            self.update_scroll_dest_abs(if (cursor.row > new_cursor_row) 0 else new_cursor_row - cursor.row);
        } else {
            return self.move_page_up(.{});
        }
    }
    pub const move_scroll_page_up_meta: Meta = .{ .description = "Move and scroll page up" };

    pub fn move_scroll_page_down(self: *Self, _: Context) Result {
        if (self.screen_cursor(&self.get_primary().cursor)) |cursor| {
            const root = try self.buf_root();
            self.with_cursors_and_view_const(root, move_cursor_page_down, &self.view) catch {};
            const new_cursor_row = self.get_primary().cursor.row;
            self.update_scroll_dest_abs(if (cursor.row > new_cursor_row) 0 else new_cursor_row - cursor.row);
        } else {
            return self.move_page_down(.{});
        }
    }
    pub const move_scroll_page_down_meta: Meta = .{ .description = "Move and scroll page down" };

    pub fn move_scroll_half_page_up(self: *Self, _: Context) Result {
        if (self.screen_cursor(&self.get_primary().cursor)) |cursor| {
            const root = try self.buf_root();
            self.with_cursors_and_view_const(root, move_cursor_half_page_up, &self.view) catch {};
            const new_cursor_row = self.get_primary().cursor.row;
            self.update_scroll_dest_abs(if (cursor.row > new_cursor_row) 0 else new_cursor_row - cursor.row);
        } else {
            return self.move_half_page_up(.{});
        }
    }
    pub const move_scroll_half_page_up_meta: Meta = .{ .description = "Move and scroll half a page up" };

    pub fn move_scroll_half_page_up_vim(self: *Self, _: Context) Result {
        if (self.screen_cursor(&self.get_primary().cursor)) |cursor| {
            const root = try self.buf_root();
            self.with_cursors_and_view_const(root, move_cursor_half_page_up_vim, &self.view) catch {};
            const new_cursor_row = self.get_primary().cursor.row;
            self.update_scroll_dest_abs(if (cursor.row > new_cursor_row) 0 else new_cursor_row - cursor.row);
        } else {
            return self.move_half_page_up(.{});
        }
    }
    pub const move_scroll_half_page_up_vim_meta: Meta = .{ .description = "Move and scroll half a page up (vim)" };

    pub fn move_scroll_half_page_down(self: *Self, _: Context) Result {
        if (self.screen_cursor(&self.get_primary().cursor)) |cursor| {
            const root = try self.buf_root();
            self.with_cursors_and_view_const(root, move_cursor_half_page_down, &self.view) catch {};
            const new_cursor_row = self.get_primary().cursor.row;
            self.update_scroll_dest_abs(if (cursor.row > new_cursor_row) 0 else new_cursor_row - cursor.row);
        } else {
            return self.move_half_page_down(.{});
        }
    }
    pub const move_scroll_half_page_down_meta: Meta = .{ .description = "Move and scroll half a page down" };

    pub fn move_scroll_half_page_down_vim(self: *Self, _: Context) Result {
        if (self.screen_cursor(&self.get_primary().cursor)) |cursor| {
            const root = try self.buf_root();
            self.with_cursors_and_view_const(root, move_cursor_half_page_down_vim, &self.view) catch {};
            const new_cursor_row = self.get_primary().cursor.row;
            self.update_scroll_dest_abs(if (cursor.row > new_cursor_row) 0 else new_cursor_row - cursor.row);
        } else {
            return self.move_half_page_down(.{});
        }
    }
    pub const move_scroll_half_page_down_vim_meta: Meta = .{ .description = "Move and scroll half a page down (vim)" };

    pub fn smart_move_begin(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        try self.with_cursors_const_once(root, smart_move_cursor_begin);
        self.clamp();
    }
    pub const smart_move_begin_meta: Meta = .{ .description = "Move cursor to beginning of line (smart)" };

    pub fn move_begin(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        try self.with_cursors_const_once(root, move_cursor_begin);
        self.clamp();
    }
    pub const move_begin_meta: Meta = .{ .description = "Move cursor to beginning of line" };

    pub fn move_end(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        try self.with_cursors_const_once(root, move_cursor_end);
        self.clamp();
    }
    pub const move_end_meta: Meta = .{ .description = "Move cursor to end of line" };

    pub fn move_page_up(self: *Self, _: Context) Result {
        try self.send_editor_jump_source();
        const root = try self.buf_root();
        try self.with_cursors_and_view_const(root, move_cursor_page_up, &self.view);
        self.clamp();
    }
    pub const move_page_up_meta: Meta = .{ .description = "Move cursor page up" };

    pub fn move_page_down(self: *Self, _: Context) Result {
        try self.send_editor_jump_source();
        const root = try self.buf_root();
        try self.with_cursors_and_view_const(root, move_cursor_page_down, &self.view);
        self.clamp();
        try self.send_editor_jump_destination();
    }
    pub const move_page_down_meta: Meta = .{ .description = "Move cursor page down" };

    pub fn move_half_page_up(self: *Self, _: Context) Result {
        try self.send_editor_jump_source();
        const root = try self.buf_root();
        try self.with_cursors_and_view_const(root, move_cursor_page_up, &self.view);
        self.clamp();
    }
    pub const move_half_page_up_meta: Meta = .{ .description = "Move cursor half a page up" };

    pub fn move_half_page_down(self: *Self, _: Context) Result {
        try self.send_editor_jump_source();
        const root = try self.buf_root();
        try self.with_cursors_and_view_const(root, move_cursor_page_down, &self.view);
        self.clamp();
        try self.send_editor_jump_destination();
    }
    pub const move_half_page_down_meta: Meta = .{ .description = "Move cursor half a page down" };

    pub fn move_buffer_begin(self: *Self, _: Context) Result {
        try self.send_editor_jump_source();
        self.cancel_all_selections();
        self.get_primary().cursor.move_buffer_begin();
        self.clamp();
        try self.send_editor_jump_destination();
    }
    pub const move_buffer_begin_meta: Meta = .{ .description = "Move cursor to start of file" };

    pub fn move_buffer_end(self: *Self, _: Context) Result {
        try self.send_editor_jump_source();
        self.cancel_all_selections();
        const root = self.buf_root() catch return;
        self.get_primary().cursor.move_buffer_end(root, self.metrics);
        self.clamp();
        try self.send_editor_jump_destination();
    }
    pub const move_buffer_end_meta: Meta = .{ .description = "Move cursor to end of file" };

    pub fn cancel(self: *Self, _: Context) Result {
        self.cancel_all_selections();
        self.cancel_all_matches();
        @import("keybind").clear_integer_argument();
    }
    pub const cancel_meta: Meta = .{ .description = "Cancel current action" };

    pub fn enable_selection(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        _ = try self.get_primary().enable_selection(root, self.metrics);
    }
    pub const enable_selection_meta: Meta = .{ .description = "Enable selection" };

    pub fn select_line_vim(self: *Self, _: Context) Result {
        self.selection_mode = .line;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel|
            try self.select_line_around_cursor(cursel);
        self.collapse_cursors();

        self.clamp();
    }
    pub const select_line_vim_meta: Meta = .{ .description = "Select the line around the cursor (vim)" };

    pub fn select_up(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const_repeat(root, move_cursor_up, ctx);
        self.clamp();
    }
    pub const select_up_meta: Meta = .{ .description = "Select up", .arguments = &.{.integer} };

    pub fn select_down(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const_repeat(root, move_cursor_down, ctx);
        self.clamp();
    }
    pub const select_down_meta: Meta = .{ .description = "Select down", .arguments = &.{.integer} };

    pub fn select_scroll_up(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const_repeat(root, move_cursor_up, ctx);
        self.view.move_up() catch {};
        self.clamp();
    }
    pub const select_scroll_up_meta: Meta = .{ .description = "Select and scroll up", .arguments = &.{.integer} };

    pub fn select_scroll_down(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const_repeat(root, move_cursor_down, ctx);
        self.view.move_down(root) catch {};
        self.clamp();
    }
    pub const select_scroll_down_meta: Meta = .{ .description = "Select and scroll down", .arguments = &.{.integer} };

    pub fn select_left(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const_repeat(root, move_cursor_left, ctx);
        self.clamp();
    }
    pub const select_left_meta: Meta = .{ .description = "Select left", .arguments = &.{.integer} };

    pub fn select_right(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const_repeat(root, move_cursor_right, ctx);
        self.clamp();
    }
    pub const select_right_meta: Meta = .{ .description = "Select right", .arguments = &.{.integer} };

    pub fn select_word_left(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const_repeat(root, move_cursor_word_left, ctx);
        self.clamp();
    }
    pub const select_word_left_meta: Meta = .{ .description = "Select left by word", .arguments = &.{.integer} };

    pub fn select_word_left_vim(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const_repeat(root, move_cursor_word_left_vim, ctx);
        self.clamp();
    }
    pub const select_word_left_vim_meta: Meta = .{ .description = "Select left by word (vim)", .arguments = &.{.integer} };

    pub fn select_word_right(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const_repeat(root, move_cursor_word_right, ctx);
        self.clamp();
    }
    pub const select_word_right_meta: Meta = .{ .description = "Select right by word", .arguments = &.{.integer} };

    pub fn select_word_right_vim(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const_repeat(root, move_cursor_word_right_vim, ctx);
        self.clamp();
    }
    pub const select_word_right_vim_meta: Meta = .{ .description = "Select right by word (vim)", .arguments = &.{.integer} };

    pub fn select_word_right_end_vim(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const_repeat(root, move_cursor_word_right_end_vim, ctx);
        self.clamp();
    }
    pub const select_word_right_end_vim_meta: Meta = .{ .description = "Select right by end of word (vim)", .arguments = &.{.integer} };

    pub fn select_word_begin(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const_repeat(root, move_cursor_word_begin, ctx);
        self.clamp();
    }
    pub const select_word_begin_meta: Meta = .{ .description = "Select to beginning of word", .arguments = &.{.integer} };

    pub fn select_word_end(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const_repeat(root, move_cursor_word_end, ctx);
        self.clamp();
    }
    pub const select_word_end_meta: Meta = .{ .description = "Select to end of word", .arguments = &.{.integer} };

    pub fn select_to_char_left(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_selections_const_arg(root, move_cursor_to_char_left, ctx) catch {};
        self.clamp();
    }
    pub const select_to_char_left_meta: Meta = .{ .arguments = &.{.integer} };

    pub fn select_to_char_left_vim(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            if (cursel.selection) |*sel| try sel.begin.move_right(root, self.metrics);
        };
        self.with_selections_const_arg(root, move_cursor_to_char_left, ctx) catch {};
        self.clamp();
    }
    pub const select_to_char_left_vim_meta: Meta = .{ .arguments = &.{.integer} };

    pub fn select_till_char_left_vim(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            if (cursel.selection) |*sel| try sel.begin.move_right(root, self.metrics);
        };
        self.with_selections_const_arg(root, move_cursor_till_char_left, ctx) catch {};
        self.clamp();
    }
    pub const select_till_char_left_vim_meta: Meta = .{ .arguments = &.{.integer} };

    pub fn select_to_char_right(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_selections_const_arg(root, move_cursor_to_char_right, ctx) catch {};
        self.clamp();
    }
    pub const select_to_char_right_meta: Meta = .{ .arguments = &.{.integer} };

    pub fn select_till_char_right(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_selections_const_arg(root, move_cursor_till_char_right, ctx) catch {};
        self.clamp();
    }
    pub const select_till_char_right_meta: Meta = .{ .arguments = &.{.integer} };

    pub fn select_begin(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const_repeat(root, move_cursor_begin, ctx);
        self.clamp();
    }
    pub const select_begin_meta: Meta = .{ .description = "Select to beginning of line", .arguments = &.{.integer} };

    pub fn smart_select_begin(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const_repeat(root, smart_move_cursor_begin, ctx);
        self.clamp();
    }
    pub const smart_select_begin_meta: Meta = .{ .description = "Select to beginning of line (smart)", .arguments = &.{.integer} };

    pub fn select_end(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const_repeat(root, move_cursor_end, ctx);
        self.clamp();
    }
    pub const select_end_meta: Meta = .{ .description = "Select to end of line", .arguments = &.{.integer} };

    pub fn select_buffer_begin(self: *Self, ctx: Context) Result {
        try self.send_editor_jump_source();
        const root = try self.buf_root();
        try self.with_selections_const_repeat(root, move_cursor_buffer_begin, ctx);
        self.clamp();
        try self.send_editor_jump_destination();
    }
    pub const select_buffer_begin_meta: Meta = .{ .description = "Select to start of file", .arguments = &.{.integer} };

    pub fn select_buffer_end(self: *Self, ctx: Context) Result {
        try self.send_editor_jump_source();
        const root = try self.buf_root();
        try self.with_selections_const_repeat(root, move_cursor_buffer_end, ctx);
        self.clamp();
        try self.send_editor_jump_destination();
    }
    pub const select_buffer_end_meta: Meta = .{ .description = "Select to end of file", .arguments = &.{.integer} };

    pub fn select_page_up(self: *Self, _: Context) Result {
        try self.send_editor_jump_source();
        const root = try self.buf_root();
        try self.with_selections_and_view_const(root, move_cursor_page_up, &self.view);
        self.clamp();
        try self.send_editor_jump_destination();
    }
    pub const select_page_up_meta: Meta = .{ .description = "Select page up" };

    pub fn select_page_down(self: *Self, _: Context) Result {
        try self.send_editor_jump_source();
        const root = try self.buf_root();
        try self.with_selections_and_view_const(root, move_cursor_page_down, &self.view);
        self.clamp();
        try self.send_editor_jump_destination();
    }
    pub const select_page_down_meta: Meta = .{ .description = "Select page down" };

    pub fn select_half_page_up(self: *Self, _: Context) Result {
        try self.send_editor_jump_source();
        const root = try self.buf_root();
        try self.with_selections_and_view_const(root, move_cursor_half_page_up, &self.view);
        self.clamp();
        try self.send_editor_jump_destination();
    }
    pub const select_half_page_up_meta: Meta = .{ .description = "Select half a page up" };

    pub fn select_half_page_down(self: *Self, _: Context) Result {
        try self.send_editor_jump_source();
        const root = try self.buf_root();
        try self.with_selections_and_view_const(root, move_cursor_half_page_down, &self.view);
        self.clamp();
        try self.send_editor_jump_destination();
    }
    pub const select_half_page_down_meta: Meta = .{ .description = "Select half a page down" };

    pub fn select_all(self: *Self, _: Context) Result {
        try self.send_editor_jump_source();
        self.cancel_all_selections();
        const primary = self.get_primary();
        const root = try self.buf_root();
        const sel = try primary.enable_selection(root, self.metrics);
        try expand_selection_to_all(root, sel, self.metrics);
        primary.cursor = sel.end;
        self.clamp();
        try self.send_editor_jump_destination();
    }
    pub const select_all_meta: Meta = .{ .description = "Select all" };

    fn select_word_at_cursor(self: *Self, cursel: *CurSel) !*Selection {
        const root = try self.buf_root();
        const sel = try cursel.enable_selection(root, self.metrics);
        defer cursel.check_selection(root, self.metrics);
        sel.normalize();
        try move_cursor_word_begin(root, &sel.begin, self.metrics);
        move_cursor_word_end(root, &sel.end, self.metrics) catch {};
        cursel.cursor = sel.end;
        return sel;
    }

    fn select_line_at_cursor(self: *Self, cursel: *CurSel) !void {
        const root = try self.buf_root();
        const sel = try cursel.enable_selection(root, self.metrics);
        sel.normalize();
        try move_cursor_begin(root, &sel.begin, self.metrics);
        move_cursor_end(root, &sel.end, self.metrics) catch {};
        cursel.cursor = sel.end;
    }

    pub fn select_line_around_cursor(self: *Self, cursel: *CurSel) !void {
        const root = try self.buf_root();
        const sel = try cursel.enable_selection(root, self.metrics);
        sel.normalize();
        try move_cursor_begin(root, &sel.begin, self.metrics);
        try move_cursor_end(root, &sel.end, self.metrics);
    }

    fn selection_reverse(_: Buffer.Root, cursel: *CurSel) !void {
        if (cursel.selection) |*sel| {
            sel.reverse();
            cursel.cursor = sel.end;
        }
    }

    pub fn selections_reverse(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        try self.with_cursels_const(root, selection_reverse);
        self.clamp();
    }
    pub const selections_reverse_meta: Meta = .{ .description = "Reverse selection" };

    fn node_at_selection(self: *Self, sel: Selection, root: Buffer.Root, metrics: Buffer.Metrics) error{Stop}!syntax.Node {
        const syn = self.syntax orelse return error.Stop;
        const node = try syn.node_at_point_range(.{
            .start_point = .{
                .row = @intCast(sel.begin.row),
                .column = @intCast(try root.get_line_width_to_pos(sel.begin.row, sel.begin.col, metrics)),
            },
            .end_point = .{
                .row = @intCast(sel.end.row),
                .column = @intCast(try root.get_line_width_to_pos(sel.end.row, sel.end.col, metrics)),
            },
            .start_byte = 0,
            .end_byte = 0,
        });
        if (node.isNull()) return error.Stop;
        return node;
    }

    fn select_node_at_cursor(self: *Self, root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
        cursel.disable_selection(root, self.metrics);
        const sel = (try cursel.enable_selection(root, self.metrics)).*;
        return cursel.select_node(try self.node_at_selection(sel, root, metrics), root, metrics);
    }

    fn expand_selection_to_parent_node(self: *Self, root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
        const sel = (try cursel.enable_selection(root, metrics)).*;
        const node = try self.node_at_selection(sel, root, metrics);
        if (node.isNull()) return error.Stop;
        const parent = node.getParent();
        if (parent.isNull()) return error.Stop;
        return cursel.select_node(parent, root, metrics);
    }

    pub fn expand_selection(self: *Self, _: Context) Result {
        try self.send_editor_jump_source();
        const root = try self.buf_root();
        const cursel = self.get_primary();
        cursel.check_selection(root, self.metrics);
        try if (cursel.selection) |_|
            self.expand_selection_to_parent_node(root, cursel, self.metrics)
        else
            self.select_node_at_cursor(root, cursel, self.metrics);
        self.clamp();
        try self.send_editor_jump_destination();
    }
    pub const expand_selection_meta: Meta = .{ .description = "Expand selection to AST parent node" };

    fn shrink_selection_to_child_node(self: *Self, root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
        const sel = (try cursel.enable_selection(root, metrics)).*;
        const node = try self.node_at_selection(sel, root, metrics);
        if (node.isNull() or node.getChildCount() == 0) return error.Stop;
        const child = node.getChild(0);
        if (child.isNull()) return error.Stop;
        return cursel.select_node(child, root, metrics);
    }

    fn shrink_selection_to_named_child_node(self: *Self, root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
        const sel = (try cursel.enable_selection(root, metrics)).*;
        const node = try self.node_at_selection(sel, root, metrics);
        if (node.isNull() or node.getNamedChildCount() == 0) return error.Stop;
        const child = node.getNamedChild(0);
        if (child.isNull()) return error.Stop;
        return cursel.select_node(child, root, metrics);
    }

    pub fn shrink_selection(self: *Self, ctx: Context) Result {
        var unnamed: bool = false;
        _ = ctx.args.match(.{tp.extract(&unnamed)}) catch false;
        try self.send_editor_jump_source();
        const root = try self.buf_root();
        const cursel = self.get_primary();
        cursel.check_selection(root, self.metrics);
        if (cursel.selection) |_|
            try if (unnamed)
                self.shrink_selection_to_child_node(root, cursel, self.metrics)
            else
                self.shrink_selection_to_named_child_node(root, cursel, self.metrics);
        self.clamp();
        try self.send_editor_jump_destination();
    }
    pub const shrink_selection_meta: Meta = .{ .description = "Shrink selection to first AST child node" };

    fn select_next_sibling_node(self: *Self, root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
        const sel = (try cursel.enable_selection(root, metrics)).*;
        const node = try self.node_at_selection(sel, root, metrics);
        if (node.isNull()) return error.Stop;
        const sibling = syntax.Node.externs.ts_node_next_sibling(node);
        if (sibling.isNull()) return error.Stop;
        return cursel.select_node(sibling, root, metrics);
    }

    fn select_next_named_sibling_node(self: *Self, root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
        const sel = (try cursel.enable_selection(root, metrics)).*;
        const node = try self.node_at_selection(sel, root, metrics);
        if (node.isNull()) return error.Stop;
        const sibling = syntax.Node.externs.ts_node_next_named_sibling(node);
        if (sibling.isNull()) return error.Stop;
        return cursel.select_node(sibling, root, metrics);
    }

    pub fn select_next_sibling(self: *Self, ctx: Context) Result {
        var unnamed: bool = false;
        _ = ctx.args.match(.{tp.extract(&unnamed)}) catch false;
        try self.send_editor_jump_source();
        const root = try self.buf_root();
        const cursel = self.get_primary();
        cursel.check_selection(root, self.metrics);
        if (cursel.selection) |_|
            try if (unnamed)
                self.select_next_sibling_node(root, cursel, self.metrics)
            else
                self.select_next_named_sibling_node(root, cursel, self.metrics);
        self.clamp();
        try self.send_editor_jump_destination();
    }
    pub const select_next_sibling_meta: Meta = .{ .description = "Move selection to next AST sibling node" };

    fn select_prev_sibling_node(self: *Self, root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
        const sel = (try cursel.enable_selection(root, metrics)).*;
        const node = try self.node_at_selection(sel, root, metrics);
        if (node.isNull()) return error.Stop;
        const sibling = syntax.Node.externs.ts_node_prev_sibling(node);
        if (sibling.isNull()) return error.Stop;
        return cursel.select_node(sibling, root, metrics);
    }

    fn select_prev_named_sibling_node(self: *Self, root: Buffer.Root, cursel: *CurSel, metrics: Buffer.Metrics) !void {
        const sel = (try cursel.enable_selection(root, metrics)).*;
        const node = try self.node_at_selection(sel, root, metrics);
        if (node.isNull()) return error.Stop;
        const sibling = syntax.Node.externs.ts_node_prev_named_sibling(node);
        if (sibling.isNull()) return error.Stop;
        return cursel.select_node(sibling, root, metrics);
    }

    pub fn select_prev_sibling(self: *Self, ctx: Context) Result {
        var unnamed: bool = false;
        _ = ctx.args.match(.{tp.extract(&unnamed)}) catch false;
        try self.send_editor_jump_source();
        const root = try self.buf_root();
        const cursel = self.get_primary();
        cursel.check_selection(root, self.metrics);
        if (cursel.selection) |_|
            try if (unnamed)
                self.select_prev_sibling_node(root, cursel, self.metrics)
            else
                self.select_prev_named_sibling_node(root, cursel, self.metrics);
        self.clamp();
        try self.send_editor_jump_destination();
    }
    pub const select_prev_sibling_meta: Meta = .{ .description = "Move selection to previous AST sibling node" };

    pub fn insert_chars(self: *Self, ctx: Context) Result {
        var chars: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&chars)}))
            return error.InvalidInsertCharsArgument;
        const b = try self.buf_for_update();
        var root = b.root;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            root = try self.insert(root, cursel, chars, b.allocator);
        };
        try self.update_buf(root);
        self.clamp();
    }
    pub const insert_chars_meta: Meta = .{ .arguments = &.{.string} };

    pub fn insert_line(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        var root = b.root;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            root = try self.insert(root, cursel, "\n", b.allocator);
        };
        try self.update_buf(root);
        self.clamp();
    }
    pub const insert_line_meta: Meta = .{ .description = "Insert line" };

    fn generate_leading_ws(self: *Self, writer: anytype, leading_ws: usize) !void {
        return switch (self.indent_mode) {
            .spaces, .auto => generate_leading_spaces(writer, leading_ws),
            .tabs => generate_leading_tabs(writer, leading_ws, self.tab_width),
        };
    }

    fn generate_leading_spaces(writer: anytype, leading_ws: usize) !void {
        var width = leading_ws;
        while (width > 0) : (width -= 1)
            try writer.writeByte(' ');
    }

    fn generate_leading_tabs(writer: anytype, leading_ws: usize, tab_width: usize) !void {
        var width = leading_ws;
        while (width > 0) if (width >= tab_width) {
            width -= tab_width;
            try writer.writeByte('\t');
        } else {
            width -= 1;
            try writer.writeByte(' ');
        };
    }

    fn cursel_smart_insert_line(self: *Self, root: Buffer.Root, cursel: *CurSel, b_allocator: std.mem.Allocator) !Buffer.Root {
        const row = cursel.cursor.row;
        const leading_ws = @min(find_first_non_ws(root, row, self.metrics), cursel.cursor.col);
        var sfa = std.heap.stackFallback(512, self.allocator);
        const allocator = sfa.get();
        var stream = std.ArrayListUnmanaged(u8).empty;
        defer stream.deinit(allocator);
        var writer = stream.writer(allocator);
        _ = try writer.write("\n");
        try self.generate_leading_ws(&writer, leading_ws);
        var root_ = try self.insert(root, cursel, stream.items, b_allocator);
        root_ = self.collapse_trailing_ws_line(root_, row, b_allocator);
        const leading_ws_ = find_first_non_ws(root_, cursel.cursor.row, self.metrics);
        if (leading_ws_ > leading_ws and leading_ws_ > cursel.cursor.col) {
            const sel = try cursel.enable_selection(root_, self.metrics);
            sel.* = .{
                .begin = .{ .row = cursel.cursor.row, .col = cursel.cursor.col },
                .end = .{ .row = cursel.cursor.row, .col = leading_ws_ },
            };
            root_ = self.delete_selection(root_, cursel, b_allocator) catch root_;
        }
        return root_;
    }

    pub fn smart_insert_line(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        var root = b.root;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            var indent_extra = true;
            const smart_brace_indent = blk: {
                var sel = Selection.from_cursor(&cursel.cursor);
                move_cursor_left(root, &sel.begin, self.metrics) catch break :blk false;
                const egc_left, _, _ = sel.end.egc_at(root, self.metrics) catch break :blk false;
                const egc_right, _, _ = sel.begin.egc_at(root, self.metrics) catch break :blk false;
                if (std.mem.eql(u8, egc_right, "[") and std.mem.eql(u8, egc_left, "]")) {
                    indent_extra = false;
                    break :blk true;
                }
                break :blk (std.mem.eql(u8, egc_right, "{") and std.mem.eql(u8, egc_left, "}")) or
                    (std.mem.eql(u8, egc_right, "(") and std.mem.eql(u8, egc_left, ")"));
            };

            root = try self.cursel_smart_insert_line(root, cursel, b.allocator);

            if (smart_brace_indent) {
                const cursor = cursel.cursor;
                root = try self.cursel_smart_insert_line(root, cursel, b.allocator);
                cursel.cursor = cursor;
                if (indent_extra)
                    root = try self.indent_cursel(root, cursel, b.allocator);
            }
        };
        try self.update_buf(root);
        self.clamp();
    }
    pub const smart_insert_line_meta: Meta = .{ .description = "Insert line (smart)" };

    pub fn insert_line_before(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        var root = b.root;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            try move_cursor_begin(root, &cursel.cursor, self.metrics);
            root = try self.insert(root, cursel, "\n", b.allocator);
            try move_cursor_left(root, &cursel.cursor, self.metrics);
        };
        try self.update_buf(root);
        self.clamp();
    }
    pub const insert_line_before_meta: Meta = .{ .description = "Insert line before" };

    pub fn smart_insert_line_before(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        var root = b.root;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            const leading_ws = @min(find_first_non_ws(root, cursel.cursor.row, self.metrics), cursel.cursor.col);
            try move_cursor_begin(root, &cursel.cursor, self.metrics);
            root = try self.insert(root, cursel, "\n", b.allocator);
            const row = cursel.cursor.row;
            try move_cursor_left(root, &cursel.cursor, self.metrics);
            var sfa = std.heap.stackFallback(512, self.allocator);
            const allocator = sfa.get();
            var stream = std.ArrayListUnmanaged(u8).empty;
            defer stream.deinit(allocator);
            var writer = stream.writer(self.allocator);
            try self.generate_leading_ws(&writer, leading_ws);
            if (stream.items.len > 0)
                root = try self.insert(root, cursel, stream.items, b.allocator);
            root = self.collapse_trailing_ws_line(root, row, b.allocator);
        };
        try self.update_buf(root);
        self.clamp();
    }
    pub const smart_insert_line_before_meta: Meta = .{ .description = "Insert line before (smart)" };

    pub fn insert_line_after(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        var root = b.root;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            try move_cursor_end(root, &cursel.cursor, self.metrics);
            root = try self.insert(root, cursel, "\n", b.allocator);
        };
        try self.update_buf(root);
        self.clamp();
    }
    pub const insert_line_after_meta: Meta = .{ .description = "Insert line after" };

    pub fn smart_insert_line_after(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        var root = b.root;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            const leading_ws = @min(find_first_non_ws(root, cursel.cursor.row, self.metrics), cursel.cursor.col);
            const row = cursel.cursor.row;
            try move_cursor_end(root, &cursel.cursor, self.metrics);
            var sfa = std.heap.stackFallback(512, self.allocator);
            const allocator = sfa.get();
            var stream = std.ArrayListUnmanaged(u8).empty;
            defer stream.deinit(allocator);
            var writer = stream.writer(allocator);
            _ = try writer.write("\n");
            try self.generate_leading_ws(&writer, leading_ws);
            if (stream.items.len > 0)
                root = try self.insert(root, cursel, stream.items, b.allocator);
            root = self.collapse_trailing_ws_line(root, row, b.allocator);
        };
        try self.update_buf(root);
        self.clamp();
    }
    pub const smart_insert_line_after_meta: Meta = .{ .description = "Insert line after (smart)" };

    pub fn smart_buffer_append(self: *Self, ctx: Context) Result {
        var chars: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&chars)}))
            return error.InvalidInsertCharsArgument;
        const b = try self.buf_for_update();
        var root = b.root;
        var cursel: CurSel = .{};
        cursel.cursor.move_buffer_end(root, self.metrics);
        root = try self.insert(root, &cursel, chars, b.allocator);
        try self.update_buf(root);
        self.clamp();
    }
    pub const smart_buffer_append_meta: Meta = .{ .arguments = &.{.string} };

    pub fn smart_insert_pair(self: *Self, ctx: Context) Result {
        var chars_left: []const u8 = undefined;
        var chars_right: []const u8 = undefined;
        if (!try ctx.args.match(.{ tp.extract(&chars_left), tp.extract(&chars_right) }))
            return error.InvalidSmartInsertPairArguments;
        const b = try self.buf_for_update();
        var move: enum { left, right } = .left;
        var root = b.root;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            if (cursel.selection) |*sel| {
                const chars_begin, const chars_end = if (sel.is_reversed())
                    .{ chars_right, chars_left }
                else
                    .{ chars_left, chars_right };
                var begin: CurSel = .{ .cursor = sel.begin };
                root = try self.insert(root, &begin, chars_begin, b.allocator);
                var end: CurSel = .{ .cursor = sel.end };
                root = try self.insert(root, &end, chars_end, b.allocator);
                sel.end.move_left(root, self.metrics) catch {};
            } else blk: {
                const egc, _, _ = cursel.cursor.egc_at(root, self.metrics) catch {
                    root = try self.insert(root, cursel, chars_left, b.allocator);
                    root = try self.insert(root, cursel, chars_right, b.allocator);
                    break :blk;
                };
                if (std.mem.eql(u8, egc, chars_left)) {
                    move = .right;
                } else {
                    root = try self.insert(root, cursel, chars_left, b.allocator);
                    root = try self.insert(root, cursel, chars_right, b.allocator);
                }
            }
            switch (move) {
                .left => cursel.cursor.move_left(root, self.metrics) catch {},
                .right => cursel.cursor.move_right(root, self.metrics) catch {},
            }
        };
        try self.update_buf(root);
        self.clamp();
    }
    pub const smart_insert_pair_meta: Meta = .{ .arguments = &.{ .string, .string } };

    pub fn smart_insert_pair_close(self: *Self, ctx: Context) Result {
        var chars_left: []const u8 = undefined;
        var chars_right: []const u8 = undefined;
        if (!try ctx.args.match(.{ tp.extract(&chars_left), tp.extract(&chars_right) }))
            return error.InvalidSmartInsertPairArguments;
        const b = try self.buf_for_update();
        var root = b.root;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            if (cursel.selection) |*sel| {
                const chars_begin, const chars_end = if (sel.is_reversed())
                    .{ chars_right, chars_left }
                else
                    .{ chars_left, chars_right };
                var begin: CurSel = .{ .cursor = sel.begin };
                root = try self.insert(root, &begin, chars_begin, b.allocator);
                var end: CurSel = .{ .cursor = sel.end };
                root = try self.insert(root, &end, chars_end, b.allocator);
                cursel.disable_selection(root, self.metrics);
            } else blk: {
                const egc, _, _ = cursel.cursor.egc_at(root, self.metrics) catch {
                    root = try self.insert(root, cursel, chars_right, b.allocator);
                    break :blk;
                };
                if (std.mem.eql(u8, egc, chars_right)) {
                    cursel.cursor.move_right(root, self.metrics) catch {
                        root = try self.insert(root, cursel, chars_right, b.allocator);
                    };
                } else {
                    root = try self.insert(root, cursel, chars_right, b.allocator);
                }
            }
        };
        try self.update_buf(root);
        self.clamp();
    }
    pub const smart_insert_pair_close_meta: Meta = .{ .arguments = &.{ .string, .string } };

    pub fn enable_fast_scroll(self: *Self, _: Context) Result {
        self.fast_scroll = true;
    }
    pub const enable_fast_scroll_meta: Meta = .{ .description = "Enable fast scroll mode" };

    pub fn disable_fast_scroll(self: *Self, _: Context) Result {
        self.fast_scroll = false;
    }
    pub const disable_fast_scroll_meta: Meta = .{};

    pub fn enable_jump_mode(self: *Self, _: Context) Result {
        self.jump_mode = true;
        tui.rdr().request_mouse_cursor_pointer(true);
    }
    pub const enable_jump_mode_meta: Meta = .{ .description = "Enable jump/hover mode" };

    pub fn disable_jump_mode(self: *Self, _: Context) Result {
        self.jump_mode = false;
        tui.rdr().request_mouse_cursor_text(true);
    }
    pub const disable_jump_mode_meta: Meta = .{};

    fn update_syntax(self: *Self) !void {
        const root = try self.buf_root();
        const eol_mode = try self.buf_eol_mode();
        if (!self.syntax_refresh_full and self.syntax_last_rendered_root == root)
            return;
        var kind: enum { full, incremental, none } = .none;
        var edit_count: usize = 0;
        const start_time = std.time.milliTimestamp();
        if (self.syntax) |syn| {
            if (self.syntax_no_render) {
                const frame = tracy.initZone(@src(), .{ .name = "editor reset syntax" });
                defer frame.deinit();
                syn.reset();
                self.syntax_last_rendered_root = null;
                self.syntax_refresh_full = false;
                return;
            }
            if (!self.syntax_incremental_reparse)
                self.syntax_refresh_full = true;
            if (self.syntax_last_rendered_root == null)
                self.syntax_refresh_full = true;
            var content_ = std.ArrayListUnmanaged(u8).empty;
            defer content_.deinit(self.allocator);
            {
                const frame = tracy.initZone(@src(), .{ .name = "editor store syntax" });
                defer frame.deinit();
                try root.store(content_.writer(self.allocator), eol_mode);
            }
            const content = try content_.toOwnedSliceSentinel(self.allocator, 0);
            defer self.allocator.free(content);
            if (self.syntax_refresh_full) {
                {
                    const frame = tracy.initZone(@src(), .{ .name = "editor reset syntax" });
                    defer frame.deinit();
                    syn.reset();
                }
                {
                    const frame = tracy.initZone(@src(), .{ .name = "editor refresh_full syntax" });
                    defer frame.deinit();
                    try syn.refresh_full(content);
                }
                kind = .full;
                self.syntax_last_rendered_root = root;
                self.syntax_refresh_full = false;
            } else {
                if (self.syntax_last_rendered_root) |root_src| {
                    self.syntax_last_rendered_root = null;
                    var old_content = std.ArrayListUnmanaged(u8).empty;
                    defer old_content.deinit(self.allocator);
                    {
                        const frame = tracy.initZone(@src(), .{ .name = "editor store syntax" });
                        defer frame.deinit();
                        try root_src.store(old_content.writer(self.allocator), eol_mode);
                    }
                    {
                        const frame = tracy.initZone(@src(), .{ .name = "editor diff syntax" });
                        defer frame.deinit();
                        const diff = @import("diff");
                        const edits = try diff.diff(self.allocator, content, old_content.items);
                        defer self.allocator.free(edits);
                        for (edits) |edit|
                            syntax_process_edit(syn, edit);
                        edit_count = edits.len;
                    }
                    {
                        const frame = tracy.initZone(@src(), .{ .name = "editor refresh syntax" });
                        defer frame.deinit();
                        try syn.refresh_from_string(content);
                        const error_count = syn.count_error_nodes();
                        if (error_count >= syntax_full_reparse_error_threshold) {
                            self.logger.print("incremental syntax update has {d} errors -> full reparse", .{error_count});
                            self.syntax_refresh_full = true;
                        }
                    }
                    self.syntax_last_rendered_root = root;
                    kind = .incremental;
                }
            }
        } else {
            var content = std.ArrayListUnmanaged(u8).empty;
            defer content.deinit(self.allocator);
            try root.store(content.writer(self.allocator), eol_mode);
            self.syntax = file_type_config.create_syntax_guess_file_type(self.allocator, content.items, self.file_path, tui.query_cache()) catch |e| switch (e) {
                error.NotFound => null,
                else => return e,
            };
            if (!self.syntax_no_render) {
                if (self.syntax) |syn| {
                    const frame = tracy.initZone(@src(), .{ .name = "editor parse syntax" });
                    defer frame.deinit();
                    try syn.refresh_full(content.items);
                    self.syntax_last_rendered_root = root;
                }
            }
        }
        const end_time = std.time.milliTimestamp();
        if (kind == .full or kind == .incremental) {
            const update_time = end_time - start_time;
            self.syntax_incremental_reparse = end_time - start_time > syntax_full_reparse_time_limit;
            if (self.syntax_report_timing)
                self.logger.print("syntax update {s} time: {d}ms ({d} edits)", .{ @tagName(kind), update_time, edit_count });
        }
    }

    fn syntax_process_edit(syn: *syntax, edit: @import("diff").Diff) void {
        switch (edit.kind) {
            .insert => syn.edit(.{
                .start_byte = @intCast(edit.start),
                .old_end_byte = @intCast(edit.start),
                .new_end_byte = @intCast(edit.start + edit.bytes.len),
                .start_point = .{ .row = 0, .column = 0 },
                .old_end_point = .{ .row = 0, .column = 0 },
                .new_end_point = .{ .row = 0, .column = 0 },
            }),
            .delete => syn.edit(.{
                .start_byte = @intCast(edit.start),
                .old_end_byte = @intCast(edit.start + edit.bytes.len),
                .new_end_byte = @intCast(edit.start),
                .start_point = .{ .row = 0, .column = 0 },
                .old_end_point = .{ .row = 0, .column = 0 },
                .new_end_point = .{ .row = 0, .column = 0 },
            }),
        }
    }

    fn reset_syntax(self: *Self) void {
        if (self.syntax) |_| self.syntax_refresh_full = true;
    }

    pub fn dump_current_line(self: *Self, _: Context) Result {
        const root = self.buf_root() catch return;
        const primary = self.get_primary();
        const tree = root.debug_render_chunks(self.allocator, primary.cursor.row, self.metrics) catch |e|
            return self.logger.print("line {d}: {any}", .{ primary.cursor.row, e });
        defer self.allocator.free(tree);
        self.logger.print("line {d}:{s}", .{ primary.cursor.row, std.fmt.fmtSliceEscapeLower(tree) });
    }
    pub const dump_current_line_meta: Meta = .{ .description = "Debug: dump current line" };

    pub fn dump_current_line_tree(self: *Self, _: Context) Result {
        const root = self.buf_root() catch return;
        const primary = self.get_primary();
        const tree = root.debug_line_render_tree(self.allocator, primary.cursor.row) catch |e|
            return self.logger.print("line {d} ast: {any}", .{ primary.cursor.row, e });
        defer self.allocator.free(tree);
        self.logger.print("line {d} ast:{s}", .{ primary.cursor.row, std.fmt.fmtSliceEscapeLower(tree) });
    }
    pub const dump_current_line_tree_meta: Meta = .{ .description = "Debug: dump current line (tree)" };

    pub fn undo(self: *Self, _: Context) Result {
        try self.restore_undo();
        self.clamp();
    }
    pub const undo_meta: Meta = .{ .description = "Undo" };

    pub fn redo(self: *Self, _: Context) Result {
        try self.restore_redo();
        self.clamp();
    }
    pub const redo_meta: Meta = .{ .description = "Redo" };

    pub fn open_buffer_from_file(self: *Self, ctx: Context) Result {
        const frame = tracy.initZone(@src(), .{ .name = "open_buffer_from_file" });
        defer frame.deinit();
        var file_path: []const u8 = undefined;
        if (ctx.args.match(.{tp.extract(&file_path)}) catch false) {
            try self.open(file_path);
            if (tui.config().follow_cursor_on_buffer_switch)
                self.clamp();
        } else return error.InvalidOpenBufferFromFileArgument;
    }
    pub const open_buffer_from_file_meta: Meta = .{ .arguments = &.{.string} };

    pub fn open_scratch_buffer(self: *Self, ctx: Context) Result {
        var file_path: []const u8 = undefined;
        var content: []const u8 = undefined;
        var file_type: []const u8 = undefined;
        if (ctx.args.match(.{ tp.extract(&file_path), tp.extract(&content), tp.extract(&file_type) }) catch false) {
            try self.open_scratch(file_path, content, file_type);
            self.clamp();
        } else if (ctx.args.match(.{ tp.extract(&file_path), tp.extract(&content) }) catch false) {
            try self.open_scratch(file_path, content, null);
            self.clamp();
        } else if (ctx.args.match(.{tp.extract(&file_path)}) catch false) {
            try self.open_scratch(file_path, "", null);
            self.clamp();
        } else {
            try self.open_scratch("*scratch*", "", null);
            self.clamp();
        }
    }
    pub const open_scratch_buffer_meta: Meta = .{ .arguments = &.{ .string, .string } };

    pub fn reload_file(self: *Self, _: Context) Result {
        if (self.buffer) |buffer| try buffer.refresh_from_file();
    }
    pub const reload_file_meta: Meta = .{ .description = "Reload file" };

    pub const SaveOption = enum { default, format, no_format };

    pub fn toggle_auto_save(self: *Self, _: Context) Result {
        self.enable_auto_save = !self.enable_auto_save;
    }
    pub const toggle_auto_save_meta: Meta = .{ .description = "Toggle auto save" };

    pub fn toggle_format_on_save(self: *Self, _: Context) Result {
        self.enable_format_on_save = !self.enable_format_on_save;
    }
    pub const toggle_format_on_save_meta: Meta = .{ .description = "Toggle format on save" };

    pub fn save_file(self: *Self, ctx: Context) Result {
        var option: SaveOption = .default;
        var then = false;
        var cmd: []const u8 = undefined;
        var args: []const u8 = undefined;
        if (ctx.args.match(.{ tp.extract(&option), "then", .{ tp.extract(&cmd), tp.extract_cbor(&args) } }) catch false) {
            then = true;
        } else if (ctx.args.match(.{ "then", .{ tp.extract(&cmd), tp.extract_cbor(&args) } }) catch false) {
            then = true;
        } else {
            _ = ctx.args.match(.{tp.extract(&option)}) catch false;
        }

        if ((option == .default and self.enable_format_on_save) or option == .format) if (self.get_formatter()) |_| {
            self.need_save_after_filter = .{ .then = if (then) .{ .cmd = cmd, .args = args } else null };
            const primary = self.get_primary();
            const sel = primary.selection;
            primary.selection = null;
            defer primary.selection = sel;
            try self.format(.{});
            return;
        };
        try self.save();
        if (then)
            return command.executeName(cmd, .{ .args = .{ .buf = args } });
    }
    pub const save_file_meta: Meta = .{ .description = "Save file" };

    pub fn save_file_with_formatting(self: *Self, _: Context) Result {
        return self.save_file(Context.fmt(.{"format"}));
    }
    pub const save_file_with_formatting_meta: Meta = .{ .description = "Save file with formatting" };

    pub fn save_file_without_formatting(self: *Self, _: Context) Result {
        return self.save_file(Context.fmt(.{"no_format"}));
    }
    pub const save_file_without_formatting_meta: Meta = .{ .description = "Save file without formatting" };

    pub fn close_file(self: *Self, _: Context) Result {
        const buffer_ = self.buffer;
        if (buffer_) |buffer| if (buffer.is_dirty())
            return tp.exit("unsaved changes");
        try self.close();
        if (buffer_) |buffer|
            self.buffer_manager.close_buffer(buffer);
    }
    pub const close_file_meta: Meta = .{ .description = "Close file" };

    pub fn close_file_without_saving(self: *Self, _: Context) Result {
        const buffer_ = self.buffer;
        if (buffer_) |buffer|
            buffer.reset_to_last_saved();
        try self.close();
        if (buffer_) |buffer|
            self.buffer_manager.close_buffer(buffer);
    }
    pub const close_file_without_saving_meta: Meta = .{ .description = "Close file without saving" };

    pub fn find_query(self: *Self, ctx: Context) Result {
        var query: []const u8 = undefined;
        if (ctx.args.match(.{tp.extract(&query)}) catch false) {
            try self.find_in_buffer(query);
            self.clamp();
        } else return error.InvalidFindQueryArgument;
    }
    pub const find_query_meta: Meta = .{ .arguments = &.{.string} };

    pub fn find_word_at_cursor(self: *Self, ctx: Context) Result {
        _ = ctx;
        const query: []const u8 = try self.copy_word_at_cursor(self.allocator);
        try self.find_in_buffer(query);
        self.allocator.free(query);
    }
    pub const find_word_at_cursor_meta: Meta = .{ .description = "Search for the word under the cursor" };

    fn find_in(self: *Self, query: []const u8, comptime find_f: ripgrep.FindF, write_buffer: bool) !void {
        const root = try self.buf_root();
        self.cancel_all_matches();
        if (std.mem.indexOfScalar(u8, query, '\n')) |_| return;
        self.logger.print("find:{s}", .{std.fmt.fmtSliceEscapeLower(query)});
        var rg = try find_f(self.allocator, query, "A");
        defer rg.deinit();
        if (write_buffer) {
            var rg_buffer = rg.bufferedWriter();
            try root.store(rg_buffer.writer());
            try rg_buffer.flush();
        }
    }

    pub fn push_find_history(self: *Self, query: []const u8) void {
        if (query.len == 0) return;
        const history = if (self.find_history) |*hist| hist else ret: {
            self.find_history = .empty;
            break :ret &self.find_history.?;
        };
        for (history.items, 0..) |entry, i|
            if (std.mem.eql(u8, entry, query))
                self.allocator.free(history.orderedRemove(i));
        const new = self.allocator.dupe(u8, query) catch return;
        (history.addOne(self.allocator) catch return).* = new;
    }

    fn set_last_find_query(self: *Self, query: []const u8) void {
        if (self.last_find_query) |last| {
            if (query.ptr != last.ptr) {
                self.allocator.free(last);
                self.last_find_query = self.allocator.dupe(u8, query) catch return;
            }
        } else self.last_find_query = self.allocator.dupe(u8, query) catch return;
    }

    pub fn find_in_buffer(self: *Self, query: []const u8) !void {
        self.set_last_find_query(query);
        return self.find_in_buffer_sync(query);
    }

    fn find_in_buffer_sync(self: *Self, query: []const u8) !void {
        const Ctx = struct {
            matches: usize = 0,
            self: *Self,
            fn cb(ctx_: *anyopaque, begin_row: usize, begin_col: usize, end_row: usize, end_col: usize) error{Stop}!void {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                ctx.matches += 1;
                ctx.self.add_match_internal(begin_row, begin_col, end_row, end_col);
                if (ctx.matches >= max_matches)
                    return error.Stop;
            }
        };
        const root = try self.buf_root();
        defer self.add_match_done();
        var ctx: Ctx = .{ .self = self };
        self.init_matches_update();
        try root.find_all_ranges(query, &ctx, Ctx.cb, self.allocator);
    }

    fn find_in_buffer_async(self: *Self, query: []const u8) !void {
        const finder = struct {
            allocator: Allocator,
            query: []const u8,
            parent: tp.pid_ref,
            root: Buffer.Root,
            token: usize,
            matches: Match.List,

            const finder = @This();

            fn start(fdr: *finder) tp.result {
                fdr.find() catch {};
                return tp.exit_normal();
            }

            fn find(fdr: *finder) !void {
                const Ctx = struct {
                    matches: usize = 0,
                    fdr: *finder,
                    const Ctx = @This();
                    fn cb(ctx_: *anyopaque, begin_row: usize, begin_col: usize, end_row: usize, end_col: usize) error{Stop}!void {
                        const ctx = @as(*Ctx, @ptrCast(@alignCast(ctx_)));
                        ctx.matches += 1;
                        const match: Match = .{ .begin = .{ .row = begin_row, .col = begin_col }, .end = .{ .row = end_row, .col = end_col } };
                        (ctx.fdr.matches.addOne() catch return).* = match;
                        if (ctx.fdr.matches.items.len >= max_match_batch)
                            ctx.fdr.send_batch() catch return error.Stop;
                        if (ctx.matches >= max_matches)
                            return error.Stop;
                    }
                };
                defer fdr.parent.send(.{ "A", "done", fdr.token }) catch {};
                defer fdr.allocator.free(fdr.query);
                var ctx: Ctx = .{ .fdr = fdr };
                try fdr.root.find_all_ranges(fdr.query, &ctx, Ctx.cb, fdr.a);
                try fdr.send_batch();
            }

            fn send_batch(fdr: *finder) !void {
                if (fdr.matches.items.len == 0)
                    return;
                var buf: [max_match_batch * @sizeOf(Match)]u8 = undefined;
                var stream = std.io.fixedBufferStream(&buf);
                const writer = stream.writer();
                try cbor.writeArrayHeader(writer, 4);
                try cbor.writeValue(writer, "A");
                try cbor.writeValue(writer, "batch");
                try cbor.writeValue(writer, fdr.token);
                try cbor.writeArrayHeader(writer, fdr.matches.items.len);
                for (fdr.matches.items) |m_| if (m_) |m| {
                    try cbor.writeArray(writer, .{ m.begin.row, m.begin.col, m.end.row, m.end.col });
                };
                try fdr.parent.send_raw(.{ .buf = stream.getWritten() });
                fdr.matches.clearRetainingCapacity();
            }
        };
        self.init_matches_update();
        const fdr = try self.allocator.create(finder);
        fdr.* = .{
            .a = self.allocator,
            .query = try self.allocator.dupe(u8, query),
            .parent = tp.self_pid(),
            .root = try self.buf_root(),
            .token = self.match_token,
            .matches = Match.List.init(self.allocator),
        };
        const pid = try tp.spawn_link(self.allocator, fdr, finder.start, "editor.find");
        pid.deinit();
    }

    pub fn find_in_buffer_ext(self: *Self, query: []const u8) !void {
        return self.find_in(query, ripgrep.find_in_stdin, true);
    }

    pub fn add_match(self: *Self, m: tp.message) !void {
        var begin_line: usize = undefined;
        var begin_pos: usize = undefined;
        var end_line: usize = undefined;
        var end_pos: usize = undefined;
        var batch_cbor: []const u8 = undefined;
        if (try m.match(.{ "A", "done", self.match_token })) {
            self.add_match_done();
        } else if (try m.match(.{ tp.any, "batch", self.match_token, tp.extract_cbor(&batch_cbor) })) {
            try self.add_match_batch(batch_cbor);
        } else if (try m.match(.{ tp.any, self.match_token, tp.extract(&begin_line), tp.extract(&begin_pos), tp.extract(&end_line), tp.extract(&end_pos) })) {
            self.add_match_internal(begin_line, begin_pos, end_line, end_pos);
        } else if (try m.match(.{ tp.any, tp.extract(&begin_line), tp.extract(&begin_pos), tp.extract(&end_line), tp.extract(&end_pos) })) {
            self.add_match_internal(begin_line, begin_pos, end_line, end_pos);
        }
    }

    pub fn add_match_batch(self: *Self, cb: []const u8) !void {
        var iter = cb;
        var begin_line: usize = undefined;
        var begin_pos: usize = undefined;
        var end_line: usize = undefined;
        var end_pos: usize = undefined;
        var len = try cbor.decodeArrayHeader(&iter);
        while (len > 0) : (len -= 1)
            if (try cbor.matchValue(&iter, .{ tp.extract(&begin_line), tp.extract(&begin_pos), tp.extract(&end_line), tp.extract(&end_pos) })) {
                self.add_match_internal(begin_line, begin_pos, end_line, end_pos);
            } else return;
    }

    fn add_match_done(self: *Self) void {
        if (self.matches.items.len > 0) {
            if (self.find_operation) |op| {
                self.find_operation = null;
                switch (op) {
                    .goto_next_match => self.goto_next_match(.{}) catch {},
                    .goto_prev_match => self.goto_prev_match(.{}) catch {},
                }
                return;
            }
        }
        self.match_done_token = self.match_token;
        self.need_render();
    }

    fn add_match_internal(self: *Self, begin_line_: usize, begin_pos_: usize, end_line_: usize, end_pos_: usize) void {
        const root = self.buf_root() catch return;
        const begin_line = begin_line_ - 1;
        const end_line = end_line_ - 1;
        const begin_pos = root.pos_to_width(begin_line, begin_pos_, self.metrics) catch return;
        const end_pos = root.pos_to_width(end_line, end_pos_, self.metrics) catch return;
        var match: Match = .{ .begin = .{ .row = begin_line, .col = begin_pos }, .end = .{ .row = end_line, .col = end_pos } };
        if (match.end.eql(self.get_primary().cursor))
            match.has_selection = true;
        (self.matches.addOne(self.allocator) catch return).* = match;
    }

    fn find_selection_match(self: *const Self, sel: Selection) ?*Match {
        for (self.matches.items) |*match_| if (match_.*) |*match| {
            if (match.to_selection().eql(sel))
                return match;
        };
        return null;
    }

    fn scan_first_match(self: *const Self) ?*Match {
        for (self.matches.items) |*match_| if (match_.*) |*match| {
            if (match.has_selection) continue;
            return match;
        };
        return null;
    }

    fn scan_next_match(self: *const Self, cursor: Cursor) ?*Match {
        const row = cursor.row;
        const col = cursor.col;
        const multi_cursor = self.cursels.items.len > 1;
        for (self.matches.items) |*match_| if (match_.*) |*match|
            if ((!multi_cursor or !match.has_selection) and (row < match.begin.row or (row == match.begin.row and col < match.begin.col)))
                return match;
        return null;
    }

    fn get_next_match(self: *const Self, cursor: Cursor) ?*Match {
        if (self.scan_next_match(cursor)) |match| return match;
        var cursor_ = cursor;
        cursor_.move_buffer_begin();
        return self.scan_first_match();
    }

    fn scan_prev_match(self: *const Self, cursor: Cursor) ?*Match {
        const row = cursor.row;
        const col = cursor.col;
        const count = self.matches.items.len;
        for (0..count) |i| {
            const match = if (self.matches.items[count - 1 - i]) |*m| m else continue;
            if (!match.has_selection and (row > match.end.row or (row == match.end.row and col > match.end.col)))
                return match;
        }
        return null;
    }

    fn get_prev_match(self: *const Self, cursor: Cursor) ?*Match {
        if (self.scan_prev_match(cursor)) |match| return match;
        const root = self.buf_root() catch return null;
        var cursor_ = cursor;
        cursor_.move_buffer_end(root, self.metrics);
        return self.scan_prev_match(cursor_);
    }

    pub fn move_cursor_next_match(self: *Self, _: Context) Result {
        const primary = self.get_primary();
        if (self.get_next_match(primary.cursor)) |match| {
            const root = self.buf_root() catch return;
            if (primary.selection) |sel| if (self.find_selection_match(sel)) |match_| {
                match_.has_selection = false;
            };
            primary.selection = match.to_selection();
            primary.cursor.move_to(root, match.end.row, match.end.col, self.metrics) catch return;
            self.clamp();
        }
    }
    pub const move_cursor_next_match_meta: Meta = .{ .description = "Move cursor to next hightlighted match" };

    pub fn goto_next_match(self: *Self, ctx: Context) Result {
        try self.send_editor_jump_source();
        self.cancel_all_selections();
        if (self.matches.items.len == 0) {
            if (self.last_find_query) |last| {
                self.find_operation = .goto_next_match;
                try self.find_in_buffer(last);
            }
        }
        try self.move_cursor_next_match(ctx);
        try self.send_editor_jump_destination();
    }
    pub const goto_next_match_meta: Meta = .{ .description = "Goto to next hightlighted match" };

    pub fn move_cursor_prev_match(self: *Self, _: Context) Result {
        const primary = self.get_primary();
        if (self.get_prev_match(primary.cursor)) |match| {
            const root = self.buf_root() catch return;
            if (primary.selection) |sel| if (self.find_selection_match(sel)) |match_| {
                match_.has_selection = false;
            };
            primary.selection = match.to_selection();
            primary.selection.?.reverse();
            primary.cursor.move_to(root, match.begin.row, match.begin.col, self.metrics) catch return;
            self.clamp();
        }
    }
    pub const move_cursor_prev_match_meta: Meta = .{ .description = "Move cursor to previous hightlighted match" };

    pub fn goto_prev_match(self: *Self, ctx: Context) Result {
        try self.send_editor_jump_source();
        self.cancel_all_selections();
        if (self.matches.items.len == 0) {
            if (self.last_find_query) |last| {
                self.find_operation = .goto_prev_match;
                try self.find_in_buffer(last);
            }
        }
        try self.move_cursor_prev_match(ctx);
        try self.send_editor_jump_destination();
    }
    pub const goto_prev_match_meta: Meta = .{ .description = "Goto to previous hightlighted match" };

    pub fn goto_next_diagnostic(self: *Self, _: Context) Result {
        if (self.diagnostics.items.len == 0) {
            if (command.get_id("goto_next_file")) |id|
                return command.execute(id, .{});
            return;
        }
        self.sort_diagnostics();
        const primary = self.get_primary();
        for (self.diagnostics.items) |*diag| {
            if ((diag.sel.begin.row == primary.cursor.row and diag.sel.begin.col > primary.cursor.col) or diag.sel.begin.row > primary.cursor.row)
                return self.goto_diagnostic(diag);
        }
        return self.goto_diagnostic(&self.diagnostics.items[0]);
    }
    pub const goto_next_diagnostic_meta: Meta = .{ .description = "Goto to next diagnostic" };

    pub fn goto_prev_diagnostic(self: *Self, _: Context) Result {
        if (self.diagnostics.items.len == 0) {
            if (command.get_id("goto_prev_file")) |id|
                return command.execute(id, .{});
            return;
        }
        self.sort_diagnostics();
        const primary = self.get_primary();
        var i = self.diagnostics.items.len - 1;
        while (true) : (i -= 1) {
            const diag = &self.diagnostics.items[i];
            if ((diag.sel.begin.row == primary.cursor.row and diag.sel.begin.col < primary.cursor.col) or diag.sel.begin.row < primary.cursor.row)
                return self.goto_diagnostic(diag);
            if (i == 0) return self.goto_diagnostic(&self.diagnostics.items[self.diagnostics.items.len - 1]);
        }
    }
    pub const goto_prev_diagnostic_meta: Meta = .{ .description = "Goto to previous diagnostic" };

    fn goto_diagnostic(self: *Self, diag: *const Diagnostic) !void {
        const root = self.buf_root() catch return;
        const primary = self.get_primary();
        try self.send_editor_jump_source();
        self.cancel_all_selections();
        try primary.cursor.move_to(root, diag.sel.begin.row, diag.sel.begin.col, self.metrics);
        self.clamp();
        try self.send_editor_jump_destination();
    }

    fn sort_diagnostics(self: *Self) void {
        const less_fn = struct {
            fn less_fn(_: void, lhs: Diagnostic, rhs: Diagnostic) bool {
                return if (lhs.sel.begin.row == rhs.sel.begin.row)
                    lhs.sel.begin.col < rhs.sel.begin.col
                else
                    lhs.sel.begin.row < rhs.sel.begin.row;
            }
        }.less_fn;
        std.mem.sort(Diagnostic, self.diagnostics.items, {}, less_fn);
    }

    pub fn goto_line(self: *Self, ctx: Context) Result {
        try self.send_editor_jump_source();
        var line: usize = 0;
        if (!try ctx.args.match(.{tp.extract(&line)}))
            return error.InvalidGotoLineArgument;
        const root = self.buf_root() catch return;
        self.cancel_all_selections();
        const primary = self.get_primary();
        try primary.cursor.move_to(root, @intCast(if (line < 1) 0 else line - 1), primary.cursor.col, self.metrics);
        self.clamp();
        try self.send_editor_jump_destination();
    }
    pub const goto_line_meta: Meta = .{ .arguments = &.{.integer} };

    pub fn goto_line_vim(self: *Self, ctx: Context) Result {
        try self.send_editor_jump_source();
        var line: usize = 0;
        _ = ctx.args.match(.{tp.extract(&line)}) catch false;
        const root = self.buf_root() catch return;
        const primary = self.get_primary();
        try primary.cursor.move_to(root, @intCast(if (line < 1) 0 else line - 1), primary.cursor.col, self.metrics);
        self.clamp();
        try self.send_editor_jump_destination();
    }
    pub const goto_line_vim_meta: Meta = .{ .arguments = &.{.integer} };

    pub fn goto_column(self: *Self, ctx: Context) Result {
        var column: usize = 0;
        if (!try ctx.args.match(.{tp.extract(&column)}))
            return error.InvalidGotoColumnArgument;
        const root = self.buf_root() catch return;
        const primary = self.get_primary();
        column = if (column < 1) 0 else column - 1;
        column = try root.pos_to_width(primary.cursor.row, column, self.metrics);
        try primary.cursor.move_to(root, primary.cursor.row, column, self.metrics);
        self.clamp();
    }
    pub const goto_column_meta: Meta = .{ .arguments = &.{.integer} };

    pub fn goto_line_and_column(self: *Self, ctx: Context) Result {
        try self.send_editor_jump_source();
        var line: usize = 0;
        var column: usize = 0;
        var have_sel: bool = false;
        var sel: Selection = .{};
        if (try ctx.args.match(.{
            tp.extract(&line),
            tp.extract(&column),
        })) {
            // self.logger.print("goto: l:{d} c:{d}", .{ line, column });
        } else if (try ctx.args.match(.{
            tp.extract(&line),
            tp.extract(&column),
            tp.extract(&sel.begin.row),
            tp.extract(&sel.begin.col),
            tp.extract(&sel.end.row),
            tp.extract(&sel.end.col),
        })) {
            // self.logger.print("goto: l:{d} c:{d} {any}", .{ line, column, sel });
            have_sel = true;
        } else return error.InvalidGotoLineAndColumnArgument;
        self.cancel_all_selections();
        const root = self.buf_root() catch return;
        const primary = self.get_primary();
        try primary.cursor.move_to(
            root,
            @intCast(if (line < 1) 0 else line - 1),
            @intCast(if (column < 1) 0 else column - 1),
            self.metrics,
        );
        if (have_sel) primary.selection = sel;
        if (self.view.is_visible(&primary.cursor))
            self.clamp()
        else
            try self.scroll_view_center(.{});
        try self.send_editor_jump_destination();
        self.need_render();
    }
    pub const goto_line_and_column_meta: Meta = .{ .arguments = &.{ .integer, .integer } };

    pub fn goto_definition(self: *Self, _: Context) Result {
        const file_path = self.file_path orelse return;
        const primary = self.get_primary();
        return project_manager.goto_definition(file_path, primary.cursor.row, primary.cursor.col);
    }
    pub const goto_definition_meta: Meta = .{ .description = "Language: Goto definition" };

    pub fn goto_declaration(self: *Self, _: Context) Result {
        const file_path = self.file_path orelse return;
        const primary = self.get_primary();
        return project_manager.goto_declaration(file_path, primary.cursor.row, primary.cursor.col);
    }
    pub const goto_declaration_meta: Meta = .{ .description = "Language: Goto declaration" };

    pub fn goto_implementation(self: *Self, _: Context) Result {
        const file_path = self.file_path orelse return;
        const primary = self.get_primary();
        return project_manager.goto_implementation(file_path, primary.cursor.row, primary.cursor.col);
    }
    pub const goto_implementation_meta: Meta = .{ .description = "Language: Goto implementation" };

    pub fn goto_type_definition(self: *Self, _: Context) Result {
        const file_path = self.file_path orelse return;
        const primary = self.get_primary();
        return project_manager.goto_type_definition(file_path, primary.cursor.row, primary.cursor.col);
    }
    pub const goto_type_definition_meta: Meta = .{ .description = "Language: Goto type definition" };

    pub fn references(self: *Self, _: Context) Result {
        const file_path = self.file_path orelse return;
        const primary = self.get_primary();
        return project_manager.references(file_path, primary.cursor.row, primary.cursor.col);
    }
    pub const references_meta: Meta = .{ .description = "Language: Find all references" };

    pub fn completion(self: *Self, _: Context) Result {
        const file_path = self.file_path orelse return;
        const primary = self.get_primary();
        self.completions.clearRetainingCapacity();
        return project_manager.completion(file_path, primary.cursor.row, primary.cursor.col);
    }
    pub const completion_meta: Meta = .{ .description = "Language: Show completions at cursor" };

    pub fn rename_symbol(self: *Self, _: Context) Result {
        const file_path = self.file_path orelse return;
        const root = self.buf_root() catch return;
        const primary = self.get_primary();
        const col = try root.get_line_width_to_pos(primary.cursor.row, primary.cursor.col, self.metrics);
        return project_manager.rename_symbol(file_path, primary.cursor.row, col);
    }
    pub const rename_symbol_meta: Meta = .{ .description = "Language: Rename symbol at cursor" };

    pub fn add_cursor_from_selection(self: *Self, sel_: Selection, op: enum { cancel, push }) !void {
        switch (op) {
            .cancel => self.cancel_all_selections(),
            .push => try self.push_cursor(),
        }
        const root = self.buf_root() catch return;
        const sel: Selection = .{
            .begin = .{
                .row = sel_.begin.row,
                .col = try root.pos_to_width(sel_.begin.row, sel_.begin.col, self.metrics),
            },
            .end = .{
                .row = sel_.end.row,
                .col = try root.pos_to_width(sel_.end.row, sel_.end.col, self.metrics),
            },
        };
        const primary = self.get_primary();
        primary.selection = sel;
        primary.cursor = sel.end;
        self.need_render();
    }

    pub fn add_cursors_from_content_diff(self: *Self, new_content: []const u8) !void {
        const frame = tracy.initZone(@src(), .{ .name = "editor diff syntax" });
        defer frame.deinit();

        var content_ = std.ArrayListUnmanaged(u8).empty;
        defer content_.deinit(self.allocator);
        const root = self.buf_root() catch return;
        const eol_mode = self.buf_eol_mode() catch return;
        try root.store(content_.writer(self.allocator), eol_mode);
        const content = content_.items;
        var last_begin_row: usize = 0;
        var last_begin_col_pos: usize = 0;
        var last_end_row: usize = 0;
        var last_end_col_pos: usize = 0;

        const diffs = try @import("diff").diff(self.allocator, new_content, content);
        defer self.allocator.free(diffs);
        var first = true;
        for (diffs) |diff| {
            switch (diff.kind) {
                .delete => {
                    var begin_row, var begin_col_pos = count_lines(content[0..diff.start]);
                    const end_row, const end_col_pos = count_lines(content[0 .. diff.start + diff.bytes.len]);
                    if (begin_row == last_end_row and begin_col_pos == last_end_col_pos) {
                        begin_row = last_begin_row;
                        begin_col_pos = last_begin_col_pos;
                    } else {
                        if (first) {
                            self.cancel_all_selections();
                        } else {
                            try self.push_cursor();
                        }
                        first = false;
                    }
                    const begin_col = try root.pos_to_width(begin_row, begin_col_pos, self.metrics);
                    const end_col = try root.pos_to_width(end_row, end_col_pos, self.metrics);

                    last_begin_row = begin_row;
                    last_begin_col_pos = begin_col_pos;
                    last_end_row = end_row;
                    last_end_col_pos = end_col_pos;

                    const sel: Selection = .{
                        .begin = .{ .row = begin_row, .col = begin_col },
                        .end = .{ .row = end_row, .col = end_col },
                    };
                    const primary = self.get_primary();
                    primary.selection = sel;
                    primary.cursor = sel.end;
                    self.need_render();
                },
                else => {},
            }
        }
    }

    fn count_lines(content: []const u8) struct { usize, usize } {
        var pos = content;
        var offset = content.len;
        var lines: usize = 0;
        while (pos.len > 0) : (pos = pos[1..]) if (pos[0] == '\n') {
            offset = pos.len - 1;
            lines += 1;
        };
        return .{ lines, offset };
    }

    pub fn hover(self: *Self, _: Context) Result {
        const primary = self.get_primary();
        return self.hover_at(primary.cursor.row, primary.cursor.col);
    }
    pub const hover_meta: Meta = .{ .description = "Language: Show documentation for symbol (hover)" };

    pub fn hover_at_abs(self: *Self, y: usize, x: usize) Result {
        const row: usize = self.view.row + y;
        const col: usize = self.view.col + x;
        return self.hover_at(row, col);
    }

    pub fn hover_at(self: *Self, row: usize, col: usize) Result {
        const file_path = self.file_path orelse return;
        const root = self.buf_root() catch return;
        const pos = root.get_line_width_to_pos(row, col, self.metrics) catch return;
        return project_manager.hover(file_path, row, pos);
    }

    pub fn add_hover_highlight(self: *Self, match_: Match) void {
        const root = self.buf_root() catch return;
        const match: Match = .{
            .begin = .{
                .row = match_.begin.row,
                .col = root.pos_to_width(match_.begin.row, match_.begin.col, self.metrics) catch return,
            },
            .end = .{
                .row = match_.end.row,
                .col = root.pos_to_width(match_.end.row, match_.end.col, self.metrics) catch return,
            },
        };
        switch (self.matches.items.len) {
            0 => {
                (self.matches.addOne(self.allocator) catch return).* = match;
            },
            1 => {
                self.matches.items[0] = match;
            },
            else => {},
        }
        self.need_render();
    }

    pub fn add_diagnostic(
        self: *Self,
        file_path: []const u8,
        source: []const u8,
        code: []const u8,
        message: []const u8,
        severity: i32,
        sel_: Selection,
    ) Result {
        if (!std.mem.eql(u8, file_path, self.file_path orelse return)) return;

        const root = self.buf_root() catch return;
        const sel: Selection = .{
            .begin = .{
                .row = sel_.begin.row,
                .col = root.pos_to_width(sel_.begin.row, sel_.begin.col, self.metrics) catch return,
            },
            .end = .{
                .row = sel_.end.row,
                .col = root.pos_to_width(sel_.end.row, sel_.end.col, self.metrics) catch return,
            },
        };

        (try self.diagnostics.addOne(self.allocator)).* = .{
            .source = try self.allocator.dupe(u8, source),
            .code = try self.allocator.dupe(u8, code),
            .message = try self.allocator.dupe(u8, message),
            .severity = severity,
            .sel = sel,
        };

        switch (Diagnostic.to_severity(severity)) {
            .Error => self.diag_errors += 1,
            .Warning => self.diag_warnings += 1,
            .Information => self.diag_info += 1,
            .Hint => self.diag_hints += 1,
        }
        self.send_editor_diagnostics() catch {};
        self.need_render();
    }

    pub fn clear_diagnostics(self: *Self) void {
        self.diagnostics.clearRetainingCapacity();
        self.diag_errors = 0;
        self.diag_warnings = 0;
        self.diag_info = 0;
        self.diag_hints = 0;
        self.send_editor_diagnostics() catch {};
        self.need_render();
    }

    pub fn add_completion(self: *Self, row: usize, col: usize, is_incomplete: bool, msg: tp.message) Result {
        try self.completions.appendSlice(self.allocator, msg.buf);
        _ = row;
        _ = col;
        _ = is_incomplete;
    }

    pub fn select(self: *Self, ctx: Context) Result {
        var sel: Selection = .{};
        if (!try ctx.args.match(.{ tp.extract(&sel.begin.row), tp.extract(&sel.begin.col), tp.extract(&sel.end.row), tp.extract(&sel.end.col) }))
            return error.InvalidSelectArgument;
        self.get_primary().selection = sel;
    }
    pub const select_meta: Meta = .{ .arguments = &.{ .integer, .integer, .integer, .integer } };

    fn get_formatter(self: *Self) ?[]const []const u8 {
        if (self.file_type) |file_type| if (file_type.formatter) |fmtr| if (fmtr.len > 0) return fmtr;
        return null;
    }

    pub fn format(self: *Self, ctx: Context) Result {
        if (ctx.args.buf.len > 0 and try ctx.args.match(.{ tp.string, tp.more })) {
            try self.filter_cmd(ctx.args);
            return;
        }
        if (self.get_formatter()) |fmtr| {
            var args = std.ArrayListUnmanaged(u8).empty;
            defer args.deinit(self.allocator);
            const writer = args.writer(self.allocator);
            try cbor.writeArrayHeader(writer, fmtr.len);
            for (fmtr) |arg| try cbor.writeValue(writer, arg);
            try self.filter_cmd(.{ .buf = try args.toOwnedSlice(self.allocator) });
            return;
        }
        return tp.exit("no formatter");
    }
    pub const format_meta: Meta = .{ .description = "Language: Format file or selection" };

    pub fn filter(self: *Self, ctx: Context) Result {
        if (!try ctx.args.match(.{ tp.string, tp.more }))
            return error.InvalidFilterArgument;
        try self.filter_cmd(ctx.args);
    }
    pub const filter_meta: Meta = .{ .arguments = &.{.string} };

    fn filter_cmd(self: *Self, cmd: tp.message) !void {
        if (self.filter_) |_| return error.Stop;
        const root = self.buf_root() catch return;
        const buf_a_ = try self.buf_a();
        const primary = self.get_primary();
        var sel: Selection = if (primary.selection) |sel_| sel_ else val: {
            var sel_: Selection = .{};
            try expand_selection_to_all(root, &sel_, self.metrics);
            break :val sel_;
        };
        const reversed = sel.begin.right_of(sel.end);
        sel.normalize();
        self.filter_ = .{
            .before_root = root,
            .work_root = root,
            .begin = sel.begin,
            .pos = .{ .cursor = sel.begin },
            .old_primary = primary.*,
            .old_primary_reversed = reversed,
            .whole_file = if (primary.selection) |_| null else .empty,
        };
        errdefer self.filter_deinit();
        const state = &self.filter_.?;
        var buf: [1024]u8 = undefined;
        const json = try cmd.to_json(&buf);
        self.logger.print("filter: start {s}", .{json});
        var sp = try tp.subprocess.init(self.allocator, cmd, "filter", .Pipe);
        defer {
            sp.close() catch {};
            sp.deinit();
        }
        var buffer = sp.bufferedWriter();
        try self.write_range(state.before_root, sel, buffer.writer(), tp.exit_error, null);
        try buffer.flush();
        self.logger.print("filter: sent", .{});
        state.work_root = try state.work_root.delete_range(sel, buf_a_, null, self.metrics);
    }

    fn filter_stdout(self: *Self, bytes: []const u8) !void {
        const state = if (self.filter_) |*s| s else return error.Stop;
        errdefer self.filter_deinit();
        const buf_a_ = try self.buf_a();
        if (state.whole_file) |*buf| {
            try buf.appendSlice(self.allocator, bytes);
        } else {
            const cursor = &state.pos.cursor;
            cursor.row, cursor.col, state.work_root = try state.work_root.insert_chars(cursor.row, cursor.col, bytes, buf_a_, self.metrics);
            state.bytes += bytes.len;
            state.chunks += 1;
        }
    }

    fn filter_error(self: *Self, bytes: []const u8) !void {
        defer self.filter_deinit();
        self.logger.print("filter: ERR: {s}", .{bytes});
        if (self.need_save_after_filter) |info| {
            try self.save();
            if (info.then) |then|
                return command.executeName(then.cmd, .{ .args = .{ .buf = then.args } });
        }
    }

    fn filter_not_found(self: *Self) !void {
        defer self.filter_deinit();
        self.logger.print_err("filter", "executable not found", .{});
        if (self.need_save_after_filter) |info| {
            try self.save();
            if (info.then) |then|
                return command.executeName(then.cmd, .{ .args = .{ .buf = then.args } });
        }
    }

    fn filter_done(self: *Self) !void {
        const b = try self.buf_for_update();
        const root = self.buf_root() catch return;
        const state = if (self.filter_) |*s| s else return error.Stop;
        if (state.before_root != root) return error.Stop;
        defer self.filter_deinit();
        const primary = self.get_primary();
        self.cancel_all_selections();
        self.cancel_all_matches();
        if (state.whole_file) |buf| {
            state.work_root = try b.load_from_string(buf.items, &state.eol_mode, &state.utf8_sanitized);
            state.bytes = buf.items.len;
            state.chunks = 1;
            primary.cursor = state.old_primary.cursor;
        } else {
            const sel = try primary.enable_selection(root, self.metrics);
            sel.begin = state.begin;
            sel.end = state.pos.cursor;
            if (state.old_primary_reversed) sel.reverse();
            primary.cursor = sel.end;
        }
        try self.update_buf_and_eol_mode(state.work_root, state.eol_mode, state.utf8_sanitized);
        primary.cursor.clamp_to_buffer(state.work_root, self.metrics);
        self.logger.print("filter: done (bytes:{d} chunks:{d})", .{ state.bytes, state.chunks });
        self.reset_syntax();
        self.clamp();
        self.need_render();
        if (self.need_save_after_filter) |info| {
            try self.save();
            if (info.then) |then|
                return command.executeName(then.cmd, .{ .args = .{ .buf = then.args } });
        }
    }

    fn filter_deinit(self: *Self) void {
        const state = if (self.filter_) |*s| s else return;
        if (state.whole_file) |*buf| buf.deinit(self.allocator);
        self.filter_ = null;
    }

    fn to_upper_cursel(self: *Self, root_: Buffer.Root, cursel: *CurSel, allocator: Allocator) error{Stop}!Buffer.Root {
        var root = root_;
        const saved = cursel.*;
        const sel = if (cursel.selection) |*sel| sel else ret: {
            var sel = cursel.enable_selection(root, self.metrics) catch return error.Stop;
            move_cursor_word_begin(root, &sel.begin, self.metrics) catch return error.Stop;
            move_cursor_word_end(root, &sel.end, self.metrics) catch return error.Stop;
            break :ret sel;
        };
        var sfa = std.heap.stackFallback(4096, self.allocator);
        const cut_text = copy_selection(root, sel.*, sfa.get(), self.metrics) catch return error.Stop;
        defer allocator.free(cut_text);
        const ucased = Buffer.unicode.get_letter_casing().toUpperStr(allocator, cut_text) catch return error.Stop;
        defer allocator.free(ucased);
        root = try self.delete_selection(root, cursel, allocator);
        root = self.insert(root, cursel, ucased, allocator) catch return error.Stop;
        cursel.* = saved;
        return root;
    }

    pub fn to_upper(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.with_cursels_mut_once(b.root, to_upper_cursel, b.allocator);
        try self.update_buf(root);
        self.clamp();
    }
    pub const to_upper_meta: Meta = .{ .description = "Convert selection or word to upper case" };

    fn to_lower_cursel(self: *Self, root_: Buffer.Root, cursel: *CurSel, allocator: Allocator) error{Stop}!Buffer.Root {
        var root = root_;
        const saved = cursel.*;
        const sel = if (cursel.selection) |*sel| sel else ret: {
            var sel = cursel.enable_selection(root, self.metrics) catch return error.Stop;
            move_cursor_word_begin(root, &sel.begin, self.metrics) catch return error.Stop;
            move_cursor_word_end(root, &sel.end, self.metrics) catch return error.Stop;
            break :ret sel;
        };
        var sfa = std.heap.stackFallback(4096, self.allocator);
        const cut_text = copy_selection(root, sel.*, sfa.get(), self.metrics) catch return error.Stop;
        defer allocator.free(cut_text);
        const ucased = Buffer.unicode.get_letter_casing().toLowerStr(allocator, cut_text) catch return error.Stop;
        defer allocator.free(ucased);
        root = try self.delete_selection(root, cursel, allocator);
        root = self.insert(root, cursel, ucased, allocator) catch return error.Stop;
        cursel.* = saved;
        return root;
    }

    pub fn to_lower(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.with_cursels_mut_once(b.root, to_lower_cursel, b.allocator);
        try self.update_buf(root);
        self.clamp();
    }
    pub const to_lower_meta: Meta = .{ .description = "Convert selection or word to lower case" };

    fn switch_case_cursel(self: *Self, root_: Buffer.Root, cursel: *CurSel, allocator: Allocator) error{Stop}!Buffer.Root {
        var root = root_;
        var saved = cursel.*;
        const sel = if (cursel.selection) |*sel| sel else ret: {
            var sel = cursel.enable_selection(root, self.metrics) catch return error.Stop;
            move_cursor_right(root, &sel.end, self.metrics) catch return error.Stop;
            saved.cursor = sel.end;
            break :ret sel;
        };
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();
        const writer: struct {
            self_: *Self,
            result: *std.ArrayList(u8),
            allocator: std.mem.Allocator,

            const Error = @typeInfo(@typeInfo(@TypeOf(Buffer.unicode.LetterCasing.toUpperStr)).@"fn".return_type.?).error_union.error_set;
            pub fn write(writer: *@This(), bytes: []const u8) Error!void {
                const letter_casing = Buffer.unicode.get_letter_casing();
                const flipped = if (letter_casing.isLowerStr(bytes))
                    try letter_casing.toUpperStr(writer.self_.allocator, bytes)
                else
                    try letter_casing.toLowerStr(writer.self_.allocator, bytes);
                defer writer.self_.allocator.free(flipped);
                return writer.result.appendSlice(flipped);
            }
            fn map_error(e: anyerror, _: ?*std.builtin.StackTrace) Error {
                return @errorCast(e);
            }
        } = .{
            .self_ = self,
            .result = &result,
            .allocator = allocator,
        };
        self.write_range(root, sel.*, writer, @TypeOf(writer).map_error, null) catch return error.Stop;
        root = try self.delete_selection(root, cursel, allocator);
        root = self.insert(root, cursel, writer.result.items, allocator) catch return error.Stop;
        cursel.* = saved;
        return root;
    }

    pub fn switch_case(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.with_cursels_mut_once(b.root, switch_case_cursel, b.allocator);
        try self.update_buf(root);
        self.clamp();
    }
    pub const switch_case_meta: Meta = .{ .description = "Switch the case of selection or character at cursor" };

    pub fn forced_mark_clean(self: *Self, _: Context) Result {
        if (self.buffer) |b| {
            b.mark_clean();
            self.update_event() catch {};
        }
    }
    pub const forced_mark_clean_meta: Meta = .{ .description = "Force current file to be marked as clean" };

    pub fn toggle_eol_mode(self: *Self, _: Context) Result {
        if (self.buffer) |b| {
            b.file_eol_mode = switch (b.file_eol_mode) {
                .lf => .crlf,
                .crlf => .lf,
            };
            self.update_event() catch {};
        }
    }
    pub const toggle_eol_mode_meta: Meta = .{ .description = "Toggle end of line sequence" };

    pub fn toggle_syntax_highlighting(self: *Self, _: Context) Result {
        self.syntax_no_render = !self.syntax_no_render;
        if (self.syntax_no_render) {
            if (self.syntax) |syn| {
                const frame = tracy.initZone(@src(), .{ .name = "editor reset syntax" });
                defer frame.deinit();
                syn.reset();
                self.syntax_last_rendered_root = null;
                self.syntax_refresh_full = true;
                self.syntax_incremental_reparse = false;
            }
        }
        self.logger.print("syntax highlighting {s}", .{if (self.syntax_no_render) "disabled" else "enabled"});
    }
    pub const toggle_syntax_highlighting_meta: Meta = .{ .description = "Toggle syntax highlighting" };

    pub fn toggle_syntax_timing(self: *Self, _: Context) Result {
        self.syntax_report_timing = !self.syntax_report_timing;
    }
    pub const toggle_syntax_timing_meta: Meta = .{ .description = "Toggle tree-sitter timing reports" };

    pub fn set_file_type(self: *Self, ctx: Context) Result {
        var file_type: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&file_type)}))
            return error.InvalidSetFileTypeArgument;

        if (self.syntax) |syn| syn.destroy(tui.query_cache());
        self.syntax_last_rendered_root = null;
        self.syntax_refresh_full = true;
        self.syntax_incremental_reparse = false;

        const file_type_config_ = try file_type_config.get(file_type);
        self.file_type = file_type_config_;

        self.syntax = blk: {
            break :blk if (self.file_type) |ft|
                ft.create_syntax(self.allocator, tui.query_cache()) catch null
            else
                null;
        };

        if (self.file_type) |ft| {
            var content = std.ArrayListUnmanaged(u8).empty;
            defer content.deinit(std.heap.c_allocator);
            const root = try self.buf_root();
            try root.store(content.writer(std.heap.c_allocator), try self.buf_eol_mode());

            if (self.buffer) |buffer| if (self.file_path) |file_path|
                project_manager.did_open(
                    file_path,
                    ft,
                    buffer.lsp_version,
                    try content.toOwnedSlice(std.heap.c_allocator),
                    if (self.buffer) |p| p.is_ephemeral() else true,
                ) catch |e|
                    self.logger.print("project_manager.did_open failed: {any}", .{e});
        }
        self.syntax_no_render = tp.env.get().is("no-syntax");
        self.syntax_report_timing = tp.env.get().is("syntax-report-timing");

        const ftn = if (self.file_type) |ft| ft.name else file_type_config.default.name;
        const fti = if (self.file_type) |ft| ft.icon orelse file_type_config.default.icon else file_type_config.default.icon;
        const ftc = if (self.file_type) |ft| ft.color orelse file_type_config.default.color else file_type_config.default.color;
        if (self.buffer) |buffer| {
            buffer.file_type_name = ftn;
            buffer.file_type_icon = fti;
            buffer.file_type_color = ftc;
        }
        const file_exists = if (self.buffer) |b| b.file_exists else false;
        try self.send_editor_open(self.file_path orelse "", file_exists, ftn, fti, ftc);
        self.logger.print("file type {s}", .{file_type});
    }
    pub const set_file_type_meta: Meta = .{ .arguments = &.{.string} };
};

pub fn create(allocator: Allocator, parent: Plane, buffer_manager: *Buffer.Manager) !Widget {
    return EditorWidget.create(allocator, parent, buffer_manager);
}

pub const EditorWidget = struct {
    plane: Plane,
    parent: Plane,

    editor: Editor,
    commands: Commands = undefined,

    last_btn: input.Mouse = .none,
    last_btn_time_ms: i64 = 0,
    last_btn_count: usize = 0,
    last_btn_x: c_int = 0,
    last_btn_y: c_int = 0,

    hover: bool = false,
    hover_timer: ?tp.Cancellable = null,
    hover_x: c_int = -1,
    hover_y: c_int = -1,
    hover_mouse_event: bool = false,

    const Self = @This();
    const Commands = command.Collection(Editor);

    fn create(allocator: Allocator, parent: Plane, buffer_manager: *Buffer.Manager) !Widget {
        const container = try WidgetList.createH(allocator, parent, "editor.container", .dynamic);
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        try self.init(allocator, container.plane, buffer_manager);
        try self.commands.init(&self.editor);
        const editorWidget = Widget.to(self);
        try container.add(try editor_gutter.create(allocator, container.widget(), editorWidget, &self.editor));
        try container.add(editorWidget);
        if (tui.config().show_scrollbars)
            try container.add(try scrollbar_v.create(allocator, container.plane, editorWidget, EventHandler.to_unowned(container)));
        return container.widget();
    }

    fn init(self: *Self, allocator: Allocator, parent: Plane, buffer_manager: *Buffer.Manager) !void {
        var n = try Plane.init(&(Widget.Box{}).opts("editor"), parent);
        errdefer n.deinit();

        self.* = .{
            .parent = parent,
            .plane = n,
            .editor = undefined,
        };
        self.editor.init(allocator, n, buffer_manager);
        errdefer self.editor.deinit();
        try self.editor.push_cursor();
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        self.update_hover_timer(.cancel);
        self.commands.deinit();
        self.editor.deinit();
        self.plane.deinit();
        allocator.destroy(self);
    }

    pub fn update(self: *Self) void {
        self.editor.update();
    }

    pub fn render(self: *Self, theme: *const Widget.Theme) bool {
        return self.editor.render(theme);
    }

    pub fn receive(self: *Self, _: tp.pid_ref, m: tp.message) error{Exit}!bool {
        return self.receive_safe(m) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn receive_safe(self: *Self, m: tp.message) !bool {
        var event: input.Event = undefined;
        var btn: input.MouseType = undefined;
        var x: c_int = undefined;
        var y: c_int = undefined;
        var xpx: c_int = undefined;
        var ypx: c_int = undefined;
        var pos: u32 = 0;
        var bytes: []const u8 = "";

        if (try m.match(.{ "M", tp.extract(&x), tp.extract(&y), tp.extract(&xpx), tp.extract(&ypx) })) {
            const hover_y, const hover_x = self.editor.plane.abs_yx_to_rel(y, x);
            if (hover_y != self.hover_y or hover_x != self.hover_x) {
                self.hover_y, self.hover_x = .{ hover_y, hover_x };
                if (self.editor.jump_mode) {
                    self.update_hover_timer(.init);
                    self.hover_mouse_event = true;
                }
            }
        } else if (try m.match(.{ "B", tp.extract(&event), tp.extract(&btn), tp.any, tp.extract(&x), tp.extract(&y), tp.extract(&xpx), tp.extract(&ypx) })) {
            try self.mouse_click_event(event, @enumFromInt(btn), y, x, ypx, xpx);
        } else if (try m.match(.{ "D", tp.extract(&event), tp.extract(&btn), tp.any, tp.extract(&x), tp.extract(&y), tp.extract(&xpx), tp.extract(&ypx) })) {
            try self.mouse_drag_event(event, @enumFromInt(btn), y, x, ypx, xpx);
        } else if (try m.match(.{ "scroll_to", tp.extract(&pos) })) {
            self.editor.scroll_to(pos);
        } else if (try m.match(.{ "filter", "stdout", tp.extract(&bytes) })) {
            self.editor.filter_stdout(bytes) catch {};
        } else if (try m.match(.{ "filter", "stderr", tp.extract(&bytes) })) {
            try self.editor.filter_error(bytes);
        } else if (try m.match(.{ "filter", "term", "error.FileNotFound", 1 })) {
            try self.editor.filter_not_found();
        } else if (try m.match(.{ "filter", "term", tp.more })) {
            try self.editor.filter_done();
        } else if (try m.match(.{ "A", tp.more })) {
            self.editor.add_match(m) catch {};
        } else if (try m.match(.{ "H", tp.extract(&self.hover) })) {
            if (self.editor.jump_mode) {
                self.update_hover_timer(.init);
                tui.rdr().request_mouse_cursor_pointer(self.hover);
            } else {
                self.update_hover_timer(.cancel);
                tui.rdr().request_mouse_cursor_text(self.hover);
            }
        } else if (try m.match(.{"HOVER"})) {
            self.update_hover_timer(.fired);
            if (self.hover_y >= 0 and self.hover_x >= 0 and self.hover_mouse_event)
                try self.editor.hover_at_abs(@intCast(self.hover_y), @intCast(self.hover_x));
        } else if (try m.match(.{ "whitespace_mode", tp.extract(&bytes) })) {
            self.editor.render_whitespace = Editor.from_whitespace_mode(bytes);
        } else {
            return false;
        }
        return true;
    }

    fn update_hover_timer(self: *Self, event: enum { init, fired, cancel }) void {
        if (self.hover_timer) |*t| {
            if (event != .fired) t.cancel() catch {};
            t.deinit();
            self.hover_timer = null;
        }
        if (event == .init) {
            self.hover_mouse_event = false;
            const delay_us: u64 = std.time.us_per_ms * tui.config().hover_time_ms;
            self.hover_timer = tp.self_pid().delay_send_cancellable(self.editor.allocator, "editor.hover_timer", delay_us, .{"HOVER"}) catch null;
        }
    }

    const Result = command.Result;

    fn mouse_click_event(self: *Self, event: input.Event, btn: input.Mouse, y: c_int, x: c_int, ypx: c_int, xpx: c_int) Result {
        if (event != input.event.press) return;
        const ret = (switch (btn) {
            input.mouse.BUTTON1 => &mouse_click_button1,
            input.mouse.BUTTON2 => &mouse_click_button2,
            input.mouse.BUTTON3 => &mouse_click_button3,
            input.mouse.BUTTON4 => &mouse_click_button4,
            input.mouse.BUTTON5 => &mouse_click_button5,
            input.mouse.BUTTON8 => &mouse_click_button8, //back
            input.mouse.BUTTON9 => &mouse_click_button9, //forward
            else => return,
        })(self, y, x, ypx, xpx);
        self.last_btn = btn;
        self.last_btn_time_ms = time.milliTimestamp();
        return ret;
    }

    fn mouse_drag_event(self: *Self, event: input.Event, btn: input.Mouse, y: c_int, x: c_int, ypx: c_int, xpx: c_int) Result {
        if (event != input.event.press) return;
        return (switch (btn) {
            input.mouse.BUTTON1 => &mouse_drag_button1,
            input.mouse.BUTTON2 => &mouse_drag_button2,
            input.mouse.BUTTON3 => &mouse_drag_button3,
            else => return,
        })(self, y, x, ypx, xpx);
    }

    fn mouse_pos_abs(self: *Self, y: c_int, x: c_int, xoffset: c_int) struct { c_int, c_int } {
        return if (tui.is_cursor_beam())
            self.editor.plane.abs_yx_to_rel_nearest_x(y, x, xoffset)
        else
            self.editor.plane.abs_yx_to_rel(y, x);
    }

    fn mouse_click_button1(self: *Self, y: c_int, x: c_int, _: c_int, xoffset: c_int) Result {
        const y_, const x_ = self.mouse_pos_abs(y, x, xoffset);
        defer {
            self.last_btn_y = y_;
            self.last_btn_x = x_;
        }
        if (self.last_btn == input.mouse.BUTTON1) {
            const click_time_ms = time.milliTimestamp() - self.last_btn_time_ms;
            if (click_time_ms <= double_click_time_ms and
                self.last_btn_y == y_ and
                self.last_btn_x == x_)
            {
                if (self.last_btn_count == 2) {
                    self.last_btn_count = 3;
                    try self.editor.primary_triple_click(y_, x_);
                    return;
                }
                self.last_btn_count = 2;
                try self.editor.primary_double_click(y_, x_);
                return;
            }
        }
        self.last_btn_count = 1;
        try self.editor.primary_click(y_, x_);
        return;
    }

    fn mouse_drag_button1(self: *Self, y: c_int, x: c_int, _: c_int, xoffset: c_int) Result {
        const y_, const x_ = self.mouse_pos_abs(y, x, xoffset);
        self.editor.primary_drag(y_, x_);
    }

    fn mouse_click_button2(_: *Self, _: c_int, _: c_int, _: c_int, _: c_int) Result {}

    fn mouse_drag_button2(_: *Self, _: c_int, _: c_int, _: c_int, _: c_int) Result {}

    fn mouse_click_button3(self: *Self, y: c_int, x: c_int, _: c_int, xoffset: c_int) Result {
        const y_, const x_ = self.mouse_pos_abs(y, x, xoffset);
        try self.editor.secondary_click(y_, x_);
    }

    fn mouse_drag_button3(self: *Self, y: c_int, x: c_int, _: c_int, xoffset: c_int) Result {
        const y_, const x_ = self.mouse_pos_abs(y, x, xoffset);
        try self.editor.secondary_drag(y_, x_);
    }

    fn mouse_click_button4(self: *Self, _: c_int, _: c_int, _: c_int, _: c_int) Result {
        try self.editor.scroll_up_pageup(.{});
    }

    fn mouse_click_button5(self: *Self, _: c_int, _: c_int, _: c_int, _: c_int) Result {
        try self.editor.scroll_down_pagedown(.{});
    }

    fn mouse_click_button8(_: *Self, _: c_int, _: c_int, _: c_int, _: c_int) Result {
        try command.executeName("jump_back", .{});
    }

    fn mouse_click_button9(_: *Self, _: c_int, _: c_int, _: c_int, _: c_int) Result {
        try command.executeName("jump_forward", .{});
    }

    pub fn handle_resize(self: *Self, pos: Widget.Box) void {
        self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
        self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;
        self.editor.handle_resize(pos);
    }

    pub fn subscribe(self: *Self, h: EventHandler) !void {
        self.editor.handlers.add(h) catch {};
    }

    pub fn unsubscribe(self: *Self, h: EventHandler) !void {
        self.editor.handlers.remove(h) catch {};
    }
};

pub const PosToWidthCache = struct {
    cache: std.ArrayList(usize),
    cached_line: usize = std.math.maxInt(usize),
    cached_root: ?Buffer.Root = null,

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        return .{
            .cache = try .initCapacity(allocator, 2048),
        };
    }

    pub fn deinit(self: *Self) void {
        self.cache.deinit();
    }

    pub fn range_to_selection(self: *Self, range: syntax.Range, root: Buffer.Root, metrics: Buffer.Metrics) ?Selection {
        const start = range.start_point;
        const end = range.end_point;
        if (root != self.cached_root or self.cached_line != start.row) {
            self.cache.clearRetainingCapacity();
            self.cached_line = start.row;
            self.cached_root = root;
            root.get_line_width_map(self.cached_line, &self.cache, metrics) catch return null;
        }
        const start_col = if (start.column < self.cache.items.len) self.cache.items[start.column] else start.column;
        const end_col = if (end.row == start.row and end.column < self.cache.items.len) self.cache.items[end.column] else root.pos_to_width(end.row, end.column, metrics) catch end.column;
        return .{ .begin = .{ .row = start.row, .col = start_col }, .end = .{ .row = end.row, .col = end_col } };
    }
};

fn ViewMap(T: type, default: T) type {
    return struct {
        rows: usize,
        cols: usize,
        data: []T = &[_]T{},
        fn init(allocator: std.mem.Allocator, rows: usize, cols: usize) !@This() {
            const data = try allocator.alloc(T, rows * cols);
            @memset(data[0 .. rows * cols], default);
            return .{ .rows = rows, .cols = cols, .data = data };
        }
        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.data);
        }
        fn set_yx(self: @This(), y: usize, x: usize, value: T) void {
            if (y >= self.rows or x >= self.cols) return;
            self.data[y * self.cols + x] = value;
        }
        fn get_yx(self: @This(), y: usize, x: usize) T {
            if (y >= self.rows or x >= self.cols) return default;
            return self.data[y * self.cols + x];
        }
    };
}
