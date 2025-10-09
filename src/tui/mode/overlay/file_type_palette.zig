const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const syntax = @import("syntax");
const file_type_config = @import("file_type_config");

const Widget = @import("../../Widget.zig");
const tui = @import("../../tui.zig");

pub fn Variant(comptime command: []const u8, comptime label_: []const u8, allow_previous: bool) type {
    return struct {
        pub const Type = @import("palette.zig").Create(@This());

        pub const label = label_;
        pub const name = " file type";
        pub const description = "file type";
        pub const icon = "  ";

        pub const Entry = struct {
            label: []const u8,
            name: []const u8,
            icon: []const u8,
            color: u24,
        };

        pub const Match = struct {
            name: []const u8,
            score: i32,
            matches: []const usize,
        };

        var previous_file_type: ?[]const u8 = null;

        pub fn load_entries(palette: *Type) !usize {
            var longest_hint: usize = 0;
            var idx: usize = 0;
            previous_file_type = blk: {
                if (tui.get_active_editor()) |editor|
                    if (editor.file_type) |editor_file_type|
                        break :blk editor_file_type.name;
                break :blk null;
            };

            for (file_type_config.get_all_names()) |file_type_name| {
                const file_type = try file_type_config.get(file_type_name) orelse unreachable;
                idx += 1;
                (try palette.entries.addOne(palette.allocator)).* = .{
                    .label = file_type.description orelse file_type_config.default.description,
                    .name = file_type.name,
                    .icon = file_type.icon orelse file_type_config.default.icon,
                    .color = file_type.color orelse file_type_config.default.color,
                };
                if (previous_file_type) |previous_name| if (std.mem.eql(u8, file_type.name, previous_name)) {
                    palette.initial_selected = idx;
                };
                longest_hint = @max(longest_hint, file_type.name.len);
            }
            return longest_hint;
        }

        pub fn add_menu_entry(palette: *Type, entry: *Entry, matches: ?[]const usize) !void {
            var value: std.Io.Writer.Allocating = .init(palette.allocator);
            defer value.deinit();
            const writer = &value.writer;
            try cbor.writeValue(writer, entry.label);
            try cbor.writeValue(writer, entry.icon);
            try cbor.writeValue(writer, entry.color);
            try cbor.writeValue(writer, entry.name);
            try cbor.writeValue(writer, matches orelse &[_]usize{});
            try palette.menu.add_item_with_handler(value.written(), select);
            palette.items += 1;
        }

        pub fn on_render_menu(_: *Type, button: *Type.ButtonType, theme: *const Widget.Theme, selected: bool) bool {
            const style_base = theme.editor_widget;
            const style_label = if (button.active) theme.editor_cursor else if (button.hover or selected) theme.editor_selection else theme.editor_widget;
            const style_hint = if (tui.find_scope_style(theme, "entity.name")) |sty| sty.style else style_label;
            button.plane.set_base_style(style_base);
            button.plane.erase();
            button.plane.home();
            button.plane.set_style(style_label);
            if (button.active or button.hover or selected) {
                button.plane.fill(" ");
                button.plane.home();
            }

            button.plane.set_style(style_hint);
            tui.render_pointer(&button.plane, selected);

            var iter = button.opts.label;
            var description_: []const u8 = undefined;
            var icon_: []const u8 = undefined;
            var color: u24 = undefined;
            if (!(cbor.matchString(&iter, &description_) catch false)) @panic("invalid file_type description");
            if (!(cbor.matchString(&iter, &icon_) catch false)) @panic("invalid file_type icon");
            if (!(cbor.matchInt(u24, &iter, &color) catch false)) @panic("invalid file_type color");

            const icon_width = tui.render_file_icon(&button.plane, icon_, color);

            button.plane.set_style(style_label);
            _ = button.plane.print("{s} ", .{description_}) catch {};

            var name_: []const u8 = undefined;
            if (!(cbor.matchString(&iter, &name_) catch false))
                name_ = "";
            button.plane.set_style(style_hint);
            _ = button.plane.print_aligned_right(0, "{s} ", .{name_}) catch {};

            var index: usize = 0;
            var len = cbor.decodeArrayHeader(&iter) catch return false;
            while (len > 0) : (len -= 1) {
                if (cbor.matchValue(&iter, cbor.extract(&index)) catch break) {
                    tui.render_match_cell(&button.plane, 0, index + 2 + icon_width, theme) catch break;
                } else break;
            }
            return false;
        }

        fn select(menu: **Type.MenuType, button: *Type.ButtonType, _: Type.Cursor) void {
            var description_: []const u8 = undefined;
            var icon_: []const u8 = undefined;
            var color: u24 = undefined;
            var name_: []const u8 = undefined;
            var iter = button.opts.label;
            if (!(cbor.matchString(&iter, &description_) catch false)) return;
            if (!(cbor.matchString(&iter, &icon_) catch false)) return;
            if (!(cbor.matchInt(u24, &iter, &color) catch false)) return;
            if (!(cbor.matchString(&iter, &name_) catch false)) return;
            if (!allow_previous) if (previous_file_type) |prev| if (std.mem.eql(u8, prev, name_))
                return;
            tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err("file_type_palette", e);
            tp.self_pid().send(.{ "cmd", command, .{name_} }) catch |e| menu.*.opts.ctx.logger.err("file_type_palette", e);
        }
    };
}
