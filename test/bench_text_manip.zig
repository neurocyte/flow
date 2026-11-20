const std = @import("std");
const text_manip = @import("text_manip");

const line_count = 200_000;
const needles = [_][]const u8{ "needle", "zulu", "alpha", "delta", "haystack" };
const words = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet" };

/// A line in the corpus. Offsets stay valid while the corpus grows.
const LineSpan = struct { start: usize, len: usize };

/// Hit count and an index hash, so both sides select the same lines.
const Scan = struct {
    matches: usize = 0,
    hash: u64 = 0,

    fn add(self: *Scan, index: usize) void {
        self.matches += 1;
        self.hash = (self.hash ^ @as(u64, @intCast(index))) *% 0x100000001b3;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var corpus: std.ArrayList(u8) = .empty;
    defer corpus.deinit(allocator);
    var spans: std.ArrayList(LineSpan) = .empty;
    defer spans.deinit(allocator);

    var rng: std.Random.DefaultPrng = .init(42);
    const random = rng.random();
    for (0..line_count) |_| {
        const start = corpus.items.len;
        for (0..10) |word| {
            if (word > 0) try corpus.append(allocator, ' ');
            try corpus.appendSlice(allocator, words[random.uintLessThan(usize, words.len)]);
            if (random.uintLessThan(u8, 8) == 0) try corpus.appendSlice(allocator, " needle");
        }
        try spans.append(allocator, .{ .start = start, .len = corpus.items.len - start });
    }

    // ASCII corpus: the filter skips lowercasing as in the palette.
    var sink: u64 = 0;
    sink +%= scan_compiled(corpus.items, spans.items, "warmup").hash;
    sink +%= scan_std(corpus.items, spans.items, "warmup").hash;

    var compiled_ns: i96 = 0;
    var std_ns: i96 = 0;
    for (needles) |needle| {
        const compiled_start = std.Io.Timestamp.now(init.io, .awake);
        const compiled = scan_compiled(corpus.items, spans.items, needle);
        const compiled_end = std.Io.Timestamp.now(init.io, .awake);
        compiled_ns += compiled_start.durationTo(compiled_end).toNanoseconds();

        const std_start = std.Io.Timestamp.now(init.io, .awake);
        const baseline = scan_std(corpus.items, spans.items, needle);
        const std_end = std.Io.Timestamp.now(init.io, .awake);
        std_ns += std_start.durationTo(std_end).toNanoseconds();

        // Both sides must select the same lines or the timings differ.
        if (compiled.matches != baseline.matches or compiled.hash != baseline.hash) {
            std.debug.print("mismatch on {s}: filter={d}/{x} std={d}/{x}\n", .{
                needle,
                compiled.matches,
                compiled.hash,
                baseline.matches,
                baseline.hash,
            });
            return error.Mismatch;
        }
        sink +%= compiled.hash +% baseline.hash;
    }

    const scanned: usize = corpus.items.len * needles.len;
    const ns_per_s: f64 = @floatFromInt(std.time.ns_per_s);
    const compiled_s = @as(f64, @floatFromInt(compiled_ns)) / ns_per_s;
    const std_s = @as(f64, @floatFromInt(std_ns)) / ns_per_s;
    const scanned_f: f64 = @floatFromInt(scanned);

    std.debug.print("search_lines filter vs std.ascii.findIgnoreCasePos\n", .{});
    std.debug.print("corpus: {d} lines, {d} bytes, {d} needles, {d} bytes scanned\n", .{
        line_count,
        corpus.items.len,
        needles.len,
        scanned,
    });
    std.debug.print("filter  {d:.3} s  {d:.2} GB/s\n", .{ compiled_s, scanned_f / compiled_s / 1e9 });
    std.debug.print("std     {d:.3} s  {d:.2} GB/s\n", .{ std_s, scanned_f / std_s / 1e9 });
    std.debug.print("ratio   {d:.2}x\n", .{std_s / compiled_s});
    std.debug.print("sink    {d}\n", .{sink});
}

fn scan_compiled(corpus: []const u8, spans: []const LineSpan, needle: []const u8) Scan {
    const query = text_manip.compile_query(needle);
    var scan: Scan = .{};
    for (spans, 0..) |span, index|
        if (query.matches(corpus[span.start..][0..span.len], false)) scan.add(index);
    return scan;
}

fn scan_std(corpus: []const u8, spans: []const LineSpan, needle: []const u8) Scan {
    var scan: Scan = .{};
    for (spans, 0..) |span, index|
        if (std.ascii.findIgnoreCasePos(corpus[span.start..][0..span.len], 0, needle) != null) scan.add(index);
    return scan;
}
