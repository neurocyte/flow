description: ?[]const u8 = null,
extensions: ?[]const []const u8 = null,
icon: ?[]const u8 = null,
color: ?u24 = null,
comment: ?[]const u8 = null,
formatter: ?[]const []const u8 = null,
language_server: ?[]const []const u8 = null,
first_line_matches_prefix: ?[]const u8 = null,
first_line_matches_content: ?[]const u8 = null,

include_files: []const u8 = "",

pub fn from_file_type(file_type: *const FileType) @This() {
    return .{
        .color = file_type.color,
        .icon = file_type.icon,
        .description = file_type.description,
        .extensions = file_type.extensions,
        .first_line_matches_prefix = if (file_type.first_line_matches) |flm| flm.prefix else null,
        .first_line_matches_content = if (file_type.first_line_matches) |flm| flm.content else null,
        .comment = file_type.comment,
        .formatter = file_type.formatter,
        .language_server = file_type.language_server,
    };
}

const FileType = @import("syntax").FileType;
