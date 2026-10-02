const Menu = @import("../Menu.zig");
const main = @import("Main.zig");

pub const cursor: Menu = .{ .label = "Language", .items = &.{
    .{ .command = .{ .command = "goto_definition" } },
    .{ .command = .{ .command = "goto_declaration" } },
    .{ .command = .{ .command = "references" } },
    .{ .command = .{ .command = "hover" } },
    .{ .command = .{ .command = "rename_symbol" } },
    .separator,
    .{ .command = .{ .command = "system_paste" } },
    .{ .command = .{ .command = "select_all" } },
    .separator,
    .{ .command = .{ .command = "toggle_comment" } },
    .{ .command = .{ .command = "format" } },
} };

pub const selection: Menu = .{ .label = "Language", .items = &.{
    .{ .command = .{ .command = "cut" } },
    .{ .command = .{ .command = "copy" } },
    .{ .command = .{ .command = "system_paste" } },
    .separator,
    .{ .command = .{ .command = "toggle_comment" } },
    .{ .command = .{ .command = "indent" } },
    .{ .command = .{ .command = "unindent" } },
    .{ .command = .{ .command = "reflow" } },
    .{ .submenu = &main.case },
    .{ .command = .{ .command = "format" } },
    .separator,
    .{ .command = .{ .command = "add_cursor_all_matches" } },
    .{ .command = .{ .command = "send_selection_to_terminal" } },
} };
