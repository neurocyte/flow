const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const cbor = @import("cbor");

frame_rate: usize = 60,
theme: []const u8 = "ayu-mirage-bordered",
light_theme: []const u8 = "ayu-light",
input_mode: []const u8 = "flow",
gutter_line_numbers_mode: ?LineNumberMode = null,
gutter_line_numbers_style: DigitStyle = .ascii,
gutter_symbols: bool = true,
gutter_diffs: bool = true,
gutter_width_mode: GutterWidthMode = .local,
gutter_width_minimum: usize = 4,
gutter_width_maximum: usize = 8,
enable_terminal_cursor: bool = true,
enable_terminal_color_scheme: bool = true,
terminal_TERM: []const u8 = "xterm-256color",
terminal_scrollback_mb: u16 = 8,
terminal_persist_scrollback: bool = true,
terminal_reflow_on_resize: bool = true,
terminal_input_delay_ms: u16 = 3,
terminal_on_exit: TerminalOnExit = .hold_on_error,
terminal_focus_after_send: bool = true,
terminal_newline_after_send: bool = false,
terminal_send_on_smart_insert_line_before: bool = true,
terminal_read_wt_profiles: bool = true,
task_runner: TaskRunner = .default,
task_terminal_on_exit: TerminalOnExit = .hold,
enable_sgr_pixel_mode_support: bool = true,
enable_osc52_primary_selection: bool = true,
enable_modal_dim: bool = true,
highlight_current_line: bool = true,
highlight_current_line_gutter: bool = true,
highlight_columns: []const u16 = &.{ 80, 100, 120 },
highlight_columns_alpha: u8 = 240,
highlight_columns_enabled: bool = false,
whitespace_mode: WhitespaceMode = .indent,
inline_diagnostics: InlineDiagnostics = .all,
inline_diagnostics_alignment: Alignment = .right,
inline_vcs_blame: bool = false,
inline_vcs_blame_alignment: Alignment = .right,
inline_vcs_blame_age: AgeFormat = .short,
animation_min_lag: usize = 0, //milliseconds
animation_max_lag: usize = 50, //milliseconds
hover_time_ms: usize = 150, //milliseconds
hover_info_mode: HoverInfoMode = .box,
input_idle_time_ms: usize = 100, //milliseconds
idle_actions: []const IdleAction = &default_actions,
code_action_indicator_mode: CodeActionIndicatorMode = CodeActionIndicatorMode.default,
idle_commands: ?[]const []const u8 = &.{"markdown_preview_sync"}, // a list of simple commands
on_disk_change_commands: ?[]const []const u8 = &.{"markdown_preview_sync_disk"}, // a list of simple commands
enable_format_on_save: bool = false,
restore_last_cursor_position: bool = true,
restore_last_cursor_position_exclusions: []const []const u8 = &.{"COMMIT_EDITMSG"},
follow_cursor_on_buffer_switch: bool = false, //scroll cursor into view on buffer switch
default_cursor: CursorShape = .default,
modes_can_change_cursor: bool = true,
enable_auto_save: bool = false,
auto_save_mode: AutoSaveMode = .on_focus_change,
limit_auto_save_file_types: ?[]const []const u8 = null, // null means *all*
enable_prefix_keyhints: bool = true,
enable_minimode_keyhints: bool = true,
enable_overlay_keyhints: bool = true,
enable_panel_keyhints: bool = false,
keyhints_details: KeyhintsDetails = .auto,
enable_auto_find: bool = true,
find_mode: FindMode = .auto,
find_in_files_mode: FindMode = .auto,
find_in_files_filter: FindInFilesFilter = .default,
initial_find_query: InitialFindQuery = .selection,
jump_label_alphabet: []const u8 = "abcdefghijklmnopqrstuvwxyz",
ignore_filter_stderr: bool = false,

auto_run_time_seconds: usize = 120, //seconds
auto_run_commands: ?[]const []const u8 = &.{"save_session_quiet"}, // a list of simple commands

indent_size: usize = 4,
tab_width: usize = 8,
indent_mode: IndentMode = .auto,
reflow_width: usize = 76,
background_syntax: BackgroundSyntax = .auto,
background_syntax_threshold: usize = 20000, // lines
syntax_injection_depth: u8 = 6,

top_bar: []const u8 = "tabs",
bottom_bar: []const u8 = "mode file log selection diagnostics keybind branch lsp linenumber clock spacer",
show_bottom_bar_grip: bool = true,
show_scrollbars: bool = true,
show_fileicons: bool = true,
show_local_diagnostics_in_panel: bool = false,
auto_open_panel_for_diagnostics: bool = true,
panel_height_ratio: f32 = 1.0 / 3.0,
scrollbar_auto_hide: bool = true,
scrollbar_overlay_hide_delay: usize = 1000, //milliseconds
scroll_step_vertical: usize = 3,
scroll_step_horizontal: usize = 5,
scroll_cursor_min_border_distance: usize = 5,

mouse_click_jump: MouseModifier = if (macos_gui) .super else .ctrl,
mouse_click_alternate: MouseModifier = .alt,
mouse_hover: MouseHover = if (macos_gui) .super else .ctrl,
mouse_scroll_fast: MouseModifier = .alt,
mouse_scroll_alternate: MouseModifier = .shift,

start_debugger_on_crash: bool = false,

completion_trigger: CompletionTrigger = .automatic,
completion_style: CompletionStyle = .dropdown,
completion_insert_mode: CompletionInsertMode = .insert,
completion_info_mode: CompletionInfoMode = .box,

widget_style: WidgetStyle = .compact,
palette_style: WidgetStyle = .bars_top_bottom,
dropdown_style: WidgetStyle = .compact,
menu_style: WidgetStyle = .compact,
dialog_style: WidgetStyle = .thick_boxed,
panel_style: WidgetStyle = .compact,
panel_centered_view: bool = false,
panel_centered_view_width: usize = 110,
home_style: WidgetStyle = .bars_top_bottom,
pane_left_style: WidgetStyle = .bar_right,
pane_right_style: WidgetStyle = .bar_left,
pane_style: PaneStyle = .panel,
hint_window_style: WidgetStyle = .thick_boxed,
info_box_style: WidgetStyle = .bar_left_spacious,
info_box_width_limit: usize = 80,
info_box_height_limit: usize = 20,
info_code_overflow: CodeOverflow = .wrap,
markdown_preview_file_links: bool = false,

palette_placement: PalettePlacement = .top_center,
vcs_status_placement: PalettePlacement = .top_right,
palette_opacity: f32 = 0.75,

show_menu: ShowMenu = .left,

centered_view: bool = false,
centered_view_width: usize = 145,
centered_view_min_screen_width: usize = 145,

lsp_output: enum { quiet, verbose } = .quiet,

keybind_mode: KeybindMode = .normal,
dropdown_keybinds: DropdownKeybindMode = .standard,
dropdown_limit: usize = 12,

retain_symlinks: bool = true,
follow_directory_symlinks: bool = false,
log_ignored_links: bool = false,
maximum_symlink_depth: usize = 3,
enable_file_watcher: bool = true,
enable_vcs_watcher: bool = true,
vcs_commit_command: []const u8 = "git commit",
vcs_commit_all_command: []const u8 = "git commit --all",
vcs_amend_command: []const u8 = "git commit --amend",
vcs_fetch_command: []const u8 = "git fetch",
vcs_push_command: []const u8 = "git push",

desktop_theme_file: []const u8 = &.{},

url_handler: []const []const u8 = switch (builtin.os.tag) {
    .windows => &.{ "rundll32", "url.dll,FileProtocolHandler", "{{url}}" },
    .macos => &.{ "open", "{{url}}" },
    else => &.{ "xdg-open", "{{url}}" },
},

non_indexed_projects: []const []const u8 = switch (builtin.os.tag) {
    .windows => &.{
        "{{env:SystemDrive}}",       "{{env:SystemRoot}}",  "{{env:ProgramFiles}}",
        "{{env:ProgramFiles(x86)}}", "{{env:ProgramData}}", "{{env:USERPROFILE}}",
        "{{env:TEMP}}",              "{{env:APPDATA}}",     "{{env:LOCALAPPDATA}}",
    },
    .macos => &.{
        "{{env:HOME}}", "/",      "/Applications", "/Library",
        "/System",      "/Users", "/Volumes",      "/bin",
        "/dev",         "/etc",   "/home",         "/private",
        "/sbin",        "/tmp",   "/usr",          "/var",
    },
    else => &.{
        "{{env:HOME}}", "/",     "/bin",   "/boot",  "/dev",
        "/home",        "/lib",  "/lib64", "/media", "/proc",
        "/run",         "/sbin", "/sys",   "/usr",   "/var",
    },
},
watch_non_indexed_projects: bool = false,

include_files: []const u8 = "",

const macos_gui = build_options.gui and builtin.os.tag == .macos;

pub const MouseModifier = enum { none, shift, alt, ctrl, super };
pub const MouseHover = enum { none, shift, alt, ctrl, super, always };

const default_actions = [_]IdleAction{ .highlight_references, .code_actions };
pub const IdleAction = enum {
    hover,
    highlight_references,
    code_actions,
};

pub const CodeActionIndicatorMode = enum {
    any,
    quickfix_on_line,
    none,

    pub const default = .quickfix_on_line;
};

pub const DigitStyle = enum {
    ascii,
    digital,
    subscript,
    superscript,
};

pub const LineNumberMode = enum {
    only_current,
    multiples_of_five,
    multiples_of_ten,
    absolute,
    relative,
    none,
};

pub const GutterWidthMode = enum {
    local,
    global,
};

pub const IndentMode = enum {
    auto,
    spaces,
    tabs,
};

pub const BackgroundSyntax = enum {
    auto,
    always,
    never,
};

pub const WidgetType = enum {
    none,
    palette,
    panel,
    home,
    pane_left,
    pane_right,
    hint_window,
    info_box,
    dropdown,
    menu,
    dialog,
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
    bar_left_spacious,
    bar_right_spacious,
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

pub const KeyhintsDetails = enum {
    auto,
    shown,
    hidden,
};

pub const AutoSaveMode = enum {
    on_input_idle,
    on_focus_change,
    on_document_change,
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
    every_keystroke,
};

pub const CompletionStyle = enum {
    palette,
    dropdown,
};

pub const CompletionInsertMode = enum {
    insert,
    replace,
};

pub const CompletionInfoMode = enum {
    none,
    box,
    panel,
};

pub const InlineDiagnostics = enum {
    none,
    undercurl,
    indicator,
    text,
    all,

    pub fn show_undercurl(self: @This()) bool {
        return self != .none;
    }

    pub fn show_indicator(self: @This()) bool {
        return self == .indicator or self == .all;
    }

    pub fn show_text(self: @This()) bool {
        return self == .text or self == .all;
    }

    pub fn cborExtract(self: *@This(), iter: *[]const u8, _: std.mem.Allocator) cbor.Error!bool {
        var enabled: bool = undefined;
        if (try cbor.matchValue(iter, cbor.extract(&enabled))) {
            self.* = if (enabled) .all else .none;
            return true;
        }
        return cbor.matchEnum(@This(), iter, self);
    }
};

pub const HoverInfoMode = enum {
    box,
    panel,
};

pub const CodeOverflow = enum {
    wrap,
    clip,
};

pub const Alignment = enum {
    left,
    right,
};

pub const AgeFormat = enum {
    short,
    long,
};

pub const TerminalOnExit = enum {
    hold_on_error,
    close,
    hold,
};

pub const PalettePlacement = enum {
    top_center,
    top_left,
    top_right,
    bottom_right,
    center,
};

pub const ShowMenu = enum {
    bar,
    left,
    right,
    none,
};

pub const TaskRunner = enum {
    buffer,
    terminal,

    pub const default = .terminal;
};

pub const FindInFilesFilter = enum {
    default,
    hidden,
    no_ignore,
    all,
};

pub const FindMode = enum {
    auto,
    exact,
    case_folded,
    regex_auto,
    regex,
    regex_case_folded,
};
