pub const agda = .{};

pub const astro = .{
    .language_server = .{ "astro-ls", "--stdio" },
};

pub const bash = .{
    .language_server = .{ "bash-language-server", "start" },
    .formatter = .{ "shfmt", "--indent", "4" },
};

pub const c = .{
    .language_server = .{"clangd"},
    .formatter = .{"clang-format"},
};

pub const @"c-sharp" = .{
    .language_server = .{ "OmniSharp", "-lsp" },
    .formatter = .{ "csharpier", "format" },
};

pub const conf = .{};

pub const cmake = .{
    .language_server = .{"cmake-language-server"},
    .formatter = .{"cmake-format"},
};

pub const cpp = .{
    .language_server = .{"clangd"},
    .formatter = .{"clang-format"},
};

pub const css = .{
    .language_server = .{ "vscode-css-language-server", "--stdio" },
};

pub const diff = .{};

pub const dockerfile = .{};

pub const dtd = .{};

pub const elixir = .{
    .language_server = .{"elixir-ls"},
    .formatter = .{ "mix", "format", "-" },
};

pub const fish = .{};

pub const fsharp = .{
    .language_server = .{"fsautocomplete"},
};

pub const @"git-rebase" = .{};

pub const gitcommit = .{};

pub const gleam = .{
    .language_server = .{ "gleam", "lsp" },
    .formatter = .{ "gleam", "format", "--stdin" },
};

pub const go = .{
    .language_server = .{"gopls"},
    .formatter = .{"gofmt"},
};

pub const hare = .{};

pub const haskell = .{
    .language_server = .{ "haskell-language-server-wrapper", "lsp" },
};

pub const html = .{
    .language_server = .{ "superhtml", "lsp" }, // https://github.com/kristoff-it/super-html.git
    .formatter = .{ "superhtml", "fmt", "--stdin" },
};

pub const superhtml = .{
    .language_server = .{ "superhtml", "lsp" },
    .formatter = .{ "superhtml", "fmt", "--stdin-super" },
};

pub const hurl = .{};

pub const java = .{};

pub const javascript = .{
    .language_server = .{ "typescript-language-server", "--stdio" },
    .formatter = .{ "prettier", "--parser", "typescript" },
};

pub const json = .{
    .language_server = .{ "vscode-json-language-server", "--stdio" },
    .formatter = .{ "prettier", "--parser", "json" },
};

pub const julia = .{
    .language_server = .{ "julia", "-e", "using LanguageServer; runserver()" },
    .formatter = .{ "julia", "-e", "using JuliaFormatter; print(format_text(read(stdin, String)))" },
};

pub const kdl = .{};

pub const lua = .{
    .language_server = .{"lua-lsp"},
};

pub const mail = .{};

pub const make = .{};

pub const markdown = .{
    .language_server = .{ "marksman", "server" },
    .formatter = .{ "prettier", "--parser", "markdown" },
};

pub const @"markdown-inline" = .{};

pub const nasm = .{};

pub const nim = .{
    .language_server = .{"nimlangserver"},
};

pub const nimble = .{};

pub const ninja = .{};

pub const nix = .{
    .language_server = .{"nixd"},
    .formatter = .{"alejandra"},
};

pub const nu = .{
    .language_server = .{ "nu", "--lsp" },
};

pub const ocaml = .{
    .language_server = .{ "ocamllsp", "--fallback-read-dot-merlin" },
    .formatter = .{ "ocamlformat", "--profile=ocamlformat", "-" },
};

pub const odin = .{
    .language_server = .{"ols"},
    .formatter = .{ "odinfmt", "-stdin" },
};

pub const openscad = .{
    .language_server = .{"openscad-lsp"},
};

pub const org = .{};

pub const php = .{
    .language_server = .{ "intelephense", "--stdio" },
};

pub const powershell = .{};

pub const proto = .{};

pub const purescript = .{};

pub const python = .{
    .language_server = .{ "ruff", "server" },
    .formatter = .{ "ruff", "format", "-" },
};

pub const regex = .{};

pub const rpmspec = .{};

pub const rst = .{
    .language_server = .{"esbonio"},
};

pub const ruby = .{
    .language_server = .{"ruby-lsp"},
};

pub const rust = .{
    .language_server = .{"rust-analyzer"},
    .formatter = .{"rustfmt"},
};

pub const scheme = .{};

pub const sql = .{};

pub const @"ssh-config" = .{};

pub const swift = .{
    .language_server = .{"sourcekit-lsp"},
    .formatter = .{"swift-format"},
};

pub const verilog = .{
    .language_server = .{"verible-verilog-ls"},
    .formatter = .{ "verible-verilog-format", "-" },
};

pub const toml = .{};

pub const typescript = .{
    .language_server = .{ "typescript-language-server", "--stdio" },
    .formatter = .{ "prettier", "--parser", "typescript" },
};

pub const typst = .{
    .language_server = .{"tinymist"},
};

pub const uxntal = .{};

pub const vim = .{};

pub const xml = .{
    .formatter = .{ "xmllint", "--format", "-" },
};

pub const yaml = .{};

pub const zig = .{
    .language_server = .{"zls"},
    .formatter = .{ "zig", "fmt", "--stdin" },
};

pub const ziggy = .{};

pub const @"ziggy-schema" = .{};
