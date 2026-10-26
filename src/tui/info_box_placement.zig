pub const Side = enum { right, left };

pub const Horizontal = struct { side: Side, x: usize, w: usize };

pub fn horizontal(screen_w: usize, before: usize, after: usize, want: usize, min: usize) ?Horizontal {
    const right = screen_w -| after;
    const left = @min(before, screen_w);
    if (right >= want) return .{ .side = .right, .x = after, .w = want };
    if (left >= want) return .{ .side = .left, .x = left - want, .w = want };
    if (right >= left and right >= min) return .{ .side = .right, .x = after, .w = right };
    if (left > right and left >= min) return .{ .side = .left, .x = 0, .w = left };
    return null;
}

pub fn clamped(screen_w: usize, x: usize, want: usize) Horizontal {
    const w = @min(want, screen_w);
    return .{ .side = .right, .x = @min(x, screen_w - w), .w = w };
}

pub const Span = struct {
    start: usize,
    below: usize,
    above_end: usize = 0,
    above: usize = 0,
};

pub const Vertical = struct { y: usize, h: usize };

pub fn vertical(span: Span, want: usize) Vertical {
    if (span.below >= want or span.below >= span.above)
        return .{ .y = span.start, .h = @min(want, span.below) };
    const h = @min(want, span.above);
    return .{ .y = span.above_end - h, .h = h };
}
