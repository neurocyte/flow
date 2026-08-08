//! Best-effort icon and brand color guessing.

const std = @import("std");

pub const Style = struct {
    icon: []const u8 = "",
    color: u24 = 0,
};

pub fn guess(name: []const u8, command: []const u8) Style {
    const Entry = struct { []const u8, []const u8, u24 };
    // Ordered most-specific first so e.g. a distro or Visual Studio prompt wins
    // over the generic "linux"/"powershell" fallbacks. Colors that overlap a
    // flow-syntax file_type mirror that file_type's color.
    const entries = [_]Entry{
        // Linux distributions (usually WSL)
        .{ "ubuntu", "\u{f31b}", 0xE95420 },
        .{ "debian", "\u{f306}", 0xA81D33 },
        .{ "archlinux", "\u{f303}", 0x1793D1 },
        .{ "arch", "\u{f303}", 0x1793D1 },
        .{ "fedora", "\u{f30a}", 0x3C6EB4 },
        .{ "opensuse", "\u{f314}", 0x73BA25 },
        .{ "suse", "\u{f314}", 0x73BA25 },
        .{ "alpine", "\u{f300}", 0x0D597F },
        .{ "kali", "\u{f327}", 0 },
        .{ "manjaro", "\u{f312}", 0x35BF5C },
        .{ "linuxmint", "\u{f30e}", 0x87CF3E },
        .{ "mint", "\u{f30e}", 0x87CF3E },
        .{ "centos", "\u{f304}", 0 },
        .{ "gentoo", "\u{f30d}", 0x54487A },
        .{ "devuan", "\u{f307}", 0 },
        .{ "nixos", "\u{f313}", 0x5277C3 },
        .{ "almalinux", "\u{f31d}", 0 },
        .{ "rocky", "\u{f32b}", 0 },
        .{ "raspbian", "\u{f315}", 0xC51A4A },
        .{ "raspberry", "\u{f315}", 0xC51A4A },
        .{ "freebsd", "\u{f30c}", 0xAB2B28 },
        .{ "redhat", "\u{f316}", 0xEE0000 },
        .{ "rhel", "\u{f316}", 0xEE0000 },
        // Visual Studio developer prompts
        .{ "visual studio", "\u{e70c}", 0x5C2D91 },
        .{ "vsdevshell", "\u{e70c}", 0x5C2D91 },
        .{ "developer", "\u{e70c}", 0x5C2D91 },
        // Shells and tools (colors mirror flow-syntax file_type colors)
        .{ "git", "\u{e702}", 0xF34F29 },
        .{ "pwsh", "", 0 },
        .{ "powershell", "\u{f0a0a}", 0x0873C5 },
        .{ "command prompt", "\u{ebc4}", 0 },
        .{ "cmd", "\u{ebc4}", 0 },
        .{ "bash", "\u{ebca}", 0x3E474A },
        // Generic fallbacks
        .{ "wsl", "\u{f17c}", 0 },
        .{ "linux", "\u{f17c}", 0 },
    };
    for (entries) |entry|
        if (std.ascii.indexOfIgnoreCase(name, entry[0]) != null or
            std.ascii.indexOfIgnoreCase(command, entry[0]) != null)
            return .{ .icon = entry[1], .color = entry[2] };
    return .{};
}

test "guess: matches known names with icon and color, falls back to none" {
    const ps = guess("Windows PowerShell", "powershell.exe");
    try std.testing.expectEqualStrings("\u{f0a0a}", ps.icon);
    try std.testing.expectEqual(@as(u24, 0x0873C5), ps.color);

    const ubuntu = guess("Ubuntu", "wsl.exe -d Ubuntu");
    try std.testing.expectEqualStrings("\u{f31b}", ubuntu.icon);
    try std.testing.expectEqual(@as(u24, 0xE95420), ubuntu.color);

    try std.testing.expectEqualStrings("\u{f316}", guess("RHEL", "wsl.exe -d RHEL").icon);
    try std.testing.expectEqualStrings("\u{ebc4}", guess("Command Prompt", "cmd.exe").icon);
    try std.testing.expectEqualStrings("\u{e70c}", guess("Developer PowerShell for VS 2022", "pwsh.exe").icon);
    try std.testing.expectEqualStrings("\u{e702}", guess("Git Bash", "bash.exe").icon);

    const none = guess("Custom Thing", "myapp.exe");
    try std.testing.expectEqualStrings("", none.icon);
    try std.testing.expectEqual(@as(u24, 0), none.color);
}
