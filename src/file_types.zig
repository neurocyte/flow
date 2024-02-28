pub const agda = .{
    .extensions = &[_][]const u8{"agda"},
    .comment = "--",
};

pub const bash = .{
    .color = 0x3e474a,
    .icon = "󱆃",
    .extensions = &[_][]const u8{ "sh", "bash" },
    .comment = "#",
    .first_line_matches = .{ .prefix = "#!", .content = "sh" },
};

pub const c = .{
    .icon = "󰙱",
    .extensions = &[_][]const u8{ "c", "h" },
    .comment = "//",
};

pub const @"c-sharp" = .{
    .color = 0x68217a,
    .icon = "󰌛",
    .extensions = &[_][]const u8{"cs"},
    .comment = "//",
};

pub const conf = .{
    .color = 0x000000,
    .icon = "",
    .extensions = &[_][]const u8{ "conf", "config", ".gitconfig" },
    .highlights = fish.highlights,
    .comment = "#",
    .parser = fish.parser,
};

pub const cpp = .{
    .color = 0x9c033a,
    .icon = "",
    .extensions = &[_][]const u8{ "cc", "cpp", "cxx", "hpp", "hxx", "h", "ipp", "ixx" },
    .comment = "//",
    .injections = @embedFile("tree-sitter-cpp/queries/injections.scm"),
};

pub const css = .{
    .color = 0x3d8fc6,
    .icon = "󰌜",
    .extensions = &[_][]const u8{"css"},
    .comment = "//",
};

pub const diff = .{
    .extensions = &[_][]const u8{ "diff", "patch" },
    .comment = "#",
};

pub const dockerfile = .{
    .color = 0x019bc6,
    .icon = "",
    .extensions = &[_][]const u8{ "Dockerfile", "dockerfile", "docker", "Containerfile", "container" },
    .comment = "#",
};

pub const dtd = .{
    .icon = "󰗀",
    .extensions = &[_][]const u8{"dtd"},
    .comment = "<!--",
    .highlights = @embedFile("tree-sitter-xml/dtd/queries/highlights.scm"),
};

pub const fish = .{
    .extensions = &[_][]const u8{"fish"},
    .comment = "#",
    .parser = @import("file_type.zig").Parser("fish"),
    .highlights = @embedFile("tree-sitter-fish/queries/highlights.scm"),
};

pub const @"git-rebase" = .{
    .color = 0xf34f29,
    .icon = "",
    .extensions = &[_][]const u8{"git-rebase-todo"},
    .comment = "#",
};

pub const gitcommit = .{
    .color = 0xf34f29,
    .icon = "",
    .extensions = &[_][]const u8{"COMMIT_EDITMSG"},
    .comment = "#",
    .injections = @embedFile("tree-sitter-gitcommit/queries/injections.scm"),
};

pub const go = .{
    .color = 0x00acd7,
    .icon = "󰟓",
    .extensions = &[_][]const u8{"go"},
    .comment = "//",
};

pub const haskell = .{
    .color = 0x5E5185,
    .icon = "󰲒",
    .extensions = &[_][]const u8{"hs"},
    .comment = "--",
};

pub const html = .{
    .color = 0xe54d26,
    .icon = "󰌝",
    .extensions = &[_][]const u8{"html"},
    .comment = "<!--",
    .injections = @embedFile("tree-sitter-html/queries/injections.scm"),
};

pub const java = .{
    .color = 0xEA2D2E,
    .icon = "",
    .extensions = &[_][]const u8{"java"},
    .comment = "//",
};

pub const javascript = .{
    .color = 0xf0db4f,
    .icon = "󰌞",
    .extensions = &[_][]const u8{"js"},
    .comment = "//",
    .injections = @embedFile("tree-sitter-javascript/queries/injections.scm"),
};

pub const json = .{
    .extensions = &[_][]const u8{"json"},
    .comment = "//",
};

pub const lua = .{
    .color = 0x000080,
    .icon = "󰢱",
    .extensions = &[_][]const u8{"lua"},
    .comment = "--",
    .injections = @embedFile("tree-sitter-lua/queries/injections.scm"),
    .first_line_matches = .{ .prefix = "--", .content = "lua" },
};

pub const make = .{
    .extensions = &[_][]const u8{ "makefile", "Makefile", "MAKEFILE", "GNUmakefile", "mk", "mak", "dsp" },
    .comment = "#",
};

pub const markdown = .{
    .color = 0x000000,
    .icon = "󰍔",
    .extensions = &[_][]const u8{"md"},
    .comment = "<!--",
    .highlights = @embedFile("tree-sitter-markdown/tree-sitter-markdown/queries/highlights.scm"),
    .injections = @embedFile("tree-sitter-markdown/tree-sitter-markdown/queries/injections.scm"),
};

pub const @"markdown-inline" = .{
    .color = 0x000000,
    .icon = "󰍔",
    .extensions = &[_][]const u8{},
    .comment = "<!--",
    .highlights = @embedFile("tree-sitter-markdown/tree-sitter-markdown-inline/queries/highlights.scm"),
    .injections = @embedFile("tree-sitter-markdown/tree-sitter-markdown-inline/queries/injections.scm"),
};

pub const nasm = .{
    .extensions = &[_][]const u8{ "asm", "nasm" },
    .comment = "#",
    .injections = @embedFile("tree-sitter-nasm/queries/injections.scm"),
};

pub const ninja = .{
    .extensions = &[_][]const u8{"ninja"},
    .comment = "#",
};

pub const nix = .{
    .color = 0x5277C3,
    .icon = "󱄅",
    .extensions = &[_][]const u8{"nix"},
    .comment = "#",
    .injections = @embedFile("tree-sitter-nix/queries/injections.scm"),
};

pub const ocaml = .{
    .color = 0xF18803,
    .icon = "",
    .extensions = &[_][]const u8{ "ml", "mli" },
    .comment = "(*",
};

pub const openscad = .{
    .color = 0x000000,
    .icon = "󰻫",
    .extensions = &[_][]const u8{"scad"},
    .comment = "//",
    .injections = @embedFile("tree-sitter-openscad/queries/injections.scm"),
};

pub const org = .{
    .icon = "",
    .extensions = &[_][]const u8{"org"},
    .comment = "#",
};

pub const php = .{
    .color = 0x6181b6,
    .icon = "󰌟",
    .extensions = &[_][]const u8{"php"},
    .comment = "//",
    .injections = @embedFile("tree-sitter-php/queries/injections.scm"),
};

pub const purescript = .{
    .color = 0x14161a,
    .icon = "",
    .extensions = &[_][]const u8{"purs"},
    .comment = "--",
    .injections = @embedFile("tree-sitter-purescript/queries/injections.scm"),
};

pub const python = .{
    .color = 0xffd845,
    .icon = "󰌠",
    .extensions = &[_][]const u8{"py"},
    .comment = "#",
    .first_line_matches = .{ .prefix = "#!", .content = "/bin/bash" },
};

pub const regex = .{
    .extensions = &[_][]const u8{},
    .comment = "#",
};

pub const ruby = .{
    .color = 0xd91404,
    .icon = "󰴭",
    .extensions = &[_][]const u8{"rb"},
    .comment = "#",
};

pub const rust = .{
    .color = 0x000000,
    .icon = "󱘗",
    .extensions = &[_][]const u8{"rs"},
    .comment = "//",
    .injections = @embedFile("tree-sitter-rust/queries/injections.scm"),
};

pub const scheme = .{
    .extensions = &[_][]const u8{ "scm", "ss", "el" },
    .comment = ";",
};

pub const @"ssh-config" = .{
    .extensions = &[_][]const u8{".ssh/config"},
    .comment = "#",
};

pub const toml = .{
    .extensions = &[_][]const u8{ "toml" },
    .comment = "#",
};

pub const typescript = .{
    .color = 0x007acc,
    .icon = "󰛦",
    .extensions = &[_][]const u8{ "ts", "tsx" },
    .comment = "//",
};

pub const xml = .{
    .icon = "󰗀",
    .extensions = &[_][]const u8{"xml"},
    .comment = "<!--",
    .highlights = @embedFile("tree-sitter-xml/xml/queries/highlights.scm"),
    .first_line_matches = .{ .prefix = "<?xml " },
};

pub const zig = .{
    .color = 0xf7a41d,
    .icon = "",
    .extensions = &[_][]const u8{ "zig", "zon" },
    .comment = "//",
    .injections = @embedFile("tree-sitter-zig/queries/injections.scm"),
};

pub const ziggy = .{
    .color = 0xf7a41d,
    .icon = "",
    .extensions = &[_][]const u8{ "ziggy" },
    .comment = "//",
    .highlights = @embedFile("tree-sitter-ziggy/tree-sitter-ziggy/queries/highlights.scm"),
};
