const std = @import("std");

pub fn build(b: *std.Build) void {
    const use_tree_sitter = b.option(bool, "use_tree_sitter", "Enable tree-sitter (default: yes)") orelse true;
    const options = b.addOptions();
    options.addOption(bool, "use_tree_sitter", use_tree_sitter);
    const options_mod = options.createModule();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tree_sitter_dep = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
    });

    const tree_sitter_host_dep = b.dependency("tree_sitter", .{
        .target = b.graph.host,
        .optimize = optimize,
    });

    const cbor_dep = b.dependency("cbor", .{
        .target = target,
        .optimize = optimize,
    });

    const ts_bin_query_gen = b.addExecutable(.{
        .name = "ts_bin_query_gen",
        .target = b.graph.host,
        .root_source_file = b.path("src/ts_bin_query_gen.zig"),
    });
    ts_bin_query_gen.linkLibC();
    ts_bin_query_gen.root_module.addImport("cbor", cbor_dep.module("cbor"));
    ts_bin_query_gen.root_module.addImport("treez", tree_sitter_host_dep.module("treez"));
    ts_bin_query_gen.root_module.addImport("build_options", options_mod);

    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "queries/cmake/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-agda/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-astro/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-bash/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-c-sharp/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-c/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-cpp/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-css/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-diff/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-dockerfile/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-elixir/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-git-rebase/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-gitcommit/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-gleam/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-go/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-fish/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-haskell/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-hare/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-html/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-hurl/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-java/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-javascript/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-jsdoc/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-json/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-julia/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-kdl/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-lua/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-mail/queries/mail/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-make/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-markdown/tree-sitter-markdown/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-markdown/tree-sitter-markdown-inline/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-nasm/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-nim/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-ninja/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-nix/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-nu/queries/nu/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-ocaml/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-odin/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-openscad/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-org/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-php/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-proto/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-python/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-purescript/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-regex/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-rpmspec/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-ruby/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-rust/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-ssh-config/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-scala/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-scheme/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-superhtml/tree-sitter-superhtml/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-sql/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-swift/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-toml/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-typescript/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-typst/queries/typst/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-uxntal/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-vim/queries/vim/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-xml/queries/dtd/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-xml/queries/xml/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-yaml/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-zig/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-ziggy/tree-sitter-ziggy/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-ziggy/tree-sitter-ziggy-schema/queries/highlights.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "nvim-treesitter/queries/verilog/highlights.scm");

    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "queries/cmake/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-astro/queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-cpp/queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-elixir/queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-gitcommit/queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-hare/queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-html/queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-hurl/queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-javascript/queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-kdl/queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-lua/queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-markdown/tree-sitter-markdown-inline/queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-markdown/tree-sitter-markdown/queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-nasm/queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-nix/queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-nu/queries/nu/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-odin/queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-openscad/queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-php/queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-purescript/queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-purescript/vim_queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-rust/queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-superhtml/tree-sitter-superhtml/queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-swift/queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-typst/queries/typst/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-uxntal/queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-vim/queries/vim/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "tree-sitter-zig/queries/injections.scm");
    ts_queryfile(b, tree_sitter_dep, ts_bin_query_gen, "nvim-treesitter/queries/verilog/injections.scm");

    const syntax_mod = b.addModule("syntax", .{
        .root_source_file = b.path("src/syntax.zig"),
        .imports = &.{
            .{ .name = "build_options", .module = options_mod },
            .{ .name = "cbor", .module = cbor_dep.module("cbor") },
            .{ .name = "treez", .module = tree_sitter_dep.module("treez") },
        },
    });

    if (use_tree_sitter) {
        const ts_bin_query_gen_step = b.addRunArtifact(ts_bin_query_gen);
        const output = ts_bin_query_gen_step.addOutputFileArg("bin_queries.cbor");
        syntax_mod.addAnonymousImport("syntax_bin_queries", .{ .root_source_file = output });
    }
}

fn ts_queryfile(b: *std.Build, dep: *std.Build.Dependency, bin_gen: *std.Build.Step.Compile, comptime sub_path: []const u8) void {
    const module = b.createModule(.{ .root_source_file = dep.path(sub_path) });
    bin_gen.root_module.addImport(sub_path, module);
}
