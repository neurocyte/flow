const builtin = @import("builtin");

frame_rate: usize = 120,
theme: []const u8 = "ayu-mirage-bordered",
light_theme: []const u8 = "ayu-light",
input_mode: []const u8 = "flow",
gutter_line_numbers_mode: ?LineNumberMode = null,
gutter_line_numbers_style: DigitStyle = .ascii,
gutter_symbols: bool = true,
enable_terminal_cursor: bool = true,
enable_terminal_color_scheme: bool = false,
enable_modal_dim: bool = true,
highlight_current_line: bool = true,
highlight_current_line_gutter: bool = true,
highlight_columns: []const u16 = &.{ 80, 100, 120 },
highlight_columns_alpha: u8 = 240,
highlight_columns_enabled: bool = false,
whitespace_mode: WhitespaceMode = .indent,
inline_diagnostics: bool = true,
inline_diagnostics_alignment: Alignment = .right,
animation_min_lag: usize = 0, //milliseconds
animation_max_lag: usize = 50, //milliseconds
hover_time_ms: usize = 500, //milliseconds
input_idle_time_ms: usize = 100, //milliseconds
idle_actions: []const IdleAction = &default_actions,
idle_commands: ?[]const []const u8 = null, // a list of simple commands
enable_format_on_save: bool = false,
restore_last_cursor_position: bool = true,
follow_cursor_on_buffer_switch: bool = false, //scroll cursor into view on buffer switch
default_cursor: CursorShape = .default,
modes_can_change_cursor: bool = true,
enable_auto_save: bool = false,
limit_auto_save_file_types: ?[]const []const u8 = null, // null means *all*
enable_prefix_keyhints: bool = true,
enable_auto_find: bool = true,
initial_find_query: InitialFindQuery = .selection,
ignore_filter_stderr: bool = false,

auto_run_time_seconds: usize = 120, //seconds
auto_run_commands: ?[]const []const u8 = &.{"save_session_quiet"}, // a list of simple commands

indent_size: usize = 4,
tab_width: usize = 8,
indent_mode: IndentMode = .auto,

top_bar: []const u8 = "tabs",
bottom_bar: []const u8 = "mode file log selection diagnostics keybind branch linenumber clock spacer",
show_scrollbars: bool = true,
show_fileicons: bool = true,
show_local_diagnostics_in_panel: bool = false,
scrollbar_auto_hide: bool = true,

start_debugger_on_crash: bool = false,

completion_trigger: CompletionTrigger = .automatic,
completion_style: CompletionStyle = .dropdown,
completion_insert_mode: CompletionInsertMode = .insert,

widget_style: WidgetStyle = .compact,
palette_style: WidgetStyle = .bars_top_bottom,
dropdown_style: WidgetStyle = .compact,
panel_style: WidgetStyle = .compact,
home_style: WidgetStyle = .bars_top_bottom,
pane_left_style: WidgetStyle = .bar_right,
pane_right_style: WidgetStyle = .bar_left,
pane_style: PaneStyle = .panel,
hint_window_style: WidgetStyle = .thick_boxed,

centered_view: bool = false,
centered_view_width: usize = 145,
centered_view_min_screen_width: usize = 145,

lsp_output: enum { quiet, verbose } = .quiet,

keybind_mode: KeybindMode = .normal,
dropdown_keybinds: DropdownKeybindMode = .standard,

include_files: []const u8 = "",

const default_actions = [_]IdleAction{.highlight_references};
pub const IdleAction = enum {
    hover,
    highlight_references,
};

pub const DigitStyle = enum {
    ascii,
    digital,
    subscript,
    superscript,
};

pub const LineNumberMode = enum {
    none,
    relative,
    absolute,
};

pub const IndentMode = enum {
    auto,
    spaces,
    tabs,
};

pub const WidgetType = enum {
    none,
    palette,
    panel,
    home,
    pane_left,
    pane_right,
    hint_window,
    dropdown,
};

pub const WidgetStyle = enum {
    bars_top_bottom,
    bars_left_right,
    bar_left,
    bar_right,
    thick_boxed,
    extra_thick_boxed,
    dotted_boxed,
    rounded_boxed,
    double_boxed,
    single_double_top_bottom_boxed,
    single_double_left_right_boxed,
    boxed,
    spacious,
    compact,
};

pub const WhitespaceMode = enum {
    indent,
    leading,
    eol,
    tabs,
    external,
    visible,
    full,
    none,
};

pub const CursorShape = enum {
    default,
    block_blink,
    block,
    underline_blink,
    underline,
    beam_blink,
    beam,
};

pub const PaneStyle = enum {
    panel,
    editor,
};

pub const KeybindMode = enum {
    normal,
    ignore_alt_text_modifiers,
};

pub const DropdownKeybindMode = enum {
    standard,
    noninvasive,
};

pub const InitialFindQuery = enum {
    empty,
    selection,
    last_query,
    selection_or_last_query,
};

pub const CompletionTrigger = enum {
    manual,
    automatic,
};

pub const CompletionStyle = enum {
    palette,
    dropdown,
};

pub const CompletionInsertMode = enum {
    insert,
    replace,
};

pub const Alignment = enum {
    left,
    right,
};
