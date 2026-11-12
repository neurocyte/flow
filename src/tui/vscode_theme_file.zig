const std = @import("std");
const root = @import("soft_root").root;
const Theme = @import("theme");
const vscode_theme = @import("vscode_theme");
const CustomTheme = @import("CustomTheme.zig");

const max_file_size = 16 * 1024 * 1024;

/// free the result with deinit.
pub fn load(allocator: std.mem.Allocator, file_path: []const u8, scope_list: *std.ArrayList([]const u8)) !Theme {
    return load_file(allocator, file_path, scope_list) catch |e| {
        if (e != error.InvalidTheme) std.log.err("{s}: {t}", .{ file_path, e });
        return e;
    };
}

fn load_file(allocator: std.mem.Allocator, file_path: []const u8, scope_list: *std.ArrayList([]const u8)) !Theme {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var context: Context = .{
        .allocator = allocator,
        .arena = arena.allocator(),
        .dir = std.fs.path.dirname(file_path) orelse ".",
        .scope_list = scope_list,
    };
    const json = try std.Io.Dir.cwd().readFileAlloc(root.get_io(), file_path, context.arena, .limited(max_file_size));
    const cb = try vscode_theme.to_cbor(context.arena, std.fs.path.basename(file_path), json, null);
    const loaded = try vscode_theme.load(context.arena, context.context(), file_path, cb, .{});

    var result = loaded;
    result.name = try allocator.dupe(u8, loaded.name);
    errdefer allocator.free(result.name);
    result.description = try allocator.dupe(u8, loaded.description);
    errdefer allocator.free(result.description);
    result.tokens = try allocator.dupe(Theme.Token, loaded.tokens);
    return result;
}

pub fn write(allocator: std.mem.Allocator, theme: Theme, scopes: [][]const u8, output_path: ?[]const u8) !void {
    write_file(allocator, theme, scopes, output_path) catch |e| {
        std.log.err("theme {s}: write failed: {t}", .{ theme.name, e });
        return e;
    };
    std.log.info("theme {s} imported ({d} tokens)", .{ theme.name, theme.tokens.len });
    if (output_path) |path| std.log.info("theme {s} written to {s}", .{ theme.name, path });
}

fn write_file(allocator: std.mem.Allocator, theme: Theme, scopes: [][]const u8, output_path: ?[]const u8) !void {
    const json = try CustomTheme.jsonFromTheme(allocator, theme, scopes);
    defer allocator.free(json);
    try root.write_theme(theme.name, json);
    if (output_path) |path|
        try std.Io.Dir.cwd().writeFile(root.get_io(), .{ .sub_path = path, .data = json });
}

pub fn deinit(allocator: std.mem.Allocator, theme: Theme) void {
    allocator.free(theme.name);
    allocator.free(theme.description);
    allocator.free(theme.tokens);
}

const Context = struct {
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    dir: []const u8,
    scope_list: *std.ArrayList([]const u8),

    fn context(self: *Context) vscode_theme.Context {
        return .{ .ptr = self, .vtable = &.{ .include = include, .scope_id = scope_id } };
    }

    fn include(ptr: *anyopaque, file_name: []const u8) vscode_theme.Error![]const u8 {
        const self: *Context = @ptrCast(@alignCast(ptr));
        const path = if (std.fs.path.isAbsolute(file_name)) file_name else try std.fs.path.join(self.arena, &.{ self.dir, file_name });
        const json = std.Io.Dir.cwd().readFileAlloc(root.get_io(), path, self.arena, .limited(max_file_size)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound => return error.IncludeNotFound,
            else => return vscode_theme.Diagnostic.fail(null, path, "{t}", .{e}),
        };
        return vscode_theme.to_cbor(self.arena, std.fs.path.basename(file_name), json, null);
    }

    fn scope_id(ptr: *anyopaque, scope: []const u8) error{OutOfMemory}!usize {
        const self: *Context = @ptrCast(@alignCast(ptr));
        for (self.scope_list.items, 0..) |item, idx| if (std.mem.eql(u8, item, scope)) return idx;
        const owned = try self.allocator.dupe(u8, scope);
        errdefer self.allocator.free(owned);
        try self.scope_list.append(self.allocator, owned);
        return self.scope_list.items.len - 1;
    }
};
