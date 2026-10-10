const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const root = @import("soft_root").root;
const file_link = @import("file_link");

const filelist_stream_references: usize = 1;
const dizzy = @import("dizzy");
const tracy = @import("tracy");
const Buffer = @import("Buffer");
const FileStore = @import("FileStore");
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
server_capabilities: ServerCapabilities = .{},

const Self = @This();

pub const ServerCapabilities = struct {
    code_action: CodeActionProvider = .none,
    execute_commands: []const []const u8 = &.{},
    sync: TextDocumentSync = .incremental,

    pub const CodeActionProvider = enum { none, actions, actions_with_resolve };
    pub const TextDocumentSync = enum(u2) { none = 0, full = 1, incremental = 2 };

    pub fn read(allocator: std.mem.Allocator, capabilities: []const u8) (OutOfMemoryError || cbor.Error)!ServerCapabilities {
        var self: ServerCapabilities = .{};
        errdefer self.deinit(allocator);
        var iter = capabilities;
        var len = try cbor.decodeMapHeader(&iter);
        while (len > 0) : (len -= 1) {
            var field_name: []const u8 = undefined;
            if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidType;
            if (std.mem.eql(u8, field_name, "codeActionProvider")) {
                self.code_action = try read_code_action_provider(&iter);
            } else if (std.mem.eql(u8, field_name, "executeCommandProvider")) {
                self.execute_commands = try read_execute_commands(allocator, &iter);
            } else if (std.mem.eql(u8, field_name, "textDocumentSync")) {
                self.sync = try read_text_document_sync(&iter);
            } else {
                try cbor.skipValue(&iter);
            }
        }
        return self;
    }

    fn read_code_action_provider(iter: *[]const u8) cbor.Error!CodeActionProvider {
        var supported: bool = false;
        if (try cbor.matchValue(iter, cbor.extract(&supported)))
            return if (supported) .actions else .none;
        var resolve_provider: bool = false;
        var len = try cbor.decodeMapHeader(iter);
        while (len > 0) : (len -= 1) {
            var field_name: []const u8 = undefined;
            if (!(try cbor.matchString(iter, &field_name))) return error.InvalidType;
            if (std.mem.eql(u8, field_name, "resolveProvider")) {
                if (!(try cbor.matchValue(iter, cbor.extract(&resolve_provider)))) try cbor.skipValue(iter);
            } else {
                try cbor.skipValue(iter);
            }
        }
        return if (resolve_provider) .actions_with_resolve else .actions;
    }

    fn read_text_document_sync(iter: *[]const u8) cbor.Error!TextDocumentSync {
        var kind: usize = 0;
        if (try cbor.matchValue(iter, cbor.extract(&kind)))
            return std.enums.fromInt(TextDocumentSync, kind) orelse .incremental;
        var sync: TextDocumentSync = .none;
        var len = cbor.decodeMapHeader(iter) catch {
            try cbor.skipValue(iter);
            return .incremental;
        };
        while (len > 0) : (len -= 1) {
            var field_name: []const u8 = undefined;
            if (!(try cbor.matchString(iter, &field_name))) return error.InvalidType;
            if (std.mem.eql(u8, field_name, "change") and try cbor.matchValue(iter, cbor.extract(&kind))) {
                sync = std.enums.fromInt(TextDocumentSync, kind) orelse .incremental;
            } else {
                try cbor.skipValue(iter);
            }
        }
        return sync;
    }

    fn read_execute_commands(allocator: std.mem.Allocator, iter: *[]const u8) (OutOfMemoryError || cbor.Error)![]const []const u8 {
        var commands: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (commands.items) |command| allocator.free(command);
            commands.deinit(allocator);
        }
        var len = cbor.decodeMapHeader(iter) catch {
            try cbor.skipValue(iter);
            return &.{};
        };
        while (len > 0) : (len -= 1) {
            var field_name: []const u8 = undefined;
            if (!(try cbor.matchString(iter, &field_name))) return error.InvalidType;
            if (std.mem.eql(u8, field_name, "commands")) {
                var count = try cbor.decodeArrayHeader(iter);
                while (count > 0) : (count -= 1) {
                    var command: []const u8 = undefined;
                    if (!(try cbor.matchString(iter, &command))) return error.InvalidType;
                    (try commands.addOne(allocator)).* = try allocator.dupe(u8, command);
                }
            } else {
                try cbor.skipValue(iter);
            }
        }
        return commands.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *ServerCapabilities, allocator: std.mem.Allocator) void {
        for (self.execute_commands) |command| allocator.free(command);
        allocator.free(self.execute_commands);
        self.* = .{};
    }

    pub fn can_execute(self: *const ServerCapabilities, command: []const u8) bool {
        for (self.execute_commands) |command_| if (std.mem.eql(u8, command_, command)) return true;
        return false;
    }
};

pub const CodeActionTrigger = enum { invoked, automatic };

pub fn code_actions(
    self: *Self,
    from: tp.pid_ref,
    file_path: []const u8,
    range: Range,
    diagnostics: []const u8,
    only: []const u8,
    trigger: CodeActionTrigger,
    token: u32,
) LspError!void {
    if (self.server_capabilities.code_action == .none)
        return send_code_actions_result(from, file_path, token, null) catch error.LspFailed;

    const uri = try make_URI(self.allocator, self.project_name, file_path);
    defer self.allocator.free(uri);

    const handler: struct {
        from: tp.pid,
        file_path: []const u8,
        token: u32,

        pub fn deinit(self_: *@This()) void {
            std.heap.c_allocator.free(self_.file_path);
            self_.from.deinit();
        }

        pub fn receive(self_: @This(), response: tp.message) (CodeActionError || cbor.Error)!void {
            var result: []const u8 = undefined;
            if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.array })) {
                if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&result) }))
                    return send_code_actions_result(self_.from.ref(), self_.file_path, self_.token, result);
            }
            return send_code_actions_result(self_.from.ref(), self_.file_path, self_.token, null);
        }
    } = .{
        .from = from.clone(),
        .file_path = try std.heap.c_allocator.dupe(u8, file_path),
        .token = token,
    };

    const Context = struct {
        diagnostics: []const u8,
        only: []const u8,
        trigger: CodeActionTrigger,

        pub fn cborEncode(ctx: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try cbor.writeMapHeader(writer, if (ctx.only.len > 0) 3 else 2);
            try cbor.writeValue(writer, "diagnostics");
            try writer.writeAll(ctx.diagnostics);
            if (ctx.only.len > 0) {
                try cbor.writeValue(writer, "only");
                try cbor.writeValue(writer, .{ctx.only});
            }
            try cbor.writeValue(writer, "triggerKind");
            try cbor.writeValue(writer, @as(u8, switch (ctx.trigger) {
                .invoked => 1,
                .automatic => 2,
            }));
        }
    };

    self.lsp.send_request(self.allocator, "textDocument/codeAction", .{
        .textDocument = .{ .uri = uri },
        .range = range,
        .context = Context{ .diagnostics = diagnostics, .only = only, .trigger = trigger },
    }, handler) catch return error.LspFailed;
}

const CodeActionFields = struct {
    edit: ?[]const u8 = null,
    command: ?[]const u8 = null,
    has_data: bool = false,
};

fn read_code_action(action: []const u8) CodeActionError!CodeActionFields {
    var fields: CodeActionFields = .{};
    var iter = action;
    var len = cbor.decodeMapHeader(&iter) catch return error.InvalidCodeAction;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        var value: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &field_name) catch false)) return error.InvalidCodeActionFieldName;
        if (!(cbor.matchValue(&iter, cbor.extract_cbor(&value)) catch false)) return error.InvalidCodeActionField;
        if (cbor.match(value, cbor.null_) catch false) continue;
        if (std.mem.eql(u8, field_name, "edit")) {
            fields.edit = value;
        } else if (std.mem.eql(u8, field_name, "command")) {
            // a Command item has the command name here, a CodeAction has a Command object
            fields.command = if (cbor.match(value, cbor.string) catch false) action else value;
        } else if (std.mem.eql(u8, field_name, "data")) {
            fields.has_data = true;
        }
    }
    return fields;
}

fn get_lsp_name(self: *const Self) []const u8 {
    var name: []const u8 = "";
    _ = cbor.match(self.language_server, .{ cbor.extract(&name), cbor.more }) catch false;
    return name;
}

pub fn apply_code_action(self: *Self, from: tp.pid_ref, action: []const u8) (LspError || CodeActionError)!void {
    const fields = try read_code_action(action);
    const can_resolve = self.server_capabilities.code_action == .actions_with_resolve or fields.has_data;
    if (fields.edit != null or fields.command != null or !can_resolve)
        return execute_code_action(from, tp.self_pid(), self.project_name, self.get_lsp_name(), action) catch error.LspFailed;

    const handler: struct {
        from: tp.pid,
        project_manager: tp.pid,
        project: []const u8,
        lsp_name: []const u8,

        pub fn deinit(self_: *@This()) void {
            std.heap.c_allocator.free(self_.project);
            std.heap.c_allocator.free(self_.lsp_name);
            self_.project_manager.deinit();
            self_.from.deinit();
        }

        pub fn receive(self_: @This(), response: tp.message) !void {
            var result: []const u8 = undefined;
            if (!try cbor.match(response.buf, .{ "child", tp.string, "result", tp.map }))
                return std.log.err("failed to resolve code action", .{});
            if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&result) }))
                try execute_code_action(self_.from.ref(), self_.project_manager.ref(), self_.project, self_.lsp_name, result);
        }
    } = .{
        .from = from.clone(),
        .project_manager = tp.self_pid().clone(),
        .project = try std.heap.c_allocator.dupe(u8, self.project_name),
        .lsp_name = try std.heap.c_allocator.dupe(u8, self.get_lsp_name()),
    };

    self.lsp.send_request(self.allocator, "codeAction/resolve", cbor.Raw{ .bytes = action }, handler) catch return error.LspFailed;
}

// apply the edit of a code action first, then execute its command
fn execute_code_action(to: tp.pid_ref, project_manager: tp.pid_ref, project: []const u8, lsp_name_: []const u8, action: []const u8) !void {
    const fields = try read_code_action(action);
    const edit = fields.edit orelse {
        const command = fields.command orelse return std.log.warn("code action has no edit and no command", .{});
        return project_manager.send(.{ "execute_command", project, lsp_name_, cbor.Raw{ .bytes = command } });
    };
    var workspace_edit: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    defer workspace_edit.deinit();
    try write_workspace_edit(&workspace_edit.writer, edit);
    return if (fields.command) |command|
        to.send(.{ "cmd", "apply_workspace_edit", .{
            cbor.Raw{ .bytes = workspace_edit.written() },
            .{ "execute_command", project, lsp_name_, cbor.Raw{ .bytes = command } },
        } })
    else
        to.send(.{ "cmd", "apply_workspace_edit", .{cbor.Raw{ .bytes = workspace_edit.written() }} });
}

pub fn execute_command(self: *Self, command: []const u8) LspError!void {
    var name: []const u8 = "";
    var arguments: ?[]const u8 = null;
    var iter = command;
    var len = cbor.decodeMapHeader(&iter) catch return error.LspFailed;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        var value: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &field_name) catch false)) return error.LspFailed;
        if (!(cbor.matchValue(&iter, cbor.extract_cbor(&value)) catch false)) return error.LspFailed;
        if (std.mem.eql(u8, field_name, "command")) {
            _ = cbor.match(value, cbor.extract(&name)) catch false;
        } else if (std.mem.eql(u8, field_name, "arguments")) {
            if (!(cbor.match(value, cbor.null_) catch false)) arguments = value;
        }
    }
    if (!self.server_capabilities.can_execute(name))
        return self.logger_lsp.print("{f} cannot execute command '{s}'", .{ fmt_lsp_name_func(self.language_server), name });

    const handler: struct {
        pub fn deinit(_: *@This()) void {}
        pub fn receive(_: @This(), _: tp.message) !void {}
    } = .{};
    (if (arguments) |arguments_|
        self.lsp.send_request(self.allocator, "workspace/executeCommand", .{ .command = name, .arguments = cbor.Raw{ .bytes = arguments_ } }, handler)
    else
        self.lsp.send_request(self.allocator, "workspace/executeCommand", .{ .command = name }, handler)) catch return error.LspFailed;
}

pub const CodeActionError = error{
    InvalidCodeAction,
    InvalidCodeActionField,
    InvalidCodeActionFieldName,
} || std.Io.Writer.Error;

pub fn send_code_actions_result(to: tp.pid_ref, file_path: []const u8, token: u32, actions: ?[]const u8) CodeActionError!void {
    var entries: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    defer entries.deinit();
    if (actions) |actions_|
        try write_code_actions(&entries.writer, actions_)
    else
        try cbor.writeArrayHeader(&entries.writer, 0);
    to.send(.{ "cmd", "code_actions_result", .{ file_path, token, cbor.Raw{ .bytes = entries.written() } } }) catch |e| {
        std.log.err("send code_actions_result failed: {t}", .{e});
    };
}

pub const CodeActionPreference = enum { normal, preferred };

/// write the result of a textDocument/codeAction request, an array of CodeAction or Command items,
/// as [[title, kind, preference, disabled_reason, action], ...]
pub fn write_code_actions(writer: *std.Io.Writer, actions: []const u8) CodeActionError!void {
    var iter = actions;
    var len = cbor.decodeArrayHeader(&iter) catch return error.InvalidCodeAction;
    try cbor.writeArrayHeader(writer, len);
    while (len > 0) : (len -= 1) {
        var action: []const u8 = undefined;
        if (!(cbor.matchValue(&iter, cbor.extract_cbor(&action)) catch false)) return error.InvalidCodeAction;
        try write_code_action(writer, action);
    }
}

fn write_code_action(writer: *std.Io.Writer, action: []const u8) CodeActionError!void {
    var title: []const u8 = "";
    var kind: []const u8 = "";
    var is_preferred: bool = false;
    var disabled_reason: []const u8 = "";
    var iter = action;
    var len = cbor.decodeMapHeader(&iter) catch return error.InvalidCodeAction;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &field_name) catch false)) return error.InvalidCodeActionFieldName;
        if (std.mem.eql(u8, field_name, "title")) {
            if (!(cbor.matchValue(&iter, cbor.extract(&title)) catch false)) return error.InvalidCodeActionField;
        } else if (std.mem.eql(u8, field_name, "kind")) {
            if (!(cbor.matchValue(&iter, cbor.extract(&kind)) catch false)) cbor.skipValue(&iter) catch return error.InvalidCodeActionField;
        } else if (std.mem.eql(u8, field_name, "isPreferred")) {
            if (!(cbor.matchValue(&iter, cbor.extract(&is_preferred)) catch false)) cbor.skipValue(&iter) catch return error.InvalidCodeActionField;
        } else if (std.mem.eql(u8, field_name, "disabled")) {
            var disabled: []const u8 = undefined;
            if (!(cbor.matchValue(&iter, cbor.extract_cbor(&disabled)) catch false)) return error.InvalidCodeActionField;
            disabled_reason = read_disabled_reason(disabled);
        } else {
            cbor.skipValue(&iter) catch return error.InvalidCodeActionField;
        }
    }
    try cbor.writeValue(writer, .{
        title,
        kind,
        @as(CodeActionPreference, if (is_preferred) .preferred else .normal),
        disabled_reason,
        cbor.Raw{ .bytes = action },
    });
}

fn read_disabled_reason(disabled: []const u8) []const u8 {
    var reason: []const u8 = "disabled";
    var iter = disabled;
    var len = cbor.decodeMapHeader(&iter) catch return reason;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &field_name) catch false)) return reason;
        if (std.mem.eql(u8, field_name, "reason")) {
            _ = cbor.matchValue(&iter, cbor.extract(&reason)) catch false;
            return reason;
        }
        cbor.skipValue(&iter) catch return reason;
    }
    return reason;
}

pub fn set_server_capabilities(self: *Self, capabilities: []const u8) (OutOfMemoryError || cbor.Error)!void {
    const server_capabilities: ServerCapabilities = try .read(self.allocator, capabilities);
    self.server_capabilities.deinit(self.allocator);
    self.server_capabilities = server_capabilities;
    std.log.debug("{f}: code actions: {t}, commands: {d}, sync: {t}", .{
        fmt_lsp_name_func(self.language_server),
        server_capabilities.code_action,
        server_capabilities.execute_commands.len,
        server_capabilities.sync,
    });
}

/// write the diagnostics that overlap or touch range as an array
pub fn write_diagnostics_in_range(writer: *std.Io.Writer, diagnostics: []const u8, range: Range) (RangeError || std.Io.Writer.Error)!void {
    var count: usize = 0;
    var iter = diagnostics;
    var len = try cbor.decodeArrayHeader(&iter);
    while (len > 0) : (len -= 1) {
        var diagnostic: []const u8 = undefined;
        if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&diagnostic)))) return error.InvalidType;
        if (try diagnostic_in_range(diagnostic, range)) count += 1;
    }

    try cbor.writeArrayHeader(writer, count);
    iter = diagnostics;
    len = try cbor.decodeArrayHeader(&iter);
    while (len > 0) : (len -= 1) {
        var diagnostic: []const u8 = undefined;
        if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&diagnostic)))) return error.InvalidType;
        if (try diagnostic_in_range(diagnostic, range)) try writer.writeAll(diagnostic);
    }
}

fn diagnostic_in_range(diagnostic: []const u8, range: Range) RangeError!bool {
    var iter = diagnostic;
    var len = try cbor.decodeMapHeader(&iter);
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidType;
        if (std.mem.eql(u8, field_name, "range")) {
            var range_: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&range_)))) return error.InvalidType;
            const diagnostic_range = try read_range(range_);
            return !position_before(diagnostic_range.end, range.start) and !position_before(range.end, diagnostic_range.start);
        }
        try cbor.skipValue(&iter);
    }
    return false;
}

fn position_before(a: Position, b: Position) bool {
    return a.line < b.line or (a.line == b.line and a.character < b.character);
}

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
    self.server_capabilities.deinit(self.allocator);
    self.logger_lsp.deinit();
    self.allocator.free(self.language_server_options);
    self.allocator.free(self.language_server);
    self.allocator.free(self.project_name);
    self.allocator.destroy(self);
}

pub fn expired(self: *const Self) bool {
    return self.lsp.pid.expired();
}

pub fn process_instance_id(self: *const Self) tp.piid {
    return self.lsp.pid.instance_id();
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

pub const GetLineOfFileError = FileStore.GetLineOfFileError;

pub fn get_line_of_file(allocator: std.mem.Allocator, file_path: []const u8, line: usize) GetLineOfFileError![]const u8 {
    return FileStore.get_line_of_file(allocator, root.get_io(), file_path, line);
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
} || TextEditError || cbor.Error || std.Io.Writer.Error;
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
    var additionalTextEdits: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    defer additionalTextEdits.deinit();

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
            if (try cbor.matchValue(&iter, cbor.null_)) continue;
            additionalTextEdits.clearRetainingCapacity();
            try write_text_edits(&additionalTextEdits.writer, &iter);
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (additionalTextEdits.written().len == 0)
        try cbor.writeArrayHeader(&additionalTextEdits.writer, 0);
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
            cbor.Raw{ .bytes = additionalTextEdits.written() },
            cbor.Raw{ .bytes = item },
        },
    }) catch |e| {
        std.log.err("send add_completion failed: {t}", .{e});
    };
}

fn write_text_edits(writer: *std.Io.Writer, iter: *[]const u8) (TextEditError || std.Io.Writer.Error)!void {
    var len = cbor.decodeArrayHeader(iter) catch return invalid_text_edit_field("textEdits");
    try cbor.writeArrayHeader(writer, len);
    while (len > 0) : (len -= 1) {
        const edit = try read_textEdit(iter);
        const range = edit.replace orelse edit.insert orelse return invalid_text_edit_field("textEdits.range");
        try cbor.writeValue(writer, .{
            range.start.line,
            range.start.character,
            range.end.line,
            range.end.character,
            edit.newText,
        });
    }
}

pub fn completion_resolve(self: *Self, from: tp.pid_ref, file_path: []const u8, token: u32, item: []const u8) LspError!void {
    const handler: struct {
        from: tp.pid,
        file_path: []const u8,
        token: u32,

        pub fn deinit(self_: *@This()) void {
            std.heap.c_allocator.free(self_.file_path);
            self_.from.deinit();
        }

        pub fn receive(self_: @This(), response: tp.message) (CompletionItemError || cbor.Error)!void {
            var text_edits: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
            defer text_edits.deinit();
            var result: []const u8 = undefined;
            if (!try cbor.match(response.buf, .{ "child", tp.string, "result", tp.map })) {
                try cbor.writeValue(&text_edits.writer, null);
            } else {
                if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&result) })) {
                    var iter = result;
                    var len = try cbor.decodeMapHeader(&iter);
                    while (len > 0) : (len -= 1) {
                        var field_name: []const u8 = undefined;
                        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidCompletionItemFieldName;
                        if (std.mem.eql(u8, field_name, "additionalTextEdits")) {
                            if (try cbor.matchValue(&iter, cbor.null_)) continue;
                            text_edits.clearRetainingCapacity();
                            try write_text_edits(&text_edits.writer, &iter);
                        } else {
                            try cbor.skipValue(&iter);
                        }
                    }
                }
                if (text_edits.written().len == 0)
                    try cbor.writeArrayHeader(&text_edits.writer, 0);
            }
            self_.from.send(.{ "cmd", "completion_resolved", .{
                self_.file_path,
                self_.token,
                cbor.Raw{ .bytes = text_edits.written() },
            } }) catch |e| {
                std.log.err("send completion_resolved failed: {t}", .{e});
            };
        }
    } = .{
        .from = from.clone(),
        .file_path = try std.heap.c_allocator.dupe(u8, file_path),
        .token = token,
    };

    self.lsp.send_request(self.allocator, "completionItem/resolve", cbor.Raw{ .bytes = item }, handler) catch return error.LspFailed;
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

        fn goto_alternative_destination(self_: @This()) !void {
            if (self_.alternative_destination) |*link_|
                try navigate_to_alternate_destination(self_.from.ref(), link_);
        }

        pub fn receive(self_: @This(), response: tp.message) !void {
            var link: []const u8 = undefined;
            var locations: []const u8 = undefined;
            if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.array })) {
                if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, .{tp.extract_cbor(&link)} })) {
                    try navigate_to_location_link(self_.from.ref(), link);
                } else if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&locations) })) {
                    // an empty result array means the server found nothing
                    var iter = locations;
                    if (try cbor.decodeArrayHeader(&iter) == 0)
                        return self_.goto_alternative_destination();
                    _ = try send_reference_list("FLS", filelist_stream_references, self_.from.ref(), locations, self_.name);
                }
            } else if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.null_ })) {
                return self_.goto_alternative_destination();
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
                "byte",
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
                "byte",
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
        .goto = .{ dest.line orelse 1, dest.column orelse 1, "byte" },
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
                const count = try send_reference_list("FLS", filelist_stream_references, self_.from.ref(), locations, self_.name);
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

fn send_reference_list(tag: []const u8, stream: usize, to: tp.pid_ref, locations: []const u8, name: []const u8) (error{
    InvalidTargetURI,
    InvalidReferenceList,
} || LocationLinkError || GetLineOfFileError || cbor.Error)!usize {
    defer to.send(.{ tag, stream, "done" }) catch {};
    var iter = locations;
    var len = try cbor.decodeArrayHeader(&iter);
    const count = len;
    while (len > 0) : (len -= 1) {
        var location: []const u8 = undefined;
        if (try cbor.matchValue(&iter, cbor.extract_cbor(&location))) {
            try send_reference(tag, stream, to, location, name);
        } else return error.InvalidReferenceList;
    }
    return count;
}

fn send_reference(tag: []const u8, stream: usize, to: tp.pid_ref, location_: []const u8, name: []const u8) (error{InvalidTargetURI} || LocationLinkError || GetLineOfFileError || cbor.Error)!void {
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
        stream,
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

        pub fn deinit(self_: *@This()) void {
            self_.from.deinit();
        }

        pub fn receive(self_: @This(), response: tp.message) !void {
            const allocator = std.heap.c_allocator;
            var result: []const u8 = undefined;

            if (try cbor.match(response.buf, .{ "child", tp.string, "result", tp.map })) {
                if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&result) })) {
                    var workspace_edit: std.Io.Writer.Allocating = .init(allocator);
                    defer workspace_edit.deinit();
                    try write_workspace_edit(&workspace_edit.writer, result);

                    // send the renames as a single, atomic message
                    var msg_buf: std.Io.Writer.Allocating = .init(allocator);
                    defer msg_buf.deinit();
                    const w = &msg_buf.writer;
                    try cbor.writeArrayHeader(w, 3);
                    try cbor.writeValue(w, "cmd");
                    try cbor.writeValue(w, "rename_symbol_item");
                    try cbor.writeArrayHeader(w, try count_workspace_edit_text_edits(workspace_edit.written()));

                    var iter: []const u8 = workspace_edit.written();
                    var files = try cbor.decodeArrayHeader(&iter);
                    while (files > 0) : (files -= 1) {
                        var file_path: []const u8 = undefined;
                        var text_edits: []const u8 = undefined;
                        if (!try cbor.matchValue(&iter, .{ cbor.extract(&file_path), cbor.any, cbor.extract_cbor(&text_edits) })) {
                            try cbor.skipValue(&iter);
                            continue;
                        }
                        var edits = try cbor.decodeArrayHeader(&text_edits);
                        while (edits > 0) : (edits -= 1) {
                            var range: Range = undefined;
                            var new_text: []const u8 = undefined;
                            if (!try cbor.matchValue(&text_edits, .{
                                cbor.extract(&range.start.line),
                                cbor.extract(&range.start.character),
                                cbor.extract(&range.end.line),
                                cbor.extract(&range.end.character),
                                cbor.extract(&new_text),
                            })) return error.InvalidWorkspaceEdit;
                            const line = try get_line_of_file(allocator, file_path, range.start.line);
                            try cbor.writeValue(w, .{
                                file_path,
                                range.start.line,
                                range.start.character,
                                range.end.line,
                                range.end.character,
                                new_text,
                                line,
                            });
                        }
                    }
                    self_.from.send_raw(.{ .buf = msg_buf.written() }) catch return error.ClientFailed;
                }
            }
        }
    } = .{
        .from = from.clone(),
    };

    self.lsp.send_request(self.allocator, "textDocument/rename", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = source_location.src.line, .character = source_location.src.column },
        .newName = "PLACEHOLDER",
    }, handler) catch return error.LspFailed;
}

pub const WorkspaceEditError = error{
    InvalidWorkspaceEdit,
    InvalidWorkspaceEditField,
    InvalidWorkspaceEditFieldName,
    InvalidTargetURI,
} || TextEditError || std.Io.Writer.Error;

pub fn write_workspace_edit(writer: *std.Io.Writer, workspace_edit: []const u8) WorkspaceEditError!void {
    var iter = workspace_edit;
    var len = cbor.decodeMapHeader(&iter) catch return error.InvalidWorkspaceEdit;
    var changes: ?[]const u8 = null;
    var document_changes: ?[]const u8 = null;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        var value: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidWorkspaceEditFieldName;
        if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&value)))) return error.InvalidWorkspaceEditField;
        if (try cbor.match(value, cbor.null_)) continue;
        if (std.mem.eql(u8, field_name, "changes")) {
            changes = value;
        } else if (std.mem.eql(u8, field_name, "documentChanges")) {
            document_changes = value;
        }
    }
    return if (document_changes) |value|
        write_workspace_edit_document_changes(writer, value)
    else if (changes) |value|
        write_workspace_edit_changes(writer, value)
    else
        error.InvalidWorkspaceEdit;
}

fn write_workspace_edit_changes(writer: *std.Io.Writer, changes: []const u8) WorkspaceEditError!void {
    var iter = changes;
    var files = cbor.decodeMapHeader(&iter) catch return error.InvalidWorkspaceEditField;
    try cbor.writeArrayHeader(writer, files);
    while (files > 0) : (files -= 1) {
        var file_uri: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &file_uri))) return error.InvalidWorkspaceEditFieldName;
        try write_workspace_edit_file(writer, file_uri, null, &iter);
    }
}

fn write_workspace_edit_document_changes(writer: *std.Io.Writer, document_changes: []const u8) WorkspaceEditError!void {
    var iter = document_changes;
    var len = cbor.decodeArrayHeader(&iter) catch return error.InvalidWorkspaceEditField;
    try cbor.writeArrayHeader(writer, len);
    while (len > 0) : (len -= 1) {
        var change: []const u8 = undefined;
        if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&change)))) return error.InvalidWorkspaceEditField;
        if (try read_text_document_edit(change)) |edit_| {
            var edit = edit_;
            try write_workspace_edit_file(writer, edit.uri, edit.version, &edit.edits);
        } else try write_file_operation(writer, change);
    }
}

pub const FileOperation = enum { create, rename, delete };
pub const FileConflict = FileStore.Conflict;
pub const FileScope = FileStore.Scope;

// CreateFile, RenameFile or DeleteFile as [kind, path, to_path, on_conflict, scope]
fn write_file_operation(writer: *std.Io.Writer, change: []const u8) WorkspaceEditError!void {
    var kind: ?FileOperation = null;
    var uri: []const u8 = "";
    var old_uri: []const u8 = "";
    var new_uri: []const u8 = "";
    var overwrite = false;
    var ignore = false;
    var recursive = false;
    var iter = change;
    var len = cbor.decodeMapHeader(&iter) catch return error.InvalidWorkspaceEditField;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidWorkspaceEditFieldName;
        if (std.mem.eql(u8, field_name, "kind")) {
            var kind_: []const u8 = undefined;
            if (!(try cbor.matchString(&iter, &kind_))) return error.InvalidWorkspaceEditField;
            kind = std.meta.stringToEnum(FileOperation, kind_) orelse return error.InvalidWorkspaceEditField;
        } else if (std.mem.eql(u8, field_name, "uri")) {
            if (!(try cbor.matchString(&iter, &uri))) return error.InvalidWorkspaceEditField;
        } else if (std.mem.eql(u8, field_name, "oldUri")) {
            if (!(try cbor.matchString(&iter, &old_uri))) return error.InvalidWorkspaceEditField;
        } else if (std.mem.eql(u8, field_name, "newUri")) {
            if (!(try cbor.matchString(&iter, &new_uri))) return error.InvalidWorkspaceEditField;
        } else if (std.mem.eql(u8, field_name, "options")) {
            if (try cbor.matchValue(&iter, cbor.null_)) continue;
            var options = cbor.decodeMapHeader(&iter) catch return error.InvalidWorkspaceEditField;
            while (options > 0) : (options -= 1) {
                var value = false;
                if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidWorkspaceEditFieldName;
                if (!(try cbor.matchValue(&iter, cbor.extract(&value)))) {
                    try cbor.skipValue(&iter);
                    continue;
                }
                if (std.mem.eql(u8, field_name, "overwrite")) {
                    overwrite = value;
                } else if (std.mem.eql(u8, field_name, "ignoreIfExists") or std.mem.eql(u8, field_name, "ignoreIfNotExists")) {
                    ignore = value;
                } else if (std.mem.eql(u8, field_name, "recursive")) {
                    recursive = value;
                }
            }
        } else {
            try cbor.skipValue(&iter);
        }
    }
    const kind_ = kind orelse return error.InvalidWorkspaceEditField;
    const from_uri = if (kind_ == .rename) old_uri else uri;
    if (from_uri.len == 0 or (kind_ == .rename and new_uri.len == 0)) return error.InvalidWorkspaceEditField;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var to_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try cbor.writeValue(writer, .{
        kind_,
        try file_uri_to_path(from_uri, &path_buf),
        if (kind_ == .rename) try file_uri_to_path(new_uri, &to_path_buf) else "",
        @as(FileConflict, if (overwrite) .overwrite else if (ignore) .ignore else .fail),
        @as(FileScope, if (recursive) .recursive else .file),
    });
}

const TextDocumentEdit = struct {
    uri: []const u8,
    version: ?usize,
    edits: []const u8,
};

// returns null for the resource operations CreateFile, RenameFile and DeleteFile
fn read_text_document_edit(change: []const u8) WorkspaceEditError!?TextDocumentEdit {
    var iter = change;
    var len = cbor.decodeMapHeader(&iter) catch return error.InvalidWorkspaceEditField;
    var uri: ?[]const u8 = null;
    var version: ?usize = null;
    var edits: ?[]const u8 = null;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidWorkspaceEditFieldName;
        if (std.mem.eql(u8, field_name, "kind")) {
            return null;
        } else if (std.mem.eql(u8, field_name, "textDocument")) {
            var fields = cbor.decodeMapHeader(&iter) catch return error.InvalidWorkspaceEditField;
            while (fields > 0) : (fields -= 1) {
                if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidWorkspaceEditFieldName;
                if (std.mem.eql(u8, field_name, "uri")) {
                    var uri_: []const u8 = undefined;
                    if (!(try cbor.matchString(&iter, &uri_))) return error.InvalidWorkspaceEditField;
                    uri = uri_;
                } else if (std.mem.eql(u8, field_name, "version")) {
                    if (!(try cbor.matchValue(&iter, cbor.extract(&version)))) return error.InvalidWorkspaceEditField;
                } else {
                    try cbor.skipValue(&iter);
                }
            }
        } else if (std.mem.eql(u8, field_name, "edits")) {
            var edits_: []const u8 = undefined;
            if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&edits_)))) return error.InvalidWorkspaceEditField;
            edits = edits_;
        } else {
            try cbor.skipValue(&iter);
        }
    }
    return .{
        .uri = uri orelse return error.InvalidWorkspaceEditField,
        .version = version,
        .edits = edits orelse return error.InvalidWorkspaceEditField,
    };
}

fn write_workspace_edit_file(writer: *std.Io.Writer, file_uri: []const u8, version: ?usize, text_edits: *[]const u8) WorkspaceEditError!void {
    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try cbor.writeArrayHeader(writer, 3);
    try cbor.writeValue(writer, try file_uri_to_path(file_uri, &file_path_buf));
    try cbor.writeValue(writer, version);
    try write_text_edits(writer, text_edits);
}

fn count_workspace_edit_text_edits(workspace_edit: []const u8) cbor.Error!usize {
    var count: usize = 0;
    var iter = workspace_edit;
    var files = try cbor.decodeArrayHeader(&iter);
    while (files > 0) : (files -= 1) {
        var text_edits: []const u8 = undefined;
        if (!try cbor.matchValue(&iter, .{ cbor.any, cbor.any, cbor.extract_cbor(&text_edits) })) {
            try cbor.skipValue(&iter);
            continue;
        }
        count += try cbor.decodeArrayHeader(&text_edits);
    }
    return count;
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
    switch (self.server_capabilities.sync) {
        .none => return,
        .full => return self.did_change_full(file_path, version, text_dst),
        .incremental => {},
    }
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

fn did_change_full(self: *Self, file_path: []const u8, version: usize, text: []const u8) LspError!void {
    const uri = try make_URI(self.allocator, self.project_name, file_path);
    defer self.allocator.free(uri);
    self.lsp.send_notification("textDocument/didChange", .{
        .textDocument = .{ .uri = uri, .version = version },
        .contentChanges = .{.{ .text = text }},
    }) catch return error.LspFailed;
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
        project_manager: tp.pid,

        pub fn deinit(self_: *@This()) void {
            self_.from.deinit();
            self_.project_manager.deinit();
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
                if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&result) })) {
                    try send_lsp_init_response(self_.from.ref(), self_.project_path, self_.language_server, result);
                    try self_.send_server_capabilities(result);
                }
            }
        }

        fn send_server_capabilities(self_: @This(), result: []const u8) !void {
            var lsp_name: []const u8 = "";
            _ = cbor.match(self_.language_server, .{ cbor.extract(&lsp_name), cbor.more }) catch false;
            var iter = result;
            var len = cbor.decodeMapHeader(&iter) catch return;
            while (len > 0) : (len -= 1) {
                var field_name: []const u8 = undefined;
                var value: []const u8 = undefined;
                if (!(try cbor.matchString(&iter, &field_name))) return;
                if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&value)))) return;
                if (std.mem.eql(u8, field_name, "capabilities"))
                    self_.project_manager.send(.{ "lsp_capabilities", self_.project_path, lsp_name, cbor.Raw{ .bytes = value } }) catch {};
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
        .project_manager = tp.self_pid().clone(),
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
                .executeCommand = .{ .dynamicRegistration = false },
                .workspaceEdit = .{
                    .documentChanges = true,
                    .resourceOperations = .{ "create", "rename", "delete" },
                    .failureHandling = "abort",
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
                        .resolveSupport = .{ .properties = .{"additionalTextEdits"} },
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
                                "source.fixAll",
                            },
                        },
                    },
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
    var resolve_provider: bool = false;
    defer to.send(.{ "PRJ", "completionResolveProvider", project_path, cbor.Raw{ .bytes = language_server }, resolve_provider }) catch |e| {
        std.log.err("send completionResolveProvider failed: {t}", .{e});
    };
    var len = cbor.decodeMapHeader(iter) catch return;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(iter, &field_name))) return error.InvalidInfoMessage;
        if (std.mem.eql(u8, field_name, "triggerCharacters")) {
            var items: []const u8 = undefined;
            if (!(try cbor.matchValue(iter, cbor.extract_cbor(&items)))) return error.InvalidTriggerCharacters;
            try send_lsp_triggerCharacters(to, project_path, language_server, items);
        } else if (std.mem.eql(u8, field_name, "resolveProvider")) {
            if (!(try cbor.matchValue(iter, cbor.extract(&resolve_provider)))) try cbor.skipValue(iter);
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
