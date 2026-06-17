const std = @import("std");

pub const Glyph = struct {
    pub const Size = struct {
        width: f64,
        height: f64,
        x: f64,
        y: f64,
    };
};

pub const Metrics = struct {
    cell_width: u32,
    cell_height: u32,

    face_width: f64,
    face_height: f64,

    face_y: f64,

    icon_height: f64,
    icon_height_single: f64,
};

pub const FaceInputs = struct {
    cell_width: u32,
    cell_height: u32,
    cell_baseline_from_top: f64,
    face_advance: f64,
    face_ascent: f64,
    face_descent: f64,
    face_line_gap: f64,
    cap_height: f64,
};

pub fn metricsFromFace(f: FaceInputs) Metrics {
    const cell_height_f: f64 = @floatFromInt(f.cell_height);
    const line_gap = @max(0.0, f.face_line_gap);
    const face_height = (f.face_ascent - f.face_descent) + line_gap;
    const face_baseline = (line_gap / 2.0) - f.face_descent;
    const cell_baseline = cell_height_f - f.cell_baseline_from_top;
    return .{
        .cell_width = f.cell_width,
        .cell_height = f.cell_height,
        .face_width = f.face_advance,
        .face_height = face_height,
        .face_y = cell_baseline - face_baseline,
        .icon_height = face_height,
        .icon_height_single = (2.0 * f.cap_height + face_height) / 3.0,
    };
}

pub fn metricsFromCell(cell_width: u32, cell_height: u32, face_advance: f64, cap_height: f64) Metrics {
    const ch: f64 = @floatFromInt(cell_height);
    return .{
        .cell_width = cell_width,
        .cell_height = cell_height,
        .face_width = face_advance,
        .face_height = ch,
        .face_y = 0,
        .icon_height = ch,
        .icon_height_single = (2.0 * cap_height + ch) / 3.0,
    };
}

pub const Constraint = struct {
    pub const none: Constraint = .{};

    size: Constraint.Size = .none,

    align_vertical: Align = .none,
    align_horizontal: Align = .none,

    pad_top: f64 = 0.0,
    pad_left: f64 = 0.0,
    pad_right: f64 = 0.0,
    pad_bottom: f64 = 0.0,

    relative_width: f64 = 1.0,
    relative_height: f64 = 1.0,
    relative_x: f64 = 0.0,
    relative_y: f64 = 0.0,

    max_xy_ratio: ?f64 = null,

    max_constraint_width: u2 = 2,

    height: Height = .cell,

    pub const Size = enum {
        none,
        fit, // scale down
        cover, // scale up or down
        fit_cover1, // nerd font specific
        stretch, // scale and stretch
    };

    pub const Align = enum {
        none,
        start,
        end,
        center,
        center1, // nerd font specific
    };

    pub const Height = enum {
        cell,
        icon,
    };

    pub inline fn doesAnything(self: Constraint) bool {
        return self.size != .none or
            self.align_horizontal != .none or
            self.align_vertical != .none;
    }

    pub fn constrain(
        self: Constraint,
        glyph: Glyph.Size,
        metrics: Metrics,
        constraint_width: u2, // horizontal cells
    ) Glyph.Size {
        if (!self.doesAnything()) return glyph;

        switch (self.size) {
            .stretch => {
                var m = metrics;
                m.face_width = @floatFromInt(m.cell_width);
                m.face_height = @floatFromInt(m.cell_height);
                m.face_y = 0.0;

                var c = self;
                c.pad_bottom = @max(0, c.pad_bottom);
                c.pad_top = @max(0, c.pad_top);
                c.pad_left = @max(0, c.pad_left);
                c.pad_right = @max(0, c.pad_right);

                return c.constrainInner(glyph, m, constraint_width);
            },
            else => return self.constrainInner(glyph, metrics, constraint_width),
        }
    }

    fn constrainInner(
        self: Constraint,
        glyph: Glyph.Size,
        metrics: Metrics,
        constraint_width: u2,
    ) Glyph.Size {
        const min_constraint_width: u2 = if ((self.size == .stretch) and (metrics.face_width > 0.9 * metrics.face_height))
            1
        else
            @min(self.max_constraint_width, constraint_width);

        var group: Glyph.Size = group: {
            const group_width = glyph.width / self.relative_width;
            const group_height = glyph.height / self.relative_height;
            break :group .{
                .width = group_width,
                .height = group_height,
                .x = glyph.x - (group_width * self.relative_x),
                .y = glyph.y - (group_height * self.relative_y),
            };
        };

        const width_factor, const height_factor = self.scale_factors(group, metrics, min_constraint_width);
        const center_x = group.x + (group.width / 2);
        const center_y = group.y + (group.height / 2);
        group.width *= width_factor;
        group.height *= height_factor;
        group.x = center_x - (group.width / 2);
        group.y = center_y - (group.height / 2);

        group.y = self.aligned_y(group, metrics);
        group.x = self.aligned_x(group, metrics, min_constraint_width);

        return .{
            .width = width_factor * glyph.width,
            .height = height_factor * glyph.height,
            .x = group.x + (group.width * self.relative_x),
            .y = group.y + (group.height * self.relative_y),
        };
    }

    fn scale_factors(
        self: Constraint,
        group: Glyph.Size,
        metrics: Metrics,
        min_constraint_width: u2,
    ) struct { f64, f64 } {
        if (self.size == .none) {
            return .{ 1.0, 1.0 };
        }

        const multi_cell = (min_constraint_width > 1);

        const pad_width_factor = @as(f64, @floatFromInt(min_constraint_width)) - (self.pad_left + self.pad_right);
        const pad_height_factor = 1 - (self.pad_bottom + self.pad_top);

        const target_width = pad_width_factor * metrics.face_width;
        const target_height = pad_height_factor * switch (self.height) {
            .cell => metrics.face_height,
            .icon => if (multi_cell)
                metrics.icon_height
            else
                metrics.icon_height_single,
        };

        var width_factor = target_width / group.width;
        var height_factor = target_height / group.height;

        switch (self.size) {
            .none => unreachable,
            .fit => {
                height_factor = @min(1, width_factor, height_factor);
                width_factor = height_factor;
            },
            .cover => {
                height_factor = @min(width_factor, height_factor);
                width_factor = height_factor;
            },
            .fit_cover1 => {
                height_factor = @min(width_factor, height_factor);
                if (multi_cell and (height_factor > 1)) {
                    _, const single_height_factor = self.scale_factors(group, metrics, 1);
                    height_factor = @max(1, single_height_factor);
                }
                width_factor = height_factor;
            },
            .stretch => {},
        }

        if (self.max_xy_ratio) |ratio| {
            if (group.width * width_factor > group.height * height_factor * ratio) {
                width_factor = group.height * height_factor * ratio / group.width;
            }
        }

        return .{ width_factor, height_factor };
    }

    fn aligned_y(
        self: Constraint,
        group: Glyph.Size,
        metrics: Metrics,
    ) f64 {
        if ((self.size == .none) and (self.align_vertical == .none)) {
            return group.y;
        }
        const pad_bottom_dy = self.pad_bottom * metrics.face_height;
        const pad_top_dy = self.pad_top * metrics.face_height;
        const start_y = metrics.face_y + pad_bottom_dy;
        const end_y = metrics.face_y + (metrics.face_height - group.height - pad_top_dy);
        const center_y = (start_y + end_y) / 2;
        return switch (self.align_vertical) {
            .none => if (end_y < start_y)
                center_y
            else
                @max(start_y, @min(group.y, end_y)),
            .start => start_y,
            .end => end_y,
            .center, .center1 => center_y,
        };
    }

    fn aligned_x(
        self: Constraint,
        group: Glyph.Size,
        metrics: Metrics,
        min_constraint_width: u2,
    ) f64 {
        if ((self.size == .none) and (self.align_horizontal == .none)) {
            return group.x;
        }
        const full_face_span = metrics.face_width + @as(f64, @floatFromInt((min_constraint_width - 1) * metrics.cell_width));
        const pad_left_dx = self.pad_left * metrics.face_width;
        const pad_right_dx = self.pad_right * metrics.face_width;
        const start_x = pad_left_dx;
        const end_x = full_face_span - group.width - pad_right_dx;
        return switch (self.align_horizontal) {
            .none => @max(start_x, @min(group.x, end_x)),
            .start => start_x,
            .end => @max(start_x, end_x),
            .center => @max(start_x, (start_x + end_x) / 2),
            .center1 => center1: {
                const end1_x = metrics.face_width - group.width - pad_right_dx;
                break :center1 @max(start_x, (start_x + end1_x) / 2);
            },
        };
    }
};

fn expectApproxEqual(expected: Glyph.Size, actual: Glyph.Size) !void {
    const tol = 1e-6;
    try std.testing.expectApproxEqAbs(expected.width, actual.width, tol);
    try std.testing.expectApproxEqAbs(expected.height, actual.height, tol);
    try std.testing.expectApproxEqAbs(expected.x, actual.x, tol);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, tol);
}

test "metricsFromFace reproduces reference metrics" {
    const m = metricsFromFace(.{
        .cell_width = 10,
        .cell_height = 22,
        .cell_baseline_from_top = 17,
        .face_advance = 9.6,
        .face_ascent = 16.32,
        .face_descent = -4.8,
        .face_line_gap = 0,
        .cap_height = 11.68,
    });
    const tol = 1e-9;
    try std.testing.expectEqual(@as(u32, 10), m.cell_width);
    try std.testing.expectEqual(@as(u32, 22), m.cell_height);
    try std.testing.expectApproxEqAbs(@as(f64, 9.6), m.face_width, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 21.12), m.face_height, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), m.face_y, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 21.12), m.icon_height, tol);
    try std.testing.expectApproxEqAbs(@as(f64, 44.48 / 3.0), m.icon_height_single, tol);
}

test "Constraints" {
    const GlyphSize = Glyph.Size;

    // metrics from CoreText at size 12 and DPI 96
    const metrics: Metrics = .{
        .cell_width = 10,
        .cell_height = 22,
        .icon_height = 21.12,
        .icon_height_single = 44.48 / 3.0,
        .face_width = 9.6,
        .face_height = 21.12,
        .face_y = 0.2,
    };

    // ASCII (no constraint).
    {
        const constraint: Constraint = .none;

        // 'x' from JetBrains Mono
        const glyph_x: GlyphSize = .{
            .width = 6.784,
            .height = 15.28,
            .x = 1.408,
            .y = 4.84,
        };

        inline for (.{ 1, 2 }) |constraint_width| {
            try expectApproxEqual(
                glyph_x,
                constraint.constrain(glyph_x, metrics, constraint_width),
            );
        }
    }

    // Symbol
    {
        const constraint: Constraint = .{ .size = .fit };

        // '■' (0x25A0 black square)
        const glyph_25A0: GlyphSize = .{
            .width = 10.272,
            .height = 10.272,
            .x = 2.864,
            .y = 5.304,
        };

        try expectApproxEqual(
            GlyphSize{
                .width = metrics.face_width,
                .height = metrics.face_width,
                .x = 0,
                .y = 5.64,
            },
            constraint.constrain(glyph_25A0, metrics, 1),
        );

        try expectApproxEqual(
            glyph_25A0,
            constraint.constrain(glyph_25A0, metrics, 2),
        );
    }

    // Emoji
    {
        const constraint: Constraint = .{
            .size = .cover,
            .align_horizontal = .center,
            .align_vertical = .center,
            .pad_left = 0.025,
            .pad_right = 0.025,
        };

        // '🥸' (0x1F978) from Apple Color Emoji
        const glyph_1F978: GlyphSize = .{
            .width = 20,
            .height = 20,
            .x = 0.46,
            .y = 1,
        };

        try expectApproxEqual(
            GlyphSize{
                .width = 18.72,
                .height = 18.72,
                .x = 0.44,
                .y = 1.4,
            },
            constraint.constrain(glyph_1F978, metrics, 2),
        );
    }

    // Nerd Font
    {
        const constraint: Constraint = .{
            .size = .fit_cover1,
            .height = .icon,
            .align_horizontal = .center1,
            .align_vertical = .center1,
            .relative_width = 0.7513020833333334,
            .relative_height = 0.9291573452647278,
            .relative_x = 0.0846354166666667,
            .relative_y = 0.0708426547352722,
        };

        // '' (0xEA61 nf-cod-lightbulb) from Symbols Only
        const glyph_EA61: GlyphSize = .{
            .width = 9.015625,
            .height = 13.015625,
            .x = 3.015625,
            .y = 3.76525,
        };

        try expectApproxEqual(
            GlyphSize{
                .width = 7.2125,
                .height = 10.4125,
                .x = 0.8125,
                .y = 5.950695224719102,
            },
            constraint.constrain(glyph_EA61, metrics, 1),
        );

        try expectApproxEqual(
            GlyphSize{
                .width = glyph_EA61.width,
                .height = glyph_EA61.height,
                .x = 1.015625,
                .y = 4.7483690308988775,
            },
            constraint.constrain(glyph_EA61, metrics, 2),
        );
    }

    // Nerd Font stretch
    {
        const constraint: Constraint = .{
            .size = .stretch,
            .align_horizontal = .start,
            .align_vertical = .center1,
            .pad_left = -0.025,
            .pad_right = -0.025,
            .pad_top = -0.005,
            .pad_bottom = -0.005,
        };

        // ' ' (0xE0C0 nf-ple-flame_thick) from Symbols Only
        const glyph_E0C0: GlyphSize = .{
            .width = 16.796875,
            .height = 16.46875,
            .x = -0.796875,
            .y = 1.7109375,
        };

        try expectApproxEqual(
            GlyphSize{
                .width = @floatFromInt(metrics.cell_width),
                .height = @floatFromInt(metrics.cell_height),
                .x = 0,
                .y = 0,
            },
            constraint.constrain(glyph_E0C0, metrics, 1),
        );

        try expectApproxEqual(
            GlyphSize{
                .width = @floatFromInt(2 * metrics.cell_width),
                .height = @floatFromInt(metrics.cell_height),
                .x = 0,
                .y = 0,
            },
            constraint.constrain(glyph_E0C0, metrics, 2),
        );
    }
}
