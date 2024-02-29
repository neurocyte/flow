# Flow Control: a programmer's text editor

This is my Zig text editor. It is very much a work-in-progress, but far enough along that I am daily driving it.


https://github.com/neurocyte/flow/assets/1552770/97aae817-c209-4c08-bc65-0a0bf1f2d4c6

# Building

Build with the provided zig wrapper:
```shell
./zig build -Doptimize=ReleaseFast
```

The zig wrapper just fetches a known good version of zig nightly and places it
in the .cache directory. Or use your own version of zig. Be sure to use a version
at least as high as the version used be the zig wrapper. It's stored in `build.zig.version`.

Also, make sure your system meets the requirements listed below.

Run with:
```shell
zig-out/bin/flow
```

Place it in your path for convenient access.

See --help for full command line.

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
