//------------------------------------------------------------------------------
// builtin.glsl - sokol-shdc source for the builtin grid shader.
//
// Vertex stage:  full-screen quad from gl_VertexIndex (no vertex buffer needed)
// Fragment stage: cell-grid renderer - reads an RGBA8 cell texture (4 texels
//                 per cell: glyph_index bytes, bg color, fg color, deco
//                 bytes, stored at 4x cell-grid width) and an RGBA8
//                 glyph-atlas texture and blends fg over bg per pixel. The
//                 glyph atlas carries one of three formats per glyph,
//                 encoded in deco bits 3..2: alpha (R-channel coverage),
//                 subpixel (per-channel RGB coverage), or premultiplied
//                 RGBA color.
//------------------------------------------------------------------------------
#pragma sokol @ctype vec4 [4]f32

#pragma sokol @vs vs
// top-left = (0,0), bottom-right = (1,1) on all platforms
out vec2 v_uv;
void main() {
    int id = gl_VertexIndex;
    float u = float(id & 1);
    float v = float(id >> 1);
    v_uv = vec2(u, v);
    gl_Position = vec4(2.0 * u - 1.0, 1.0 - 2.0 * v, 0.0, 1.0);
}
#pragma sokol @end

#pragma sokol @fs fs
in vec2 v_uv;

layout(binding=0) uniform fs_params {
    ivec4 cell_size;      // .xy = cell px size, .zw = col_count, row_count
    ivec4 viewport;       // .x = viewport_height, .y = viewport_width, .zw = pad
    ivec4 underline_info; // .x = position, .y = thickness, .zw = pad
    vec4 bg_color;
};

layout(binding=0) uniform texture2D glyph_tex;
layout(binding=1) uniform texture2D cell_tex;
layout(binding=0) uniform sampler glyph_smp;
layout(binding=1) uniform sampler cell_smp;

#pragma sokol @image_sample_type glyph_tex unfilterable_float
#pragma sokol @image_sample_type cell_tex float
#pragma sokol @sampler_type glyph_smp nonfiltering
#pragma sokol @sampler_type cell_smp nonfiltering

out vec4 frag_color;

void main() {
    int cell_size_x = cell_size.x;
    int cell_size_y = cell_size.y;
    int col_count = cell_size.z;
    int row_count = cell_size.w;
    int viewport_height = viewport.x;
    int viewport_width = viewport.y;
    int underline_position = underline_info.x;
    int underline_thickness = underline_info.y;

    // v_uv: (0,0) top-left, (1,1) bottom-right — portable across GL/D3D.
    int px = int(v_uv.x * float(viewport_width));
    int py = int(v_uv.y * float(viewport_height));
    int col = px / cell_size_x;
    int row = py / cell_size_y;

    if (col >= col_count || row >= row_count || row < 0 || col < 0) {
        frag_color = vec4(bg_color.rgb, bg_color.a);
        return;
    }

    // Fetch the 4 RGBA8 texels that make up this cell.
    //   t_gi = glyph_index bytes (little-endian)
    //   bg   = bg color (RGBA8 vec4; bytes are stored ABGR per the RGBA
    //          packed-struct layout, so swizzle with .abgr to recover RGBA)
    //   fg   = fg color (same .abgr swizzle)
    //   t_dc = deco bytes (little-endian)
    ivec2 cell_base = ivec2(col * 5, row);
    vec4 t_gi = texelFetch(sampler2D(cell_tex, cell_smp), cell_base + ivec2(0, 0), 0);
    vec4 bg   = texelFetch(sampler2D(cell_tex, cell_smp), cell_base + ivec2(1, 0), 0).abgr;
    vec4 fg   = texelFetch(sampler2D(cell_tex, cell_smp), cell_base + ivec2(2, 0), 0).abgr;
    vec4 t_dc = texelFetch(sampler2D(cell_tex, cell_smp), cell_base + ivec2(3, 0), 0);
    vec4 t_cur = texelFetch(sampler2D(cell_tex, cell_smp), cell_base + ivec2(4, 0), 0);

    // Reassemble u32 fields from RGBA8 byte channels
    uint gi_u =  uint(t_gi.r * 255.0 + 0.5)
              | (uint(t_gi.g * 255.0 + 0.5) << 8u)
              | (uint(t_gi.b * 255.0 + 0.5) << 16u)
              | (uint(t_gi.a * 255.0 + 0.5) << 24u);
    uint deco =  uint(t_dc.r * 255.0 + 0.5)
              | (uint(t_dc.g * 255.0 + 0.5) << 8u)
              | (uint(t_dc.b * 255.0 + 0.5) << 16u)
              | (uint(t_dc.a * 255.0 + 0.5) << 24u);
    uint cur_packed =  uint(t_cur.r * 255.0 + 0.5)
                    | (uint(t_cur.g * 255.0 + 0.5) << 8u)
                    | (uint(t_cur.b * 255.0 + 0.5) << 16u)
                    | (uint(t_cur.a * 255.0 + 0.5) << 24u);

    // Pixel coordinates within the cell
    int cell_px_x = px % cell_size_x;
    int cell_px_y = py % cell_size_y;

    // Glyph atlas lookup
    ivec2 atlas_size = textureSize(sampler2D(glyph_tex, glyph_smp), 0);
    int cells_per_row = atlas_size.x / cell_size_x;
    int gi = int(gi_u);
    int gc = gi % cells_per_row;
    int gr = gi / cells_per_row;
    ivec2 atlas_coord = ivec2(gc * cell_size_x + cell_px_x,
                              gr * cell_size_y + cell_px_y);
    vec4 glyph_sample = texelFetch(sampler2D(glyph_tex, glyph_smp), atlas_coord, 0);

    // Decoration field (bits: 31..8=ul_color RRGGBB, 7..5=ul_style,
    // 4=strikethrough, 3..2=glyph_kind, 0=secondary cursor flag)
    uint ul_style = (deco >> 5u) & 7u;
    bool strike = ((deco >> 4u) & 1u) != 0u;
    uint glyph_kind = (deco >> 2u) & 3u;
    uint ul_packed = deco >> 8u;

    // Per-cell cursor (0 = none; low byte = shape+1, high 24 bits = RRGGBB)
    uint cur_shape = cur_packed & 255u;

    vec3 final_bg = bg.rgb;
    vec3 final_fg = fg.rgb;
    float final_a = bg.a;

    if (cur_shape != 0u) {
        vec3 cur = vec3(
            float((cur_packed >>  8u) & 255u) / 255.0,
            float((cur_packed >> 16u) & 255u) / 255.0,
            float((cur_packed >> 24u) & 255u) / 255.0
        );

        if (cur_shape == 1u) {
            // Block: cursor colour as bg, inverted for glyph contrast, always opaque
            final_bg = cur;
            final_fg = vec3(1.0) - cur;
            final_a = 1.0;
        } else if (cur_shape == 2u) {
            // Beam: 2px vertical bar at left edge of cell
            if (cell_px_x < 2) { frag_color = vec4(cur, 1.0); return; }
        } else if (cur_shape == 3u) {
            // Underline: 2px horizontal bar at bottom of cell
            if (cell_px_y >= cell_size_y - 2) { frag_color = vec4(cur, 1.0); return; }
        } else if (cur_shape == 4u) {
            // Unfocused: 2px hollow frame; cell bg (dimmed) + glyph render normally inside.
            int t = 2;
            bool on_edge =
                cell_px_x < t ||
                cell_px_x >= cell_size_x - t ||
                cell_px_y < t ||
                cell_px_y >= cell_size_y - t;
            if (on_edge) {
                vec3 dim = mix(cur, bg.rgb, 0.5);
                frag_color = vec4(dim, 1.0);
                return;
            }
        }
    }

    vec3 composed;
    if (glyph_kind == 0u) {
        // Alpha coverage in the red channel; blend fg over bg.
        float cov = fg.a * glyph_sample.r;
        composed = mix(final_bg, final_fg, cov);
        final_a = final_a + (1.0 - final_a) * cov;
    } else if (glyph_kind == 1u) {
        // Per-channel subpixel coverage.
        composed = vec3(
            mix(final_bg.r, final_fg.r, fg.a * glyph_sample.r),
            mix(final_bg.g, final_fg.g, fg.a * glyph_sample.g),
            mix(final_bg.b, final_fg.b, fg.a * glyph_sample.b)
        );
        // Approximate alpha coverage as luminance-weighted.
        float cov = fg.a * dot(glyph_sample.rgb, vec3(0.299, 0.587, 0.114));
        final_a = final_a + (1.0 - final_a) * cov;
    } else {
        // Premultiplied RGBA color glyph composited over background.
        composed = glyph_sample.rgb + final_bg * (1.0 - glyph_sample.a);
        final_a = glyph_sample.a + final_a * (1.0 - glyph_sample.a);
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
        if (ul_alpha > 0.0) {
            composed = mix(composed, ul_rgb, ul_alpha);
            final_a = final_a + (1.0 - final_a) * ul_alpha;
        }
    }

    // Strikethrough at vertical midline (uses final_fg so it inverts under block cursor)
    if (strike) {
        int sthick = max(1, underline_thickness);
        int sy = cell_size_y / 2 - sthick / 2;
        if (cell_px_y >= sy && cell_px_y < sy + sthick) {
            composed = final_fg;
            final_a = 1.0;
        }
    }

    frag_color = vec4(composed, final_a);
}
#pragma sokol @end

#pragma sokol @program builtin vs fs

// compositing program
// sample a source pixel buffer into the destination attachment, with
// global alpha. The destination region is selected by sg.applyViewport();
// this shader emits a full-viewport quad and lets the caller decide where
// it lands.

#pragma sokol @fs fs_composite
in vec2 v_uv;

layout(binding=1) uniform fs_composite_params {
    vec4 composite_alpha;  // .x = global alpha multiplier, .yzw pad
    vec4 sample_flip;      // .x = 1.0 to flip Y on sample (GL offscreen
                           // textures store bottom-origin); 0.0 otherwise.
                           // .yzw pad
};

layout(binding=2) uniform texture2D src_tex;
layout(binding=2) uniform sampler src_smp;

#pragma sokol @image_sample_type src_tex float
#pragma sokol @sampler_type src_smp filtering

out vec4 frag_color;

void main() {
    // Render-to-texture on GL stores the framebuffer bottom-up relative to
    // sampling. Sampling with v_uv directly would yield the source upside
    // down on GL; sample_flip.x is set by the host based on
    // sg.queryFeatures().origin_top_left.
    vec2 uv = vec2(v_uv.x, mix(v_uv.y, 1.0 - v_uv.y, sample_flip.x));
    vec4 s = texture(sampler2D(src_tex, src_smp), uv);
    // Straight-alpha output.
    frag_color = vec4(s.rgb, s.a * composite_alpha.x);
}
#pragma sokol @end

#pragma sokol @program composite vs fs_composite

// Identical sampling to fs_composite but emits straight (non-premultiplied) RGBA.
#pragma sokol @fs fs_present
in vec2 v_uv;

layout(binding=2) uniform fs_present_params {
    vec4 present_sample_flip;  // .x = 1.0 to flip Y on sample
};

layout(binding=3) uniform texture2D present_tex;
layout(binding=3) uniform sampler present_smp;

#pragma sokol @image_sample_type present_tex float
#pragma sokol @sampler_type present_smp filtering

out vec4 frag_color;

void main() {
    vec2 uv = vec2(v_uv.x, mix(v_uv.y, 1.0 - v_uv.y, present_sample_flip.x));
    vec4 s = texture(sampler2D(present_tex, present_smp), uv);
    // Premultiplied-alpha output
    frag_color = vec4(s.rgb * s.a, s.a);
}
#pragma sokol @end

#pragma sokol @program present vs fs_present
