# Flow Control: a programmer's text editor

This is my Zig text editor. It is very much a work-in-progress, but far enough along that I am daily driving it.


https://github.com/neurocyte/flow/assets/1552770/97aae817-c209-4c08-bc65-0a0bf1f2d4c6

# Building

Make sure your system meets the requirements listed below.

Flow tracks zig master most of the time. Build with:

```shell
zig build -Doptimize=ReleaseFast
```

Sometime zig master may introduce breaking changes and Flow may take a few days to
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

Place it in your path for convenient access.

See --help for full command line.

## MacOS

On MacOS you will need to link Flow against a MacOS build of notcurses 3.0.9. This
is easiest with `brew`:

```shell
brew install notcurses
zig build -Duse_system_notcurses=true --search-prefix /usr/local
```

# Terminal configuration

Kitty, Ghostty and most other terminals have default keybindings that conflict
with common editor commands. I highly recommend rebinding them to keys that are
not generally used anywhere else.

For Kitty rebinding `kitty_mod` is usually enough:
```
kitty_mod ctrl+alt
```

For Ghostty each conflicting binding has to be reconfigured individually.

# Requirements
- A modern terminal with 24bit color and kitty keyboard protocol support (kitty and ghostty are the only recommended terminals at this time)
- NerdFonts support
- Linux or MacOS (help porting to *BSD or Windows is welcome!)
- A UTF-8 locale (very important!)

# Features
- fast TUI interface. no user interaction should take longer than one frame (6ms) (even debug builds)
- tree sitter based syntax highlighting
- multi cursor editing support
- first class mouse support (yes, even with a scrollbar that actually works properly!)
- vscode compatible keybindings (thanks to kitty keyboard protocol)
- vim compatible keybindings (at least the basics, more to come)
- good unicode support
- hybrid rope/piece-table buffer for fast loading, saving and editing with hundreds of cursors
- theme support (compatible with vscode themes via the flow-themes project)
- infinite undo/redo (at least until you run out of ram)
- stuff I've forgotten to mention...

# Features in progress
- LSP support for linting and navigating
- find in files
- multi tty support (shared editor sessions across multiple ttys)
- command palette
- completion UI
- persistent undo/redo

# Features planned for the future
- multi host editing
- multi user editing
