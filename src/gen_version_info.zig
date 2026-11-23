const std = @import("std");

const usage =
    \\usage: gen_version_info version release|dev OUTPUT
    \\       gen_version_info info release|dev OUTPUT TARGET RENDERER OPTIMIZE ZIG_VERSION ZIG_BACKEND
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 4) return usage_error();
    const release = if (std.mem.eql(u8, args[2], "release"))
        true
    else if (std.mem.eql(u8, args[2], "dev"))
        false
    else
        return usage_error();

    var output: std.Io.Writer.Allocating = .init(allocator);
    const result = if (std.mem.eql(u8, args[1], "version") and args.len == 4)
        gen_version(io, allocator, &output.writer)
    else if (std.mem.eql(u8, args[1], "info") and args.len == 9)
        gen_version_info(io, allocator, &output.writer, args[4], args[5], args[6], args[7], args[8])
    else
        return usage_error();
    result catch |e| {
        if (release) return e;
        output.clearRetainingCapacity();
        try output.writer.writeAll("unknown");
    };
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[3], .data = output.written() });
}

fn usage_error() error{Usage} {
    std.debug.print("{s}\n", .{usage});
    return error.Usage;
}

fn git(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(allocator, io, .{ .argv = argv }) catch return null;
    if (result.term != .exited or result.term.exited != 0) return null;
    return std.mem.trimEnd(u8, result.stdout, "\r\n ");
}

fn gen_version(io: std.Io, allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    const version = git(io, allocator, &.{ "git", "describe", "--always", "--tags" }) orelse return error.GitFailure;
    const diff = git(io, allocator, &.{ "git", "diff", "--stat", "--patch", "HEAD" }) orelse return error.GitFailure;
    try writer.writeAll(version);
    if (diff.len > 0) try writer.writeAll("-dirty");
}

fn gen_version_info(
    io: std.Io,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    target_triple: []const u8,
    renderer: []const u8,
    optimize: []const u8,
    zig_version: []const u8,
    zig_backend: []const u8,
) !void {
    const version = git(io, allocator, &.{ "git", "describe", "--always", "--tags" }) orelse return error.GitFailure;
    const date = git(io, allocator, &.{ "git", "show", "-s", "--format=%ci", "HEAD" }) orelse return error.GitFailure;
    const branch = git(io, allocator, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }) orelse return error.GitFailure;
    const tracking_branch = git(io, allocator, &.{ "git", "rev-parse", "--abbrev-ref", try std.fmt.allocPrint(allocator, "{s}@{{upstream}}", .{branch}) }) orelse "";
    const tracking_remote = if (std.mem.findScalar(u8, tracking_branch, '/')) |pos|
        git(io, allocator, &.{ "git", "config", try std.fmt.allocPrint(allocator, "remote.{s}.url", .{tracking_branch[0..pos]}) }) orelse "(remote not found)"
    else
        "";
    const remote = git(io, allocator, &.{ "git", "config", "remote.origin.url" }) orelse "(origin not found)";
    const log = git(io, allocator, &.{ "git", "log", "--pretty=oneline", "@{u}..." }) orelse "";
    const diff = git(io, allocator, &.{ "git", "diff", "--stat", "--patch", "HEAD" }) orelse "(git diff failed)";
    const base_commit = git(io, allocator, &.{ "git", "merge-base", branch, tracking_branch }) orelse "";
    const describe_base_commit = git(io, allocator, &.{ "git", "describe", "--always", "--tags", base_commit }) orelse "unknown";

    try writer.print(
        \\Flow Control: a programmer's text editor
        \\
        \\version: {s}{s}
        \\committed: {s}
        \\target: {s}
        \\renderer: {s}
        \\
    ,
        .{
            version,
            if (diff.len > 0) "-dirty" else "",
            date,
            target_triple,
            renderer,
        },
    );

    if (branch.len > 0) if (tracking_branch.len > 0)
        try writer.print("branch: {s} tracking {s} at {s}\n", .{ branch, tracking_branch, tracking_remote })
    else
        try writer.print("branch: {s} at {s}\n", .{ branch, remote });

    try writer.print("built-with: zig {s} ({s})\n", .{ zig_version, zig_backend });
    try writer.print("build-mode: {s}\n", .{optimize});

    if (log.len > 0)
        try writer.print(
            \\
            \\branched off {s} @ {s} with the following diverging commits:
            \\{s}
            \\
        , .{ tracking_branch, describe_base_commit, log });

    if (diff.len > 0)
        try writer.print("\nwith the following uncommitted changes:\n\n{s}\n", .{diff});
}
