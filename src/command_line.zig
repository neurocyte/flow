//! Splitting a command line string into argv.

const std = @import("std");
const builtin = @import("builtin");

pub const split = if (builtin.os.tag == .windows) splitWindows else splitPosix;

pub fn free(allocator: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

pub fn splitWindows(allocator: std.mem.Allocator, cmd_line: []const u8) std.mem.Allocator.Error![][]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer freeList(allocator, &argv);

    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);

    var in_quotes = false;
    var have_arg = false;
    var i: usize = 0;
    while (i < cmd_line.len) : (i += 1) {
        switch (cmd_line[i]) {
            ' ', '\t' => {
                if (in_quotes) {
                    try current.append(allocator, cmd_line[i]);
                } else if (have_arg) {
                    try argv.append(allocator, try current.toOwnedSlice(allocator));
                    have_arg = false;
                }
            },
            '"' => {
                if (in_quotes and i + 1 < cmd_line.len and cmd_line[i + 1] == '"') {
                    try current.append(allocator, '"');
                    i += 1;
                } else {
                    in_quotes = !in_quotes;
                }
                have_arg = true;
            },
            '\\' => {
                // Only an escape when it runs into a quote: 2n backslashes give n
                // and toggle quoting, 2n+1 give n and a literal quote. Anywhere
                // else a backslash is just a path separator.
                var slashes: usize = 0;
                while (i + slashes < cmd_line.len and cmd_line[i + slashes] == '\\') slashes += 1;
                const before_quote = i + slashes < cmd_line.len and cmd_line[i + slashes] == '"';
                try current.appendNTimes(allocator, '\\', if (before_quote) slashes / 2 else slashes);
                if (before_quote and slashes % 2 == 1) {
                    try current.append(allocator, '"');
                    i += slashes; // consume the quote as well
                } else {
                    i += slashes - 1;
                }
                have_arg = true;
            },
            else => {
                try current.append(allocator, cmd_line[i]);
                have_arg = true;
            },
        }
    }
    if (have_arg) try argv.append(allocator, try current.toOwnedSlice(allocator));

    return argv.toOwnedSlice(allocator);
}

pub fn splitPosix(allocator: std.mem.Allocator, cmd_line: []const u8) std.mem.Allocator.Error![][]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer freeList(allocator, &argv);

    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);

    var have_arg = false;
    var i: usize = 0;
    while (i < cmd_line.len) : (i += 1) {
        switch (cmd_line[i]) {
            ' ', '\t', '\n', '\r' => {
                if (have_arg) {
                    try argv.append(allocator, try current.toOwnedSlice(allocator));
                    have_arg = false;
                }
            },
            '\'' => {
                // Single quotes are literal throughout: no escapes inside.
                have_arg = true;
                i += 1;
                while (i < cmd_line.len and cmd_line[i] != '\'') : (i += 1)
                    try current.append(allocator, cmd_line[i]);
            },
            '"' => {
                have_arg = true;
                i += 1;
                while (i < cmd_line.len and cmd_line[i] != '"') : (i += 1) {
                    // Inside double quotes a backslash only escapes these.
                    if (cmd_line[i] == '\\' and i + 1 < cmd_line.len) {
                        switch (cmd_line[i + 1]) {
                            '"', '\\', '$', '`' => {
                                i += 1;
                                try current.append(allocator, cmd_line[i]);
                                continue;
                            },
                            '\n' => {
                                i += 1; // line continuation
                                continue;
                            },
                            else => {},
                        }
                    }
                    try current.append(allocator, cmd_line[i]);
                }
            },
            '\\' => {
                have_arg = true;
                if (i + 1 < cmd_line.len) {
                    i += 1;
                    if (cmd_line[i] != '\n') // line continuation drops both
                        try current.append(allocator, cmd_line[i]);
                } else {
                    try current.append(allocator, '\\');
                }
            },
            else => {
                try current.append(allocator, cmd_line[i]);
                have_arg = true;
            },
        }
    }
    if (have_arg) try argv.append(allocator, try current.toOwnedSlice(allocator));

    return argv.toOwnedSlice(allocator);
}

fn freeList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |arg| allocator.free(arg);
    list.deinit(allocator);
}

fn expectSplit(
    comptime splitFn: fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error![][]const u8,
    cmd_line: []const u8,
    expected: []const []const u8,
) !void {
    const argv = try splitFn(std.testing.allocator, cmd_line);
    defer free(std.testing.allocator, argv);
    try std.testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "windows: bare program and arguments" {
    try expectSplit(splitWindows, "pwsh.exe", &.{"pwsh.exe"});
    try expectSplit(splitWindows, "  pwsh.exe  ", &.{"pwsh.exe"});
    try expectSplit(splitWindows, "wsl.exe -d Ubuntu", &.{ "wsl.exe", "-d", "Ubuntu" });
}

// What Windows Terminal writes for a default PowerShell 7 profile.
test "windows: quoted program path" {
    try expectSplit(splitWindows,
        \\"C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo
    , &.{ "C:\\Program Files\\PowerShell\\7\\pwsh.exe", "-NoLogo" });
}

test "windows: unquoted path keeps backslashes" {
    try expectSplit(splitWindows,
        \\C:\Windows\System32\cmd.exe /k
    , &.{ "C:\\Windows\\System32\\cmd.exe", "/k" });
}

test "windows: backslash quote rules" {
    try expectSplit(splitWindows,
        \\a\\\"b
    , &.{"a\\\"b"});
    try expectSplit(splitWindows,
        \\"a\\" b
    , &.{ "a\\", "b" });
}

test "windows: empty input and quoted empty argument" {
    try expectSplit(splitWindows, "", &.{});
    try expectSplit(splitWindows, "   ", &.{});
    try expectSplit(splitWindows, "a \"\" b", &.{ "a", "", "b" });
}

test "windows: doubled quotes are a literal quote" {
    try expectSplit(splitWindows,
        \\Import-Module """C:\Program Files\x.dll"""
    , &.{
        "Import-Module",
        \\"C:\Program Files\x.dll"
    });
}

test "posix: bare program and arguments" {
    try expectSplit(splitPosix, "bash", &.{"bash"});
    try expectSplit(splitPosix, "  bash -l  ", &.{ "bash", "-l" });
}

test "posix: escaped space" {
    try expectSplit(splitPosix,
        \\/home/me/my\ app --flag
    , &.{ "/home/me/my app", "--flag" });
}

test "posix: single quotes are literal" {
    try expectSplit(splitPosix,
        \\echo 'a b\c"d'
    , &.{ "echo", "a b\\c\"d" });
}

test "posix: double quotes escape a subset" {
    try expectSplit(splitPosix,
        \\echo "a b" "c\"d" "e\\f" "g\qh"
    , &.{ "echo", "a b", "c\"d", "e\\f", "g\\qh" });
}

test "posix: expansion is not performed" {
    try expectSplit(splitPosix, "echo $HOME *.zig", &.{ "echo", "$HOME", "*.zig" });
}

test "posix: adjacent quoted and bare segments join" {
    try expectSplit(splitPosix,
        \\--opt="a b"c
    , &.{"--opt=a bc"});
}

test "posix: empty input and quoted empty argument" {
    try expectSplit(splitPosix, "", &.{});
    try expectSplit(splitPosix, "   ", &.{});
    try expectSplit(splitPosix, "a '' b", &.{ "a", "", "b" });
}
