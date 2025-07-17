const std = @import("std");
const cbor = @import("cbor");
const treez = @import("treez");

pub const tss = @import("ts_serializer.zig");

const verbose = false;

pub fn main() anyerror!void {
    const allocator = std.heap.c_allocator;
    const args = try std.process.argsAlloc(allocator);

    var opt_output_file_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (opt_output_file_path != null) fatal("duplicated {s} argument", .{arg});
        opt_output_file_path = args[i];
    }

    const output_file_path = opt_output_file_path orelse fatal("missing output file", .{});
    var output_file = std.fs.cwd().createFile(output_file_path, .{}) catch |err| {
        fatal("unable to open '{s}': {s}", .{ output_file_path, @errorName(err) });
    };
    defer output_file.close();

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    const writer = output.writer();

    try cbor.writeMapHeader(writer, file_types.len);

    for (file_types) |file_type| {
        const lang = file_type.lang_fn() orelse std.debug.panic("tree-sitter parser function failed for language: {s}", .{file_type.name});

        try cbor.writeValue(writer, file_type.name);
        try cbor.writeMapHeader(writer, if (file_type.injections) |_| 3 else 2);

        const highlights_in = try treez.Query.create(lang, file_type.highlights);
        const ts_highlights_in: *tss.TSQuery = @alignCast(@ptrCast(highlights_in));

        const highlights_cb = try tss.toCbor(ts_highlights_in, allocator);
        defer allocator.free(highlights_cb);

        try cbor.writeValue(writer, "highlights");
        try cbor.writeValue(writer, highlights_cb);
        if (verbose)
            std.log.info("file_type {s} highlights {d} bytes", .{ file_type.name, highlights_cb.len });

        const errors_in = try treez.Query.create(lang, "(ERROR) @error");
        const ts_errors_in: *tss.TSQuery = @alignCast(@ptrCast(errors_in));

        const errors_cb = try tss.toCbor(ts_errors_in, allocator);
        defer allocator.free(errors_cb);

        try cbor.writeValue(writer, "errors");
        try cbor.writeValue(writer, errors_cb);
        if (verbose)
            std.log.info("file_type {s} errors {d} bytes", .{ file_type.name, errors_cb.len });

        if (file_type.injections) |injections| {
            const injections_in = try treez.Query.create(lang, injections);
            const ts_injections_in: *tss.TSQuery = @alignCast(@ptrCast(injections_in));

            const injections_cb = try tss.toCbor(ts_injections_in, allocator);
            defer allocator.free(injections_cb);

            try cbor.writeValue(writer, "injections");
            try cbor.writeValue(writer, injections_cb);
            if (verbose)
                std.log.info("file_type {s} injections {d} bytes", .{ file_type.name, injections_cb.len });
        }
    }

    try output_file.writeAll(output.items);
    if (verbose)
        std.log.info("file_types total {d} bytes", .{output.items.len});
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}

pub const file_types = load_file_types(@import("file_types.zig"));

const FileType = struct {
    name: []const u8,
    lang_fn: LangFn,
    highlights: [:0]const u8,
    injections: ?[:0]const u8,
};
const LangFn = *const fn () callconv(.c) ?*const treez.Language;

fn load_file_types(comptime Namespace: type) []const FileType {
    comptime switch (@typeInfo(Namespace)) {
        .@"struct" => |info| {
            var count = 0;
            for (info.decls) |_| count += 1;
            var construct_types: [count]FileType = undefined;
            var i = 0;
            for (info.decls) |decl| {
                const lang = decl.name;
                const args = @field(Namespace, lang);
                construct_types[i] = .{
                    .name = lang,
                    .lang_fn = if (@hasField(@TypeOf(args), "parser")) args.parser else get_parser(lang),
                    .highlights = if (@hasField(@TypeOf(args), "highlights"))
                        @embedFile(args.highlights)
                    else if (@hasField(@TypeOf(args), "highlights_list"))
                        @embedFile(args.highlights_list[0]) ++ "\n" ++ @embedFile(args.highlights_list[1])
                    else
                        @embedFile("tree-sitter-" ++ lang ++ "/queries/highlights.scm"),
                    .injections = if (@hasField(@TypeOf(args), "injections"))
                        @embedFile(args.injections)
                    else
                        null,
                };
                i += 1;
            }
            const types = construct_types;
            return &types;
        },
        else => @compileError("expected tuple or struct type"),
    };
}

fn get_parser(comptime lang: []const u8) LangFn {
    const language_name = ft_func_name(lang);
    return @extern(?LangFn, .{ .name = "tree_sitter_" ++ language_name }) orelse @compileError(std.fmt.comptimePrint("Cannot find extern tree_sitter_{s}", .{language_name}));
}

fn ft_func_name(comptime lang: []const u8) []const u8 {
    var transform: [lang.len]u8 = undefined;
    for (lang, 0..) |c, i|
        transform[i] = if (c == '-') '_' else c;
    const func_name = transform;
    return &func_name;
}
