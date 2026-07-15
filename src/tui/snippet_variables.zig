/// Resolve the variables of the LSP snippet grammar
/// $TM_SELECTED_TEXT - The currently selected text or the empty string
/// $TM_CURRENT_LINE - The contents of the current line
/// $TM_CURRENT_WORD - The contents of the word under cursor or the empty string
/// $TM_LINE_INDEX - The zero-index based line number
/// $TM_LINE_NUMBER - The one-index based line number
/// $TM_FILENAME - The filename of the current document
/// $TM_FILENAME_BASE - The filename of the current document without its extensions
/// $TM_DIRECTORY - The directory of the current document
/// $TM_FILEPATH - The full file path of the current document
///
/// Returns null for any other name.
pub fn resolve(allocator: Allocator, name: []const u8) Error!?[]const u8 {
    const func = variables.get(name) orelse return null;
    return try func(allocator);
}

pub const Error = error{
    OutOfMemory,
    WriteFailed,
};

const variables = std.StaticStringMap(Function).initComptime(get_functions());

const functions = struct {
    pub fn TM_SELECTED_TEXT(allocator: Allocator) Error![]const u8 {
        const ed = editor() orelse return &.{};
        const sel = ed.get_primary().selection orelse return &.{};
        return ed.get_selection(sel, allocator) catch &.{};
    }

    pub fn TM_CURRENT_LINE(allocator: Allocator) Error![]const u8 {
        const ed = editor() orelse return &.{};
        const root = ed.buf_root() catch return &.{};
        var stream: std.Io.Writer.Allocating = .init(allocator);
        errdefer stream.deinit();
        root.get_line(ed.get_primary().cursor.row, &stream.writer, ed.metrics) catch return &.{};
        return stream.toOwnedSlice();
    }

    pub fn TM_CURRENT_WORD(allocator: Allocator) Error![]const u8 {
        const ed = editor() orelse return &.{};
        return ed.get_word_at_cursor(allocator) catch &.{};
    }

    pub fn TM_LINE_INDEX(allocator: Allocator) Error![]const u8 {
        const ed = editor() orelse return &.{};
        return print(allocator, "{d}", .{ed.get_primary().cursor.row});
    }

    pub fn TM_LINE_NUMBER(allocator: Allocator) Error![]const u8 {
        const ed = editor() orelse return &.{};
        return print(allocator, "{d}", .{ed.get_primary().cursor.row + 1});
    }

    pub fn TM_FILENAME(allocator: Allocator) Error![]const u8 {
        return allocator.dupe(u8, std.fs.path.basename(file_path() orelse return &.{}));
    }

    pub fn TM_FILENAME_BASE(allocator: Allocator) Error![]const u8 {
        return allocator.dupe(u8, std.fs.path.stem(file_path() orelse return &.{}));
    }

    pub fn TM_DIRECTORY(allocator: Allocator) Error![]const u8 {
        const path = file_path() orelse return &.{};
        return allocator.dupe(u8, std.fs.path.dirname(path) orelse &.{});
    }

    pub fn TM_FILEPATH(allocator: Allocator) Error![]const u8 {
        return allocator.dupe(u8, file_path() orelse return &.{});
    }
};

fn editor() ?*Editor {
    const mv = tui.mainview() orelse return null;
    return mv.get_active_editor();
}

fn file_path() ?[]const u8 {
    return (editor() orelse return null).file_path;
}

fn print(allocator: Allocator, comptime fmt: []const u8, args: anytype) Error![]const u8 {
    var stream: std.Io.Writer.Allocating = .init(allocator);
    errdefer stream.deinit();
    try stream.writer.print(fmt, args);
    return stream.toOwnedSlice();
}

fn get_functions() []struct { []const u8, Function } {
    comptime switch (@typeInfo(functions)) {
        .@"struct" => |info| {
            var count = 0;
            for (info.decls) |_| count += 1;
            var funcs: [count]FunctionDef = undefined;
            for (info.decls, 0..) |decl, i|
                funcs[i] = .{ decl.name, &@field(functions, decl.name) };
            return &funcs;
        },
        else => @compileError("expected tuple or struct type"),
    };
}

const Function = *const fn (allocator: Allocator) Error![]const u8;
const FunctionDef = struct { []const u8, Function };

const std = @import("std");
const Allocator = @import("std").mem.Allocator;
const tui = @import("tui.zig");
const Editor = @import("editor.zig").Editor;
