const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");

pub const Source = enum { push, pull, internal };
pub const SourceType = enum { clipboard, primary_selection };
pub const ContentType = enum { plain_text_utf8 };

source: Source,
source_type: SourceType,
content_type: ContentType = .plain_text_utf8,
content: []const u8,

const Self = @This();

pub fn match(m: tp.message) error{Exit}!?Self {
    var self: Self = undefined;
    if (try m.match(.{ "paste", tp.extract(&self.source), tp.extract(&self.source_type), tp.extract(&self.content_type), tp.extract(&self.content) }))
        return self;
    return null;
}

pub fn write(self: Self, writer: *std.Io.Writer) error{WriteFailed}!void {
    try cbor.writeValue(writer, .{ "paste", self.source, self.source_type, self.content_type, self.content });
}

pub fn send(self: Self, to: tp.pid_ref) error{Exit}!void {
    return to.send(.{ "paste", self.source, self.source_type, self.content_type, self.content });
}
