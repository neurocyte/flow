const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.Usage;
    const cwd = std.Io.Dir.cwd();
    const input = try cwd.readFileAlloc(init.io, args[1], init.gpa, .unlimited);
    defer init.gpa.free(input);
    const output = try init.gpa.alloc(u8, input.len);
    defer init.gpa.free(output);
    var len: usize = 0;
    for (input, 0..) |c, i| {
        if (c == '\r' and i + 1 < input.len and input[i + 1] == '\n') continue;
        output[len] = c;
        len += 1;
    }
    try cwd.writeFile(init.io, .{ .sub_path = args[2], .data = output[0..len] });
}
