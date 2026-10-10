const std = @import("std");
const Buffer = @import("Buffer");
const project_manager = @import("project_manager");
const file_type_config = @import("file_type_config");

pub fn file_type(buffer: *Buffer) ?file_type_config {
    if (buffer.file_type_name) |name| return file_type_config.get(name) catch null;
    const content = buffer.store_to_string_cached(buffer.root, buffer.file_eol_mode);
    const ft = file_type_config.guess_file_type(buffer.get_file_path(), content) orelse return null;
    buffer.file_type_name = ft.name;
    buffer.file_type_icon = ft.icon orelse file_type_config.default.icon;
    buffer.file_type_color = ft.color orelse file_type_config.default.color;
    return ft;
}

pub fn open(buffer: *Buffer) void {
    if (buffer.lsp_state == .open or buffer.is_ephemeral()) return;
    const ft = file_type(buffer) orelse return;
    const language_server = ft.language_server orelse return;
    if (language_server.len == 0) return;
    const content = buffer.store_to_string_cached(buffer.root, buffer.file_eol_mode);
    project_manager.did_open(buffer.get_file_path(), ft, buffer.lsp_version, content, false) catch |e|
        return std.log.err("did_open failed: {t}", .{e});
    buffer.lsp_state = .open;
    buffer.lsp_root = buffer.root;
}

pub fn close(buffer: *Buffer) void {
    if (buffer.lsp_state != .open) return;
    buffer.lsp_state = .closed;
    buffer.lsp_root = null;
    project_manager.did_close(buffer.get_file_path()) catch {};
}

pub fn reopen(buffer: *Buffer) void {
    buffer.lsp_state = .closed;
    open(buffer);
}

/// send the difference between the root that the language server has and the current root
pub fn sync(buffer: *Buffer) !void {
    if (buffer.lsp_state != .open) return open(buffer);
    const old_root = buffer.lsp_root orelse return;
    if (old_root == buffer.root) return;
    const eol_mode = buffer.file_eol_mode;
    const text_dst = try text_from_root(buffer.root, eol_mode);
    const text_src = text_from_root(old_root, eol_mode) catch |e| {
        std.heap.c_allocator.free(text_dst);
        return e;
    };
    buffer.lsp_version += 1;
    buffer.lsp_root = buffer.root;
    project_manager.did_change(buffer.get_file_path(), buffer.lsp_version, text_dst, text_src, eol_mode) catch {};
}

fn text_from_root(root: Buffer.Root, eol_mode: Buffer.EolMode) ![]const u8 {
    var text: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    defer text.deinit();
    try root.store_node(&text.writer, eol_mode);
    return text.toOwnedSlice();
}
