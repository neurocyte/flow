const command = @import("command");

const tui = @import("../../tui.zig");
const ed = @import("../../editor.zig");
const jump_labels = @import("../../jump_labels.zig");

pub const Type = @import("get_char.zig").Create(@This());
pub const create = Type.create;

pub const ValueType = struct {
    editor: ?*ed.Editor,
    state: jump_labels.State,
    text: [1]u8 = undefined,
};

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
        .pending => |first| show_first(self, first),
        .select => |label| {
            editor.jump_to_label(.empty(), label) catch {};
            return exit();
        },
        .cancel => return exit(),
    }
}

fn show_first(self: *Type, first: u8) void {
    self.value.text[0] = first;
    const mini_mode = tui.mini_mode() orelse return;
    mini_mode.text = self.value.text[0..1];
    mini_mode.cursor = 1;
}

fn active_editor(self: *Type) ?*ed.Editor {
    const expected = self.value.editor orelse return null;
    const editor = tui.get_active_editor() orelse return null;
    return if (editor == expected) editor else null;
}

fn exit() command.Result {
    return command.executeName("exit_mini_mode", .empty());
}
