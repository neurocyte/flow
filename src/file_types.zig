pub const agda = .{
    .description = "Agda",
    .extensions = .{"agda"},
    .comment = "--",
};

pub const bash = .{
    .description = "Bash",
    .color = 0x3e474a,
    .icon = "󱆃",
    .extensions = .{ "sh", "bash", ".profile" },
    .comment = "#",
    .first_line_matches = .{ .prefix = "#!", .content = "sh" },
    .formatter = .{ "shfmt", "--indent", "4" },
    .language_server = .{ "bash-language-server", "start" },
};

pub const c = .{
    .description = "C",
    .icon = "",
    .extensions = .{"c"},
    .comment = "//",
    .formatter = .{"clang-format"},
    .language_server = .{"clangd"},
};

pub const @"c-sharp" = .{
    .description = "C#",
    .color = 0x68217a,
    .icon = "󰌛",
    .extensions = .{"cs"},
    .comment = "//",
    .language_server = .{ "omnisharp", "-lsp" },
};

pub const conf = .{
    .description = "Config",
    .color = 0x000000,
    .icon = "",
    .extensions = .{ "conf", "config", ".gitconfig" },
    .highlights = fish.highlights,
    .comment = "#",
    .parser = fish.parser,
};

pub const cmake = .{
    .description = "CMake",
    .color = 0x004078,
    .icon = "",
    .extensions = .{ "CMakeLists.txt", "cmake", "cmake.in" },
    .comment = "#",
    .highlights = "queries/cmake/highlights.scm",
    .injections = "queries/cmake/injections.scm",
    .formatter = .{"cmake-format"},
    .language_server = .{"cmake-language-server"},
};

pub const cpp = .{
    .description = "C++",
    .color = 0x9c033a,
    .icon = "",
    .extensions = .{ "cc", "cpp", "cxx", "hpp", "hxx", "h", "ipp", "ixx" },
    .comment = "//",
    .highlights_list = .{
        "tree-sitter-c/queries/highlights.scm",
        "tree-sitter-cpp/queries/highlights.scm",
    },
    .injections = "tree-sitter-cpp/queries/injections.scm",
    .formatter = .{"clang-format"},
    .language_server = .{"clangd"},
};

pub const css = .{
    .description = "CSS",
    .color = 0x3d8fc6,
    .icon = "󰌜",
    .extensions = .{"css"},
    .comment = "//",
};

pub const diff = .{
    .description = "Diff",
    .extensions = .{ "diff", "patch" },
    .comment = "#",
};

pub const dockerfile = .{
    .description = "Docker",
    .color = 0x019bc6,
    .icon = "",
    .extensions = .{ "Dockerfile", "dockerfile", "docker", "Containerfile", "container" },
    .comment = "#",
};

pub const dtd = .{
    .description = "DTD",
    .icon = "󰗀",
    .extensions = .{"dtd"},
    .comment = "<!--",
    .highlights = "tree-sitter-xml/queries/dtd/highlights.scm",
};

pub const elixir = .{
    .description = "Elixir",
    .color = 0x4e2a8e,
    .icon = "",
    .extensions = .{ "ex", "exs" },
    .comment = "#",
    .injections = "tree-sitter-elixir/queries/injections.scm",
    .formatter = .{ "mix", "format", "-" },
    .language_server = .{"elixir-ls"},
};

pub const fish = .{
    .description = "Fish",
    .extensions = .{"fish"},
    .comment = "#",
    .parser = @import("file_type.zig").Parser("fish"),
    .highlights = "tree-sitter-fish/queries/highlights.scm",
};

pub const @"git-rebase" = .{
    .description = "Git (rebase)",
    .color = 0xf34f29,
    .icon = "",
    .extensions = .{"git-rebase-todo"},
    .comment = "#",
};

pub const gitcommit = .{
    .description = "Git (commit)",
    .color = 0xf34f29,
    .icon = "",
    .extensions = .{"COMMIT_EDITMSG"},
    .comment = "#",
    .injections = "tree-sitter-gitcommit/queries/injections.scm",
};

pub const gleam = .{
    .description = "Gleam",
    .color = 0xffaff3,
    .icon = "󰦥",
    .extensions = .{"gleam"},
    .comment = "//",
    .language_server = .{ "gleam", "lsp" },
    .formatter = .{ "gleam", "format", "--stdin" },
};

pub const go = .{
    .description = "Go",
    .color = 0x00acd7,
    .icon = "󰟓",
    .extensions = .{"go"},
    .comment = "//",
    .language_server = .{"gopls"},
    .formatter = .{"gofmt"},
};

pub const hare = .{
    .description = "Hare",
    .extensions = .{"ha"},
    .comment = "//",
};

pub const haskell = .{
    .description = "Haskell",
    .color = 0x5E5185,
    .icon = "󰲒",
    .extensions = .{"hs"},
    .comment = "--",
    .language_server = .{ "haskell-language-server-wrapper", "lsp" },
};

pub const html = .{
    .description = "HTML",
    .color = 0xe54d26,
    .icon = "󰌝",
    .extensions = .{"html"},
    .comment = "<!--",
    .injections = "tree-sitter-html/queries/injections.scm",
    .language_server = .{ "superhtml", "lsp" }, // https://github.com/kristoff-it/super-html.git
    .formatter = .{ "superhtml", "fmt", "--stdin" },
};

pub const superhtml = .{
    .description = "SuperHTML",
    .color = 0xe54d26,
    .icon = "󰌝",
    .extensions = .{"shtml"},
    .comment = "<!--",
    .highlights = "tree-sitter-superhtml/tree-sitter-superhtml/queries/highlights.scm",
    .injections = "tree-sitter-superhtml/tree-sitter-superhtml/queries/injections.scm",
    .language_server = .{ "superhtml", "lsp" },
    .formatter = .{ "superhtml", "fmt", "--stdin-super" },
};

pub const java = .{
    .description = "Java",
    .color = 0xEA2D2E,
    .icon = "",
    .extensions = .{"java"},
    .comment = "//",
};

pub const javascript = .{
    .description = "JavaScript",
    .color = 0xf0db4f,
    .icon = "󰌞",
    .extensions = .{"js"},
    .comment = "//",
    .injections = "tree-sitter-javascript/queries/injections.scm",
    .language_server = .{ "deno", "lsp" },
};

pub const json = .{
    .description = "JSON",
    .extensions = .{"json"},
    .comment = "//",
    .language_server = .{ "deno", "lsp" },
    .formatter = .{ "hjson", "-j" },
};

pub const julia = .{
    .description = "Julia",
    .color = 0x4D64AE,
    .icon = "",
    .extensions = .{"jl"},
    .comment = "#",
    .language_server = .{ "julia", "-e", "using LanguageServer; runserver()" },
};

pub const kdl = .{
    .description = "KDL",
    .color = 0x000000,
    .icon = "",
    .extensions = .{"kdl"},
    .comment = "//",
};

pub const lua = .{
    .description = "Lua",
    .color = 0x02027d,
    .icon = "󰢱",
    .extensions = .{"lua"},
    .comment = "--",
    .injections = "tree-sitter-lua/queries/injections.scm",
    .first_line_matches = .{ .prefix = "--", .content = "lua" },
    .language_server = .{"lua-lsp"},
};

pub const mail = .{
    .description = "E-Mail",
    .icon = "󰇮",
    .extensions = .{ "eml", "mbox" },
    .comment = ">",
    .highlights = "tree-sitter-mail/queries/mail/highlights.scm",
    .first_line_matches = .{ .prefix = "From" },
};

pub const make = .{
    .description = "Make",
    .extensions = .{ "makefile", "Makefile", "MAKEFILE", "GNUmakefile", "mk", "mak", "dsp" },
    .comment = "#",
};

pub const markdown = .{
    .description = "Markdown",
    .color = 0x000000,
    .icon = "󰍔",
    .extensions = .{"md"},
    .comment = "<!--",
    .highlights = "tree-sitter-markdown/tree-sitter-markdown/queries/highlights.scm",
    .injections = "tree-sitter-markdown/tree-sitter-markdown/queries/injections.scm",
    .language_server = .{ "deno", "lsp" },
};

pub const @"markdown-inline" = .{
    .description = "Markdown (inline)",
    .color = 0x000000,
    .icon = "󰍔",
    .extensions = .{},
    .comment = "<!--",
    .highlights = "tree-sitter-markdown/tree-sitter-markdown-inline/queries/highlights.scm",
    .injections = "tree-sitter-markdown/tree-sitter-markdown-inline/queries/injections.scm",
};

pub const nasm = .{
    .description = "Assembly Language (nasm)",
    .extensions = .{ "asm", "nasm" },
    .comment = "#",
    .injections = "tree-sitter-nasm/queries/injections.scm",
};

pub const nim = .{
    .description = "Nim",
    .color = 0xffe953,
    .icon = "",
    .extensions = .{"nim"},
    .comment = "#",
    .language_server = .{"nimlangserver"},
};

pub const nimble = .{
    .description = "Nimble (nim)",
    .color = 0xffe953,
    .icon = "",
    .extensions = .{"nimble"},
    .highlights = toml.highlights,
    .comment = "#",
    .parser = toml.parser,
};

pub const ninja = .{
    .description = "Ninja",
    .extensions = .{"ninja"},
    .comment = "#",
};

pub const nix = .{
    .description = "Nix",
    .color = 0x5277C3,
    .icon = "󱄅",
    .extensions = .{"nix"},
    .comment = "#",
    .injections = "tree-sitter-nix/queries/injections.scm",
};

pub const nu = .{
    .description = "Nushell",
    .color = 0x3AA675,
    .icon = ">",
    .extensions = .{ "nu", "nushell" },
    .comment = "#",
    .language_server = .{ "nu", "--lsp" },
    .highlights = "tree-sitter-nu/queries/nu/highlights.scm",
    .injections = "tree-sitter-nu/queries/nu/injections.scm",
};

pub const ocaml = .{
    .description = "OCaml",
    .color = 0xF18803,
    .icon = "",
    .extensions = .{ "ml", "mli" },
    .comment = "(*",
    .formatter = .{ "ocamlformat", "--profile=ocamlformat", "-" },
    .language_server = .{ "ocamllsp", "--fallback-read-dot-merlin" },
};

pub const odin = .{
    .description = "Odin",
    .extensions = .{"odin"},
    .comment = "//",
    .parser = @import("file_type.zig").Parser("odin"),
    .injections = "tree-sitter-odin/queries/injections.scm",
    .language_server = .{"ols"},
    .formatter = .{ "odinfmt", "-stdin" },
};

pub const openscad = .{
    .description = "OpenSCAD",
    .color = 0x000000,
    .icon = "󰻫",
    .extensions = .{"scad"},
    .comment = "//",
    .injections = "tree-sitter-openscad/queries/injections.scm",
    .language_server = .{"openscad-lsp"},
};

pub const org = .{
    .description = "Org Mode",
    .icon = "",
    .extensions = .{"org"},
    .comment = "#",
};

pub const php = .{
    .description = "PHP",
    .color = 0x6181b6,
    .icon = "󰌟",
    .extensions = .{"php"},
    .comment = "//",
    .injections = "tree-sitter-php/queries/injections.scm",
};

pub const purescript = .{
    .description = "PureScript",
    .color = 0x14161a,
    .icon = "",
    .extensions = .{"purs"},
    .comment = "--",
    .injections = "tree-sitter-purescript/queries/injections.scm",
};

pub const python = .{
    .description = "Python",
    .color = 0xffd845,
    .icon = "󰌠",
    .extensions = .{ "py", "pyi" },
    .comment = "#",
    .first_line_matches = .{ .prefix = "#!", .content = "python" },
    .language_server = .{"pylsp"},
};

pub const regex = .{
    .description = "Regular expression",
    .extensions = .{},
    .comment = "#",
};

pub const ruby = .{
    .description = "Ruby",
    .color = 0xd91404,
    .icon = "󰴭",
    .extensions = .{"rb"},
    .comment = "#",
    .language_server = .{"ruby-lsp"},
};

pub const rust = .{
    .description = "Rust",
    .color = 0x000000,
    .icon = "󱘗",
    .extensions = .{"rs"},
    .comment = "//",
    .injections = "tree-sitter-rust/queries/injections.scm",
    .language_server = .{"rust-analyzer"},
};

pub const scheme = .{
    .description = "Scheme",
    .extensions = .{ "scm", "ss", "el" },
    .comment = ";",
};

pub const @"ssh-config" = .{
    .description = "SSH config",
    .extensions = .{".ssh/config"},
    .comment = "#",
};

pub const swift = .{
    .description = "Swift",
    .color = 0xf05138,
    .icon = "󰛥",
    .extensions = .{ "swift", "swiftinterface" },
    .comment = "//",
    .language_server = .{"sourcekit-lsp"},
    .formatter = .{"swift-format"},
};

pub const toml = .{
    .description = "TOML",
    .extensions = .{ "toml", "ini" },
    .comment = "#",
    .highlights = "tree-sitter-toml/queries/highlights.scm",
    .parser = @import("file_type.zig").Parser("toml"),
};

pub const typescript = .{
    .description = "TypeScript",
    .color = 0x007acc,
    .icon = "󰛦",
    .extensions = .{ "ts", "tsx" },
    .comment = "//",
    .language_server = .{ "deno", "lsp" },
};

pub const typst = .{
    .description = "Typst",
    .color = 0x23b6bc,
    .icon = "t",
    .extensions = .{ "typst", "typ" },
    .comment = "//",
    .language_server = .{"tinymist"},
    .highlights = "tree-sitter-typst/queries/typst/highlights.scm",
    .injections = "tree-sitter-typst/queries/typst/injections.scm",
};

pub const vim = .{
    .description = "Vimscript",
    .color = 0x007f00,
    .icon = "",
    .extensions = .{"vim"},
    .comment = "\"",
    .highlights = "tree-sitter-vim/queries/vim/highlights.scm",
    .injections = "tree-sitter-vim/queries/vim/injections.scm",
};

pub const xml = .{
    .description = "XML",
    .icon = "󰗀",
    .extensions = .{"xml"},
    .comment = "<!--",
    .highlights = "tree-sitter-xml/queries/xml/highlights.scm",
    .first_line_matches = .{ .prefix = "<?xml " },
    .formatter = .{ "xmllint", "--format", "-" },
};

pub const yaml = .{
    .description = "YAML",
    .color = 0x000000,
    .icon = "",
    .extensions = .{ "yaml", "yml" },
    .comment = "#",
};

pub const zig = .{
    .description = "Zig",
    .color = 0xf7a41d,
    .icon = "",
    .extensions = .{ "zig", "zon" },
    .comment = "//",
    .formatter = .{ "zig", "fmt", "--stdin" },
    .language_server = .{"zls"},
    .injections = "tree-sitter-zig/queries/injections.scm",
};

pub const ziggy = .{
    .description = "Ziggy",
    .color = 0xf7a41d,
    .icon = "",
    .extensions = .{ "ziggy", "zgy" },
    .comment = "//",
    .highlights = "tree-sitter-ziggy/tree-sitter-ziggy/queries/highlights.scm",
};

pub const @"ziggy-schema" = .{
    .description = "Ziggy (schema)",
    .color = 0xf7a41d,
    .icon = "",
    .extensions = .{ "ziggy-schema", "zyg-schema" },
    .comment = "//",
    .highlights = "tree-sitter-ziggy/tree-sitter-ziggy-schema/queries/highlights.scm",
};
