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
const project_manager = @import("project_manager");
const CaseData = @import("CaseData");
const root_mod = @import("root");

const Plane = @import("renderer").Plane;
const Cell = @import("renderer").Cell;
const key = @import("renderer").input.key;
const event_type = @import("renderer").input.event_type;

const scrollbar_v = @import("scrollbar_v.zig");
const editor_gutter = @import("editor_gutter.zig");
const EventHandler = @import("EventHandler.zig");
const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const command = @import("command.zig");
const tui = @import("tui.zig");

const module = @This();

pub const Cursor = Buffer.Cursor;
pub const View = Buffer.View;
pub const Selection = Buffer.Selection;

const Allocator = std.mem.Allocator;
const copy = std.mem.copy;
const fmt = std.fmt;
const time = std.time;

const scroll_step_small = 3;
const scroll_page_ratio = 3;
const scroll_cursor_min_border_distance = 5;
const scroll_cursor_min_border_distance_mouse = 1;

const double_click_time_ms = 350;
pub const max_matches = if (builtin.mode == std.builtin.OptimizeMode.Debug) 10_000 else 100_000;
pub const max_match_lines = 15;
pub const max_match_batch = if (builtin.mode == std.builtin.OptimizeMode.Debug) 100 else 1000;

pub const Match = struct {
    begin: Cursor = Cursor{},
    end: Cursor = Cursor{},
    has_selection: bool = false,
    style: ?Widget.Theme.Style = null,

    const List = std.ArrayList(?Self);
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

    const List = std.ArrayList(?Self);
    const Self = @This();

    pub inline fn invalid() Self {
        return .{ .cursor = Cursor.invalid() };
    }

    inline fn reset(self: *Self) void {
        self.* = .{};
    }

    fn enable_selection(self: *Self) *Selection {
        return if (self.selection) |*sel|
            sel
        else cod: {
            self.selection = Selection.from_cursor(&self.cursor);
            break :cod &self.selection.?;
        };
    }

    fn check_selection(self: *Self) void {
        if (self.selection) |sel| if (sel.empty()) {
            self.selection = null;
        };
    }

    fn expand_selection_to_line(self: *Self, root: Buffer.Root, plane: Plane) *Selection {
        const sel = self.enable_selection();
        sel.normalize();
        sel.begin.move_begin();
        if (!(sel.end.row > sel.begin.row and sel.end.col == 0)) {
            sel.end.move_end(root, plane.metrics());
            sel.end.move_right(root, plane.metrics()) catch {};
        }
        return sel;
    }

    fn write(self: *const Self, writer: Buffer.MetaWriter) !void {
        try self.cursor.write(writer);
        if (self.selection) |sel| {
            try sel.write(writer);
        } else {
            try cbor.writeValue(writer, null);
        }
    }

    fn extract(self: *Self, iter: *[]const u8) !bool {
        if (!try self.cursor.extract(iter)) return false;
        var iter2 = iter.*;
        if (try cbor.matchValue(&iter2, cbor.null_)) {
            iter.* = iter2;
        } else {
            var sel: Selection = .{};
            if (!try sel.extract(iter)) return false;
            self.selection = sel;
        }
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

    fn deinit(self: *Diagnostic, a: std.mem.Allocator) void {
        a.free(self.source);
        a.free(self.code);
        a.free(self.message);
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

    a: Allocator,
    plane: Plane,
    logger: log.Logger,

    file_path: ?[]const u8,
    buffer: ?*Buffer,
    lsp_version: usize = 1,

    cursels: CurSel.List,
    cursels_saved: CurSel.List,
    selection_mode: SelectMode = .char,
    clipboard: ?[]const u8 = null,
    target_column: ?Cursor = null,
    filter: ?struct {
        before_root: Buffer.Root,
        work_root: Buffer.Root,
        begin: Cursor,
        pos: CurSel,
        old_primary: CurSel,
        old_primary_reversed: bool,
        whole_file: ?std.ArrayList(u8),
        bytes: usize = 0,
        chunks: usize = 0,
    } = null,
    matches: Match.List,
    match_token: usize = 0,
    match_done_token: usize = 0,
    last_find_query: ?[]const u8 = null,
    find_history: ?std.ArrayList([]const u8) = null,
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
    show_whitespace: bool,

    last: struct {
        root: ?Buffer.Root = null,
        primary: CurSel = CurSel.invalid(),
        view: View = View.invalid(),
        matches: usize = 0,
        cursels: usize = 0,
        dirty: bool = false,
    } = .{},

    syntax: ?*syntax = null,
    syntax_refresh_full: bool = false,
    syntax_token: usize = 0,

    style_cache: ?StyleCache = null,
    style_cache_theme: []const u8 = "",

    diagnostics: std.ArrayList(Diagnostic),
    diag_errors: usize = 0,
    diag_warnings: usize = 0,
    diag_info: usize = 0,
    diag_hints: usize = 0,

    const StyleCache = std.AutoHashMap(u32, ?Widget.Theme.Token);

    const Context = command.Context;
    const Result = command.Result;

    pub fn write_state(self: *const Self, writer: Buffer.MetaWriter) !void {
        try cbor.writeArrayHeader(writer, 6);
        try cbor.writeValue(writer, self.file_path orelse "");
        try cbor.writeValue(writer, self.clipboard orelse "");
        try cbor.writeValue(writer, self.last_find_query orelse "");
        if (self.find_history) |history| {
            try cbor.writeArrayHeader(writer, history.items.len);
            for (history.items) |item|
                try cbor.writeValue(writer, item);
        } else {
            try cbor.writeArrayHeader(writer, 0);
        }
        try self.view.write(writer);
        try self.get_primary().cursor.write(writer);
    }

    pub fn extract_state(self: *Self, buf: []const u8) !void {
        var file_path: []const u8 = undefined;
        var view_cbor: []const u8 = undefined;
        var primary_cbor: []const u8 = undefined;
        var clipboard: []const u8 = undefined;
        var query: []const u8 = undefined;
        var find_history: []const u8 = undefined;
        if (!try cbor.match(buf, .{
            tp.extract(&file_path),
            tp.extract(&clipboard),
            tp.extract(&query),
            tp.extract_cbor(&find_history),
            tp.extract_cbor(&view_cbor),
            tp.extract_cbor(&primary_cbor),
        }))
            return error.RestoreStateMatch;
        try self.open(file_path);
        self.clipboard = if (clipboard.len > 0) try self.a.dupe(u8, clipboard) else null;
        self.last_find_query = if (query.len > 0) try self.a.dupe(u8, clipboard) else null;
        if (!try self.view.extract(&view_cbor))
            return error.RestoreView;
        self.scroll_dest = self.view.row;
        if (!try self.get_primary().cursor.extract(&primary_cbor))
            return error.RestoreCursor;
        var len = cbor.decodeArrayHeader(&find_history) catch return error.RestoryFindHistory;
        while (len > 0) : (len -= 1) {
            var value: []const u8 = undefined;
            if (!(cbor.matchValue(&find_history, cbor.extract(&value)) catch return error.RestoryFindHistory))
                return error.RestoryFindHistory;
            self.push_find_history(value);
        }
    }

    fn init(self: *Self, a: Allocator, n: Plane) void {
        const logger = log.logger("editor");
        var frame_rate = tp.env.get().num("frame-rate");
        if (frame_rate == 0) frame_rate = 60;
        self.* = Self{
            .a = a,
            .plane = n,
            .logger = logger,
            .file_path = null,
            .buffer = null,
            .handlers = EventHandler.List.init(a),
            .animation_lag = get_animation_max_lag(),
            .animation_frame_rate = frame_rate,
            .animation_last_time = time.microTimestamp(),
            .cursels = CurSel.List.init(a),
            .cursels_saved = CurSel.List.init(a),
            .matches = Match.List.init(a),
            .enable_terminal_cursor = tui.current().config.enable_terminal_cursor,
            .show_whitespace = tui.current().config.show_whitespace,
            .diagnostics = std.ArrayList(Diagnostic).init(a),
        };
    }

    fn deinit(self: *Self) void {
        for (self.diagnostics.items) |*d| d.deinit(self.diagnostics.allocator);
        self.diagnostics.deinit();
        if (self.syntax) |syn| syn.destroy();
        self.cursels.deinit();
        self.matches.deinit();
        self.handlers.deinit();
        self.logger.deinit();
        if (self.buffer) |p| p.deinit();
    }

    fn need_render(_: *Self) void {
        Widget.need_render();
    }

    fn buf_for_update(self: *Self) !*const Buffer {
        self.cursels_saved.clearAndFree();
        self.cursels_saved = try self.cursels.clone();
        return if (self.buffer) |p| p else error.Stop;
    }

    fn buf_root(self: *const Self) !Buffer.Root {
        return if (self.buffer) |p| p.root else error.Stop;
    }

    fn buf_a(self: *const Self) !Allocator {
        return if (self.buffer) |p| p.a else error.Stop;
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

    pub fn is_dirty(self: *Self) bool {
        const b = if (self.buffer) |p| p else return false;
        return b.is_dirty();
    }

    fn open(self: *Self, file_path: []const u8) !void {
        var new_buf = try Buffer.create(self.a);
        errdefer new_buf.deinit();
        try new_buf.load_from_file_and_update(file_path);
        return self.open_buffer(file_path, new_buf);
    }

    fn open_scratch(self: *Self, file_path: []const u8, content: []const u8) !void {
        var new_buf = try Buffer.create(self.a);
        errdefer new_buf.deinit();
        try new_buf.load_from_string_and_update(file_path, content);
        new_buf.file_exists = true;
        return self.open_buffer(file_path, new_buf);
    }

    fn open_buffer(self: *Self, file_path: []const u8, new_buf: *Buffer) !void {
        errdefer new_buf.deinit();
        self.cancel_all_selections();
        self.get_primary().reset();
        self.file_path = try self.a.dupe(u8, file_path);
        if (self.buffer) |_| try self.close();
        self.buffer = new_buf;

        self.syntax = if (tp.env.get().is("no-syntax")) null else syntax: {
            if (new_buf.root.lines() > root_mod.max_syntax_lines)
                break :syntax null;
            const lang_override = tp.env.get().str("language");
            var content = std.ArrayList(u8).init(self.a);
            defer content.deinit();
            try new_buf.root.store(content.writer());
            const syn = if (lang_override.len > 0)
                syntax.create_file_type(self.a, content.items, lang_override) catch null
            else
                syntax.create_guess_file_type(self.a, content.items, self.file_path) catch null;
            if (syn) |syn_|
                project_manager.did_open(file_path, syn_.file_type, self.lsp_version, try content.toOwnedSlice()) catch {};
            break :syntax syn;
        };

        const ftn = if (self.syntax) |syn| syn.file_type.name else "text";
        const fti = if (self.syntax) |syn| syn.file_type.icon else "🖹";
        const ftc = if (self.syntax) |syn| syn.file_type.color else 0x000000;
        try self.send_editor_open(file_path, new_buf.file_exists, ftn, fti, ftc);
    }

    fn close(self: *Self) !void {
        return self.close_internal(false);
    }

    fn close_dirty(self: *Self) !void {
        return self.close_internal(true);
    }

    fn close_internal(self: *Self, allow_dirty_close: bool) !void {
        const b = if (self.buffer) |p| p else return error.Stop;
        if (!allow_dirty_close and b.is_dirty()) return tp.exit("unsaved changes");
        if (self.buffer) |b_mut| b_mut.deinit();
        self.buffer = null;
        self.plane.erase();
        self.plane.home();
        tui.current().rdr.cursor_disable();
        _ = try self.handlers.msg(.{ "E", "close" });
        if (self.syntax) |_| if (self.file_path) |file_path|
            project_manager.did_close(file_path) catch {};
    }

    fn save(self: *Self) !void {
        const b = if (self.buffer) |p| p else return error.Stop;
        if (!b.is_dirty()) return tp.exit("no changes to save");
        if (self.file_path) |file_path| {
            if (self.buffer) |b_mut| try b_mut.store_to_file_and_clean(file_path);
        } else return error.SaveNoFileName;
        try self.send_editor_save(self.file_path.?);
        self.last.dirty = false;
    }

    pub fn push_cursor(self: *Self) !void {
        const primary = if (self.cursels.getLastOrNull()) |c| c orelse CurSel{} else CurSel{};
        (try self.cursels.addOne()).* = primary;
    }

    pub fn pop_cursor(self: *Self, _: Context) Result {
        if (self.cursels.items.len > 1) {
            const cursel = self.cursels.popOrNull() orelse return orelse return;
            if (cursel.selection) |sel| if (self.find_selection_match(sel)) |match| {
                match.has_selection = false;
            };
        }
        self.clamp();
    }

    pub fn get_primary(self: *const Self) *CurSel {
        var idx = self.cursels.items.len;
        while (idx > 0) : (idx -= 1)
            if (self.cursels.items[idx - 1]) |*primary|
                return primary;
        if (idx == 0) {
            self.logger.print("ERROR: no more cursors", .{});
            (@constCast(self).cursels.addOne() catch |e| switch (e) {
                error.OutOfMemory => @panic("get_primary error.OutOfMemory"),
            }).* = CurSel{};
        }
        return self.get_primary();
    }

    fn store_undo_meta(self: *Self, a: Allocator) ![]u8 {
        var meta = std.ArrayList(u8).init(a);
        const writer = meta.writer();
        for (self.cursels_saved.items) |*cursel_| if (cursel_.*) |*cursel|
            try cursel.write(writer);
        return meta.toOwnedSlice();
    }

    fn store_current_undo_meta(self: *Self, a: Allocator) ![]u8 {
        var meta = std.ArrayList(u8).init(a);
        const writer = meta.writer();
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel|
            try cursel.write(writer);
        return meta.toOwnedSlice();
    }

    fn update_buf(self: *Self, root: Buffer.Root) !void {
        const b = if (self.buffer) |p| p else return error.Stop;
        var sfa = std.heap.stackFallback(512, self.a);
        const a = sfa.get();
        const meta = try self.store_undo_meta(a);
        defer a.free(meta);
        try b.store_undo(meta);
        b.update(root);
        try self.send_editor_modified();
    }

    fn restore_undo_redo_meta(self: *Self, meta: []const u8) !void {
        if (meta.len > 0)
            self.clear_all_cursors();
        var iter = meta;
        while (iter.len > 0) {
            var cursel: CurSel = .{};
            if (!try cursel.extract(&iter)) return error.SyntaxError;
            (try self.cursels.addOne()).* = cursel;
        }
    }

    fn restore_undo(self: *Self) !void {
        if (self.buffer) |b_mut| {
            try self.send_editor_jump_source();
            self.cancel_all_matches();
            var sfa = std.heap.stackFallback(512, self.a);
            const a = sfa.get();
            const redo_meta = try self.store_current_undo_meta(a);
            defer a.free(redo_meta);
            const meta = b_mut.undo(redo_meta) catch |e| switch (e) {
                error.Stop => {
                    self.logger.print("nothing to undo", .{});
                    return;
                },
                else => return e,
            };
            try self.restore_undo_redo_meta(meta);
            try self.send_editor_jump_destination();
            self.reset_syntax();
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
            self.reset_syntax();
        }
    }

    fn find_first_non_ws(root: Buffer.Root, row: usize, plane: Plane) usize {
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
        root.walk_egc_forward(row, Ctx.walker, &ctx, plane.metrics()) catch return 0;
        return ctx.col;
    }

    fn write_range(
        self: *const Self,
        root: Buffer.Root,
        sel: Selection,
        writer: anytype,
        map_error: fn (e: anyerror, stack_trace: ?*std.builtin.StackTrace) @TypeOf(writer).Error,
        wcwidth_: ?*usize,
        plane_: Plane,
    ) @TypeOf(writer).Error!void {
        _ = self;
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
        root.walk_egc_forward(sel.begin.row, Ctx.walker, &ctx, plane_.metrics()) catch |e| return map_error(e, @errorReturnTrace());
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
                self.style_cache = StyleCache.init(self.a);
                // self.logger.print("style_cache reset {s} -> {s}", .{ self.style_cache_theme, theme.name });
            }
        } else {
            self.style_cache = StyleCache.init(self.a);
        }
        self.style_cache_theme = theme.name;
        const cache: *StyleCache = &self.style_cache.?;
        self.render_screen(theme, cache);
        return self.scroll_dest != self.view.row;
    }

    fn render_screen(self: *Self, theme: *const Widget.Theme, cache: *StyleCache) void {
        const ctx = struct {
            self: *Self,
            buf_row: usize,
            buf_col: usize = 0,
            match_idx: usize = 0,
            theme: *const Widget.Theme,
            hl_row: ?usize,

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
                    const ptr = self_.a.allocSentinel(u8, len, 0) catch |e| return Buffer.Walker{ .err = e };
                    chunk_alloc = ptr;
                    break :ret ptr;
                } else &bufstatic;
                defer if (chunk_alloc) |p| self_.a.free(p);

                @memcpy(chunk[0..leaf.buf.len], leaf.buf);
                chunk[leaf.buf.len] = 0;
                chunk.len = leaf.buf.len;

                while (chunk.len > 0) {
                    if (ctx.buf_col >= view.col + view.cols)
                        break;
                    var cell = n.cell_init();
                    const c = &cell;
                    const bytes, const colcount = switch (chunk[0]) {
                        0...8, 10...31 => |code| ctx.self.render_control_code(c, n, code, ctx.theme),
                        32 => ctx.self.render_space(c, n, ctx.theme),
                        9 => ctx.self.render_tab(c, n, ctx.buf_col, ctx.theme),
                        else => render_egc(c, n, chunk),
                    };
                    if (ctx.hl_row) |hl_row| if (hl_row == ctx.buf_row)
                        self_.render_line_highlight_cell(ctx.theme, c);
                    self_.render_matches(&ctx.match_idx, ctx.theme, c);
                    self_.render_selections(ctx.theme, c);

                    const advanced = if (ctx.buf_col >= view.col) n.putc(c) catch break else colcount;
                    const new_col = ctx.buf_col + colcount - advanced;
                    if (ctx.buf_col < view.col and ctx.buf_col + advanced > view.col)
                        n.cursor_move_rel(0, @intCast(ctx.buf_col + advanced - view.col)) catch {};
                    ctx.buf_col += advanced;

                    while (ctx.buf_col < new_col) {
                        if (ctx.buf_col >= view.col + view.cols)
                            break;
                        var cell_ = n.cell_init();
                        const c_ = &cell_;
                        if (ctx.hl_row) |hl_row| if (hl_row == ctx.buf_row)
                            self_.render_line_highlight_cell(ctx.theme, c_);
                        self_.render_matches(&ctx.match_idx, ctx.theme, c_);
                        self_.render_selections(ctx.theme, c_);
                        const advanced_ = n.putc(c_) catch break;
                        ctx.buf_col += advanced_;
                    }
                    chunk = chunk[bytes..];
                }

                if (leaf.eol) {
                    var c = ctx.self.render_eol(n, ctx.theme);
                    if (ctx.hl_row) |hl_row| if (hl_row == ctx.buf_row)
                        self_.render_line_highlight_cell(ctx.theme, &c);
                    self_.render_matches(&ctx.match_idx, ctx.theme, &c);
                    self_.render_selections(ctx.theme, &c);
                    _ = n.putc(&c) catch {};
                    var term_cell = render_terminator(n, ctx.theme);
                    if (ctx.hl_row) |hl_row| if (hl_row == ctx.buf_row)
                        self_.render_line_highlight_cell(ctx.theme, &term_cell);
                    _ = n.putc(&term_cell) catch {};
                    n.cursor_move_yx(-1, 0) catch |e| return Buffer.Walker{ .err = e };
                    n.cursor_move_rel(1, 0) catch |e| return Buffer.Walker{ .err = e };
                    ctx.buf_row += 1;
                    ctx.buf_col = 0;
                }
                return Buffer.Walker.keep_walking;
            }
        };
        const hl_row: ?usize = if (tui.current().config.highlight_current_line) self.get_primary().cursor.row else null;
        var ctx_: ctx = .{ .self = self, .buf_row = self.view.row, .theme = theme, .hl_row = hl_row };
        const root = self.buf_root() catch return;

        {
            const frame = tracy.initZone(@src(), .{ .name = "editor render screen" });
            defer frame.deinit();

            self.plane.set_base_style(" ", theme.editor);
            self.plane.erase();
            if (hl_row) |_|
                self.render_line_highlight(&self.get_primary().cursor, theme) catch {};
            self.plane.home();
            _ = root.walk_from_line_begin_const(self.view.row, ctx.walker, &ctx_, self.plane.metrics()) catch {};
        }
        self.render_syntax(theme, cache, root) catch {};
        self.render_diagnostics(theme, hl_row) catch {};
        self.render_cursors(theme) catch {};
    }

    fn render_terminal_cursor(self: *const Self, cursor_: *const Cursor) !void {
        if (self.screen_cursor(cursor_)) |cursor| {
            const y, const x = self.plane.rel_yx_to_abs(@intCast(cursor.row), @intCast(cursor.col));
            tui.current().rdr.cursor_enable(y, x) catch {};
        } else {
            tui.current().rdr.cursor_disable();
        }
    }

    fn render_cursors(self: *Self, theme: *const Widget.Theme) !void {
        const frame = tracy.initZone(@src(), .{ .name = "editor render cursors" });
        defer frame.deinit();
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel|
            try self.render_cursor(&cursel.cursor, theme);
        if (self.enable_terminal_cursor)
            try self.render_terminal_cursor(&self.get_primary().cursor);
    }

    fn render_cursor(self: *Self, cursor: *const Cursor, theme: *const Widget.Theme) !void {
        if (self.screen_cursor(cursor)) |pos| {
            self.plane.cursor_move_yx(@intCast(pos.row), @intCast(pos.col)) catch return;
            self.render_cursor_cell(theme);
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

    fn render_diagnostics(self: *Self, theme: *const Widget.Theme, hl_row: ?usize) !void {
        for (self.diagnostics.items) |*diag| self.render_diagnostic(diag, theme, hl_row);
    }

    fn render_diagnostic(self: *Self, diag: *const Diagnostic, theme: *const Widget.Theme, hl_row: ?usize) void {
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
        const space_begin = get_line_end_space_begin(&self.plane, screen_width, pos.row);
        if (space_begin < screen_width) {
            self.render_diagnostic_message(diag.message, pos.row, screen_width - space_begin, style);
        }
    }

    fn get_line_end_space_begin(plane: *Plane, screen_width: usize, screen_row: usize) usize {
        var pos = screen_width;
        var cell = plane.cell_init();
        while (pos > 0) : (pos -= 1) {
            plane.cursor_move_yx(@intCast(screen_row), @intCast(pos - 1)) catch return pos;
            const cell_egc_bytes = plane.at_cursor_cell(&cell) catch return pos;
            if (cell_egc_bytes > 0) return pos;
        }
        return pos;
    }

    fn render_diagnostic_message(self: *Self, message: []const u8, y: usize, max_space: usize, style: Widget.Theme.Style) void {
        self.plane.set_style(style);
        _ = self.plane.print_aligned_right(@intCast(y), "{s}", .{message[0..@min(max_space, message.len)]}) catch {};
    }

    inline fn render_diagnostic_cell(self: *Self, style: Widget.Theme.Style) void {
        var cell = self.plane.cell_init();
        _ = self.plane.at_cursor_cell(&cell) catch return;
        cell.set_style(.{ .fs = .undercurl });
        if (style.fg) |ul_col| cell.set_under_color(ul_col);
        _ = self.plane.putc(&cell) catch {};
    }

    inline fn render_cursor_cell(self: *Self, theme: *const Widget.Theme) void {
        var cell = self.plane.cell_init();
        _ = self.plane.at_cursor_cell(&cell) catch return;
        cell.set_style(theme.editor_cursor);
        _ = self.plane.putc(&cell) catch {};
    }

    inline fn render_selection_cell(_: *const Self, theme: *const Widget.Theme, cell: *Cell) void {
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
        if (self.show_whitespace)
            c.set_style(theme.editor_whitespace);
        _ = n.cell_load(c, val) catch {};
        return .{ 1, 1 };
    }

    inline fn render_eol(self: *const Self, n: *Plane, theme: *const Widget.Theme) Cell {
        var cell = n.cell_init();
        const c = &cell;
        if (self.show_whitespace) {
            c.set_style(theme.editor_whitespace);
            //_ = n.cell_load(c, "$") catch {};
            //_ = n.cell_load(c, " ") catch {};
            //_ = n.cell_load(c, "⏎") catch {};
            // _ = n.cell_load(c, "󰌑") catch {};
            _ = n.cell_load(c, "↩") catch {};
            //_ = n.cell_load(c, "↲") catch {};
            //_ = n.cell_load(c, "⤶") catch {};
            //_ = n.cell_load(c, "󱞱") catch {};
            //_ = n.cell_load(c, "󱞲") catch {};
            //_ = n.cell_load(c, "⤦") catch {};
            //_ = n.cell_load(c, "¬") catch {};
            //_ = n.cell_load(c, "␤") catch {};
            //_ = n.cell_load(c, "❯") catch {};
            //_ = n.cell_load(c, "❮") catch {};
        } else {
            _ = n.cell_load(c, " ") catch {};
        }
        return cell;
    }

    inline fn render_terminator(n: *Plane, theme: *const Widget.Theme) Cell {
        var cell = n.cell_init();
        cell.set_style(theme.editor);
        _ = n.cell_load(&cell, "\u{2003}") catch unreachable;
        return cell;
    }

    inline fn render_space(self: *const Self, c: *Cell, n: *Plane, theme: *const Widget.Theme) struct { usize, usize } {
        if (self.show_whitespace) {
            c.set_style(theme.editor_whitespace);
            _ = n.cell_load(c, "·") catch {};
            //_ = n.cell_load(c, "•") catch {};
            //_ = n.cell_load(c, "⁃") catch {};
            //_ = n.cell_load(c, " ") catch {};
            //_ = n.cell_load(c, "_") catch {};
            //_ = n.cell_load(c, "󱁐") catch {};
            //_ = n.cell_load(c, "⎵") catch {};
            //_ = n.cell_load(c, "‿") catch {};
            //_ = n.cell_load(c, "_") catch {};
            //_ = n.cell_load(c, " ") catch {};
            //_ = n.cell_load(c, "〿") catch {};
            //_ = n.cell_load(c, "␠") catch {};
        } else {
            _ = n.cell_load(c, " ") catch {};
        }
        return .{ 1, 1 };
    }

    inline fn render_tab(self: *const Self, c: *Cell, n: *Plane, abs_col: usize, theme: *const Widget.Theme) struct { usize, usize } {
        if (self.show_whitespace) {
            c.set_style(theme.editor_whitespace);
            _ = n.cell_load(c, "→") catch {};
            //_ = n.cell_load(c, "⭲") catch {};
        } else {
            _ = n.cell_load(c, " ") catch {};
        }
        return .{ 1, 9 - (abs_col % 8) };
    }

    inline fn render_egc(c: *Cell, n: *Plane, egc: [:0]const u8) struct { usize, usize } {
        const bytes = n.cell_load(c, egc) catch return .{ 1, 1 };
        const colcount = c.columns();
        return .{ bytes, colcount };
    }

    fn render_syntax(self: *Self, theme: *const Widget.Theme, cache: *StyleCache, root: Buffer.Root) !void {
        const frame = tracy.initZone(@src(), .{ .name = "editor render syntax" });
        defer frame.deinit();
        const syn = if (self.syntax) |syn| syn else return;
        const Ctx = struct {
            self: *Self,
            theme: *const Widget.Theme,
            cache: *StyleCache,
            last_row: usize = std.math.maxInt(usize),
            last_col: usize = std.math.maxInt(usize),
            root: Buffer.Root,
            pos_cache: PosToWidthCache,
            fn cb(ctx: *@This(), range: syntax.Range, scope: []const u8, id: u32, _: usize, _: *const syntax.Node) error{Stop}!void {
                const sel_ = ctx.pos_cache.range_to_selection(range, ctx.root, ctx.self.plane) orelse return;
                defer {
                    ctx.last_row = sel_.begin.row;
                    ctx.last_col = sel_.begin.col;
                }
                if (ctx.last_row == sel_.begin.row and sel_.begin.col <= ctx.last_col)
                    return;

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
            .pos_cache = try PosToWidthCache.init(self.a),
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
        if (token_from(self.last.root) != token_from(root)) {
            try self.send_editor_update(self.last.root, root);
            self.lsp_version += 1;
        }

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

        if (!primary.cursor.eql(self.last.primary.cursor))
            try self.send_editor_pos(&primary.cursor);

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

        if (!self.view.eql(self.last.view))
            try self.send_editor_view();

        self.last.view = self.view;
        self.last.primary = primary.*;
        self.last.dirty = dirty;
        self.last.root = root;
    }

    fn send_editor_pos(self: *const Self, cursor: *const Cursor) !void {
        const root = self.buf_root() catch return error.Stop;
        _ = try self.handlers.msg(.{ "E", "pos", root.lines(), cursor.row, cursor.col });
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

    fn send_editor_view(self: *const Self) !void {
        const root = self.buf_root() catch return error.Stop;
        _ = try self.handlers.msg(.{ "E", "view", root.lines(), self.view.rows, self.view.row });
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

    fn send_editor_update(self: *const Self, old_root: ?Buffer.Root, new_root: ?Buffer.Root) !void {
        _ = try self.handlers.msg(.{ "E", "update", token_from(new_root), token_from(old_root) });
        if (self.syntax) |_| if (self.file_path) |file_path| if (old_root != null and new_root != null)
            project_manager.did_change(file_path, self.lsp_version, token_from(new_root), token_from(old_root)) catch {};
    }

    fn clamp_abs(self: *Self, abs: bool) void {
        var dest: View = self.view;
        dest.clamp(&self.get_primary().cursor, abs);
        self.update_scroll_dest_abs(dest.row);
        self.view.col = dest.col;
    }

    inline fn clamp(self: *Self) void {
        self.clamp_abs(false);
    }

    fn clamp_mouse(self: *Self) void {
        self.clamp_abs(true);
    }

    fn clear_all_cursors(self: *Self) void {
        self.cursels.clearRetainingCapacity();
    }

    fn collapse_cursors(self: *Self) void {
        const frame = tracy.initZone(@src(), .{ .name = "collapse cursors" });
        defer frame.deinit();
        var old = self.cursels;
        defer old.deinit();
        self.cursels = CurSel.List.initCapacity(self.a, old.items.len) catch return;
        for (old.items[0 .. old.items.len - 1], 0..) |*a_, i| if (a_.*) |*a| {
            for (old.items[i + 1 ..], i + 1..) |*b_, j| if (b_.*) |*b| {
                if (a.cursor.eql(b.cursor))
                    old.items[j] = null;
            };
        };
        for (old.items) |*item_| if (item_.*) |*item| {
            (self.cursels.addOne() catch return).* = item.*;
        };
    }

    fn cancel_all_selections(self: *Self) void {
        var primary = if (self.cursels.getLast()) |p| p else CurSel{};
        primary.selection = null;
        self.cursels.clearRetainingCapacity();
        self.cursels.addOneAssumeCapacity().* = primary;
        for (self.matches.items) |*match_| if (match_.*) |*match| {
            match.has_selection = false;
        };
    }

    fn cancel_all_matches(self: *Self) void {
        self.matches.clearAndFree();
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

    fn with_cursor_const(root: Buffer.Root, move: cursor_operator_const, cursel: *CurSel, plane: Plane) error{Stop}!void {
        try move(root, &cursel.cursor, plane);
    }

    fn with_cursors_const(self: *Self, root: Buffer.Root, move: cursor_operator_const) error{Stop}!void {
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            cursel.selection = null;
            try with_cursor_const(root, move, cursel, self.plane);
        };
        self.collapse_cursors();
    }

    fn with_cursor_const_arg(root: Buffer.Root, move: cursor_operator_const_arg, cursel: *CurSel, ctx: Context, plane: Plane) error{Stop}!void {
        try move(root, &cursel.cursor, ctx, plane);
    }

    fn with_cursors_const_arg(self: *Self, root: Buffer.Root, move: cursor_operator_const_arg, ctx: Context) error{Stop}!void {
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            cursel.selection = null;
            try with_cursor_const_arg(root, move, cursel, ctx, self.plane);
        };
        self.collapse_cursors();
    }

    fn with_cursor_and_view_const(root: Buffer.Root, move: cursor_view_operator_const, cursel: *CurSel, view: *const View, plane: Plane) error{Stop}!void {
        try move(root, &cursel.cursor, view, plane);
    }

    fn with_cursors_and_view_const(self: *Self, root: Buffer.Root, move: cursor_view_operator_const, view: *const View) error{Stop}!void {
        var someone_stopped = false;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel|
            with_cursor_and_view_const(root, move, cursel, view, self.plane) catch {
                someone_stopped = true;
            };
        self.collapse_cursors();
        return if (someone_stopped) error.Stop else {};
    }

    fn with_cursor(root: Buffer.Root, move: cursor_operator, cursel: *CurSel, a: Allocator) error{Stop}!Buffer.Root {
        return try move(root, &cursel.cursor, a);
    }

    fn with_cursors(self: *Self, root_: Buffer.Root, move: cursor_operator, a: Allocator) error{Stop}!Buffer.Root {
        var root = root_;
        for (self.cursels.items) |*cursel| {
            cursel.selection = null;
            root = try with_cursor(root, move, cursel, a);
        }
        self.collapse_cursors();
        return root;
    }

    fn with_selection_const(root: Buffer.Root, move: cursor_operator_const, cursel: *CurSel, plane: Plane) error{Stop}!void {
        const sel = cursel.enable_selection();
        try move(root, &sel.end, plane);
        cursel.cursor = sel.end;
        cursel.check_selection();
    }

    fn with_selections_const(self: *Self, root: Buffer.Root, move: cursor_operator_const) error{Stop}!void {
        var someone_stopped = false;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel|
            with_selection_const(root, move, cursel, self.plane) catch {
                someone_stopped = true;
            };
        self.collapse_cursors();
        return if (someone_stopped) error.Stop else {};
    }

    fn with_selection_const_arg(root: Buffer.Root, move: cursor_operator_const_arg, cursel: *CurSel, ctx: Context, plane: Plane) error{Stop}!void {
        const sel = cursel.enable_selection();
        try move(root, &sel.end, ctx, plane);
        cursel.cursor = sel.end;
        cursel.check_selection();
    }

    fn with_selections_const_arg(self: *Self, root: Buffer.Root, move: cursor_operator_const_arg, ctx: Context) error{Stop}!void {
        var someone_stopped = false;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel|
            with_selection_const_arg(root, move, cursel, ctx, self.plane) catch {
                someone_stopped = true;
            };
        self.collapse_cursors();
        return if (someone_stopped) error.Stop else {};
    }

    fn with_selection_and_view_const(root: Buffer.Root, move: cursor_view_operator_const, cursel: *CurSel, view: *const View, plane: Plane) error{Stop}!void {
        const sel = cursel.enable_selection();
        try move(root, &sel.end, view, plane);
        cursel.cursor = sel.end;
    }

    fn with_selections_and_view_const(self: *Self, root: Buffer.Root, move: cursor_view_operator_const, view: *const View) error{Stop}!void {
        var someone_stopped = false;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel|
            with_selection_and_view_const(root, move, cursel, view, self.plane) catch {
                someone_stopped = true;
            };
        self.collapse_cursors();
        return if (someone_stopped) error.Stop else {};
    }

    fn with_cursel(root: Buffer.Root, op: cursel_operator, cursel: *CurSel, a: Allocator) error{Stop}!Buffer.Root {
        return op(root, cursel, a);
    }

    fn with_cursels(self: *Self, root_: Buffer.Root, move: cursel_operator, a: Allocator) error{Stop}!Buffer.Root {
        var root = root_;
        var someone_stopped = false;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            root = with_cursel(root, move, cursel, a) catch ret: {
                someone_stopped = true;
                break :ret root;
            };
        };
        self.collapse_cursors();
        return if (someone_stopped) error.Stop else root;
    }

    fn with_cursel_mut(self: *Self, root: Buffer.Root, op: cursel_operator_mut, cursel: *CurSel, a: Allocator) error{Stop}!Buffer.Root {
        return op(self, root, cursel, a);
    }

    fn with_cursels_mut(self: *Self, root_: Buffer.Root, move: cursel_operator_mut, a: Allocator) error{Stop}!Buffer.Root {
        var root = root_;
        var someone_stopped = false;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            root = self.with_cursel_mut(root, move, cursel, a) catch ret: {
                someone_stopped = true;
                break :ret root;
            };
        };
        self.collapse_cursors();
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

    fn nudge_insert(self: *Self, nudge: Selection, exclude: *const CurSel, size: usize) void {
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel|
            if (cursel != exclude)
                cursel.nudge_insert(nudge);
        for (self.matches.items) |*match_| if (match_.*) |*match|
            match.nudge_insert(nudge);
        if (self.syntax) |syn| {
            const root = self.buf_root() catch return;
            const start_byte = root.get_byte_pos(nudge.begin, self.plane.metrics()) catch return;
            syn.edit(.{
                .start_byte = @intCast(start_byte),
                .old_end_byte = @intCast(start_byte),
                .new_end_byte = @intCast(start_byte + size),
                .start_point = .{ .row = @intCast(nudge.begin.row), .column = @intCast(nudge.begin.col) },
                .old_end_point = .{ .row = @intCast(nudge.begin.row), .column = @intCast(nudge.begin.col) },
                .new_end_point = .{ .row = @intCast(nudge.end.row), .column = @intCast(nudge.end.col) },
            });
        }
    }

    fn nudge_delete(self: *Self, nudge: Selection, exclude: *const CurSel, size: usize) void {
        for (self.cursels.items, 0..) |*cursel_, i| if (cursel_.*) |*cursel|
            if (cursel != exclude)
                if (!cursel.nudge_delete(nudge)) {
                    self.cursels.items[i] = null;
                };
        for (self.matches.items, 0..) |*match_, i| if (match_.*) |*match|
            if (!match.nudge_delete(nudge)) {
                self.matches.items[i] = null;
            };
        if (self.syntax) |syn| {
            const root = self.buf_root() catch return;
            const start_byte = root.get_byte_pos(nudge.begin, self.plane.metrics()) catch return;
            syn.edit(.{
                .start_byte = @intCast(start_byte),
                .old_end_byte = @intCast(start_byte + size),
                .new_end_byte = @intCast(start_byte),
                .start_point = .{ .row = @intCast(nudge.begin.row), .column = @intCast(nudge.begin.col) },
                .old_end_point = .{ .row = @intCast(nudge.end.row), .column = @intCast(nudge.end.col) },
                .new_end_point = .{ .row = @intCast(nudge.begin.row), .column = @intCast(nudge.begin.col) },
            });
        }
    }

    fn delete_selection(self: *Self, root: Buffer.Root, cursel: *CurSel, a: Allocator) error{Stop}!Buffer.Root {
        var sel: Selection = if (cursel.selection) |sel| sel else return error.Stop;
        sel.normalize();
        cursel.cursor = sel.begin;
        cursel.selection = null;
        var size: usize = 0;
        const root_ = try root.delete_range(sel, a, &size, self.plane.metrics());
        self.nudge_delete(sel, cursel, size);
        return root_;
    }

    fn delete_to(self: *Self, move: cursor_operator_const, root_: Buffer.Root, a: Allocator) error{Stop}!Buffer.Root {
        var all_stop = true;
        var root = root_;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            if (cursel.selection) |_| {
                root = self.delete_selection(root, cursel, a) catch continue;
                all_stop = false;
                continue;
            }
            with_selection_const(root, move, cursel, self.plane) catch continue;
            root = self.delete_selection(root, cursel, a) catch continue;
            all_stop = false;
        };

        if (all_stop)
            return error.Stop;
        return root;
    }

    const cursor_predicate = *const fn (root: Buffer.Root, cursor: *Cursor, plane: Plane) bool;
    const cursor_operator_const = *const fn (root: Buffer.Root, cursor: *Cursor, plane: Plane) error{Stop}!void;
    const cursor_operator_const_arg = *const fn (root: Buffer.Root, cursor: *Cursor, ctx: Context, plane: Plane) error{Stop}!void;
    const cursor_view_operator_const = *const fn (root: Buffer.Root, cursor: *Cursor, view: *const View, plane: Plane) error{Stop}!void;
    const cursel_operator_const = *const fn (root: Buffer.Root, cursel: *CurSel) error{Stop}!void;
    const cursor_operator = *const fn (root: Buffer.Root, cursor: *Cursor, a: Allocator) error{Stop}!Buffer.Root;
    const cursel_operator = *const fn (root: Buffer.Root, cursel: *CurSel, a: Allocator) error{Stop}!Buffer.Root;
    const cursel_operator_mut = *const fn (self: *Self, root: Buffer.Root, cursel: *CurSel, a: Allocator) error{Stop}!Buffer.Root;

    fn is_not_word_char(c: []const u8) bool {
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
            '?' => true,
            '&' => true,
            else => false,
        };
    }

    fn is_word_char(c: []const u8) bool {
        return !is_not_word_char(c);
    }

    fn is_word_char_at_cursor(root: Buffer.Root, cursor: *const Cursor, plane: Plane) bool {
        return cursor.test_at(root, is_word_char, plane.metrics());
    }

    fn is_non_word_char_at_cursor(root: Buffer.Root, cursor: *const Cursor, plane: Plane) bool {
        return cursor.test_at(root, is_not_word_char, plane.metrics());
    }

    fn is_word_boundary_left(root: Buffer.Root, cursor: *const Cursor, plane: Plane) bool {
        if (cursor.col == 0)
            return true;
        if (is_non_word_char_at_cursor(root, cursor, plane))
            return false;
        var next = cursor.*;
        next.move_left(root, plane.metrics()) catch return true;
        if (is_non_word_char_at_cursor(root, &next, plane))
            return true;
        return false;
    }

    fn is_non_word_boundary_left(root: Buffer.Root, cursor: *const Cursor, plane: Plane) bool {
        if (cursor.col == 0)
            return true;
        if (is_word_char_at_cursor(root, cursor, plane))
            return false;
        var next = cursor.*;
        next.move_left(root, plane.metrics()) catch return true;
        if (is_word_char_at_cursor(root, &next, plane))
            return true;
        return false;
    }

    fn is_word_boundary_right(root: Buffer.Root, cursor: *const Cursor, plane: Plane) bool {
        const line_width = root.line_width(cursor.row, plane.metrics()) catch return true;
        if (cursor.col >= line_width)
            return true;
        if (is_non_word_char_at_cursor(root, cursor, plane))
            return false;
        var next = cursor.*;
        next.move_right(root, plane.metrics()) catch return true;
        if (is_non_word_char_at_cursor(root, &next, plane))
            return true;
        return false;
    }

    fn is_non_word_boundary_right(root: Buffer.Root, cursor: *const Cursor, plane: Plane) bool {
        const line_width = root.line_width(cursor.row, plane.metrics()) catch return true;
        if (cursor.col >= line_width)
            return true;
        if (is_word_char_at_cursor(root, cursor, plane))
            return false;
        var next = cursor.*;
        next.move_right(root, plane.metrics()) catch return true;
        if (is_word_char_at_cursor(root, &next, plane))
            return true;
        return false;
    }

    fn is_eol_left(_: Buffer.Root, cursor: *const Cursor, _: Plane) bool {
        if (cursor.col == 0)
            return true;
        return false;
    }

    fn is_eol_right(root: Buffer.Root, cursor: *const Cursor, plane: Plane) bool {
        const line_width = root.line_width(cursor.row, plane.metrics()) catch return true;
        if (cursor.col >= line_width)
            return true;
        return false;
    }

    fn is_eol_right_vim(root: Buffer.Root, cursor: *const Cursor, plane: Plane) bool {
        const line_width = root.line_width(cursor.row, plane.metrics()) catch return true;
        if (line_width == 0) return true;
        if (cursor.col >= line_width - 1)
            return true;
        return false;
    }

    fn move_cursor_left(root: Buffer.Root, cursor: *Cursor, plane: Plane) error{Stop}!void {
        try cursor.move_left(root, plane.metrics());
    }

    fn move_cursor_left_until(root: Buffer.Root, cursor: *Cursor, pred: cursor_predicate, plane: Plane) void {
        while (!pred(root, cursor, plane))
            move_cursor_left(root, cursor, plane) catch return;
    }

    fn move_cursor_left_unless(root: Buffer.Root, cursor: *Cursor, pred: cursor_predicate, plane: Plane) void {
        if (!pred(root, cursor, plane))
            move_cursor_left(root, cursor, plane) catch return;
    }

    fn move_cursor_begin(_: Buffer.Root, cursor: *Cursor, _: Plane) !void {
        cursor.move_begin();
    }

    fn smart_move_cursor_begin(root: Buffer.Root, cursor: *Cursor, plane: Plane) !void {
        const first = find_first_non_ws(root, cursor.row, plane);
        return if (cursor.col == first) cursor.move_begin() else cursor.move_to(root, cursor.row, first, plane.metrics());
    }

    fn move_cursor_right(root: Buffer.Root, cursor: *Cursor, plane: Plane) error{Stop}!void {
        try cursor.move_right(root, plane.metrics());
    }

    fn move_cursor_right_until(root: Buffer.Root, cursor: *Cursor, pred: cursor_predicate, plane: Plane) void {
        while (!pred(root, cursor, plane))
            move_cursor_right(root, cursor, plane) catch return;
    }

    fn move_cursor_right_unless(root: Buffer.Root, cursor: *Cursor, pred: cursor_predicate, plane: Plane) void {
        if (!pred(root, cursor, plane))
            move_cursor_right(root, cursor, plane) catch return;
    }

    fn move_cursor_end(root: Buffer.Root, cursor: *Cursor, plane: Plane) !void {
        cursor.move_end(root, plane.metrics());
    }

    fn move_cursor_up(root: Buffer.Root, cursor: *Cursor, plane: Plane) !void {
        try cursor.move_up(root, plane.metrics());
    }

    fn move_cursor_down(root: Buffer.Root, cursor: *Cursor, plane: Plane) !void {
        try cursor.move_down(root, plane.metrics());
    }

    fn move_cursor_buffer_begin(_: Buffer.Root, cursor: *Cursor, _: Plane) !void {
        cursor.move_buffer_begin();
    }

    fn move_cursor_buffer_end(root: Buffer.Root, cursor: *Cursor, plane: Plane) !void {
        cursor.move_buffer_end(root, plane.metrics());
    }

    fn move_cursor_page_up(root: Buffer.Root, cursor: *Cursor, view: *const View, plane: Plane) !void {
        cursor.move_page_up(root, view, plane.metrics());
    }

    fn move_cursor_page_down(root: Buffer.Root, cursor: *Cursor, view: *const View, plane: Plane) !void {
        cursor.move_page_down(root, view, plane.metrics());
    }

    pub fn primary_click(self: *Self, y: c_int, x: c_int) !void {
        if (self.fast_scroll)
            try self.push_cursor()
        else
            self.cancel_all_selections();
        const primary = self.get_primary();
        primary.selection = null;
        self.selection_mode = .char;
        try self.send_editor_jump_source();
        const root = self.buf_root() catch return;
        primary.cursor.move_abs(root, &self.view, @intCast(y), @intCast(x), self.plane.metrics()) catch return;
        self.clamp_mouse();
        try self.send_editor_jump_destination();
        if (self.jump_mode) try self.goto_definition(.{});
    }

    pub fn primary_double_click(self: *Self, y: c_int, x: c_int) !void {
        const primary = self.get_primary();
        primary.selection = null;
        self.selection_mode = .word;
        const root = self.buf_root() catch return;
        primary.cursor.move_abs(root, &self.view, @intCast(y), @intCast(x), self.plane.metrics()) catch return;
        _ = try self.select_word_at_cursor(primary);
        self.clamp_mouse();
    }

    pub fn primary_triple_click(self: *Self, y: c_int, x: c_int) !void {
        const primary = self.get_primary();
        primary.selection = null;
        self.selection_mode = .line;
        const root = self.buf_root() catch return;
        primary.cursor.move_abs(root, &self.view, @intCast(y), @intCast(x), self.plane.metrics()) catch return;
        try self.select_line_at_cursor(primary);
        self.clamp_mouse();
    }

    pub fn primary_drag(self: *Self, y: c_int, x: c_int) void {
        const y_ = if (y < 0) 0 else y;
        const x_ = if (x < 0) 0 else x;
        const primary = self.get_primary();
        const sel = primary.enable_selection();
        const root = self.buf_root() catch return;
        sel.end.move_abs(root, &self.view, @intCast(y_), @intCast(x_), self.plane.metrics()) catch return;
        switch (self.selection_mode) {
            .char => {},
            .word => if (sel.begin.right_of(sel.end))
                with_selection_const(root, move_cursor_word_begin, primary, self.plane) catch return
            else
                with_selection_const(root, move_cursor_word_end, primary, self.plane) catch return,
            .line => if (sel.begin.right_of(sel.end))
                with_selection_const(root, move_cursor_begin, primary, self.plane) catch return
            else {
                with_selection_const(root, move_cursor_end, primary, self.plane) catch return;
                with_selection_const(root, move_cursor_right, primary, self.plane) catch return;
            },
        }
        primary.cursor = sel.end;
        primary.check_selection();
        self.clamp_mouse();
    }

    pub fn drag_to(self: *Self, ctx: Context) Result {
        var y: i32 = 0;
        var x: i32 = 0;
        if (!try ctx.args.match(.{ tp.extract(&y), tp.extract(&x) }))
            return error.InvalidArgument;
        return self.primary_drag(y, x);
    }

    pub fn secondary_click(self: *Self, y: c_int, x: c_int) !void {
        return self.primary_drag(y, x);
    }

    pub fn secondary_drag(self: *Self, y: c_int, x: c_int) !void {
        return self.primary_drag(y, x);
    }

    fn get_animation_min_lag() f64 {
        const ms: f64 = @floatFromInt(tui.current().config.animation_min_lag);
        return @max(ms * 0.001, 0.001); // to seconds
    }

    fn get_animation_max_lag() f64 {
        const ms: f64 = @floatFromInt(tui.current().config.animation_max_lag);
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

    pub fn scroll_down_pagedown(self: *Self, _: Context) Result {
        if (self.fast_scroll)
            self.scroll_pagedown()
        else
            self.scroll_down();
    }

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

    pub fn scroll_view_top(self: *Self, _: Context) Result {
        return self.scroll_view_offset(scroll_cursor_min_border_distance);
    }

    pub fn scroll_view_bottom(self: *Self, _: Context) Result {
        return self.scroll_view_offset(if (self.view.rows > scroll_cursor_min_border_distance) self.view.rows - scroll_cursor_min_border_distance else 0);
    }

    fn set_clipboard(self: *Self, text: []const u8) void {
        if (self.clipboard) |old|
            self.a.free(old);
        self.clipboard = text;
        tui.current().rdr.copy_to_system_clipboard(text);
    }

    fn copy_selection(root: Buffer.Root, sel: Selection, text_a: Allocator, plane: Plane) ![]const u8 {
        var size: usize = 0;
        _ = try root.get_range(sel, null, &size, null, plane.metrics());
        const buf__ = try text_a.alloc(u8, size);
        return (try root.get_range(sel, buf__, null, null, plane.metrics())).?;
    }

    pub fn get_selection(self: *const Self, sel: Selection, text_a: Allocator) ![]const u8 {
        return copy_selection(try self.buf_root(), sel, text_a, self.plane);
    }

    fn copy_word_at_cursor(self: *Self, text_a: Allocator) ![]const u8 {
        const root = try self.buf_root();
        const primary = self.get_primary();
        const sel = if (primary.selection) |*sel| sel else try self.select_word_at_cursor(primary);
        return try copy_selection(root, sel.*, text_a, self.plane);
    }

    pub fn cut_selection(self: *Self, root: Buffer.Root, cursel: *CurSel) !struct { []const u8, Buffer.Root } {
        return if (cursel.selection) |sel| ret: {
            var old_selection: Selection = sel;
            old_selection.normalize();
            const cut_text = try copy_selection(root, sel, self.a, self.plane);
            if (cut_text.len > 100) {
                self.logger.print("cut:{s}...", .{std.fmt.fmtSliceEscapeLower(cut_text[0..100])});
            } else {
                self.logger.print("cut:{s}", .{std.fmt.fmtSliceEscapeLower(cut_text)});
            }
            break :ret .{ cut_text, try self.delete_selection(root, cursel, try self.buf_a()) };
        } else error.Stop;
    }

    fn expand_selection_to_all(root: Buffer.Root, sel: *Selection, plane: Plane) !void {
        try move_cursor_buffer_begin(root, &sel.begin, plane);
        try move_cursor_buffer_end(root, &sel.end, plane);
    }

    fn insert(self: *Self, root: Buffer.Root, cursel: *CurSel, s: []const u8, a: Allocator) !Buffer.Root {
        var root_ = if (cursel.selection) |_| try self.delete_selection(root, cursel, a) else root;
        const cursor = &cursel.cursor;
        const begin = cursel.cursor;
        cursor.row, cursor.col, root_ = try root_.insert_chars(cursor.row, cursor.col, s, a, self.plane.metrics());
        cursor.target = cursor.col;
        self.nudge_insert(.{ .begin = begin, .end = cursor.* }, cursel, s.len);
        return root_;
    }

    pub fn cut(self: *Self, _: Context) Result {
        const primary = self.get_primary();
        const b = self.buf_for_update() catch return;
        var root = b.root;
        if (self.cursels.items.len == 1)
            if (primary.selection) |_| {} else {
                const sel = primary.enable_selection();
                try move_cursor_begin(root, &sel.begin, self.plane);
                try move_cursor_end(root, &sel.end, self.plane);
                try move_cursor_right(root, &sel.end, self.plane);
            };
        var first = true;
        var text = std.ArrayList(u8).init(self.a);
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            const cut_text, root = try self.cut_selection(root, cursel);
            if (first) {
                first = false;
            } else {
                try text.appendSlice("\n");
            }
            try text.appendSlice(cut_text);
        };
        try self.update_buf(root);
        self.set_clipboard(text.items);
        self.clamp();
    }

    pub fn copy(self: *Self, _: Context) Result {
        const root = self.buf_root() catch return;
        var first = true;
        var text = std.ArrayList(u8).init(self.a);
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            if (cursel.selection) |sel| {
                const copy_text = try copy_selection(root, sel, self.a, self.plane);
                if (first) {
                    first = false;
                } else {
                    try text.appendSlice("\n");
                }
                try text.appendSlice(copy_text);
            }
        };
        if (text.items.len > 0) {
            if (text.items.len > 100) {
                self.logger.print("copy:{s}...", .{std.fmt.fmtSliceEscapeLower(text.items[0..100])});
            } else {
                self.logger.print("copy:{s}", .{std.fmt.fmtSliceEscapeLower(text.items)});
            }
            self.set_clipboard(text.items);
        }
    }

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
            root = try self.insert(root, primary, text, b.a);
        } else {
            if (std.mem.indexOfScalar(u8, text, '\n')) |_| {
                var pos: usize = 0;
                for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
                    if (std.mem.indexOfScalarPos(u8, text, pos, '\n')) |next| {
                        root = try self.insert(root, cursel, text[pos..next], b.a);
                        pos = next + 1;
                    } else {
                        root = try self.insert(root, cursel, text[pos..], b.a);
                        pos = 0;
                    }
                };
            } else {
                for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
                    root = try self.insert(root, cursel, text, b.a);
                };
            }
        }
        try self.update_buf(root);
        self.clamp();
        self.need_render();
    }

    pub fn system_paste(self: *Self, _: Context) Result {
        if (builtin.os.tag == .windows) return self.paste(.{});
        tui.current().rdr.request_system_clipboard();
    }

    pub fn delete_forward(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.delete_to(move_cursor_right, b.root, b.a);
        try self.update_buf(root);
        self.clamp();
    }

    pub fn delete_backward(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.delete_to(move_cursor_left, b.root, b.a);
        try self.update_buf(root);
        self.clamp();
    }

    pub fn delete_word_left(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.delete_to(move_cursor_word_left_space, b.root, b.a);
        try self.update_buf(root);
        self.clamp();
    }

    pub fn delete_word_right(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.delete_to(move_cursor_word_right_space, b.root, b.a);
        try self.update_buf(root);
        self.clamp();
    }

    pub fn delete_to_begin(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.delete_to(move_cursor_begin, b.root, b.a);
        try self.update_buf(root);
        self.clamp();
    }

    pub fn delete_to_end(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.delete_to(move_cursor_end, b.root, b.a);
        try self.update_buf(root);
        self.clamp();
    }

    pub fn join_next_line(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        try self.with_cursors_const(b.root, move_cursor_end);
        const root = try self.delete_to(move_cursor_right, b.root, b.a);
        try self.update_buf(root);
        self.clamp();
    }

    pub fn move_left(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const(root, move_cursor_left) catch {};
        self.clamp();
    }

    pub fn move_right(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const(root, move_cursor_right) catch {};
        self.clamp();
    }

    fn move_cursor_left_vim(root: Buffer.Root, cursor: *Cursor, plane: Plane) error{Stop}!void {
        move_cursor_left_unless(root, cursor, is_eol_left, plane);
    }

    fn move_cursor_right_vim(root: Buffer.Root, cursor: *Cursor, plane: Plane) error{Stop}!void {
        move_cursor_right_unless(root, cursor, is_eol_right_vim, plane);
    }

    pub fn move_left_vim(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const(root, move_cursor_left_vim) catch {};
        self.clamp();
    }

    pub fn move_right_vim(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const(root, move_cursor_right_vim) catch {};
        self.clamp();
    }

    fn move_cursor_word_begin(root: Buffer.Root, cursor: *Cursor, plane: Plane) error{Stop}!void {
        if (is_non_word_char_at_cursor(root, cursor, plane)) {
            move_cursor_left_until(root, cursor, is_word_boundary_right, plane);
            try move_cursor_right(root, cursor, plane);
        } else {
            move_cursor_left_until(root, cursor, is_word_boundary_left, plane);
        }
    }

    fn move_cursor_word_end(root: Buffer.Root, cursor: *Cursor, plane: Plane) error{Stop}!void {
        if (is_non_word_char_at_cursor(root, cursor, plane)) {
            move_cursor_right_until(root, cursor, is_word_boundary_left, plane);
            try move_cursor_left(root, cursor, plane);
        } else {
            move_cursor_right_until(root, cursor, is_word_boundary_right, plane);
        }
        try move_cursor_right(root, cursor, plane);
    }

    fn move_cursor_word_left(root: Buffer.Root, cursor: *Cursor, plane: Plane) error{Stop}!void {
        try move_cursor_left(root, cursor, plane);
        move_cursor_left_until(root, cursor, is_word_boundary_left, plane);
    }

    fn move_cursor_word_left_space(root: Buffer.Root, cursor: *Cursor, plane: Plane) error{Stop}!void {
        try move_cursor_left(root, cursor, plane);
        var next = cursor.*;
        next.move_left(root, plane.metrics()) catch
            return move_cursor_left_until(root, cursor, is_word_boundary_left, plane);
        if (is_non_word_char_at_cursor(root, cursor, plane) and is_non_word_char_at_cursor(root, &next, plane))
            move_cursor_left_until(root, cursor, is_non_word_boundary_left, plane)
        else
            move_cursor_left_until(root, cursor, is_word_boundary_left, plane);
    }

    pub fn move_cursor_word_right(root: Buffer.Root, cursor: *Cursor, plane: Plane) error{Stop}!void {
        move_cursor_right_until(root, cursor, is_word_boundary_right, plane);
        try move_cursor_right(root, cursor, plane);
    }

    pub fn move_cursor_word_right_vim(root: Buffer.Root, cursor: *Cursor, plane: Plane) error{Stop}!void {
        try move_cursor_right(root, cursor, plane);
        move_cursor_right_until(root, cursor, is_word_boundary_left, plane);
    }

    pub fn move_cursor_word_right_space(root: Buffer.Root, cursor: *Cursor, plane: Plane) error{Stop}!void {
        var next = cursor.*;
        next.move_right(root, plane.metrics()) catch {
            move_cursor_right_until(root, cursor, is_word_boundary_right, plane);
            try move_cursor_right(root, cursor, plane);
            return;
        };
        if (is_non_word_char_at_cursor(root, cursor, plane) and is_non_word_char_at_cursor(root, &next, plane))
            move_cursor_right_until(root, cursor, is_non_word_boundary_right, plane)
        else
            move_cursor_right_until(root, cursor, is_word_boundary_right, plane);
        try move_cursor_right(root, cursor, plane);
    }

    pub fn move_word_left(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const(root, move_cursor_word_left) catch {};
        self.clamp();
    }

    pub fn move_word_right(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const(root, move_cursor_word_right) catch {};
        self.clamp();
    }

    pub fn move_word_right_vim(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const(root, move_cursor_word_right_vim) catch {};
        self.clamp();
    }

    fn move_cursor_to_char_left(root: Buffer.Root, cursor: *Cursor, ctx: Context, plane: Plane) error{Stop}!void {
        var egc: []const u8 = undefined;
        if (!(ctx.args.match(.{tp.extract(&egc)}) catch return error.Stop))
            return error.Stop;
        try move_cursor_left(root, cursor, plane);
        while (true) {
            const curr_egc, _, _ = root.ecg_at(cursor.row, cursor.col, plane.metrics()) catch return error.Stop;
            if (std.mem.eql(u8, curr_egc, egc))
                return;
            if (is_eol_left(root, cursor, plane))
                return;
            move_cursor_left(root, cursor, plane) catch return error.Stop;
        }
    }

    pub fn move_cursor_to_char_right(root: Buffer.Root, cursor: *Cursor, ctx: Context, plane: Plane) error{Stop}!void {
        var egc: []const u8 = undefined;
        if (!(ctx.args.match(.{tp.extract(&egc)}) catch return error.Stop))
            return error.Stop;
        try move_cursor_right(root, cursor, plane);
        while (true) {
            const curr_egc, _, _ = root.ecg_at(cursor.row, cursor.col, plane.metrics()) catch return error.Stop;
            if (std.mem.eql(u8, curr_egc, egc))
                return;
            if (is_eol_right(root, cursor, plane))
                return;
            move_cursor_right(root, cursor, plane) catch return error.Stop;
        }
    }

    pub fn move_to_char_left(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const_arg(root, move_cursor_to_char_left, ctx) catch {};
        self.clamp();
    }

    pub fn move_to_char_right(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const_arg(root, move_cursor_to_char_right, ctx) catch {};
        self.clamp();
    }

    pub fn move_up(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const(root, move_cursor_up) catch {};
        self.clamp();
    }

    pub fn add_cursor_up(self: *Self, _: Context) Result {
        try self.push_cursor();
        const primary = self.get_primary();
        const root = try self.buf_root();
        move_cursor_up(root, &primary.cursor, self.plane) catch {};
        self.clamp();
    }

    pub fn move_down(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const(root, move_cursor_down) catch {};
        self.clamp();
    }

    pub fn add_cursor_down(self: *Self, _: Context) Result {
        try self.push_cursor();
        const primary = self.get_primary();
        const root = try self.buf_root();
        move_cursor_down(root, &primary.cursor, self.plane) catch {};
        self.clamp();
    }

    pub fn add_cursor_next_match(self: *Self, _: Context) Result {
        try self.send_editor_jump_source();
        if (self.matches.items.len == 0) {
            const root = self.buf_root() catch return;
            self.with_cursors_const(root, move_cursor_word_begin) catch {};
            try self.with_selections_const(root, move_cursor_word_end);
        } else if (self.get_next_match(self.get_primary().cursor)) |match| {
            try self.push_cursor();
            const primary = self.get_primary();
            const root = self.buf_root() catch return;
            primary.selection = match.to_selection();
            match.has_selection = true;
            primary.cursor.move_to(root, match.end.row, match.end.col, self.plane.metrics()) catch return;
        }
        self.clamp();
        try self.send_editor_jump_destination();
    }

    pub fn add_cursor_all_matches(self: *Self, _: Context) Result {
        if (self.matches.items.len == 0) return;
        try self.send_editor_jump_source();
        while (self.get_next_match(self.get_primary().cursor)) |match| {
            try self.push_cursor();
            const primary = self.get_primary();
            const root = self.buf_root() catch return;
            primary.selection = match.to_selection();
            match.has_selection = true;
            primary.cursor.move_to(root, match.end.row, match.end.col, self.plane.metrics()) catch return;
        }
        self.clamp();
        try self.send_editor_jump_destination();
    }

    fn add_cursors_to_cursel_line_ends(self: *Self, root: Buffer.Root, cursel: *CurSel) !void {
        var sel = cursel.enable_selection();
        sel.normalize();
        var row = sel.begin.row;
        while (row <= sel.end.row) : (row += 1) {
            const new_cursel = try self.cursels.addOne();
            new_cursel.* = CurSel{
                .selection = null,
                .cursor = .{
                    .row = row,
                    .col = 0,
                },
            };
            new_cursel.*.?.cursor.move_end(root, self.plane.metrics());
        }
    }

    pub fn add_cursors_to_line_ends(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        const cursels = try self.cursels.toOwnedSlice();
        defer self.cursels.allocator.free(cursels);
        for (cursels) |*cursel_| if (cursel_.*) |*cursel|
            try self.add_cursors_to_cursel_line_ends(root, cursel);
        self.collapse_cursors();
        self.clamp();
    }

    fn pull_cursel_up(self: *Self, root_: Buffer.Root, cursel: *CurSel, a: Allocator) error{Stop}!Buffer.Root {
        var root = root_;
        const saved = cursel.*;
        const sel = cursel.expand_selection_to_line(root, self.plane);
        var sfa = std.heap.stackFallback(4096, self.a);
        const cut_text = copy_selection(root, sel.*, sfa.get(), self.plane) catch return error.Stop;
        defer a.free(cut_text);
        root = try self.delete_selection(root, cursel, a);
        try cursel.cursor.move_up(root, self.plane.metrics());
        root = self.insert(root, cursel, cut_text, a) catch return error.Stop;
        cursel.* = saved;
        try cursel.cursor.move_up(root, self.plane.metrics());
        if (cursel.selection) |*sel_| {
            try sel_.begin.move_up(root, self.plane.metrics());
            try sel_.end.move_up(root, self.plane.metrics());
        }
        return root;
    }

    pub fn pull_up(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.with_cursels_mut(b.root, pull_cursel_up, b.a);
        try self.update_buf(root);
        self.clamp();
    }

    fn pull_cursel_down(self: *Self, root_: Buffer.Root, cursel: *CurSel, a: Allocator) error{Stop}!Buffer.Root {
        var root = root_;
        const saved = cursel.*;
        const sel = cursel.expand_selection_to_line(root, self.plane);
        var sfa = std.heap.stackFallback(4096, self.a);
        const cut_text = copy_selection(root, sel.*, sfa.get(), self.plane) catch return error.Stop;
        defer a.free(cut_text);
        root = try self.delete_selection(root, cursel, a);
        try cursel.cursor.move_down(root, self.plane.metrics());
        root = self.insert(root, cursel, cut_text, a) catch return error.Stop;
        cursel.* = saved;
        try cursel.cursor.move_down(root, self.plane.metrics());
        if (cursel.selection) |*sel_| {
            try sel_.begin.move_down(root, self.plane.metrics());
            try sel_.end.move_down(root, self.plane.metrics());
        }
        return root;
    }

    pub fn pull_down(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.with_cursels_mut(b.root, pull_cursel_down, b.a);
        try self.update_buf(root);
        self.clamp();
    }

    fn dupe_cursel_up(self: *Self, root_: Buffer.Root, cursel: *CurSel, a: Allocator) error{Stop}!Buffer.Root {
        var root = root_;
        const sel: Selection = if (cursel.selection) |sel_| sel_ else Selection.line_from_cursor(cursel.cursor, root, self.plane.metrics());
        cursel.selection = null;
        var sfa = std.heap.stackFallback(4096, self.a);
        const text = copy_selection(root, sel, sfa.get(), self.plane) catch return error.Stop;
        defer a.free(text);
        cursel.cursor = sel.begin;
        root = self.insert(root, cursel, text, a) catch return error.Stop;
        cursel.selection = .{ .begin = sel.begin, .end = sel.end };
        cursel.cursor = sel.begin;
        return root;
    }

    pub fn dupe_up(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.with_cursels_mut(b.root, dupe_cursel_up, b.a);
        try self.update_buf(root);
        self.clamp();
    }

    fn dupe_cursel_down(self: *Self, root_: Buffer.Root, cursel: *CurSel, a: Allocator) error{Stop}!Buffer.Root {
        var root = root_;
        const sel: Selection = if (cursel.selection) |sel_| sel_ else Selection.line_from_cursor(cursel.cursor, root, self.plane.metrics());
        cursel.selection = null;
        var sfa = std.heap.stackFallback(4096, self.a);
        const text = copy_selection(root, sel, sfa.get(), self.plane) catch return error.Stop;
        defer a.free(text);
        cursel.cursor = sel.end;
        root = self.insert(root, cursel, text, a) catch return error.Stop;
        cursel.selection = .{ .begin = sel.end, .end = cursel.cursor };
        return root;
    }

    pub fn dupe_down(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.with_cursels_mut(b.root, dupe_cursel_down, b.a);
        try self.update_buf(root);
        self.clamp();
    }

    fn toggle_cursel_prefix(self: *Self, root_: Buffer.Root, cursel: *CurSel, a: Allocator) error{Stop}!Buffer.Root {
        var root = root_;
        const saved = cursel.*;
        const sel = cursel.expand_selection_to_line(root, self.plane);
        var sfa = std.heap.stackFallback(4096, self.a);
        const alloc = sfa.get();
        const text = copy_selection(root, sel.*, alloc, self.plane) catch return error.Stop;
        defer a.free(text);
        root = try self.delete_selection(root, cursel, a);
        const new_text = text_manip.toggle_prefix_in_text(self.prefix, text, alloc) catch return error.Stop;
        root = self.insert(root, cursel, new_text, a) catch return error.Stop;
        cursel.* = saved;
        return root;
    }

    pub fn toggle_prefix(self: *Self, ctx: Context) Result {
        var prefix: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&prefix)}))
            return;
        @memcpy(self.prefix_buf[0..prefix.len], prefix);
        self.prefix = self.prefix_buf[0..prefix.len];
        const b = try self.buf_for_update();
        const root = try self.with_cursels_mut(b.root, toggle_cursel_prefix, b.a);
        try self.update_buf(root);
    }

    pub fn toggle_comment(self: *Self, _: Context) Result {
        const comment = if (self.syntax) |syn| syn.file_type.comment else "//";
        return self.toggle_prefix(command.fmt(.{comment}));
    }

    fn indent_cursor(self: *Self, root: Buffer.Root, cursor: Cursor, a: Allocator) error{Stop}!Buffer.Root {
        const space = "    ";
        var cursel: CurSel = .{};
        cursel.cursor = cursor;
        const cols = 4 - find_first_non_ws(root, cursel.cursor.row, self.plane) % 4;
        try smart_move_cursor_begin(root, &cursel.cursor, self.plane);
        return self.insert(root, &cursel, space[0..cols], a) catch return error.Stop;
    }

    fn indent_cursel(self: *Self, root_: Buffer.Root, cursel: *CurSel, a: Allocator) error{Stop}!Buffer.Root {
        if (cursel.selection) |sel_| {
            var root = root_;
            var sel = sel_;
            sel.normalize();
            while (sel.begin.row < sel.end.row) : (sel.begin.row += 1)
                root = try self.indent_cursor(root, sel.begin, a);
            if (sel.end.col > 0)
                root = try self.indent_cursor(root, sel.end, a);
            return root;
        } else return try self.indent_cursor(root_, cursel.cursor, a);
    }

    pub fn indent(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.with_cursels_mut(b.root, indent_cursel, b.a);
        try self.update_buf(root);
    }

    fn unindent_cursor(self: *Self, root: Buffer.Root, cursel: *CurSel, cursor: Cursor, a: Allocator) error{Stop}!Buffer.Root {
        const saved = cursel.*;
        var newroot = root;
        defer {
            cursel.* = saved;
            cursel.cursor.clamp_to_buffer(newroot, self.plane.metrics());
        }
        cursel.selection = null;
        cursel.cursor = cursor;
        const first = find_first_non_ws(root, cursel.cursor.row, self.plane);
        if (first == 0) return error.Stop;
        const off = first % 4;
        const cols = if (off == 0) 4 else off;
        const sel = cursel.enable_selection();
        sel.begin.move_begin();
        try sel.end.move_to(root, sel.end.row, cols, self.plane.metrics());
        if (cursel.cursor.col < cols) try cursel.cursor.move_to(root, cursel.cursor.row, cols, self.plane.metrics());
        newroot = try self.delete_selection(root, cursel, a);
        return newroot;
    }

    fn unindent_cursel(self: *Self, root_: Buffer.Root, cursel: *CurSel, a: Allocator) error{Stop}!Buffer.Root {
        if (cursel.selection) |sel_| {
            var root = root_;
            var sel = sel_;
            sel.normalize();
            while (sel.begin.row < sel.end.row) : (sel.begin.row += 1)
                root = try self.unindent_cursor(root, cursel, sel.begin, a);
            if (sel.end.col > 0)
                root = try self.unindent_cursor(root, cursel, sel.end, a);
            return root;
        } else return self.unindent_cursor(root_, cursel, cursel.cursor, a);
    }

    pub fn unindent(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.with_cursels_mut(b.root, unindent_cursel, b.a);
        try self.update_buf(root);
    }

    pub fn move_scroll_up(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const(root, move_cursor_up) catch {};
        self.view.move_up() catch {};
        self.clamp();
    }

    pub fn move_scroll_down(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        self.with_cursors_const(root, move_cursor_down) catch {};
        self.view.move_down(root) catch {};
        self.clamp();
    }

    pub fn move_scroll_left(self: *Self, _: Context) Result {
        self.view.move_left() catch {};
    }

    pub fn move_scroll_right(self: *Self, _: Context) Result {
        self.view.move_right() catch {};
    }

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

    pub fn smart_move_begin(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        try self.with_cursors_const(root, smart_move_cursor_begin);
        self.clamp();
    }

    pub fn move_begin(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        try self.with_cursors_const(root, move_cursor_begin);
        self.clamp();
    }

    pub fn move_end(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        try self.with_cursors_const(root, move_cursor_end);
        self.clamp();
    }

    pub fn move_page_up(self: *Self, _: Context) Result {
        try self.send_editor_jump_source();
        const root = try self.buf_root();
        try self.with_cursors_and_view_const(root, move_cursor_page_up, &self.view);
        self.clamp();
    }

    pub fn move_page_down(self: *Self, _: Context) Result {
        try self.send_editor_jump_source();
        const root = try self.buf_root();
        try self.with_cursors_and_view_const(root, move_cursor_page_down, &self.view);
        self.clamp();
        try self.send_editor_jump_destination();
    }

    pub fn move_buffer_begin(self: *Self, _: Context) Result {
        try self.send_editor_jump_source();
        self.cancel_all_selections();
        self.get_primary().cursor.move_buffer_begin();
        self.clamp();
        try self.send_editor_jump_destination();
    }

    pub fn move_buffer_end(self: *Self, _: Context) Result {
        try self.send_editor_jump_source();
        self.cancel_all_selections();
        const root = self.buf_root() catch return;
        self.get_primary().cursor.move_buffer_end(root, self.plane.metrics());
        self.clamp();
        try self.send_editor_jump_destination();
    }

    pub fn cancel(self: *Self, _: Context) Result {
        self.cancel_all_selections();
        self.cancel_all_matches();
    }

    pub fn select_up(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const(root, move_cursor_up);
        self.clamp();
    }

    pub fn select_down(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const(root, move_cursor_down);
        self.clamp();
    }

    pub fn select_scroll_up(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const(root, move_cursor_up);
        self.view.move_up() catch {};
        self.clamp();
    }

    pub fn select_scroll_down(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const(root, move_cursor_down);
        self.view.move_down(root) catch {};
        self.clamp();
    }

    pub fn select_left(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const(root, move_cursor_left);
        self.clamp();
    }

    pub fn select_right(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const(root, move_cursor_right);
        self.clamp();
    }

    pub fn select_word_left(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const(root, move_cursor_word_left);
        self.clamp();
    }

    pub fn select_word_right(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const(root, move_cursor_word_right);
        self.clamp();
    }

    pub fn select_word_begin(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const(root, move_cursor_word_begin);
        self.clamp();
    }

    pub fn select_word_end(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const(root, move_cursor_word_end);
        self.clamp();
    }

    pub fn select_to_char_left(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_selections_const_arg(root, move_cursor_to_char_left, ctx) catch {};
        self.clamp();
    }

    pub fn select_to_char_right(self: *Self, ctx: Context) Result {
        const root = try self.buf_root();
        self.with_selections_const_arg(root, move_cursor_to_char_right, ctx) catch {};
        self.clamp();
    }

    pub fn select_begin(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const(root, move_cursor_begin);
        self.clamp();
    }

    pub fn smart_select_begin(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const(root, smart_move_cursor_begin);
        self.clamp();
    }

    pub fn select_end(self: *Self, _: Context) Result {
        const root = try self.buf_root();
        try self.with_selections_const(root, move_cursor_end);
        self.clamp();
    }

    pub fn select_buffer_begin(self: *Self, _: Context) Result {
        try self.send_editor_jump_source();
        const root = try self.buf_root();
        try self.with_selections_const(root, move_cursor_buffer_begin);
        self.clamp();
        try self.send_editor_jump_destination();
    }

    pub fn select_buffer_end(self: *Self, _: Context) Result {
        try self.send_editor_jump_source();
        const root = try self.buf_root();
        try self.with_selections_const(root, move_cursor_buffer_end);
        self.clamp();
        try self.send_editor_jump_destination();
    }

    pub fn select_page_up(self: *Self, _: Context) Result {
        try self.send_editor_jump_source();
        const root = try self.buf_root();
        try self.with_selections_and_view_const(root, move_cursor_page_up, &self.view);
        self.clamp();
        try self.send_editor_jump_destination();
    }

    pub fn select_page_down(self: *Self, _: Context) Result {
        try self.send_editor_jump_source();
        const root = try self.buf_root();
        try self.with_selections_and_view_const(root, move_cursor_page_down, &self.view);
        self.clamp();
        try self.send_editor_jump_destination();
    }

    pub fn select_all(self: *Self, _: Context) Result {
        try self.send_editor_jump_source();
        self.cancel_all_selections();
        const primary = self.get_primary();
        const sel = primary.enable_selection();
        const root = try self.buf_root();
        try expand_selection_to_all(root, sel, self.plane);
        primary.cursor = sel.end;
        self.clamp();
        try self.send_editor_jump_destination();
    }

    fn select_word_at_cursor(self: *Self, cursel: *CurSel) !*Selection {
        const root = try self.buf_root();
        const sel = cursel.enable_selection();
        defer cursel.check_selection();
        sel.normalize();
        try move_cursor_word_begin(root, &sel.begin, self.plane);
        try move_cursor_word_end(root, &sel.end, self.plane);
        cursel.cursor = sel.end;
        return sel;
    }

    fn select_line_at_cursor(self: *Self, cursel: *CurSel) !void {
        const root = try self.buf_root();
        const sel = cursel.enable_selection();
        sel.normalize();
        try move_cursor_begin(root, &sel.begin, self.plane);
        try move_cursor_end(root, &sel.end, self.plane);
        cursel.cursor = sel.end;
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

    pub fn insert_chars(self: *Self, ctx: Context) Result {
        var chars: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&chars)}))
            return error.InvalidArgument;
        const b = try self.buf_for_update();
        var root = b.root;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            root = try self.insert(root, cursel, chars, b.a);
        };
        try self.update_buf(root);
        self.clamp();
    }

    pub fn insert_line(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        var root = b.root;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            root = try self.insert(root, cursel, "\n", b.a);
        };
        try self.update_buf(root);
        self.clamp();
    }

    pub fn smart_insert_line(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        var root = b.root;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            var leading_ws = @min(find_first_non_ws(root, cursel.cursor.row, self.plane), cursel.cursor.col);
            var sfa = std.heap.stackFallback(512, self.a);
            const a = sfa.get();
            var stream = std.ArrayList(u8).init(a);
            defer stream.deinit();
            var writer = stream.writer();
            _ = try writer.write("\n");
            while (leading_ws > 0) : (leading_ws -= 1)
                _ = try writer.write(" ");
            root = try self.insert(root, cursel, stream.items, b.a);
        };
        try self.update_buf(root);
        self.clamp();
    }

    pub fn insert_line_before(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        var root = b.root;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            try move_cursor_begin(root, &cursel.cursor, self.plane);
            root = try self.insert(root, cursel, "\n", b.a);
            try move_cursor_left(root, &cursel.cursor, self.plane);
        };
        try self.update_buf(root);
        self.clamp();
    }

    pub fn smart_insert_line_before(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        var root = b.root;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            var leading_ws = @min(find_first_non_ws(root, cursel.cursor.row, self.plane), cursel.cursor.col);
            try move_cursor_begin(root, &cursel.cursor, self.plane);
            root = try self.insert(root, cursel, "\n", b.a);
            try move_cursor_left(root, &cursel.cursor, self.plane);
            var sfa = std.heap.stackFallback(512, self.a);
            const a = sfa.get();
            var stream = std.ArrayList(u8).init(a);
            defer stream.deinit();
            var writer = stream.writer();
            while (leading_ws > 0) : (leading_ws -= 1)
                _ = try writer.write(" ");
            if (stream.items.len > 0)
                root = try self.insert(root, cursel, stream.items, b.a);
        };
        try self.update_buf(root);
        self.clamp();
    }

    pub fn insert_line_after(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        var root = b.root;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            try move_cursor_end(root, &cursel.cursor, self.plane);
            root = try self.insert(root, cursel, "\n", b.a);
        };
        try self.update_buf(root);
        self.clamp();
    }

    pub fn smart_insert_line_after(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        var root = b.root;
        for (self.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            var leading_ws = @min(find_first_non_ws(root, cursel.cursor.row, self.plane), cursel.cursor.col);
            try move_cursor_end(root, &cursel.cursor, self.plane);
            var sfa = std.heap.stackFallback(512, self.a);
            const a = sfa.get();
            var stream = std.ArrayList(u8).init(a);
            defer stream.deinit();
            var writer = stream.writer();
            _ = try writer.write("\n");
            while (leading_ws > 0) : (leading_ws -= 1)
                _ = try writer.write(" ");
            if (stream.items.len > 0)
                root = try self.insert(root, cursel, stream.items, b.a);
        };
        try self.update_buf(root);
        self.clamp();
    }

    pub fn enable_fast_scroll(self: *Self, _: Context) Result {
        self.fast_scroll = true;
    }

    pub fn disable_fast_scroll(self: *Self, _: Context) Result {
        self.fast_scroll = false;
    }

    pub fn enable_jump_mode(self: *Self, _: Context) Result {
        self.jump_mode = true;
        tui.current().rdr.request_mouse_cursor_pointer(true);
    }

    pub fn disable_jump_mode(self: *Self, _: Context) Result {
        self.jump_mode = false;
        tui.current().rdr.request_mouse_cursor_text(true);
    }

    fn update_syntax(self: *Self) !void {
        const frame = tracy.initZone(@src(), .{ .name = "editor update syntax" });
        defer frame.deinit();
        const root = try self.buf_root();
        const token = @intFromPtr(root);
        if (root.lines() > root_mod.max_syntax_lines)
            return;
        if (self.syntax_token == token)
            return;
        if (self.syntax) |syn| {
            if (self.syntax_refresh_full) {
                var content = std.ArrayList(u8).init(self.a);
                defer content.deinit();
                try root.store(content.writer());
                try syn.refresh_full(content.items);
                self.syntax_refresh_full = false;
            } else {
                try syn.refresh_from_buffer(root, self.plane.metrics());
            }
            self.syntax_token = token;
        } else {
            var content = std.ArrayList(u8).init(self.a);
            defer content.deinit();
            try root.store(content.writer());
            self.syntax = if (tp.env.get().is("no-syntax"))
                null
            else
                syntax.create_guess_file_type(self.a, content.items, self.file_path) catch |e| switch (e) {
                    error.NotFound => null,
                    else => return e,
                };
        }
    }

    fn reset_syntax(self: *Self) void {
        if (self.syntax) |_| self.syntax_refresh_full = true;
    }

    pub fn dump_current_line(self: *Self, _: Context) Result {
        const root = self.buf_root() catch return;
        const primary = self.get_primary();
        var tree = std.ArrayList(u8).init(self.a);
        defer tree.deinit();
        root.debug_render_chunks(primary.cursor.row, &tree, self.plane.metrics()) catch |e|
            return self.logger.print("line {d}: {any}", .{ primary.cursor.row, e });
        self.logger.print("line {d}:{s}", .{ primary.cursor.row, std.fmt.fmtSliceEscapeLower(tree.items) });
    }

    pub fn dump_current_line_tree(self: *Self, _: Context) Result {
        const root = self.buf_root() catch return;
        const primary = self.get_primary();
        var tree = std.ArrayList(u8).init(self.a);
        defer tree.deinit();
        root.debug_line_render_tree(primary.cursor.row, &tree) catch |e|
            return self.logger.print("line {d} ast: {any}", .{ primary.cursor.row, e });
        self.logger.print("line {d} ast:{s}", .{ primary.cursor.row, std.fmt.fmtSliceEscapeLower(tree.items) });
    }

    pub fn undo(self: *Self, _: Context) Result {
        try self.restore_undo();
        self.clamp();
    }

    pub fn redo(self: *Self, _: Context) Result {
        try self.restore_redo();
        self.clamp();
    }

    pub fn open_buffer_from_file(self: *Self, ctx: Context) Result {
        var file_path: []const u8 = undefined;
        if (ctx.args.match(.{tp.extract(&file_path)}) catch false) {
            try self.open(file_path);
            self.clamp();
        } else return error.InvalidArgument;
    }

    pub fn open_scratch_buffer(self: *Self, ctx: Context) Result {
        var file_path: []const u8 = undefined;
        var content: []const u8 = undefined;
        if (ctx.args.match(.{ tp.extract(&file_path), tp.extract(&content) }) catch false) {
            try self.open_scratch(file_path, content);
            self.clamp();
        } else return error.InvalidArgument;
    }

    pub fn save_file(self: *Self, _: Context) Result {
        try self.save();
    }

    pub fn close_file(self: *Self, _: Context) Result {
        self.cancel_all_selections();
        try self.close();
    }

    pub fn close_file_without_saving(self: *Self, _: Context) Result {
        self.cancel_all_selections();
        try self.close_dirty();
    }

    pub fn find_query(self: *Self, ctx: Context) Result {
        var query: []const u8 = undefined;
        if (ctx.args.match(.{tp.extract(&query)}) catch false) {
            try self.find_in_buffer(query);
            self.clamp();
        } else return error.InvalidArgument;
    }

    fn find_in(self: *Self, query: []const u8, comptime find_f: ripgrep.FindF, write_buffer: bool) !void {
        const root = try self.buf_root();
        self.cancel_all_matches();
        if (std.mem.indexOfScalar(u8, query, '\n')) |_| return;
        self.logger.print("find:{s}", .{std.fmt.fmtSliceEscapeLower(query)});
        var rg = try find_f(self.a, query, "A");
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
            self.find_history = std.ArrayList([]const u8).init(self.a);
            break :ret &self.find_history.?;
        };
        for (history.items, 0..) |entry, i|
            if (std.mem.eql(u8, entry, query))
                self.a.free(history.orderedRemove(i));
        const new = self.a.dupe(u8, query) catch return;
        (history.addOne() catch return).* = new;
    }

    fn set_last_find_query(self: *Self, query: []const u8) void {
        if (self.last_find_query) |last| {
            if (query.ptr != last.ptr) {
                self.a.free(last);
                self.last_find_query = self.a.dupe(u8, query) catch return;
            }
        } else self.last_find_query = self.a.dupe(u8, query) catch return;
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
        try root.find_all_ranges(query, &ctx, Ctx.cb, self.a);
    }

    fn find_in_buffer_async(self: *Self, query: []const u8) !void {
        const finder = struct {
            a: Allocator,
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
                defer fdr.a.free(fdr.query);
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
        const fdr = try self.a.create(finder);
        fdr.* = .{
            .a = self.a,
            .query = try self.a.dupe(u8, query),
            .parent = tp.self_pid(),
            .root = try self.buf_root(),
            .token = self.match_token,
            .matches = Match.List.init(self.a),
        };
        const pid = try tp.spawn_link(self.a, fdr, finder.start, "editor.find");
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
        const begin_pos = root.pos_to_width(begin_line, begin_pos_, self.plane.metrics()) catch return;
        const end_pos = root.pos_to_width(end_line, end_pos_, self.plane.metrics()) catch return;
        var match: Match = .{ .begin = .{ .row = begin_line, .col = begin_pos }, .end = .{ .row = end_line, .col = end_pos } };
        if (match.end.eql(self.get_primary().cursor))
            match.has_selection = true;
        (self.matches.addOne() catch return).* = match;
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
        cursor_.move_buffer_end(root, self.plane.metrics());
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
            primary.cursor.move_to(root, match.end.row, match.end.col, self.plane.metrics()) catch return;
            self.clamp();
        }
    }

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

    pub fn move_cursor_prev_match(self: *Self, _: Context) Result {
        const primary = self.get_primary();
        if (self.get_prev_match(primary.cursor)) |match| {
            const root = self.buf_root() catch return;
            if (primary.selection) |sel| if (self.find_selection_match(sel)) |match_| {
                match_.has_selection = false;
            };
            primary.selection = match.to_selection();
            primary.selection.?.reverse();
            primary.cursor.move_to(root, match.begin.row, match.begin.col, self.plane.metrics()) catch return;
            self.clamp();
        }
    }

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

    pub fn goto_next_diagnostic(self: *Self, _: Context) Result {
        if (self.diagnostics.items.len == 0) return command.executeName("goto_next_file", .{});
        self.sort_diagnostics();
        const primary = self.get_primary();
        for (self.diagnostics.items) |*diag| {
            if ((diag.sel.begin.row == primary.cursor.row and diag.sel.begin.col > primary.cursor.col) or diag.sel.begin.row > primary.cursor.row)
                return self.goto_diagnostic(diag);
        }
        return self.goto_diagnostic(&self.diagnostics.items[0]);
    }

    pub fn goto_prev_diagnostic(self: *Self, _: Context) Result {
        if (self.diagnostics.items.len == 0) return command.executeName("goto_prev_file", .{});
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

    fn goto_diagnostic(self: *Self, diag: *const Diagnostic) !void {
        const root = self.buf_root() catch return;
        const primary = self.get_primary();
        try self.send_editor_jump_source();
        self.cancel_all_selections();
        try primary.cursor.move_to(root, diag.sel.begin.row, diag.sel.begin.col, self.plane.metrics());
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
            return error.InvalidArgument;
        const root = self.buf_root() catch return;
        self.cancel_all_selections();
        const primary = self.get_primary();
        try primary.cursor.move_to(root, @intCast(if (line < 1) 0 else line - 1), primary.cursor.col, self.plane.metrics());
        self.clamp();
        try self.send_editor_jump_destination();
    }

    pub fn goto_column(self: *Self, ctx: Context) Result {
        var column: usize = 0;
        if (!try ctx.args.match(.{tp.extract(&column)}))
            return error.InvalidArgument;
        const root = self.buf_root() catch return;
        const primary = self.get_primary();
        try primary.cursor.move_to(root, primary.cursor.row, @intCast(if (column < 1) 0 else column - 1), self.plane.metrics());
        self.clamp();
    }

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
        } else return error.InvalidArgument;
        self.cancel_all_selections();
        const root = self.buf_root() catch return;
        const primary = self.get_primary();
        try primary.cursor.move_to(
            root,
            @intCast(if (line < 1) 0 else line - 1),
            @intCast(if (column < 1) 0 else column - 1),
            self.plane.metrics(),
        );
        if (have_sel) primary.selection = sel;
        if (self.view.is_visible(&primary.cursor))
            self.clamp()
        else
            try self.scroll_view_center(.{});
        try self.send_editor_jump_destination();
        self.need_render();
    }

    pub fn goto_definition(self: *Self, _: Context) Result {
        const file_path = self.file_path orelse return;
        const primary = self.get_primary();
        return project_manager.goto_definition(file_path, primary.cursor.row, primary.cursor.col);
    }

    pub fn references(self: *Self, _: Context) Result {
        const file_path = self.file_path orelse return;
        const primary = self.get_primary();
        return project_manager.references(file_path, primary.cursor.row, primary.cursor.col);
    }

    pub fn completion(self: *Self, _: Context) Result {
        const file_path = self.file_path orelse return;
        const primary = self.get_primary();
        return project_manager.completion(file_path, primary.cursor.row, primary.cursor.col);
    }

    pub fn add_diagnostic(
        self: *Self,
        file_path: []const u8,
        source: []const u8,
        code: []const u8,
        message: []const u8,
        severity: i32,
        sel: Selection,
    ) Result {
        if (!std.mem.eql(u8, file_path, self.file_path orelse return)) return;

        (try self.diagnostics.addOne()).* = .{
            .source = try self.diagnostics.allocator.dupe(u8, source),
            .code = try self.diagnostics.allocator.dupe(u8, code),
            .message = try self.diagnostics.allocator.dupe(u8, message),
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

    pub fn select(self: *Self, ctx: Context) Result {
        var sel: Selection = .{};
        if (!try ctx.args.match(.{ tp.extract(&sel.begin.row), tp.extract(&sel.begin.col), tp.extract(&sel.end.row), tp.extract(&sel.end.col) }))
            return error.InvalidArgument;
        self.get_primary().selection = sel;
    }

    pub fn format(self: *Self, ctx: Context) Result {
        if (ctx.args.buf.len > 0 and try ctx.args.match(.{ tp.string, tp.more })) {
            try self.filter_cmd(ctx.args);
            return;
        }
        if (self.syntax) |syn| if (syn.file_type.formatter) |fmtr| if (fmtr.len > 0) {
            var args = std.ArrayList(u8).init(self.a);
            const writer = args.writer();
            try cbor.writeArrayHeader(writer, fmtr.len);
            for (fmtr) |arg| try cbor.writeValue(writer, arg);
            try self.filter_cmd(.{ .buf = args.items });
            return;
        };
        return tp.exit("no formatter");
    }

    pub fn filter(self: *Self, ctx: Context) Result {
        if (!try ctx.args.match(.{ tp.string, tp.more }))
            return error.InvalidArgument;
        try self.filter_cmd(ctx.args);
    }

    fn filter_cmd(self: *Self, cmd: tp.message) !void {
        if (self.filter) |_| return error.Stop;
        const root = self.buf_root() catch return;
        const buf_a_ = try self.buf_a();
        const primary = self.get_primary();
        var sel: Selection = if (primary.selection) |sel_| sel_ else val: {
            var sel_: Selection = .{};
            try expand_selection_to_all(root, &sel_, self.plane);
            break :val sel_;
        };
        const reversed = sel.begin.right_of(sel.end);
        sel.normalize();
        self.filter = .{
            .before_root = root,
            .work_root = root,
            .begin = sel.begin,
            .pos = .{ .cursor = sel.begin },
            .old_primary = primary.*,
            .old_primary_reversed = reversed,
            .whole_file = if (primary.selection) |_| null else std.ArrayList(u8).init(self.a),
        };
        errdefer self.filter_deinit();
        const state = &self.filter.?;
        var buf: [1024]u8 = undefined;
        const json = try cmd.to_json(&buf);
        self.logger.print("filter: start {s}", .{json});
        var sp = try tp.subprocess.init(self.a, cmd, "filter", .Pipe);
        defer {
            sp.close() catch {};
            sp.deinit();
        }
        var buffer = sp.bufferedWriter();
        try self.write_range(state.before_root, sel, buffer.writer(), tp.exit_error, null, self.plane);
        try buffer.flush();
        self.logger.print("filter: sent", .{});
        state.work_root = try state.work_root.delete_range(sel, buf_a_, null, self.plane.metrics());
    }

    fn filter_stdout(self: *Self, bytes: []const u8) !void {
        const state = if (self.filter) |*s| s else return error.Stop;
        errdefer self.filter_deinit();
        const buf_a_ = try self.buf_a();
        if (state.whole_file) |*buf| {
            try buf.appendSlice(bytes);
        } else {
            const cursor = &state.pos.cursor;
            cursor.row, cursor.col, state.work_root = try state.work_root.insert_chars(cursor.row, cursor.col, bytes, buf_a_, self.plane.metrics());
            state.bytes += bytes.len;
            state.chunks += 1;
        }
    }

    fn filter_error(self: *Self, bytes: []const u8) void {
        defer self.filter_deinit();
        self.logger.print("filter: ERR: {s}", .{bytes});
    }

    fn filter_done(self: *Self) !void {
        const b = try self.buf_for_update();
        const root = self.buf_root() catch return;
        const state = if (self.filter) |*s| s else return error.Stop;
        if (state.before_root != root) return error.Stop;
        defer self.filter_deinit();
        const primary = self.get_primary();
        self.cancel_all_selections();
        self.cancel_all_matches();
        if (state.whole_file) |buf| {
            state.work_root = try b.load_from_string(buf.items);
            state.bytes = buf.items.len;
            state.chunks = 1;
            primary.cursor = state.old_primary.cursor;
        } else {
            const sel = primary.enable_selection();
            sel.begin = state.begin;
            sel.end = state.pos.cursor;
            if (state.old_primary_reversed) sel.reverse();
            primary.cursor = sel.end;
        }
        try self.update_buf(state.work_root);
        primary.cursor.clamp_to_buffer(state.work_root, self.plane.metrics());
        self.logger.print("filter: done (bytes:{d} chunks:{d})", .{ state.bytes, state.chunks });
        self.reset_syntax();
        self.clamp();
        self.need_render();
    }

    fn filter_deinit(self: *Self) void {
        const state = if (self.filter) |*s| s else return;
        if (state.whole_file) |*buf| buf.deinit();
        self.filter = null;
    }

    fn to_upper_cursel(self: *Self, root_: Buffer.Root, cursel: *CurSel, a: Allocator) error{Stop}!Buffer.Root {
        var root = root_;
        const saved = cursel.*;
        const sel = if (cursel.selection) |*sel| sel else ret: {
            var sel = cursel.enable_selection();
            move_cursor_word_begin(root, &sel.begin, self.plane) catch return error.Stop;
            move_cursor_word_end(root, &sel.end, self.plane) catch return error.Stop;
            break :ret sel;
        };
        var sfa = std.heap.stackFallback(4096, self.a);
        const cut_text = copy_selection(root, sel.*, sfa.get(), self.plane) catch return error.Stop;
        defer a.free(cut_text);
        const cd = CaseData.init(a) catch return error.Stop;
        defer cd.deinit();
        const ucased = cd.toUpperStr(a, cut_text) catch return error.Stop;
        defer a.free(ucased);
        root = try self.delete_selection(root, cursel, a);
        root = self.insert(root, cursel, ucased, a) catch return error.Stop;
        cursel.* = saved;
        return root;
    }

    pub fn to_upper(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.with_cursels_mut(b.root, to_upper_cursel, b.a);
        try self.update_buf(root);
        self.clamp();
    }

    fn to_lower_cursel(self: *Self, root_: Buffer.Root, cursel: *CurSel, a: Allocator) error{Stop}!Buffer.Root {
        var root = root_;
        const saved = cursel.*;
        const sel = if (cursel.selection) |*sel| sel else ret: {
            var sel = cursel.enable_selection();
            move_cursor_word_begin(root, &sel.begin, self.plane) catch return error.Stop;
            move_cursor_word_end(root, &sel.end, self.plane) catch return error.Stop;
            break :ret sel;
        };
        var sfa = std.heap.stackFallback(4096, self.a);
        const cut_text = copy_selection(root, sel.*, sfa.get(), self.plane) catch return error.Stop;
        defer a.free(cut_text);
        const cd = CaseData.init(a) catch return error.Stop;
        defer cd.deinit();
        const ucased = cd.toLowerStr(a, cut_text) catch return error.Stop;
        defer a.free(ucased);
        root = try self.delete_selection(root, cursel, a);
        root = self.insert(root, cursel, ucased, a) catch return error.Stop;
        cursel.* = saved;
        return root;
    }

    pub fn to_lower(self: *Self, _: Context) Result {
        const b = try self.buf_for_update();
        const root = try self.with_cursels_mut(b.root, to_lower_cursel, b.a);
        try self.update_buf(root);
        self.clamp();
    }
};

pub fn create(a: Allocator, parent: Widget) !Widget {
    return EditorWidget.create(a, parent);
}

pub const EditorWidget = struct {
    plane: Plane,
    parent: Plane,

    editor: Editor,
    commands: Commands = undefined,

    last_btn: c_int = -1,
    last_btn_time_ms: i64 = 0,
    last_btn_count: usize = 0,

    hover: bool = false,

    const Self = @This();
    const Commands = command.Collection(Editor);

    fn create(a: Allocator, parent: Widget) !Widget {
        const container = try WidgetList.createH(a, parent, "editor.container", .dynamic);
        const self: *Self = try a.create(Self);
        try self.init(a, container.widget());
        try self.commands.init(&self.editor);
        const editorWidget = Widget.to(self);
        try container.add(try editor_gutter.create(a, container.widget(), editorWidget, &self.editor));
        try container.add(editorWidget);
        try container.add(try scrollbar_v.create(a, container.widget(), editorWidget, EventHandler.to_unowned(container)));
        return container.widget();
    }

    fn init(self: *Self, a: Allocator, parent: Widget) !void {
        var n = try Plane.init(&(Widget.Box{}).opts("editor"), parent.plane.*);
        errdefer n.deinit();

        self.* = .{
            .parent = parent.plane.*,
            .plane = n,
            .editor = undefined,
        };
        self.editor.init(a, n);
        errdefer self.editor.deinit();
        try self.editor.push_cursor();
    }

    pub fn deinit(self: *Self, a: Allocator) void {
        self.commands.deinit();
        self.editor.deinit();
        self.plane.deinit();
        a.destroy(self);
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
        var evtype: c_int = undefined;
        var btn: c_int = undefined;
        var x: c_int = undefined;
        var y: c_int = undefined;
        var xpx: c_int = undefined;
        var ypx: c_int = undefined;
        var pos: u32 = 0;
        var bytes: []u8 = "";

        if (try m.match(.{ "B", tp.extract(&evtype), tp.extract(&btn), tp.any, tp.extract(&x), tp.extract(&y), tp.extract(&xpx), tp.extract(&ypx) })) {
            try self.mouse_click_event(evtype, btn, y, x, ypx, xpx);
        } else if (try m.match(.{ "D", tp.extract(&evtype), tp.extract(&btn), tp.any, tp.extract(&x), tp.extract(&y), tp.extract(&xpx), tp.extract(&ypx) })) {
            try self.mouse_drag_event(evtype, btn, y, x, ypx, xpx);
        } else if (try m.match(.{ "scroll_to", tp.extract(&pos) })) {
            self.editor.scroll_to(pos);
        } else if (try m.match(.{ "filter", "stdout", tp.extract(&bytes) })) {
            self.editor.filter_stdout(bytes) catch {};
        } else if (try m.match(.{ "filter", "stderr", tp.extract(&bytes) })) {
            self.editor.filter_error(bytes);
        } else if (try m.match(.{ "filter", "term", tp.more })) {
            self.editor.filter_done() catch {};
        } else if (try m.match(.{ "A", tp.more })) {
            self.editor.add_match(m) catch {};
        } else if (try m.match(.{ "H", tp.extract(&self.hover) })) {
            if (self.editor.jump_mode)
                tui.current().rdr.request_mouse_cursor_pointer(self.hover)
            else
                tui.current().rdr.request_mouse_cursor_text(self.hover);
        } else if (try m.match(.{ "show_whitespace", tp.extract(&self.editor.show_whitespace) })) {
            _ = "";
        } else {
            return false;
        }
        return true;
    }

    const Result = command.Result;

    fn mouse_click_event(self: *Self, evtype: c_int, btn: c_int, y: c_int, x: c_int, ypx: c_int, xpx: c_int) Result {
        if (evtype != event_type.PRESS) return;
        const ret = (switch (btn) {
            key.BUTTON1 => &mouse_click_button1,
            key.BUTTON2 => &mouse_click_button2,
            key.BUTTON3 => &mouse_click_button3,
            key.BUTTON4 => &mouse_click_button4,
            key.BUTTON5 => &mouse_click_button5,
            key.BUTTON8 => &mouse_click_button8, //back
            key.BUTTON9 => &mouse_click_button9, //forward
            else => return,
        })(self, y, x, ypx, xpx);
        self.last_btn = btn;
        self.last_btn_time_ms = time.milliTimestamp();
        return ret;
    }

    fn mouse_drag_event(self: *Self, evtype: c_int, btn: c_int, y: c_int, x: c_int, ypx: c_int, xpx: c_int) Result {
        if (evtype != event_type.PRESS) return;
        return (switch (btn) {
            key.BUTTON1 => &mouse_drag_button1,
            key.BUTTON2 => &mouse_drag_button2,
            key.BUTTON3 => &mouse_drag_button3,
            else => return,
        })(self, y, x, ypx, xpx);
    }

    fn mouse_click_button1(self: *Self, y: c_int, x: c_int, _: c_int, _: c_int) Result {
        const y_, const x_ = self.editor.plane.abs_yx_to_rel(y, x);
        if (self.last_btn == key.BUTTON1) {
            const click_time_ms = time.milliTimestamp() - self.last_btn_time_ms;
            if (click_time_ms <= double_click_time_ms) {
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

    fn mouse_drag_button1(self: *Self, y: c_int, x: c_int, _: c_int, _: c_int) Result {
        const y_, const x_ = self.editor.plane.abs_yx_to_rel(y, x);
        self.editor.primary_drag(y_, x_);
    }

    fn mouse_click_button2(_: *Self, _: c_int, _: c_int, _: c_int, _: c_int) Result {}

    fn mouse_drag_button2(_: *Self, _: c_int, _: c_int, _: c_int, _: c_int) Result {}

    fn mouse_click_button3(self: *Self, y: c_int, x: c_int, _: c_int, _: c_int) Result {
        const y_, const x_ = self.editor.plane.abs_yx_to_rel(y, x);
        try self.editor.secondary_click(y_, x_);
    }

    fn mouse_drag_button3(self: *Self, y: c_int, x: c_int, _: c_int, _: c_int) Result {
        const y_, const x_ = self.editor.plane.abs_yx_to_rel(y, x);
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

    pub fn init(a: Allocator) !Self {
        return .{
            .cache = try std.ArrayList(usize).initCapacity(a, 2048),
        };
    }

    pub fn deinit(self: *Self) void {
        self.cache.deinit();
    }

    pub fn range_to_selection(self: *Self, range: syntax.Range, root: Buffer.Root, plane: Plane) ?Selection {
        const start = range.start_point;
        const end = range.end_point;
        if (root != self.cached_root or self.cached_line != start.row) {
            self.cache.clearRetainingCapacity();
            self.cached_line = start.row;
            self.cached_root = root;
            root.get_line_width_map(self.cached_line, &self.cache, plane.metrics()) catch return null;
        }
        const start_col = if (start.column < self.cache.items.len) self.cache.items[start.column] else start.column;
        const end_col = if (end.row == start.row and end.column < self.cache.items.len) self.cache.items[end.column] else root.pos_to_width(end.row, end.column, plane.metrics()) catch end.column;
        return .{ .begin = .{ .row = start.row, .col = start_col }, .end = .{ .row = end.row, .col = end_col } };
    }
};
