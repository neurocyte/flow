const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const tracy_enabled = b.option(bool, "enable_tracy", "Enable tracy client library (default: no)") orelse false;
    const optimize_deps = b.option(bool, "optimize_deps", "Enable optimization for dependecies (default: yes)") orelse true;
    const use_llvm_option = b.option(bool, "use_llvm", "Enable llvm backend (default: yes)");
    const use_lld_option = b.option(bool, "use_lld", "Enable lld backend (default: yes)");
    const use_tree_sitter = b.option(bool, "use_tree_sitter", "Enable tree-sitter (default: yes)") orelse true;

    const options = b.addOptions();
    options.addOption(bool, "enable_tracy", tracy_enabled);
    options.addOption(bool, "optimize_deps", optimize_deps);
    options.addOption(bool, "use_tree_sitter", use_tree_sitter);
    options.addOption(bool, "use_llvm", use_llvm_option orelse true);
    options.addOption(bool, "use_lld", use_lld_option orelse true);

    const options_mod = options.createModule();

    const target = b.standardTargetOptions(.{ .default_target = .{ .abi = if (builtin.os.tag == .linux and !tracy_enabled) .musl else null } });
    // std.debug.print("target abi: {s}\n", .{@tagName(target.result.abi)});
    const optimize = b.standardOptimizeOption(.{});

    const dependency_optimize = if (optimize_deps) .ReleaseFast else optimize;

    std.fs.cwd().makeDir(".cache") catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => std.debug.panic("makeDir(\".cache\") failed: {any}", .{e}),
    };
    std.fs.cwd().makeDir(".cache/cdb") catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => std.debug.panic("makeDir(\".cache/cdb\") failed: {any}", .{e}),
    };

    var version_info = std.ArrayList(u8).init(b.allocator);
    defer version_info.deinit();
    gen_version_info(b, version_info.writer()) catch {
        version_info.clearAndFree();
        version_info.appendSlice("unknown") catch {};
    };

    const wf = b.addWriteFiles();
    const version_info_file = wf.add("version", version_info.items);

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = dependency_optimize,
    });
    const vaxis_mod = vaxis_dep.module("vaxis");

    const flags_dep = b.dependency("flags", .{
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
        .root_source_file = b.path("src/tracy_noop.zig"),
    });

    const zg_dep = vaxis_dep.builder.dependency("zg", .{
        .target = target,
        .optimize = dependency_optimize,
    });

    const zeit_dep = b.dependency("zeit", .{
        .target = target,
        .optimize = dependency_optimize,
    });
    const zeit_mod = zeit_dep.module("zeit");

    const themes_dep = b.dependency("themes", .{});

    const syntax_dep = b.dependency("syntax", .{
        .target = target,
        .optimize = dependency_optimize,
        .use_tree_sitter = use_tree_sitter,
    });
    const syntax_mod = syntax_dep.module("syntax");

    const thespian_dep = b.dependency("thespian", .{
        .target = target,
        .optimize = dependency_optimize,
        .enable_tracy = tracy_enabled,
    });

    const thespian_mod = thespian_dep.module("thespian");
    const cbor_mod = thespian_dep.module("cbor");

    const help_mod = b.createModule(.{
        .root_source_file = b.path("help.md"),
    });

    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .imports = &.{
            .{ .name = "cbor", .module = cbor_mod },
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
        },
    });

    const EventHandler_mod = b.createModule(.{
        .root_source_file = b.path("src/EventHandler.zig"),
        .imports = &.{
            .{ .name = "thespian", .module = thespian_mod },
        },
    });

    const color_mod = b.createModule(.{
        .root_source_file = b.path("src/color.zig"),
    });

    const Buffer_mod = b.createModule(.{
        .root_source_file = b.path("src/buffer/Buffer.zig"),
        .imports = &.{
            .{ .name = "cbor", .module = cbor_mod },
        },
    });

    const renderer_mod = b.createModule(.{
        .root_source_file = b.path("src/renderer/vaxis/renderer.zig"),
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis_mod },
            .{ .name = "theme", .module = themes_dep.module("theme") },
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "log", .module = log_mod },
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "Buffer", .module = Buffer_mod },
        },
    });

    const keybind_static_mod = b.createModule(.{
        .root_source_file = b.path("src/keybind/static/root.zig"),
        .imports = &.{
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "command", .module = command_mod },
            .{ .name = "EventHandler", .module = EventHandler_mod },
            .{ .name = "renderer", .module = renderer_mod },
            .{ .name = "thespian", .module = thespian_mod },
        },
    });

    const ripgrep_mod = b.createModule(.{
        .root_source_file = b.path("src/ripgrep.zig"),
        .imports = &.{
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "log", .module = log_mod },
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
            .{ .name = "log", .module = log_mod },
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "Buffer", .module = Buffer_mod },
            .{ .name = "tracy", .module = tracy_mod },
            .{ .name = "syntax", .module = syntax_mod },
            .{ .name = "dizzy", .module = dizzy_dep.module("dizzy") },
            .{ .name = "fuzzig", .module = fuzzig_dep.module("fuzzig") },
        },
    });

    const diff_mod = b.createModule(.{
        .root_source_file = b.path("src/diff.zig"),
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
        .root_source_file = b.path("src/text_manip.zig"),
        .imports = &.{},
    });

    const tui_mod = b.createModule(.{
        .root_source_file = b.path("src/tui/tui.zig"),
        .imports = &.{
            .{ .name = "renderer", .module = renderer_mod },
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "log", .module = log_mod },
            .{ .name = "command", .module = command_mod },
            .{ .name = "EventHandler", .module = EventHandler_mod },
            .{ .name = "location_history", .module = location_history_mod },
            .{ .name = "project_manager", .module = project_manager_mod },
            .{ .name = "syntax", .module = syntax_mod },
            .{ .name = "text_manip", .module = text_manip_mod },
            .{ .name = "Buffer", .module = Buffer_mod },
            .{ .name = "keybind", .module = keybind_static_mod },
            .{ .name = "ripgrep", .module = ripgrep_mod },
            .{ .name = "theme", .module = themes_dep.module("theme") },
            .{ .name = "themes", .module = themes_dep.module("themes") },
            .{ .name = "tracy", .module = tracy_mod },
            .{ .name = "build_options", .module = options_mod },
            .{ .name = "color", .module = color_mod },
            .{ .name = "diff", .module = diff_mod },
            .{ .name = "help.md", .module = help_mod },
            .{ .name = "CaseData", .module = zg_dep.module("CaseData") },
            .{ .name = "fuzzig", .module = fuzzig_dep.module("fuzzig") },
            .{ .name = "zeit", .module = zeit_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "flow",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (use_llvm_option) |enabled| exe.use_llvm = enabled;
    if (use_lld_option) |enabled| exe.use_lld = enabled;

    exe.root_module.addImport("build_options", options_mod);
    exe.root_module.addImport("flags", flags_dep.module("flags"));
    exe.root_module.addImport("cbor", cbor_mod);
    exe.root_module.addImport("config", config_mod);
    exe.root_module.addImport("tui", tui_mod);
    exe.root_module.addImport("thespian", thespian_mod);
    exe.root_module.addImport("log", log_mod);
    exe.root_module.addImport("tracy", tracy_mod);
    exe.root_module.addImport("renderer", renderer_mod);
    exe.root_module.addImport("syntax", syntax_mod);
    exe.root_module.addImport("version_info", b.createModule(.{ .root_source_file = version_info_file }));
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
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (use_llvm_option) |enabled| check_exe.use_llvm = enabled;
    if (use_lld_option) |enabled| check_exe.use_lld = enabled;

    check_exe.root_module.addImport("build_options", options_mod);
    check_exe.root_module.addImport("flags", flags_dep.module("flags"));
    check_exe.root_module.addImport("cbor", cbor_mod);
    check_exe.root_module.addImport("config", config_mod);
    check_exe.root_module.addImport("tui", tui_mod);
    check_exe.root_module.addImport("thespian", thespian_mod);
    check_exe.root_module.addImport("log", log_mod);
    check_exe.root_module.addImport("tracy", tracy_mod);
    check_exe.root_module.addImport("renderer", renderer_mod);
    check_exe.root_module.addImport("syntax", syntax_mod);
    check_exe.root_module.addImport("version_info", b.createModule(.{ .root_source_file = version_info_file }));
    const check = b.step("check", "Check the app");
    check.dependOn(&check_exe.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("test/tests.zig"),
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

    const lints_step = b.step("lint", "Run lints");

    const lints = b.addFmt(.{
        .paths = &.{ "src", "test", "build.zig" },
        .check = true,
    });

    lints_step.dependOn(&lints.step);
    // b.default_step.dependOn(lints_step);
}

fn gen_version_info(b: *std.Build, writer: anytype) !void {
    var code: u8 = 0;

    const describe = try b.runAllowFail(&[_][]const u8{ "git", "describe", "--always", "--tags" }, &code, .Ignore);
    const branch_ = try b.runAllowFail(&[_][]const u8{ "git", "rev-parse", "--abbrev-ref", "HEAD" }, &code, .Ignore);
    const remote_ = try b.runAllowFail(&[_][]const u8{ "git", "config", "remote.origin.url" }, &code, .Ignore);
    const log_ = try b.runAllowFail(&[_][]const u8{ "git", "log", "--pretty=oneline", "@{u}..." }, &code, .Ignore);
    const diff_ = try b.runAllowFail(&[_][]const u8{ "git", "diff", "--stat", "--patch", "HEAD" }, &code, .Ignore);
    const version = std.mem.trimRight(u8, describe, "\r\n ");
    const branch = std.mem.trimRight(u8, branch_, "\r\n ");
    const remote = std.mem.trimRight(u8, remote_, "\r\n ");
    const log = std.mem.trimRight(u8, log_, "\r\n ");
    const diff = std.mem.trimRight(u8, diff_, "\r\n ");

    try writer.print("Flow Control: a programmer's text editor\n\nversion: {s}{s}\n", .{
        version,
        if (diff.len > 0) "-dirty" else "",
    });

    if (branch.len > 0)
        try writer.print("branch: {s} at {s}\n", .{ branch, remote });

    if (log.len > 0)
        try writer.print("\nwith the following diverging commits:\n{s}\n", .{log});

    if (diff.len > 0)
        try writer.print("\nwith the following uncommited changes:\n\n{s}\n", .{diff});
}
