const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const command = @import("command");
const project_manager = @import("project_manager");

const tui = @import("../../tui.zig");

pub const Type = @import("file_browser.zig").Create(@This());

pub const create = Type.create;

pub fn load_entries(self: *Type) !void {
    const editor = tui.get_active_editor() orelse return;
    const file_path = editor.file_path orelse "";
    try self.mini_editor.buffer.insert(file_path);
    if (editor.get_primary().selection) |sel| ret: {
        const text = editor.get_selection(sel, self.allocator) catch break :ret;
        defer self.allocator.free(text);
        if (!(text.len > 2 and std.mem.eql(u8, text[0..2], "..")))
            try self.mini_editor.buffer.clear();
        const begin = self.file_path().len;
        try self.mini_editor.buffer.insert(text);
        const end = self.file_path().len;
        if (std.fs.path.extension(text).len == 0 and !std.mem.endsWith(u8, text, std.fs.path.sep_str))
            try append_default_extension(self, editor);
        self.mini_editor.buffer.select_range(begin, end);
        return;
    }
    const buffer = editor.buffer orelse return;
    if (buffer.file_exists and !buffer.is_ephemeral()) return;
    const basename = std.fs.path.basename(file_path);
    const extension = std.fs.path.extension(basename);
    if (extension.len == 0)
        try append_default_extension(self, editor);
    self.mini_editor.buffer.select_range(file_path.len - basename.len, file_path.len - extension.len);
}

fn append_default_extension(self: *Type, editor: *const tui.exports.editor.Editor) !void {
    const ext = default_extension(editor) orelse return;
    try self.mini_editor.buffer.insert(".");
    try self.mini_editor.buffer.insert(ext);
}

fn default_extension(editor: *const tui.exports.editor.Editor) ?[]const u8 {
    const file_type = editor.file_type orelse return null;
    return for (file_type.extensions orelse return null) |ext| {
        if (std.mem.indexOfScalar(u8, ext, '.') == null) break ext;
    } else null;
}

pub fn name(_: *Type) []const u8 {
    return " save as";
}

pub fn select(self: *Type) void {
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const file_path = project_manager.expand_home(self.allocator, &buf, self.file_path());
        if (file_path.len > 0) {
            var save_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
            const save: cbor.Raw = .{ .bytes = cbor.fmt(&save_buf, .{ "cmd", "save_file_as", .{file_path} }) };
            tui.probe(file_path, .{ .file = save, .other = save });
        }
    }
    command.executeName("exit_mini_mode", .empty()) catch {};
}
