pub fn age_short(timestamp: i64) struct {
    timestamp: i64,
    pub fn format(self: @This(), writer: anytype) std.Io.Writer.Error!void {
        const age = std.time.timestamp() -| self.timestamp;
        return if (age < 60)
            writer.writeAll("now")
        else if (age < 3600)
            writer.print("{d}m", .{@divTrunc(age, 60)})
        else if (age < 86400)
            writer.print("{d}h", .{@divTrunc(age, 3600)})
        else if (age < 2592000)
            writer.print("{d}D", .{@divTrunc(age, 86400)})
        else if (age < 31536000)
            writer.print("{d}M", .{@divTrunc(age, 2592000)})
        else
            writer.print("{d}Y", .{@divTrunc(age, 31536000)});
    }
} {
    return .{ .timestamp = timestamp };
}

pub fn age_long(timestamp: i64) struct {
    timestamp: i64,
    pub fn format(self: @This(), writer: anytype) std.Io.Writer.Error!void {
        const age = std.time.timestamp() -| self.timestamp;
        return if (age < 60)
            writer.writeAll("just now")
        else if (age < 3600)
            writer.print("{d} minutes ago", .{@divTrunc(age, 60)})
        else if (age < 86400)
            writer.print("{d} hours ago", .{@divTrunc(age, 3600)})
        else if (age < 2592000)
            writer.print("{d} days ago", .{@divTrunc(age, 86400)})
        else if (age < 31536000)
            writer.print("{d} months ago", .{@divTrunc(age, 2592000)})
        else
            writer.print("{d} years ago", .{@divTrunc(age, 31536000)});
    }
} {
    return .{ .timestamp = timestamp };
}

const std = @import("std");
