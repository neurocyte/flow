//! Project file finders. A file finder finds the files of one project by
//! name. File lists of project files describe each file by its file type,
//! detected here.

const std = @import("std");

const file_type = @import("file_type.zig");
pub const guess_file_type = file_type.guess_file_type;
pub const guess_path_file_type = file_type.guess_path_file_type;

test {
    std.testing.refAllDecls(@This());
}
