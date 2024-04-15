const std = @import("std");
const builtin = @import("builtin");

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

    const target = b.standardTargetOptions(.{ .default_target = .{ .abi = if (builtin.os.tag == .linux and !tracy_enabled) .musl else null } });
    // std.debug.print("target abi: {s}\n", .{@tagName(target.result.abi)});
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

    const fuzzig_dep = b.dependency("fuzzig", .{
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

    const syntax_dep = b.dependency("syntax", .{
        .target = target,
        .optimize = dependency_optimize,
    });

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

    const project_manager_mod = b.createModule(.{
        .root_source_file = .{ .path = "src/project_manager.zig" },
        .imports = &.{
            .{ .name = "log", .module = log_mod },
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "Buffer", .module = Buffer_mod },
            .{ .name = "tracy", .module = tracy_mod },
            .{ .name = "syntax", .module = syntax_dep.module("syntax") },
            .{ .name = "dizzy", .module = dizzy_dep.module("dizzy") },
            .{ .name = "fuzzig", .module = fuzzig_dep.module("fuzzig") },
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
            .{ .name = "project_manager", .module = project_manager_mod },
            .{ .name = "syntax", .module = syntax_dep.module("syntax") },
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

    const check_exe = b.addExecutable(.{
        .name = "flow",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    if (use_llvm_option) |enabled| check_exe.use_llvm = enabled;
    if (use_lld_option) |enabled| check_exe.use_lld = enabled;

    check_exe.root_module.addImport("build_options", options_mod);
    check_exe.root_module.addImport("clap", clap_dep.module("clap"));
    check_exe.root_module.addImport("cbor", cbor_mod);
    check_exe.root_module.addImport("config", config_mod);
    check_exe.root_module.addImport("tui", tui_mod);
    check_exe.root_module.addImport("thespian", thespian_mod);
    check_exe.root_module.addImport("log", log_mod);
    check_exe.root_module.addImport("tracy", tracy_mod);
    const check = b.step("check", "Check the app");
    check.dependOn(&check_exe.step);

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
