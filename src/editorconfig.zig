const std = @import("std");
const builtin = @import("builtin");

pub const IndentStyle = enum { space, tab };
pub const EndOfLine = enum { lf, cr, crlf };
pub const IndentSize = union(enum) { tab, size: usize };
const max_file_size = 1 << 20;

pub const Settings = struct {
    indent_style: ?IndentStyle = null,
    indent_size: ?IndentSize = null,
    tab_width: ?usize = null,
    end_of_line: ?EndOfLine = null,
    trim_trailing_whitespace: ?bool = null,
    insert_final_newline: ?bool = null,
};

const Property = enum {
    indent_style,
    indent_size,
    tab_width,
    end_of_line,
    trim_trailing_whitespace,
    insert_final_newline,
    const count = std.meta.tags(Property).len;
};

const ValueList = struct {
    data: [Property.count]?[]const u8 = std.mem.zeroes([Property.count]?[]const u8),

    fn get(self: *const @This(), p: Property) ?[]const u8 {
        return self.data[@backingInt(p)];
    }

    fn set(self: *@This(), p: Property, value: []const u8) void {
        self.data[@backingInt(p)] = value;
    }

    fn clear(self: *@This()) void {
        self.data = std.mem.zeroes([Property.count]?[]const u8);
    }
};

pub fn query(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8) error{OutOfMemory}!?Settings {
    var arena_impl = std.heap.ArenaAllocator.init(allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();

    const path = try resolve_path(io, a, file_path);
    const dirs = (try dir_chain(a, path)) orelse return null;

    var values: ValueList = .{};
    var i = dirs.len;
    while (i > 0) {
        i -= 1;
        const d = dirs[i];
        const config_path = try std.fmt.allocPrint(a, "{s}/.editorconfig", .{d});
        if (read_file(io, a, config_path)) |content|
            try apply_file(a, content, d, path, &values);
    }
    return resolve(&values);
}

pub fn config_paths(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8) error{OutOfMemory}![]const []const u8 {
    const path = try resolve_path(io, allocator, file_path);
    defer allocator.free(path);
    const dirs = (try dir_chain(allocator, path)) orelse return &.{};
    defer allocator.free(dirs);
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer list.deinit(allocator);
    for (dirs) |d| {
        const config_path = try std.fmt.allocPrint(allocator, "{s}/.editorconfig", .{d});
        if (read_file(io, allocator, config_path) != null)
            try list.append(allocator, config_path)
        else
            allocator.free(config_path);
    }
    return list.toOwnedSlice(allocator);
}

fn dir_chain(a: std.mem.Allocator, path: []const u8) error{OutOfMemory}!?[]const []const u8 {
    const dir = std.fs.path.dirname(path) orelse return null;
    var dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer dirs.deinit(a);
    var cur: []const u8 = dir;
    while (cur.len > 0) {
        try dirs.append(a, cur);
        const parent = std.fs.path.dirname(cur) orelse break;
        if (std.mem.eql(u8, parent, cur)) break;
        cur = parent;
    }
    return @as(?[]const []const u8, try dirs.toOwnedSlice(a));
}

fn resolve(values: *const ValueList) ?Settings {
    var v = values.*;
    if (v.get(.indent_style)) |style| {
        if (eq_ignore_ascii_case(style, "tab") and v.get(.indent_size) == null)
            v.set(.indent_size, "tab");
    }
    if (v.get(.indent_size)) |size| {
        if (eq_ignore_ascii_case(size, "tab")) {
            if (v.get(.tab_width)) |w| v.set(.indent_size, w);
        } else if (v.get(.tab_width) == null) {
            v.set(.tab_width, size);
        }
    }

    var s: Settings = .{};
    if (v.get(.indent_style)) |style| {
        if (eq_ignore_ascii_case(style, "unset")) {} else if (eq_ignore_ascii_case(style, "tab"))
            s.indent_style = .tab
        else if (eq_ignore_ascii_case(style, "space"))
            s.indent_style = .space;
    }
    if (v.get(.indent_size)) |size| {
        if (eq_ignore_ascii_case(size, "unset")) {} else if (eq_ignore_ascii_case(size, "tab"))
            s.indent_size = .tab
        else if (parse_int(size)) |n|
            s.indent_size = .{ .size = n };
    }
    if (v.get(.tab_width)) |w| {
        if (eq_ignore_ascii_case(w, "unset")) {} else if (parse_int(w)) |n|
            s.tab_width = n;
    }
    if (v.get(.end_of_line)) |eol| {
        if (eq_ignore_ascii_case(eol, "unset")) {} else if (eq_ignore_ascii_case(eol, "lf"))
            s.end_of_line = .lf
        else if (eq_ignore_ascii_case(eol, "crlf"))
            s.end_of_line = .crlf
        else if (eq_ignore_ascii_case(eol, "cr"))
            s.end_of_line = .cr;
    }
    if (v.get(.trim_trailing_whitespace)) |val| {
        if (eq_ignore_ascii_case(val, "unset")) {} else if (eq_ignore_ascii_case(val, "true"))
            s.trim_trailing_whitespace = true
        else if (eq_ignore_ascii_case(val, "false"))
            s.trim_trailing_whitespace = false;
    }
    if (v.get(.insert_final_newline)) |val| {
        if (eq_ignore_ascii_case(val, "unset")) {} else if (eq_ignore_ascii_case(val, "true"))
            s.insert_final_newline = true
        else if (eq_ignore_ascii_case(val, "false"))
            s.insert_final_newline = false;
    }
    return if (s.indent_style != null or s.indent_size != null or s.tab_width != null or
        s.end_of_line != null or s.trim_trailing_whitespace != null or s.insert_final_newline != null)
        s
    else
        null;
}

pub fn transform(
    allocator: std.mem.Allocator,
    content: []const u8,
    end_of_line: EndOfLine,
    trim_trailing_whitespace: bool,
    insert_final_newline: ?bool,
) !?[]u8 {
    const eol: []const u8 = switch (end_of_line) {
        .lf => "\n",
        .crlf => "\r\n",
        .cr => "\r",
    };
    const has_final = std.mem.endsWith(u8, content, eol);
    if (!trim_trailing_whitespace and (insert_final_newline == null or insert_final_newline.? == has_final)) return null;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < content.len) {
        const nl = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
        var line_end = if (nl < content.len and nl > i and content[nl - 1] == '\r') nl - 1 else nl;
        while (line_end > i and (content[line_end - 1] == ' ' or content[line_end - 1] == '\t'))
            line_end -= 1;
        try out.appendSlice(allocator, content[i..line_end]);
        if (nl < content.len) {
            try out.appendSlice(allocator, eol);
            i = nl + 1;
        } else {
            break;
        }
    }
    if (insert_final_newline) |want_final| {
        const out_has_final = std.mem.endsWith(u8, out.items, eol);
        if (want_final) {
            if (!out_has_final)
                try out.appendSlice(allocator, eol);
        } else {
            if (out_has_final)
                out.shrinkRetainingCapacity(out.items.len - eol.len);
        }
    }
    if (std.mem.eql(u8, out.items, content)) {
        out.deinit(allocator);
        return null;
    }
    const result = try out.toOwnedSlice(allocator);
    return @as(?[]u8, result);
}

fn read_file(io: std.Io, a: std.mem.Allocator, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_file_size)) catch null;
}

fn resolve_path(io: std.Io, a: std.mem.Allocator, file_path: []const u8) error{OutOfMemory}![]const u8 {
    const resolved: []const u8 = if (std.fs.path.isAbsolute(file_path))
        try a.dupe(u8, file_path)
    else blk: {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.Io.Dir.cwd().realPathFile(io, file_path, &path_buf) catch
            break :blk try resolve_from_cwd(io, a, file_path);
        break :blk try a.dupe(u8, path_buf[0..n]);
    };
    if (builtin.os.tag == .windows) {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(a);
        for (resolved) |c|
            try buf.append(a, if (c == '\\') '/' else c);
        a.free(resolved);
        return buf.toOwnedSlice(a);
    }
    return resolved;
}

fn resolve_from_cwd(io: std.Io, a: std.mem.Allocator, file_path: []const u8) error{OutOfMemory}![]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.Io.Dir.cwd().realPath(io, &path_buf) catch return a.dupe(u8, file_path);
    return std.fs.path.resolve(a, &.{ path_buf[0..cwd_len], file_path });
}

fn escape_special(a: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    for (s) |c| {
        switch (c) {
            '?', '[', ']', '\\', '*', '-', '{', '}', ',' => try buf.append(a, '\\'),
            else => {},
        }
        try buf.append(a, c);
    }
    return buf.toOwnedSlice(a);
}

fn build_pattern(a: std.mem.Allocator, dir_escaped: []const u8, section: []const u8) error{OutOfMemory}![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, dir_escaped);
    if (std.mem.indexOfScalar(u8, section, '/') == null) {
        try buf.appendSlice(a, "**/");
    } else if (section[0] != '/') {
        try buf.append(a, '/');
    }
    try buf.appendSlice(a, section);
    return buf.toOwnedSlice(a);
}

fn apply_file(a: std.mem.Allocator, content: []const u8, dir: []const u8, full_path: []const u8, values: *ValueList) error{OutOfMemory}!void {
    const dir_escaped = try escape_special(a, dir);
    var it = std.mem.splitScalar(u8, content, '\n');
    var lineno: usize = 0;
    var section: []const u8 = "";
    while (it.next()) |raw| {
        lineno += 1;
        var line = raw;
        if (lineno == 1 and line.len >= 3 and line[0] == 0xef and line[1] == 0xbb and line[2] == 0xbf)
            line = line[3..];
        var end = line.len;
        if (end > 0 and line[end - 1] == '\r') end -= 1;
        const l = line[0..end];
        const start = l[skip_ws(l)..];
        if (start.len == 0 or start[0] == ';' or start[0] == '#') continue;
        if (start[0] == '[') {
            section = section_name(start);
            continue;
        }
        const sep = find_separator(start) orelse continue;
        const key = trim_end(start[0..sep]);
        const value = parse_value(start[sep + 1 ..]);
        if (key.len == 0) continue;
        if (section.len == 0) {
            if (eq_ignore_ascii_case(key, "root") and eq_ignore_ascii_case(value, "true"))
                values.clear();
            continue;
        }
        const prop = property(key) orelse continue;
        const full = try build_pattern(a, dir_escaped, section);
        if (!glob_match(full, full_path)) continue;
        values.set(prop, if (need_lowercase(prop)) try lower(a, value) else value);
    }
}

fn property(key: []const u8) ?Property {
    inline for (std.meta.tags(Property)) |p| {
        if (eq_ignore_ascii_case(key, @tagName(p))) return p;
    }
    return null;
}

fn need_lowercase(p: Property) bool {
    return switch (p) {
        .indent_style, .indent_size, .tab_width, .end_of_line, .trim_trailing_whitespace, .insert_final_newline => true,
    };
}

fn lower(a: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]const u8 {
    const buf = try a.dupe(u8, s);
    for (buf) |*c| {
        if (c.* >= 'A' and c.* <= 'Z')
            c.* += 32;
    }
    return buf;
}

fn skip_ws(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and is_ws(s[i])) i += 1;
    return i;
}

fn is_ws(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == 0x0b or c == 0x0c;
}

fn trim_end(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and is_ws(s[end - 1])) end -= 1;
    return s[0..end];
}

fn parse_value(v: []const u8) []const u8 {
    const start = skip_ws(v);
    var i = start;
    var was_ws = false;
    while (i < v.len) : (i += 1) {
        if (was_ws and (v[i] == ';' or v[i] == '#')) break;
        was_ws = is_ws(v[i]);
    }
    return trim_end(v[start..i]);
}

fn find_separator(s: []const u8) ?usize {
    var was_ws = false;
    for (s, 0..) |c, i| {
        if (was_ws and (c == ';' or c == '#')) return null;
        if (c == '=' or c == ':') return i;
        was_ws = is_ws(c);
    }
    return null;
}

fn section_name(line: []const u8) []const u8 {
    var last_bracket: usize = 0;
    var was_ws = false;
    for (line[1..], 1..) |c, i| {
        if (was_ws and (c == ';' or c == '#')) break;
        if (c == ']') last_bracket = i;
        was_ws = is_ws(c);
    }
    return if (last_bracket > 0) line[1..last_bracket] else "";
}

fn eq_ignore_ascii_case(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (ascii_lower(x) != ascii_lower(y)) return false;
    return true;
}

fn ascii_lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn parse_int(s: []const u8) ?usize {
    if (s.len == 0) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(usize, s, 10) catch null;
}

fn braces_paired(p: []const u8) bool {
    var left: usize = 0;
    var right: usize = 0;
    var i: usize = 0;
    while (i < p.len) : (i += 1) {
        if (p[i] == '\\' and i + 1 < p.len) {
            i += 1;
            continue;
        }
        switch (p[i]) {
            '{' => left += 1,
            '}' => {
                right += 1;
                if (right > left) return false;
            },
            else => {},
        }
    }
    return left == right;
}

fn glob_match(pattern: []const u8, string: []const u8) bool {
    const braces_ops = braces_paired(pattern);
    return match(pattern, 0, string, 0, braces_ops);
}

fn match(p: []const u8, pi: usize, s: []const u8, si: usize, braces_ops: bool) bool {
    if (pi >= p.len) return si == s.len;
    switch (p[pi]) {
        '\\' => {
            if (pi + 1 >= p.len) {
                if (si >= s.len or s[si] != '\\') return false;
                return match(p, pi + 1, s, si + 1, braces_ops);
            }
            if (si >= s.len or s[si] != p[pi + 1]) return false;
            return match(p, pi + 2, s, si + 1, braces_ops);
        },
        '?' => {
            if (si >= s.len or s[si] == '/') return false;
            return match(p, pi + 1, s, si + 1, braces_ops);
        },
        '*' => {
            if (pi + 1 < p.len and p[pi + 1] == '*')
                return match_dstar(p, pi + 2, s, si, braces_ops);
            return match_star(p, pi + 1, s, si, braces_ops);
        },
        '[' => return match_class(p, pi, s, si, braces_ops),
        '{' => return match_brace(p, pi, s, si, braces_ops),
        '/' => {
            if (pi + 3 < p.len and p[pi + 1] == '*' and p[pi + 2] == '*' and p[pi + 3] == '/') {
                if (si < s.len and s[si] == '/') {
                    if (match(p, pi + 4, s, si + 1, braces_ops)) return true;
                    var j = si + 1;
                    while (j < s.len) : (j += 1)
                        if (s[j] == '/') if (match(p, pi + 4, s, j + 1, braces_ops)) return true;
                }
                return false;
            }
            if (si >= s.len or s[si] != '/') return false;
            return match(p, pi + 1, s, si + 1, braces_ops);
        },
        '}', ',' => {
            if (si >= s.len or s[si] != p[pi]) return false;
            return match(p, pi + 1, s, si + 1, braces_ops);
        },
        else => {
            if (si >= s.len or s[si] != p[pi]) return false;
            return match(p, pi + 1, s, si + 1, braces_ops);
        },
    }
}

fn match_star(p: []const u8, pi: usize, s: []const u8, si: usize, braces_ops: bool) bool {
    var j = si;
    while (true) {
        if (match(p, pi, s, j, braces_ops)) return true;
        if (j >= s.len) return false;
        if (s[j] == '/') return false;
        j += 1;
    }
}

fn match_dstar(p: []const u8, pi: usize, s: []const u8, si: usize, braces_ops: bool) bool {
    var j = si;
    while (true) {
        if (match(p, pi, s, j, braces_ops)) return true;
        if (j >= s.len) return false;
        j += 1;
    }
}

fn class_close(p: []const u8, pi: usize) usize {
    var i = pi + 1;
    while (i < p.len) : (i += 1) {
        if (p[i] == '\\') {
            i += 1;
            continue;
        }
        if (p[i] == ']') return i;
    }
    return p.len;
}

fn match_class(p: []const u8, pi: usize, s: []const u8, si: usize, braces_ops: bool) bool {
    const close = class_close(p, pi);
    var has_slash = false;
    var i = pi + 1;
    while (i < close) {
        if (p[i] == '\\') {
            i += 2;
            continue;
        }
        if (p[i] == '/') {
            has_slash = true;
            break;
        }
        i += 1;
    }
    const advance = if (close < p.len) close + 1 else p.len;
    if (has_slash) {
        const lit = p[pi..advance];
        if (si + lit.len > s.len) return false;
        if (!std.mem.eql(u8, s[si .. si + lit.len], lit)) return false;
        return match(p, advance, s, si + lit.len, braces_ops);
    }
    if (si >= s.len) return false;
    const negate = pi + 1 < p.len and p[pi + 1] == '!';
    const body = p[pi + 1 + @intFromBool(negate) .. close];
    if (!class_member(body, s[si], negate)) return false;
    return match(p, advance, s, si + 1, braces_ops);
}

fn class_member(body: []const u8, c: u8, negate: bool) bool {
    var in_set = false;
    var i: usize = 0;
    var prev: ?u8 = null;
    while (i < body.len) {
        const ch = body[i];
        if (ch == '\\' and i + 1 < body.len) {
            const m = body[i + 1];
            if (i + 3 < body.len and body[i + 2] == '-' and body[i + 3] != ']') {
                if (c >= m and c <= body[i + 3]) in_set = true;
                i += 4;
            } else {
                if (c == m) in_set = true;
                prev = m;
                i += 2;
            }
            continue;
        }
        if (ch == '-' and i + 1 < body.len) {
            const hi_off = if (body[i + 1] == '\\' and i + 2 < body.len) i + 2 else i + 1;
            const hi = body[hi_off];
            if (prev != null and hi != ']') {
                if (c >= prev.? and c <= hi) in_set = true;
                i = hi_off + 1;
                prev = null;
                continue;
            }
        }
        if (c == ch) in_set = true;
        prev = ch;
        i += 1;
    }
    return if (negate) !in_set else in_set;
}

fn find_group_close(p: []const u8, pi: usize) ?usize {
    var depth: usize = 1;
    var i = pi + 1;
    while (i < p.len) : (i += 1) {
        if (p[i] == '\\') {
            i += 1;
            continue;
        }
        switch (p[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn next_top_comma(content: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var i = start;
    while (i < content.len) : (i += 1) {
        if (content[i] == '\\') {
            i += 1;
            continue;
        }
        switch (content[i]) {
            '{' => depth += 1,
            '}' => {
                if (depth > 0)
                    depth -= 1;
            },
            ',' => {
                if (depth == 0)
                    return i;
            },
            else => {},
        }
    }
    return null;
}

fn match_brace(p: []const u8, pi: usize, s: []const u8, si: usize, braces_ops: bool) bool {
    if (!braces_ops) {
        if (si >= s.len or s[si] != '{') return false;
        return match(p, pi + 1, s, si + 1, braces_ops);
    }
    const close = find_group_close(p, pi) orelse {
        if (si >= s.len or s[si] != '{') return false;
        return match(p, pi + 1, s, si + 1, braces_ops);
    };
    const content = p[pi + 1 .. close];
    if (next_top_comma(content, 0) != null) {
        var alt_start: usize = 0;
        while (true) {
            const c_end = next_top_comma(content, alt_start) orelse content.len;
            const alt = content[alt_start..c_end];
            var j = si;
            while (j <= s.len) : (j += 1)
                if (match(alt, 0, s[si..j], 0, braces_ops))
                    if (match(p, close + 1, s, j, braces_ops)) return true;
            if (c_end >= content.len) break;
            alt_start = c_end + 1;
        }
        return false;
    } else if (numeric_range(content)) |range| {
        return match_range(p, close + 1, s, si, range, braces_ops);
    } else {
        if (si >= s.len or s[si] != '{') return false;
        var j = si + 1;
        while (j < s.len) : (j += 1) {
            if (s[j] != '}') continue;
            if (match(content, 0, s[si + 1 .. j], 0, braces_ops))
                if (match(p, close + 1, s, j + 1, braces_ops)) return true;
        }
        return false;
    }
}

const Range = struct { lo: i64, hi: i64 };

fn numeric_range(content: []const u8) ?Range {
    var i: usize = 0;
    const lo_sign: i64 = sign_value(content, &i);
    const lo_start = i;
    while (i < content.len and std.ascii.isDigit(content[i])) i += 1;
    if (i == lo_start) return null;
    const lo = (std.fmt.parseInt(i64, content[lo_start..i], 10) catch return null) * lo_sign;
    if (i + 2 > content.len or content[i] != '.' or content[i + 1] != '.') return null;
    i += 2;
    const hi_sign: i64 = sign_value(content, &i);
    const hi_start = i;
    while (i < content.len and std.ascii.isDigit(content[i])) i += 1;
    if (i == hi_start) return null;
    const hi = (std.fmt.parseInt(i64, content[hi_start..i], 10) catch return null) * hi_sign;
    if (i != content.len) return null;
    return .{ .lo = lo, .hi = hi };
}

fn sign_value(content: []const u8, i: *usize) i64 {
    if (i.* < content.len and content[i.*] == '-') {
        i.* += 1;
        return -1;
    }
    if (i.* < content.len and content[i.*] == '+') {
        i.* += 1;
        return 1;
    }
    return 1;
}

fn match_range(p: []const u8, next_pi: usize, s: []const u8, si: usize, range: Range, braces_ops: bool) bool {
    var sign: i64 = 1;
    var j = si;
    if (j < s.len and (s[j] == '+' or s[j] == '-')) {
        if (s[j] == '-') sign = -1;
        j += 1;
    }
    const dstart = j;
    while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
    if (j == dstart) return false;
    var k = j;
    while (true) {
        if (match(p, next_pi, s, k, braces_ops)) {
            if (s[dstart] == '0') return false;
            const v = (std.fmt.parseInt(i64, s[dstart..k], 10) catch return false) * sign;
            return v >= range.lo and v <= range.hi;
        }
        if (k == dstart + 1) return false;
        k -= 1;
    }
}

pub fn matches(dir: []const u8, section: []const u8, file_path: []const u8) bool {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    const de = escape_special(a, dir) catch return false;
    const full = build_pattern(a, de, section) catch return false;
    return glob_match(full, file_path);
}

fn match_section(dir: []const u8, section: []const u8, string: []const u8) !bool {
    return matches(dir, section, string);
}

test "glob star" {
    try expect_match_section("/proj", "a*e.c", "/proj/ace.c", true);
    try expect_match_section("/proj", "a*e.c", "/proj/ae.c", true);
    try expect_match_section("/proj", "a*e.c", "/proj/abcde.c", true);
    try expect_match_section("/proj", "a*e.c", "/proj/sub/ace.c", true);
    try expect_match_section("/proj", "a*e.c", "/proj/a/e.c", false);
    try expect_match_section("/proj", "Bar/*", "/proj/Bar/foo.txt", true);
    try expect_match_section("/proj", "Bar/*", "/proj/Bar/x/foo.txt", false);
    try expect_match_section("/proj", "*", "/proj/.editorconfig", true);
}

test "glob question" {
    try expect_match_section("/proj", "som?.c", "/proj/some.c", true);
    try expect_match_section("/proj", "som?.c", "/proj/som.c", false);
    try expect_match_section("/proj", "som?.c", "/proj/som/.c", false);
}

test "glob brackets" {
    try expect_match_section("/proj", "[ab].a", "/proj/a.a", true);
    try expect_match_section("/proj", "[ab].a", "/proj/c.a", false);
    try expect_match_section("/proj", "[!ab].b", "/proj/c.b", true);
    try expect_match_section("/proj", "[!ab].b", "/proj/a.b", false);
    try expect_match_section("/proj", "[d-g].c", "/proj/f.c", true);
    try expect_match_section("/proj", "[d-g].c", "/proj/h.c", false);
    try expect_match_section("/proj", "[!d-g].d", "/proj/h.d", true);
    try expect_match_section("/proj", "[!d-g].d", "/proj/f.d", false);
    try expect_match_section("/proj", "[\\]ab].g", "/proj/].g", true);
    try expect_match_section("/proj", "[ab]].g", "/proj/b].g", true);
    try expect_match_section("/proj", "[-ab].f", "/proj/-.f", true);
    try expect_match_section("/proj", "ab[e/]cd.i", "/proj/ab[e/]cd.i", true);
    try expect_match_section("/proj", "ab[/c", "/proj/ab[/c", true);
}

test "glob braces" {
    try expect_match_section("/proj", "*.{py,js,html}", "/proj/test.py", true);
    try expect_match_section("/proj", "*.{py,js,html}", "/proj/test.js", true);
    try expect_match_section("/proj", "*.{py,js,html}", "/proj/test.pyc", false);
    try expect_match_section("/proj", "{single}.b", "/proj/{single}.b", true);
    try expect_match_section("/proj", "{}.c", "/proj/{}.c", true);
    try expect_match_section("/proj", "a{b,c,}.d", "/proj/a.d", true);
    try expect_match_section("/proj", "a{b,c,}.d", "/proj/ab.d", true);
    try expect_match_section("/proj", "a{b,c,}.d", "/proj/ac.d", true);
    try expect_match_section("/proj", "a{b,c,}.d", "/proj/a,.d", false);
    try expect_match_section("/proj", "{.f", "/proj/{.f", true);
    try expect_match_section("/proj", "{word,{also},this}.g", "/proj/word.g", true);
    try expect_match_section("/proj", "{word,{also},this}.g", "/proj/{also}.g", true);
    try expect_match_section("/proj", "{word,{also},this}.g", "/proj/this.g", true);
    try expect_match_section("/proj", "{{a,b},c}.k", "/proj/a.k", true);
    try expect_match_section("/proj", "{{a,b},c}.k", "/proj/c.k", true);
    try expect_match_section("/proj", "{a,{b,c}}.l", "/proj/b.l", true);
    try expect_match_section("/proj", "{a\\,b,cd}.txt", "/proj/a,b.txt", true);
    try expect_match_section("/proj", "{e,\\},f}.txt", "/proj/}.txt", true);
    try expect_match_section("/proj", "{some,a{*c,b}[ef]}.j", "/proj/some.j", true);
    try expect_match_section("/proj", "{some,a{*c,b}[ef]}.j", "/proj/abe.j", true);
    try expect_match_section("/proj", "{some,a{*c,b}[ef]}.j", "/proj/abg.j", false);
    try expect_match_section("/proj", "{aardvark..antelope}", "/proj/{aardvark..antelope}", true);
    try expect_match_section("/proj", "{{,b,c{d}.i", "/proj/{{,b,c{d}.i", true);
    try expect_match_section("/proj", "{},b}.h", "/proj/{},b}.h", true);
}

test "glob numeric range" {
    try expect_match_section("/proj", "{3..120}", "/proj/3", true);
    try expect_match_section("/proj", "{3..120}", "/proj/15", true);
    try expect_match_section("/proj", "{3..120}", "/proj/120", true);
    try expect_match_section("/proj", "{3..120}", "/proj/+3", true);
    try expect_match_section("/proj", "{3..120}", "/proj/1", false);
    try expect_match_section("/proj", "{3..120}", "/proj/121", false);
    try expect_match_section("/proj", "{3..120}", "/proj/060", false);
    try expect_match_section("/proj", "{3..120}", "/proj/5a", false);
}

test "glob star star" {
    try expect_match_section("/proj", "a**z.c", "/proj/a/z.c", true);
    try expect_match_section("/proj", "a**z.c", "/proj/a/mn/z.c", true);
    try expect_match_section("/proj", "a**z.c", "/proj/amnz.c", true);
    try expect_match_section("/proj", "b/**z.c", "/proj/b/z.c", true);
    try expect_match_section("/proj", "b/**z.c", "/proj/bmnz.c", false);
    try expect_match_section("/proj", "d/**/z.c", "/proj/d/z.c", true);
    try expect_match_section("/proj", "d/**/z.c", "/proj/d/mn/z.c", true);
    try expect_match_section("/proj", "中文.txt", "/proj/中文.txt", true);
}

test "glob case sensitive" {
    try expect_match_section("/proj", "*.C", "/proj/x.c", false);
    try expect_match_section("/proj", "*.C", "/proj/x.C", true);
}

test "query end to end" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const dir = buf[0..len];

    try tmp.dir.createDir(io, "sub", .default_dir);

    try tmp.dir.writeFile(io, .{ .sub_path = ".editorconfig", .data =
        \\root = true
        \\
        \\[*.c]
        \\indent_style = space
        \\indent_size = 4
        \\end_of_line = lf
        \\trim_trailing_whitespace = false
        \\
        \\[*.py]
        \\indent_style = tab
        \\tab_width = 2
        \\insert_final_newline = true
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/.editorconfig", .data =
        \\[*]
        \\tab_width = 3
        \\trim_trailing_whitespace = true
        \\
    });

    const a = std.testing.allocator;
    const p1 = try std.fmt.allocPrint(a, "{s}/test.c", .{dir});
    defer a.free(p1);
    const p2 = try std.fmt.allocPrint(a, "{s}/sub/test.c", .{dir});
    defer a.free(p2);
    const p3 = try std.fmt.allocPrint(a, "{s}/sub/test.py", .{dir});
    defer a.free(p3);
    const p4 = try std.fmt.allocPrint(a, "{s}/README", .{dir});
    defer a.free(p4);

    const s1 = (try query(io, a, p1)).?;
    try std.testing.expectEqual(@as(?IndentStyle, .space), s1.indent_style);
    try std.testing.expectEqual(@as(?usize, 4), s1.tab_width);
    try std.testing.expectEqual(@as(?EndOfLine, .lf), s1.end_of_line);
    try std.testing.expectEqual(@as(?bool, false), s1.trim_trailing_whitespace);
    try std.testing.expectEqual(@as(?bool, null), s1.insert_final_newline);

    const s2 = (try query(io, a, p2)).?;
    try std.testing.expectEqual(@as(?IndentStyle, .space), s2.indent_style);
    try std.testing.expectEqual(@as(?usize, 3), s2.tab_width);
    try std.testing.expectEqual(@as(?bool, true), s2.trim_trailing_whitespace);

    const s3 = (try query(io, a, p3)).?;
    try std.testing.expectEqual(@as(?IndentStyle, .tab), s3.indent_style);
    try std.testing.expectEqual(@as(?usize, 3), s3.tab_width);
    try std.testing.expectEqual(@as(?bool, true), s3.insert_final_newline);

    try std.testing.expect((try query(io, a, p4)) == null);
}

test "unset gated by section match" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const dir = buf[0..len];

    try tmp.dir.writeFile(io, .{ .sub_path = ".editorconfig", .data =
        \\root = true
        \\
        \\[*.c]
        \\indent_style = space
        \\indent_size = 4
        \\
        \\[*.py]
        \\indent_style = tab
        \\tab_width = 2
        \\indent_size = unset
        \\
    });

    const a = std.testing.allocator;
    const p1 = try std.fmt.allocPrint(a, "{s}/x.c", .{dir});
    defer a.free(p1);
    const s1 = (try query(io, a, p1)).?;
    try std.testing.expectEqual(@as(?IndentStyle, .space), s1.indent_style);
    try std.testing.expectEqual(@as(?usize, 4), s1.tab_width);

    const p2 = try std.fmt.allocPrint(a, "{s}/x.py", .{dir});
    defer a.free(p2);
    const s2 = (try query(io, a, p2)).?;
    try std.testing.expectEqual(@as(?IndentStyle, .tab), s2.indent_style);
    try std.testing.expectEqual(@as(?usize, 2), s2.tab_width);
    try std.testing.expectEqual(@as(?IndentSize, null), s2.indent_size);

    const p3 = try std.fmt.allocPrint(a, "{s}/x.txt", .{dir});
    defer a.free(p3);
    try std.testing.expect((try query(io, a, p3)) == null);
}

test "transform" {
    const a = std.testing.allocator;
    try expect_transform(a, "a  \nb\t\n c  ", .lf, true, false, "a\nb\n c");
    try expect_transform(a, "a\nb\n", .lf, true, true, null);
    try expect_transform(a, "a\nb", .lf, true, true, "a\nb\n");
    try expect_transform(a, "a\nb\n", .lf, false, false, "a\nb");
    try expect_transform(a, "a  \r\nb\t\r\n", .crlf, true, false, "a\r\nb");
    try expect_transform(a, "a\nb\n", .lf, false, true, null);
    try expect_transform(a, "a \n", .lf, true, false, "a");
    try expect_transform(a, "", .lf, true, true, "\n");
    try expect_transform(a, "a\nb\n", .lf, true, null, null);
    try expect_transform(a, "a\nb", .lf, true, null, null);
    try expect_transform(a, "a  \nb\t\n", .lf, false, null, null);
    try expect_transform(a, "a\nb\n", .lf, true, false, "a\nb");
    try expect_transform(a, "a\nb", .lf, true, true, "a\nb\n");
}

fn expect_match_section(dir: []const u8, section: []const u8, string: []const u8, want: bool) !void {
    try std.testing.expectEqual(want, try match_section(dir, section, string));
}

fn expect_transform(a: std.mem.Allocator, content: []const u8, eol: EndOfLine, trim: bool, final_nl: ?bool, expected: ?[]const u8) !void {
    const out = try transform(a, content, eol, trim, final_nl);
    defer if (out) |o| a.free(o);
    if (expected) |want| {
        try std.testing.expectEqualStrings(want, out.?);
    } else {
        try std.testing.expect(out == null);
    }
}
