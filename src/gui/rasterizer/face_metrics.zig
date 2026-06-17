const std = @import("std");

pub const FaceMetrics = struct {
    px_per_em: f64 = 16,

    advance: f64 = 8,
    ascent: f64 = 12,
    line_height: f64 = 16,
    cap_height: ?f64 = null,
    ex_height: ?f64 = null,
    ascii_height: ?f64 = null,
    ic_width: ?f64 = null,

    fn capHeightPx(m: FaceMetrics) f64 {
        if (m.cap_height) |v| if (v > 0) return v;
        return 0.75 * m.ascent;
    }
    fn exHeightPx(m: FaceMetrics) f64 {
        if (m.ex_height) |v| if (v > 0) return v;
        return 0.75 * m.capHeightPx();
    }
    fn asciiHeightPx(m: FaceMetrics) f64 {
        if (m.ascii_height) |v| if (v > 0) return v;
        return 1.5 * m.capHeightPx();
    }
    fn icWidthPx(m: FaceMetrics) f64 {
        if (m.ic_width) |v| if (v > 0) return v;
        return @min(m.asciiHeightPx(), 2.0 * m.advance);
    }
};

pub fn faceScaleFactor(primary: FaceMetrics, face: FaceMetrics) f64 {
    const ratio = blk: {
        if (face.ic_width) |v| {
            if (v > 0) break :blk (primary.icWidthPx() / primary.px_per_em) / (face.icWidthPx() / face.px_per_em);
        }
        if (face.ex_height) |v| {
            if (v > 0) break :blk (primary.exHeightPx() / primary.px_per_em) / (face.exHeightPx() / face.px_per_em);
        }
        if (face.cap_height) |v| {
            if (v > 0) break :blk (primary.capHeightPx() / primary.px_per_em) / (face.capHeightPx() / face.px_per_em);
        }
        break :blk (primary.line_height / primary.px_per_em) / (face.line_height / face.px_per_em);
    };
    if (!std.math.isFinite(ratio) or ratio <= 0) return 1.0;
    return std.math.clamp(ratio, 0.25, 4.0); // flow guard; ghostty doesn't clamp
}
