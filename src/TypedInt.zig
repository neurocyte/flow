pub fn Tagged(T: type, tag: []const u8) type {
    return enum(T) {
        _,

        pub const TAG = tag;

        pub fn cborEncode(self: @This(), writer: *Writer) Writer.Error!void {
            const value: T = @intFromEnum(self);
            try cbor.writeValue(writer, .{ TAG, value });
        }

        pub fn cborExtract(self: *@This(), iter: *[]const u8) cbor.Error!bool {
            var value: T = 0;
            if (try cbor.matchValue(iter, .{ TAG, cbor.extract(&value) })) {
                self.* = @enumFromInt(value);
                return true;
            }
            return false;
        }

        pub fn format(self: @This(), writer: anytype) !void {
            return writer.print("{s}:{d}", .{ TAG, @intFromEnum(self) });
        }
    };
}

const Writer = @import("std").Io.Writer;
const cbor = @import("cbor");
