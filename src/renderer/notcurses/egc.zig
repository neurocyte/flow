const nc = @import("notcurses");

pub fn length(egcs: []const u8, colcount: *c_int, abs_col: usize) usize {
    if (egcs[0] == '\t') {
        colcount.* = @intCast(8 - abs_col % 8);
        return 1;
    }
    return nc.ncegc_len(egcs, colcount) catch ret: {
        colcount.* = 1;
        break :ret 1;
    };
}

pub fn chunk_width(chunk_: []const u8, abs_col_: usize) usize {
    var abs_col = abs_col_;
    var chunk = chunk_;
    var colcount: usize = 0;
    var cols: c_int = 0;
    while (chunk.len > 0) {
        const bytes = length(chunk, &cols, abs_col);
        colcount += @intCast(cols);
        abs_col += @intCast(cols);
        if (chunk.len < bytes) break;
        chunk = chunk[bytes..];
    }
    return colcount;
}

pub const ucs32_to_utf8 = nc.ucs32_to_utf8;
