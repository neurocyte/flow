# Flow Control: a programmer's text editor

This is my Zig text editor. It is very much a work-in-progress, but far enough along that I am daily driving it.


https://github.com/neurocyte/flow/assets/1552770/97aae817-c209-4c08-bc65-0a0bf1f2d4c6

# Requirements
- A modern terminal with 24bit color and kitty keyboard protocol support. Kitty and
    ghostty are the only recommended terminals at this time. Most other terminals
    will work, but with reduced functionality.
- NerdFonts support
- Linux or MacOS (help porting to *BSD or Windows is welcome!)
- A UTF-8 locale (very important!)

# Building

Make sure your system meets the requirements listed above.

Flow tracks zig master most of the time. Build with:

```shell
zig build -Doptimize=ReleaseFast
```

Or, for a slightly smaller executable (with no debug info):

```shell
zig build -Doptimize=ReleaseSmall
```

Sometimes zig master may introduce breaking changes and Flow may take a few days to
catch up. In that case there is a simple zig wrapper script provided that will download
and build with the last known compatible version of zig. The version is stored in
`build.zig.version`.

Build with the zig wrapper:
```shell
./zig build -Doptimize=ReleaseFast
```

The zig wrapper places the downloaded zig compiler in the `.cache` directory and does
not touch your system. It requires `bash`, `curl` and `jq` to run.

Run with:
```shell
zig-out/bin/flow
```

# Running Flow Control

The output binary is:

```shell
zig-out/bin/flow
```

Place it in your path for convenient access:

```shell
sudo cp zig-out/bin/flow /usr/local/bin
```

Flow Control is a single statically linked binary. No further runtime is required.
You may install it on another system by simply copying the binary.

```shell
scp zig-out/bin/flow root@otherhost:/usr/local/bin
```

Logs, traces and per-project most recently used file lists are stored in the
standard user runtime cache directory. Usually `~/.cache/flow`.

Configuration is mostly dynamically maintained with various commands in the UI.
It stored under the standard user configuration path. Usually `~/.config/flow`.

Files to load may be specifed on the command line:

```shell
flow fileA.zig fileB.zig
```

Common target line specifiers are supported to:

```shell
flow file.txt:123
```

Or Vim style:

```shell
flow file.txt +123
```

Use the --language option to force the file type of a file:

```shell
flow --language bash ~/.bash_profile
```

See `flow --help` for the full list of command line options.

# Terminal configuration

Kitty, Ghostty and most other terminals have default keybindings that conflict
with common editor commands. I highly recommend rebinding them to keys that are
not generally used anywhere else.

For Kitty rebinding `kitty_mod` is usually enough:
```
kitty_mod ctrl+alt
```

For Ghostty each conflicting binding has to be reconfigured individually.

# Features
- fast TUI interface. no user interaction should take longer than one frame (6ms) (even debug builds)
- tree sitter based syntax highlighting
- linting (diagnostics) and code navigation (goto definition) via language server
- multi cursor editing support
- first class mouse support (yes, even with a scrollbar that actually works properly!)
- vscode compatible keybindings (thanks to kitty keyboard protocol)
- vim compatible keybindings (at least the basics, more to come)
- good unicode support
- hybrid rope/piece-table buffer for fast loading, saving and editing with hundreds of cursors
- theme support (compatible with vscode themes via the flow-themes project)
- infinite undo/redo (at least until you run out of ram)
- stuff I've forgotten to mention...

# Features in progress (aka, the road to 1.0)
- completion UI/LSP support for completion
- find in files
- command palette
- persistent undo/redo
- file watcher for auto reload

# Features planned for the future
- multi tty support (shared editor sessions across multiple ttys)
- multi host editing
- multi user editing

# Community

![Discord](https://img.shields.io/discord/1214308467553341470)

Join our [Discord](https://discord.com/invite/4wvteUPphx) server or use the discussions section here on GitHub
to meet with other Flow users!
