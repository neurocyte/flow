const std = @import("std");
const Theme = @import("theme");

name: []const u8,
description: []const u8,
type: Theme.Type,

editor: Theme.Style,
editor_cursor: Theme.Style,
editor_cursor_primary: Theme.Style,
editor_cursor_secondary: Theme.Style,
editor_line_highlight: Theme.Style,
editor_error: Theme.Style,
editor_warning: Theme.Style,
editor_information: Theme.Style,
editor_hint: Theme.Style,
editor_match: Theme.Style,
editor_selection: Theme.Style,
editor_whitespace: Theme.Style,
editor_gutter: Theme.Style,
editor_gutter_active: Theme.Style,
editor_gutter_modified: Theme.Style,
editor_gutter_added: Theme.Style,
editor_gutter_deleted: Theme.Style,
editor_widget: Theme.Style,
editor_widget_border: Theme.Style,
statusbar: Theme.Style,
statusbar_hover: Theme.Style,
scrollbar: Theme.Style,
scrollbar_hover: Theme.Style,
scrollbar_active: Theme.Style,
sidebar: Theme.Style,
panel: Theme.Style,
input: Theme.Style,
input_border: Theme.Style,
input_placeholder: Theme.Style,
input_option_active: Theme.Style,
input_option_hover: Theme.Style,
tab_active: Theme.Style,
tab_inactive: Theme.Style,
tab_selected: Theme.Style,
tab_unfocused_active: Theme.Style,
tab_unfocused_inactive: Theme.Style,

ansi_black: Theme.Color,
ansi_red: Theme.Color,
ansi_green: Theme.Color,
ansi_yellow: Theme.Color,
ansi_blue: Theme.Color,
ansi_magenta: Theme.Color,
ansi_cyan: Theme.Color,
ansi_white: Theme.Color,
ansi_bright_black: Theme.Color,
ansi_bright_red: Theme.Color,
ansi_bright_green: Theme.Color,
ansi_bright_yellow: Theme.Color,
ansi_bright_blue: Theme.Color,
ansi_bright_magenta: Theme.Color,
ansi_bright_cyan: Theme.Color,
ansi_bright_white: Theme.Color,

ansi_palette: [16][3]u8,

scope_type: Theme.ScopeType,

tokens: Tokens,

pub const Token = struct { scope: []const u8, style: Theme.Style };
pub const Tokens = []const Token;

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    allocator.free(self.name);
    allocator.free(self.description);
    for (self.tokens) |*tok| allocator.free(tok.scope);
    allocator.free(self.tokens);
}

pub fn toTheme(self: @This(), allocator: std.mem.Allocator, scope_list: *std.ArrayList([]const u8)) !Theme {
    return .{
        .name = try allocator.dupe(u8, self.name),
        .description = try allocator.dupe(u8, self.description),
        .type = self.type,

        .editor = self.editor,
        .editor_cursor = self.editor_cursor,
        .editor_cursor_primary = self.editor_cursor_primary,
        .editor_cursor_secondary = self.editor_cursor_secondary,
        .editor_line_highlight = self.editor_line_highlight,
        .editor_error = self.editor_error,
        .editor_warning = self.editor_warning,
        .editor_information = self.editor_information,
        .editor_hint = self.editor_hint,
        .editor_match = self.editor_match,
        .editor_selection = self.editor_selection,
        .editor_whitespace = self.editor_whitespace,
        .editor_gutter = self.editor_gutter,
        .editor_gutter_active = self.editor_gutter_active,
        .editor_gutter_modified = self.editor_gutter_modified,
        .editor_gutter_added = self.editor_gutter_added,
        .editor_gutter_deleted = self.editor_gutter_deleted,
        .editor_widget = self.editor_widget,
        .editor_widget_border = self.editor_widget_border,
        .statusbar = self.statusbar,
        .statusbar_hover = self.statusbar_hover,
        .scrollbar = self.scrollbar,
        .scrollbar_hover = self.scrollbar_hover,
        .scrollbar_active = self.scrollbar_active,
        .sidebar = self.sidebar,
        .panel = self.panel,
        .input = self.input,
        .input_border = self.input_border,
        .input_placeholder = self.input_placeholder,
        .input_option_active = self.input_option_active,
        .input_option_hover = self.input_option_hover,
        .tab_active = self.tab_active,
        .tab_inactive = self.tab_inactive,
        .tab_selected = self.tab_selected,
        .tab_unfocused_active = self.tab_unfocused_active,
        .tab_unfocused_inactive = self.tab_unfocused_inactive,

        .ansi_black = self.ansi_black,
        .ansi_red = self.ansi_red,
        .ansi_green = self.ansi_green,
        .ansi_yellow = self.ansi_yellow,
        .ansi_blue = self.ansi_blue,
        .ansi_magenta = self.ansi_magenta,
        .ansi_cyan = self.ansi_cyan,
        .ansi_white = self.ansi_white,
        .ansi_bright_black = self.ansi_bright_black,
        .ansi_bright_red = self.ansi_bright_red,
        .ansi_bright_green = self.ansi_bright_green,
        .ansi_bright_yellow = self.ansi_bright_yellow,
        .ansi_bright_blue = self.ansi_bright_blue,
        .ansi_bright_magenta = self.ansi_bright_magenta,
        .ansi_bright_cyan = self.ansi_bright_cyan,
        .ansi_bright_white = self.ansi_bright_white,

        .ansi_palette = self.ansi_palette,

        .scope_type = self.scope_type,

        .tokens = try toTokens(allocator, self.tokens, scope_list),
    };
}

fn toTokens(allocator: std.mem.Allocator, customTokens: Tokens, scope_list: *std.ArrayList([]const u8)) !Theme.Tokens {
    const tokens = try allocator.alloc(Theme.Token, customTokens.len);
    errdefer allocator.free(tokens);
    for (customTokens, tokens) |from, *to_| {
        to_.* = .{
            .id = blk: for (scope_list.items, 0..) |item, idx| {
                if (std.mem.eql(u8, item, from.scope)) break :blk idx;
            } else new: {
                const scope = try allocator.dupe(u8, from.scope);
                errdefer allocator.free(scope);
                try scope_list.append(allocator, scope);
                break :new scope_list.items.len - 1;
            },
            .style = from.style,
        };
    }
    return tokens;
}

pub fn fromTheme(allocator: std.mem.Allocator, theme: Theme, scopes: [][]const u8) !@This() {
    return .{
        .name = try allocator.dupe(u8, theme.name),
        .description = try allocator.dupe(u8, theme.description),
        .type = theme.type,

        .editor = theme.editor,
        .editor_cursor = theme.editor_cursor,
        .editor_cursor_primary = theme.editor_cursor_primary,
        .editor_cursor_secondary = theme.editor_cursor_secondary,
        .editor_line_highlight = theme.editor_line_highlight,
        .editor_error = theme.editor_error,
        .editor_warning = theme.editor_warning,
        .editor_information = theme.editor_information,
        .editor_hint = theme.editor_hint,
        .editor_match = theme.editor_match,
        .editor_selection = theme.editor_selection,
        .editor_whitespace = theme.editor_whitespace,
        .editor_gutter = theme.editor_gutter,
        .editor_gutter_active = theme.editor_gutter_active,
        .editor_gutter_modified = theme.editor_gutter_modified,
        .editor_gutter_added = theme.editor_gutter_added,
        .editor_gutter_deleted = theme.editor_gutter_deleted,
        .editor_widget = theme.editor_widget,
        .editor_widget_border = theme.editor_widget_border,
        .statusbar = theme.statusbar,
        .statusbar_hover = theme.statusbar_hover,
        .scrollbar = theme.scrollbar,
        .scrollbar_hover = theme.scrollbar_hover,
        .scrollbar_active = theme.scrollbar_active,
        .sidebar = theme.sidebar,
        .panel = theme.panel,
        .input = theme.input,
        .input_border = theme.input_border,
        .input_placeholder = theme.input_placeholder,
        .input_option_active = theme.input_option_active,
        .input_option_hover = theme.input_option_hover,
        .tab_active = theme.tab_active,
        .tab_inactive = theme.tab_inactive,
        .tab_selected = theme.tab_selected,
        .tab_unfocused_active = theme.tab_unfocused_active,
        .tab_unfocused_inactive = theme.tab_unfocused_inactive,

        .ansi_black = theme.ansi_black,
        .ansi_red = theme.ansi_red,
        .ansi_green = theme.ansi_green,
        .ansi_yellow = theme.ansi_yellow,
        .ansi_blue = theme.ansi_blue,
        .ansi_magenta = theme.ansi_magenta,
        .ansi_cyan = theme.ansi_cyan,
        .ansi_white = theme.ansi_white,
        .ansi_bright_black = theme.ansi_bright_black,
        .ansi_bright_red = theme.ansi_bright_red,
        .ansi_bright_green = theme.ansi_bright_green,
        .ansi_bright_yellow = theme.ansi_bright_yellow,
        .ansi_bright_blue = theme.ansi_bright_blue,
        .ansi_bright_magenta = theme.ansi_bright_magenta,
        .ansi_bright_cyan = theme.ansi_bright_cyan,
        .ansi_bright_white = theme.ansi_bright_white,

        .ansi_palette = theme.ansi_palette,

        .scope_type = theme.scope_type,

        .tokens = try fromTokens(allocator, theme.tokens, scopes),
    };
}

fn fromTokens(allocator: std.mem.Allocator, tokens: Theme.Tokens, scopes: [][]const u8) !Tokens {
    const customTokens = try allocator.alloc(Token, tokens.len);
    errdefer allocator.free(customTokens);
    for (tokens, customTokens) |from, *to_| {
        to_.* = .{
            .scope = scopes[from.id],
            .style = from.style,
        };
    }
    return customTokens;
}
