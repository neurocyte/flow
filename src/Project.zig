const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const root = @import("root");
const dizzy = @import("dizzy");
const Buffer = @import("Buffer");
const fuzzig = @import("fuzzig");
const tracy = @import("tracy");
const builtin = @import("builtin");

const LSP = @import("LSP.zig");

allocator: std.mem.Allocator,
name: []const u8,
files: std.ArrayList(File),
pending: std.ArrayList(File),
longest_file_path: usize = 0,
open_time: i64,
language_servers: std.StringHashMap(LSP),
file_language_server: std.StringHashMap(LSP),

const Self = @This();

const OutOfMemoryError = error{OutOfMemory};
const CallError = tp.CallError;
const SpawnError = (OutOfMemoryError || error{ThespianSpawnFailed});
pub const InvalidMessageError = error{ InvalidMessage, InvalidMessageField, InvalidTargetURI };
pub const StartLspError = (error{ ThespianSpawnFailed, Timeout, InvalidLspCommand } || LspError || OutOfMemoryError || cbor.Error);
pub const LspError = (error{ NoLsp, LspFailed } || OutOfMemoryError);
pub const ClientError = (error{ClientFailed} || OutOfMemoryError);
pub const LspOrClientError = (LspError || ClientError);

const File = struct {
    path: []const u8,
    mtime: i128,
    row: usize = 0,
    col: usize = 0,
    visited: bool = false,
};

pub fn init(allocator: std.mem.Allocator, name: []const u8) OutOfMemoryError!Self {
    return .{
        .allocator = allocator,
        .name = try allocator.dupe(u8, name),
        .files = std.ArrayList(File).init(allocator),
        .pending = std.ArrayList(File).init(allocator),
        .open_time = std.time.milliTimestamp(),
        .language_servers = std.StringHashMap(LSP).init(allocator),
        .file_language_server = std.StringHashMap(LSP).init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    var i_ = self.file_language_server.iterator();
    while (i_.next()) |p| {
        self.allocator.free(p.key_ptr.*);
    }
    var i = self.language_servers.iterator();
    while (i.next()) |p| {
        self.allocator.free(p.key_ptr.*);
        p.value_ptr.*.term();
    }
    for (self.files.items) |file| self.allocator.free(file.path);
    self.files.deinit();
    self.allocator.free(self.name);
}

pub fn write_state(self: *Self, writer: anytype) !void {
    try cbor.writeValue(writer, self.name);
    for (self.files.items) |file| {
        if (!file.visited) continue;
        try cbor.writeArrayHeader(writer, 4);
        try cbor.writeValue(writer, file.path);
        try cbor.writeValue(writer, file.mtime);
        try cbor.writeValue(writer, file.row);
        try cbor.writeValue(writer, file.col);
    }
}

pub fn restore_state(self: *Self, data: []const u8) !void {
    defer self.sort_files_by_mtime();
    var name: []const u8 = undefined;
    var path: []const u8 = undefined;
    var mtime: i128 = undefined;
    var row: usize = undefined;
    var col: usize = undefined;
    var iter: []const u8 = data;
    _ = cbor.matchValue(&iter, tp.extract(&name)) catch {};
    while (cbor.matchValue(&iter, .{
        tp.extract(&path),
        tp.extract(&mtime),
        tp.extract(&row),
        tp.extract(&col),
    }) catch |e| switch (e) {
        error.TooShort => return,
        else => return e,
    }) {
        self.longest_file_path = @max(self.longest_file_path, path.len);
        const stat = std.fs.cwd().statFile(path) catch return;
        switch (stat.kind) {
            .sym_link, .file => {},
            else => return,
        }
        try self.update_mru_internal(path, mtime, row, col);
    }
}

fn get_language_server_instance(self: *Self, language_server: []const u8) StartLspError!LSP {
    if (self.language_servers.get(language_server)) |lsp| {
        if (!lsp.pid.expired()) return lsp;
        lsp.deinit();
        _ = self.language_servers.remove(language_server);
    }
    const lsp = try LSP.open(self.allocator, self.name, .{ .buf = language_server });
    errdefer lsp.deinit();
    const uri = try self.make_URI(null);
    defer self.allocator.free(uri);
    const basename_begin = std.mem.lastIndexOfScalar(u8, self.name, std.fs.path.sep);
    const basename = if (basename_begin) |begin| self.name[begin + 1 ..] else self.name;
    const response = try self.send_lsp_init_request(lsp, self.name, basename, uri);
    defer self.allocator.free(response.buf);
    lsp.send_notification("initialized", .{}) catch return error.LspFailed;
    if (lsp.pid.expired()) return error.LspFailed;
    log.logger("lsp").print("initialized LSP: {s}", .{fmt_lsp_name_func(language_server)});
    try self.language_servers.put(try self.allocator.dupe(u8, language_server), lsp);
    return lsp;
}

fn get_or_start_language_server(self: *Self, file_path: []const u8, language_server: []const u8) StartLspError!LSP {
    const lsp = self.file_language_server.get(file_path) orelse blk: {
        const new_lsp = try self.get_language_server_instance(language_server);
        const key = try self.allocator.dupe(u8, file_path);
        try self.file_language_server.put(key, new_lsp);
        break :blk new_lsp;
    };
    return lsp;
}

fn get_language_server(self: *Self, file_path: []const u8) LspError!LSP {
    const lsp = self.file_language_server.get(file_path) orelse return error.NoLsp;
    if (lsp.pid.expired()) {
        if (self.file_language_server.fetchRemove(file_path)) |kv|
            self.allocator.free(kv.key);
        return error.LspFailed;
    }
    return lsp;
}

fn make_URI(self: *Self, file_path: ?[]const u8) LspError![]const u8 {
    var buf = std.ArrayList(u8).init(self.allocator);
    if (file_path) |path| {
        if (std.fs.path.isAbsolute(path)) {
            try buf.writer().print("file://{s}", .{path});
        } else {
            try buf.writer().print("file://{s}{c}{s}", .{ self.name, std.fs.path.sep, path });
        }
    } else try buf.writer().print("file://{s}", .{self.name});
    return buf.toOwnedSlice();
}

pub fn sort_files_by_mtime(self: *Self) void {
    const less_fn = struct {
        fn less_fn(_: void, lhs: File, rhs: File) bool {
            return lhs.mtime > rhs.mtime;
        }
    }.less_fn;
    std.mem.sort(File, self.files.items, {}, less_fn);
}

pub fn request_n_most_recent_file(self: *Self, from: tp.pid_ref, n: usize) ClientError!void {
    if (n >= self.files.items.len) return error.ClientFailed;
    const file_path = if (self.files.items.len > 0) self.files.items[n].path else null;
    from.send(.{file_path}) catch return error.ClientFailed;
}

pub fn request_recent_files(self: *Self, from: tp.pid_ref, max: usize) ClientError!void {
    defer from.send(.{ "PRJ", "recent_done", self.longest_file_path, "" }) catch {};
    for (self.files.items, 0..) |file, i| {
        from.send(.{ "PRJ", "recent", self.longest_file_path, file.path }) catch return error.ClientFailed;
        if (i >= max) return;
    }
}

fn simple_query_recent_files(self: *Self, from: tp.pid_ref, max: usize, query: []const u8) ClientError!usize {
    var i: usize = 0;
    defer from.send(.{ "PRJ", "recent_done", self.longest_file_path, query }) catch {};
    for (self.files.items) |file| {
        if (file.path.len < query.len) continue;
        if (std.mem.indexOf(u8, file.path, query)) |idx| {
            var matches = try self.allocator.alloc(usize, query.len);
            defer self.allocator.free(matches);
            var n: usize = 0;
            while (n < query.len) : (n += 1) matches[n] = idx + n;
            from.send(.{ "PRJ", "recent", self.longest_file_path, file.path, matches }) catch return error.ClientFailed;
            i += 1;
            if (i >= max) return i;
        }
    }
    return i;
}

pub fn query_recent_files(self: *Self, from: tp.pid_ref, max: usize, query: []const u8) ClientError!usize {
    if (query.len < 3)
        return self.simple_query_recent_files(from, max, query);
    defer from.send(.{ "PRJ", "recent_done", self.longest_file_path, query }) catch {};

    var searcher = try fuzzig.Ascii.init(
        self.allocator,
        4096, // haystack max size
        4096, // needle max size
        .{ .case_sensitive = false },
    );
    defer searcher.deinit();

    const Match = struct {
        path: []const u8,
        score: i32,
        matches: []const usize,
    };
    var matches = std.ArrayList(Match).init(self.allocator);

    for (self.files.items) |file| {
        const match = searcher.scoreMatches(file.path, query);
        if (match.score) |score| {
            (try matches.addOne()).* = .{
                .path = file.path,
                .score = score,
                .matches = try self.allocator.dupe(usize, match.matches),
            };
        }
    }
    if (matches.items.len == 0) return 0;

    const less_fn = struct {
        fn less_fn(_: void, lhs: Match, rhs: Match) bool {
            return lhs.score > rhs.score;
        }
    }.less_fn;
    std.mem.sort(Match, matches.items, {}, less_fn);

    for (matches.items[0..@min(max, matches.items.len)]) |match|
        from.send(.{ "PRJ", "recent", self.longest_file_path, match.path, match.matches }) catch return error.ClientFailed;
    return @min(max, matches.items.len);
}

pub fn add_pending_file(self: *Self, file_path: []const u8, mtime: i128) OutOfMemoryError!void {
    self.longest_file_path = @max(self.longest_file_path, file_path.len);
    (try self.pending.addOne()).* = .{ .path = try self.allocator.dupe(u8, file_path), .mtime = mtime };
}

pub fn merge_pending_files(self: *Self) OutOfMemoryError!void {
    defer self.sort_files_by_mtime();
    const existing = try self.files.toOwnedSlice();
    self.files = self.pending;
    self.pending = std.ArrayList(File).init(self.allocator);
    for (existing) |*file| {
        self.update_mru_internal(file.path, file.mtime, file.row, file.col) catch {};
        self.allocator.free(file.path);
    }
    self.allocator.free(existing);
}

pub fn update_mru(self: *Self, file_path: []const u8, row: usize, col: usize) OutOfMemoryError!void {
    defer self.sort_files_by_mtime();
    try self.update_mru_internal(file_path, std.time.nanoTimestamp(), row, col);
}

fn update_mru_internal(self: *Self, file_path: []const u8, mtime: i128, row: usize, col: usize) OutOfMemoryError!void {
    for (self.files.items) |*file| {
        if (!std.mem.eql(u8, file.path, file_path)) continue;
        file.mtime = mtime;
        if (row != 0) {
            file.row = row;
            file.col = col;
            file.visited = true;
        }
        return;
    }
    if (row != 0) {
        (try self.files.addOne()).* = .{
            .path = try self.allocator.dupe(u8, file_path),
            .mtime = mtime,
            .row = row,
            .col = col,
            .visited = true,
        };
    } else {
        (try self.files.addOne()).* = .{
            .path = try self.allocator.dupe(u8, file_path),
            .mtime = mtime,
        };
    }
}

pub fn get_mru_position(self: *Self, from: tp.pid_ref, file_path: []const u8) ClientError!void {
    for (self.files.items) |*file| {
        if (!std.mem.eql(u8, file.path, file_path)) continue;
        if (file.row != 0)
            from.send(.{ "cmd", "goto_line_and_column", .{ file.row + 1, file.col + 1 } }) catch return error.ClientFailed;
        return;
    }
}

pub fn did_open(self: *Self, file_path: []const u8, file_type: []const u8, language_server: []const u8, version: usize, text: []const u8) StartLspError!void {
    self.update_mru(file_path, 0, 0) catch {};
    const lsp = try self.get_or_start_language_server(file_path, language_server);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);
    lsp.send_notification("textDocument/didOpen", .{
        .textDocument = .{ .uri = uri, .languageId = file_type, .version = version, .text = text },
    }) catch return error.LspFailed;
}

pub fn did_change(self: *Self, file_path: []const u8, version: usize, root_dst_addr: usize, root_src_addr: usize, eol_mode: Buffer.EolMode) LspError!void {
    const lsp = try self.get_language_server(file_path);
    const uri = try self.make_URI(file_path);

    var arena_ = std.heap.ArenaAllocator.init(self.allocator);
    const arena = arena_.allocator();
    var scratch_alloc: ?[]u32 = null;
    defer {
        const frame = tracy.initZone(@src(), .{ .name = "deinit" });
        self.allocator.free(uri);
        arena_.deinit();
        frame.deinit();
        if (scratch_alloc) |scratch|
            self.allocator.free(scratch);
    }

    const root_dst: Buffer.Root = if (root_dst_addr == 0) return else @ptrFromInt(root_dst_addr);
    const root_src: Buffer.Root = if (root_src_addr == 0) return else @ptrFromInt(root_src_addr);

    var dizzy_edits = std.ArrayListUnmanaged(dizzy.Edit){};
    var dst = std.ArrayList(u8).init(arena);
    var src = std.ArrayList(u8).init(arena);
    var edits_cb = std.ArrayList(u8).init(arena);
    const writer = edits_cb.writer();

    {
        const frame = tracy.initZone(@src(), .{ .name = "store" });
        defer frame.deinit();
        try root_dst.store(dst.writer(), eol_mode);
        try root_src.store(src.writer(), eol_mode);
    }
    const scratch_len = 4 * (dst.items.len + src.items.len) + 2;
    const scratch = blk: {
        const frame = tracy.initZone(@src(), .{ .name = "scratch" });
        defer frame.deinit();
        break :blk try self.allocator.alloc(u32, scratch_len);
    };
    scratch_alloc = scratch;

    {
        const frame = tracy.initZone(@src(), .{ .name = "diff" });
        defer frame.deinit();
        try dizzy.PrimitiveSliceDiffer(u8).diff(arena, &dizzy_edits, src.items, dst.items, scratch);
    }
    var lines_dst: usize = 0;
    var last_offset: usize = 0;
    var edits_count: usize = 0;

    {
        const frame = tracy.initZone(@src(), .{ .name = "transform" });
        defer frame.deinit();
        for (dizzy_edits.items) |dizzy_edit| {
            switch (dizzy_edit.kind) {
                .equal => {
                    scan_char(src.items[dizzy_edit.range.start..dizzy_edit.range.end], &lines_dst, '\n', &last_offset);
                },
                .insert => {
                    const line_start_dst: usize = lines_dst;
                    try cbor.writeValue(writer, .{
                        .range = .{
                            .start = .{ .line = line_start_dst, .character = last_offset },
                            .end = .{ .line = line_start_dst, .character = last_offset },
                        },
                        .text = dst.items[dizzy_edit.range.start..dizzy_edit.range.end],
                    });
                    edits_count += 1;
                    scan_char(dst.items[dizzy_edit.range.start..dizzy_edit.range.end], &lines_dst, '\n', &last_offset);
                },
                .delete => {
                    var line_end_dst: usize = lines_dst;
                    var offset_end_dst: usize = last_offset;
                    scan_char(src.items[dizzy_edit.range.start..dizzy_edit.range.end], &line_end_dst, '\n', &offset_end_dst);
                    try cbor.writeValue(writer, .{
                        .range = .{
                            .start = .{ .line = lines_dst, .character = last_offset },
                            .end = .{ .line = line_end_dst, .character = offset_end_dst },
                        },
                        .text = "",
                    });
                    edits_count += 1;
                },
            }
        }
    }
    {
        const frame = tracy.initZone(@src(), .{ .name = "send" });
        defer frame.deinit();
        var msg = std.ArrayList(u8).init(arena);
        const msg_writer = msg.writer();
        try cbor.writeMapHeader(msg_writer, 2);
        try cbor.writeValue(msg_writer, "textDocument");
        try cbor.writeValue(msg_writer, .{ .uri = uri, .version = version });
        try cbor.writeValue(msg_writer, "contentChanges");
        try cbor.writeArrayHeader(msg_writer, edits_count);
        _ = try msg_writer.write(edits_cb.items);

        lsp.send_notification_raw("textDocument/didChange", msg.items) catch return error.LspFailed;
    }
}

fn scan_char(chars: []const u8, lines: *usize, char: u8, last_offset: ?*usize) void {
    var pos = chars;
    if (last_offset) |off| off.* += pos.len;
    while (pos.len > 0) {
        if (pos[0] == char) {
            if (last_offset) |off| off.* = pos.len - 1;
            lines.* += 1;
        }
        pos = pos[1..];
    }
}

pub fn did_save(self: *Self, file_path: []const u8) LspError!void {
    const lsp = try self.get_language_server(file_path);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);
    lsp.send_notification("textDocument/didSave", .{
        .textDocument = .{ .uri = uri },
    }) catch return error.LspFailed;
}

pub fn did_close(self: *Self, file_path: []const u8) LspError!void {
    const lsp = try self.get_language_server(file_path);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);
    lsp.send_notification("textDocument/didClose", .{
        .textDocument = .{ .uri = uri },
    }) catch return error.LspFailed;
}

pub fn goto_definition(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) SendGotoRequestError!void {
    return self.send_goto_request(from, file_path, row, col, "textDocument/definition");
}

pub fn goto_declaration(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) SendGotoRequestError!void {
    return self.send_goto_request(from, file_path, row, col, "textDocument/declaration");
}

pub fn goto_implementation(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) SendGotoRequestError!void {
    return self.send_goto_request(from, file_path, row, col, "textDocument/implementation");
}

pub fn goto_type_definition(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) SendGotoRequestError!void {
    return self.send_goto_request(from, file_path, row, col, "textDocument/typeDefinition");
}

pub const SendGotoRequestError = (LspError || ClientError || InvalidMessageError || GetLineOfFileError || cbor.Error);

fn send_goto_request(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize, method: []const u8) SendGotoRequestError!void {
    const lsp = try self.get_language_server(file_path);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);
    const response = lsp.send_request(self.allocator, method, .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = row, .character = col },
    }) catch return error.LspFailed;
    defer self.allocator.free(response.buf);
    var link: []const u8 = undefined;
    var locations: []const u8 = undefined;
    if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.array })) {
        if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, .{tp.extract_cbor(&link)} })) {
            try self.navigate_to_location_link(from, link);
        } else if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&locations) })) {
            try self.send_reference_list(from, locations);
        }
    } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.null_ })) {
        return;
    } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.extract_cbor(&link) })) {
        try self.navigate_to_location_link(from, link);
    }
}

fn navigate_to_location_link(_: *Self, from: tp.pid_ref, location_link: []const u8) (ClientError || InvalidMessageError || cbor.Error)!void {
    var iter = location_link;
    var targetUri: ?[]const u8 = null;
    var targetRange: ?Range = null;
    var targetSelectionRange: ?Range = null;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "targetUri") or std.mem.eql(u8, field_name, "uri")) {
            var value: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract(&value)))) return error.InvalidMessageField;
            targetUri = value;
        } else if (std.mem.eql(u8, field_name, "targetRange") or std.mem.eql(u8, field_name, "range")) {
            var range: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range)))) return error.InvalidMessageField;
            targetRange = try read_range(range);
        } else if (std.mem.eql(u8, field_name, "targetSelectionRange")) {
            var range: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range)))) return error.InvalidMessageField;
            targetSelectionRange = try read_range(range);
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (targetUri == null or targetRange == null) return error.InvalidMessageField;
    if (!std.mem.eql(u8, targetUri.?[0..7], "file://")) return error.InvalidTargetURI;
    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var file_path = std.Uri.percentDecodeBackwards(&file_path_buf, targetUri.?[7..]);
    if (builtin.os.tag == .windows) {
        if (file_path[0] == '/') file_path = file_path[1..];
        for (file_path, 0..) |c, i| if (c == '/') {
            file_path[i] = '\\';
        };
    }
    if (targetSelectionRange) |sel| {
        from.send(.{ "cmd", "navigate", .{
            .file = file_path,
            .goto = .{
                targetRange.?.start.line + 1,
                targetRange.?.start.character + 1,
                sel.start.line,
                sel.start.character,
                sel.end.line,
                sel.end.character,
            },
        } }) catch return error.ClientFailed;
    } else {
        from.send(.{ "cmd", "navigate", .{
            .file = file_path,
            .goto = .{
                targetRange.?.start.line + 1,
                targetRange.?.start.character + 1,
            },
        } }) catch return error.ClientFailed;
    }
}

pub fn references(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) SendGotoRequestError!void {
    const lsp = try self.get_language_server(file_path);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);
    log.logger("lsp").print("finding references...", .{});

    const response = lsp.send_request(self.allocator, "textDocument/references", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = row, .character = col },
        .context = .{ .includeDeclaration = true },
    }) catch return error.LspFailed;
    defer self.allocator.free(response.buf);
    var locations: []const u8 = undefined;
    if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.null_ })) {
        return;
    } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.extract_cbor(&locations) })) {
        try self.send_reference_list(from, locations);
    }
}

fn send_reference_list(self: *Self, to: tp.pid_ref, locations: []const u8) (ClientError || InvalidMessageError || GetLineOfFileError || cbor.Error)!void {
    defer to.send(.{ "REF", "done" }) catch {};
    var iter = locations;
    var len = try cbor.decodeArrayHeader(&iter);
    const count = len;
    while (len > 0) : (len -= 1) {
        var location: []const u8 = undefined;
        if (try cbor.matchValue(&iter, cbor.extract_cbor(&location))) {
            try self.send_reference(to, location);
        } else return error.InvalidMessageField;
    }
    log.logger("lsp").print("found {d} references", .{count});
}

fn send_reference(self: *Self, to: tp.pid_ref, location: []const u8) (ClientError || InvalidMessageError || GetLineOfFileError || cbor.Error)!void {
    var iter = location;
    var targetUri: ?[]const u8 = null;
    var targetRange: ?Range = null;
    var targetSelectionRange: ?Range = null;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "targetUri") or std.mem.eql(u8, field_name, "uri")) {
            var value: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract(&value)))) return error.InvalidMessageField;
            targetUri = value;
        } else if (std.mem.eql(u8, field_name, "targetRange") or std.mem.eql(u8, field_name, "range")) {
            var range: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range)))) return error.InvalidMessageField;
            targetRange = try read_range(range);
        } else if (std.mem.eql(u8, field_name, "targetSelectionRange")) {
            var range: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range)))) return error.InvalidMessageField;
            targetSelectionRange = try read_range(range);
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (targetUri == null or targetRange == null) return error.InvalidMessageField;
    if (!std.mem.eql(u8, targetUri.?[0..7], "file://")) return error.InvalidTargetURI;
    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var file_path = std.Uri.percentDecodeBackwards(&file_path_buf, targetUri.?[7..]);
    if (builtin.os.tag == .windows) {
        if (file_path[0] == '/') file_path = file_path[1..];
        for (file_path, 0..) |c, i| if (c == '/') {
            file_path[i] = '\\';
        };
    }
    const line = try self.get_line_of_file(self.allocator, file_path, targetRange.?.start.line);
    defer self.allocator.free(line);
    const file_path_ = if (file_path.len > self.name.len and std.mem.eql(u8, self.name, file_path[0..self.name.len]))
        file_path[self.name.len + 1 ..]
    else
        file_path;
    to.send(.{
        "REF",
        file_path_,
        targetRange.?.start.line + 1,
        targetRange.?.start.character,
        targetRange.?.end.line + 1,
        targetRange.?.end.character,
        line,
    }) catch return error.ClientFailed;
}

pub fn completion(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) (LspOrClientError || InvalidMessageError || cbor.Error)!void {
    const lsp = try self.get_language_server(file_path);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);
    const response = lsp.send_request(self.allocator, "textDocument/completion", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = row, .character = col },
    }) catch return error.LspFailed;
    defer self.allocator.free(response.buf);
    var result: []const u8 = undefined;
    if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.null_ })) {
        try send_content_msg_empty(from, "hover", file_path, row, col);
    } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.array })) {
        if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&result) }))
            try self.send_completion_items(from, file_path, row, col, result, false);
    } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.map })) {
        if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&result) }))
            try self.send_completion_list(from, file_path, row, col, result);
    }
}

fn send_completion_list(self: *Self, to: tp.pid_ref, file_path: []const u8, row: usize, col: usize, result: []const u8) (ClientError || InvalidMessageError || cbor.Error)!void {
    var iter = result;
    var len = cbor.decodeMapHeader(&iter) catch return;
    var items: []const u8 = "";
    var is_incomplete: bool = false;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "items")) {
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&items)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "isIncomplete")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&is_incomplete)))) return error.InvalidMessageField;
        } else {
            try cbor.skipValue(&iter);
        }
    }
    return self.send_completion_items(to, file_path, row, col, items, is_incomplete) catch error.ClientFailed;
}

fn send_completion_items(self: *Self, to: tp.pid_ref, file_path: []const u8, row: usize, col: usize, items: []const u8, is_incomplete: bool) (ClientError || InvalidMessageError || cbor.Error)!void {
    var iter = items;
    var len = cbor.decodeArrayHeader(&iter) catch return;
    var item: []const u8 = "";
    while (len > 0) : (len -= 1) {
        if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&item)))) return error.InvalidMessageField;
        self.send_completion_item(to, file_path, row, col, item, if (len > 1) true else is_incomplete) catch return error.ClientFailed;
    }
}

fn send_completion_item(_: *Self, to: tp.pid_ref, file_path: []const u8, row: usize, col: usize, item: []const u8, is_incomplete: bool) (ClientError || InvalidMessageError || cbor.Error)!void {
    var label: []const u8 = "";
    var label_detail: []const u8 = "";
    var label_description: []const u8 = "";
    var kind: usize = 0;
    var detail: []const u8 = "";
    var documentation: []const u8 = "";
    var documentation_kind: []const u8 = "";
    var sortText: []const u8 = "";
    var insertTextFormat: usize = 0;
    var textEdit_newText: []const u8 = "";
    var textEdit_insert: ?Range = null;
    var textEdit_replace: ?Range = null;

    var iter = item;
    var len = cbor.decodeMapHeader(&iter) catch return;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "label")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&label)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "labelDetails")) {
            var len_ = cbor.decodeMapHeader(&iter) catch return;
            while (len_ > 0) : (len_ -= 1) {
                if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
                if (std.mem.eql(u8, field_name, "detail")) {
                    if (!(try cbor.matchValue(&iter, cbor.extract(&label_detail)))) return error.InvalidMessageField;
                } else if (std.mem.eql(u8, field_name, "description")) {
                    if (!(try cbor.matchValue(&iter, cbor.extract(&label_description)))) return error.InvalidMessageField;
                } else {
                    try cbor.skipValue(&iter);
                }
            }
        } else if (std.mem.eql(u8, field_name, "kind")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&kind)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "detail")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&detail)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "documentation")) {
            var len_ = cbor.decodeMapHeader(&iter) catch return;
            while (len_ > 0) : (len_ -= 1) {
                if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
                if (std.mem.eql(u8, field_name, "kind")) {
                    if (!(try cbor.matchValue(&iter, cbor.extract(&documentation_kind)))) return error.InvalidMessageField;
                } else if (std.mem.eql(u8, field_name, "value")) {
                    if (!(try cbor.matchValue(&iter, cbor.extract(&documentation)))) return error.InvalidMessageField;
                } else {
                    try cbor.skipValue(&iter);
                }
            }
        } else if (std.mem.eql(u8, field_name, "sortText")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&sortText)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "insertTextFormat")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&insertTextFormat)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "textEdit")) {
            // var textEdit: []const u8 = ""; // { "newText": "wait_expired(${1:timeout_ns: isize})", "insert": Range, "replace": Range },
            var len_ = cbor.decodeMapHeader(&iter) catch return;
            while (len_ > 0) : (len_ -= 1) {
                if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
                if (std.mem.eql(u8, field_name, "newText")) {
                    if (!(try cbor.matchValue(&iter, cbor.extract(&textEdit_newText)))) return error.InvalidMessageField;
                } else if (std.mem.eql(u8, field_name, "insert")) {
                    var range_: []const u8 = undefined;
                    if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range_)))) return error.InvalidMessageField;
                    textEdit_insert = try read_range(range_);
                } else if (std.mem.eql(u8, field_name, "replace")) {
                    var range_: []const u8 = undefined;
                    if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range_)))) return error.InvalidMessageField;
                    textEdit_replace = try read_range(range_);
                } else {
                    try cbor.skipValue(&iter);
                }
            }
        } else {
            try cbor.skipValue(&iter);
        }
    }
    const insert = textEdit_insert orelse return error.InvalidMessageField;
    const replace = textEdit_replace orelse return error.InvalidMessageField;
    return to.send(.{
        "completion_item",
        file_path,
        row,
        col,
        is_incomplete,
        label,
        label_detail,
        label_description,
        kind,
        detail,
        documentation,
        sortText,
        insertTextFormat,
        textEdit_newText,
        insert.start.line,
        insert.start.character,
        insert.end.line,
        insert.end.character,
        replace.start.line,
        replace.start.character,
        replace.end.line,
        replace.end.character,
    }) catch error.ClientFailed;
}

const Rename = struct {
    uri: []const u8,
    new_text: []const u8,
    range: Range,
};

pub fn rename_symbol(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) (LspOrClientError || InvalidMessageError || cbor.Error)!void {
    const lsp = try self.get_language_server(file_path);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);
    const response = lsp.send_request(self.allocator, "textDocument/rename", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = row, .character = col },
        .newName = "foobar",
    }) catch return error.LspFailed;
    defer self.allocator.free(response.buf);
    var result: []const u8 = undefined;
    // buffer the renames in order to send as a single, atomic message
    var renames = std.ArrayList(Rename).init(self.allocator);
    defer renames.deinit();

    if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.map })) {
        if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&result) })) {
            try self.decode_rename_symbol_map(result, &renames);
            // write the renames message manually since there doesn't appear to be an array helper
            var msg_buf = std.ArrayList(u8).init(self.allocator);
            defer msg_buf.deinit();
            const w = msg_buf.writer();
            try cbor.writeArrayHeader(w, 3);
            try cbor.writeValue(w, "cmd");
            try cbor.writeValue(w, "rename_symbol_item");
            try cbor.writeArrayHeader(w, renames.items.len);
            for (renames.items) |rename| {
                var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const file_path_ = std.Uri.percentDecodeBackwards(&file_path_buf, rename.uri[7..]);
                try cbor.writeValue(w, .{
                    file_path_,
                    rename.range.start.line,
                    rename.range.start.character,
                    rename.range.end.line,
                    rename.range.end.character,
                    rename.new_text,
                });
            }
            from.send_raw(.{ .buf = msg_buf.items }) catch return error.ClientFailed;
        }
    }
}

// decode a WorkspaceEdit record which may have shape {"changes": {}} or {"documentChanges": []}
// https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workspaceEdit
fn decode_rename_symbol_map(self: *Self, result: []const u8, renames: *std.ArrayList(Rename)) (ClientError || InvalidMessageError || cbor.Error)!void {
    var iter = result;
    var len = cbor.decodeMapHeader(&iter) catch return error.InvalidMessage;
    var changes: []const u8 = "";
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "changes")) {
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&changes)))) return error.InvalidMessageField;
            try self.decode_rename_symbol_changes(changes, renames);
            return;
        } else if (std.mem.eql(u8, field_name, "documentChanges")) {
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&changes)))) return error.InvalidMessageField;
            try self.decode_rename_symbol_doc_changes(changes, renames);
            return;
        } else {
            try cbor.skipValue(&iter);
        }
    }
    return error.ClientFailed;
}

fn decode_rename_symbol_changes(self: *Self, changes: []const u8, renames: *std.ArrayList(Rename)) (ClientError || InvalidMessageError || cbor.Error)!void {
    var iter = changes;
    var files_len = cbor.decodeMapHeader(&iter) catch return error.InvalidMessage;
    while (files_len > 0) : (files_len -= 1) {
        var file_uri: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &file_uri))) return error.InvalidMessage;
        try decode_rename_symbol_item(self, file_uri, iter, renames);
    }
}

fn decode_rename_symbol_doc_changes(self: *Self, changes: []const u8, renames: *std.ArrayList(Rename)) (ClientError || InvalidMessageError || cbor.Error)!void {
    var iter = changes;
    var changes_len = cbor.decodeArrayHeader(&iter) catch return error.InvalidMessage;
    while (changes_len > 0) : (changes_len -= 1) {
        var dc_fields_len = cbor.decodeMapHeader(&iter) catch return error.InvalidMessage;
        var file_uri: []const u8 = "";
        while (dc_fields_len > 0) : (dc_fields_len -= 1) {
            var field_name: []const u8 = undefined;
            if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
            if (std.mem.eql(u8, field_name, "textDocument")) {
                var td_fields_len = cbor.decodeMapHeader(&iter) catch return error.InvalidMessage;
                while (td_fields_len > 0) : (td_fields_len -= 1) {
                    var td_field_name: []const u8 = undefined;
                    if (!(try cbor.matchString(&iter, &td_field_name))) return error.InvalidMessage;
                    if (std.mem.eql(u8, td_field_name, "uri")) {
                        if (!(try cbor.matchString(&iter, &file_uri))) return error.InvalidMessage;
                    } else try cbor.skipValue(&iter); // skip "version": 1
                }
            } else if (std.mem.eql(u8, field_name, "edits")) {
                if (file_uri.len == 0) return error.InvalidMessage;
                try decode_rename_symbol_item(self, file_uri, iter, renames);
            }
        }
    }
}

// https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textEdit
fn decode_rename_symbol_item(_: *Self, file_uri: []const u8, _iter: []const u8, renames: *std.ArrayList(Rename)) (ClientError || InvalidMessageError || cbor.Error)!void {
    var iter = _iter;
    var text_edits_len = cbor.decodeArrayHeader(&iter) catch return error.InvalidMessage;
    while (text_edits_len > 0) : (text_edits_len -= 1) {
        var m_range: ?Range = null;
        var new_text: []const u8 = "";
        var edits_len = cbor.decodeMapHeader(&iter) catch return error.InvalidMessage;
        while (edits_len > 0) : (edits_len -= 1) {
            var field_name: []const u8 = undefined;
            if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
            if (std.mem.eql(u8, field_name, "range")) {
                var range: []const u8 = undefined;
                if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range)))) return error.InvalidMessageField;
                m_range = try read_range(range);
            } else if (std.mem.eql(u8, field_name, "newText")) {
                if (!(try cbor.matchString(&iter, &new_text))) return error.InvalidMessageField;
            } else {
                try cbor.skipValue(&iter);
            }
        }

        const range = m_range orelse return error.InvalidMessageField;
        try renames.append(.{ .uri = file_uri, .range = range, .new_text = new_text });
    }
}

pub fn hover(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) (LspOrClientError || InvalidMessageError || cbor.Error)!void {
    const lsp = try self.get_language_server(file_path);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);
    // log.logger("lsp").print("fetching hover information...", .{});

    const response = lsp.send_request(self.allocator, "textDocument/hover", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = row, .character = col },
    }) catch return error.LspFailed;
    defer self.allocator.free(response.buf);
    var result: []const u8 = undefined;
    if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.null_ })) {
        try send_content_msg_empty(from, "hover", file_path, row, col);
    } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.extract_cbor(&result) })) {
        try self.send_hover(from, file_path, row, col, result);
    }
}

fn send_hover(self: *Self, to: tp.pid_ref, file_path: []const u8, row: usize, col: usize, result: []const u8) (ClientError || InvalidMessageError || cbor.Error)!void {
    var iter = result;
    var len = cbor.decodeMapHeader(&iter) catch return;
    var contents: []const u8 = "";
    var range: ?Range = null;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "contents")) {
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&contents)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "range")) {
            var range_: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range_)))) return error.InvalidMessageField;
            range = try read_range(range_);
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (contents.len > 0)
        return self.send_contents(to, "hover", file_path, row, col, contents, range);
}

fn send_contents(
    self: *Self,
    to: tp.pid_ref,
    tag: []const u8,
    file_path: []const u8,
    row: usize,
    col: usize,
    result: []const u8,
    range: ?Range,
) !void {
    var iter = result;
    var kind: []const u8 = "plaintext";
    var value: []const u8 = "";
    if (try cbor.matchValue(&iter, cbor.extract(&value)))
        return send_content_msg(to, tag, file_path, row, col, kind, value, range);

    var is_list = true;
    var len = cbor.decodeArrayHeader(&iter) catch blk: {
        is_list = false;
        iter = result;
        break :blk cbor.decodeMapHeader(&iter) catch return;
    };

    if (is_list) {
        var content = std.ArrayList(u8).init(self.allocator);
        defer content.deinit();
        while (len > 0) : (len -= 1) {
            if (try cbor.matchValue(&iter, cbor.extract(&value))) {
                try content.appendSlice(value);
                if (len > 1) try content.appendSlice("\n");
            }
        }
        return send_content_msg(to, tag, file_path, row, col, kind, content.items, range);
    }

    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "kind")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&kind)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "value")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&value)))) return error.InvalidMessageField;
        } else {
            try cbor.skipValue(&iter);
        }
    }
    return send_content_msg(to, tag, file_path, row, col, kind, value, range);
}

fn send_content_msg(
    to: tp.pid_ref,
    tag: []const u8,
    file_path: []const u8,
    row: usize,
    col: usize,
    kind: []const u8,
    content: []const u8,
    range: ?Range,
) ClientError!void {
    const r = range orelse Range{
        .start = .{ .line = row, .character = col },
        .end = .{ .line = row, .character = col },
    };
    to.send(.{ tag, file_path, kind, content, r.start.line, r.start.character, r.end.line, r.end.character }) catch return error.ClientFailed;
}

fn send_content_msg_empty(to: tp.pid_ref, tag: []const u8, file_path: []const u8, row: usize, col: usize) ClientError!void {
    return send_content_msg(to, tag, file_path, row, col, "plaintext", "", null);
}

pub fn publish_diagnostics(self: *Self, to: tp.pid_ref, params_cb: []const u8) (ClientError || InvalidMessageError || cbor.Error)!void {
    var uri: ?[]const u8 = null;
    var diagnostics: []const u8 = &.{};
    var iter = params_cb;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "uri")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&uri)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "diagnostics")) {
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&diagnostics)))) return error.InvalidMessageField;
        } else {
            try cbor.skipValue(&iter);
        }
    }

    if (uri == null) return error.InvalidMessageField;
    if (!std.mem.eql(u8, uri.?[0..7], "file://")) return error.InvalidTargetURI;
    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = std.Uri.percentDecodeBackwards(&file_path_buf, uri.?[7..]);

    try self.send_clear_diagnostics(to, file_path);

    iter = diagnostics;
    len = try cbor.decodeArrayHeader(&iter);
    while (len > 0) : (len -= 1) {
        var diagnostic: []const u8 = undefined;
        if (try cbor.matchValue(&iter, cbor.extract_cbor(&diagnostic))) {
            try self.send_diagnostic(to, file_path, diagnostic);
        } else return error.InvalidMessageField;
    }
}

fn send_diagnostic(_: *Self, to: tp.pid_ref, file_path: []const u8, diagnostic: []const u8) (ClientError || InvalidMessageError || cbor.Error)!void {
    var source: []const u8 = "unknown";
    var code: []const u8 = "none";
    var message: []const u8 = "empty";
    var severity: i64 = 1;
    var range: ?Range = null;
    var iter = diagnostic;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "source") or std.mem.eql(u8, field_name, "uri")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&source)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "code")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&code)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "message")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&message)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "severity")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&severity)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "range")) {
            var range_: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range_)))) return error.InvalidMessageField;
            range = try read_range(range_);
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (range == null) return error.InvalidMessageField;
    to.send(.{ "cmd", "add_diagnostic", .{
        file_path,
        source,
        code,
        message,
        severity,
        range.?.start.line,
        range.?.start.character,
        range.?.end.line,
        range.?.end.character,
    } }) catch return error.ClientFailed;
}

fn send_clear_diagnostics(_: *Self, to: tp.pid_ref, file_path: []const u8) ClientError!void {
    to.send(.{ "cmd", "clear_diagnostics", .{file_path} }) catch return error.ClientFailed;
}

const Range = struct { start: Position, end: Position };
fn read_range(range: []const u8) !Range {
    var iter = range;
    var start: ?Position = null;
    var end: ?Position = null;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "start")) {
            var position: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&position)))) return error.InvalidMessageField;
            start = try read_position(position);
        } else if (std.mem.eql(u8, field_name, "end")) {
            var position: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&position)))) return error.InvalidMessageField;
            end = try read_position(position);
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (start == null or end == null) return error.InvalidMessageField;
    return .{ .start = start.?, .end = end.? };
}

const Position = struct { line: usize, character: usize };
fn read_position(position: []const u8) !Position {
    var iter = position;
    var line: ?usize = 0;
    var character: ?usize = 0;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "line")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&line)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "character")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&character)))) return error.InvalidMessageField;
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (line == null or character == null) return error.InvalidMessageField;
    return .{ .line = line.?, .character = character.? };
}

pub fn show_message(_: *Self, _: tp.pid_ref, params_cb: []const u8) !void {
    var type_: i32 = 0;
    var message: ?[]const u8 = null;
    var iter = params_cb;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidMessage;
        if (std.mem.eql(u8, field_name, "type")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&type_)))) return error.InvalidMessageField;
        } else if (std.mem.eql(u8, field_name, "message")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&message)))) return error.InvalidMessageField;
        } else {
            try cbor.skipValue(&iter);
        }
    }
    const msg = message orelse return;
    const logger = log.logger("lsp");
    defer logger.deinit();
    if (type_ <= 2)
        logger.err_msg("lsp", msg)
    else
        logger.print("{s}", .{msg});
}

pub fn register_capability(self: *Self, from: tp.pid_ref, cbor_id: []const u8, params_cb: []const u8) ClientError!void {
    _ = params_cb;
    return self.send_lsp_response(from, cbor_id, null);
}

pub fn workDoneProgress_create(self: *Self, from: tp.pid_ref, cbor_id: []const u8, params_cb: []const u8) ClientError!void {
    _ = params_cb;
    return self.send_lsp_response(from, cbor_id, null);
}

pub fn send_lsp_response(self: *Self, from: tp.pid_ref, cbor_id: []const u8, result: anytype) ClientError!void {
    var cb = std.ArrayList(u8).init(self.allocator);
    defer cb.deinit();
    const writer = cb.writer();
    try cbor.writeArrayHeader(writer, 3);
    try cbor.writeValue(writer, "RSP");
    try writer.writeAll(cbor_id);
    try cbor.writeValue(cb.writer(), result);
    from.send_raw(.{ .buf = cb.items }) catch return error.ClientFailed;
}

fn send_lsp_init_request(self: *Self, lsp: LSP, project_path: []const u8, project_basename: []const u8, project_uri: []const u8) CallError!tp.message {
    return lsp.send_request(self.allocator, "initialize", .{
        .processId = if (builtin.os.tag == .linux) std.os.linux.getpid() else null,
        .rootPath = project_path,
        .rootUri = project_uri,
        .workspaceFolders = .{
            .{
                .uri = project_uri,
                .name = project_basename,
            },
        },
        .trace = "verbose",
        .locale = "en-us",
        .clientInfo = .{
            .name = root.application_name,
            .version = "0.0.1",
        },
        .capabilities = .{
            .workspace = .{
                .applyEdit = true,
                .workspaceEdit = .{
                    .documentChanges = true,
                    .resourceOperations = .{
                        "create",
                        "rename",
                        "delete",
                    },
                    .failureHandling = "textOnlyTransactional",
                    .normalizesLineEndings = true,
                    .changeAnnotationSupport = .{ .groupsOnLabel = true },
                },
                // .configuration = true,
                .didChangeWatchedFiles = .{
                    .dynamicRegistration = true,
                    .relativePatternSupport = true,
                },
                .symbol = .{
                    .dynamicRegistration = true,
                    .symbolKind = .{
                        .valueSet = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26 },
                    },
                    .tagSupport = .{ .valueSet = .{1} },
                    .resolveSupport = .{ .properties = .{"location.range"} },
                },
                .codeLens = .{ .refreshSupport = false },
                .executeCommand = .{ .dynamicRegistration = true },
                // .didChangeConfiguration = .{ .dynamicRegistration = true },
                .workspaceFolders = true,
                .semanticTokens = .{ .refreshSupport = false },
                .fileOperations = .{
                    .dynamicRegistration = true,
                    .didCreate = true,
                    .didRename = true,
                    .didDelete = true,
                    .willCreate = true,
                    .willRename = true,
                    .willDelete = true,
                },
                .inlineValue = .{ .refreshSupport = false },
                .inlayHint = .{ .refreshSupport = false },
                .diagnostics = .{ .refreshSupport = true },
            },
            .textDocument = .{
                .publishDiagnostics = .{
                    .relatedInformation = true,
                    .versionSupport = false,
                    .tagSupport = .{ .valueSet = .{ 1, 2 } },
                    .codeDescriptionSupport = true,
                    .dataSupport = true,
                },
                .synchronization = .{
                    .dynamicRegistration = true,
                    .willSave = true,
                    .willSaveWaitUntil = true,
                    .didSave = true,
                },
                .completion = .{
                    .dynamicRegistration = true,
                    .contextSupport = true,
                    .completionItem = .{
                        .snippetSupport = true,
                        .commitCharactersSupport = true,
                        .documentationFormat = .{
                            // "markdown",
                            "plaintext",
                        },
                        .deprecatedSupport = true,
                        .preselectSupport = true,
                        .tagSupport = .{ .valueSet = .{1} },
                        .insertReplaceSupport = true,
                        .resolveSupport = .{ .properties = .{
                            "documentation",
                            "detail",
                            "additionalTextEdits",
                        } },
                        .insertTextModeSupport = .{ .valueSet = .{ 1, 2 } },
                        .labelDetailsSupport = true,
                    },
                    .insertTextMode = 2,
                    .completionItemKind = .{
                        .valueSet = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25 },
                    },
                    .completionList = .{ .itemDefaults = .{
                        "commitCharacters",
                        "editRange",
                        "insertTextFormat",
                        "insertTextMode",
                    } },
                },
                .hover = .{
                    .dynamicRegistration = true,
                    .contentFormat = .{
                        // "markdown",
                        "plaintext",
                    },
                },
                .signatureHelp = .{
                    .dynamicRegistration = true,
                    .signatureInformation = .{
                        .documentationFormat = .{
                            // "markdown",
                            "plaintext",
                        },
                        .parameterInformation = .{ .labelOffsetSupport = true },
                        .activeParameterSupport = true,
                    },
                    .contextSupport = true,
                },
                .definition = .{
                    .dynamicRegistration = true,
                    .linkSupport = true,
                },
                .references = .{ .dynamicRegistration = true },
                .documentHighlight = .{ .dynamicRegistration = true },
                .documentSymbol = .{
                    .dynamicRegistration = true,
                    .symbolKind = .{
                        .valueSet = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26 },
                    },
                    .hierarchicalDocumentSymbolSupport = true,
                    .tagSupport = .{ .valueSet = .{1} },
                    .labelSupport = true,
                },
                .codeAction = .{
                    .dynamicRegistration = true,
                    .isPreferredSupport = true,
                    .disabledSupport = true,
                    .dataSupport = true,
                    .resolveSupport = .{ .properties = .{"edit"} },
                    .codeActionLiteralSupport = .{
                        .codeActionKind = .{
                            .valueSet = .{
                                "",
                                "quickfix",
                                "refactor",
                                "refactor.extract",
                                "refactor.inline",
                                "refactor.rewrite",
                                "source",
                                "source.organizeImports",
                            },
                        },
                    },
                    .honorsChangeAnnotations = false,
                },
                .codeLens = .{ .dynamicRegistration = true },
                .formatting = .{ .dynamicRegistration = true },
                .rangeFormatting = .{ .dynamicRegistration = true },
                .onTypeFormatting = .{ .dynamicRegistration = true },
                .rename = .{
                    .dynamicRegistration = true,
                    .prepareSupport = true,
                    .prepareSupportDefaultBehavior = 1,
                    .honorsChangeAnnotations = true,
                },
                .documentLink = .{
                    .dynamicRegistration = true,
                    .tooltipSupport = true,
                },
                .typeDefinition = .{
                    .dynamicRegistration = true,
                    .linkSupport = true,
                },
                .implementation = .{
                    .dynamicRegistration = true,
                    .linkSupport = true,
                },
                .colorProvider = .{ .dynamicRegistration = true },
                .foldingRange = .{
                    .dynamicRegistration = true,
                    .rangeLimit = 5000,
                    .lineFoldingOnly = true,
                    .foldingRangeKind = .{ .valueSet = .{ "comment", "imports", "region" } },
                    .foldingRange = .{ .collapsedText = false },
                },
                .declaration = .{
                    .dynamicRegistration = true,
                    .linkSupport = true,
                },
                .selectionRange = .{ .dynamicRegistration = true },
                .callHierarchy = .{ .dynamicRegistration = true },
                .semanticTokens = .{
                    .dynamicRegistration = true,
                    .tokenTypes = .{
                        "namespace",
                        "type",
                        "class",
                        "enum",
                        "interface",
                        "struct",
                        "typeParameter",
                        "parameter",
                        "variable",
                        "property",
                        "enumMember",
                        "event",
                        "function",
                        "method",
                        "macro",
                        "keyword",
                        "modifier",
                        "comment",
                        "string",
                        "number",
                        "regexp",
                        "operator",
                        "decorator",
                    },
                    .tokenModifiers = .{
                        "declaration",
                        "definition",
                        "readonly",
                        "static",
                        "deprecated",
                        "abstract",
                        "async",
                        "modification",
                        "documentation",
                        "defaultLibrary",
                    },
                    .formats = .{"relative"},
                    .requests = .{
                        .range = true,
                        .full = .{ .delta = true },
                    },
                    .multilineTokenSupport = false,
                    .overlappingTokenSupport = false,
                    .serverCancelSupport = true,
                    .augmentsSyntaxTokens = true,
                },
                .linkedEditingRange = .{ .dynamicRegistration = true },
                .typeHierarchy = .{ .dynamicRegistration = true },
                .inlineValue = .{ .dynamicRegistration = true },
                .inlayHint = .{
                    .dynamicRegistration = true,
                    .resolveSupport = .{
                        .properties = .{
                            "tooltip",
                            "textEdits",
                            "label.tooltip",
                            "label.location",
                            "label.command",
                        },
                    },
                },
                .diagnostic = .{
                    .dynamicRegistration = true,
                    .relatedDocumentSupport = false,
                },
            },
            .window = .{
                .showMessage = .{
                    .messageActionItem = .{ .additionalPropertiesSupport = true },
                },
                .showDocument = .{ .support = true },
                .workDoneProgress = false,
            },
            .general = .{
                .staleRequestSupport = .{
                    .cancel = true,
                    .retryOnContentModified = .{
                        "textDocument/semanticTokens/full",
                        "textDocument/semanticTokens/range",
                        "textDocument/semanticTokens/full/delta",
                    },
                },
                .regularExpressions = .{
                    .engine = "ECMAScript",
                    .version = "ES2020",
                },
                .markdown = .{
                    .parser = "marked",
                    .version = "1.1.0",
                },
                .positionEncodings = .{"utf-8"},
            },
            .notebookDocument = .{
                .synchronization = .{
                    .dynamicRegistration = true,
                    .executionSummarySupport = true,
                },
            },
        },
    });
}

fn fmt_lsp_name_func(bytes: []const u8) std.fmt.Formatter(format_lsp_name_func) {
    return .{ .data = bytes };
}

fn format_lsp_name_func(
    bytes: []const u8,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;
    var iter: []const u8 = bytes;
    var len = cbor.decodeArrayHeader(&iter) catch return;
    var first: bool = true;
    while (len > 0) : (len -= 1) {
        var value: []const u8 = undefined;
        if (!(cbor.matchValue(&iter, cbor.extract(&value)) catch return))
            return;
        if (first) first = false else try writer.writeAll(" ");
        try writer.writeAll(value);
    }
}

const eol = '\n';

const GetLineOfFileError = (OutOfMemoryError || std.fs.File.OpenError || std.fs.File.Reader.Error);

fn get_line_of_file(self: *Self, allocator: std.mem.Allocator, file_path: []const u8, line_: usize) GetLineOfFileError![]const u8 {
    const line = line_ + 1;
    const file = try std.fs.cwd().openFile(file_path, .{ .mode = .read_only });
    defer file.close();
    const stat = try file.stat();
    var buf = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(buf);
    const read_size = try file.reader().readAll(buf);
    if (read_size != @as(@TypeOf(read_size), @intCast(stat.size)))
        @panic("get_line_of_file: buffer underrun");

    var line_count: usize = 1;
    for (0..buf.len) |i| {
        if (line_count == line)
            return self.get_line(allocator, buf[i..]);
        if (buf[i] == eol) line_count += 1;
    }
    return allocator.dupe(u8, "");
}

pub fn get_line(_: *Self, allocator: std.mem.Allocator, buf: []const u8) ![]const u8 {
    for (0..buf.len) |i| {
        if (buf[i] == eol) return allocator.dupe(u8, buf[0..i]);
    }
    return allocator.dupe(u8, buf);
}
