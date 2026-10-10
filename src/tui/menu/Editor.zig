const Menu = @import("../Menu.zig");
const main = @import("Main.zig");

pub const code_actions: Menu = .{
    .label = "Code actions",
    .items = &.{.{ .command = .{ .command = "code_action_submenu", .label = "Loading…", .state = .{ .disabled = "" } } }},
    .on_open = .{ .command = "code_action_submenu" },
};

pub const cursor: Menu = .{ .label = "Language", .items = &.{
    .{ .command = .{ .command = "goto_definition" } },
    .{ .command = .{ .command = "goto_declaration" } },
    .{ .command = .{ .command = "references" } },
    .{ .command = .{ .command = "hover" } },
    .{ .command = .{ .command = "rename_symbol" } },
    .{ .submenu = &code_actions },
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
    .{ .submenu = &code_actions },
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
