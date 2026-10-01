const Menu = @import("../Menu.zig");

pub const menu: Menu = .{ .label = "Menu", .items = &.{
    .{ .submenu = &file },
    .{ .submenu = &edit },
    .{ .submenu = &view },
    .{ .submenu = &terminal },
    .{ .submenu = &settings },
    .separator,
    .{ .command = .{ .command = "open_command_palette" } },
    .{ .command = .{ .command = "open_help" } },
    .separator,
    .{ .command = .{ .command = "quit" } },
} };

const file: Menu = .{ .label = "File", .items = &.{
    .{ .command = .{ .command = "create_new_file" } },
    .{ .command = .{ .command = "find_file" } },
    .{ .command = .{ .command = "open_recent" } },
    .{ .command = .{ .command = "open_recent_project" } },
    .separator,
    .{ .command = .{ .command = "save_file" } },
    .{ .command = .{ .command = "save_as" } },
    .{ .command = .{ .command = "save_all" } },
    .separator,
    .{ .command = .{ .command = "close_file" } },
} };

const edit: Menu = .{ .label = "Edit", .items = &.{
    .{ .command = .{ .command = "undo" } },
    .{ .command = .{ .command = "redo" } },
    .separator,
    .{ .command = .{ .command = "cut" } },
    .{ .command = .{ .command = "copy" } },
    .{ .command = .{ .command = "paste" } },
    .{ .command = .{ .command = "select_all" } },
    .separator,
    .{ .command = .{ .command = "find" } },
    .{ .command = .{ .command = "find_in_files" } },
    .{ .command = .{ .command = "goto" } },
} };

const view: Menu = .{ .label = "View", .items = &.{
    .{ .command = .{ .command = "switch_buffers" } },
    .{ .command = .{ .command = "add_split" } },
    .{ .command = .{ .command = "close_split" } },
    .separator,
    .{ .command = .{ .command = "toggle_panel" } },
    .{ .command = .{ .command = "toggle_maximize_panel" } },
    .{ .command = .{ .command = "show_logview" } },
    .separator,
    .{ .command = .{ .command = "toggle_centered_view" } },
    .{ .command = .{ .command = "toggle_whitespace_mode" } },
    .{ .command = .{ .command = "toggle_keybind_hints" } },
} };

const terminal: Menu = .{ .label = "Terminal", .items = &.{
    .{ .command = .{ .command = "terminal_new" } },
    .{ .command = .{ .command = "switch_terminals" } },
    .separator,
    .{ .command = .{ .command = "run_task" } },
    .{ .command = .{ .command = "add_task" } },
} };

const settings: Menu = .{ .label = "Settings", .items = &.{
    .{ .submenu = &theme },
    .{ .command = .{ .command = "open_config" } },
    .{ .command = .{ .command = "open_keybind_config" } },
    .separator,
    .{ .command = .{ .command = "open_version_info" } },
} };

const theme: Menu = .{ .label = "Theme", .items = &.{
    .{ .command = .{ .command = "change_theme" } },
    .separator,
    .{ .command = .{ .command = "theme_next" } },
    .{ .command = .{ .command = "theme_prev" } },
} };
