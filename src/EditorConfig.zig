const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const root = @import("soft_root").root;
const builtin = @import("builtin");

const log = std.log.scoped(.editorconfig);

const module_name = @typeName(@This());

const SpawnError = error{ OutOfMemory, ThespianSpawnFailed };

const ClientOp = enum { add, remove };

pub fn spawn(file_store: tp.pid_ref) SpawnError!tp.pid {
    return Process.create(file_store);
}

const IndentStyle = enum { space, tab };
const EndOfLine = enum { lf, cr, crlf };
const max_file_size = 1 << 20;
const whitespace = " \t\r\x0b\x0c";

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

const Values = struct {
    indent_style: ?IndentStyle = null,
    indent_size: ?usize = null,
    tab_width: ?usize = null,
    end_of_line: ?EndOfLine = null,
    trim_trailing_whitespace: ?bool = null,
    insert_final_newline: ?bool = null,
};

/// The `.editorconfig` paths that apply, nearest first.
fn chain_paths(a: std.mem.Allocator, file_path: []const u8) error{OutOfMemory}![]const []const u8 {
    const dirs = (try dir_chain(a, file_path)) orelse return &.{};
    defer a.free(dirs);
    const paths = try a.alloc([]const u8, dirs.len);
    var n: usize = 0;
    errdefer {
        for (paths[0..n]) |path| a.free(path);
        a.free(paths);
    }
    for (dirs) |dir| {
        paths[n] = try std.fs.path.join(a, &.{ dir, file_name });
        n += 1;
    }
    return paths;
}

fn resolve_chain(a: std.mem.Allocator, file_path: []const u8, contents: []const ?[]const u8) error{OutOfMemory}!?Values {
    const path = try normalize(a, file_path);
    const dirs = (try dir_chain(a, path)) orelse return null;
    var values: ValueList = .{};
    var i = @min(dirs.len, contents.len);
    while (i > 0) {
        i -= 1;
        if (contents[i]) |content| try apply_file(a, content, dirs[i], path, &values);
    }
    return resolve(&values);
}

const file_name = ".editorconfig";

fn declares_root(content: []const u8) bool {
    var it = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (it.next()) |raw| {
        const line = content_line(raw, first);
        first = false;
        if (line.len == 0) continue;
        if (line[0] == '[') return false;
        const sep = find_separator(line) orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, line[0..sep], whitespace), "root") and std.ascii.eqlIgnoreCase(parse_value(line[sep + 1 ..]), "true"))
            return true;
    }
    return false;
}

fn watch_count(config_paths: []const []const u8, contents: []const ?[]const u8, project_dir: []const u8) usize {
    for (contents, 0..) |content_, i| if (content_) |content| if (declares_root(content)) return i + 1;
    var n: usize = 0;
    for (config_paths) |config_path| {
        const dir = std.fs.path.dirname(config_path) orelse break;
        if (!is_within(dir, project_dir)) break;
        n += 1;
    }
    return @max(n, @min(config_paths.len, 1));
}

fn is_within(dir: []const u8, project_dir: []const u8) bool {
    const base = std.mem.trimEnd(u8, project_dir, &.{std.fs.path.sep});
    if (base.len == 0) return false;
    if (!std.mem.startsWith(u8, dir, base)) return false;
    return dir.len == base.len or dir[base.len] == std.fs.path.sep;
}

fn normalize(a: std.mem.Allocator, path: []const u8) error{OutOfMemory}![]const u8 {
    if (builtin.os.tag != .windows) return path;
    const result = try a.dupe(u8, path);
    std.mem.replaceScalar(u8, result, '\\', '/');
    return result;
}

fn dir_chain(a: std.mem.Allocator, path: []const u8) error{OutOfMemory}!?[]const []const u8 {
    const dir = std.fs.path.dirname(path) orelse return null;
    var dirs: std.ArrayList([]const u8) = .empty;
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

fn resolve(values: *const ValueList) ?Values {
    var v = values.*;
    if (v.get(.indent_style)) |style| {
        if (std.mem.eql(u8, style, "tab") and v.get(.indent_size) == null)
            v.set(.indent_size, "tab");
    }
    if (v.get(.indent_size)) |size| {
        if (std.mem.eql(u8, size, "tab")) {
            if (v.get(.tab_width)) |w| v.set(.indent_size, w);
        } else if (v.get(.tab_width) == null) {
            v.set(.tab_width, size);
        }
    }
    const result: Values = .{
        .indent_style = enum_value(IndentStyle, v.get(.indent_style)),
        .indent_size = width_value(v.get(.indent_size)),
        .tab_width = width_value(v.get(.tab_width)),
        .end_of_line = enum_value(EndOfLine, v.get(.end_of_line)),
        .trim_trailing_whitespace = bool_value(v.get(.trim_trailing_whitespace)),
        .insert_final_newline = bool_value(v.get(.insert_final_newline)),
    };
    return if (std.meta.eql(result, Values{})) null else result;
}

fn enum_value(comptime T: type, value: ?[]const u8) ?T {
    return std.meta.stringToEnum(T, value orelse return null);
}

fn bool_value(value: ?[]const u8) ?bool {
    return (enum_value(enum { true, false }, value) orelse return null) == .true;
}

fn width_value(value: ?[]const u8) ?usize {
    return parse_width(value orelse return null);
}

fn read_file(io: std.Io, a: std.mem.Allocator, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_file_size)) catch null;
}

fn escape_special(a: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
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
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, std.mem.trimEnd(u8, dir_escaped, "/"));
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
    var first = true;
    var section: []const u8 = "";
    while (it.next()) |raw| {
        const line = content_line(raw, first);
        first = false;
        if (line.len == 0) continue;
        if (line[0] == '[') {
            section = section_name(line);
            continue;
        }
        const sep = find_separator(line) orelse continue;
        const key = std.mem.trimEnd(u8, line[0..sep], whitespace);
        const value = parse_value(line[sep + 1 ..]);
        if (key.len == 0) continue;
        if (section.len == 0) {
            if (std.ascii.eqlIgnoreCase(key, "root") and std.ascii.eqlIgnoreCase(value, "true"))
                values.clear();
            continue;
        }
        const prop = property(key) orelse continue;
        const full = try build_pattern(a, dir_escaped, section);
        if (!glob_match(full, full_path)) continue;
        values.set(prop, try std.ascii.allocLowerString(a, value));
    }
}

fn property(key: []const u8) ?Property {
    inline for (std.meta.tags(Property)) |p| {
        if (std.ascii.eqlIgnoreCase(key, @tagName(p))) return p;
    }
    return null;
}

fn content_line(raw: []const u8, first: bool) []const u8 {
    const line = std.mem.trim(u8, if (first and std.mem.startsWith(u8, raw, "\xef\xbb\xbf")) raw[3..] else raw, whitespace);
    return if (line.len > 0 and (line[0] == ';' or line[0] == '#')) "" else line;
}

fn is_ws(c: u8) bool {
    return std.mem.indexOfScalar(u8, whitespace, c) != null;
}

fn parse_value(raw: []const u8) []const u8 {
    const v = std.mem.trimStart(u8, raw, whitespace);
    var was_ws = false;
    const end = for (v, 0..) |c, i| {
        if (was_ws and (c == ';' or c == '#')) break i;
        was_ws = is_ws(c);
    } else v.len;
    return std.mem.trimEnd(u8, v[0..end], whitespace);
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

fn parse_width(s: []const u8) ?usize {
    if (s.len == 0) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    const n = std.fmt.parseInt(usize, s, 10) catch return null;
    return if (n == 0) null else n;
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
            if (s[dstart] == '0' and k - dstart > 1) return false;
            const v = (std.fmt.parseInt(i64, s[dstart..k], 10) catch return false) * sign;
            return v >= range.lo and v <= range.hi;
        }
        if (k == dstart + 1) return false;
        k -= 1;
    }
}

const Process = struct {
    allocator: std.mem.Allocator,
    receiver: Receiver,
    parent: tp.pid,
    file_store: tp.pid,
    clients: std.AutoHashMapUnmanaged(tp.piid, void) = .empty,
    files: std.StringHashMapUnmanaged(File) = .empty,
    configs: std.StringHashMapUnmanaged(Config) = .empty,

    const Receiver = tp.Receiver(*@This());

    const File = struct {
        count: usize = 0,
        map: ?cbor.Raw = null,
        project_dir: []const u8 = "",
        watched: usize = 0,
    };

    const Config = struct {
        refs: usize = 0,
        watches: usize = 0,
        content: ?[]const u8 = null,
    };

    fn create(file_store: tp.pid_ref) SpawnError!tp.pid {
        const allocator = std.heap.c_allocator;
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .receiver = .init(receive, dtor, self),
            .parent = tp.self_pid().clone(),
            .file_store = file_store.clone(),
        };
        return tp.spawn_link(allocator, self, @This().start, module_name);
    }

    fn dtor(self: *@This()) void {
        var files = self.files.iterator();
        while (files.next()) |p| {
            if (p.value_ptr.map) |map| self.allocator.free(map.bytes);
            self.allocator.free(p.value_ptr.project_dir);
            self.allocator.free(p.key_ptr.*);
        }
        self.files.deinit(self.allocator);
        var configs = self.configs.iterator();
        while (configs.next()) |p| {
            if (p.value_ptr.content) |content| self.allocator.free(content);
            self.allocator.free(p.key_ptr.*);
        }
        self.configs.deinit(self.allocator);
        self.clients.deinit(self.allocator);
        self.file_store.deinit();
        self.parent.deinit();
        self.allocator.destroy(self);
    }

    fn start(self: *@This()) tp.result {
        _ = tp.set_trap(true);
        tp.receive(&self.receiver);
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive_safe(from, m) catch |e| switch (e) {
            error.ExitNormal => tp.exit_normal(),
            else => err("receive", e),
        };
    }

    fn receive_safe(self: *@This(), from: tp.pid_ref, m: tp.message) (error{ ExitNormal, OutOfMemory } || cbor.Error)!void {
        var path: []const u8 = undefined;
        var from_path: []const u8 = undefined;
        var client: tp.piid = undefined;
        var op: ClientOp = undefined;
        var project_dir: []const u8 = undefined;

        if (try cbor.match(m.buf, .{ tp.extract(&client), .{ "file_open", tp.extract(&path) }, tp.extract(&project_dir) })) {
            try self.file_open(path, project_dir);
        } else if (try cbor.match(m.buf, .{ tp.extract(&client), .{ "file_close", tp.extract(&path) } })) {
            self.file_close(path);
        } else if (try cbor.match(m.buf, .{ "FS", "change", tp.extract(&path), tp.more })) {
            try self.config_changed(path);
        } else if (try cbor.match(m.buf, .{ "FS", "rename", tp.extract(&from_path), tp.extract(&path), tp.more })) {
            try self.config_changed(from_path);
            try self.config_changed(path);
        } else if (try cbor.match(m.buf, .{ "FS", tp.more })) {
            return;
        } else if (try cbor.match(m.buf, .{ tp.extract(&client), .{ "editorconfig_client", tp.extract(&op) } })) {
            switch (op) {
                .add => try self.add_client(client),
                .remove => self.remove_client(client),
            }
        } else if (try cbor.match(m.buf, .{"shutdown"})) {
            return error.ExitNormal;
        } else if (try cbor.match(m.buf, .{ "exit", tp.more })) {
            return self.handle_exit(from);
        } else {
            err("receive", tp.unexpected(m));
        }
    }

    fn handle_exit(self: *@This(), from: tp.pid_ref) error{ExitNormal}!void {
        const piid = from.instance_id();
        if (self.clients.contains(piid)) return self.remove_client(piid);
        if (self.parent.instance_id() == piid or self.file_store.instance_id() == piid)
            return error.ExitNormal;
    }

    fn active(self: *const @This()) bool {
        return self.clients.count() > 0;
    }

    fn file_open(self: *@This(), path: []const u8, project_dir: []const u8) error{OutOfMemory}!void {
        const gop = try self.files.getOrPut(self.allocator, path);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, path) catch |e| {
                self.files.removeByPtr(gop.key_ptr);
                return e;
            };
            const owned_project_dir = self.allocator.dupe(u8, project_dir) catch |e| {
                self.allocator.free(gop.key_ptr.*);
                self.files.removeByPtr(gop.key_ptr);
                return e;
            };
            gop.value_ptr.* = .{ .project_dir = owned_project_dir };
        }
        gop.value_ptr.count += 1;
        if (gop.value_ptr.count == 1 and self.active()) {
            try self.acquire_chain(gop.key_ptr.*, gop.value_ptr);
            try self.resolve(gop.key_ptr.*, gop.value_ptr);
        }
    }

    fn file_close(self: *@This(), path: []const u8) void {
        const file = self.files.getPtr(path) orelse return;
        file.count -= 1;
        if (file.count > 0) return;
        const kv = self.files.fetchRemove(path).?;
        if (kv.value.map) |map| {
            self.release_chain(kv.key, kv.value.watched);
            self.allocator.free(map.bytes);
        }
        self.allocator.free(kv.value.project_dir);
        self.allocator.free(kv.key);
    }

    fn add_client(self: *@This(), client: tp.piid) error{OutOfMemory}!void {
        if (self.clients.contains(client)) return;
        const pid = tp.pid.from_id(client) orelse return;
        defer pid.deinit();
        pid.link() catch return log.err("failed to link client", .{});
        const was_active = self.active();
        try self.clients.put(self.allocator, client, {});
        var files = self.files.iterator();
        while (files.next()) |p| {
            if (!was_active) try self.acquire_chain(p.key_ptr.*, p.value_ptr);
            if (p.value_ptr.map == null) try self.resolve(p.key_ptr.*, p.value_ptr) else send_update(pid.ref(), p.key_ptr.*, p.value_ptr.map.?);
        }
    }

    fn remove_client(self: *@This(), client: tp.piid) void {
        if (!self.clients.remove(client)) return;
        if (self.active()) return;
        var files = self.files.iterator();
        while (files.next()) |p| if (p.value_ptr.map) |map| {
            self.release_chain(p.key_ptr.*, p.value_ptr.watched);
            self.allocator.free(map.bytes);
            p.value_ptr.map = null;
            p.value_ptr.watched = 0;
        };
    }

    fn acquire_chain(self: *@This(), path: []const u8, file: *File) error{OutOfMemory}!void {
        var arena_impl = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_impl.deinit();
        const a = arena_impl.allocator();
        const config_paths = try chain_paths(a, path);
        const contents = try a.alloc(?[]const u8, config_paths.len);
        for (config_paths, contents) |config_path, *content| {
            const gop = try self.configs.getOrPut(self.allocator, config_path);
            if (!gop.found_existing) {
                gop.key_ptr.* = self.allocator.dupe(u8, config_path) catch |e| {
                    self.configs.removeByPtr(gop.key_ptr);
                    return e;
                };
                gop.value_ptr.* = .{ .content = read_file(root.get_io(), self.allocator, config_path) };
            } else if (gop.value_ptr.watches == 0) {
                if (gop.value_ptr.content) |old| self.allocator.free(old);
                gop.value_ptr.content = read_file(root.get_io(), self.allocator, config_path);
            }
            gop.value_ptr.refs += 1;
            content.* = gop.value_ptr.content;
        }
        file.watched = watch_count(config_paths, contents, file.project_dir);
        for (config_paths[0..file.watched]) |config_path| {
            const kv = self.configs.getEntry(config_path).?;
            kv.value_ptr.watches += 1;
            if (kv.value_ptr.watches == 1)
                self.file_store.send(.{ "watch", kv.key_ptr.* }) catch |e| err("watch", e);
        }
    }

    fn release_chain(self: *@This(), path: []const u8, watched: usize) void {
        var arena_impl = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_impl.deinit();
        const config_paths = chain_paths(arena_impl.allocator(), path) catch return;
        for (config_paths[0..@min(watched, config_paths.len)]) |config_path| {
            const kv = self.configs.getEntry(config_path) orelse continue;
            kv.value_ptr.watches -= 1;
            if (kv.value_ptr.watches == 0)
                self.file_store.send(.{ "unwatch", kv.key_ptr.* }) catch |e| err("unwatch", e);
        }
        for (config_paths) |config_path| {
            const config = self.configs.getPtr(config_path) orelse continue;
            config.refs -= 1;
            if (config.refs > 0) continue;
            const kv = self.configs.fetchRemove(config_path).?;
            if (kv.value.content) |content| self.allocator.free(content);
            self.allocator.free(kv.key);
        }
    }

    fn config_changed(self: *@This(), config_path: []const u8) error{OutOfMemory}!void {
        const config = self.configs.getPtr(config_path) orelse return;
        if (config.watches == 0) return;
        if (config.content) |content| self.allocator.free(content);
        config.content = read_file(root.get_io(), self.allocator, config_path);

        var arena_impl = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_impl.deinit();
        const a = arena_impl.allocator();
        var files = self.files.iterator();
        while (files.next()) |p| {
            if (p.value_ptr.map == null) continue;
            const config_paths = try chain_paths(a, p.key_ptr.*);
            for (config_paths[0..@min(p.value_ptr.watched, config_paths.len)]) |chain_path| if (std.mem.eql(u8, chain_path, config_path)) {
                const watched = p.value_ptr.watched;
                try self.acquire_chain(p.key_ptr.*, p.value_ptr);
                self.release_chain(p.key_ptr.*, watched);
                try self.resolve(p.key_ptr.*, p.value_ptr);
                break;
            };
        }
    }

    fn resolve(self: *@This(), path: []const u8, file: *File) error{OutOfMemory}!void {
        var arena_impl = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_impl.deinit();
        const a = arena_impl.allocator();
        const config_paths = try chain_paths(a, path);
        const contents = try a.alloc(?[]const u8, config_paths.len);
        for (config_paths, contents) |config_path, *content|
            content.* = if (self.configs.get(config_path)) |config| config.content else null;
        const values = try resolve_chain(a, path, contents) orelse Values{};

        var map: std.Io.Writer.Allocating = .init(self.allocator);
        defer map.deinit();
        cbor.writeValue(&map.writer, values) catch return error.OutOfMemory;
        if (file.map) |old| {
            if (std.mem.eql(u8, old.bytes, map.written())) return;
            self.allocator.free(old.bytes);
            file.map = null;
        }
        file.map = .{ .bytes = try map.toOwnedSlice() };

        var clients = self.clients.keyIterator();
        while (clients.next()) |client| {
            const pid = tp.pid.from_id(client.*) orelse continue;
            defer pid.deinit();
            send_update(pid.ref(), path, file.map.?);
        }
    }

    fn send_update(to: tp.pid_ref, path: []const u8, map: cbor.Raw) void {
        to.send(.{ "EC", "update", path, map }) catch |e| err("update", e);
    }
};

fn err(context: []const u8, e: anyerror) void {
    switch (e) {
        error.Exit => log.err("{s}: {s}", .{ context, tp.error_text() }),
        else => log.err("{s}: {t}", .{ context, e }),
    }
}

test "sections of a file at the filesystem root" {
    try expect_match_section("/", "src/*.c", "/src/x.c", true);
    try expect_match_section("/", "/x.c", "/x.c", true);
    try expect_match_section("/", "*.c", "/a/b.c", true);
    try expect_match_section("C:/", "src/*.c", "C:/src/x.c", true);
    try expect_match_section("C:/", "*.c", "C:/a/b.c", true);
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
    try expect_match_section("/proj", "{0..3}", "/proj/0", true);
    try expect_match_section("/proj", "{0..3}", "/proj/00", false);
    try expect_match_section("/proj", "{0..3}", "/proj/03", false);
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

fn query_for_test(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8) error{OutOfMemory}!?Values {
    var arena_impl = std.heap.ArenaAllocator.init(allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    const paths = try chain_paths(a, file_path);
    const contents = try a.alloc(?[]const u8, paths.len);
    for (paths, contents) |config_path, *content| content.* = read_file(io, a, config_path);
    return resolve_chain(a, file_path, contents);
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

    const s1 = (try query_for_test(io, a, p1)).?;
    try std.testing.expectEqual(@as(?IndentStyle, .space), s1.indent_style);
    try std.testing.expectEqual(@as(?usize, 4), s1.tab_width);
    try std.testing.expectEqual(@as(?EndOfLine, .lf), s1.end_of_line);
    try std.testing.expectEqual(@as(?bool, false), s1.trim_trailing_whitespace);
    try std.testing.expectEqual(@as(?bool, null), s1.insert_final_newline);

    const s2 = (try query_for_test(io, a, p2)).?;
    try std.testing.expectEqual(@as(?IndentStyle, .space), s2.indent_style);
    try std.testing.expectEqual(@as(?usize, 3), s2.tab_width);
    try std.testing.expectEqual(@as(?bool, true), s2.trim_trailing_whitespace);

    const s3 = (try query_for_test(io, a, p3)).?;
    try std.testing.expectEqual(@as(?IndentStyle, .tab), s3.indent_style);
    try std.testing.expectEqual(@as(?usize, 3), s3.tab_width);
    try std.testing.expectEqual(@as(?bool, true), s3.insert_final_newline);

    try std.testing.expect((try query_for_test(io, a, p4)) == null);
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
    const s1 = (try query_for_test(io, a, p1)).?;
    try std.testing.expectEqual(@as(?IndentStyle, .space), s1.indent_style);
    try std.testing.expectEqual(@as(?usize, 4), s1.tab_width);

    const p2 = try std.fmt.allocPrint(a, "{s}/x.py", .{dir});
    defer a.free(p2);
    const s2 = (try query_for_test(io, a, p2)).?;
    try std.testing.expectEqual(@as(?IndentStyle, .tab), s2.indent_style);
    try std.testing.expectEqual(@as(?usize, 2), s2.tab_width);
    try std.testing.expectEqual(@as(?usize, null), s2.indent_size);

    const p3 = try std.fmt.allocPrint(a, "{s}/x.txt", .{dir});
    defer a.free(p3);
    try std.testing.expect((try query_for_test(io, a, p3)) == null);
}

test "resolve_chain from contents in memory" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    const path = if (builtin.os.tag == .windows) "C:\\proj\\sub\\x.c" else "/proj/sub/x.c";
    const paths = try chain_paths(a, path);
    try std.testing.expectEqual(@as(usize, 3), paths.len);
    try std.testing.expectEqualStrings(file_name, std.fs.path.basename(paths[0]));
    const sub = "[*.c]\nindent_size = 2\n";
    const proj = "root = true\n[*.c]\nindent_style = space\nindent_size = 4\ntab_width = 8\n";
    const above = "[*]\nend_of_line = crlf\n";
    const s1 = (try resolve_chain(a, path, &.{ sub, proj, above })).?;
    try std.testing.expectEqual(@as(?IndentStyle, .space), s1.indent_style);
    try std.testing.expectEqual(@as(?usize, 2), s1.indent_size);
    try std.testing.expectEqual(@as(?usize, 8), s1.tab_width);
    try std.testing.expectEqual(@as(?EndOfLine, null), s1.end_of_line);
    const s2 = (try resolve_chain(a, path, &.{ null, null, above })).?;
    try std.testing.expectEqual(@as(?EndOfLine, .crlf), s2.end_of_line);
    try std.testing.expect((try resolve_chain(a, path, &.{ null, null, null })) == null);
}

test "watch_count stops at the nearest root file or at the project directory" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    const windows = builtin.os.tag == .windows;
    const path = if (windows) "C:\\home\\proj\\sub\\x.c" else "/home/proj/sub/x.c";
    const project_dir = if (windows) "C:\\home\\proj" else "/home/proj";
    const paths = try chain_paths(a, path);
    try std.testing.expectEqual(@as(usize, 4), paths.len);
    try std.testing.expect(declares_root("\xef\xbb\xbf; comment\r\nROOT = True\r\n[*]\n"));
    try std.testing.expect(!declares_root("[*]\nroot = true\n"));
    try std.testing.expect(!declares_root("root = false\n"));
    try std.testing.expectEqual(@as(usize, 2), watch_count(paths, &.{ null, null, null, null }, project_dir));
    try std.testing.expectEqual(@as(usize, 1), watch_count(paths, &.{ "root = true\n", null, null, null }, project_dir));
    try std.testing.expectEqual(@as(usize, 3), watch_count(paths, &.{ null, null, "root = true\n", null }, project_dir));
    try std.testing.expectEqual(@as(usize, 1), watch_count(paths, &.{ null, null, null, null }, ""));
    try std.testing.expectEqual(@as(usize, 1), watch_count(paths, &.{ null, null, null, null }, if (windows) "C:\\other" else "/other"));
}

test "zero widths are ignored" {
    var v: ValueList = .{};
    v.set(.indent_style, "space");
    v.set(.indent_size, "0");
    const s1 = resolve(&v).?;
    try std.testing.expectEqual(@as(?usize, null), s1.indent_size);
    try std.testing.expectEqual(@as(?usize, null), s1.tab_width);

    v.clear();
    v.set(.indent_style, "tab");
    v.set(.tab_width, "0");
    const s2 = resolve(&v).?;
    try std.testing.expectEqual(@as(?usize, null), s2.indent_size);
    try std.testing.expectEqual(@as(?usize, null), s2.tab_width);

    v.clear();
    v.set(.indent_size, "00");
    v.set(.tab_width, "4");
    const s3 = resolve(&v).?;
    try std.testing.expectEqual(@as(?usize, null), s3.indent_size);
    try std.testing.expectEqual(@as(?usize, 4), s3.tab_width);
}

fn expect_match_section(dir: []const u8, section: []const u8, string: []const u8, want: bool) !void {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    const pattern = try build_pattern(a, try escape_special(a, dir), section);
    try std.testing.expectEqual(want, glob_match(pattern, string));
}
