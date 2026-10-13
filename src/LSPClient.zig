const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const root = @import("soft_root").root;
const file_link = @import("file_link");

const filelist_stream_references: usize = 1;
const tracy = @import("tracy");
const Buffer = @import("Buffer");
const FileStore = @import("FileStore");
const EditSet = @import("EditSet");
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
document_hashes: DocumentHashes = .{},
documents: Documents = .{},
capabilities_known: bool = false,
server_name: []const u8 = "",
server_version: []const u8 = "",

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

pub const DocumentHashes = struct {
    documents: std.StringHashMapUnmanaged(Versions) = .empty,

    pub const max_versions = 32;

    const Versions = struct {
        entries: [max_versions]Entry = undefined,
        len: usize = 0,
        next: usize = 0,

        const Entry = struct { version: usize, hash: EditSet.Hash };

        fn add(self: *Versions, version: usize, hash: EditSet.Hash) void {
            self.entries[self.next] = .{ .version = version, .hash = hash };
            self.next = (self.next + 1) % max_versions;
            self.len = @min(self.len + 1, max_versions);
        }

        fn latest(self: *const Versions) ?Entry {
            return if (self.len == 0) null else self.entries[(self.next + max_versions - 1) % max_versions];
        }

        fn get(self: *const Versions, version: usize) ?EditSet.Hash {
            for (self.entries[0..self.len]) |entry| if (entry.version == version) return entry.hash;
            return null;
        }
    };

    pub fn deinit(self: *DocumentHashes, allocator: std.mem.Allocator) void {
        var keys = self.documents.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        self.documents.deinit(allocator);
        self.* = .{};
    }

    pub fn open(self: *DocumentHashes, allocator: std.mem.Allocator, uri: []const u8, version: usize, hash: EditSet.Hash) error{OutOfMemory}!void {
        self.close(allocator, uri);
        const key = try allocator.dupe(u8, uri);
        errdefer allocator.free(key);
        var versions: Versions = .{};
        versions.add(version, hash);
        try self.documents.put(allocator, key, versions);
    }

    pub fn change(self: *DocumentHashes, uri: []const u8, version: usize, hash: EditSet.Hash) void {
        if (self.documents.getPtr(uri)) |versions| versions.add(version, hash);
    }

    pub fn close(self: *DocumentHashes, allocator: std.mem.Allocator, uri: []const u8) void {
        if (self.documents.fetchRemove(uri)) |kv| allocator.free(kv.key);
    }

    pub fn base_hash(self: *const DocumentHashes, uri: []const u8, version: ?usize) ?EditSet.Hash {
        const versions = self.documents.getPtr(uri) orelse return null;
        return if (version) |version_| versions.get(version_) else if (versions.latest()) |entry| entry.hash else null;
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
        return self.execute_code_action(from, action) catch error.LspFailed;

    const handler: struct {
        project_manager: tp.pid,
        project: []const u8,
        lsp_name: []const u8,

        pub fn deinit(self_: *@This()) void {
            std.heap.c_allocator.free(self_.project);
            std.heap.c_allocator.free(self_.lsp_name);
            self_.project_manager.deinit();
        }

        pub fn receive(self_: @This(), response: tp.message) !void {
            var result: []const u8 = undefined;
            if (!try cbor.match(response.buf, .{ "child", tp.string, "result", tp.map }))
                return std.log.err("failed to resolve code action", .{});
            if (try cbor.match(response.buf, .{ tp.any, tp.any, tp.any, tp.extract_cbor(&result) }))
                try self_.project_manager.send(.{ "execute_code_action", self_.project, self_.lsp_name, cbor.Raw{ .bytes = result } });
        }
    } = .{
        .project_manager = tp.self_pid().clone(),
        .project = try std.heap.c_allocator.dupe(u8, self.project_name),
        .lsp_name = try std.heap.c_allocator.dupe(u8, self.get_lsp_name()),
    };

    self.lsp.send_request(self.allocator, "codeAction/resolve", cbor.Raw{ .bytes = action }, handler) catch return error.LspFailed;
}

// apply the edit of a code action first, then execute its command
pub fn execute_code_action(self: *Self, to: tp.pid_ref, action: []const u8) !void {
    const project = self.project_name;
    const lsp_name_ = self.get_lsp_name();
    const fields = try read_code_action(action);
    const edit = fields.edit orelse {
        const command = fields.command orelse return std.log.warn("code action has no edit and no command", .{});
        return tp.self_pid().send(.{ "execute_command", project, lsp_name_, cbor.Raw{ .bytes = command } });
    };
    var workspace_edit: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    defer workspace_edit.deinit();
    try write_workspace_edit(&workspace_edit.writer, edit, &self.document_hashes);
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

pub fn set_server_info(self: *Self, server_info: []const u8) (OutOfMemoryError || cbor.Error)!void {
    var name: []const u8 = "";
    var version: []const u8 = "";
    var iter = server_info;
    var len = cbor.decodeMapHeader(&iter) catch return;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return;
        if (std.mem.eql(u8, field_name, "name")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&name)))) try cbor.skipValue(&iter);
        } else if (std.mem.eql(u8, field_name, "version")) {
            if (!(try cbor.matchValue(&iter, cbor.extract(&version)))) try cbor.skipValue(&iter);
        } else try cbor.skipValue(&iter);
    }
    const owned_name = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(owned_name);
    const owned_version = try self.allocator.dupe(u8, version);
    self.allocator.free(self.server_name);
    self.allocator.free(self.server_version);
    self.server_name = owned_name;
    self.server_version = owned_version;
}

pub fn set_server_capabilities(self: *Self, capabilities: []const u8) (OutOfMemoryError || cbor.Error)!void {
    const server_capabilities: ServerCapabilities = try .read(self.allocator, capabilities);
    self.server_capabilities.deinit(self.allocator);
    self.server_capabilities = server_capabilities;
    self.capabilities_known = true;
    if (!self.keeps_documents()) self.documents.deinit(self.allocator);
    std.log.debug("{f}: code actions: {t}, commands: {d}, sync: {t}", .{
        fmt_lsp_name_func(self.language_server),
        server_capabilities.code_action,
        server_capabilities.execute_commands.len,
        server_capabilities.sync,
    });
}

pub const ConfigurationError = cbor.Error || std.Io.Writer.Error || error{InvalidConfigurationParams};

pub fn write_configuration(writer: *std.Io.Writer, settings: []const u8, params: []const u8) ConfigurationError!void {
    var iter = params;
    var len = cbor.decodeMapHeader(&iter) catch return error.InvalidConfigurationParams;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidConfigurationParams;
        if (!std.mem.eql(u8, field_name, "items")) {
            try cbor.skipValue(&iter);
            continue;
        }
        var items = cbor.decodeArrayHeader(&iter) catch return error.InvalidConfigurationParams;
        try cbor.writeArrayHeader(writer, items);
        while (items > 0) : (items -= 1) {
            const section = try read_configuration_section(&iter);
            if (configuration_section(settings, section)) |value|
                try writer.writeAll(value)
            else
                try cbor.writeValue(writer, null);
        }
        return;
    }
    return error.InvalidConfigurationParams;
}

fn read_configuration_section(iter: *[]const u8) ConfigurationError!?[]const u8 {
    var section: ?[]const u8 = null;
    var len = cbor.decodeMapHeader(iter) catch return error.InvalidConfigurationParams;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(iter, &field_name))) return error.InvalidConfigurationParams;
        var value: []const u8 = undefined;
        if (std.mem.eql(u8, field_name, "section") and try cbor.matchString(iter, &value)) {
            section = value;
        } else {
            try cbor.skipValue(iter);
        }
    }
    return section;
}

fn configuration_section(settings: []const u8, section: ?[]const u8) ?[]const u8 {
    if (settings.len == 0) return null;
    var value = settings;
    var path = std.mem.splitScalar(u8, section orelse return settings, '.');
    while (path.next()) |key| value = map_value(value, key) orelse return null;
    return value;
}

fn map_value(map: []const u8, key: []const u8) ?[]const u8 {
    var iter = map;
    var len = cbor.decodeMapHeader(&iter) catch return null;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &field_name) catch return null)) return null;
        const value = iter;
        cbor.skipValue(&iter) catch return null;
        if (std.mem.eql(u8, field_name, key)) return value[0 .. value.len - iter.len];
    }
    return null;
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
    self.allocator.free(self.server_name);
    self.allocator.free(self.server_version);
    self.document_hashes.deinit(self.allocator);
    self.documents.deinit(self.allocator);
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
            try write_text_edits(&additionalTextEdits.writer, &iter, null);
        } else {
            try cbor.skipValue(&iter);
        }
    }
    if (additionalTextEdits.written().len == 0)
        try write_no_text_edits(&additionalTextEdits.writer);
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

/// write an LSP TextEdit[] as an edit set, a server may send the edits in any order
fn write_text_edits(writer: *std.Io.Writer, iter: *[]const u8, base_hash: ?EditSet.Hash) (TextEditError || std.Io.Writer.Error)!void {
    const allocator = std.heap.c_allocator;
    var len = cbor.decodeArrayHeader(iter) catch return invalid_text_edit_field("textEdits");
    var edits: std.ArrayList(EditSet.Edit) = try .initCapacity(allocator, len);
    defer edits.deinit(allocator);
    while (len > 0) : (len -= 1) {
        const edit = try read_textEdit(iter);
        const range = edit.replace orelse edit.insert orelse return invalid_text_edit_field("textEdits.range");
        const begin: EditSet.Position = .{ .row = range.start.line, .pos = range.start.character };
        const end: EditSet.Position = .{ .row = range.end.line, .pos = range.end.character };
        edits.appendAssumeCapacity(if (end.order(begin) == .lt)
            .{ .begin = end, .end = begin, .text = edit.newText }
        else
            .{ .begin = begin, .end = end, .text = edit.newText });
    }
    std.mem.sort(EditSet.Edit, edits.items, {}, EditSet.less_than);
    EditSet.write(writer, edits.items, .{ .base_hash = base_hash }) catch |e| return switch (e) {
        error.InvalidEditSet, error.TooManyEdits => error.InvalidTextEdit,
        error.WriteFailed => error.WriteFailed,
    };
}

fn write_no_text_edits(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    EditSet.write(writer, &.{}, .{}) catch return error.WriteFailed;
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
                            try write_text_edits(&text_edits.writer, &iter, null);
                        } else {
                            try cbor.skipValue(&iter);
                        }
                    }
                }
                if (text_edits.written().len == 0)
                    try write_no_text_edits(&text_edits.writer);
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
                    try write_workspace_edit(&workspace_edit.writer, result, null);

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
                        var edits = EditSet.Iterator.init(.{ .bytes = text_edits }) catch return error.InvalidWorkspaceEdit;
                        while (edits.next() catch return error.InvalidWorkspaceEdit) |edit| {
                            const line = try get_line_of_file(allocator, file_path, edit.begin.row);
                            try cbor.writeValue(w, .{
                                file_path,
                                edit.begin.row,
                                edit.begin.pos,
                                edit.end.row,
                                edit.end.pos,
                                edit.text,
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

pub fn write_workspace_edit(writer: *std.Io.Writer, workspace_edit: []const u8, hashes: ?*const DocumentHashes) WorkspaceEditError!void {
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
        write_workspace_edit_document_changes(writer, value, hashes)
    else if (changes) |value|
        write_workspace_edit_changes(writer, value, hashes)
    else
        error.InvalidWorkspaceEdit;
}

fn write_workspace_edit_changes(writer: *std.Io.Writer, changes: []const u8, hashes: ?*const DocumentHashes) WorkspaceEditError!void {
    var iter = changes;
    var files = cbor.decodeMapHeader(&iter) catch return error.InvalidWorkspaceEditField;
    try cbor.writeArrayHeader(writer, files);
    while (files > 0) : (files -= 1) {
        var file_uri: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &file_uri))) return error.InvalidWorkspaceEditFieldName;
        try write_workspace_edit_file(writer, file_uri, null, &iter, hashes);
    }
}

fn write_workspace_edit_document_changes(writer: *std.Io.Writer, document_changes: []const u8, hashes: ?*const DocumentHashes) WorkspaceEditError!void {
    var iter = document_changes;
    var len = cbor.decodeArrayHeader(&iter) catch return error.InvalidWorkspaceEditField;
    try cbor.writeArrayHeader(writer, len);
    while (len > 0) : (len -= 1) {
        var change: []const u8 = undefined;
        if (!(try cbor.matchValue(&iter, cbor.extract_cbor(&change)))) return error.InvalidWorkspaceEditField;
        if (try read_text_document_edit(change)) |edit_| {
            var edit = edit_;
            try write_workspace_edit_file(writer, edit.uri, edit.version, &edit.edits, hashes);
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

fn write_workspace_edit_file(writer: *std.Io.Writer, file_uri: []const u8, version: ?usize, text_edits: *[]const u8, hashes: ?*const DocumentHashes) WorkspaceEditError!void {
    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try cbor.writeArrayHeader(writer, 3);
    try cbor.writeValue(writer, try file_uri_to_path(file_uri, &file_path_buf));
    try cbor.writeValue(writer, version);
    try write_text_edits(writer, text_edits, if (hashes) |hashes_| hashes_.base_hash(file_uri, version) else null);
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
        count += (EditSet.Iterator.init(.{ .bytes = text_edits }) catch return error.InvalidArrayType).remaining;
    }
    return count;
}

pub fn did_open(self: *Self, file_path: []const u8, file_type: []const u8, version: usize, hash: EditSet.Hash, text: []const u8) LspError!void {
    const uri = try make_URI(self.allocator, self.project_name, file_path);
    defer self.allocator.free(uri);
    try self.document_hashes.open(self.allocator, uri, version, hash);
    self.documents.close(self.allocator, uri);
    if (self.keeps_documents()) try self.documents.open(self.allocator, uri, text);
    self.lsp.send_notification("textDocument/didOpen", .{
        .textDocument = .{ .uri = uri, .languageId = file_type, .version = version, .text = text },
    }) catch return error.LspFailed;
}

fn keeps_documents(self: *const Self) bool {
    return !self.capabilities_known or self.server_capabilities.sync == .full;
}

const Documents = struct {
    texts: std.StringHashMapUnmanaged(std.ArrayList(u8)) = .empty,

    fn deinit(self: *Documents, allocator: std.mem.Allocator) void {
        var it = self.texts.iterator();
        while (it.next()) |p| {
            allocator.free(p.key_ptr.*);
            p.value_ptr.deinit(allocator);
        }
        self.texts.deinit(allocator);
        self.* = .{};
    }

    fn open(self: *Documents, allocator: std.mem.Allocator, uri: []const u8, text: []const u8) error{OutOfMemory}!void {
        const key = try allocator.dupe(u8, uri);
        errdefer allocator.free(key);
        var content: std.ArrayList(u8) = .empty;
        errdefer content.deinit(allocator);
        try content.appendSlice(allocator, text);
        try self.texts.put(allocator, key, content);
    }

    fn close(self: *Documents, allocator: std.mem.Allocator, uri: []const u8) void {
        var kv = self.texts.fetchRemove(uri) orelse return;
        allocator.free(kv.key);
        kv.value.deinit(allocator);
    }
};

pub const DidChangeError = LspError || error{OutOfSync};

pub fn did_change(self: *Self, file_path: []const u8, version: usize, hash: EditSet.Hash, edit_set: cbor.Raw) DidChangeError!void {
    const uri = try make_URI(self.allocator, self.project_name, file_path);
    defer self.allocator.free(uri);
    self.document_hashes.change(uri, version, hash);
    const document = self.documents.texts.getPtr(uri);
    if (document) |text| EditSet.apply_to_string(self.allocator, text, edit_set) catch |e| {
        self.documents.close(self.allocator, uri);
        std.log.err("{s}: the text for the language server is out of sync: {t}", .{ file_path, e });
        return error.OutOfSync;
    };
    switch (self.server_capabilities.sync) {
        .none => {},
        .full => self.lsp.send_notification("textDocument/didChange", .{
            .textDocument = .{ .uri = uri, .version = version },
            .contentChanges = .{.{ .text = (document orelse return error.OutOfSync).items }},
        }) catch return error.LspFailed,
        .incremental => {
            var msg: std.Io.Writer.Allocating = .init(self.allocator);
            defer msg.deinit();
            write_did_change(self.allocator, &msg.writer, uri, version, edit_set) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.LspFailed,
            };
            self.lsp.send_notification_raw("textDocument/didChange", msg.written()) catch return error.LspFailed;
        },
    }
}

pub fn write_did_change(allocator: std.mem.Allocator, writer: *std.Io.Writer, uri: []const u8, version: usize, edit_set: cbor.Raw) !void {
    const edits = try EditSet.collect(allocator, edit_set);
    defer allocator.free(edits);

    try cbor.writeMapHeader(writer, 2);
    try cbor.writeValue(writer, "textDocument");
    try cbor.writeValue(writer, .{ .uri = uri, .version = version });
    try cbor.writeValue(writer, "contentChanges");
    try cbor.writeArrayHeader(writer, edits.len);
    // the server applies the changes one after the other, last edit first keeps the positions of the base document valid
    var index = edits.len;
    while (index > 0) {
        index -= 1;
        const edit = edits[index];
        try cbor.writeValue(writer, .{
            .range = .{
                .start = .{ .line = edit.begin.row, .character = edit.begin.pos },
                .end = .{ .line = edit.end.row, .character = edit.end.pos },
            },
            .text = edit.text,
        });
    }
}

pub fn did_change_full(self: *Self, file_path: []const u8, version: usize, hash: EditSet.Hash, text: []const u8) LspError!void {
    const uri = try make_URI(self.allocator, self.project_name, file_path);
    defer self.allocator.free(uri);
    self.document_hashes.change(uri, version, hash);
    self.documents.close(self.allocator, uri);
    if (self.keeps_documents()) try self.documents.open(self.allocator, uri, text);
    if (self.server_capabilities.sync == .none) return;
    self.lsp.send_notification("textDocument/didChange", .{
        .textDocument = .{ .uri = uri, .version = version },
        .contentChanges = .{.{ .text = text }},
    }) catch return error.LspFailed;
}

pub fn did_save(self: *Self, file_path: []const u8) LspError!void {
    const uri = try make_URI(self.allocator, self.project_name, file_path);
    defer self.allocator.free(uri);
    self.lsp.send_notification("textDocument/didSave", .{
        .textDocument = .{ .uri = uri },
    }) catch return error.LspFailed;
}

pub fn did_change_configuration(self: *Self, settings: ?cbor.Raw) LspError!void {
    self.lsp.send_notification("workspace/didChangeConfiguration", .{
        .settings = settings,
    }) catch return error.LspFailed;
}

pub fn did_close(self: *Self, file_path: []const u8) LspError!void {
    const uri = try make_URI(self.allocator, self.project_name, file_path);
    defer self.allocator.free(uri);
    self.document_hashes.close(self.allocator, uri);
    self.documents.close(self.allocator, uri);
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

            var lsp_name: []const u8 = "";
            _ = cbor.match(self_.language_server, .{ cbor.extract(&lsp_name), cbor.more }) catch false;
            self_.project_manager.send(.{ "lsp_initialized", self_.project_path, lsp_name }) catch {};
            if (self_.notify_restart)
                self_.from.send(.{ "PRJ", "lsp_restarted", self_.project_path, lsp_name }) catch {};

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
                if (std.mem.eql(u8, field_name, "serverInfo"))
                    self_.project_manager.send(.{ "lsp_server_info", self_.project_path, lsp_name, cbor.Raw{ .bytes = value } }) catch {};
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
                .configuration = true,
                .didChangeConfiguration = .{ .dynamicRegistration = false },
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
