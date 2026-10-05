const command = @import("command");

const tui = @import("../../tui.zig");
const ed = @import("../../editor.zig");
const jump_labels = @import("../../jump_labels.zig");

pub const Type = @import("get_char.zig").Create(@This());
pub const create = Type.create;

pub const ValueType = struct {
    editor: ?*ed.Editor,
    state: jump_labels.State,
};

pub const show_input = {};

/// Expects the labels installed by `goto_word`.
pub fn start(_: *Type) ValueType {
    const editor = tui.get_active_editor() orelse return .{ .editor = null, .state = .{ .labels = &.{} } };
    return .{ .editor = editor, .state = jump_labels.State.init(editor.get_jump_labels()) };
}

pub fn name(_: *Type) []const u8 {
    return "↷ jump";
}

/// The labels only live while this mode is active.
pub fn deinit(self: *Type) void {
    const editor = active_editor(self) orelse return;
    editor.clear_jump_labels();
}

pub fn process_egc(self: *Type, egc: []const u8) command.Result {
    const editor = active_editor(self) orelse return exit();
    if (egc.len != 1) return exit();
    switch (self.value.state.input(egc[0])) {
        .pending => |first| {
            editor.set_jump_label_prefix(first);
            show_first(self, first);
        },
        .select => |label| {
            editor.jump_to_label(.empty(), label) catch {};
            return exit();
        },
        .cancel => return exit(),
    }
}

fn show_first(self: *Type, first: u8) void {
    const mini_editor = self.mini_editor orelse return;
    mini_editor.buffer.set_text(&.{first}) catch {};
}

fn active_editor(self: *Type) ?*ed.Editor {
    const expected = self.value.editor orelse return null;
    const editor = tui.get_active_editor() orelse return null;
    return if (editor == expected) editor else null;
}

fn exit() command.Result {
    return command.executeName("exit_mini_mode", .empty());
}
