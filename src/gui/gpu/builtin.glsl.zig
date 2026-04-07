// Hand-crafted sokol_gfx ShaderDesc for the builtin grid shader.
// Targets the GLCORE backend only (OpenGL 4.10 core profile).
//
// Vertex stage:  full-screen quad from gl_VertexID (no vertex buffer needed)
// Fragment stage: cell-grid renderer — reads a RGBA32UI cell texture and an
//                 R8 glyph-atlas texture and blends fg over bg per pixel.

const sg = @import("sokol").gfx;

// Uniform block slot 0, fragment stage.
// Individual GLSL uniforms (GLCORE uses glUniform* calls, not UBOs).
pub const FsParams = extern struct {
    cell_size_x: i32,
    cell_size_y: i32,
    col_count: i32,
    row_count: i32,
    viewport_height: i32,
    // Primary cursor (position + appearance)
    cursor_col: i32,
    cursor_row: i32,
    cursor_shape: i32, // 0=block, 1=beam, 2=underline
    cursor_vis: i32, // 0=hidden, 1=visible
    cursor_color: [4]f32, // RGBA normalized [0,1]
    // Secondary cursor colour (positions encoded in ShaderCell._pad)
    sec_cursor_color: [4]f32, // RGBA normalized [0,1]
};

const vs_src =
    \\#version 330 core
    \\void main() {
    \\    int id = gl_VertexID;
    \\    float x = 2.0 * (float(id & 1) - 0.5);
    \\    float y = -(float(id >> 1) - 0.5) * 2.0;
    \\    gl_Position = vec4(x, y, 0.0, 1.0);
    \\}
;

const fs_src =
    \\#version 330 core
    \\uniform int cell_size_x;
    \\uniform int cell_size_y;
    \\uniform int col_count;
    \\uniform int row_count;
    \\uniform int viewport_height;
    \\uniform int cursor_col;
    \\uniform int cursor_row;
    \\uniform int cursor_shape;
    \\uniform int cursor_vis;
    \\uniform vec4 cursor_color;
    \\uniform vec4 sec_cursor_color;
    \\uniform sampler2D glyph_tex_glyph_smp;
    \\uniform usampler2D cell_tex_cell_smp;
    \\out vec4 frag_color;
    \\
    \\vec4 unpack_rgba(uint v) {
    \\    return vec4(
    \\        float((v >> 24u) & 255u) / 255.0,
    \\        float((v >> 16u) & 255u) / 255.0,
    \\        float((v >>  8u) & 255u) / 255.0,
    \\        float( v         & 255u) / 255.0
    \\    );
    \\}
    \\
    \\void main() {
    \\    // Convert gl_FragCoord (bottom-left origin) to top-left origin.
    \\    int px = int(gl_FragCoord.x);
    \\    int py = viewport_height - 1 - int(gl_FragCoord.y);
    \\    int col = px / cell_size_x;
    \\    int row = py / cell_size_y;
    \\
    \\    if (col >= col_count || row >= row_count || row < 0 || col < 0) {
    \\        frag_color = vec4(0.0, 0.0, 0.0, 1.0);
    \\        return;
    \\    }
    \\
    \\    // Fetch cell: texel = (glyph_index, bg_packed, fg_packed, cursor_flag)
    \\    uvec4 cell = texelFetch(cell_tex_cell_smp, ivec2(col, row), 0);
    \\    vec4 bg = unpack_rgba(cell.g);
    \\    vec4 fg = unpack_rgba(cell.b);
    \\
    \\    // Pixel coordinates within the cell
    \\    int cell_px_x = px % cell_size_x;
    \\    int cell_px_y = py % cell_size_y;
    \\
    \\    // Glyph atlas lookup
    \\    ivec2 atlas_size = textureSize(glyph_tex_glyph_smp, 0);
    \\    int cells_per_row = atlas_size.x / cell_size_x;
    \\    int gi = int(cell.r);
    \\    int gc = gi % cells_per_row;
    \\    int gr = gi / cells_per_row;
    \\    ivec2 atlas_coord = ivec2(gc * cell_size_x + cell_px_x,
    \\                              gr * cell_size_y + cell_px_y);
    \\    float glyph_alpha = texelFetch(glyph_tex_glyph_smp, atlas_coord, 0).r;
    \\
    \\    // Cursor detection
    \\    bool is_primary   = (cursor_vis != 0) && (col == cursor_col) && (row == cursor_row);
    \\    bool is_secondary = (cell.a != 0u);
    \\
    \\    vec3 final_bg = bg.rgb;
    \\    vec3 final_fg = fg.rgb;
    \\
    \\    if (is_primary || is_secondary) {
    \\        vec4 cur = is_primary ? cursor_color : sec_cursor_color;
    \\        int shape = cursor_shape;
    \\
    \\        if (shape == 1) {
    \\            // Beam: 2px vertical bar at left edge of cell
    \\            if (cell_px_x < 2) { frag_color = vec4(cur.rgb, 1.0); return; }
    \\        } else if (shape == 2) {
    \\            // Underline: 2px horizontal bar at bottom of cell
    \\            if (cell_px_y >= cell_size_y - 2) { frag_color = vec4(cur.rgb, 1.0); return; }
    \\        } else {
    \\            // Block: cursor colour as bg, inverted for glyph contrast
    \\            final_bg = cur.rgb;
    \\            final_fg = vec3(1.0) - cur.rgb;
    \\        }
    \\    }
    \\
    \\    frag_color = vec4(mix(final_bg, final_fg, fg.a * glyph_alpha), 1.0);
    \\}
;

pub fn shaderDesc(backend: sg.Backend) sg.ShaderDesc {
    var desc: sg.ShaderDesc = .{};
    switch (backend) {
        .GLCORE => {
            desc.vertex_func.source = vs_src;
            desc.fragment_func.source = fs_src;

            // Fragment uniform block: individual uniforms (GLCORE uses glUniform* calls)
            desc.uniform_blocks[0].stage = .FRAGMENT;
            desc.uniform_blocks[0].size = @sizeOf(FsParams);
            desc.uniform_blocks[0].layout = .NATIVE;
            desc.uniform_blocks[0].glsl_uniforms[0] = .{ .type = .INT, .glsl_name = "cell_size_x" };
            desc.uniform_blocks[0].glsl_uniforms[1] = .{ .type = .INT, .glsl_name = "cell_size_y" };
            desc.uniform_blocks[0].glsl_uniforms[2] = .{ .type = .INT, .glsl_name = "col_count" };
            desc.uniform_blocks[0].glsl_uniforms[3] = .{ .type = .INT, .glsl_name = "row_count" };
            desc.uniform_blocks[0].glsl_uniforms[4] = .{ .type = .INT, .glsl_name = "viewport_height" };
            desc.uniform_blocks[0].glsl_uniforms[5] = .{ .type = .INT, .glsl_name = "cursor_col" };
            desc.uniform_blocks[0].glsl_uniforms[6] = .{ .type = .INT, .glsl_name = "cursor_row" };
            desc.uniform_blocks[0].glsl_uniforms[7] = .{ .type = .INT, .glsl_name = "cursor_shape" };
            desc.uniform_blocks[0].glsl_uniforms[8] = .{ .type = .INT, .glsl_name = "cursor_vis" };
            desc.uniform_blocks[0].glsl_uniforms[9] = .{ .type = .FLOAT4, .glsl_name = "cursor_color" };
            desc.uniform_blocks[0].glsl_uniforms[10] = .{ .type = .FLOAT4, .glsl_name = "sec_cursor_color" };

            // Glyph atlas texture: R8 → sample_type = FLOAT
            desc.views[0].texture = .{
                .stage = .FRAGMENT,
                .image_type = ._2D,
                .sample_type = .FLOAT,
            };
            desc.samplers[0] = .{ .stage = .FRAGMENT, .sampler_type = .NONFILTERING };
            desc.texture_sampler_pairs[0] = .{
                .stage = .FRAGMENT,
                .view_slot = 0,
                .sampler_slot = 0,
                .glsl_name = "glyph_tex_glyph_smp",
            };

            // Cell texture: RGBA32UI → sample_type = UINT
            desc.views[1].texture = .{
                .stage = .FRAGMENT,
                .image_type = ._2D,
                .sample_type = .UINT,
            };
            desc.samplers[1] = .{ .stage = .FRAGMENT, .sampler_type = .NONFILTERING };
            desc.texture_sampler_pairs[1] = .{
                .stage = .FRAGMENT,
                .view_slot = 1,
                .sampler_slot = 1,
                .glsl_name = "cell_tex_cell_smp",
            };
        },
        else => {},
    }
    return desc;
}
