const std = @import("std");

const CrossTarget = std.zig.CrossTarget;

const cppflags = [_][]const u8{
    "-fcolor-diagnostics",
    "-std=c++20",
    "-Wall",
    "-Wextra",
    "-Werror",
    "-Wno-unqualified-std-cast-call",
    "-Wno-bitwise-instead-of-logical", //for notcurses
    "-fno-sanitize=undefined",
    "-gen-cdb-fragment-path",
    ".cache/cdb",
};

pub fn build(b: *std.Build) void {
    const enable_tracy_option = b.option(bool, "enable_tracy", "Enable tracy client library (default: no)");
    const optimize_deps_option = b.option(bool, "optimize_deps", "Enable optimization for dependecies (default: yes)");
    const use_llvm_option = b.option(bool, "use_llvm", "Enable llvm backend (default: yes)");
    const use_lld_option = b.option(bool, "use_lld", "Enable lld backend (default: yes)");
    const use_system_notcurses = b.option(bool, "use_system_notcurses", "Build against system notcurses (default: no)") orelse false;

    const tracy_enabled = if (enable_tracy_option) |enabled| enabled else false;
    const optimize_deps_enabled = if (optimize_deps_option) |enabled| enabled else true;

    const options = b.addOptions();
    options.addOption(bool, "enable_tracy", tracy_enabled);
    options.addOption(bool, "optimize_deps", optimize_deps_enabled);
    options.addOption(bool, "use_llvm", use_llvm_option orelse false);
    options.addOption(bool, "use_lld", use_lld_option orelse false);
    options.addOption(bool, "use_system_notcurses", use_system_notcurses);

    const options_mod = options.createModule();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dependency_optimize = if (optimize_deps_enabled) .ReleaseFast else optimize;

    std.fs.cwd().makeDir(".cache") catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => std.debug.panic("makeDir(\".cache\") failed: {any}", .{e}),
    };
    std.fs.cwd().makeDir(".cache/cdb") catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => std.debug.panic("makeDir(\".cache/cdb\") failed: {any}", .{e}),
    };

    const notcurses_dep = b.dependency("notcurses", .{
        .target = target,
        .optimize = dependency_optimize,
        .use_system_notcurses = use_system_notcurses,
    });

    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = dependency_optimize,
    });

    const dizzy_dep = b.dependency("dizzy", .{
        .target = target,
        .optimize = dependency_optimize,
    });

    const tracy_dep = if (tracy_enabled) b.dependency("tracy", .{
        .target = target,
        .optimize = dependency_optimize,
    }) else undefined;
    const tracy_mod = if (tracy_enabled) tracy_dep.module("tracy") else b.createModule(.{
        .root_source_file = .{ .path = "src/tracy_noop.zig" },
    });

    const themes_dep = b.dependency("themes", .{});

    const thespian_dep = b.dependency("thespian", .{
        .target = target,
        .optimize = dependency_optimize,
        .enable_tracy = tracy_enabled,
    });

    const thespian_mod = thespian_dep.module("thespian");
    const cbor_mod = thespian_dep.module("cbor");
    const notcurses_mod = notcurses_dep.module("notcurses");

    const help_mod = b.createModule(.{
        .root_source_file = .{ .path = "help.md" },
    });

    const config_mod = b.createModule(.{
        .root_source_file = .{ .path = "src/config.zig" },
        .imports = &.{
            .{ .name = "cbor", .module = cbor_mod },
        },
    });

    const log_mod = b.createModule(.{
        .root_source_file = .{ .path = "src/log.zig" },
        .imports = &.{
            .{ .name = "thespian", .module = thespian_mod },
        },
    });

    const tree_sitter_dep = b.dependency("tree-sitter", .{
        .target = target,
        .optimize = dependency_optimize,
    });

    const color_mod = b.createModule(.{
        .root_source_file = .{ .path = "src/color.zig" },
    });

    const Buffer_mod = b.createModule(.{
        .root_source_file = .{ .path = "src/buffer/Buffer.zig" },
        .imports = &.{
            .{ .name = "notcurses", .module = notcurses_mod },
            .{ .name = "cbor", .module = cbor_mod },
        },
    });

    const ripgrep_mod = b.createModule(.{
        .root_source_file = .{ .path = "src/ripgrep.zig" },
        .imports = &.{
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "log", .module = log_mod },
        },
    });

    const location_history_mod = b.createModule(.{
        .root_source_file = .{ .path = "src/location_history.zig" },
        .imports = &.{
            .{ .name = "thespian", .module = thespian_mod },
        },
    });

    const syntax_mod = b.createModule(.{
        .root_source_file = .{ .path = "src/syntax.zig" },
        .imports = &.{
            .{ .name = "Buffer", .module = Buffer_mod },
            .{ .name = "tracy", .module = tracy_mod },
            .{ .name = "treez", .module = tree_sitter_dep.module("treez") },
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-agda/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-bash/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-c-sharp/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-c/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-cpp/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-css/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-diff/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-dockerfile/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-git-rebase/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-gitcommit/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-go/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-fish/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-haskell/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-html/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-java/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-javascript/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-jsdoc/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-json/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-lua/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-make/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-markdown/tree-sitter-markdown/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-markdown/tree-sitter-markdown-inline/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-nasm/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-ninja/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-nix/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-ocaml/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-openscad/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-org/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-php/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-python/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-purescript/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-regex/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-ruby/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-rust/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-ssh-config/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-scala/queries/scala/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-scheme/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-toml/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-typescript/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-xml/dtd/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-xml/xml/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-zig/queries/highlights.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-ziggy/tree-sitter-ziggy/queries/highlights.scm"),

            ts_queryfile(b, tree_sitter_dep, "tree-sitter-cpp/queries/injections.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-gitcommit/queries/injections.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-html/queries/injections.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-javascript/queries/injections.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-lua/queries/injections.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-markdown/tree-sitter-markdown-inline/queries/injections.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-markdown/tree-sitter-markdown/queries/injections.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-nasm/queries/injections.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-nix/queries/injections.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-openscad/queries/injections.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-php/queries/injections.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-purescript/queries/injections.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-purescript/vim_queries/injections.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-rust/queries/injections.scm"),
            ts_queryfile(b, tree_sitter_dep, "tree-sitter-zig/queries/injections.scm"),
        },
    });

    const diff_mod = b.createModule(.{
        .root_source_file = .{ .path = "src/diff.zig" },
        .imports = &.{
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "Buffer", .module = Buffer_mod },
            .{ .name = "tracy", .module = tracy_mod },
            .{ .name = "dizzy", .module = dizzy_dep.module("dizzy") },
            .{ .name = "log", .module = log_mod },
            .{ .name = "cbor", .module = cbor_mod },
        },
    });

    const text_manip_mod = b.createModule(.{
        .root_source_file = .{ .path = "src/text_manip.zig" },
        .imports = &.{},
    });

    const tui_mod = b.createModule(.{
        .root_source_file = .{ .path = "src/tui/tui.zig" },
        .imports = &.{
            .{ .name = "notcurses", .module = notcurses_mod },
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "log", .module = log_mod },
            .{ .name = "location_history", .module = location_history_mod },
            .{ .name = "syntax", .module = syntax_mod },
            .{ .name = "text_manip", .module = text_manip_mod },
            .{ .name = "Buffer", .module = Buffer_mod },
            .{ .name = "ripgrep", .module = ripgrep_mod },
            .{ .name = "theme", .module = themes_dep.module("theme") },
            .{ .name = "themes", .module = themes_dep.module("themes") },
            .{ .name = "tracy", .module = tracy_mod },
            .{ .name = "build_options", .module = options_mod },
            .{ .name = "color", .module = color_mod },
            .{ .name = "diff", .module = diff_mod },
            .{ .name = "help.md", .module = help_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "flow",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    if (use_llvm_option) |enabled| exe.use_llvm = enabled;
    if (use_lld_option) |enabled| exe.use_lld = enabled;

    exe.root_module.addImport("build_options", options_mod);
    exe.root_module.addImport("clap", clap_dep.module("clap"));
    exe.root_module.addImport("cbor", cbor_mod);
    exe.root_module.addImport("config", config_mod);
    exe.root_module.addImport("tui", tui_mod);
    exe.root_module.addImport("thespian", thespian_mod);
    exe.root_module.addImport("log", log_mod);
    exe.root_module.addImport("tracy", tracy_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "test/tests.zig" },
        .target = target,
        .optimize = optimize,
    });

    tests.root_module.addImport("build_options", options_mod);
    tests.root_module.addImport("log", log_mod);
    tests.root_module.addImport("Buffer", Buffer_mod);
    tests.root_module.addImport("color", color_mod);
    // b.installArtifact(tests);

    const test_run_cmd = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_run_cmd.step);
}

fn ts_queryfile(b: *std.Build, dep: *std.Build.Dependency, comptime sub_path: []const u8) std.Build.Module.Import {
    return .{
        .name = sub_path,
        .module = b.createModule(.{
            .root_source_file = dep.path(sub_path),
        }),
    };
}
