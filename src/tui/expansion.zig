/// Expand variables in arg
/// {{project}} - The path to the current project directory
/// {{file}} - The path to the current file
/// {{line}} - The line number of the primary cursor
/// {{column}} - The column of the primary cursor
/// {{selection}} - The current selection of the primary cursor
/// {{selections}} - All current selections seperated by NL characters
/// {{selectionsZ}} - All current selections separated by NULL characters
/// {{selections*}} - All current selections expanded to multiple quoted arguments
/// {{indent_mode}} - The current indent mode ("tabs" or "spaces")
/// {{indent_size}} - The current indent size (in columns)
pub fn expand(allocator: Allocator, arg: []const u8) Error![]const u8 {
    var result: std.Io.Writer.Allocating = .init(allocator);
    defer result.deinit();
    var iter = arg;

    while (iter.len > 0) {
        const pos_begin = std.mem.indexOf(u8, iter, var_begin_mark) orelse {
            try result.writer.writeAll(iter);
            break;
        };
        try result.writer.writeAll(iter[0..pos_begin]);
        iter = iter[pos_begin + var_begin_mark.len ..];

        const pos_end = std.mem.indexOf(u8, iter, var_end_mark) orelse {
            try result.writer.writeAll(iter);
            break;
        };
        const var_name = iter[0..pos_end];
        iter = iter[pos_end + var_end_mark.len ..];

        const func = variables.get(var_name) orelse {
            std.log.err("unknown variable '{s}'", .{arg});
            return error.NotFound;
        };
        const text = try func(allocator);
        defer allocator.free(text);
        try result.writer.writeAll(text);
    }
    return try result.toOwnedSlice();
}

pub fn expand_cbor(allocator: Allocator, args_cbor: []const u8) ![]const u8 {
    var result: std.Io.Writer.Allocating = .init(allocator);
    defer result.deinit();
    var iter = args_cbor;
    var len = try cbor.decodeArrayHeader(&iter);
    try cbor.writeArrayHeader(&result.writer, len);
    while (len > 0) : (len -= 1) {
        var arg: []const u8 = undefined;
        if (try cbor.matchValue(&iter, cbor.extract(&arg))) {
            const expanded = try expand(allocator, arg);
            defer allocator.free(expanded);
            try cbor.writeValue(&result.writer, expanded);
        } else {
            if (try cbor.matchValue(&iter, cbor.extract_cbor(&arg)))
                try result.writer.writeAll(arg);
        }
    }
    return try result.toOwnedSlice();
}

const var_begin_mark = "{{";
const var_end_mark = "}}";

pub const Error = error{
    OutOfMemory,
    WriteFailed,
    NotFound,
};
const variables = std.StaticStringMap(Function).initComptime(get_functions());

const functions = struct {
    pub fn project(allocator: Allocator) Error![]const u8 {
        return try allocator.dupe(u8, tp.env.get().str("project"));
    }

    pub fn file(allocator: Allocator) Error![]const u8 {
        const mv = tui.mainview() orelse return &.{};
        const ed = mv.get_active_editor() orelse return &.{};
        return allocator.dupe(u8, ed.file_path orelse &.{});
    }

    pub fn line(allocator: Allocator) Error![]const u8 {
        const mv = tui.mainview() orelse return &.{};
        const ed = mv.get_active_editor() orelse return &.{};
        var stream: std.Io.Writer.Allocating = .init(allocator);
        try stream.writer.print("{d}", .{ed.get_primary().cursor.row + 1});
        return stream.toOwnedSlice();
    }

    pub fn column(allocator: Allocator) Error![]const u8 {
        const mv = tui.mainview() orelse return &.{};
        const ed = mv.get_active_editor() orelse return &.{};
        var stream: std.Io.Writer.Allocating = .init(allocator);
        try stream.writer.print("{d}", .{ed.get_primary().cursor.col + 1});
        return stream.toOwnedSlice();
    }

    pub fn selection(allocator: Allocator) Error![]const u8 {
        const mv = tui.mainview() orelse return &.{};
        const ed = mv.get_active_editor() orelse return &.{};
        const sel = ed.get_primary().selection orelse return &.{};
        return allocator.dupe(u8, ed.get_selection(sel, allocator) catch &.{});
    }

    pub fn selections(allocator: Allocator) Error![]const u8 {
        const mv = tui.mainview() orelse return &.{};
        const ed = mv.get_active_editor() orelse return &.{};
        var results: std.Io.Writer.Allocating = .init(allocator);
        for (ed.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            const sel = cursel.selection orelse continue;
            const text = ed.get_selection(sel, allocator) catch return error.WriteFailed;
            defer allocator.free(text);
            try results.writer.writeAll(text);
            try results.writer.writeByte('\n');
        };
        return try results.toOwnedSlice();
    }

    pub fn selectionsZ(allocator: Allocator) Error![]const u8 {
        const mv = tui.mainview() orelse return &.{};
        const ed = mv.get_active_editor() orelse return &.{};
        var results: std.Io.Writer.Allocating = .init(allocator);
        for (ed.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
            const sel = cursel.selection orelse continue;
            const text = ed.get_selection(sel, allocator) catch return error.WriteFailed;
            defer allocator.free(text);
            try results.writer.writeAll(text);
            try results.writer.writeByte(0);
        };
        return try results.toOwnedSlice();
    }

    // pub fn @"selections*"(allocator: Allocator) Error![][]const u8 {
    //     const mv = tui.mainview() orelse return &.{};
    //     const ed = mv.get_active_editor() orelse return &.{};
    //     var results: std.ArrayList([]const u8) = .empty;
    //     for (ed.cursels.items) |*cursel_| if (cursel_.*) |*cursel| {
    //         const sel = cursel.selection orelse continue;
    //         (try results.addOne(allocator)).* = ed.get_selection(sel, allocator);
    //     };
    //     return results.toOwnedSlice(allocator);
    // }

    /// {{indent_mode}} - The current indent mode ("tabs" or "spaces")
    pub fn indent_mode(allocator: Allocator) Error![]const u8 {
        const mv = tui.mainview() orelse return &.{};
        const ed = mv.get_active_editor() orelse return &.{};
        var stream: std.Io.Writer.Allocating = .init(allocator);
        try stream.writer.print("{t}", .{ed.indent_mode});
        return stream.toOwnedSlice();
    }

    /// {{indent_size}} - The current indent size (in columns)
    pub fn indent_size(allocator: Allocator) Error![]const u8 {
        const mv = tui.mainview() orelse return &.{};
        const ed = mv.get_active_editor() orelse return &.{};
        var stream: std.Io.Writer.Allocating = .init(allocator);
        try stream.writer.print("{d}", .{ed.indent_size});
        return stream.toOwnedSlice();
    }
};

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
const tp = @import("thespian");
const cbor = @import("cbor");
const tui = @import("tui.zig");
