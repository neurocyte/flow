const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const root = @import("soft_root").root;
const file_link = @import("file_link");
const dizzy = @import("dizzy");
const tracy = @import("tracy");
const Buffer = @import("Buffer");
const file_type_config = @import("file_type_config");
const builtin = @import("builtin");

const LSP = @import("LSP.zig");

pub const LspError = (error{ NoLsp, LspFailed } || OutOfMemoryError || std.Io.Writer.Error);
pub const StartLspError = (error{ ThespianSpawnFailed, Timeout, InvalidLspCommand } || LspError || OutOfMemoryError || cbor.Error);

allocator: std.mem.Allocator,
lsp: *const LSP,
project_name: []const u8,
logger_lsp: log.Logger,
language_server: []const u8,
language_server_options: []const u8,
language_server_protocol: file_type_config.ProtocolLevel,
owner: tp.pid,

const Self = @This();

const OutOfMemoryError = error{OutOfMemory};

pub const SourceLocation = struct {
    src: file_link.FileSrc,
    alternative_destination: ?file_link.FileDest = null,
};

pub fn convert_path(file_path_: []u8) []u8 {
    var file_path = file_path_;
    if (builtin.os.tag == .windows) {
        if (file_path[0] == '/') file_path = file_path[1..];
        for (file_path, 0..) |c, i| if (c == '/') {
            file_path[i] = '\\';
        };
    }
    return file_path;
}

pub fn start(
    allocator: std.mem.Allocator,
    project_name: []const u8,
    language_server: []const u8,
    language_server_options: []const u8,
    language_server_protocol: file_type_config.ProtocolLevel,
    from: tp.pid_ref,
    notify_restart: bool,
) StartLspError!*Self {
    const self = blk: {
        const lsp = try LSP.open(allocator, project_name, .{ .buf = language_server });
        errdefer lsp.deinit();
        break :blk try create(allocator, lsp, project_name, language_server, language_server_options, language_server_protocol, from);
    };
    errdefer self.deinit();
    try self.send_init_request(from, language_server, language_server_options, language_server_protocol, notify_restart);
    return self;
}

fn create(
    allocator: std.mem.Allocator,
    lsp: *const LSP,
    project_name: []const u8,
    language_server: []const u8,
    language_server_options: []const u8,
    language_server_protocol: file_type_config.ProtocolLevel,
    from: tp.pid_ref,
) error{OutOfMemory}!*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    const name_copy = try allocator.dupe(u8, project_name);
    errdefer allocator.free(name_copy);
    const lsp_name_copy = try allocator.dupe(u8, language_server);
    errdefer allocator.free(lsp_name_copy);
    const options_copy = try allocator.dupe(u8, language_server_options);
    errdefer allocator.free(options_copy);
    self.* = .{
        .allocator = allocator,
        .lsp = lsp,
        .project_name = name_copy,
        .logger_lsp = log.logger("lsp"),
        .language_server = lsp_name_copy,
        .language_server_options = options_copy,
        .language_server_protocol = language_server_protocol,
        .owner = from.clone(),
    };
    return self;
}

pub fn deinit(self: *Self) void {
    self.owner.deinit();
    self.lsp.term();
    self.logger_lsp.deinit();
    self.allocator.free(self.language_server_options);
    self.allocator.free(self.language_server);
    self.allocator.free(self.project_name);
    self.allocator.destroy(self);
}

pub fn expired(self: *const Self) bool {
    return self.lsp.pid.expired();
}

pub fn restart(self: *const Self) StartLspError!*Self {
    return Self.start(
        self.allocator,
        self.project_name,
        self.language_server,
        self.language_server_options,
        self.language_server_protocol,
        self.owner.ref(),
        true, // notify_restart
    );
}

pub const eol = '\n';

pub const GetLineOfFileError = (OutOfMemoryError || std.Io.File.OpenError || std.Io.File.ReadStreamingError || std.Io.File.StatError || std.Io.File.ReadPositionalError);

pub fn get_line_of_file(allocator: std.mem.Allocator, file_path: []const u8, line_: usize) GetLineOfFileError![]const u8 {
    const io = root.get_io();
    const line = line_ + 1;
    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    var buf = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(buf);
    const read_size = try file.readPositionalAll(io, buf, 0);
    if (read_size != @as(@TypeOf(read_size), @intCast(stat.size)))
        @panic("get_line_of_file: buffer underrun");

    var line_count: usize = 1;
    for (0..buf.len) |i| {
        if (line_count == line)
            return get_line(allocator, buf[i..]);
        if (buf[i] == eol) line_count += 1;
    }
    return allocator.dupe(u8, "");
}

pub fn get_line(allocator: std.mem.Allocator, buf: []const u8) ![]const u8 {
    for (0..buf.len) |i| {
        if (buf[i] == eol) return allocator.dupe(u8, buf[0..i]);
    }
    return allocator.dupe(u8, buf);
}

pub fn make_URI(allocator: std.mem.Allocator, project_name: []const u8, file_path: ?[]const u8) LspError![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const writer = &buf.writer;
    try writer.writeAll("file://");

    const absolute_path = if (file_path) |path|
        if (std.fs.path.isAbsolute(path)) path else project_name
    else
        project_name;
    if (builtin.os.tag == .windows and std.fs.path.isAbsolute(absolute_path))
        try writer.writeByte('/');

    if (file_path) |path| {
        if (std.fs.path.isAbsolute(path)) {
            try write_URI_path(writer, path);
        } else {
            try write_URI_path(writer, project_name);
            try writer.writeByte('/');
            try write_URI_path(writer, path);
        }
    } else try write_URI_path(writer, project_name);
    return buf.toOwnedSlice();
}

pub fn write_URI_path(writer: *std.Io.Writer, path: []const u8) std.Io.Writer.Error!void {
    for (path) |c| try switch (c) {
        std.fs.path.sep => writer.writeByte('/'),
        // ':' => writer.writeAll("%3A"),
        else => writer.writeByte(c),
    };
}

pub fn file_uri_to_path(uri: []const u8, file_path_buf: []u8) error{InvalidTargetURI}![]u8 {
    const file_path = std.Uri.percentDecodeBackwards(file_path_buf, if (std.mem.eql(u8, uri[0..7], "file://"))
        uri[7..]
    else if (std.mem.eql(u8, uri[0..5], "file:"))
        uri[5..]
    else
        return error.InvalidTargetURI);
    return convert_path(file_path);
}

pub const DocumentHighlight = struct {
    range: Range,
    kind: ?Kind,

    const Kind = enum(u8) {
        Text = 1,
        Read = 2,
        Write = 3,
    };
};

pub const DocumentHighlightError = error{
    InvalidDocumentHighlight,
    InvalidDocumentHighlightField,
    InvalidDocumentHighlightFieldName,
} || RangeError || cbor.Error;
pub fn read_document_highlight(document_highlight: []const u8) DocumentHighlightError!DocumentHighlight {
    var iter = document_highlight;
    var range: ?Range = null;
    var kind: ?DocumentHighlight.Kind = null;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidDocumentHighlightFieldName;
        if (std.mem.eql(u8, field_name, "range")) {
            var range_: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range_)))) return error.InvalidDocumentHighlightField;
            range = try read_range(range_);
        } else if (std.mem.eql(u8, field_name, "kind")) {
            var kind_: u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract(&kind_)))) return error.InvalidDocumentHighlightField;
            kind = std.enums.fromInt(DocumentHighlight.Kind, kind_) orelse return error.InvalidDocumentHighlightField;
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (range == null) return error.InvalidDocumentHighlight;
    return .{ .range = range.?, .kind = kind };
}

pub fn invalid_text_edit_field(field: []const u8) error{InvalidTextEditField} {
    std.log.err("invalid text edit field '{s}'", .{field});
    return error.InvalidTextEditField;
}

pub const TextEditError = error{
    InvalidTextEdit,
    InvalidTextEditField,
    InvalidTextEditFieldName,
} || RangeError || cbor.Error;
pub fn read_textEdit(iter: *[]const u8) TextEditError!TextEdit {
    var field_name: []const u8 = undefined;
    var newText: []const u8 = "";
    var insert: ?Range = null;
    var replace: ?Range = null;
    var len_ = cbor.decodeMapHeader(iter) catch return invalid_text_edit_field("textEdit");
    while (len_ > 0) : (len_ -= 1) {
        if (!(try cbor.matchString(iter, &field_name))) return invalid_text_edit_field("textEdit");
        if (std.mem.eql(u8, field_name, "newText")) {
            if (!(try cbor.matchValue(iter, cbor.extract(&newText)))) return invalid_text_edit_field("textEdit.newText");
        } else if (std.mem.eql(u8, field_name, "insert")) {
            var range_: []const u8 = undefined;
            if (!(try cbor.matchValue(iter, cbor.extract_cbor(&range_)))) return invalid_text_edit_field("textEdit.insert");
            insert = try read_range(range_);
        } else if (std.mem.eql(u8, field_name, "replace") or std.mem.eql(u8, field_name, "range")) {
            var range_: []const u8 = undefined;
            if (!(try cbor.matchValue(iter, cbor.extract_cbor(&range_)))) return invalid_text_edit_field("textEdit.replace");
            replace = try read_range(range_);
        } else {
            try cbor.skipValue(iter);
        }
    }
    return .{ .newText = newText, .insert = insert, .replace = replace };
}

pub const TextEdit = struct {
    newText: []const u8 = &.{},
    insert: ?Range = null,
    replace: ?Range = null,
};

pub const Rename = struct {
    uri: []const u8,
    new_text: []const u8,
    range: Range,
};

pub const DocumentChangesError = error{
    InvalidDocumentChanges,
    InvalidDocumentChangesField,
    InvalidDocumentChangesFieldName,
} || TextEditError || cbor.Error;

pub const SymbolType = enum { document_symbol, symbol_information };

pub const DocumentSymbol = struct {
    name: []const u8 = &.{},
    detail: ?[]const u8 = &.{},
    kind: usize,
    tags: ?[]const usize = &.{},
    deprecated: ?bool = false,
    range: Range,
    selectionRange: Range,
    children: ?[]const DocumentSymbol = &.{},
    parent_name: []const u8 = &.{},
};

// Location is a subset of LocationLink
pub const Location = LocationLink;

pub const LocationLink = struct {
    targetUri: ?[]const u8 = null,
    targetRange: ?Range = null,
    targetSelectionRange: ?Range = null,
};
pub const LocationLinkError = error{
    InvalidLocationLink,
    InvalidLocationLinkFieldName,
    InvalidLocationLinkField,
} || RangeError || cbor.Error;
pub fn read_locationlink(location_link: []const u8) LocationLinkError!LocationLink {
    var iter = location_link;
    var targetUri: ?[]const u8 = null;
    var targetRange: ?Range = null;
    var targetSelectionRange: ?Range = null;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidLocationLinkFieldName;
        if (std.mem.eql(u8, field_name, "targetUri") or std.mem.eql(u8, field_name, "uri")) {
            var uri_: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract(&uri_)))) return error.InvalidLocationLinkField;
            targetUri = uri_;
        } else if (std.mem.eql(u8, field_name, "targetRange") or std.mem.eql(u8, field_name, "range")) {
            var range_: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range_)))) return error.InvalidLocationLinkField;
            targetRange = try read_range(range_);
        } else if (std.mem.eql(u8, field_name, "targetSelectionRange")) {
            var range_: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range_)))) return error.InvalidLocationLinkField;
            targetSelectionRange = try read_range(range_);
        } else {
            try cbor.skipValue(&iter);
        }
    }
    return .{ .targetUri = targetUri, .targetRange = targetRange, .targetSelectionRange = targetSelectionRange };
}

pub const Range = struct { start: Position, end: Position };
pub const RangeError = error{
    InvalidRange,
    InvalidRangeFieldName,
    InvalidRangeField,
} || PositionError || cbor.Error;
pub fn read_range(range: []const u8) RangeError!Range {
    var iter = range;
    var start_pos: ?Position = null;
    var end_pos: ?Position = null;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidRangeFieldName;
        if (std.mem.eql(u8, field_name, "start")) {
            var position: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&position)))) return error.InvalidRangeField;
            start_pos = try read_position(position);
        } else if (std.mem.eql(u8, field_name, "end")) {
            var position: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&position)))) return error.InvalidRangeField;
            end_pos = try read_position(position);
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (start_pos == null or end_pos == null) return error.InvalidRange;
    return .{ .start = start_pos.?, .end = end_pos.? };
}

pub const Position = struct { line: usize, character: usize };
pub const PositionError = error{
    InvalidPosition,
    InvalidPositionFieldName,
    InvalidPositionField,
} || cbor.Error;
pub fn read_position(position: []const u8) PositionError!Position {
    var iter = position;
    var line: ?usize = 0;
    var character: ?usize = 0;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidPositionFieldName;
        if (std.mem.eql(u8, field_name, "line")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&line)))) return error.InvalidPositionField;
        } else if (std.mem.eql(u8, field_name, "character")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&character)))) return error.InvalidPositionField;
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (line == null or character == null) return error.InvalidPosition;
    return .{ .line = line.?, .character = character.? };
}

pub fn hover(self: *Self, from: tp.pid_ref, source_location: *const SourceLocation) LspError!void {
    const uri = try make_URI(self.allocator, self.project_name, source_location.src.path);
    defer self.allocator.free(uri);
    // self.logger_lsp.print("fetching hover information...", .{});

    const handler: struct {
        from: tp.pid,
        file_path: []const u8,
        row: usize,
        col: usize,

        pub fn deinit(self_: *@This()) void {
            self_.from.deinit();
            std.heap.c_allocator.free(self_.file_path);
        }

        pub fn receive(self_: @This(), response: tp.message) !void {
            var result: []const u8 = undefined;
            if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.null_ })) {
                try send_content_msg_empty(self_.from.ref(), "hover", self_.file_path, self_.row, self_.col);
            } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.extract_cbor(&result) })) {
                try send_hover(self_.from.ref(), self_.file_path, self_.row, self_.col, result);
            }
        }
    } = .{
        .from = from.clone(),
        .file_path = try std.heap.c_allocator.dupe(u8, source_location.src.path),
        .row = source_location.src.line,
        .col = source_location.src.column,
    };

    self.lsp.send_request(self.allocator, "textDocument/hover", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = source_location.src.line, .character = source_location.src.column },
    }, handler) catch return error.LspFailed;
}

const HoverError = error{
    InvalidHover,
    InvalidHoverField,
    InvalidHoverFieldName,
} || HoverContentsError || RangeError || cbor.Error;

fn send_hover(to: tp.pid_ref, file_path: []const u8, row: usize, col: usize, result: []const u8) HoverError!void {
    var iter = result;
    var len = cbor.decodeMapHeader(&iter) catch return;
    var contents: []const u8 = "";
    var range: ?Range = null;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidHoverFieldName;
        if (std.mem.eql(u8, field_name, "contents")) {
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&contents)))) return error.InvalidHoverField;
        } else if (std.mem.eql(u8, field_name, "range")) {
            var range_: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range_)))) return error.InvalidHoverField;
            range = try read_range(range_);
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (contents.len > 0)
        return send_contents(to, "hover", file_path, row, col, contents, range);
}

const HoverContentsError = error{
    InvalidHoverContents,
    InvalidHoverContentsField,
    InvalidHoverContentsFieldName,
} || cbor.Error;

fn send_contents(
    to: tp.pid_ref,
    tag: []const u8,
    file_path: []const u8,
    row: usize,
    col: usize,
    result: []const u8,
    range: ?Range,
) HoverContentsError!void {
    var iter = result;
    var kind: []const u8 = "plaintext";
    var value: []const u8 = "";
    if (try cbor.matchValue(&iter, cbor.extract(&value)))
        return send_content_msg(to, tag, file_path, row, col, kind, value, range);

    var list_size = cbor.decodeArrayHeader(&iter) catch blk: {
        iter = result;
        break :blk 1;
    };

    while (list_size > 0) : (list_size -= 1) {
        var len = cbor.decodeMapHeader(&iter) catch return;
        while (len > 0) : (len -= 1) {
            var field_name: []const u8 = undefined;
            if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidHoverContentsFieldName;
            if (std.mem.eql(u8, field_name, "kind")) {
                if (!(try cbor.matchValue(&iter, cbor.extract(&kind)))) return error.InvalidHoverContentsField;
            } else if (std.mem.eql(u8, field_name, "value")) {
                if (!(try cbor.matchValue(&iter, cbor.extract(&value)))) return error.InvalidHoverContentsField;
            } else {
                try cbor.skipValue(&iter);
            }
        }
        try send_content_msg(to, tag, file_path, row, col, kind, value, range);
    }
}

pub fn send_content_msg(
    to: tp.pid_ref,
    tag: []const u8,
    file_path: []const u8,
    row: usize,
    col: usize,
    kind: []const u8,
    content: []const u8,
    range: ?Range,
) error{}!void {
    const r = range orelse Range{
        .start = .{ .line = row, .character = col },
        .end = .{ .line = row, .character = col },
    };
    to.send(.{ tag, file_path, kind, content, r.start.line, r.start.character, r.end.line, r.end.character }) catch |e| {
        std.log.err("send {s} (in send_content_msg) failed: {t}", .{ tag, e });
    };
}

pub fn send_content_msg_empty(to: tp.pid_ref, tag: []const u8, file_path: []const u8, row: usize, col: usize) error{}!void {
    return send_content_msg(to, tag, file_path, row, col, "plaintext", "", null);
}

pub const CompletionError = error{
    InvalidTargetURI,
} || CompletionListError || CompletionItemError || TextEditError || cbor.Error;

pub fn completion(self: *Self, from: tp.pid_ref, source_location: *const SourceLocation) LspError!void {
    const uri = try make_URI(self.allocator, self.project_name, source_location.src.path);
    defer self.allocator.free(uri);

    const handler: struct {
        from: tp.pid,
        file_path: []const u8,
        row: usize,
        col: usize,

        pub fn deinit(self_: *@This()) void {
            std.heap.c_allocator.free(self_.file_path);
            self_.from.deinit();
        }

        pub fn receive(self_: @This(), response: tp.message) (CompletionError || cbor.Error)!void {
            var result: []const u8 = undefined;
            if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.null_ })) {
                send_completion_done(self_.from.ref(), self_.file_path, self_.row, self_.col);
            } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.array })) {
                if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&result) }))
                    try send_completion_items(self_.from.ref(), self_.file_path, self_.row, self_.col, result, false);
            } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.map })) {
                if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&result) }))
                    try send_completion_list(self_.from.ref(), self_.file_path, self_.row, self_.col, result);
            }
        }
    } = .{
        .from = from.clone(),
        .file_path = try std.heap.c_allocator.dupe(u8, source_location.src.path),
        .row = source_location.src.line,
        .col = source_location.src.column,
    };

    self.lsp.send_request(self.allocator, "textDocument/completion", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = source_location.src.line, .character = source_location.src.column },
    }, handler) catch return error.LspFailed;
}

pub const CompletionListError = error{
    InvalidCompletionListField,
    InvalidCompletionListFieldName,
} || CompletionItemError || TextEditError || cbor.Error;
fn send_completion_list(to: tp.pid_ref, file_path: []const u8, row: usize, col: usize, result: []const u8) (CompletionListError || cbor.Error)!void {
    var iter = result;
    var len = cbor.decodeMapHeader(&iter) catch return;
    var items: []const u8 = "";
    var is_incomplete: bool = true;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidCompletionListFieldName;
        if (std.mem.eql(u8, field_name, "items")) {
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&items)))) return error.InvalidCompletionListField;
        } else if (std.mem.eql(u8, field_name, "isIncomplete")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&is_incomplete)))) return error.InvalidCompletionListField;
        } else {
            try cbor.skipValue(&iter);
        }
    }
    return if (items.len > 0)
        send_completion_items(to, file_path, row, col, items, is_incomplete)
    else
        send_completion_done(to, file_path, row, col);
}

pub const CompletionItemError = error{
    InvalidCompletionItem,
    InvalidCompletionItemField,
    InvalidCompletionItemFieldName,
} || TextEditError || cbor.Error;
fn send_completion_items(to: tp.pid_ref, file_path: []const u8, row: usize, col: usize, items: []const u8, is_incomplete: bool) (CompletionItemError || cbor.Error)!void {
    var iter = items;
    var len = cbor.decodeArrayHeader(&iter) catch return;
    var item: []const u8 = "";
    while (len > 0) : (len -= 1) {
        if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&item)))) return error.InvalidCompletionItem;
        try send_completion_item(to, file_path, row, col, item, if (len > 1) true else is_incomplete);
    }
    send_completion_done(to, file_path, row, col);
}

fn send_completion_done(to: tp.pid_ref, file_path: []const u8, row: usize, col: usize) void {
    return to.send(.{ "cmd", "add_completion_done", .{ file_path, row, col } }) catch |e| {
        std.log.err("send add_completion_done failed: {t}", .{e});
    };
}

fn invalid_completion_item_field(field: []const u8) error{InvalidCompletionItemField} {
    std.log.err("invalid completion item field '{s}'", .{field});
    return error.InvalidCompletionItemField;
}

fn send_completion_item(to: tp.pid_ref, file_path: []const u8, row: usize, col: usize, item: []const u8, is_incomplete: bool) CompletionItemError!void {
    var label: []const u8 = "";
    var label_detail: []const u8 = "";
    var label_description: []const u8 = "";
    var kind: usize = 0;
    var detail: []const u8 = "";
    var documentation: []const u8 = "";
    var documentation_kind: []const u8 = "";
    var sortText: []const u8 = "";
    var insertText: []const u8 = "";
    var insertTextFormat: usize = 0;
    var textEdit: TextEdit = .{};
    var additionalTextEdits: [32]TextEdit = undefined;
    var additionalTextEdits_len: usize = 0;

    var iter = item;
    var len = cbor.decodeMapHeader(&iter) catch return;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) {
            const json = cbor.toJsonAlloc(std.heap.c_allocator, iter) catch "(error)";
            defer std.heap.c_allocator.free(json);
            std.log.err("unexpected value in completion item field name: {s}", .{json});
            return error.InvalidCompletionItemFieldName;
        }
        if (std.mem.eql(u8, field_name, "label")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&label)))) return invalid_completion_item_field("label");
        } else if (std.mem.eql(u8, field_name, "labelDetails")) {
            var len_ = cbor.decodeMapHeader(&iter) catch return;
            while (len_ > 0) : (len_ -= 1) {
                if (!(try cbor.matchString(&iter, &field_name))) return invalid_completion_item_field("labelDetails");
                if (std.mem.eql(u8, field_name, "detail")) {
                    if (!(try cbor.matchValue(&iter, cbor.extract(&label_detail)))) return invalid_completion_item_field("labelDetails.detail");
                } else if (std.mem.eql(u8, field_name, "description")) {
                    if (!(try cbor.matchValue(&iter, cbor.extract(&label_description)))) try cbor.skipValue(&iter);
                } else {
                    try cbor.skipValue(&iter);
                }
            }
        } else if (std.mem.eql(u8, field_name, "kind")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&kind)))) return invalid_completion_item_field("kind");
        } else if (std.mem.eql(u8, field_name, "detail")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&detail)))) try cbor.skipValue(&iter);
        } else if (std.mem.eql(u8, field_name, "documentation")) {
            if (try cbor.matchValue(&iter, cbor.null_)) continue;
            if (try cbor.matchValue(&iter, cbor.extract(&documentation))) {
                documentation_kind = "plaintext";
            } else {
                var len_ = cbor.decodeMapHeader(&iter) catch return invalid_completion_item_field("documentation");
                while (len_ > 0) : (len_ -= 1) {
                    if (!(try cbor.matchString(&iter, &field_name))) return invalid_completion_item_field("documentation");
                    if (std.mem.eql(u8, field_name, "kind")) {
                        if (!(try cbor.matchValue(&iter, cbor.extract(&documentation_kind)))) return invalid_completion_item_field("documentation.kind");
                    } else if (std.mem.eql(u8, field_name, "value")) {
                        if (!(try cbor.matchValue(&iter, cbor.extract(&documentation)))) return invalid_completion_item_field("documentation.value");
                    } else {
                        try cbor.skipValue(&iter);
                    }
                }
            }
        } else if (std.mem.eql(u8, field_name, "insertText")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&insertText)))) return invalid_completion_item_field("insertText");
        } else if (std.mem.eql(u8, field_name, "sortText")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&sortText)))) return invalid_completion_item_field("sortText");
        } else if (std.mem.eql(u8, field_name, "insertTextFormat")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&insertTextFormat)))) return invalid_completion_item_field("insertTextFormat");
        } else if (std.mem.eql(u8, field_name, "textEdit")) {
            textEdit = try read_textEdit(&iter);
        } else if (std.mem.eql(u8, field_name, "additionalTextEdits")) {
            var len_ = cbor.decodeArrayHeader(&iter) catch return;
            additionalTextEdits_len = len_;
            var idx: usize = 0;
            while (len_ > 0) : (len_ -= 1) {
                additionalTextEdits[idx] = try read_textEdit(&iter);
                idx += 1;
            }
        } else {
            try cbor.skipValue(&iter);
        }
    }
    const insert = textEdit.insert orelse Range{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };
    const replace = textEdit.replace orelse Range{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };
    return to.send(.{
        "cmd", "add_completion",
        .{
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
            documentation_kind,
            sortText,
            insertText,
            insertTextFormat,
            textEdit.newText,
            if (textEdit.insert == null) null else .{
                insert.start.line,
                insert.start.character,
                insert.end.line,
                insert.end.character,
            },
            if (textEdit.replace == null) null else .{
                replace.start.line,
                replace.start.character,
                replace.end.line,
                replace.end.character,
            },
            additionalTextEdits[0..additionalTextEdits_len],
        },
    }) catch |e| {
        std.log.err("send add_completion failed: {t}", .{e});
    };
}

pub fn symbols(self: *Self, from: tp.pid_ref, file_path: []const u8) (LspError || SymbolInformationError)!void {
    const uri = try make_URI(self.allocator, self.project_name, file_path);
    defer self.allocator.free(uri);

    const handler: struct {
        from: tp.pid,
        file_path: []const u8,

        pub fn deinit(self_: *@This()) void {
            std.heap.c_allocator.free(self_.file_path);
            self_.from.deinit();
        }

        pub fn receive(self_: @This(), response: tp.message) !void {
            var result: []const u8 = undefined;
            if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.null_ })) {
                try send_content_msg_empty(self_.from.ref(), "hover", self_.file_path, 1, 1);
            } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.array })) {
                if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&result) }))
                    try send_symbol_items(self_.from.ref(), self_.file_path, result);
            }
        }
    } = .{
        .from = from.clone(),
        .file_path = try std.heap.c_allocator.dupe(u8, file_path),
    };

    self.lsp.send_request(self.allocator, "textDocument/documentSymbol", .{
        .textDocument = .{ .uri = uri },
    }, handler) catch return error.LspFailed;
}

fn send_symbol_items(to: tp.pid_ref, file_path: []const u8, items: []const u8) (SymbolInformationError || cbor.Error)!void {
    var iter = items;
    var len = cbor.decodeArrayHeader(&iter) catch return;
    var item: []const u8 = "";
    var node_count: usize = 0;
    while (len > 0) : (len -= 1) {
        if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&item)))) return error.InvalidSymbolInformationArray;
        node_count += try send_symbol_information(to, file_path, item, "", 0);
    }
    return to.send(.{ "cmd", "add_document_symbol_done", .{file_path} }) catch |e| {
        std.log.err("send add_document_symbol_done failed: {t}", .{e});
        return;
    };
}

fn invalid_symbol_information_field(field: []const u8) error{InvalidSymbolInformationField} {
    std.log.err("invalid symbol information field '{s}'", .{field});
    return error.InvalidSymbolInformationField;
}

pub const SymbolInformationError = error{
    InvalidSymbolInformationFieldName,
    InvalidSymbolInformationArray,
    InvalidSymbolInformationField,
    InvalidTargetURI,
} || LocationLinkError || cbor.Error;
fn send_symbol_information(to: tp.pid_ref, file_path: []const u8, item: []const u8, parent_name: []const u8, depth: u8) SymbolInformationError!usize {
    var name: []const u8 = "";
    var detail: ?[]const u8 = "";
    var kind: usize = 0;
    var tags: [32]usize = undefined;
    var deprecated: ?bool = false;
    var range: Range = undefined;
    var selectionRange: Range = undefined;
    var location: ?Location = null;
    var containerName: ?[]const u8 = "";
    var len_tags_: usize = 0;
    var descendant_count: usize = 0;
    var symbolKind: SymbolType = undefined;
    const logger_t = log.logger("lsp");
    defer logger_t.deinit();
    var iter = item;
    var len = cbor.decodeMapHeader(&iter) catch return 0;
    tags[0] = 0;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidSymbolInformationFieldName;
        if (std.mem.eql(u8, field_name, "name")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&name)))) return invalid_symbol_information_field("name");
        } else if (std.mem.eql(u8, field_name, "detail")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&detail)))) return invalid_symbol_information_field("detail");
        } else if (std.mem.eql(u8, field_name, "kind")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&kind)))) return invalid_symbol_information_field("kind");
        } else if (std.mem.eql(u8, field_name, "tags")) {
            var len_ = cbor.decodeArrayHeader(&iter) catch return 0;
            var idx: usize = 0;
            var this_tag: usize = undefined;
            len_tags_ = len_;
            while (len_ > 0) : (len_ -= 1) {
                if (!(try cbor.matchValue(&iter, cbor.extract(&this_tag)))) return invalid_symbol_information_field("tags");
                tags[idx] = this_tag;
                idx += 1;
            }
        } else if (std.mem.eql(u8, field_name, "deprecated")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&deprecated)))) return invalid_symbol_information_field("deprecated");
        } else if (std.mem.eql(u8, field_name, "range")) {
            var range_: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range_)))) return invalid_symbol_information_field("range");
            range = try read_range(range_);
            symbolKind = SymbolType.document_symbol;
        } else if (std.mem.eql(u8, field_name, "selectionRange")) {
            var range_: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range_)))) return invalid_symbol_information_field("selectionRange");
            selectionRange = try read_range(range_);
        } else if (std.mem.eql(u8, field_name, "children")) {
            var len_ = cbor.decodeArrayHeader(&iter) catch return 0;
            var descendant: []const u8 = "";
            while (len_ > 0) : (len_ -= 1) {
                if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&descendant)))) return error.InvalidSymbolInformationField;
                descendant_count += try send_symbol_information(to, file_path, descendant, name, depth + 1);
            }
        } else if (std.mem.eql(u8, field_name, "location")) {} else if (std.mem.eql(u8, field_name, "location")) {
            var location_: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&location_)))) return invalid_symbol_information_field("selectionRange");
            location = try read_locationlink(iter);
            symbolKind = SymbolType.document_symbol;
        } else if (std.mem.eql(u8, field_name, "containerName")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&containerName)))) return invalid_symbol_information_field("containerName");
        } else {
            try cbor.skipValue(&iter);
        }
    }

    try switch (symbolKind) {
        SymbolType.document_symbol => {
            to.send(.{ "cmd", "add_document_symbol", .{
                file_path,
                name,
                parent_name,
                kind,
                range.start.line,
                range.start.character,
                range.end.line,
                range.end.character,
                tags[0..len_tags_],
                selectionRange.start.line,
                selectionRange.start.character,
                selectionRange.end.line,
                selectionRange.end.character,
                deprecated,
                detail,
                depth,
            } }) catch |e| {
                std.log.err("send add_document_symbol failed: {t}", .{e});
                return 0;
            };
            return descendant_count + 1;
        },
        SymbolType.symbol_information => {
            var fp = file_path;
            if (location) |location_| {
                if (location_.targetUri == null or location_.targetRange == null) return error.InvalidSymbolInformationField;
                var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const file_path_ = try file_uri_to_path(location_.targetUri.?, &file_path_buf);
                fp = file_path_;
                to.send(.{ "cmd", "add_symbol_information", .{ fp, name, parent_name, kind, location_.targetRange.?.start.line, location_.targetRange.?.start.character, location_.targetRange.?.end.line, location_.targetRange.?.end.character, tags[0..len_tags_], location_.targetSelectionRange.?.start.line, location_.targetSelectionRange.?.start.character, location_.targetSelectionRange.?.end.line, location_.targetSelectionRange.?.end.character, deprecated, location_.targetUri } }) catch |e| {
                    std.log.err("send add_symbol_information failed: {t}", .{e});
                    return 0;
                };
                return 1;
            } else {
                return error.InvalidSymbolInformationField;
            }
        },
    };
}

pub fn goto_definition(self: *Self, from: tp.pid_ref, args: *const SourceLocation) SendGotoRequestError!void {
    return self.send_goto_request(from, args, "textDocument/definition");
}

pub fn goto_declaration(self: *Self, from: tp.pid_ref, args: *const SourceLocation) SendGotoRequestError!void {
    return self.send_goto_request(from, args, "textDocument/declaration");
}

pub fn goto_implementation(self: *Self, from: tp.pid_ref, args: *const SourceLocation) SendGotoRequestError!void {
    return self.send_goto_request(from, args, "textDocument/implementation");
}

pub fn goto_type_definition(self: *Self, from: tp.pid_ref, args: *const SourceLocation) SendGotoRequestError!void {
    return self.send_goto_request(from, args, "textDocument/typeDefinition");
}

pub const SendGotoRequestError = (error{} || StartLspError || GetLineOfFileError || cbor.Error);

fn send_goto_request(self: *Self, from: tp.pid_ref, args: *const SourceLocation, method: []const u8) SendGotoRequestError!void {
    const uri = try make_URI(self.allocator, self.project_name, args.src.path);
    defer self.allocator.free(uri);

    const handler: struct {
        from: tp.pid,
        name: []const u8,
        alternative_destination: ?file_link.FileDest = null,

        pub fn deinit(self_: *@This()) void {
            if (self_.alternative_destination) |dest| std.heap.c_allocator.free(dest.path);
            std.heap.c_allocator.free(self_.name);
            self_.from.deinit();
        }

        pub fn receive(self_: @This(), response: tp.message) !void {
            var link: []const u8 = undefined;
            var locations: []const u8 = undefined;
            if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.array })) {
                if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, .{tp.extract_cbor(&link)} })) {
                    try navigate_to_location_link(self_.from.ref(), link);
                } else if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&locations) })) {
                    _ = try send_reference_list("REF", self_.from.ref(), locations, self_.name);
                }
            } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.null_ })) {
                if (self_.alternative_destination) |*link_|
                    try navigate_to_alternate_destination(self_.from.ref(), link_);
                return;
            } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.extract_cbor(&link) })) {
                try navigate_to_location_link(self_.from.ref(), link);
            }
        }
    } = .{
        .from = from.clone(),
        .name = try std.heap.c_allocator.dupe(u8, self.project_name),
        .alternative_destination = if (args.alternative_destination) |dest| .{
            .path = try std.heap.c_allocator.dupe(u8, dest.path),
            .line = dest.line,
            .column = dest.column,
            .end_column = dest.end_column,
            .exists = dest.exists,
            .offset = dest.offset,
        } else null,
    };

    self.lsp.send_request(self.allocator, method, .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = args.src.line, .character = args.src.column },
    }, handler) catch return error.LspFailed;
}

fn navigate_to_location_link(from: tp.pid_ref, location_link: []const u8) (error{InvalidTargetURI} || LocationLinkError)!void {
    const location: LocationLink = try read_locationlink(location_link);
    if (location.targetUri == null or location.targetRange == null) return error.InvalidLocationLink;
    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = try file_uri_to_path(location.targetUri.?, &file_path_buf);
    if (location.targetSelectionRange) |sel| {
        from.send(.{ "cmd", "navigate", .{
            .file = file_path,
            .goto = .{
                location.targetSelectionRange.?.start.line + 1,
                location.targetSelectionRange.?.start.character + 1,
                sel.start.line,
                sel.start.character,
                sel.end.line,
                sel.end.character,
            },
        } }) catch |e| {
            std.log.err("send navigate failed: {t}", .{e});
            return;
        };
    } else {
        from.send(.{ "cmd", "navigate", .{
            .file = file_path,
            .goto = .{
                location.targetRange.?.start.line + 1,
                location.targetRange.?.start.character + 1,
            },
        } }) catch |e| {
            std.log.err("send navigate failed: {t}", .{e});
            return;
        };
    }
}

pub fn navigate_to_alternate_destination(from: tp.pid_ref, dest: *const file_link.FileDest) error{}!void {
    from.send(.{ "cmd", "navigate", .{
        .file = dest.path,
        .goto = .{ dest.line orelse 1, dest.column orelse 1 },
    } }) catch |e| {
        std.log.err("send navigate failed: {t}", .{e});
        return;
    };
}

pub fn references(self: *Self, from: tp.pid_ref, source_location: *const SourceLocation) SendGotoRequestError!void {
    const uri = try make_URI(self.allocator, self.project_name, source_location.src.path);
    defer self.allocator.free(uri);
    self.logger_lsp.print("finding references...", .{});

    const handler: struct {
        from: tp.pid,
        name: []const u8,

        pub fn deinit(self_: *@This()) void {
            std.heap.c_allocator.free(self_.name);
            self_.from.deinit();
        }

        pub fn receive(self_: @This(), response: tp.message) !void {
            var locations: []const u8 = undefined;
            if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.null_ })) {
                return;
            } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.extract_cbor(&locations) })) {
                const count = try send_reference_list("REF", self_.from.ref(), locations, self_.name);
                std.log.info("found {d} references", .{count});
            }
        }
    } = .{
        .from = from.clone(),
        .name = try std.heap.c_allocator.dupe(u8, self.project_name),
    };

    self.lsp.send_request(self.allocator, "textDocument/references", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = source_location.src.line, .character = source_location.src.column },
        .context = .{ .includeDeclaration = true },
    }, handler) catch return error.LspFailed;
}

fn send_reference_list(tag: []const u8, to: tp.pid_ref, locations: []const u8, name: []const u8) (error{
    InvalidTargetURI,
    InvalidReferenceList,
} || LocationLinkError || GetLineOfFileError || cbor.Error)!usize {
    defer to.send(.{ tag, "done" }) catch {};
    var iter = locations;
    var len = try cbor.decodeArrayHeader(&iter);
    const count = len;
    while (len > 0) : (len -= 1) {
        var location: []const u8 = undefined;
        if (try cbor.matchValue(&iter, cbor.extract_cbor(&location))) {
            try send_reference(tag, to, location, name);
        } else return error.InvalidReferenceList;
    }
    return count;
}

fn send_reference(tag: []const u8, to: tp.pid_ref, location_: []const u8, name: []const u8) (error{InvalidTargetURI} || LocationLinkError || GetLineOfFileError || cbor.Error)!void {
    const allocator = std.heap.c_allocator;
    const location: LocationLink = try read_locationlink(location_);
    if (location.targetUri == null or location.targetRange == null) return error.InvalidLocationLink;
    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = try file_uri_to_path(location.targetUri.?, &file_path_buf);
    const line = try get_line_of_file(allocator, file_path, location.targetRange.?.start.line);
    defer allocator.free(line);
    const file_path_ = if (file_path.len > name.len and std.mem.eql(u8, name, file_path[0..name.len]))
        file_path[name.len + 1 ..]
    else
        file_path;
    to.send(.{
        tag,
        file_path_,
        location.targetRange.?.start.line + 1,
        location.targetRange.?.start.character,
        location.targetRange.?.end.line + 1,
        location.targetRange.?.end.character,
        line,
    }) catch |e| {
        std.log.err("send {s} (in send_reference) failed: {t}", .{ tag, e });
        return;
    };
}

pub fn highlight_references(self: *Self, from: tp.pid_ref, source_location: *const SourceLocation) SendGotoRequestError!void {
    const uri = try make_URI(self.allocator, self.project_name, source_location.src.path);
    defer self.allocator.free(uri);

    const handler: struct {
        from: tp.pid,
        file_path: []const u8,

        pub fn deinit(self_: *@This()) void {
            std.heap.c_allocator.free(self_.file_path);
            self_.from.deinit();
        }

        pub fn receive(self_: @This(), response: tp.message) !void {
            var highlights: []const u8 = undefined;
            if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.null_ })) {
                self_.from.send(.{ "HREF", self_.file_path, "done" }) catch {};
            } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.extract_cbor(&highlights) })) {
                _ = try send_highlight_list(self_.from.ref(), highlights, self_.file_path);
            }
        }
    } = .{
        .from = from.clone(),
        .file_path = try std.heap.c_allocator.dupe(u8, source_location.src.path),
    };

    self.lsp.send_request(self.allocator, "textDocument/documentHighlight", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = source_location.src.line, .character = source_location.src.column },
        .context = .{ .includeDeclaration = true },
    }, handler) catch return error.LspFailed;
}

fn send_highlight_list(to: tp.pid_ref, highlights: []const u8, file_path: []const u8) (error{InvalidDocumentHighlightList} || DocumentHighlightError)!usize {
    defer to.send(.{ "HREF", file_path, "done" }) catch {};
    var iter = highlights;
    var len = try cbor.decodeArrayHeader(&iter);
    const count = len;
    while (len > 0) : (len -= 1) {
        var highlight: []const u8 = undefined;
        if (try cbor.matchValue(&iter, cbor.extract_cbor(&highlight))) {
            try send_highlight(to, highlight, file_path);
        } else return error.InvalidDocumentHighlightList;
    }
    return count;
}

fn send_highlight(to: tp.pid_ref, highlight_: []const u8, file_path: []const u8) DocumentHighlightError!void {
    const highlight = try read_document_highlight(highlight_);
    to.send(.{
        "HREF",
        file_path,
        highlight.range.start.line + 1,
        highlight.range.start.character,
        highlight.range.end.line + 1,
        highlight.range.end.character,
    }) catch |e| {
        std.log.err("send HREF (in send_highlight) failed: {t}", .{e});
        return;
    };
}

pub fn rename_symbol(self: *Self, from: tp.pid_ref, source_location: *const SourceLocation) (LspError || GetLineOfFileError)!void {
    const uri = try make_URI(self.allocator, self.project_name, source_location.src.path);
    defer self.allocator.free(uri);

    const handler: struct {
        from: tp.pid,
        file_path: []const u8,

        pub fn deinit(self_: *@This()) void {
            std.heap.c_allocator.free(self_.file_path);
            self_.from.deinit();
        }

        pub fn receive(self_: @This(), response: tp.message) !void {
            const allocator = std.heap.c_allocator;
            var result: []const u8 = undefined;
            // buffer the renames in order to send as a single, atomic message
            var renames = std.array_list.Managed(Rename).init(allocator);
            defer renames.deinit();

            if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.map })) {
                if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&result) })) {
                    try decode_rename_symbol_map(result, &renames);
                    // write the renames message manually since there doesn't appear to be an array helper
                    var msg_buf: std.Io.Writer.Allocating = .init(allocator);
                    defer msg_buf.deinit();
                    const w = &msg_buf.writer;
                    try cbor.writeArrayHeader(w, 3);
                    try cbor.writeValue(w, "cmd");
                    try cbor.writeValue(w, "rename_symbol_item");
                    try cbor.writeArrayHeader(w, renames.items.len);
                    for (renames.items) |rename| {
                        var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const file_path_ = try file_uri_to_path(rename.uri, &file_path_buf);
                        const line = try get_line_of_file(allocator, self_.file_path, rename.range.start.line);
                        try cbor.writeValue(w, .{
                            file_path_,
                            rename.range.start.line,
                            rename.range.start.character,
                            rename.range.end.line,
                            rename.range.end.character,
                            rename.new_text,
                            line,
                        });
                    }
                    self_.from.send_raw(.{ .buf = msg_buf.written() }) catch return error.ClientFailed;
                }
            }
        }
    } = .{
        .from = from.clone(),
        .file_path = try std.heap.c_allocator.dupe(u8, source_location.src.path),
    };

    self.lsp.send_request(self.allocator, "textDocument/rename", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = source_location.src.line, .character = source_location.src.column },
        .newName = "PLACEHOLDER",
    }, handler) catch return error.LspFailed;
}

// decode a WorkspaceEdit record which may have shape {"changes": {}} or {"documentChanges": []}
// https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workspaceEdit
fn decode_rename_symbol_map(result: []const u8, renames: *std.array_list.Managed(Rename)) DocumentChangesError!void {
    var iter = result;
    var len = cbor.decodeMapHeader(&iter) catch return error.InvalidDocumentChanges;
    var changes: []const u8 = "";
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidDocumentChangesFieldName;
        if (std.mem.eql(u8, field_name, "changes")) {
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&changes)))) return error.InvalidDocumentChangesField;
            try decode_rename_symbol_changes(changes, renames);
            return;
        } else if (std.mem.eql(u8, field_name, "documentChanges")) {
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&changes)))) return error.InvalidDocumentChangesField;
            try decode_rename_symbol_doc_changes(changes, renames);
            return;
        } else {
            try cbor.skipValue(&iter);
        }
    }
    return error.InvalidDocumentChanges;
}

fn decode_rename_symbol_changes(changes: []const u8, renames: *std.array_list.Managed(Rename)) TextEditError!void {
    var iter = changes;
    var files_len = cbor.decodeMapHeader(&iter) catch return error.InvalidTextEdit;
    while (files_len > 0) : (files_len -= 1) {
        var file_uri: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &file_uri))) return error.InvalidTextEdit;
        try decode_rename_symbol_item(file_uri, &iter, renames);
    }
}

fn decode_rename_symbol_doc_changes(changes: []const u8, renames: *std.array_list.Managed(Rename)) DocumentChangesError!void {
    var iter = changes;
    var changes_len = cbor.decodeArrayHeader(&iter) catch return error.InvalidDocumentChanges;
    while (changes_len > 0) : (changes_len -= 1) {
        var dc_fields_len = cbor.decodeMapHeader(&iter) catch return error.InvalidDocumentChanges;
        var file_uri: []const u8 = "";
        while (dc_fields_len > 0) : (dc_fields_len -= 1) {
            var field_name: []const u8 = undefined;
            if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidDocumentChangesFieldName;
            if (std.mem.eql(u8, field_name, "textDocument")) {
                var td_fields_len = cbor.decodeMapHeader(&iter) catch return error.InvalidDocumentChangesField;
                while (td_fields_len > 0) : (td_fields_len -= 1) {
                    var td_field_name: []const u8 = undefined;
                    if (!(try cbor.matchString(&iter, &td_field_name))) return error.InvalidDocumentChangesField;
                    if (std.mem.eql(u8, td_field_name, "uri")) {
                        if (!(try cbor.matchString(&iter, &file_uri))) return error.InvalidDocumentChangesField;
                    } else try cbor.skipValue(&iter); // skip "version": 1
                }
            } else if (std.mem.eql(u8, field_name, "edits")) {
                if (file_uri.len == 0) return error.InvalidDocumentChangesField;
                try decode_rename_symbol_item(file_uri, &iter, renames);
            }
        }
    }
}

// https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textEdit
fn decode_rename_symbol_item(file_uri: []const u8, iter: *[]const u8, renames: *std.array_list.Managed(Rename)) TextEditError!void {
    var text_edits_len = cbor.decodeArrayHeader(iter) catch return error.InvalidTextEditField;
    while (text_edits_len > 0) : (text_edits_len -= 1) {
        var m_range: ?Range = null;
        var new_text: []const u8 = "";
        var edits_len = cbor.decodeMapHeader(iter) catch return error.InvalidTextEditField;
        while (edits_len > 0) : (edits_len -= 1) {
            var field_name: []const u8 = undefined;
            if (!(try cbor.matchString(iter, &field_name))) return error.InvalidTextEditField;
            if (std.mem.eql(u8, field_name, "range")) {
                var range: []const u8 = undefined;
                if (!(try cbor.matchValue(iter, cbor.extract_cbor(&range)))) return error.InvalidTextEditField;
                m_range = try read_range(range);
            } else if (std.mem.eql(u8, field_name, "newText")) {
                if (!(try cbor.matchString(iter, &new_text))) return error.InvalidTextEditField;
            } else {
                try cbor.skipValue(iter);
            }
        }

        const range = m_range orelse return error.InvalidTextEditField;
        try renames.append(.{ .uri = file_uri, .range = range, .new_text = new_text });
    }
}

pub fn did_open(self: *Self, file_path: []const u8, file_type: []const u8, version: usize, text: []const u8) LspError!void {
    const uri = try make_URI(self.allocator, self.project_name, file_path);
    defer self.allocator.free(uri);
    self.lsp.send_notification("textDocument/didOpen", .{
        .textDocument = .{ .uri = uri, .languageId = file_type, .version = version, .text = text },
    }) catch return error.LspFailed;
}

pub fn did_change(self: *Self, file_path: []const u8, version: usize, text_dst: []const u8, text_src: []const u8, eol_mode: Buffer.EolMode) LspError!void {
    _ = eol_mode;
    defer std.heap.c_allocator.free(text_dst);
    defer std.heap.c_allocator.free(text_src);
    const uri = try make_URI(self.allocator, self.project_name, file_path);

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

    var dizzy_edits: std.ArrayList(dizzy.Edit) = .empty;
    var edits_cb: std.Io.Writer.Allocating = .init(self.allocator);
    const writer = &edits_cb.writer;

    const scratch_len = 4 * (text_dst.len + text_src.len) + 2;
    const scratch = blk: {
        const frame = tracy.initZone(@src(), .{ .name = "scratch" });
        defer frame.deinit();
        break :blk try self.allocator.alloc(u32, scratch_len);
    };
    scratch_alloc = scratch;

    {
        const frame = tracy.initZone(@src(), .{ .name = "diff" });
        defer frame.deinit();
        try dizzy.PrimitiveSliceDiffer(u8).diff(arena, &dizzy_edits, text_src, text_dst, scratch);
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
                    scan_char(text_src[dizzy_edit.range.start..dizzy_edit.range.end], &lines_dst, '\n', &last_offset);
                },
                .insert => {
                    const line_start_dst: usize = lines_dst;
                    try cbor.writeValue(writer, .{
                        .range = .{
                            .start = .{ .line = line_start_dst, .character = last_offset },
                            .end = .{ .line = line_start_dst, .character = last_offset },
                        },
                        .text = text_dst[dizzy_edit.range.start..dizzy_edit.range.end],
                    });
                    edits_count += 1;
                    scan_char(text_dst[dizzy_edit.range.start..dizzy_edit.range.end], &lines_dst, '\n', &last_offset);
                },
                .delete => {
                    var line_end_dst: usize = lines_dst;
                    var offset_end_dst: usize = last_offset;
                    scan_char(text_src[dizzy_edit.range.start..dizzy_edit.range.end], &line_end_dst, '\n', &offset_end_dst);
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
        var msg: std.Io.Writer.Allocating = .init(self.allocator);
        defer msg.deinit();
        const msg_writer = &msg.writer;
        try cbor.writeMapHeader(msg_writer, 2);
        try cbor.writeValue(msg_writer, "textDocument");
        try cbor.writeValue(msg_writer, .{ .uri = uri, .version = version });
        try cbor.writeValue(msg_writer, "contentChanges");
        try cbor.writeArrayHeader(msg_writer, edits_count);
        _ = try msg_writer.write(edits_cb.written());

        self.lsp.send_notification_raw("textDocument/didChange", msg.written()) catch return error.LspFailed;
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
    const uri = try make_URI(self.allocator, self.project_name, file_path);
    defer self.allocator.free(uri);
    self.lsp.send_notification("textDocument/didSave", .{
        .textDocument = .{ .uri = uri },
    }) catch return error.LspFailed;
}

pub fn did_close(self: *Self, file_path: []const u8) LspError!void {
    const uri = try make_URI(self.allocator, self.project_name, file_path);
    defer self.allocator.free(uri);
    self.lsp.send_notification("textDocument/didClose", .{
        .textDocument = .{ .uri = uri },
    }) catch return error.LspFailed;
}

pub const LspInfoError = error{ InvalidInfoMessage, InvalidTriggerCharacters };

fn send_init_request(
    self: *Self,
    from: tp.pid_ref,
    language_server: []const u8,
    language_server_options: []const u8,
    language_server_protocol: file_type_config.ProtocolLevel,
    notify_restart: bool,
) !void {
    const project_path = self.project_name;
    const project_uri = try make_URI(self.allocator, self.project_name, null);
    defer self.allocator.free(project_uri);
    const basename_begin = std.mem.lastIndexOfScalar(u8, project_path, std.fs.path.sep);
    const project_basename = if (basename_begin) |begin| project_path[begin + 1 ..] else project_path;
    const lsp = self.lsp;

    const handler: struct {
        from: tp.pid,
        language_server: []const u8,
        lsp: LSP,
        project_path: []const u8,
        notify_restart: bool,

        pub fn deinit(self_: *@This()) void {
            self_.from.deinit();
            self_.lsp.pid.deinit();
            std.heap.c_allocator.free(self_.language_server);
            std.heap.c_allocator.free(self_.project_path);
        }

        pub fn receive(self_: @This(), response: tp.message) !void {
            self_.lsp.send_notification("initialized", .{}) catch return error.LspFailed;
            if (self_.lsp.pid.expired()) return error.LspFailed;
            std.log.info("initialized LSP: {f}", .{fmt_lsp_name_func(self_.language_server)});

            if (self_.notify_restart) {
                var lsp_name: []const u8 = "";
                _ = cbor.match(self_.language_server, .{ cbor.extract(&lsp_name), cbor.more }) catch false;
                self_.from.send(.{ "PRJ", "lsp_restarted", self_.project_path, lsp_name }) catch {};
            }

            var result: []const u8 = undefined;
            if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.null_ })) {
                return;
            } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.map })) {
                if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&result) }))
                    try send_lsp_init_response(self_.from.ref(), self_.project_path, self_.language_server, result);
            }
        }
    } = .{
        .from = from.clone(),
        .language_server = try std.heap.c_allocator.dupe(u8, language_server),
        .lsp = .{
            .allocator = lsp.allocator,
            .pid = lsp.pid.clone(),
        },
        .project_path = try std.heap.c_allocator.dupe(u8, project_path),
        .notify_restart = notify_restart,
    };

    const version = if (root.version.len > 0 and root.version[0] == 'v') root.version[1..] else root.version;
    const initializationOptions: struct {
        pub fn cborEncode(ctx: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            if (ctx.language_server_options.len == 0) {
                try cbor.writeValue(writer, null);
                return;
            }
            const toCbor = cbor.fromJsonAlloc(ctx.client.allocator, ctx.language_server_options) catch {
                try cbor.writeValue(writer, null);
                ctx.client.logger_lsp.print_err("init", "ignored invalid JSON in LSP initialization options", .{});
                return;
            };
            defer ctx.client.allocator.free(toCbor);

            writer.writeAll(toCbor) catch return error.WriteFailed;
        }
        client: *Self,
        language_server_options: []const u8,
    } = .{ .client = self, .language_server_options = language_server_options };

    try lsp.set_protocol(language_server_protocol);

    if (language_server_protocol == .simple) {
        try lsp.send_request(self.allocator, "initialize", .{
            .rootUri = project_uri,
        }, handler);
        return;
    }

    try lsp.send_request(self.allocator, "initialize", .{
        .initializationOptions = initializationOptions,
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
            .version = version,
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
    }, handler);
}

fn send_lsp_init_response(to: tp.pid_ref, project_path: []const u8, language_server: []const u8, result: []const u8) (LspInfoError || cbor.Error)!void {
    var iter = result;
    var len = cbor.decodeMapHeader(&iter) catch return;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidInfoMessage;
        if (std.mem.eql(u8, field_name, "capabilities")) {
            try send_lsp_capabilities(to, project_path, language_server, &iter);
        } else {
            try cbor.skipValue(&iter);
        }
    }
}

fn send_lsp_capabilities(to: tp.pid_ref, project_path: []const u8, language_server: []const u8, iter: *[]const u8) (LspInfoError || cbor.Error)!void {
    var len = cbor.decodeMapHeader(iter) catch return;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(iter, &field_name))) return error.InvalidInfoMessage;
        if (std.mem.eql(u8, field_name, "completionProvider")) {
            try send_lsp_completionProvider(to, project_path, language_server, iter);
        } else {
            try cbor.skipValue(iter);
        }
    }
}

fn send_lsp_completionProvider(to: tp.pid_ref, project_path: []const u8, language_server: []const u8, iter: *[]const u8) (LspInfoError || cbor.Error)!void {
    var len = cbor.decodeMapHeader(iter) catch return;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(iter, &field_name))) return error.InvalidInfoMessage;
        if (std.mem.eql(u8, field_name, "triggerCharacters")) {
            var items: []const u8 = undefined;
            if (!(try cbor.matchValue(iter, cbor.extract_cbor(&items)))) return error.InvalidTriggerCharacters;
            try send_lsp_triggerCharacters(to, project_path, language_server, items);
        } else {
            try cbor.skipValue(iter);
        }
    }
}

fn send_lsp_triggerCharacters(to: tp.pid_ref, project_path: []const u8, language_server: []const u8, items: []const u8) (LspInfoError || cbor.Error)!void {
    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const w = &writer;
    try cbor.writeArrayHeader(w, 5);
    try cbor.writeValue(w, "PRJ");
    try cbor.writeValue(w, "triggerCharacters");
    try cbor.writeValue(w, project_path);
    try w.writeAll(language_server);
    try w.writeAll(items);
    to.send_raw(.{ .buf = w.buffered() }) catch |e| {
        std.log.err("send triggerCharacters failed: {t}", .{e});
        return;
    };
}

const LspNameFormatter = struct {
    data: []const u8,
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return format_lsp_name_func(self.data, writer);
    }
};

fn fmt_lsp_name_func(bytes: []const u8) LspNameFormatter {
    return .{ .data = bytes };
}

fn format_lsp_name_func(
    bytes: []const u8,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
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
