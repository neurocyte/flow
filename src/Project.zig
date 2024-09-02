const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const root = @import("root");
const dizzy = @import("dizzy");
const Buffer = @import("Buffer");
const fuzzig = @import("fuzzig");
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

const File = struct {
    path: []const u8,
    mtime: i128,
    row: usize = 0,
    col: usize = 0,
    visited: bool = false,
};

pub fn init(allocator: std.mem.Allocator, name: []const u8) error{OutOfMemory}!Self {
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
        error.CborTooShort => return,
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

fn get_lsp(self: *Self, language_server: []const u8) !LSP {
    if (self.language_servers.get(language_server)) |lsp| return lsp;
    const logger = log.logger("lsp");
    errdefer |e| logger.print_err("get_lsp", "failed to initialize LSP: {s} -> {any}", .{ fmt_lsp_name_func(language_server), e });
    const lsp = try LSP.open(self.allocator, self.name, .{ .buf = language_server });
    try self.language_servers.put(try self.allocator.dupe(u8, language_server), lsp);
    const uri = try self.make_URI(null);
    defer self.allocator.free(uri);
    const basename_begin = std.mem.lastIndexOfScalar(u8, self.name, std.fs.path.sep);
    const basename = if (basename_begin) |begin| self.name[begin + 1 ..] else self.name;
    const response = try self.send_lsp_init_request(lsp, self.name, basename, uri);
    defer self.allocator.free(response.buf);
    try lsp.send_notification("initialized", .{});
    logger.print("initialized LSP: {s}", .{fmt_lsp_name_func(language_server)});
    return lsp;
}

fn get_file_lsp(self: *Self, file_path: []const u8) !LSP {
    const logger = log.logger("lsp");
    errdefer logger.print_err("get_file_lsp", "no LSP found for file: {s} ({s})", .{
        std.fmt.fmtSliceEscapeLower(file_path),
        self.name,
    });
    const lsp = self.file_language_server.get(file_path) orelse return tp.exit("no language server");
    if (lsp.pid.expired()) return tp.exit("no language server");
    return lsp;
}

fn make_URI(self: *Self, file_path: ?[]const u8) ![]const u8 {
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

pub fn request_most_recent_file(self: *Self, from: tp.pid_ref) error{ OutOfMemory, Exit }!void {
    const file_path = if (self.files.items.len > 0) self.files.items[0].path else null;
    try from.send(.{file_path});
}

pub fn request_recent_files(self: *Self, from: tp.pid_ref, max: usize) error{ OutOfMemory, Exit }!void {
    defer from.send(.{ "PRJ", "recent_done", self.longest_file_path, "" }) catch {};
    for (self.files.items, 0..) |file, i| {
        try from.send(.{ "PRJ", "recent", self.longest_file_path, file.path });
        if (i >= max) return;
    }
}

fn simple_query_recent_files(self: *Self, from: tp.pid_ref, max: usize, query: []const u8) error{ OutOfMemory, Exit }!usize {
    var i: usize = 0;
    defer from.send(.{ "PRJ", "recent_done", self.longest_file_path, query }) catch {};
    for (self.files.items) |file| {
        if (file.path.len < query.len) continue;
        if (std.mem.indexOf(u8, file.path, query)) |idx| {
            var matches = try self.allocator.alloc(usize, query.len);
            defer self.allocator.free(matches);
            var n: usize = 0;
            while (n < query.len) : (n += 1) matches[n] = idx + n;
            try from.send(.{ "PRJ", "recent", self.longest_file_path, file.path, matches });
            i += 1;
            if (i >= max) return i;
        }
    }
    return i;
}

pub fn query_recent_files(self: *Self, from: tp.pid_ref, max: usize, query: []const u8) error{ OutOfMemory, Exit }!usize {
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
        try from.send(.{ "PRJ", "recent", self.longest_file_path, match.path, match.matches });
    return @min(max, matches.items.len);
}

pub fn add_pending_file(self: *Self, file_path: []const u8, mtime: i128) error{OutOfMemory}!void {
    self.longest_file_path = @max(self.longest_file_path, file_path.len);
    (try self.pending.addOne()).* = .{ .path = try self.allocator.dupe(u8, file_path), .mtime = mtime };
}

pub fn merge_pending_files(self: *Self) error{OutOfMemory}!void {
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

pub fn update_mru(self: *Self, file_path: []const u8, row: usize, col: usize) !void {
    defer self.sort_files_by_mtime();
    try self.update_mru_internal(file_path, std.time.nanoTimestamp(), row, col);
}

fn update_mru_internal(self: *Self, file_path: []const u8, mtime: i128, row: usize, col: usize) !void {
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

pub fn get_mru_position(self: *Self, from: tp.pid_ref, file_path: []const u8) !void {
    for (self.files.items) |*file| {
        if (!std.mem.eql(u8, file.path, file_path)) continue;
        if (file.row != 0)
            try from.send(.{ "cmd", "goto_line_and_column", .{ file.row + 1, file.col + 1 } });
        return;
    }
}

pub fn did_open(self: *Self, file_path: []const u8, file_type: []const u8, language_server: []const u8, version: usize, text: []const u8) !void {
    self.update_mru(file_path, 0, 0) catch {};
    const lsp = try self.get_lsp(language_server);
    if (!self.file_language_server.contains(file_path)) {
        const key = try self.allocator.dupe(u8, file_path);
        try self.file_language_server.put(key, lsp);
    }
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);
    try lsp.send_notification("textDocument/didOpen", .{
        .textDocument = .{ .uri = uri, .languageId = file_type, .version = version, .text = text },
    });
}

pub fn did_change(self: *Self, file_path: []const u8, version: usize, root_dst_addr: usize, root_src_addr: usize) !void {
    const lsp = try self.get_file_lsp(file_path);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);

    const root_dst: Buffer.Root = if (root_dst_addr == 0) return else @ptrFromInt(root_dst_addr);
    const root_src: Buffer.Root = if (root_src_addr == 0) return else @ptrFromInt(root_src_addr);

    var dizzy_edits = std.ArrayListUnmanaged(dizzy.Edit){};
    var dst = std.ArrayList(u8).init(self.allocator);
    var src = std.ArrayList(u8).init(self.allocator);
    var scratch = std.ArrayListUnmanaged(u32){};
    var edits_cb = std.ArrayList(u8).init(self.allocator);
    const writer = edits_cb.writer();

    defer {
        edits_cb.deinit();
        dst.deinit();
        src.deinit();
        scratch.deinit(self.allocator);
        dizzy_edits.deinit(self.allocator);
    }

    try root_dst.store(dst.writer());
    try root_src.store(src.writer());

    const scratch_len = 4 * (dst.items.len + src.items.len) + 2;
    try scratch.ensureTotalCapacity(self.allocator, scratch_len);
    scratch.items.len = scratch_len;

    try dizzy.PrimitiveSliceDiffer(u8).diff(self.allocator, &dizzy_edits, src.items, dst.items, scratch.items);

    var lines_dst: usize = 0;
    var last_offset: usize = 0;
    var edits_count: usize = 0;

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

    var msg = std.ArrayList(u8).init(self.allocator);
    defer msg.deinit();
    const msg_writer = msg.writer();
    try cbor.writeMapHeader(msg_writer, 2);
    try cbor.writeValue(msg_writer, "textDocument");
    try cbor.writeValue(msg_writer, .{ .uri = uri, .version = version });
    try cbor.writeValue(msg_writer, "contentChanges");
    try cbor.writeArrayHeader(msg_writer, edits_count);
    _ = try msg_writer.write(edits_cb.items);

    try lsp.send_notification_raw("textDocument/didChange", msg.items);
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

pub fn did_save(self: *Self, file_path: []const u8) !void {
    const lsp = try self.get_file_lsp(file_path);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);
    try lsp.send_notification("textDocument/didSave", .{
        .textDocument = .{ .uri = uri },
    });
}

pub fn did_close(self: *Self, file_path: []const u8) !void {
    const lsp = try self.get_file_lsp(file_path);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);
    try lsp.send_notification("textDocument/didClose", .{
        .textDocument = .{ .uri = uri },
    });
}

pub fn goto_definition(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) !void {
    return self.send_goto_request(from, file_path, row, col, "textDocument/definition");
}

pub fn goto_declaration(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) !void {
    return self.send_goto_request(from, file_path, row, col, "textDocument/declaration");
}

pub fn goto_implementation(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) !void {
    return self.send_goto_request(from, file_path, row, col, "textDocument/implementation");
}

pub fn goto_type_definition(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) !void {
    return self.send_goto_request(from, file_path, row, col, "textDocument/typeDefinition");
}

fn send_goto_request(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize, method: []const u8) !void {
    const lsp = try self.get_file_lsp(file_path);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);
    const response = try lsp.send_request(self.allocator, method, .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = row, .character = col },
    });
    defer self.allocator.free(response.buf);
    var link: []const u8 = undefined;
    var locations: []const u8 = undefined;
    if (try response.match(.{ "child", tp.string, "result", tp.array })) {
        if (try response.match(.{ tp.any, tp.any, tp.any, .{tp.extract_cbor(&link)} })) {
            try self.navigate_to_location_link(from, link);
        } else if (try response.match(.{ tp.any, tp.any, tp.any, tp.extract_cbor(&locations) })) {
            try self.send_reference_list(from, locations);
        }
    } else if (try response.match(.{ "child", tp.string, "result", tp.null_ })) {
        return;
    } else if (try response.match(.{ "child", tp.string, "result", tp.extract_cbor(&link) })) {
        try self.navigate_to_location_link(from, link);
    }
}

fn navigate_to_location_link(_: *Self, from: tp.pid_ref, location_link: []const u8) !void {
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
        try from.send(.{ "cmd", "navigate", .{
            .file = file_path,
            .goto = .{
                targetRange.?.start.line + 1,
                targetRange.?.start.character + 1,
                sel.start.line,
                sel.start.character,
                sel.end.line,
                sel.end.character,
            },
        } });
    } else {
        try from.send(.{ "cmd", "navigate", .{
            .file = file_path,
            .goto = .{
                targetRange.?.start.line + 1,
                targetRange.?.start.character + 1,
            },
        } });
    }
}

pub fn references(self: *Self, from: tp.pid_ref, file_path: []const u8, row: usize, col: usize) !void {
    const lsp = try self.get_file_lsp(file_path);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);
    log.logger("lsp").print("finding references...", .{});

    const response = try lsp.send_request(self.allocator, "textDocument/references", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = row, .character = col },
        .context = .{ .includeDeclaration = true },
    });
    defer self.allocator.free(response.buf);
    var locations: []const u8 = undefined;
    if (try response.match(.{ "child", tp.string, "result", tp.null_ })) {
        return;
    } else if (try response.match(.{ "child", tp.string, "result", tp.extract_cbor(&locations) })) {
        try self.send_reference_list(from, locations);
    }
}

fn send_reference_list(self: *Self, to: tp.pid_ref, locations: []const u8) !void {
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

fn send_reference(self: *Self, to: tp.pid_ref, location: []const u8) !void {
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
    try to.send(.{
        "REF",
        file_path_,
        targetRange.?.start.line + 1,
        targetRange.?.start.character,
        targetRange.?.end.line + 1,
        targetRange.?.end.character,
        line,
    });
}

pub fn completion(self: *Self, _: tp.pid_ref, file_path: []const u8, row: usize, col: usize) !void {
    const lsp = try self.get_file_lsp(file_path);
    const uri = try self.make_URI(file_path);
    defer self.allocator.free(uri);
    const response = try lsp.send_request(self.allocator, "textDocument/completion", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = row, .character = col },
    });
    defer self.allocator.free(response.buf);
}

pub fn publish_diagnostics(self: *Self, to: tp.pid_ref, params_cb: []const u8) !void {
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
    if (!std.mem.eql(u8, uri.?[0..7], "file://")) return error.InvalidURI;
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

fn send_diagnostic(_: *Self, to: tp.pid_ref, file_path: []const u8, diagnostic: []const u8) !void {
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
    try to.send(.{ "cmd", "add_diagnostic", .{
        file_path,
        source,
        code,
        message,
        severity,
        range.?.start.line,
        range.?.start.character,
        range.?.end.line,
        range.?.end.character,
    } });
}

fn send_clear_diagnostics(_: *Self, to: tp.pid_ref, file_path: []const u8) !void {
    try to.send(.{ "cmd", "clear_diagnostics", .{file_path} });
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

fn send_lsp_init_request(self: *Self, lsp: LSP, project_path: []const u8, project_basename: []const u8, project_uri: []const u8) !tp.message {
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
                .codeLens = .{ .refreshSupport = true },
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
                .inlineValue = .{ .refreshSupport = true },
                .inlayHint = .{ .refreshSupport = true },
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
                            "markdown",
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
                    .contentFormat = .{ "markdown", "plaintext" },
                },
                .signatureHelp = .{
                    .dynamicRegistration = true,
                    .signatureInformation = .{
                        .documentationFormat = .{ "markdown", "plaintext" },
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

fn get_line_of_file(self: *Self, allocator: std.mem.Allocator, file_path: []const u8, line_: usize) ![]const u8 {
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
