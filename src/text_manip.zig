const std = @import("std");
const uucode = @import("vaxis").uucode;
const TextWriter = *std.Io.Writer;

pub fn find_first_non_ws(text: []const u8) ?usize {
    for (text, 0..) |c, i| if (c == ' ' or c == '\t') continue else return i;
    return null;
}

pub fn find_prefix(prefix: []const u8, text: []const u8) ?usize {
    var start: usize = 0;
    var pos: usize = 0;
    var in_prefix: bool = false;
    for (text, 0..) |c, i| {
        if (!in_prefix) {
            if (c == ' ' or c == '\t')
                continue
            else {
                in_prefix = true;
                start = i;
            }
        }

        if (in_prefix) {
            if (c == prefix[pos]) {
                pos += 1;
                if (prefix.len > pos) continue else return start;
            } else return null;
        }
    }
    return null;
}

fn add_prefix_in_line(prefix: []const u8, text: []const u8, writer: TextWriter, pos: usize) !void {
    if (text.len >= pos and find_first_non_ws(text) != null) {
        try writer.writeAll(text[0..pos]);
        try writer.writeAll(prefix);
        try writer.writeAll(" ");
        try writer.writeAll(text[pos..]);
    } else {
        try writer.writeAll(text);
    }
}

fn remove_prefix_in_line(prefix: []const u8, text: []const u8, writer: TextWriter) !void {
    if (find_prefix(prefix, text)) |pos| {
        try writer.writeAll(text[0..pos]);
        if (text.len > pos + prefix.len) {
            _ = try if (text[pos + prefix.len] == ' ')
                writer.write(text[pos + 1 + prefix.len ..])
            else
                writer.write(text[pos + prefix.len ..]);
        }
    } else {
        try writer.writeAll(text);
    }
}

pub fn toggle_prefix_in_text(prefix: []const u8, text: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var result: std.Io.Writer.Allocating = .init(allocator);
    defer result.deinit();
    const writer = &result.writer;
    if (text.len == 0) {
        try writer.writeAll(prefix);
        return result.toOwnedSlice();
    }
    var prefix_pos: usize = std.math.maxInt(usize);
    var have_prefix = true;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (find_prefix(prefix, line)) |_| {} else {
            if (find_first_non_ws(line)) |_| {
                have_prefix = false;
                break;
            }
        }
    }

    it = std.mem.splitScalar(u8, text, '\n');
    if (!have_prefix)
        while (it.next()) |line| {
            if (find_first_non_ws(line)) |prefix_pos_|
                prefix_pos = @min(prefix_pos, prefix_pos_);
        };

    it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try writer.writeAll("\n");
        first = false;
        if (have_prefix) {
            try remove_prefix_in_line(prefix, line, writer);
        } else {
            try add_prefix_in_line(prefix, line, writer, prefix_pos);
        }
    }

    return result.toOwnedSlice();
}

pub fn write_string(writer: *std.Io.Writer, string: []const u8, pad: ?usize) !void {
    try writer.writeAll(string);
    if (pad) |pad_| try write_padding(writer, string.len, pad_);
}

pub fn write_padding(writer: *std.Io.Writer, len: usize, pad_len: usize) !void {
    for (0..pad_len - len) |_| try writer.writeAll(" ");
}

// Filter from ad, the Rust terminal editor: https://github.com/sminez/ad

/// Queries with more fragments than this re-tokenize on every line.
const max_query_fragments = 32;

/// What a fragment can match in ad's line number prefix.
const PrefixKind = enum { none, digits, pipe };

/// One whitespace-separated part of a query, analyzed once.
const Fragment = struct {
    text: []const u8,
    /// Every character is lowercase, so the fragment matches ignoring case.
    folded: bool,
    ascii: bool,
    /// The text has an i or k, which İ (U+0130) and K (U+212A) lowercase to.
    has_i_or_k: bool,
    prefix: PrefixKind,
};

/// Fragments and `raw` borrow from the query string.
/// `unicode_upper` is `has_unicode_upper(line)`, cached by the caller.
pub const CompiledQuery = struct {
    fragments: [max_query_fragments]Fragment = undefined,
    len: usize = 0,
    /// Too many fragments to compile, so matching re-tokenizes `raw`.
    overflow: bool = false,
    raw: []const u8 = "",
    /// Some fragment can match the line number prefix.
    needs_prefix: bool = false,
    /// Some fragment can match the line number digits.
    needs_number: bool = false,

    pub fn matches(self: *const CompiledQuery, line: []const u8, unicode_upper: bool) bool {
        return self.match_line(line, unicode_upper, null);
    }

    /// Match ad's numbered line, where `number` is the unpadded row number.
    pub fn matches_with_number(self: *const CompiledQuery, number: []const u8, line: []const u8, unicode_upper: bool) bool {
        return self.match_line(line, unicode_upper, number);
    }

    fn match_line(self: *const CompiledQuery, line: []const u8, unicode_upper: bool, number: ?[]const u8) bool {
        if (self.overflow) return matches_uncompiled(self.raw, line, unicode_upper, number);
        // Byte path is exact unless a non-ASCII char lowercases differently.
        if (!unicode_upper) {
            for (self.fragments[0..self.len]) |fragment|
                if (!match_byte_fragment(line, number, fragment)) return false;
            return true;
        }
        var lower: LowercasedLine = .{ .line = line };
        for (self.fragments[0..self.len]) |fragment|
            if (!match_lowered(&lower, number, fragment)) return false;
        return true;
    }
};

pub fn compile_query(query: []const u8) CompiledQuery {
    var compiled: CompiledQuery = .{ .raw = query };
    var it: FragmentIterator = .{ .query = query };
    while (it.next()) |text| {
        if (compiled.len == max_query_fragments) {
            compiled.len = 0;
            compiled.overflow = true;
            compiled.needs_prefix = true;
            compiled.needs_number = true;
            return compiled;
        }
        const fragment = init_fragment(text);
        compiled.fragments[compiled.len] = fragment;
        compiled.len += 1;
        compiled.needs_prefix = compiled.needs_prefix or fragment.prefix != .none;
        compiled.needs_number = compiled.needs_number or fragment.prefix == .digits;
    }
    return compiled;
}

/// True when `next` only appends to `prev`, so its matches are a subset.
/// `prev` must be valid UTF-8, or appended bytes could complete a space.
pub fn query_extends(prev: []const u8, next: []const u8) bool {
    return next.len > prev.len and std.mem.startsWith(u8, next, prev) and
        std.unicode.utf8ValidateSlice(prev);
}

/// Splits a query like Rust's `str::split_whitespace`.
const FragmentIterator = struct {
    query: []const u8,
    pos: usize = 0,

    pub fn next(self: *FragmentIterator) ?[]const u8 {
        const query = self.query;
        while (self.pos < query.len) {
            const len = whitespace_len(query, self.pos);
            if (len == 0) break;
            self.pos += len;
        }
        if (self.pos == query.len) return null;
        const start = self.pos;
        while (self.pos < query.len and whitespace_len(query, self.pos) == 0)
            self.pos += char_len(query, self.pos);
        return query[start..self.pos];
    }
};

fn init_fragment(text: []const u8) Fragment {
    var all_digits = true;
    var ascii = true;
    var has_i_or_k = false;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) all_digits = false;
        if (!std.ascii.isAscii(c)) ascii = false;
        if (c == 'i' or c == 'k') has_i_or_k = true;
    }
    return .{
        .text = text,
        .folded = is_lowercase(text),
        .ascii = ascii,
        .has_i_or_k = has_i_or_k,
        .prefix = if (all_digits) .digits else if (text.len == 1 and text[0] == '|') .pipe else .none,
    };
}

/// Rust's `chars().all(char::is_lowercase)`. Invalid UTF-8 is not lowercase.
fn is_lowercase(text: []const u8) bool {
    var pos: usize = 0;
    while (pos < text.len) {
        const char = char_at(text, pos) orelse return false;
        if (!uucode.get(.is_lowercase, char.cp)) return false;
        pos += char.len;
    }
    return true;
}

/// ad's filter: every fragment must match, all-lowercase ones ignore case.
pub fn line_matches_fragments(line: []const u8, query: []const u8) bool {
    return matches_uncompiled(query, line, has_unicode_upper(line), null);
}

fn matches_uncompiled(query: []const u8, line: []const u8, unicode_upper: bool, number: ?[]const u8) bool {
    var it: FragmentIterator = .{ .query = query };
    if (!unicode_upper) {
        while (it.next()) |text|
            if (!match_byte_fragment(line, number, init_fragment(text))) return false;
        return true;
    }
    var lower: LowercasedLine = .{ .line = line };
    while (it.next()) |text|
        if (!match_lowered(&lower, number, init_fragment(text))) return false;
    return true;
}

/// True when a non-ASCII char lowercases differently, so bytes are not exact.
pub fn has_unicode_upper(line: []const u8) bool {
    var pos: usize = 0;
    while (find_non_ascii(line, pos)) |start| {
        const char = char_at(line, start) orelse {
            pos = start + 1;
            continue;
        };
        if (uucode.get(.changes_when_lowercased, char.cp)) return true;
        pos = start + char.len;
    }
    return false;
}

pub fn has_non_ascii(text: []const u8) bool {
    return find_non_ascii(text, 0) != null;
}

inline fn match_byte_fragment(line: []const u8, number: ?[]const u8, fragment: Fragment) bool {
    if (find_bytes(line, fragment)) return true;
    return if (number) |n| fragment_matches_prefix(fragment, n) else false;
}

inline fn match_lowered(lower: *LowercasedLine, number: ?[]const u8, fragment: Fragment) bool {
    if (find_bytes(lower.line, fragment)) return true;
    if (fragment.folded and lower.contains(fragment)) return true;
    return if (number) |n| fragment_matches_prefix(fragment, n) else false;
}

/// A line lowercased on first use, shared by all fragments of one query.
const LowercasedLine = struct {
    line: []const u8,
    state: enum { pending, done, too_long } = .pending,
    maps_to_ascii: enum { unknown, no, yes } = .unknown,
    buf: [1024]u8 = undefined,
    len: usize = 0,

    fn contains(self: *LowercasedLine, fragment: Fragment) bool {
        if (fragment.ascii) {
            // Lowercasing can only add an i or k to the ASCII part of a line.
            if (!fragment.has_i_or_k or !self.lowercases_to_ascii()) return false;
        }
        if (self.state == .pending)
            self.state = if (lowercase_line(self.line, &self.buf, &self.len)) .done else .too_long;
        return switch (self.state) {
            .done => find_bytes(self.buf[0..self.len], fragment),
            .too_long => contains_lowercased(self.line, fragment.text),
            .pending => unreachable,
        };
    }

    /// True when the line has U+0130 or U+212A, the only ASCII-lowering chars.
    fn lowercases_to_ascii(self: *LowercasedLine) bool {
        switch (self.maps_to_ascii) {
            .unknown => {
                const found = std.mem.find(u8, self.line, "\u{212A}") != null or
                    std.mem.find(u8, self.line, "\u{130}") != null;
                self.maps_to_ascii = if (found) .yes else .no;
                return found;
            },
            .no => return false,
            .yes => return true,
        }
    }
};

/// Rust's `to_lowercase` into `buf`, false when the line may not fit.
fn lowercase_line(line: []const u8, buf: []u8, len: *usize) bool {
    // Lowercasing grows a line by at most half its byte length.
    if (line.len + line.len / 2 > buf.len) return false;
    var out: usize = 0;
    var pos: usize = 0;
    while (pos < line.len) {
        const c = line[pos];
        if (c < 0x80) {
            buf[out] = std.ascii.toLower(c);
            out += 1;
            pos += 1;
            continue;
        }
        var char_buf: [4]u8 = undefined;
        const lower = lowercase_at(line, pos, &char_buf);
        @memcpy(buf[out..][0..lower.bytes.len], lower.bytes);
        out += lower.bytes.len;
        pos += lower.len;
    }
    len.* = out;
    return true;
}

fn fragment_matches_prefix(fragment: Fragment, number: []const u8) bool {
    return switch (fragment.prefix) {
        .none => false,
        // The prefix always has a pipe.
        .pipe => true,
        .digits => find_bytes(number, fragment),
    };
}

/// Byte search, folding ASCII case for a folded fragment.
inline fn find_bytes(line: []const u8, fragment: Fragment) bool {
    const text = fragment.text;
    if (text.len > line.len) return false;
    // std has no vectorized ignore-case search, and most fragments fail early.
    const fold_first = fragment.folded and std.ascii.isLower(text[0]);
    if (text.len == 1)
        return if (fold_first)
            find_folded(line, 0, text[0]) != null
        else
            std.mem.findScalarPos(u8, line, 0, text[0]) != null;
    var i: usize = 0;
    while (true) {
        const pos = (if (fold_first)
            find_folded(line, i, text[0])
        else
            std.mem.findScalarPos(u8, line, i, text[0])) orelse return false;
        if (pos + text.len > line.len) return false;
        const equal = if (fragment.folded)
            std.ascii.eqlIgnoreCase(line[pos..][0..text.len], text)
        else
            std.mem.eql(u8, line[pos..][0..text.len], text);
        if (equal) return true;
        i = pos + 1;
    }
}

/// `| 0x20` folds A-Z onto a-z and leaves other bytes outside a-z.
fn find_folded(line: []const u8, start: usize, lower_first: u8) ?usize {
    const block_len = std.simd.suggestVectorLength(u8) orelse 16;
    const Vec = @Vector(block_len, u8);
    const fold: Vec = @splat(0x20);
    const target: Vec = @splat(lower_first);
    var i = start;
    while (i + block_len <= line.len) : (i += block_len) {
        const block: Vec = line[i..][0..block_len].*;
        if (std.simd.firstTrue((block | fold) == target)) |offset| return i + offset;
    }
    while (i < line.len) : (i += 1)
        if ((line[i] | 0x20) == lower_first) return i;
    return null;
}

fn find_non_ascii(line: []const u8, start: usize) ?usize {
    const block_len = std.simd.suggestVectorLength(u8) orelse 16;
    const Vec = @Vector(block_len, u8);
    const high: Vec = @splat(0x80);
    var i = start;
    while (i + block_len <= line.len) : (i += block_len) {
        const block: Vec = line[i..][0..block_len].*;
        if (std.simd.firstTrue(block >= high)) |offset| return i + offset;
    }
    while (i < line.len) : (i += 1)
        if (line[i] >= 0x80) return i;
    return null;
}

/// Rust's `line.to_lowercase().contains(fragment)` when the line is too long.
fn contains_lowercased(line: []const u8, fragment: []const u8) bool {
    var start: usize = 0;
    while (start < line.len) : (start += char_len(line, start))
        if (lowercased_starts_with(line, start, fragment)) return true;
    return false;
}

fn lowercased_starts_with(line: []const u8, start: usize, fragment: []const u8) bool {
    var pos = start;
    var matched: usize = 0;
    while (matched < fragment.len) {
        if (pos == line.len) return false;
        var buf: [4]u8 = undefined;
        const lower = lowercase_at(line, pos, &buf);
        const n = @min(lower.bytes.len, fragment.len - matched);
        if (!std.mem.eql(u8, lower.bytes[0..n], fragment[matched..][0..n])) return false;
        matched += n;
        pos += lower.len;
    }
    return true;
}

const LoweredChar = struct { bytes: []const u8, len: usize };

/// Rust's lowercase of the char at `pos`, invalid bytes stay as they are.
fn lowercase_at(line: []const u8, pos: usize, buf: *[4]u8) LoweredChar {
    const char = char_at(line, pos) orelse return .{ .bytes = line[pos..][0..1], .len = 1 };
    const lower: u21 = switch (char.cp) {
        // The only character that lowercases to two characters.
        0x130 => return .{ .bytes = "i\u{307}", .len = char.len },
        0x3A3 => if (is_final_sigma(line, pos, char.len)) 0x3C2 else 0x3C3,
        else => uucode.get(.simple_lowercase_mapping, char.cp),
    };
    const n = std.unicode.utf8Encode(lower, buf) catch unreachable;
    return .{ .bytes = buf[0..n], .len = char.len };
}

/// Rust lowercases Σ to ς with a cased letter before it and none after.
fn is_final_sigma(line: []const u8, pos: usize, len: usize) bool {
    return cased_before(line, pos) and !cased_after(line, pos + len);
}

fn cased_before(line: []const u8, end: usize) bool {
    var pos = end;
    while (pos > 0) {
        var start = pos - 1;
        while (start > 0 and pos - start < 4 and line[start] & 0xC0 == 0x80) start -= 1;
        const char = char_at(line, start) orelse return false;
        if (start + char.len != pos) return false;
        if (!is_case_ignorable(char.cp)) return is_cased(char.cp);
        pos = start;
    }
    return false;
}

fn cased_after(line: []const u8, start: usize) bool {
    var pos = start;
    while (pos < line.len) {
        const char = char_at(line, pos) orelse return false;
        if (!is_case_ignorable(char.cp)) return is_cased(char.cp);
        pos += char.len;
    }
    return false;
}

fn is_cased(cp: u21) bool {
    if (uucode.get(.is_lowercase, cp)) return true;
    return switch (uucode.get(.general_category, cp)) {
        .letter_uppercase, .letter_titlecase => true,
        // Other_Uppercase
        else => switch (cp) {
            0x2160...0x216F, 0x24B6...0x24CF, 0x1F130...0x1F149, 0x1F150...0x1F169, 0x1F170...0x1F189 => true,
            else => false,
        },
    };
}

fn is_case_ignorable(cp: u21) bool {
    return switch (uucode.get(.general_category, cp)) {
        .mark_nonspacing, .mark_enclosing, .other_format, .letter_modifier, .symbol_modifier => true,
        // Word_Break MidLetter, MidNumLet and Single_Quote
        else => switch (cp) {
            '\'', '.', ':', 0xB7, 0x387, 0x55F, 0x5F4, 0x2018, 0x2019, 0x2024, 0x2027, 0xFE13, 0xFE52, 0xFE55, 0xFF07, 0xFF0E, 0xFF1A => true,
            else => false,
        },
    };
}

/// Rust's `char::is_whitespace`.
fn is_whitespace(cp: u21) bool {
    return switch (cp) {
        '\t'...'\r', ' ', 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

fn whitespace_len(text: []const u8, pos: usize) usize {
    const char = char_at(text, pos) orelse return 0;
    return if (is_whitespace(char.cp)) char.len else 0;
}

const Char = struct { cp: u21, len: u3 };

/// Decode the char at `pos`, or null when the bytes are not valid UTF-8.
fn char_at(text: []const u8, pos: usize) ?Char {
    const first = text[pos];
    if (first < 0x80) return .{ .cp = first, .len = 1 };
    const len = std.unicode.utf8ByteSequenceLength(first) catch return null;
    if (len > text.len - pos) return null;
    const bytes = text[pos..];
    const cp = switch (len) {
        2 => std.unicode.utf8Decode2(bytes[0..2].*),
        3 => std.unicode.utf8Decode3(bytes[0..3].*),
        4 => std.unicode.utf8Decode4(bytes[0..4].*),
        else => unreachable,
    } catch return null;
    return .{ .cp = cp, .len = len };
}

fn char_len(text: []const u8, pos: usize) usize {
    return if (char_at(text, pos)) |char| char.len else 1;
}

/// Expand tabs. Wide chars count as one, so tab stops can drift.
pub fn write_tabs_expanded(writer: *std.Io.Writer, line: []const u8, tab_width: usize) !void {
    const width = @max(tab_width, 1);
    var col: usize = 0;
    for (line) |c| {
        if (c == '\t') {
            const spaces = width - (col % width);
            for (0..spaces) |_| try writer.writeByte(' ');
            col += spaces;
        } else {
            try writer.writeByte(c);
            col += 1;
        }
    }
}
