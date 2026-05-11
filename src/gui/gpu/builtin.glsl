//------------------------------------------------------------------------------
// builtin.glsl - sokol-shdc source for the builtin grid shader.
//
// Vertex stage:  full-screen quad from gl_VertexIndex (no vertex buffer needed)
// Fragment stage: cell-grid renderer - reads a RGBA32UI cell texture and an
//                 RGBA8 glyph-atlas texture and blends fg over bg per pixel.
//                 The glyph atlas carries one of three formats per glyph,
//                 encoded in deco bits 3..2: alpha (R-channel coverage),
//                 subpixel (per-channel RGB coverage), or premultiplied RGBA
//                 color.
//------------------------------------------------------------------------------
@ctype vec4 [4]f32

@vs vs
void main() {
    int id = gl_VertexIndex;
    float x = 2.0 * (float(id & 1) - 0.5);
    float y = -(float(id >> 1) - 0.5) * 2.0;
    gl_Position = vec4(x, y, 0.0, 1.0);
}
@end

@fs fs
layout(binding=0) uniform fs_params {
    ivec4 cell_size;      // .xy = cell px size, .zw = col_count, row_count
    ivec4 viewport;       // .x = viewport_height, .yzw = pad
    ivec4 cursor_pos;     // .x = col, .y = row, .z = shape, .w = vis
    ivec4 underline_info; // .x = position, .y = thickness, .zw = pad
    vec4 cursor_color;
    vec4 sec_cursor_color;
    vec4 bg_color;
};

layout(binding=0) uniform texture2D glyph_tex;
layout(binding=1) uniform utexture2D cell_tex;
layout(binding=0) uniform sampler glyph_smp;
layout(binding=1) uniform sampler cell_smp;

@image_sample_type glyph_tex unfilterable_float
@sampler_type glyph_smp nonfiltering
@sampler_type cell_smp nonfiltering

out vec4 frag_color;

vec4 unpack_rgba(uint v) {
    return vec4(
        float((v >> 24u) & 255u) / 255.0,
        float((v >> 16u) & 255u) / 255.0,
        float((v >>  8u) & 255u) / 255.0,
        float( v         & 255u) / 255.0
    );
}

void main() {
    int cell_size_x = cell_size.x;
    int cell_size_y = cell_size.y;
    int col_count = cell_size.z;
    int row_count = cell_size.w;
    int viewport_height = viewport.x;
    int cursor_col = cursor_pos.x;
    int cursor_row = cursor_pos.y;
    int cursor_shape = cursor_pos.z;
    int cursor_vis = cursor_pos.w;
    int underline_position = underline_info.x;
    int underline_thickness = underline_info.y;

    // Convert gl_FragCoord (bottom-left origin) to top-left origin.
    int px = int(gl_FragCoord.x);
    int py = viewport_height - 1 - int(gl_FragCoord.y);
    int col = px / cell_size_x;
    int row = py / cell_size_y;

    if (col >= col_count || row >= row_count || row < 0 || col < 0) {
        frag_color = vec4(bg_color.rgb, 1.0);
        return;
    }

    // Fetch cell: texel = (glyph_index, bg_packed, fg_packed, deco)
    uvec4 cell = texelFetch(usampler2D(cell_tex, cell_smp), ivec2(col, row), 0);
    vec4 bg = unpack_rgba(cell.g);
    vec4 fg = unpack_rgba(cell.b);

    // Pixel coordinates within the cell
    int cell_px_x = px % cell_size_x;
    int cell_px_y = py % cell_size_y;

    // Glyph atlas lookup
    ivec2 atlas_size = textureSize(sampler2D(glyph_tex, glyph_smp), 0);
    int cells_per_row = atlas_size.x / cell_size_x;
    int gi = int(cell.r);
    int gc = gi % cells_per_row;
    int gr = gi / cells_per_row;
    ivec2 atlas_coord = ivec2(gc * cell_size_x + cell_px_x,
                              gr * cell_size_y + cell_px_y);
    vec4 glyph_sample = texelFetch(sampler2D(glyph_tex, glyph_smp), atlas_coord, 0);

    // Decoration field (bits: 31..8=ul_color RRGGBB, 7..5=ul_style,
    // 4=strikethrough, 3..2=glyph_kind, 0=secondary cursor flag)
    uint deco = cell.a;
    uint ul_style = (deco >> 5u) & 7u;
    bool strike = ((deco >> 4u) & 1u) != 0u;
    uint glyph_kind = (deco >> 2u) & 3u;
    uint ul_packed = deco >> 8u;

    // Cursor detection
    bool is_primary   = (cursor_vis != 0) && (col == cursor_col) && (row == cursor_row);
    bool is_secondary = (deco & 1u) != 0u;

    vec3 final_bg = bg.rgb;
    vec3 final_fg = fg.rgb;

    if (is_primary || is_secondary) {
        vec4 cur = is_primary ? cursor_color : sec_cursor_color;
        int shape = cursor_shape;

        if (shape == 1) {
            // Beam: 2px vertical bar at left edge of cell
            if (cell_px_x < 2) { frag_color = vec4(cur.rgb, 1.0); return; }
        } else if (shape == 2) {
            // Underline: 2px horizontal bar at bottom of cell
            if (cell_px_y >= cell_size_y - 2) { frag_color = vec4(cur.rgb, 1.0); return; }
        } else {
            // Block: cursor colour as bg, inverted for glyph contrast
            final_bg = cur.rgb;
            final_fg = vec3(1.0) - cur.rgb;
        }
    }

    vec3 composed;
    if (glyph_kind == 0u) {
        // Alpha coverage in the red channel; blend fg over bg.
        composed = mix(final_bg, final_fg, fg.a * glyph_sample.r);
    } else if (glyph_kind == 1u) {
        // Per-channel subpixel coverage.
        composed = vec3(
            mix(final_bg.r, final_fg.r, fg.a * glyph_sample.r),
            mix(final_bg.g, final_fg.g, fg.a * glyph_sample.g),
            mix(final_bg.b, final_fg.b, fg.a * glyph_sample.b)
        );
    } else {
        // Premultiplied RGBA color glyph composited over background.
        composed = glyph_sample.rgb + final_bg * (1.0 - glyph_sample.a);
    }

    // Underline overlay
    if (ul_style != 0u) {
        vec3 ul_rgb = (ul_packed == 0u)
            ? final_fg
            : vec3(
                float((ul_packed >> 16u) & 255u) / 255.0,
                float((ul_packed >>  8u) & 255u) / 255.0,
                float( ul_packed         & 255u) / 255.0
            );
        int thick = max(1, underline_thickness);
        int ul_top = clamp(underline_position, 0, cell_size_y - thick);
        float ul_alpha = 0.0;
        if (ul_style == 1u) {
            if ((cell_px_y >= ul_top) && (cell_px_y < ul_top + thick)) ul_alpha = 1.0;
        } else if (ul_style == 2u) {
            int upper_top = max(0, ul_top - 2 * thick);
            if (((cell_px_y >= upper_top) && (cell_px_y < upper_top + thick)) ||
                ((cell_px_y >= ul_top)    && (cell_px_y < ul_top    + thick))) ul_alpha = 1.0;
        } else if (ul_style == 3u) {
            // Curly: sine wave with Wu-style per-row antialiasing.
            int amp = max(1, cell_size_y / 16);
            float center_y = float(ul_top) + float(thick) * 0.5;
            float ph = float(cell_px_x) / float(cell_size_x) * 6.2831853;
            float wave_y = center_y + sin(ph) * float(amp);
            float half_stroke = float(thick) * 0.5;
            float dist = abs(float(cell_px_y) + 0.5 - wave_y);
            ul_alpha = clamp(half_stroke + 0.5 - dist, 0.0, 1.0);
        } else if (ul_style == 4u) {
            int period = max(2, 2 * thick);
            if ((cell_px_y >= ul_top) && (cell_px_y < ul_top + thick) &&
                ((cell_px_x % period) < (period / 2))) ul_alpha = 1.0;
        } else if (ul_style == 5u) {
            int seg = max(2, cell_size_x / 4);
            if ((cell_px_y >= ul_top) && (cell_px_y < ul_top + thick) &&
                ((cell_px_x % (2 * seg)) < seg)) ul_alpha = 1.0;
        }
        if (ul_alpha > 0.0) composed = mix(composed, ul_rgb, ul_alpha);
    }

    // Strikethrough at vertical midline (uses final_fg so it inverts under block cursor)
    if (strike) {
        int sthick = max(1, underline_thickness);
        int sy = cell_size_y / 2 - sthick / 2;
        if (cell_px_y >= sy && cell_px_y < sy + sthick) composed = final_fg;
    }

    frag_color = vec4(composed, 1.0);
}
@end

@program builtin vs fs
