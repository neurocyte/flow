const std = @import("std");
const treez = @import("treez");
pub const FileType = @This();

color: u24,
icon: []const u8,
name: []const u8,
lang_fn: LangFn,
extensions: []const []const u8,
highlights: [:0]const u8,
injections: ?[:0]const u8,
first_line_matches: ?FirstLineMatch = null,
comment: []const u8,

pub fn get_by_name(name: []const u8) ?*const FileType {
    for (file_types) |*file_type|
        if (std.mem.eql(u8, file_type.name, name))
            return file_type;
    return null;
}

pub fn guess(file_path: ?[]const u8, content: []const u8) ?*const FileType {
    if (guess_first_line(content)) |ft| return ft;
    for (file_types) |*file_type|
        if (file_path) |fp| if (match_file_type(file_type, fp))
            return file_type;
    return null;
}

fn guess_first_line(content: []const u8) ?*const FileType {
    const first_line = if (std.mem.indexOf(u8, content, "\n")) |pos| content[0..pos] else content;
    for (file_types) |*file_type|
        if (file_type.first_line_matches) |match|
            if (match_first_line(match, first_line))
                return file_type;
    return null;
}

fn match_first_line(match: FirstLineMatch, first_line: []const u8) bool {
    if (match.prefix) |prefix|
        if (prefix.len > first_line.len or !std.mem.eql(u8, first_line[0..prefix.len], prefix))
            return false;
    if (match.content) |content|
        if (std.mem.indexOf(u8, first_line, content)) |_| {} else return false;
    return true;
}

fn match_file_type(file_type: *const FileType, file_path: []const u8) bool {
    const basename = std.fs.path.basename(file_path);
    const extension = std.fs.path.extension(file_path);
    return for (file_type.extensions) |ext| {
        if (ext.len == basename.len and std.mem.eql(u8, ext, basename))
            return true;
        if (extension.len > 0 and ext.len == extension.len - 1 and std.mem.eql(u8, ext, extension[1..]))
            return true;
    } else false;
}

pub fn Parser(comptime lang: []const u8) LangFn {
    return get_parser(lang);
}

fn get_parser(comptime lang: []const u8) LangFn {
    const language_name = ft_func_name(lang);
    return @extern(?LangFn, .{ .name = "tree_sitter_" ++ language_name }) orelse @compileError(std.fmt.comptimePrint("Cannot find extern tree_sitter_{s}", .{language_name}));
}

fn ft_func_name(comptime lang: []const u8) []const u8 {
    var func_name: [lang.len]u8 = undefined;
    for (lang, 0..) |c, i|
        func_name[i] = if (c == '-') '_' else c;
    return &func_name;
}

const LangFn = *const fn () callconv(.C) ?*const treez.Language;

const FirstLineMatch = struct {
    prefix: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

const FileTypeOptions = struct {
    extensions: []const []const u8 = &[_][]const u8{},
    comment: []const u8,
    icon: ?[]const u8 = null,
    color: ?u24 = null,
    highlights: ?[:0]const u8 = null,
    injections: ?[:0]const u8 = null,
    first_line_matches: ?FirstLineMatch = null,
    parser: ?LangFn = null,
};

fn DeclLang(comptime lang: []const u8, comptime args: FileTypeOptions) FileType {
    return .{
        .color = args.color orelse 0xffffff,
        .icon = args.icon orelse "󱀫",
        .name = lang,
        .lang_fn = if (args.parser) |p| p else get_parser(lang),
        .extensions = args.extensions,
        .comment = args.comment,
        .highlights = if (args.highlights) |h| h else @embedFile("tree-sitter-" ++ lang ++ "/queries/highlights.scm"),
        .injections = args.injections,
        .first_line_matches = args.first_line_matches,
    };
}

pub const file_types = load_file_types(@import("file_types.zig"));

fn load_file_types(comptime Namespace: type) []FileType {
    comptime switch (@typeInfo(Namespace)) {
        .Struct => |info| {
            var count = 0;
            for (info.decls) |_| {
                // @compileLog(decl.name, @TypeOf(@field(Namespace, decl.name)));
                count += 1;
            }
            var cmds: [count]FileType = undefined;
            var i = 0;
            for (info.decls) |decl| {
                cmds[i] = DeclLang(decl.name, @field(Namespace, decl.name));
                i += 1;
            }
            return &cmds;
        },
        else => @compileError("expected tuple or struct type"),
    };
}
