const std = @import("std");
const tp = @import("thespian");
const root = @import("soft_root").root;

pub const Dest = union(enum) {
    file: FileDest,
    dir: DirDest,
};

pub const FileDest = struct {
    path: []const u8,
    line: ?usize = null,
    column: ?usize = null,
    end_column: ?usize = null,
    exists: bool = false,
    offset: ?usize = null,
};

pub const DirDest = struct {
    path: []const u8,
};

pub const FileSrc = struct {
    path: []const u8,
    line: usize,
    column: usize,
};

pub fn parse(link: []const u8) error{InvalidFileLink}!Dest {
    if (link.len == 0) return error.InvalidFileLink;

    if (std.mem.lastIndexOfScalar(u8, link, '(')) |pos| blk: {
        for (link[pos + 1 ..]) |c| switch (c) {
            '0'...'9', ',', ')', ':', ' ' => continue,
            else => break :blk,
        };
        return parse_bracket_link(link);
    }

    var it = std.mem.splitScalar(u8, link, ':');
    var dest: Dest = if (root.is_directory(link))
        .{ .dir = .{ .path = link } }
    else
        .{ .file = .{ .path = it.first() } };
    switch (dest) {
        .file => |*file| {
            if (it.next()) |line_| if (line_.len > 0 and line_[0] == 'b') {
                file.offset = std.fmt.parseInt(usize, line_[1..], 10) catch blk: {
                    file.path = link;
                    break :blk null;
                };
            } else if (line_.len > 5 and std.mem.eql(u8, "line ", line_[0..5])) {
                file.line = std.fmt.parseInt(usize, line_[5..], 10) catch blk: {
                    file.path = link;
                    break :blk null;
                };
            } else {
                file.line = std.fmt.parseInt(usize, line_, 10) catch blk: {
                    file.path = link;
                    break :blk null;
                };
            };
            if (file.line) |_| if (it.next()) |col_| {
                file.column = std.fmt.parseInt(usize, col_, 10) catch null;
            };
            if (file.column) |_| if (it.next()) |col_| {
                file.end_column = std.fmt.parseInt(usize, col_, 10) catch null;
            };
            file.exists = root.is_file(file.path);
        },
        .dir => {},
    }
    return dest;
}

pub fn parse_bracket_link(link: []const u8) error{InvalidFileLink}!Dest {
    var it_ = std.mem.splitScalar(u8, link, '(');
    var dest: Dest = if (root.is_directory(link))
        .{ .dir = .{ .path = link } }
    else
        .{ .file = .{ .path = it_.first() } };

    const rest = it_.next() orelse "";
    var it = std.mem.splitAny(u8, rest, ",):");

    switch (dest) {
        .file => |*file| {
            if (it.next()) |line_|
                file.line = std.fmt.parseInt(usize, line_, 10) catch blk: {
                    file.path = link;
                    break :blk null;
                };
            if (file.line) |_| if (it.next()) |col_| {
                file.column = std.fmt.parseInt(usize, col_, 10) catch null;
            };
            if (file.column) |_| if (it.next()) |col_| {
                file.end_column = std.fmt.parseInt(usize, col_, 10) catch null;
            };
            file.exists = root.is_file(file.path);
        },
        .dir => {},
    }
    return dest;
}

pub const Range = struct {
    start: usize,
    end: usize,
};

fn is_link_separator(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn is_link_leading_trim(c: u8) bool {
    return c == '"' or c == '\'' or c == '`' or c == '(' or c == '[' or c == '<';
}

fn is_link_trailing_trim(c: u8) bool {
    return c == '"' or c == '\'' or c == '`' or c == ']' or c == '>' or
        c == ',' or c == '.' or c == ';' or c == ':';
}

/// Bracket style: path(digits/commas/colons/spaces). Token must end with ')'.
fn is_bracket_link(token: []const u8) bool {
    if (token.len == 0 or token[token.len - 1] != ')') return false;
    const paren_pos = std.mem.lastIndexOfScalar(u8, token, '(') orelse return false;
    if (paren_pos == 0) return false;
    var has_digit = false;
    for (token[paren_pos + 1 ..]) |c| switch (c) {
        '0'...'9' => has_digit = true,
        ',', ')', ':', ' ' => {},
        else => return false,
    };
    return has_digit;
}

/// Colon style: path:N[:col[:end_col]] or path:bN.
/// Returns the byte length of the longest valid colon-link prefix, or 0.
/// Each numeric segment is consumed only up to its trailing digit; a
/// non-digit suffix terminates that segment and stops further parsing.
/// The path part must not contain quote characters.
fn find_colon_link_end(token: []const u8) usize {
    if (token.len == 0) return 0;
    const colon1 = std.mem.indexOfScalar(u8, token, ':') orelse return 0;
    if (colon1 == 0) return 0;
    for (token[0..colon1]) |c| switch (c) {
        '"', '\'', '`' => return 0,
        else => {},
    };
    // First numeric segment (optionally 'b'-prefixed for byte offset).
    var pos: usize = colon1 + 1;
    if (pos < token.len and token[pos] == 'b') pos += 1;
    const n1_start = pos;
    while (pos < token.len and token[pos] >= '0' and token[pos] <= '9') pos += 1;
    if (pos == n1_start) return 0;
    var end = pos;
    // Optional column — only if the next char is exactly ':'.
    if (pos >= token.len or token[pos] != ':') return end;
    pos += 1;
    const n2_start = pos;
    while (pos < token.len and token[pos] >= '0' and token[pos] <= '9') pos += 1;
    if (pos == n2_start) return end;
    end = pos;
    // Optional end_column.
    if (pos >= token.len or token[pos] != ':') return end;
    pos += 1;
    const n3_start = pos;
    while (pos < token.len and token[pos] >= '0' and token[pos] <= '9') pos += 1;
    if (pos == n3_start) return end;
    return pos;
}

fn looks_like_path(token: []const u8) bool {
    if (token.len == 0) return false;
    // A token made entirely of dots and separators is not a path (e.g. "...", "//", "../").
    for (token) |c| switch (c) {
        '.', '/', '\\' => {},
        else => break,
    } else return false;
    // Tokens embedding quote characters are not plain paths; they are likely code.
    for (token) |c| switch (c) {
        '"', '\'', '`' => return false,
        else => {},
    };
    if (token[0] == '.' or token[0] == '/' or token[0] == '~' or token[0] == '\\') return true;
    for (token) |c| switch (c) {
        '.', '/', '\\' => return true,
        else => {},
    };
    return false;
}

fn try_parse_token(line: []const u8, raw_start: usize, raw_end: usize) ?Range {
    var start = raw_start;
    var end = raw_end;
    while (start < end and is_link_leading_trim(line[start])) start += 1;
    // Strip trailing punctuation but keep ')' for now as it may be part of bracket notation.
    while (end > start and is_link_trailing_trim(line[end - 1])) end -= 1;
    if (start >= end) return null;
    // Bracket style keeps the closing ')'.
    if (is_bracket_link(line[start..end])) return .{ .start = start, .end = end };
    // Colon style: strip trailing ')' and re-apply trailing trim (handles e.g. `"path")`).
    var colon_end = end;
    while (colon_end > start and line[colon_end - 1] == ')') colon_end -= 1;
    while (colon_end > start and is_link_trailing_trim(line[colon_end - 1])) colon_end -= 1;
    const cl = find_colon_link_end(line[start..colon_end]);
    if (cl > 0) return .{ .start = start, .end = start + cl };
    // Plain path: no location info so accept if it plausibly looks like a path.
    if (looks_like_path(line[start..colon_end])) return .{ .start = start, .end = colon_end };
    return null;
}

/// Advance past one token, treating `\<sep>` as a non-breaking escaped space.
fn scan_token_end(line: []const u8, start: usize) usize {
    var pos = start;
    while (pos < line.len) {
        if (line[pos] == '\\' and pos + 1 < line.len and is_link_separator(line[pos + 1])) {
            pos += 2;
        } else if (is_link_separator(line[pos])) {
            break;
        } else {
            pos += 1;
        }
    }
    return pos;
}

/// Search within a whitespace token for a valid link inside a quote-delimited sub-token.
fn find_in_quoted(line: []const u8, tok_start: usize, tok_end: usize) ?Range {
    var pos = tok_start;
    while (pos < tok_end) {
        const c = line[pos];
        if (c == '"' or c == '\'' or c == '`') {
            const q = c;
            pos += 1;
            const sub_start = pos;
            while (pos < tok_end and line[pos] != q) pos += 1;
            if (pos > sub_start) {
                if (try_parse_token(line, sub_start, pos)) |range| return range;
            }
            if (pos < tok_end) pos += 1;
        } else {
            pos += 1;
        }
    }
    return null;
}

/// Scan `line` for the first valid file link. Returns its byte range, or null.
pub fn find_in_line(line: []const u8) ?Range {
    var pos: usize = 0;
    while (pos < line.len) {
        while (pos < line.len and is_link_separator(line[pos])) pos += 1;
        if (pos >= line.len) break;
        const tok_start = pos;
        pos = scan_token_end(line, pos);
        if (try_parse_token(line, tok_start, pos)) |range| return range;
        if (find_in_quoted(line, tok_start, pos)) |range| return range;
    }
    return null;
}

/// Find a valid file link in `line` whose range contains `point` (byte offset).
/// Returns the byte range of the link, or null.
pub fn find_at_point(line: []const u8, point: usize) ?Range {
    var pos: usize = 0;
    while (pos < line.len) {
        while (pos < line.len and is_link_separator(line[pos])) pos += 1;
        if (pos >= line.len) break;
        const tok_start = pos;
        pos = scan_token_end(line, pos);
        if (point < tok_start or point >= pos) continue;
        if (try_parse_token(line, tok_start, pos)) |range| return range;
        return find_in_quoted(line, tok_start, pos);
    }
    return null;
}

pub fn navigate(to: tp.pid_ref, link: *const Dest) anyerror!void {
    switch (link.*) {
        .file => |file| {
            if (file.offset) |offset| {
                return to.send(.{ "cmd", "navigate", .{ .file = file.path, .offset = offset } });
            }
            if (file.line) |l| {
                if (file.column) |col| {
                    try to.send(.{ "cmd", "navigate", .{ .file = file.path, .line = l, .column = col } });
                    if (file.end_column) |end|
                        try to.send(.{ "A", l, col - 1, end - 1 });
                    return;
                }
                return to.send(.{ "cmd", "navigate", .{ .file = file.path, .line = l } });
            }
            return to.send(.{ "cmd", "navigate", .{ .file = file.path } });
        },
        else => {},
    }
}
