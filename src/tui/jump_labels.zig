const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("Buffer");
const Cursor = Buffer.Cursor;

pub const Label = struct {
    pos: Cursor,
    text: [2]u8,
};

/// `index` must be smaller than `alphabet.len * alphabet.len` and `alphabet` not empty.
pub fn label_text(alphabet: []const u8, index: usize) [2]u8 {
    return .{ alphabet[index / alphabet.len], alphabet[index % alphabet.len] };
}

pub fn sanitize_alphabet(allocator: Allocator, alphabet: []const u8) error{OutOfMemory}![]u8 {
    const result = try allocator.alloc(u8, alphabet.len);
    var len: usize = 0;
    for (alphabet) |c| {
        if (!std.ascii.isPrint(c) or c == ' ') continue; // a space would be an invisible label
        if (std.mem.findScalar(u8, result[0..len], c) != null) continue;
        result[len] = c;
        len += 1;
    }
    return allocator.realloc(result, len);
}

pub const State = struct {
    labels: []const Label,
    first: ?u8 = null,

    pub const Action = union(enum) {
        pending: u8, // the matched first character
        select: Label,
        cancel,
    };

    pub fn init(labels: []const Label) State {
        return .{ .labels = labels };
    }

    pub fn input(self: *State, c: u8) Action {
        if (self.first) |first| {
            const label = self.find_label(first, c) orelse return .cancel;
            return .{ .select = label };
        }
        for (self.labels) |label| if (label.text[0] == c) {
            self.first = c;
            return .{ .pending = c };
        };
        return .cancel;
    }

    fn find_label(self: *const State, first: u8, c: u8) ?Label {
        for (self.labels) |label|
            if (label.text[0] == first and label.text[1] == c) return label;
        return null;
    }
};
