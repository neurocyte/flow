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
    int page_id = viewport.z; // atlas page bound for this pass
    int underline_position = underline_info.x;
    int underline_thickness = underline_info.y;

    // v_uv: (0,0) top-left, (1,1) bottom-right - portable across GL/D3D.
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

    // glyph_index packs page id (high 10 bits) and slot (low 22). Each paint
    // pass binds a single page and renders only the cells that belong to it;
    // cells on other pages are drawn by their own pass. Discarding leaves this
    // cell's pixels for the pass that owns its page.
    int page = int(gi_u >> 22u);
    int slot = int(gi_u & 0x3FFFFFu);
    if (page != page_id) { discard; }

    // Glyph atlas lookup (into the bound page)
    ivec2 atlas_size = textureSize(sampler2D(glyph_tex, glyph_smp), 0);
    int cells_per_row = atlas_size.x / cell_size_x;
    int gc = slot % cells_per_row;
    int gr = slot / cells_per_row;
    ivec2 atlas_coord = ivec2(gc * cell_size_x + cell_px_x,
                              gr * cell_size_y + cell_px_y);
    vec4 glyph_sample = texelFetch(sampler2D(glyph_tex, glyph_smp), atlas_coord, 0);

    // Decoration field (bits: 31..8=ul_color RRGGBB, 7..5=ul_style,
    // 4=strikethrough, 3..2=glyph_kind, 1=reserved, 0=glyph_alpha_from_bg)
    uint ul_style = (deco >> 5u) & 7u;
    bool strike = ((deco >> 4u) & 1u) != 0u;
    uint glyph_kind = (deco >> 2u) & 3u;
    bool fg_from_bg = (deco & 1u) != 0u;
    bool bg_transparent = ((deco >> 1u) & 1u) != 0u;
    uint ul_packed = deco >> 8u;

    // Captured before the cursor branch potentially raises final_a to 1.0.
    float cell_a = bg.a;
    float bg_fill_a = bg_transparent ? 0.0 : bg.a;

    // Per-cell cursor (0 = none; low byte = shape+1, high 24 bits = RRGGBB)
    uint cur_shape = cur_packed & 255u;

    vec3 final_bg = bg.rgb;
    vec3 final_fg = fg.rgb;
    float final_a = bg_fill_a;

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
    // Total glyph coverage of this pixel.
    float glyph_cov = 0.0;
    if (glyph_kind == 0u) {
        // Alpha coverage in the red channel; blend fg over bg.
        float cov = fg.a * glyph_sample.r;
        composed = mix(final_bg, final_fg, cov);
        final_a = final_a + (1.0 - final_a) * cov;
        glyph_cov = cov;
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
        glyph_cov = cov;
    } else {
        // Premultiplied RGBA color glyph composited over background.
        composed = glyph_sample.rgb + final_bg * (1.0 - glyph_sample.a);
        final_a = glyph_sample.a + final_a * (1.0 - glyph_sample.a);
        glyph_cov = glyph_sample.a;
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

    // When the cell opts into "glyph alpha follows bg", the glyph foreground
    // takes the styled bg alpha (cell_a) while the background fill keeps its
    // own alpha (bg_fill_a).
    if (fg_from_bg && cur_shape != 1u) final_a = mix(bg_fill_a, cell_a, glyph_cov);

    frag_color = vec4(composed, final_a);
}
#pragma sokol @end

#pragma sokol @program builtin vs fs

// Coverage (0..1, 1px feathered) of a rounded rectangle with per-corner
// rounding. `p` and `size` are in top-origin layer pixels. `cmask`
// is per-corner enable (tl, tr, br, bl).
#pragma sokol @block corner_coverage
float corner_coverage(vec2 p, vec2 size, float radius, vec4 cmask) {
    if (radius <= 0.0) return 1.0;
    float r = min(radius, min(size.x, size.y) * 0.5);
    bool left = p.x < size.x * 0.5;
    bool top  = p.y < size.y * 0.5;
    float cm = left ? (top ? cmask.x : cmask.w) : (top ? cmask.y : cmask.z);
    if (cm < 0.5) return 1.0;
    vec2 cc = vec2(left ? r : size.x - r, top ? r : size.y - r);
    vec2 d = max(vec2(left ? cc.x - p.x : p.x - cc.x,
                      top  ? cc.y - p.y : p.y - cc.y), vec2(0.0));
    return clamp(0.5 - (length(d) - r), 0.0, 1.0);
}
#pragma sokol @end

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
    vec4 round_geom;       // .xy = layer size px, .z = corner radius, .w pad
    vec4 round_mask;       // per-corner rounding enable: tl, tr, br, bl (0/1)
};

layout(binding=2) uniform texture2D src_tex;
layout(binding=2) uniform sampler src_smp;

#pragma sokol @image_sample_type src_tex float
#pragma sokol @sampler_type src_smp filtering

out vec4 frag_color;

#pragma sokol @include_block corner_coverage

void main() {
    // Render-to-texture on GL stores the framebuffer bottom-up relative to
    // sampling. Sampling with v_uv directly would yield the source upside
    // down on GL; sample_flip.x is set by the host based on
    // sg.queryFeatures().origin_top_left.
    vec2 uv = vec2(v_uv.x, mix(v_uv.y, 1.0 - v_uv.y, sample_flip.x));
    vec4 s = texture(sampler2D(src_tex, src_smp), uv);
    // geometry coverage uses the un-flipped v_uv (top-origin screen space).
    float cov = corner_coverage(v_uv * round_geom.xy, round_geom.xy, round_geom.z, round_mask);
    // Straight-alpha output.
    frag_color = vec4(s.rgb, s.a * composite_alpha.x * cov);
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

// blit_uv: copy a UV-windowed sub-rect of a source render target into a
// full-quad destination viewport. Used to snapshot the part of a layer's
// pixel buffer that sits under a src_over_blur target's footprint.

#pragma sokol @fs fs_blit_uv
in vec2 v_uv;

layout(binding=3) uniform fs_blit_uv_params {
    vec4 src_uv;           // .xy = source UV origin, .zw = source UV scale
    vec4 blit_sample_flip; // .x = 1.0 to flip Y on sample; .yzw pad
};

layout(binding=4) uniform texture2D blit_tex;
layout(binding=4) uniform sampler blit_smp;

#pragma sokol @image_sample_type blit_tex float
#pragma sokol @sampler_type blit_smp filtering

out vec4 frag_color;

void main() {
    vec2 logical = src_uv.xy + v_uv * src_uv.zw;
    vec2 uv = vec2(logical.x, mix(logical.y, 1.0 - logical.y, blit_sample_flip.x));
    frag_color = texture(sampler2D(blit_tex, blit_smp), uv);
}
#pragma sokol @end

#pragma sokol @program blit_uv vs fs_blit_uv

// blur: one Kawase pass. 4 diagonal taps at (±off.x, ±off.y) averaged. The
// bilinear sampler turns each tap into a 2x2 box, so one pass averages 16
// effective source pixels.

#pragma sokol @fs fs_blur
in vec2 v_uv;

layout(binding=4) uniform fs_blur_params {
    vec4 blur_step;         // .xy = (offset_x_uv, offset_y_uv); .zw pad
    vec4 blur_sample_flip;  // .x = 1.0 to flip Y on sample; .yzw pad
};

layout(binding=5) uniform texture2D blur_src_tex;
layout(binding=5) uniform sampler blur_src_smp;

#pragma sokol @image_sample_type blur_src_tex float
#pragma sokol @sampler_type blur_src_smp filtering

out vec4 frag_color;

void main() {
    vec2 uv = vec2(v_uv.x, mix(v_uv.y, 1.0 - v_uv.y, blur_sample_flip.x));
    vec2 off = blur_step.xy;
    vec4 s = vec4(0.0);
    s += texture(sampler2D(blur_src_tex, blur_src_smp), uv + vec2( off.x,  off.y));
    s += texture(sampler2D(blur_src_tex, blur_src_smp), uv + vec2(-off.x,  off.y));
    s += texture(sampler2D(blur_src_tex, blur_src_smp), uv + vec2( off.x, -off.y));
    s += texture(sampler2D(blur_src_tex, blur_src_smp), uv + vec2(-off.x, -off.y));
    frag_color = s * 0.25;
}
#pragma sokol @end

#pragma sokol @program blur vs fs_blur

// blur_compose: final step of src_over_blur. Samples the blurred backdrop
// and the src layer, applies post-process (contrast / brightness /
// vibrancy / noise) to the backdrop, then src_over composites src on top.
// Output is the final pixel for the dst sub-rect (written with REPLACE).

#pragma sokol @fs fs_blur_compose
in vec2 v_uv;

layout(binding=5) uniform fs_blur_compose_params {
    vec4 post0;          // .x = noise, .y = contrast, .z = brightness, .w = vibrancy
    vec4 post1;          // .x = vibrancy_darkness, .y = composite_alpha; .zw pad
    vec4 bc_sample_flip; // .x = 1.0 to flip Y on sample; .yzw pad
    vec4 round_geom;     // .xy = layer size px, .z = corner radius, .w pad
    vec4 round_mask;     // per-corner rounding enable: tl, tr, br, bl (0/1)
};

layout(binding=6) uniform texture2D backdrop_tex;
layout(binding=7) uniform texture2D bc_src_tex;
layout(binding=6) uniform sampler backdrop_smp;
layout(binding=7) uniform sampler bc_src_smp;

#pragma sokol @image_sample_type backdrop_tex float
#pragma sokol @image_sample_type bc_src_tex float
#pragma sokol @sampler_type backdrop_smp filtering
#pragma sokol @sampler_type bc_src_smp filtering

out vec4 frag_color;

// IQ-style hash for tiny per-pixel noise (no texture lookup needed).
float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 19.19);
    return fract((p3.x + p3.y) * p3.z);
}

#pragma sokol @include_block corner_coverage

void main() {
    vec2 uv = vec2(v_uv.x, mix(v_uv.y, 1.0 - v_uv.y, bc_sample_flip.x));
    vec4 bg = texture(sampler2D(backdrop_tex, backdrop_smp), uv);
    vec4 sr = texture(sampler2D(bc_src_tex, bc_src_smp), uv);

    float noise    = post0.x;
    float contrast = post0.y;
    float bright   = post0.z;
    float vib      = post0.w;
    float vib_dark = post1.x;
    float alpha_g  = post1.y;

    vec3 c = bg.rgb;
    c = (c - 0.5) * contrast + 0.5;
    c *= bright;
    float luma = dot(c, vec3(0.299, 0.587, 0.114));
    float vib_scale = mix(1.0, smoothstep(0.0, 0.5, luma), 1.0 - vib_dark);
    c = mix(vec3(luma), c, 1.0 + vib * vib_scale);
    float n = (hash12(gl_FragCoord.xy) - 0.5) * noise;
    c += vec3(n);
    c = clamp(c, 0.0, 1.0);

    float a_src = sr.a * alpha_g;
    vec3 out_rgb = sr.rgb * a_src + c * (1.0 - a_src);
    float cov = corner_coverage(v_uv * round_geom.xy, round_geom.xy, round_geom.z, round_mask);
    frag_color = vec4(out_rgb * cov, cov);
}
#pragma sokol @end

#pragma sokol @program blur_compose vs fs_blur_compose

// shadow: an analytic drop shadow drawn onto a parent (dst) layer around and
// under a child layer's footprint, before that child composites. The quad is
// the child rect expanded by `range` px on every side (plus the shadow
// offset); the fragment shader computes per-pixel alpha from the distance to
// the rounded-rect silhouette, with a power falloff over `range`, then cuts
// out the child footprint so the shadow only shows around it.
//
// `uv_rect` maps the (possibly viewport-clamped) draw area back to the full
// intended quad: pixel = full_size * (uv_rect.xy + v_uv * uv_rect.zw).
// Coordinates are top-origin (applyViewport is called with origin_top_left);
// because we synthesise geometry rather than sampling a texture, no Y-flip is
// needed.

#pragma sokol @fs fs_shadow
in vec2 v_uv;

layout(binding=6) uniform fs_shadow_params {
    vec4 color;       // straight-alpha shadow color; .a = peak opacity
    vec4 full_size;   // .xy = full quad size px; .zw pad
    vec4 cut;         // child footprint (cutout): .xy = top-left, .zw = bottom-right (quad px)
    vec4 geom;        // .x = range, .y = power, .z = radius, .w pad
    vec4 edge_mask;   // top, right, bottom, left (0/1)
    vec4 corner_mask; // top-left, top-right, bottom-right, bottom-left (0/1)
    vec4 bleed_mask;  // disabled edges a perpendicular band may extend across
                      // (top, right, bottom, left; 0/1). Otherwise the band is
                      // clipped at the layer boundary.
    vec4 uv_rect;     // .xy = uv origin, .zw = uv extent (clamp remap)
};

out vec4 frag_color;

float shadow_falloff(float d, float range, float power) {
    // d: distance outward from the silhouette outline (0 at outline).
    return pow(clamp((range - d) / range, 0.0, 1.0), power);
}

// Inside-test for a rounded rect with per-corner rounding (radius gated by
// `cmask`). Used to cut the child footprint out of the shadow.
bool in_rounded_rect(vec2 p, vec2 tl, vec2 br, float radius, vec4 cmask) {
    if (p.x < tl.x || p.x > br.x || p.y < tl.y || p.y > br.y)
        return false;
    if (radius <= 0.0)
        return true;
    radius = min(radius, min((br.x - tl.x) * 0.5, (br.y - tl.y) * 0.5));
    vec2 itl = tl + vec2(radius, radius);
    vec2 ibr = br - vec2(radius, radius);
    if (p.x >= itl.x && p.x <= ibr.x) return true; // central vertical band
    if (p.y >= itl.y && p.y <= ibr.y) return true; // central horizontal band
    float cm;
    vec2  cc;
    if (p.x < itl.x && p.y < itl.y)      { cm = cmask.x; cc = itl; }                  // tl
    else if (p.x > ibr.x && p.y < itl.y) { cm = cmask.y; cc = vec2(ibr.x, itl.y); }   // tr
    else if (p.x > ibr.x && p.y > ibr.y) { cm = cmask.z; cc = ibr; }                  // br
    else                                 { cm = cmask.w; cc = vec2(itl.x, ibr.y); }   // bl
    if (cm < 0.5) return true; // square corner: the whole bbox corner is inside
    return length(p - cc) <= radius;
}

void main() {
    float range  = geom.x;
    float power  = geom.y;
    float radius = geom.z;
    vec2  fs = full_size.xy;
    vec2  p  = fs * (uv_rect.xy + v_uv * uv_rect.zw);

    float rTL = corner_mask.x > 0.5 ? radius : 0.0;
    float rTR = corner_mask.y > 0.5 ? radius : 0.0;
    float rBR = corner_mask.z > 0.5 ? radius : 0.0;
    float rBL = corner_mask.w > 0.5 ? radius : 0.0;

    float a = 1.0;
    bool  done = false;

    // corner regions (extend inward to the arc centre so the rounded
    // outline is captured). With both adjacent edges enabled the corner gets
    // a radial falloff. With only one enabled, that edge's band extends
    // through the corner only if the other (disabled) edge allows bleed -
    // otherwise it is clipped at the layer boundary. With neither, no shadow.
    if (p.x < range + rTL && p.y < range + rTL) {
        done = true;
        bool et = edge_mask.x > 0.5, el = edge_mask.w > 0.5;
        if (et && el) {
            float d = length(p - vec2(range + rTL, range + rTL));
            a = d <= rTL ? 1.0 : shadow_falloff(d - rTL, range, power);
        } else if (et) a = bleed_mask.w > 0.5 ? shadow_falloff(range - p.y, range, power) : 0.0;
        else if (el)   a = bleed_mask.x > 0.5 ? shadow_falloff(range - p.x, range, power) : 0.0;
        else a = 0.0;
    } else if (p.x > fs.x - range - rTR && p.y < range + rTR) {
        done = true;
        bool et = edge_mask.x > 0.5, er = edge_mask.y > 0.5;
        if (et && er) {
            float d = length(p - vec2(fs.x - range - rTR, range + rTR));
            a = d <= rTR ? 1.0 : shadow_falloff(d - rTR, range, power);
        } else if (et) a = bleed_mask.y > 0.5 ? shadow_falloff(range - p.y, range, power) : 0.0;
        else if (er)   a = bleed_mask.x > 0.5 ? shadow_falloff(p.x - (fs.x - range), range, power) : 0.0;
        else a = 0.0;
    } else if (p.x > fs.x - range - rBR && p.y > fs.y - range - rBR) {
        done = true;
        bool eb = edge_mask.z > 0.5, er = edge_mask.y > 0.5;
        if (eb && er) {
            float d = length(p - vec2(fs.x - range - rBR, fs.y - range - rBR));
            a = d <= rBR ? 1.0 : shadow_falloff(d - rBR, range, power);
        } else if (eb) a = bleed_mask.y > 0.5 ? shadow_falloff(p.y - (fs.y - range), range, power) : 0.0;
        else if (er)   a = bleed_mask.z > 0.5 ? shadow_falloff(p.x - (fs.x - range), range, power) : 0.0;
        else a = 0.0;
    } else if (p.x < range + rBL && p.y > fs.y - range - rBL) {
        done = true;
        bool eb = edge_mask.z > 0.5, el = edge_mask.w > 0.5;
        if (eb && el) {
            float d = length(p - vec2(range + rBL, fs.y - range - rBL));
            a = d <= rBL ? 1.0 : shadow_falloff(d - rBL, range, power);
        } else if (eb) a = bleed_mask.w > 0.5 ? shadow_falloff(p.y - (fs.y - range), range, power) : 0.0;
        else if (el)   a = bleed_mask.z > 0.5 ? shadow_falloff(range - p.x, range, power) : 0.0;
        else a = 0.0;
    }

    if (!done) {
        // edge bands and silhouette interior
        if (p.x < range)               a = edge_mask.w > 0.5 ? shadow_falloff(range - p.x, range, power) : 0.0;
        else if (p.x > fs.x - range)   a = edge_mask.y > 0.5 ? shadow_falloff(p.x - (fs.x - range), range, power) : 0.0;
        else if (p.y < range)          a = edge_mask.x > 0.5 ? shadow_falloff(range - p.y, range, power) : 0.0;
        else if (p.y > fs.y - range)   a = edge_mask.z > 0.5 ? shadow_falloff(p.y - (fs.y - range), range, power) : 0.0;
        else                           a = 1.0;
    }

    // cut out the child footprint
    if (in_rounded_rect(p, cut.xy, cut.zw, radius, corner_mask))
        a = 0.0;

    a *= color.a;
    if (a <= 0.0)
        discard;
    frag_color = vec4(color.rgb, a);
}
#pragma sokol @end

#pragma sokol @program shadow vs fs_shadow
