//! flow-syntax (tree-sitter) predicate validator
//!
//! This adds lua-match predicates on top of syntax.SimpleNonRegex.

const std = @import("std");
const cbor = @import("cbor");
const syntax = @import("syntax");
const match = @import("match");

const wrap_buffer_size = 4096;

pub fn Validator(comptime T: type) fn (T, cbor.Raw) bool {
    const simple = syntax.SimpleNonRegex(void);

    const local = struct {
        fn evalPredicates(predicates: cbor.Raw) cbor.Error!bool {
            var iter = predicates.bytes;
            var count = cbor.decodeArrayHeader(&iter) catch return true;
            while (count > 0) : (count -= 1) {
                var predicate: cbor.Raw = undefined;
                _ = try cbor.matchValue(&iter, cbor.extract(&predicate));
                if (!try evalPredicate(predicate)) return false;
            }
            return true;
        }

        fn evalPredicate(predicate: cbor.Raw) cbor.Error!bool {
            if (isDirective(predicate)) return true;

            var op: []const u8 = undefined;
            var capture: cbor.Raw = undefined;
            var pattern: cbor.Raw = undefined;
            if (try cbor.match(predicate.bytes, .{ cbor.extract(&op), cbor.extract(&capture), cbor.extract(&pattern) })) {
                var name = op;
                const negate = std.mem.startsWith(u8, name, "not-");
                if (negate) name = name["not-".len..];
                const any = std.mem.startsWith(u8, name, "any-");
                if (any) name = name["any-".len..];
                if (std.mem.eql(u8, name, "lua-match?")) {
                    const result = try evalLuaMatch(capture, pattern, any);
                    return if (negate) !result else result;
                }
            }
            return delegate(predicate);
        }

        fn isDirective(predicate: cbor.Raw) bool {
            var iter = predicate.bytes;
            _ = cbor.decodeArrayHeader(&iter) catch return false;
            var op: []const u8 = undefined;
            if (!(cbor.matchValue(&iter, cbor.extract(&op)) catch false)) return false;
            return std.mem.endsWith(u8, op, "!");
        }

        fn delegate(predicate: cbor.Raw) bool {
            var buf: [wrap_buffer_size]u8 = undefined;
            if (predicate.bytes.len + 1 > buf.len) return false; // too large to wrap: drop
            var writer = std.Io.Writer.fixed(&buf);
            cbor.writeValue(&writer, .{predicate}) catch return false;
            return simple({}, .{ .bytes = writer.buffered() });
        }

        fn evalLuaMatch(capture: cbor.Raw, pattern: cbor.Raw, any: bool) cbor.Error!bool {
            var pattern_text: []const u8 = undefined;
            if (!(cbor.match(pattern.bytes, cbor.extract(&pattern_text)) catch false)) return true;

            var nodes = NodeTexts.init(capture);
            while (nodes.next()) |text| {
                const is_match = luaMatches(text, pattern_text);
                if (any and is_match) return true;
                if (!any and !is_match) return false;
            }
            return !any;
        }

        fn luaMatches(text: []const u8, pattern: []const u8) bool {
            const result = match.find(text, pattern, 0) catch return false;
            return result != null;
        }

        const NodeTexts = struct {
            iter: []const u8,
            remaining: usize,

            fn init(value: cbor.Raw) NodeTexts {
                if (cbor.match(value.bytes, cbor.null_) catch false)
                    return .{ .iter = value.bytes, .remaining = 0 };
                if (cbor.match(value.bytes, cbor.string) catch false)
                    return .{ .iter = value.bytes, .remaining = 1 };
                var iter = value.bytes;
                const count = cbor.decodeArrayHeader(&iter) catch 0;
                return .{ .iter = iter, .remaining = count };
            }

            fn next(self: *NodeTexts) ?[]const u8 {
                if (self.remaining == 0) return null;
                self.remaining -= 1;
                var text: []const u8 = undefined;
                return if (cbor.matchValue(&self.iter, cbor.extract(&text)) catch false) text else null;
            }
        };
    };

    return struct {
        fn validate(_: T, predicates: cbor.Raw) bool {
            return local.evalPredicates(predicates) catch true;
        }
    }.validate;
}

test "wraps SimpleNonRegex: existing predicates still evaluated" {
    const validator = Validator(void);
    const eval = struct {
        fn eval(value: anytype) bool {
            var buf: [4096]u8 = undefined;
            return validator({}, .{ .bytes = cbor.fmt(&buf, value) });
        }
    }.eval;

    // #eq? / #not-eq?
    try std.testing.expect(eval(.{.{ "eq?", "x", "x" }}));
    try std.testing.expect(!eval(.{.{ "eq?", "y", "x" }}));
    try std.testing.expect(eval(.{.{ "not-eq?", "y", "x" }}));

    // #any-of? / #not-any-of?
    try std.testing.expect(eval(.{.{ "any-of?", "y", "x", "y" }}));
    try std.testing.expect(!eval(.{.{ "any-of?", "z", "x", "y" }}));

    // multi-node capture
    try std.testing.expect(eval(.{.{ "eq?", .{ "x", "x" }, "x" }}));
    try std.testing.expect(!eval(.{.{ "eq?", .{ "x", "y" }, "x" }}));

    // unrecognized (including regex #match?) predicates still drop the match
    try std.testing.expect(!eval(.{.{ "match?", "x", "[a-z]+" }}));

    // every predicate in a group must pass
    try std.testing.expect(eval(.{ .{ "eq?", "x", "x" }, .{ "any-of?", "y", "y", "z" } }));
    try std.testing.expect(!eval(.{ .{ "eq?", "x", "x" }, .{ "eq?", "y", "z" } }));
}

test "lua-match predicates" {
    const validator = Validator(void);
    const eval = struct {
        fn eval(value: anytype) bool {
            var buf: [4096]u8 = undefined;
            return validator({}, .{ .bytes = cbor.fmt(&buf, value) });
        }
    }.eval;

    // #lua-match?: unanchored search anywhere in the text
    try std.testing.expect(eval(.{.{ "lua-match?", "hello123", "%d+" }}));
    try std.testing.expect(!eval(.{.{ "lua-match?", "hello", "%d+" }}));
    try std.testing.expect(eval(.{.{ "lua-match?", "foobar", "^%a+$" }})); // all letters, anchored
    try std.testing.expect(!eval(.{.{ "lua-match?", "foo bar", "^%a+$" }})); // space breaks the anchor

    // #not-lua-match? negates #lua-match?
    try std.testing.expect(eval(.{.{ "not-lua-match?", "hello", "%d+" }}));
    try std.testing.expect(!eval(.{.{ "not-lua-match?", "hello123", "%d+" }}));

    // multi-node capture: #lua-match? requires every node to match
    try std.testing.expect(eval(.{.{ "lua-match?", .{ "a1", "b2" }, "%d" }}));
    try std.testing.expect(!eval(.{.{ "lua-match?", .{ "a1", "bb" }, "%d" }}));

    // #any-lua-match? requires at least one node to match
    try std.testing.expect(eval(.{.{ "any-lua-match?", .{ "aa", "b2" }, "%d" }}));
    try std.testing.expect(!eval(.{.{ "any-lua-match?", .{ "aa", "bb" }, "%d" }}));

    // #not-lua-match? == not(all match) == at least one node does NOT match
    try std.testing.expect(eval(.{.{ "not-lua-match?", .{ "a1", "bb" }, "%d" }}));
    try std.testing.expect(!eval(.{.{ "not-lua-match?", .{ "a1", "b2" }, "%d" }}));

    // #not-any-lua-match? == not(any match) == no node matches
    try std.testing.expect(eval(.{.{ "not-any-lua-match?", .{ "aa", "bb" }, "%d" }}));
    try std.testing.expect(!eval(.{.{ "not-any-lua-match?", .{ "aa", "b2" }, "%d" }}));

    // a missing capture (null) has no nodes: #lua-match? vacuously holds,
    // #any-lua-match? fails
    try std.testing.expect(eval(.{.{ "lua-match?", null, "%d" }}));
    try std.testing.expect(!eval(.{.{ "any-lua-match?", null, "%d" }}));

    // a malformed pattern counts as no match (drops a #lua-match?)
    try std.testing.expect(!eval(.{.{ "lua-match?", "abc", "%" }}));
}

test "mixed lua-match and simple predicates" {
    const validator = Validator(void);
    const eval = struct {
        fn eval(value: anytype) bool {
            var buf: [4096]u8 = undefined;
            return validator({}, .{ .bytes = cbor.fmt(&buf, value) });
        }
    }.eval;

    // both pass
    try std.testing.expect(eval(.{ .{ "eq?", "x", "x" }, .{ "lua-match?", "abc123", "%d" } }));
    // simple passes, lua-match fails
    try std.testing.expect(!eval(.{ .{ "eq?", "x", "x" }, .{ "lua-match?", "abc", "%d" } }));
    // lua-match passes, simple fails
    try std.testing.expect(!eval(.{ .{ "lua-match?", "abc123", "%d" }, .{ "eq?", "y", "z" } }));
}

test "directives (names ending in '!') are ignored and keep the match" {
    const validator = Validator(void);
    const eval = struct {
        fn eval(value: anytype) bool {
            var buf: [4096]u8 = undefined;
            return validator({}, .{ .bytes = cbor.fmt(&buf, value) });
        }
    }.eval;

    // directives should be ignored
    try std.testing.expect(eval(.{.{ "set!", "injection.language", "zig" }}));
    try std.testing.expect(eval(.{.{ "set!", "key" }}));
    try std.testing.expect(eval(.{.{ "select-adjacent!", "x", "y" }}));
    try std.testing.expect(!eval(.{.{ "match?", "x", "[a-z]+" }}));

    // a directive does not override a real predicate in the same group
    try std.testing.expect(eval(.{ .{ "set!", "k", "v" }, .{ "eq?", "x", "x" } }));
    try std.testing.expect(!eval(.{ .{ "set!", "k", "v" }, .{ "eq?", "y", "z" } }));
}
