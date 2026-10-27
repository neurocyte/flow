//! convert markdown text to a structured document

const std = @import("std");
const syntax = @import("syntax");
const build_options = @import("build_options");
const SDoc = @import("SDoc.zig");

const Allocator = std.mem.Allocator;
const Node = syntax.Node;
const Range = syntax.Range;
const ElementBuilder = SDoc.ElementBuilder;

pub const Error = error{ OutOfMemory, ParseFailed };

/// write `lines` as a fenced code block, with a fence no line can close
pub fn write_code_block(writer: *std.Io.Writer, lang: ?[]const u8, lines: []const []const u8) std.Io.Writer.Error!void {
    var fence_len: usize = 3;
    for (lines) |line| fence_len = @max(fence_len, longest_backtick_run(line) + 1);
    try writer.splatByteAll('`', fence_len);
    if (lang) |l| try writer.writeAll(l);
    try writer.writeByte('\n');
    for (lines) |line| if (line.len > 0) {
        try writer.writeAll(line);
        try writer.writeByte('\n');
    };
    try writer.splatByteAll('`', fence_len);
    try writer.writeByte('\n');
}

fn longest_backtick_run(text: []const u8) usize {
    var longest: usize = 0;
    var run: usize = 0;
    for (text) |c| {
        run = if (c == '`') run + 1 else 0;
        longest = @max(longest, run);
    }
    return longest;
}

/// parse markdown into a structured document
pub fn parse(allocator: Allocator, source_: []const u8, query_cache: *syntax.QueryCache) Error!SDoc {
    var arena_: std.heap.ArenaAllocator = .init(allocator);
    defer arena_.deinit();
    const arena = arena_.allocator();
    // a block at the end of the text needs a line end to close, closing code fences in particular
    const source = if (std.mem.endsWith(u8, source_, "\n")) source_ else try std.mem.concat(arena, u8, &.{ source_, "\n" });

    const body = try ElementBuilder.create(arena, "body", 0, source_.len);
    if (!build_options.use_tree_sitter) {
        const pre = try body.add_elem(arena, "pre", 0, source_.len);
        try pre.add_text(arena, source_);
    } else {
        var builder: Builder = .{
            .arena = arena,
            .src = source,
            .block_syn = try create_syntax(allocator, "markdown", query_cache),
            .inline_syn = undefined,
        };
        defer builder.block_syn.destroy();
        builder.inline_syn = try create_syntax(allocator, "markdown-inline", query_cache);
        defer builder.inline_syn.destroy();

        const tree = builder.block_syn.parser.parseString(null, source) catch return error.ParseFailed;
        defer tree.destroy();
        const top = tree.getRootNode();
        try builder.collect_definitions(top);
        try builder.blocks(body, top);
    }

    return body.encode(allocator, source_);
}

fn create_syntax(allocator: Allocator, lang: []const u8, query_cache: *syntax.QueryCache) Error!*syntax {
    return syntax.create_file_type_static(allocator, lang, query_cache) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ParseFailed,
    };
}

fn add_node(elem: *ElementBuilder, arena: Allocator, tag: []const u8, node: Node) error{OutOfMemory}!*ElementBuilder {
    return elem.add_elem(arena, tag, node.getStartByte(), node.getEndByte());
}

const Definition = struct {
    href: []const u8,
    title: ?[]const u8,
};

const Builder = struct {
    arena: Allocator,
    src: []const u8,
    block_syn: *syntax,
    inline_syn: *syntax,
    definitions: std.StringHashMapUnmanaged(Definition) = .empty,
    /// the source ranges of the inline content being walked
    included: []const Range = &.{},

    fn text(self: *const Builder, node: Node) []const u8 {
        return self.src[node.getStartByte()..node.getEndByte()];
    }

    fn child_of_type(node: Node, type_: []const u8) ?Node {
        var i: u32 = 0;
        while (i < node.getChildCount()) : (i += 1) {
            const child = node.getChild(i);
            if (std.mem.eql(u8, child.getType(), type_)) return child;
        }
        return null;
    }

    /// the range of a node without its block_continuation children
    fn content_ranges(self: *const Builder, node: Node) error{OutOfMemory}![]Range {
        var ranges: std.ArrayList(Range) = .empty;
        var cur = node.getRange();
        var i: u32 = 0;
        while (i < node.getChildCount()) : (i += 1) {
            const child = node.getChild(i);
            if (!std.mem.eql(u8, child.getType(), "block_continuation")) continue;
            if (child.getStartByte() > cur.start_byte)
                try ranges.append(self.arena, .{
                    .start_point = cur.start_point,
                    .end_point = child.getStartPoint(),
                    .start_byte = cur.start_byte,
                    .end_byte = child.getStartByte(),
                });
            cur.start_point = child.getEndPoint();
            cur.start_byte = child.getEndByte();
        }
        if (cur.end_byte > cur.start_byte) try ranges.append(self.arena, cur);
        return ranges.items;
    }

    /// the text of a node without its block_continuation children
    fn content_text(self: *const Builder, node: Node) error{OutOfMemory}![]const u8 {
        const ranges = try self.content_ranges(node);
        if (ranges.len == 1) return self.src[ranges[0].start_byte..ranges[0].end_byte];
        var out: std.ArrayList(u8) = .empty;
        for (ranges) |r| try out.appendSlice(self.arena, self.src[r.start_byte..r.end_byte]);
        return out.items;
    }

    fn collect_definitions(self: *Builder, node: Node) error{OutOfMemory}!void {
        if (std.mem.eql(u8, node.getType(), "link_reference_definition")) {
            const label = child_of_type(node, "link_label") orelse return;
            const dest = child_of_type(node, "link_destination") orelse return;
            const key = try self.normalize_label(self.text(label));
            const result = try self.definitions.getOrPut(self.arena, key);
            if (!result.found_existing) result.value_ptr.* = .{
                .href = try self.destination(dest),
                .title = if (child_of_type(node, "link_title")) |t| try self.title(t) else null,
            };
            return;
        }
        var i: u32 = 0;
        while (i < node.getNamedChildCount()) : (i += 1) try self.collect_definitions(node.getNamedChild(i));
    }

    /// case fold, collapse whitespace and drop the brackets of a link label
    fn normalize_label(self: *const Builder, label_: []const u8) error{OutOfMemory}![]const u8 {
        var label = label_;
        if (label.len >= 2 and label[0] == '[' and label[label.len - 1] == ']') label = label[1 .. label.len - 1];
        var out: std.ArrayList(u8) = .empty;
        var it = std.mem.tokenizeAny(u8, label, " \t\r\n");
        while (it.next()) |word| {
            if (out.items.len > 0) try out.append(self.arena, ' ');
            for (word) |c| try out.append(self.arena, std.ascii.toLower(c));
        }
        return out.items;
    }

    fn destination(self: *const Builder, node: Node) error{OutOfMemory}![]const u8 {
        var dest = self.text(node);
        if (dest.len >= 2 and dest[0] == '<' and dest[dest.len - 1] == '>') dest = dest[1 .. dest.len - 1];
        return self.unescape(dest);
    }

    fn title(self: *const Builder, node: Node) error{OutOfMemory}![]const u8 {
        var t = self.text(node);
        if (t.len >= 2) t = t[1 .. t.len - 1];
        return self.unescape(t);
    }

    fn unescape(self: *const Builder, s: []const u8) error{OutOfMemory}![]const u8 {
        if (std.mem.indexOfScalar(u8, s, '\\') == null and std.mem.indexOfScalar(u8, s, '&') == null) return s;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == '\\' and i + 1 < s.len and std.ascii.isPrint(s[i + 1]) and !std.ascii.isAlphanumeric(s[i + 1])) {
                try out.append(self.arena, s[i + 1]);
                i += 2;
            } else if (s[i] == '&') {
                const end = std.mem.indexOfScalarPos(u8, s, i, ';') orelse s.len;
                if (end < s.len) if (try decode_entity(self.arena, s[i .. end + 1])) |decoded| {
                    try out.appendSlice(self.arena, decoded);
                    i = end + 1;
                    continue;
                };
                try out.append(self.arena, '&');
                i += 1;
            } else {
                try out.append(self.arena, s[i]);
                i += 1;
            }
        }
        return out.items;
    }

    fn blocks(self: *Builder, parent: *ElementBuilder, node: Node) Error!void {
        var i: u32 = 0;
        while (i < node.getNamedChildCount()) : (i += 1) try self.block(parent, node.getNamedChild(i));
    }

    fn block(self: *Builder, parent: *ElementBuilder, node: Node) Error!void {
        const t = node.getType();
        const eql = std.mem.eql;
        if (eql(u8, t, "section") or eql(u8, t, "document")) {
            try self.blocks(parent, node);
        } else if (eql(u8, t, "atx_heading")) {
            const marker = node.getChild(0).getType();
            const level: u8 = if (marker.len == "atx_h1_marker".len and std.ascii.isDigit(marker[5])) marker[5] - '0' else 1;
            const h = try add_node(parent, self.arena, heading_tags[level - 1], node);
            if (child_of_type(node, "inline")) |content| try self.inline_content(h, content);
            strip_closing_sequence(h);
        } else if (eql(u8, t, "setext_heading")) {
            const level: u8 = if (child_of_type(node, "setext_h2_underline")) |_| 2 else 1;
            const h = try add_node(parent, self.arena, heading_tags[level - 1], node);
            if (child_of_type(node, "paragraph")) |para| if (child_of_type(para, "inline")) |content|
                try self.inline_content(h, content);
        } else if (eql(u8, t, "paragraph")) {
            const p = try add_node(parent, self.arena, "p", node);
            if (child_of_type(node, "inline")) |content| try self.inline_content(p, content);
        } else if (eql(u8, t, "block_quote")) {
            try self.blocks(try add_node(parent, self.arena, "blockquote", node), node);
        } else if (eql(u8, t, "list")) {
            try self.list(parent, node);
        } else if (eql(u8, t, "fenced_code_block")) {
            const pre = try add_node(parent, self.arena, "pre", node);
            if (child_of_type(node, "info_string")) |info| if (child_of_type(info, "language")) |lang|
                try pre.set(self.arena, "lang", .{ .string = self.text(lang) });
            if (child_of_type(node, "code_fence_content")) |content| {
                pre.src_row = content.getStartPoint().row;
                try pre.add_text(self.arena, try self.dedent(trim_final_newline(try self.content_text(content)), self.fence_indent(node)));
            }
        } else if (eql(u8, t, "indented_code_block")) {
            const pre = try add_node(parent, self.arena, "pre", node);
            // the indentation of later lines is in block_continuation nodes, the first line keeps it
            const code = std.mem.trimEnd(u8, try self.content_text(node), "\r\n");
            try pre.add_text(self.arena, strip_code_indent(code));
        } else if (eql(u8, t, "thematic_break")) {
            _ = try add_node(parent, self.arena, "hr", node);
        } else if (eql(u8, t, "html_block")) {
            const html = try add_node(parent, self.arena, "html", node);
            try html.add_text(self.arena, std.mem.trimEnd(u8, try self.content_text(node), "\r\n"));
        } else if (eql(u8, t, "pipe_table")) {
            try self.table(parent, node);
        } else if (is_ignored_block(t)) {
            return;
        } else {
            const raw = std.mem.trim(u8, try self.content_text(node), " \t\r\n");
            if (raw.len > 0) try (try add_node(parent, self.arena, "p", node)).add_text(self.arena, raw);
        }
    }

    /// the spaces before an opening code fence, after any container marker
    fn fence_indent(self: *const Builder, node: Node) usize {
        const start = if (child_of_type(node, "fenced_code_block_delimiter")) |d| d.getStartByte() else node.getStartByte();
        var lower = if (std.mem.lastIndexOfScalar(u8, self.src[0..start], '\n')) |eol| eol + 1 else 0;
        const prev = node.prevSibling();
        if (!prev.isNull() and prev.getEndByte() <= start) lower = @max(lower, prev.getEndByte());
        var i = start;
        while (i > lower and self.src[i - 1] == ' ') i -= 1;
        var j = start;
        while (j < self.src.len and self.src[j] == ' ') j += 1;
        return j - i;
    }

    /// remove up to `indent` leading spaces from each line
    fn dedent(self: *const Builder, code: []const u8, indent: usize) error{OutOfMemory}![]const u8 {
        if (indent == 0) return code;
        var out: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitScalar(u8, code, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) try out.append(self.arena, '\n');
            first = false;
            var n: usize = 0;
            while (n < indent and n < line.len and line[n] == ' ') n += 1;
            try out.appendSlice(self.arena, line[n..]);
        }
        return out.items;
    }

    fn is_ignored_block(t: []const u8) bool {
        const ignored = [_][]const u8{
            "link_reference_definition",
            "block_continuation",
            "block_quote_marker",
            "minus_metadata",
            "plus_metadata",
        };
        for (ignored) |i| if (std.mem.eql(u8, t, i)) return true;
        return false;
    }

    fn table(self: *Builder, parent: *ElementBuilder, node: Node) Error!void {
        const elem = try add_node(parent, self.arena, "table", node);
        var aligns: std.ArrayList(?[]const u8) = .empty;
        if (child_of_type(node, "pipe_table_delimiter_row")) |row| {
            var i: u32 = 0;
            while (i < row.getNamedChildCount()) : (i += 1) {
                const cell = row.getNamedChild(i);
                if (!std.mem.eql(u8, cell.getType(), "pipe_table_delimiter_cell")) continue;
                const left = child_of_type(cell, "pipe_table_align_left") != null;
                const right = child_of_type(cell, "pipe_table_align_right") != null;
                try aligns.append(self.arena, if (left and right) "center" else if (left) "left" else if (right) "right" else null);
            }
        }
        var body: ?*ElementBuilder = null;
        var i: u32 = 0;
        while (i < node.getNamedChildCount()) : (i += 1) {
            const row = node.getNamedChild(i);
            const t = row.getType();
            const head = std.mem.eql(u8, t, "pipe_table_header");
            if (!head and !std.mem.eql(u8, t, "pipe_table_row")) continue;
            const section = if (head)
                try add_node(elem, self.arena, "thead", row)
            else
                body orelse blk: {
                    body = try elem.add_elem(self.arena, "tbody", row.getStartByte(), node.getEndByte());
                    break :blk body.?;
                };
            const tr = try add_node(section, self.arena, "tr", row);
            var column: usize = 0;
            var j: u32 = 0;
            while (j < row.getNamedChildCount()) : (j += 1) {
                const cell = row.getNamedChild(j);
                if (!std.mem.eql(u8, cell.getType(), "pipe_table_cell")) continue;
                const td = try add_node(tr, self.arena, if (head) "th" else "td", cell);
                if (column < aligns.items.len) if (aligns.items[column]) |a| try td.set(self.arena, "align", .{ .string = a });
                column += 1;
                try self.inline_ranges(td, &.{cell.getRange()});
            }
        }
    }

    fn is_list_marker(t: []const u8) bool {
        return std.mem.startsWith(u8, t, "list_marker_") or std.mem.startsWith(u8, t, "task_list_marker_");
    }

    /// the blocks of a list item, without markers and continuations
    fn item_blocks(self: *const Builder, item: Node) error{OutOfMemory}![]Node {
        var list_: std.ArrayList(Node) = .empty;
        var i: u32 = 0;
        while (i < item.getNamedChildCount()) : (i += 1) {
            const child = item.getNamedChild(i);
            const t = child.getType();
            if (is_list_marker(t) or std.mem.eql(u8, t, "block_continuation")) continue;
            try list_.append(self.arena, child);
        }
        return list_.items;
    }

    /// a list is loose if a blank line separates two of its blocks
    fn is_loose(self: *const Builder, node: Node) error{OutOfMemory}!bool {
        var prev_end: ?usize = null;
        var i: u32 = 0;
        while (i < node.getNamedChildCount()) : (i += 1) {
            const item = node.getNamedChild(i);
            if (!std.mem.eql(u8, item.getType(), "list_item")) continue;
            for (try self.item_blocks(item)) |b| {
                if (prev_end) |end| if (self.blank_between(end, b.getStartByte())) return true;
                prev_end = b.getEndByte();
            }
        }
        return false;
    }

    fn blank_between(self: *const Builder, end: usize, start: usize) bool {
        if (start <= end) return false;
        var newlines = std.mem.count(u8, self.src[end..start], "\n");
        if (end > 0 and self.src[end - 1] == '\n') newlines += 1;
        return newlines >= 2;
    }

    fn list(self: *Builder, parent: *ElementBuilder, node: Node) Error!void {
        const first = node.getNamedChild(0);
        const marker = if (first.isNull()) null else child_of_type(first, "list_marker_dot") orelse child_of_type(first, "list_marker_parenthesis");
        const elem = try add_node(parent, self.arena, if (marker) |_| "ol" else "ul", node);
        if (marker) |m| {
            const digits = std.mem.trim(u8, self.text(m), " \t.)");
            const start = std.fmt.parseInt(u64, digits, 10) catch 1;
            if (start != 1) try elem.set(self.arena, "start", .{ .uint = start });
        }
        const loose = try self.is_loose(node);
        var i: u32 = 0;
        while (i < node.getNamedChildCount()) : (i += 1) {
            const item = node.getNamedChild(i);
            if (!std.mem.eql(u8, item.getType(), "list_item")) continue;
            const li = try add_node(elem, self.arena, "li", item);
            if (child_of_type(item, "task_list_marker_checked")) |_|
                try li.set(self.arena, "checked", .{ .boolean = true })
            else if (child_of_type(item, "task_list_marker_unchecked")) |_|
                try li.set(self.arena, "checked", .{ .boolean = false });
            for (try self.item_blocks(item)) |b| {
                if (!loose and std.mem.eql(u8, b.getType(), "paragraph")) {
                    if (child_of_type(b, "inline")) |content| try self.inline_content(li, content);
                } else try self.block(li, b);
            }
        }
    }

    fn set_included_ranges(self: *Builder, ranges: []const Range) Error!void {
        const Parser = @typeInfo(@TypeOf(self.inline_syn.parser)).pointer.child;
        if (!Parser.externs.ts_parser_set_included_ranges(self.inline_syn.parser, ranges.ptr, @intCast(ranges.len)))
            return error.ParseFailed;
    }

    /// parse inline content in `ranges` and add it to `elem`
    fn inline_ranges(self: *Builder, elem: *ElementBuilder, ranges: []const Range) Error!void {
        if (ranges.len == 0) return;
        try self.set_included_ranges(ranges);
        const tree = self.inline_syn.parser.parseString(null, self.src) catch return error.ParseFailed;
        defer tree.destroy();
        self.included = ranges;
        defer self.included = &.{};
        const top = tree.getRootNode();
        const first = elem.children.items.len;
        try self.container(elem, top, ranges[0].start_byte, ranges[ranges.len - 1].end_byte);
        try normalize(self.arena, elem, first);
    }

    fn inline_content(self: *Builder, elem: *ElementBuilder, node: Node) Error!void {
        return self.inline_ranges(elem, try self.content_ranges(node));
    }

    /// add the source bytes in [start, end) that are inside the included ranges
    fn add_source(self: *const Builder, elem: *ElementBuilder, start: usize, end: usize) error{OutOfMemory}!void {
        for (self.included) |r| {
            const s = @max(start, r.start_byte);
            const e = @min(end, r.end_byte);
            if (s < e) try elem.add_text(self.arena, self.src[s..e]);
        }
    }

    fn source_text(self: *const Builder, start: usize, end: usize) error{OutOfMemory}![]const u8 {
        var tmp: ElementBuilder = .{ .tag = "", .sloc = .{ start, end } };
        try self.add_source(&tmp, start, end);
        return if (tmp.children.items.len > 0) tmp.children.items[0].text.items else "";
    }

    /// walk an inline node: text between the children, markup children as elements
    fn container(self: *Builder, elem: *ElementBuilder, node: Node, start: usize, end: usize) Error!void {
        const eql = std.mem.eql;
        var pos = start;
        var i: u32 = 0;
        while (i < node.getChildCount()) : (i += 1) {
            const child = node.getChild(i);
            const t = child.getType();
            const cs = child.getStartByte();
            const ce = child.getEndByte();
            if (eql(u8, t, "emphasis_delimiter") or eql(u8, t, "code_span_delimiter")) {
                try self.add_source(elem, pos, cs);
                pos = ce;
                continue;
            }
            if (!child.isNamed()) continue;
            const handled = try self.inline_node(elem, child, pos);
            if (handled) pos = ce;
        }
        try self.add_source(elem, pos, end);
    }

    /// add a markup node, returns false if the node stays text
    fn inline_node(self: *Builder, elem: *ElementBuilder, child: Node, pos: usize) Error!bool {
        const eql = std.mem.eql;
        const t = child.getType();
        const cs = child.getStartByte();
        const ce = child.getEndByte();
        if (eql(u8, t, "emphasis") or eql(u8, t, "strong_emphasis") or eql(u8, t, "strikethrough")) {
            try self.add_source(elem, pos, cs);
            const tag: []const u8 = if (eql(u8, t, "emphasis")) "em" else if (eql(u8, t, "strong_emphasis")) "strong" else "del";
            const target = if (elem.is(tag) and eql(u8, tag, "del")) elem else try add_node(elem, self.arena, tag, child);
            try self.container(target, child, cs, ce);
        } else if (eql(u8, t, "code_span")) {
            try self.add_source(elem, pos, cs);
            const code = try add_node(elem, self.arena, "code", child);
            try code.add_text(self.arena, try self.code_span_text(child));
        } else if (eql(u8, t, "inline_link")) {
            try self.add_source(elem, pos, cs);
            const a = try add_node(elem, self.arena, "a", child);
            try a.set(self.arena, "href", .{ .string = if (child_of_type(child, "link_destination")) |d| try self.destination(d) else "" });
            if (child_of_type(child, "link_title")) |ti| try a.set(self.arena, "title", .{ .string = try self.title(ti) });
            if (child_of_type(child, "link_text")) |lt| try self.container(a, lt, lt.getStartByte(), lt.getEndByte());
        } else if (eql(u8, t, "full_reference_link") or eql(u8, t, "collapsed_reference_link") or eql(u8, t, "shortcut_link")) {
            const lt = child_of_type(child, "link_text");
            const label = child_of_type(child, "link_label") orelse lt orelse return false;
            const def = self.definitions.get(try self.normalize_label(try self.source_text(label.getStartByte(), label.getEndByte()))) orelse return false;
            try self.add_source(elem, pos, cs);
            const a = try add_node(elem, self.arena, "a", child);
            try a.set(self.arena, "href", .{ .string = def.href });
            if (def.title) |ti| try a.set(self.arena, "title", .{ .string = ti });
            if (lt) |l| try self.container(a, l, l.getStartByte(), l.getEndByte());
        } else if (eql(u8, t, "image")) {
            try self.add_source(elem, pos, cs);
            const img = try add_node(elem, self.arena, "img", child);
            try img.set(self.arena, "src", .{ .string = if (child_of_type(child, "link_destination")) |d| try self.destination(d) else "" });
            var alt: ElementBuilder = .{ .tag = "", .sloc = .{ cs, ce } };
            if (child_of_type(child, "image_description")) |d| try self.container(&alt, d, d.getStartByte(), d.getEndByte());
            try img.set(self.arena, "alt", .{ .string = try plain_text(self.arena, &alt) });
            if (child_of_type(child, "link_title")) |ti| try img.set(self.arena, "title", .{ .string = try self.title(ti) });
        } else if (eql(u8, t, "uri_autolink") or eql(u8, t, "email_autolink")) {
            try self.add_source(elem, pos, cs);
            const inner = self.src[cs + 1 .. ce - 1];
            const a = try add_node(elem, self.arena, "a", child);
            const href = if (eql(u8, t, "email_autolink")) try std.mem.concat(self.arena, u8, &.{ "mailto:", inner }) else inner;
            try a.set(self.arena, "href", .{ .string = href });
            try a.add_text(self.arena, inner);
        } else if (eql(u8, t, "backslash_escape")) {
            try self.add_source(elem, pos, cs);
            try elem.add_text(self.arena, self.src[cs + 1 .. ce]);
        } else if (eql(u8, t, "entity_reference") or eql(u8, t, "numeric_character_reference")) {
            try self.add_source(elem, pos, cs);
            try elem.add_text(self.arena, try decode_entity(self.arena, self.src[cs..ce]) orelse self.src[cs..ce]);
        } else if (eql(u8, t, "html_tag")) {
            try self.add_source(elem, pos, cs);
            const raw = self.src[cs..ce];
            if (is_br_tag(raw))
                _ = try add_node(elem, self.arena, "br", child)
            else
                try (try add_node(elem, self.arena, "html", child)).add_text(self.arena, raw);
        } else if (eql(u8, t, "hard_line_break")) {
            try self.add_source(elem, pos, cs);
            _ = try add_node(elem, self.arena, "br", child);
        } else return false;
        return true;
    }

    fn code_span_text(self: *const Builder, node: Node) error{OutOfMemory}![]const u8 {
        var start = node.getStartByte();
        var end = node.getEndByte();
        var i: u32 = 0;
        while (i < node.getChildCount()) : (i += 1) {
            const child = node.getChild(i);
            if (!std.mem.eql(u8, child.getType(), "code_span_delimiter")) continue;
            if (child.getStartByte() == start) start = child.getEndByte() else end = child.getStartByte();
        }
        const raw = try self.source_text(start, @max(start, end));
        const out = try self.arena.dupe(u8, raw);
        for (out) |*c| if (c.* == '\n' or c.* == '\r') {
            c.* = ' ';
        };
        if (out.len >= 2 and out[0] == ' ' and out[out.len - 1] == ' ' and std.mem.trim(u8, out, " ").len > 0)
            return out[1 .. out.len - 1];
        return out;
    }
};

const heading_tags = [_][]const u8{ "h1", "h2", "h3", "h4", "h5", "h6" };

/// `<br>`, `<br/>` or `<br />`, in any case
fn is_br_tag(raw: []const u8) bool {
    if (raw.len < 4 or raw[0] != '<' or raw[raw.len - 1] != '>') return false;
    const inner = std.mem.trim(u8, raw[1 .. raw.len - 1], " \t/");
    return std.ascii.eqlIgnoreCase(inner, "br");
}

fn strip_code_indent(code: []const u8) []const u8 {
    if (std.mem.startsWith(u8, code, "\t")) return code[1..];
    var n: usize = 0;
    while (n < 4 and n < code.len and code[n] == ' ') n += 1;
    return code[n..];
}

/// drop the optional closing `#` sequence of an ATX heading
fn strip_closing_sequence(h: *ElementBuilder) void {
    if (h.children.items.len == 0) return;
    const last = &h.children.items[h.children.items.len - 1];
    if (last.* != .text) return;
    const s = std.mem.trimEnd(u8, last.text.items, " \t");
    const hashes = std.mem.trimEnd(u8, s, "#");
    if (hashes.len == s.len) return;
    if (hashes.len > 0 and hashes[hashes.len - 1] != ' ' and hashes[hashes.len - 1] != '\t') return;
    last.text.shrinkRetainingCapacity(std.mem.trimEnd(u8, hashes, " \t").len);
}

fn trim_final_newline(s: []const u8) []const u8 {
    if (std.mem.endsWith(u8, s, "\r\n")) return s[0 .. s.len - 2];
    if (std.mem.endsWith(u8, s, "\n")) return s[0 .. s.len - 1];
    return s;
}

fn is_inline_tag(tag: []const u8) bool {
    const tags = [_][]const u8{ "em", "strong", "del", "a", "html" };
    for (tags) |t| if (std.mem.eql(u8, tag, t)) return true;
    return false;
}

/// turn soft line breaks into spaces and trim the edges of a block's inline content
fn normalize(arena: Allocator, elem: *ElementBuilder, first: usize) error{OutOfMemory}!void {
    try collapse_breaks(arena, elem, first);
    const items = elem.children.items[first..];
    for (items, 0..) |*child, i| switch (child.*) {
        .text => |*t| {
            const at_start = i == 0 or (items[i - 1] == .elem and items[i - 1].elem.is("br"));
            const at_end = i == items.len - 1 or (items[i + 1] == .elem and items[i + 1].elem.is("br"));
            var s: []const u8 = t.items;
            if (at_start) s = std.mem.trimStart(u8, s, " \t");
            if (at_end) s = std.mem.trimEnd(u8, s, " \t");
            const off = @intFromPtr(s.ptr) - @intFromPtr(t.items.ptr);
            std.mem.copyForwards(u8, t.items[0..s.len], t.items[off..][0..s.len]);
            t.shrinkRetainingCapacity(s.len);
        },
        .elem => {},
    };
    var i: usize = first;
    while (i < elem.children.items.len) {
        if (elem.children.items[i] == .text and elem.children.items[i].text.items.len == 0)
            _ = elem.children.orderedRemove(i)
        else
            i += 1;
    }
}

fn collapse_breaks(arena: Allocator, elem: *ElementBuilder, first: usize) error{OutOfMemory}!void {
    for (elem.children.items[first..]) |*child| switch (child.*) {
        .text => |*t| {
            var out: std.ArrayList(u8) = .empty;
            var i: usize = 0;
            while (i < t.items.len) : (i += 1) {
                const c = t.items[i];
                if (c != '\n' and c != '\r') {
                    try out.append(arena, c);
                    continue;
                }
                while (out.items.len > 0 and (out.getLast() == ' ' or out.getLast() == '\t')) _ = out.pop();
                while (i + 1 < t.items.len and std.mem.indexOfScalar(u8, " \t\r\n", t.items[i + 1]) != null) i += 1;
                try out.append(arena, ' ');
            }
            t.* = out;
        },
        .elem => |e| if (is_inline_tag(e.tag)) try collapse_breaks(arena, e, 0),
    };
}

fn plain_text(arena: Allocator, elem: *const ElementBuilder) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try append_plain_text(arena, &out, elem);
    return out.items;
}

fn append_plain_text(arena: Allocator, out: *std.ArrayList(u8), elem: *const ElementBuilder) error{OutOfMemory}!void {
    for (elem.children.items) |child| switch (child) {
        .text => |t| try out.appendSlice(arena, t.items),
        .elem => |e| try append_plain_text(arena, out, e),
    };
}

const entities = [_]struct { []const u8, []const u8 }{
    .{ "amp", "&" },
    .{ "lt", "<" },
    .{ "gt", ">" },
    .{ "quot", "\"" },
    .{ "apos", "'" },
    .{ "nbsp", "\u{a0}" },
    .{ "ensp", "\u{2002}" },
    .{ "emsp", "\u{2003}" },
    .{ "thinsp", "\u{2009}" },
    .{ "copy", "©" },
    .{ "reg", "®" },
    .{ "trade", "™" },
    .{ "hellip", "…" },
    .{ "mdash", "\u{2014}" },
    .{ "ndash", "–" },
    .{ "laquo", "«" },
    .{ "raquo", "»" },
    .{ "lsquo", "‘" },
    .{ "rsquo", "’" },
    .{ "ldquo", "“" },
    .{ "rdquo", "”" },
    .{ "bull", "•" },
    .{ "middot", "·" },
    .{ "times", "×" },
    .{ "divide", "÷" },
    .{ "deg", "°" },
    .{ "plusmn", "±" },
    .{ "para", "¶" },
    .{ "sect", "§" },
    .{ "larr", "←" },
    .{ "rarr", "→" },
    .{ "uarr", "↑" },
    .{ "darr", "↓" },
    .{ "harr", "↔" },
    .{ "lArr", "⇐" },
    .{ "rArr", "⇒" },
};

/// decode `&name;`, `&#123;` or `&#x1f;`, null if unknown
fn decode_entity(arena: Allocator, ref: []const u8) error{OutOfMemory}!?[]const u8 {
    if (ref.len < 3 or ref[0] != '&' or ref[ref.len - 1] != ';') return null;
    const name = ref[1 .. ref.len - 1];
    if (name[0] == '#') {
        const cp = (if (name.len > 1 and (name[1] == 'x' or name[1] == 'X'))
            std.fmt.parseInt(u21, name[2..], 16)
        else
            std.fmt.parseInt(u21, name[1..], 10)) catch return null;
        const char: u21 = if (cp == 0 or !std.unicode.utf8ValidCodepoint(cp)) 0xfffd else cp;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(char, &buf) catch return null;
        return try arena.dupe(u8, buf[0..len]);
    }
    for (entities) |e| if (std.mem.eql(u8, e[0], name)) return e[1];
    return null;
}
