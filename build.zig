const std = @import("std");
const builtin = @import("builtin");

const optimize_deps = .ReleaseFast;

pub const Renderer = enum { terminal, gui };

pub fn build(b: *std.Build) void {
    const all_targets = b.option(bool, "all-targets", "Build all known good targets during release builds (default: no)") orelse false;
    const tracy_enabled = b.option(bool, "enable-tracy", "Enable tracy client library (default: no)") orelse false;
    const use_tree_sitter = b.option(bool, "use-tree-sitter", "Enable tree-sitter (default: yes)") orelse true;
    const strip = b.option(bool, "strip", "Disable debug information (default: no)");
    const use_llvm = b.option(bool, "use-llvm", "Enable llvm backend (default: none)");
    const pie = b.option(bool, "pie", "Produce an executable with position independent code (default: none)");
    const renderer = b.option(Renderer, "renderer", "Renderer backend: terminal (default), gui") orelse .terminal;
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};
    const embed_emoji = b.option(bool, "embed-emoji", "Embed Noto Color Emoji as a built-in color glyph fallback (default: true)") orelse true;

    const run_step = b.step("run", "Run the app");
    const check_step = b.step("check", "Check the app");
    const test_step = b.step("test", "Run unit tests");
    const lint_step = b.step("lint", "Run lints");

    var version: std.Io.Writer.Allocating = .init(b.allocator);
    defer version.deinit();
    gen_version(b, &version.writer) catch |e| {
        if (b.release_mode != .off)
            std.debug.panic("gen_version failed: {any}", .{e});
        version.clearRetainingCapacity();
        version.writer.writeAll("unknown") catch {};
    };

    const release = switch (b.release_mode) {
        .off => false,
        .any => blk: {
            b.release_mode = .fast;
            break :blk true;
        },
        else => true,
    };

    return (if (release) &build_release else &build_development)(
        b,
        run_step,
        check_step,
        test_step,
        lint_step,
        tracy_enabled,
        use_tree_sitter,
        strip,
        use_llvm,
        pie,
        renderer,
        version.written(),
        all_targets,
        test_filters,
        embed_emoji,
    );
}

fn build_development(
    b: *std.Build,
    run_step: *std.Build.Step,
    check_step: *std.Build.Step,
    test_step: *std.Build.Step,
    lint_step: *std.Build.Step,
    tracy_enabled: bool,
    use_tree_sitter: bool,
    strip: ?bool,
    use_llvm: ?bool,
    pie: ?bool,
    renderer: Renderer,
    version: []const u8,
    _: bool, // all_targets
    test_filters: []const []const u8,
    embed_emoji: bool,
) void {
    // The gui renderer links system GL/X11 libraries which are not available
    // via the musl sysroot, so use the native ABI when building it.
    const force_musl = builtin.os.tag == .linux and !tracy_enabled and renderer != .gui;
    const target = b.standardTargetOptions(.{ .default_target = .{ .abi = if (force_musl) .musl else null } });
    const optimize = b.standardOptimizeOption(.{});

    return build_exe(
        b,
        run_step,
        check_step,
        test_step,
        lint_step,
        target,
        optimize,
        .{},
        tracy_enabled,
        use_tree_sitter,
        strip orelse false,
        use_llvm,
        pie,
        renderer,
        version,
        test_filters,
        embed_emoji,
    );
}

fn build_release(
    b: *std.Build,
    run_step: *std.Build.Step,
    check_step: *std.Build.Step,
    test_step: *std.Build.Step,
    lint_step: *std.Build.Step,
    tracy_enabled: bool,
    use_tree_sitter: bool,
    _: ?bool, //release builds control strip
    use_llvm: ?bool,
    pie: ?bool,
    _: Renderer, //renderer
    version: []const u8,
    all_targets: bool,
    test_filters: []const []const u8,
    embed_emoji: bool,
) void {
    const targets: []const struct { std.Target.Query, Renderer } = if (all_targets) &.{
        .{ .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl }, .terminal },
        .{ .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu }, .gui },
        .{ .{ .cpu_arch = .x86, .os_tag = .linux, .abi = .musl }, .terminal },
        .{ .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl }, .terminal },
        .{ .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu }, .gui },
        .{ .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .musleabihf }, .terminal },
        .{ .{ .cpu_arch = .x86_64, .os_tag = .macos }, .terminal },
        .{ .{ .cpu_arch = .aarch64, .os_tag = .macos }, .terminal },
        .{ .{ .cpu_arch = .x86_64, .os_tag = .windows }, .terminal },
        .{ .{ .cpu_arch = .x86_64, .os_tag = .windows }, .gui },
        .{ .{ .cpu_arch = .aarch64, .os_tag = .windows }, .terminal },
        .{ .{ .cpu_arch = .aarch64, .os_tag = .windows }, .gui },
        .{ .{ .cpu_arch = .x86_64, .os_tag = .freebsd }, .terminal },
        .{ .{ .cpu_arch = .aarch64, .os_tag = .freebsd }, .terminal },
    } else blk: {
        const maybe_triple = b.option(
            []const u8,
            "target",
            "The CPU architecture, OS, and ABI to build for",
        );
        const triple = maybe_triple orelse {
            const native_target = b.resolveTargetQuery(.{}).result;
            break :blk switch (native_target.os.tag) {
                .linux => &.{
                    .{ .{ .cpu_arch = native_target.cpu.arch, .os_tag = native_target.os.tag, .abi = .musl }, .terminal },
                    .{ .{ .cpu_arch = native_target.cpu.arch, .os_tag = native_target.os.tag, .abi = null }, .gui },
                },
                .windows => &.{
                    .{ .{ .cpu_arch = native_target.cpu.arch, .os_tag = native_target.os.tag }, .terminal },
                    .{ .{ .cpu_arch = native_target.cpu.arch, .os_tag = native_target.os.tag }, .gui },
                },
                else => &.{
                    .{ .{ .cpu_arch = native_target.cpu.arch, .os_tag = native_target.os.tag }, .terminal },
                },
            };
        };
        const selected_target = std.Build.parseTargetQuery(.{
            .arch_os_abi = triple,
        }) catch |err| switch (err) {
            error.ParseFailed => @panic("unknown target"),
        };
        break :blk switch (selected_target.os_tag.?) {
            .linux => &.{
                .{ .{ .cpu_arch = selected_target.cpu_arch, .os_tag = selected_target.os_tag, .abi = .musl }, .terminal },
                .{ .{ .cpu_arch = selected_target.cpu_arch, .os_tag = selected_target.os_tag, .abi = .gnu }, .gui },
            },
            .windows => &.{
                .{ .{ .cpu_arch = selected_target.cpu_arch, .os_tag = selected_target.os_tag, .abi = selected_target.abi }, .terminal },
                .{ .{ .cpu_arch = selected_target.cpu_arch, .os_tag = selected_target.os_tag, .abi = selected_target.abi }, .gui },
            },
            else => &.{
                .{ .{ .cpu_arch = selected_target.cpu_arch, .os_tag = selected_target.os_tag, .abi = selected_target.abi }, .terminal },
            },
        };
    };
    const optimize = b.standardOptimizeOption(.{});
    const optimize_release = optimize;
    const optimize_debug = optimize;

    const write_file_step = b.addWriteFiles();
    const version_file = write_file_step.add("version", version);
    b.getInstallStep().dependOn(&b.addInstallFile(version_file, "version").step);

    for (targets) |t| {
        const renderer = t.@"1";
        const target = b.resolveTargetQuery(t.@"0");
        var triple = std.mem.splitScalar(u8, t.@"0".zigTriple(b.allocator) catch unreachable, '-');
        const arch = triple.next() orelse unreachable;
        const os = triple.next() orelse unreachable;
        const target_path = std.mem.join(b.allocator, "-", &[_][]const u8{ os, arch }) catch unreachable;
        const target_path_debug = std.mem.join(b.allocator, "-", &[_][]const u8{ os, arch, "debug" }) catch unreachable;

        build_exe(
            b,
            run_step,
            check_step,
            test_step,
            lint_step,
            target,
            optimize_release,
            .{ .dest_dir = .{ .override = .{ .custom = target_path } } },
            tracy_enabled,
            use_tree_sitter,
            true, // strip release builds
            use_llvm,
            pie,
            renderer,
            version,
            test_filters,
            embed_emoji,
        );

        build_exe(
            b,
            run_step,
            check_step,
            test_step,
            lint_step,
            target,
            optimize_debug,
            .{ .dest_dir = .{ .override = .{ .custom = target_path_debug } } },
            tracy_enabled,
            use_tree_sitter,
            false, // don't strip debug builds
            use_llvm,
            pie,
            renderer,
            version,
            test_filters,
            embed_emoji,
        );
    }
}

pub fn build_exe(
    b: *std.Build,
    run_step: *std.Build.Step,
    check_step: *std.Build.Step,
    test_step: *std.Build.Step,
    lint_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    exe_install_options: std.Build.Step.InstallArtifact.Options,
    tracy_enabled: bool,
    use_tree_sitter: bool,
    strip: bool,
    use_llvm_: ?bool,
    pie: ?bool,
    renderer: Renderer,
    version: []const u8,
    test_filters: []const []const u8,
    embed_emoji: bool,
) void {
    const use_llvm = use_llvm_ orelse if (target.result.os.tag == .linux) true else null;
    const use_lld = if (target.result.os.tag.isDarwin()) null else use_llvm;
    const is_native = target.query.isNative();
    const options = b.addOptions();
    options.addOption(bool, "enable_tracy", tracy_enabled);
    options.addOption(bool, "use_tree_sitter", use_tree_sitter);
    options.addOption(bool, "gui", renderer != .terminal);

    const options_mod = options.createModule();

    std.Io.Dir.cwd().createDir(b.graph.io, ".cache", .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => std.debug.panic("makeDir(\".cache\") failed: {any}", .{e}),
    };
    std.Io.Dir.cwd().createDir(b.graph.io, ".cache/cdb", .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => std.debug.panic("makeDir(\".cache/cdb\") failed: {any}", .{e}),
    };

    var version_info: std.Io.Writer.Allocating = .init(b.allocator);
    defer version_info.deinit();
    gen_version_info(b, target, &version_info.writer, optimize, renderer) catch |e| {
        if (b.release_mode != .off)
            std.debug.panic("gen_version failed: {any}", .{e});
        version_info.clearRetainingCapacity();
        version_info.writer.writeAll("unknown") catch {};
    };

    const wf = b.addWriteFiles();
    const version_file = wf.add("version", version);
    const version_info_file = wf.add("version_info", version_info.written());

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis_mod = vaxis_dep.module("vaxis");

    const flags_dep = b.dependency("flags", .{
        .target = target,
        .optimize = optimize,
    });

    const dizzy_dep = b.dependency("dizzy", .{
        .target = target,
        .optimize = optimize,
    });

    const diffz_dep = b.dependency("diffz", .{
        .target = target,
        .optimize = optimize,
    });

    const fuzzig_dep = b.dependency("fuzzig", .{
        .target = target,
        .optimize = optimize,
    });

    const thespian_dep = b.dependency("thespian", .{
        .target = target,
        .optimize = optimize_deps,
        .enable_tracy = tracy_enabled,
    });

    const thespian_mod = thespian_dep.module("thespian");

    const cbor_dep = thespian_dep.builder.dependency("cbor", .{
        .target = target,
        .optimize = optimize_deps,
    });
    const cbor_mod = cbor_dep.module("cbor");

    const tracy_dep = if (tracy_enabled) thespian_dep.builder.dependency("tracy", .{
        .target = target,
        .optimize = optimize,
    }) else undefined;
    const tracy_mod = if (tracy_enabled) tracy_dep.module("tracy") else b.createModule(.{
        .root_source_file = b.path("src/tracy_noop.zig"),
    });

    const zeit_dep = b.dependency("zeit", .{
        .target = target,
        .optimize = optimize,
    });
    const zeit_mod = zeit_dep.module("zeit");

    const regex_dep = b.dependency("regex", .{
        .target = target,
        .optimize = optimize,
    });
    const regex_mod = regex_dep.module("regex");

    const themes_dep = b.dependency("themes", .{});

    const syntax_dep = b.dependency("syntax", .{
        .target = target,
        .optimize = optimize_deps,
        .use_tree_sitter = use_tree_sitter,
        .@"use-llvm" = if (builtin.os.tag == .linux) true else use_llvm,
    });
    const syntax_mod = syntax_dep.module("syntax");

    const help_mod = b.createModule(.{
        .root_source_file = b.path("help.md"),
    });

    const soft_root_mod = b.createModule(.{
        .root_source_file = b.path("src/soft_root.zig"),
        .imports = &.{},
    });

    const crash_mod = b.createModule(.{
        .root_source_file = b.path("src/crash.zig"),
        .imports = &.{
            .{ .name = "soft_root", .module = soft_root_mod },
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "build_options", .module = options_mod },
        },
    });

    const time_fmt_mod = b.createModule(.{
        .root_source_file = b.path("src/time_fmt.zig"),
    });

    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .imports = &.{
            .{ .name = "cbor", .module = cbor_mod },
        },
    });

    const gui_config_mod = b.createModule(.{
        .root_source_file = b.path("src/gui_config.zig"),
        .imports = &.{
            .{ .name = "cbor", .module = cbor_mod },
        },
    });

    const file_link_mod = b.createModule(.{
        .root_source_file = b.path("src/file_link.zig"),
        .imports = &.{
            .{ .name = "soft_root", .module = soft_root_mod },
            .{ .name = "thespian", .module = thespian_mod },
        },
    });

    const file_type_config_mod = b.createModule(.{
        .root_source_file = b.path("src/file_type_config.zig"),
        .imports = &.{
            .{ .name = "soft_root", .module = soft_root_mod },
            .{ .name = "syntax", .module = syntax_mod },
        },
    });

    const argv_mod = b.createModule(.{
        .root_source_file = b.path("src/argv.zig"),
        .imports = &.{
            .{ .name = "cbor", .module = cbor_mod },
        },
    });

    const lsp_config_mod = b.createModule(.{
        .root_source_file = b.path("src/lsp_config.zig"),
        .imports = &.{
            .{ .name = "soft_root", .module = soft_root_mod },
        },
    });

    const log_mod = b.createModule(.{
        .root_source_file = b.path("src/log.zig"),
        .imports = &.{
            .{ .name = "thespian", .module = thespian_mod },
        },
    });

    const command_mod = b.createModule(.{
        .root_source_file = b.path("src/command.zig"),
        .imports = &.{
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "log", .module = log_mod },
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "soft_root", .module = soft_root_mod },
        },
    });

    const EventHandler_mod = b.createModule(.{
        .root_source_file = b.path("src/EventHandler.zig"),
        .imports = &.{
            .{ .name = "thespian", .module = thespian_mod },
        },
    });

    const VcsStatus_mod = b.createModule(.{
        .root_source_file = b.path("src/VcsStatus.zig"),
        .imports = &.{},
    });

    const VcsBlame_mod = b.createModule(.{
        .root_source_file = b.path("src/VcsBlame.zig"),
        .imports = &.{},
    });

    const color_mod = b.createModule(.{
        .root_source_file = b.path("src/color.zig"),
    });

    const xterm_mod = b.createModule(.{
        .root_source_file = b.path("src/xterm.zig"),
    });

    const match_mod = b.createModule(.{
        .root_source_file = b.path("src/match.zig"),
    });

    const syntax_validator_mod = b.createModule(.{
        .root_source_file = b.path("src/syntax_validator.zig"),
        .imports = &.{
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "syntax", .module = syntax_mod },
            .{ .name = "match", .module = match_mod },
        },
    });

    const bin_path_mod = b.createModule(.{
        .root_source_file = b.path("src/bin_path.zig"),
    });

    const snippet_mod = b.createModule(.{
        .root_source_file = b.path("src/snippet.zig"),
    });

    const lsp_types_mod = b.createModule(.{
        .root_source_file = b.path("src/lsp_types.zig"),
    });

    const TypedInt_mod = b.createModule(.{
        .root_source_file = b.path("src/TypedInt.zig"),
        .imports = &.{
            .{ .name = "cbor", .module = cbor_mod },
        },
    });

    const Buffer_mod = b.createModule(.{
        .root_source_file = b.path("src/buffer/Buffer.zig"),
        .imports = &.{
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "TypedInt", .module = TypedInt_mod },
            .{ .name = "vaxis", .module = vaxis_mod },
            .{ .name = "file_type_config", .module = file_type_config_mod },
            .{ .name = "VcsBlame", .module = VcsBlame_mod },
            .{ .name = "regex", .module = regex_mod },
            .{ .name = "config", .module = config_mod },
        },
    });

    const double_mapped_ring_buffer_mod = b.createModule(.{
        .root_source_file = b.path("src/DoubleMappedRingBuffer.zig"),
    });

    const Terminal_mod = b.createModule(.{
        .root_source_file = b.path("src/terminal/Terminal.zig"),
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis_mod },
            .{ .name = "DoubleMappedRingBuffer", .module = double_mapped_ring_buffer_mod },
            .{ .name = "xterm", .module = xterm_mod },
            .{ .name = "soft_root", .module = soft_root_mod },
        },
    });

    const input_mod = b.createModule(.{
        .root_source_file = b.path("src/renderer/vaxis/input.zig"),
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis_mod },
        },
    });

    const MouseEvent_mod = b.createModule(.{
        .root_source_file = b.path("src/MouseEvent.zig"),
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis_mod },
            .{ .name = "cbor", .module = cbor_mod },
        },
    });

    const tui_renderer_mod = b.createModule(.{
        .root_source_file = b.path("src/renderer/vaxis/renderer.zig"),
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis_mod },
            .{ .name = "input", .module = input_mod },
            .{ .name = "MouseEvent", .module = MouseEvent_mod },
            .{ .name = "theme", .module = themes_dep.module("theme") },
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "log", .module = log_mod },
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "Buffer", .module = Buffer_mod },
            .{ .name = "color", .module = color_mod },
            .{ .name = "TypedInt", .module = TypedInt_mod },
            .{ .name = "crash", .module = crash_mod },
        },
    });

    const renderer_mod = blk: {
        switch (renderer) {
            .terminal => break :blk tui_renderer_mod,
            .gui => {
                const wio_dep_lazy = b.lazyDependency("wio", .{
                    .target = target,
                    .optimize = optimize_deps,
                    .enable_opengl = true,
                });
                const sokol_dep_lazy = b.lazyDependency("sokol", .{
                    .target = target,
                    .optimize = optimize_deps,
                    .gl = switch (target.result.os.tag) {
                        .windows => false,
                        else => true,
                    },
                    .dont_link_system_libs = true,
                });

                const wio_dep = wio_dep_lazy orelse break :blk tui_renderer_mod;
                const sokol_dep = sokol_dep_lazy orelse break :blk tui_renderer_mod;

                const wio_mod = wio_dep.module("wio");
                const sokol_mod = sokol_dep.module("sokol");

                const cross_linux = target.result.os.tag == .linux and !is_native;
                const flow_gui_headers_dep = if (cross_linux)
                    b.lazyDependency("flow_gui_headers", .{}) orelse break :blk tui_renderer_mod
                else
                    null;
                if (cross_linux) {
                    const sokol_clib = sokol_dep.artifact("sokol_clib");
                    if (b.lazyDependency("wio_unix_headers", .{})) |unix_headers|
                        sokol_clib.root_module.addSystemIncludePath(unix_headers.path("."));
                    sokol_clib.root_module.addSystemIncludePath(flow_gui_headers_dep.?.path("include"));
                }

                const shdc = if (b.lazyImport(@This(), "sokol")) |sokol| sokol.shdc else break :blk tui_renderer_mod;
                const shader_mod = shdc.createModule(b, "shader", sokol_mod, .{
                    .shdc_dep = sokol_dep.builder.dependency("shdc", .{}),
                    .input = "src/gui/gpu/builtin.glsl",
                    .output = "builtin.glsl.zig",
                    .slang = switch (target.result.os.tag) {
                        .windows => .{ .hlsl5 = true },
                        else => .{ .glsl410 = true },
                    },
                    .format = .sokol_zig,
                }) catch |e| std.debug.panic("sokol-shdc createModule failed: {s}", .{@errorName(e)});

                const gui_xy_mod = b.createModule(.{ .root_source_file = b.path("src/gui/xy.zig") });
                const gui_blit_mod = b.createModule(.{
                    .root_source_file = b.path("src/gui/rasterizer/blit.zig"),
                    .target = target,
                    .optimize = .ReleaseFast,
                });
                const gui_glyph_constraint_mod = b.createModule(.{ .root_source_file = b.path("src/gui/glyph_constraint.zig") });
                const gui_face_metrics_mod = b.createModule(.{ .root_source_file = b.path("src/gui/rasterizer/face_metrics.zig") });
                const gui_cell_mod = b.createModule(.{
                    .root_source_file = b.path("src/gui/cell.zig"),
                    .imports = &.{
                        .{ .name = "color", .module = color_mod },
                    },
                });
                const gui_glyph_atlas_mod = b.createModule(.{
                    .root_source_file = b.path("src/gui/GlyphAtlas.zig"),
                    .imports = &.{
                        .{ .name = "xy", .module = gui_xy_mod },
                    },
                });
                const flow_sprite_dep = b.lazyDependency("flow_sprite", .{
                    .target = target,
                    .optimize = optimize_deps,
                }) orelse break :blk tui_renderer_mod;
                const flow_sprite_mod = flow_sprite_dep.module("sprite");

                const uucode_utils_mod = b.createModule(.{
                    .root_source_file = b.path("src/gui/uucode_utils.zig"),
                    .target = target,
                    .imports = &.{
                        .{ .name = "vaxis", .module = vaxis_mod },
                    },
                });

                const combined_rasterizer_mod = b.createModule(.{
                    .root_source_file = b.path("src/gui/rasterizer/combined.zig"),
                    .target = target,
                    .imports = &.{
                        .{ .name = "xy", .module = gui_xy_mod },
                        .{ .name = "gui_config", .module = gui_config_mod },
                        .{ .name = "glyph_constraint", .module = gui_glyph_constraint_mod },
                    },
                });

                const nerd_font_mod = blk2: {
                    const nerd_dep = b.lazyDependency("nerd_fonts", .{}) orelse break :blk2 null;
                    break :blk2 b.createModule(.{
                        .root_source_file = nerd_dep.path("SymbolsNerdFontMono-Regular.ttf"),
                    });
                };

                const noto_emoji_font_mod = blk2: {
                    const flow_fonts_dep = b.lazyDependency("flow_fonts", .{}) orelse break :blk2 null;
                    break :blk2 b.createModule(.{
                        .root_source_file = flow_fonts_dep.path("noto-emoji-2.051/Noto-COLRv1.ttf"),
                    });
                };

                if (target.result.os.tag == .windows) {
                    const win32_dep = b.lazyDependency("win32", .{}) orelse break :blk tui_renderer_mod;
                    const win32_mod = win32_dep.module("win32");
                    const dwrite_rasterizer_mod = b.createModule(.{
                        .root_source_file = b.path("src/gui/rasterizer/dwrite.zig"),
                        .target = target,
                        .imports = &.{
                            .{ .name = "xy", .module = gui_xy_mod },
                            .{ .name = "gui_config", .module = gui_config_mod },
                            .{ .name = "win32", .module = win32_mod },
                            .{ .name = "uucode_utils", .module = uucode_utils_mod },
                            .{ .name = "flow_sprite", .module = flow_sprite_mod },
                            .{ .name = "glyph_constraint", .module = gui_glyph_constraint_mod },
                            .{ .name = "face_metrics", .module = gui_face_metrics_mod },
                            .{ .name = "blit", .module = gui_blit_mod },
                        },
                    });
                    if (nerd_font_mod) |m| dwrite_rasterizer_mod.addImport("nerd_font", m);
                    combined_rasterizer_mod.addImport("dw_rasterizer", dwrite_rasterizer_mod);
                } else {
                    const tt_dep = b.lazyDependency("TrueType", .{
                        .target = target,
                        .optimize = optimize_deps,
                    }) orelse break :blk tui_renderer_mod;

                    const font_finder_mod = b.createModule(.{
                        .root_source_file = b.path("src/gui/rasterizer/font_finder.zig"),
                        .target = target,
                    });
                    if (target.result.os.tag == .linux) {
                        if (is_native) {
                            font_finder_mod.linkSystemLibrary("fontconfig", .{});
                        } else {
                            const fv = b.lazyImport(@This(), "flow_gui_headers") orelse break :blk tui_renderer_mod;
                            font_finder_mod.addObjectFile(fv.stubSharedLib(b, target, optimize, "fontconfig", 1, &fv.fontconfig_stub_symbols).getEmittedBin());
                            font_finder_mod.addIncludePath(flow_gui_headers_dep.?.path("include"));
                        }
                        font_finder_mod.link_libc = true;
                    }

                    const fallback_resolver_mod = b.createModule(.{
                        .root_source_file = b.path("src/gui/rasterizer/fallback_resolver.zig"),
                        .target = target,
                        .imports = &.{
                            .{ .name = "font_finder", .module = font_finder_mod },
                            .{ .name = "face_metrics", .module = gui_face_metrics_mod },
                        },
                    });

                    const truetype_rasterizer_mod = b.createModule(.{
                        .root_source_file = b.path("src/gui/rasterizer/truetype.zig"),
                        .target = target,
                        .imports = &.{
                            .{ .name = "soft_root", .module = soft_root_mod },
                            .{ .name = "TrueType", .module = tt_dep.module("TrueType") },
                            .{ .name = "xy", .module = gui_xy_mod },
                            .{ .name = "flow_sprite", .module = flow_sprite_mod },
                            .{ .name = "font_finder", .module = font_finder_mod },
                            .{ .name = "fallback_resolver", .module = fallback_resolver_mod },
                            .{ .name = "gui_config", .module = gui_config_mod },
                            .{ .name = "uucode_utils", .module = uucode_utils_mod },
                            .{ .name = "glyph_constraint", .module = gui_glyph_constraint_mod },
                            .{ .name = "blit", .module = gui_blit_mod },
                        },
                    });
                    if (nerd_font_mod) |m| truetype_rasterizer_mod.addImport("nerd_font", m);

                    const gui_embed_options = b.addOptions();
                    gui_embed_options.addOption(bool, "embed_emoji", embed_emoji);
                    const gui_embed_options_mod = gui_embed_options.createModule();

                    const freetype_rasterizer_mod = b.createModule(.{
                        .root_source_file = b.path("src/gui/rasterizer/freetype.zig"),
                        .target = target,
                        .imports = &.{
                            .{ .name = "xy", .module = gui_xy_mod },
                            .{ .name = "flow_sprite", .module = flow_sprite_mod },
                            .{ .name = "font_finder", .module = font_finder_mod },
                            .{ .name = "fallback_resolver", .module = fallback_resolver_mod },
                            .{ .name = "gui_config", .module = gui_config_mod },
                            .{ .name = "uucode_utils", .module = uucode_utils_mod },
                            .{ .name = "build_options", .module = gui_embed_options_mod },
                            .{ .name = "glyph_constraint", .module = gui_glyph_constraint_mod },
                            .{ .name = "blit", .module = gui_blit_mod },
                        },
                    });
                    if (nerd_font_mod) |m| freetype_rasterizer_mod.addImport("nerd_font", m);
                    if (noto_emoji_font_mod) |m| freetype_rasterizer_mod.addImport("noto_emoji_font", m);
                    if (cross_linux) {
                        const fv = b.lazyImport(@This(), "flow_gui_headers") orelse break :blk tui_renderer_mod;
                        freetype_rasterizer_mod.addObjectFile(fv.stubSharedLib(b, target, optimize, "freetype", 6, &fv.freetype_stub_symbols).getEmittedBin());
                    } else {
                        freetype_rasterizer_mod.linkSystemLibrary("freetype2", .{});
                    }
                    const freetype_dep = b.lazyDependency("freetype", .{}) orelse break :blk tui_renderer_mod;
                    freetype_rasterizer_mod.addIncludePath(freetype_dep.path("include"));
                    freetype_rasterizer_mod.link_libc = true;

                    combined_rasterizer_mod.addImport("tt_rasterizer", truetype_rasterizer_mod);
                    combined_rasterizer_mod.addImport("ft_rasterizer", freetype_rasterizer_mod);
                }

                const gpu_mod = b.createModule(.{
                    .root_source_file = b.path("src/gui/gpu/gpu.zig"),
                    .imports = &.{
                        .{ .name = "color", .module = color_mod },
                        .{ .name = "sokol", .module = sokol_mod },
                        .{ .name = "rasterizer", .module = combined_rasterizer_mod },
                        .{ .name = "xy", .module = gui_xy_mod },
                        .{ .name = "cell", .module = gui_cell_mod },
                        .{ .name = "GlyphAtlas", .module = gui_glyph_atlas_mod },
                        .{ .name = "shader", .module = shader_mod },
                    },
                });

                const nerd_font_attributes_mod = b.createModule(.{
                    .root_source_file = flow_sprite_dep.path("src/font/nerd_font_attributes.zig"),
                    .imports = &.{
                        .{ .name = "Glyph.zig", .module = b.createModule(.{
                            .root_source_file = b.path("src/gui/GlyphAdaptor.zig"),
                            .imports = &.{
                                .{ .name = "glyph_constraint", .module = gui_glyph_constraint_mod },
                            },
                        }) },
                    },
                });

                const app_mod = b.createModule(.{
                    .root_source_file = b.path("src/gui/wio/app.zig"),
                    .imports = &.{
                        .{ .name = "color", .module = color_mod },
                        .{ .name = "wio", .module = wio_mod },
                        .{ .name = "sokol", .module = sokol_mod },
                        .{ .name = "gpu", .module = gpu_mod },
                        .{ .name = "thespian", .module = thespian_mod },
                        .{ .name = "cbor", .module = cbor_mod },
                        .{ .name = "vaxis", .module = vaxis_mod },
                        .{ .name = "MouseEvent", .module = MouseEvent_mod },
                        .{ .name = "uucode_utils", .module = uucode_utils_mod },
                        .{ .name = "nerd_font_attributes", .module = nerd_font_attributes_mod },
                        .{ .name = "xterm", .module = xterm_mod },
                        .{ .name = "soft_root", .module = soft_root_mod },
                        .{ .name = "gui_config", .module = gui_config_mod },
                        .{ .name = "tuirenderer", .module = tui_renderer_mod },
                    },
                });

                if (target.result.os.tag == .windows) {
                    const win32_dep = b.lazyDependency("win32", .{}) orelse break :blk tui_renderer_mod;
                    const win32_mod = win32_dep.module("win32");
                    const d3d11_swapchain_mod = b.createModule(.{
                        .root_source_file = b.path("src/gui/wio/d3d11_swapchain.zig"),
                        .target = target,
                        .imports = &.{
                            .{ .name = "win32", .module = win32_mod },
                        },
                    });
                    app_mod.addImport("d3d11_swapchain", d3d11_swapchain_mod);
                    app_mod.addImport("win32", win32_mod);
                }

                const mod = b.createModule(.{
                    .root_source_file = b.path("src/renderer/gui/renderer.zig"),
                    .imports = &.{
                        .{ .name = "soft_root", .module = soft_root_mod },
                        .{ .name = "color", .module = color_mod },
                        .{ .name = "theme", .module = themes_dep.module("theme") },
                        .{ .name = "cbor", .module = cbor_mod },
                        .{ .name = "thespian", .module = thespian_mod },
                        .{ .name = "input", .module = input_mod },
                        .{ .name = "MouseEvent", .module = MouseEvent_mod },
                        .{ .name = "app", .module = app_mod },
                        .{ .name = "tuirenderer", .module = tui_renderer_mod },
                        .{ .name = "vaxis", .module = vaxis_mod },
                        .{ .name = "uucode_utils", .module = uucode_utils_mod },
                        .{ .name = "rasterizer", .module = combined_rasterizer_mod },
                    },
                });
                break :blk mod;
            },
        }
    };

    const keybind_mod = b.createModule(.{
        .root_source_file = b.path("src/keybind/keybind.zig"),
        .imports = &.{
            .{ .name = "soft_root", .module = soft_root_mod },
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "command", .module = command_mod },
            .{ .name = "EventHandler", .module = EventHandler_mod },
            .{ .name = "input", .module = input_mod },
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "Buffer", .module = Buffer_mod },
            .{ .name = "config", .module = config_mod },
        },
    });

    const keybind_test_run_cmd = blk: {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/keybind/keybind.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        tests.root_module.addImport("cbor", cbor_mod);
        tests.root_module.addImport("command", command_mod);
        tests.root_module.addImport("EventHandler", EventHandler_mod);
        tests.root_module.addImport("input", input_mod);
        tests.root_module.addImport("thespian", thespian_mod);
        tests.root_module.addImport("log", log_mod);
        tests.root_module.addImport("Buffer", Buffer_mod);
        tests.root_module.addImport("config", config_mod);
        tests.root_module.addImport("soft_root", soft_root_mod);
        // b.installArtifact(tests);
        break :blk b.addRunArtifact(tests);
    };

    const match_test_run_cmd = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/match.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    }));

    const glyph_constraint_test_run_cmd = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gui/glyph_constraint.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    }));

    const glyph_atlas_test_run_cmd = blk: {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/gui/GlyphAtlas.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .filters = test_filters,
        });
        tests.root_module.addImport("xy", b.createModule(.{
            .root_source_file = b.path("src/gui/xy.zig"),
        }));
        break :blk b.addRunArtifact(tests);
    };

    const terminal_screen_test_run_cmd = blk: {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/terminal/Screen.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .filters = test_filters,
        });
        tests.root_module.addImport("vaxis", vaxis_mod);
        tests.root_module.addImport("DoubleMappedRingBuffer", double_mapped_ring_buffer_mod);
        break :blk b.addRunArtifact(tests);
    };

    const double_mapped_ring_buffer_test_run_cmd = blk: {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/DoubleMappedRingBuffer.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .filters = test_filters,
        });
        break :blk b.addRunArtifact(tests);
    };

    const mouse_event_test_run_cmd = blk: {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/MouseEvent.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .filters = test_filters,
        });
        tests.root_module.addImport("vaxis", vaxis_mod);
        tests.root_module.addImport("cbor", cbor_mod);
        break :blk b.addRunArtifact(tests);
    };

    const syntax_validator_test_run_cmd = blk: {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/syntax_validator.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .filters = test_filters,
        });
        tests.root_module.addImport("cbor", cbor_mod);
        tests.root_module.addImport("syntax", syntax_mod);
        tests.root_module.addImport("match", match_mod);
        break :blk b.addRunArtifact(tests);
    };

    const shell_mod = b.createModule(.{
        .root_source_file = b.path("src/shell.zig"),
        .imports = &.{
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "log", .module = log_mod },
            .{ .name = "soft_root", .module = soft_root_mod },
        },
    });

    const git_mod = b.createModule(.{
        .root_source_file = b.path("src/git.zig"),
        .imports = &.{
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "shell", .module = shell_mod },
            .{ .name = "bin_path", .module = bin_path_mod },
            .{ .name = "soft_root", .module = soft_root_mod },
        },
    });

    const ripgrep_mod = b.createModule(.{
        .root_source_file = b.path("src/ripgrep.zig"),
        .imports = &.{
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "log", .module = log_mod },
            .{ .name = "bin_path", .module = bin_path_mod },
            .{ .name = "soft_root", .module = soft_root_mod },
        },
    });

    const location_history_mod = b.createModule(.{
        .root_source_file = b.path("src/location_history.zig"),
        .imports = &.{
            .{ .name = "thespian", .module = thespian_mod },
        },
    });

    const project_manager_mod = b.createModule(.{
        .root_source_file = b.path("src/project_manager.zig"),
        .imports = &.{
            .{ .name = "soft_root", .module = soft_root_mod },
            .{ .name = "log", .module = log_mod },
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "file_link", .module = file_link_mod },
            .{ .name = "Buffer", .module = Buffer_mod },
            .{ .name = "tracy", .module = tracy_mod },
            .{ .name = "file_type_config", .module = file_type_config_mod },
            .{ .name = "lsp_config", .module = lsp_config_mod },
            .{ .name = "dizzy", .module = dizzy_dep.module("dizzy") },
            .{ .name = "fuzzig", .module = fuzzig_dep.module("fuzzig") },
            .{ .name = "git", .module = git_mod },
            .{ .name = "VcsStatus", .module = VcsStatus_mod },
        },
    });

    const diff_mod = b.createModule(.{
        .root_source_file = b.path("src/diff.zig"),
        .imports = &.{
            .{ .name = "soft_root", .module = soft_root_mod },
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "Buffer", .module = Buffer_mod },
            .{ .name = "tracy", .module = tracy_mod },
            .{ .name = "dizzy", .module = dizzy_dep.module("dizzy") },
            .{ .name = "diffz", .module = diffz_dep.module("diffz") },
            .{ .name = "log", .module = log_mod },
            .{ .name = "cbor", .module = cbor_mod },
        },
    });

    const text_manip_mod = b.createModule(.{
        .root_source_file = b.path("src/text_manip.zig"),
        .imports = &.{},
    });

    const tui_mod = b.createModule(.{
        .root_source_file = b.path("src/tui/tui.zig"),
        .imports = &.{
            .{ .name = "soft_root", .module = soft_root_mod },
            .{ .name = "crash", .module = crash_mod },
            .{ .name = "file_link", .module = file_link_mod },
            .{ .name = "renderer", .module = renderer_mod },
            .{ .name = "input", .module = input_mod },
            .{ .name = "MouseEvent", .module = MouseEvent_mod },
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "gui_config", .module = gui_config_mod },
            .{ .name = "file_type_config", .module = file_type_config_mod },
            .{ .name = "lsp_config", .module = lsp_config_mod },
            .{ .name = "log", .module = log_mod },
            .{ .name = "command", .module = command_mod },
            .{ .name = "EventHandler", .module = EventHandler_mod },
            .{ .name = "location_history", .module = location_history_mod },
            .{ .name = "project_manager", .module = project_manager_mod },
            .{ .name = "syntax", .module = syntax_mod },
            .{ .name = "syntax_validator", .module = syntax_validator_mod },
            .{ .name = "text_manip", .module = text_manip_mod },
            .{ .name = "argv", .module = argv_mod },
            .{ .name = "Buffer", .module = Buffer_mod },
            .{ .name = "keybind", .module = keybind_mod },
            .{ .name = "shell", .module = shell_mod },
            .{ .name = "ripgrep", .module = ripgrep_mod },
            .{ .name = "theme", .module = themes_dep.module("theme") },
            .{ .name = "themes", .module = themes_dep.module("themes") },
            .{ .name = "tracy", .module = tracy_mod },
            .{ .name = "build_options", .module = options_mod },
            .{ .name = "color", .module = color_mod },
            .{ .name = "diff", .module = diff_mod },
            .{ .name = "help.md", .module = help_mod },
            .{ .name = "fuzzig", .module = fuzzig_dep.module("fuzzig") },
            .{ .name = "zeit", .module = zeit_mod },
            .{ .name = "VcsStatus", .module = VcsStatus_mod },
            .{ .name = "bin_path", .module = bin_path_mod },
            .{ .name = "snippet", .module = snippet_mod },
            .{ .name = "lsp_types", .module = lsp_types_mod },
            .{ .name = "time_fmt", .module = time_fmt_mod },
            .{ .name = "Terminal", .module = Terminal_mod },
        },
    });

    const c_step = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    const c_mod = c_step.createModule();

    const exe_name = switch (renderer) {
        .terminal => "flow",
        .gui => "flow-gui",
    };

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
        // .gui uses wio's manifest; .terminal uses ours.
        .win32_manifest = if (renderer == .terminal)
            b.path("src/win32/flow.manifest")
        else
            null,
    });

    exe.use_llvm = use_llvm;
    exe.use_lld = use_lld;

    if (pie) |value| exe.pie = value;
    exe.root_module.addImport("build_options", options_mod);
    exe.root_module.addImport("soft_root", soft_root_mod);
    exe.root_module.addImport("crash", crash_mod);
    exe.root_module.addImport("file_link", file_link_mod);
    exe.root_module.addImport("flags", flags_dep.module("flags"));
    exe.root_module.addImport("cbor", cbor_mod);
    exe.root_module.addImport("config", config_mod);
    exe.root_module.addImport("text_manip", text_manip_mod);
    exe.root_module.addImport("argv", argv_mod);
    exe.root_module.addImport("Buffer", Buffer_mod);
    exe.root_module.addImport("tui", tui_mod);
    exe.root_module.addImport("thespian", thespian_mod);
    exe.root_module.addImport("log", log_mod);
    exe.root_module.addImport("tracy", tracy_mod);
    exe.root_module.addImport("renderer", renderer_mod);
    exe.root_module.addImport("input", input_mod);
    exe.root_module.addImport("syntax", syntax_mod);
    exe.root_module.addImport("file_type_config", file_type_config_mod);
    exe.root_module.addImport("color", color_mod);
    exe.root_module.addImport("bin_path", bin_path_mod);
    exe.root_module.addImport("regex", regex_mod);
    exe.root_module.addImport("version", b.createModule(.{ .root_source_file = version_file }));
    exe.root_module.addImport("version_info", b.createModule(.{ .root_source_file = version_info_file }));

    exe.root_module.addImport("c", c_mod);

    if (target.result.os.tag == .windows) {
        exe.root_module.addWin32ResourceFile(.{
            .file = b.path("src/win32/flow.rc"),
        });
        if (renderer != .terminal) {
            exe.subsystem = .Windows;
        }
    }

    if (renderer == .gui) switch (target.result.os.tag) {
        .linux => if (is_native)
            exe.root_module.linkSystemLibrary("GL", .{})
        else if (b.lazyImport(@This(), "flow_gui_headers")) |fv|
            exe.root_module.addObjectFile(fv.stubSharedLib(b, target, optimize, "GL", 1, &fv.gl_stub_symbols).getEmittedBin()),
        .windows => {
            exe.root_module.linkSystemLibrary("d3d11", .{});
            exe.root_module.linkSystemLibrary("dxgi", .{});
            exe.root_module.linkSystemLibrary("dwrite", .{});
            exe.root_module.linkSystemLibrary("d2d1", .{});
            exe.root_module.linkSystemLibrary("ole32", .{});
        },
        else => {},
    };

    const exe_install = b.addInstallArtifact(exe, exe_install_options);
    b.getInstallStep().dependOn(&exe_install.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    run_step.dependOn(&run_cmd.step);

    const check_exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    check_exe.root_module.addImport("build_options", options_mod);
    check_exe.root_module.addImport("file_link", file_link_mod);
    check_exe.root_module.addImport("soft_root", soft_root_mod);
    check_exe.root_module.addImport("crash", crash_mod);
    check_exe.root_module.addImport("flags", flags_dep.module("flags"));
    check_exe.root_module.addImport("cbor", cbor_mod);
    check_exe.root_module.addImport("config", config_mod);
    check_exe.root_module.addImport("text_manip", text_manip_mod);
    check_exe.root_module.addImport("argv", argv_mod);
    check_exe.root_module.addImport("Buffer", Buffer_mod);
    check_exe.root_module.addImport("tui", tui_mod);
    check_exe.root_module.addImport("thespian", thespian_mod);
    check_exe.root_module.addImport("log", log_mod);
    check_exe.root_module.addImport("tracy", tracy_mod);
    check_exe.root_module.addImport("renderer", renderer_mod);
    check_exe.root_module.addImport("input", input_mod);
    check_exe.root_module.addImport("syntax", syntax_mod);
    check_exe.root_module.addImport("file_type_config", file_type_config_mod);
    check_exe.root_module.addImport("color", color_mod);
    check_exe.root_module.addImport("bin_path", bin_path_mod);
    check_exe.root_module.addImport("regex", regex_mod);
    check_exe.root_module.addImport("version", b.createModule(.{ .root_source_file = version_file }));
    check_exe.root_module.addImport("version_info", b.createModule(.{ .root_source_file = version_info_file }));
    check_exe.root_module.addImport("c", c_mod);
    check_step.dependOn(&check_exe.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/tests.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_lld,
        .filters = test_filters,
    });

    tests.pie = pie;
    tests.root_module.addImport("build_options", options_mod);
    tests.root_module.addImport("soft_root", soft_root_mod);
    tests.root_module.addImport("file_link", file_link_mod);
    tests.root_module.addImport("log", log_mod);
    tests.root_module.addImport("Buffer", Buffer_mod);
    tests.root_module.addImport("color", color_mod);
    tests.root_module.addImport("tui", tui_mod);
    tests.root_module.addImport("command", command_mod);
    tests.root_module.addImport("project_manager", project_manager_mod);
    tests.root_module.addImport("regex", regex_mod);
    tests.root_module.addImport("snippet", snippet_mod);
    // b.installArtifact(tests);

    const test_run_cmd = b.addRunArtifact(tests);

    test_step.dependOn(&test_run_cmd.step);
    test_step.dependOn(&keybind_test_run_cmd.step);
    test_step.dependOn(&match_test_run_cmd.step);
    test_step.dependOn(&glyph_constraint_test_run_cmd.step);
    test_step.dependOn(&glyph_atlas_test_run_cmd.step);
    test_step.dependOn(&terminal_screen_test_run_cmd.step);
    test_step.dependOn(&double_mapped_ring_buffer_test_run_cmd.step);
    test_step.dependOn(&mouse_event_test_run_cmd.step);
    test_step.dependOn(&syntax_validator_test_run_cmd.step);

    const lints = b.addFmt(.{
        .paths = &.{ "src", "test", "build.zig" },
        .check = true,
    });

    lint_step.dependOn(&lints.step);
    b.default_step.dependOn(lint_step);
}

fn gen_version_info(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    writer: anytype,
    optimize: std.builtin.OptimizeMode,
    renderer: Renderer,
) !void {
    var code: u8 = 0;

    const describe = try b.runAllowFail(&[_][]const u8{ "git", "describe", "--always", "--tags" }, &code, .ignore);
    const date_ = try b.runAllowFail(&[_][]const u8{ "git", "show", "-s", "--format=%ci", "HEAD" }, &code, .ignore);
    const branch_ = try b.runAllowFail(&[_][]const u8{ "git", "rev-parse", "--abbrev-ref", "HEAD" }, &code, .ignore);
    const branch = std.mem.trimEnd(u8, branch_, "\r\n ");
    const tracking_branch_ = blk: {
        var buf: std.Io.Writer.Allocating = .init(b.allocator);
        defer buf.deinit();
        try buf.writer.writeAll(branch);
        try buf.writer.writeAll("@{upstream}");
        break :blk (b.runAllowFail(&[_][]const u8{ "git", "rev-parse", "--abbrev-ref", buf.written() }, &code, .ignore) catch "");
    };
    const tracking_remote_name = if (std.mem.indexOfScalar(u8, tracking_branch_, '/')) |pos| tracking_branch_[0..pos] else "";
    const tracking_remote_ = if (tracking_remote_name.len > 0) blk: {
        var remote_config_path: std.Io.Writer.Allocating = .init(b.allocator);
        defer remote_config_path.deinit();
        try remote_config_path.writer.print("remote.{s}.url", .{tracking_remote_name});
        break :blk b.runAllowFail(&[_][]const u8{ "git", "config", remote_config_path.written() }, &code, .ignore) catch "(remote not found)";
    } else "";
    const remote_ = b.runAllowFail(&[_][]const u8{ "git", "config", "remote.origin.url" }, &code, .ignore) catch "(origin not found)";
    const log_ = b.runAllowFail(&[_][]const u8{ "git", "log", "--pretty=oneline", "@{u}..." }, &code, .ignore) catch "";
    const diff_ = b.runAllowFail(&[_][]const u8{ "git", "diff", "--stat", "--patch", "HEAD" }, &code, .ignore) catch "(git diff failed)";
    const version = std.mem.trimEnd(u8, describe, "\r\n ");
    const date = std.mem.trimEnd(u8, date_, "\r\n ");
    const tracking_branch = std.mem.trimEnd(u8, tracking_branch_, "\r\n ");
    const tracking_remote = std.mem.trimEnd(u8, tracking_remote_, "\r\n ");
    const remote = std.mem.trimEnd(u8, remote_, "\r\n ");
    const base_commit_ = b.runAllowFail(&[_][]const u8{ "git", "merge-base", branch, tracking_branch }, &code, .ignore) catch "";
    const base_commit = std.mem.trimEnd(u8, base_commit_, "\r\n ");
    const describe_base_commit_ = try b.runAllowFail(&[_][]const u8{ "git", "describe", "--always", "--tags", base_commit }, &code, .ignore);
    const describe_base_commit = std.mem.trimEnd(u8, describe_base_commit_, "\r\n ");
    const log = std.mem.trimEnd(u8, log_, "\r\n ");
    const diff = std.mem.trimEnd(u8, diff_, "\r\n ");
    const target_triple = try target.result.zigTriple(b.allocator);

    try writer.print("Flow Control: a programmer's text editor\n\nversion: {s}{s}\ncommitted: {s}\ntarget: {s}\nrenderer: {t}\n", .{
        version,
        if (diff.len > 0) "-dirty" else "",
        date,
        target_triple,
        renderer,
    });

    if (branch.len > 0) if (tracking_branch.len > 0)
        try writer.print("branch: {s} tracking {s} at {s}\n", .{ branch, tracking_branch, tracking_remote })
    else
        try writer.print("branch: {s} at {s}\n", .{ branch, remote });

    try writer.print("built-with: zig {s} ({t})\n", .{ builtin.zig_version_string, builtin.zig_backend });
    try writer.print("build-mode: {t}\n", .{optimize});

    if (log.len > 0)
        try writer.print("\nbranched off {s} @ {s} with the following diverging commits:\n{s}\n", .{ tracking_branch, describe_base_commit, log });

    if (diff.len > 0)
        try writer.print("\nwith the following uncommited changes:\n\n{s}\n", .{diff});
}

fn gen_version(b: *std.Build, writer: *std.Io.Writer) !void {
    var code: u8 = 0;

    const describe = try b.runAllowFail(&[_][]const u8{ "git", "describe", "--always", "--tags" }, &code, .ignore);
    const diff_ = try b.runAllowFail(&[_][]const u8{ "git", "diff", "--stat", "--patch", "HEAD" }, &code, .ignore);
    const diff = std.mem.trimEnd(u8, diff_, "\r\n ");
    const version = std.mem.trimEnd(u8, describe, "\r\n ");

    try writer.print("{s}{s}", .{ version, if (diff.len > 0) "-dirty" else "" });
}
