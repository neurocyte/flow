# Flow Control: a programmer's text editor

## Terminal configuration

Most terminals have default keybindings that conflict with common editor
commands. I highly recommend rebinding them to keys that are not generally
used anywhere else.

For Kitty rebinding `kitty_mod` by adding this line to your kitty.conf is
usually enough:

```
kitty_mod ctrl+alt
```

For other terminals you will probably have to disable or rebind them each
individually.

## Searching

Press ctrl+f to search this help file. Type a search term and press
ctrl+n/ctrl+p or f3/shift+f3 to jump through the matches. Press Enter to
exit find mode at the current match or Escape to return to your starting
point.

Normal text search and regular expression search are supported. While the
find prompt is open:

- alt+c => Cycle case mode: auto, exact, case-folded
- alt+r => Toggle between normal search and regular expression search

The auto case mode is smart-case: a query with no uppercase letters searches
case-folded, while a query containing uppercase letters searches exactly.
Regex search has the same case modes: regex auto, regex exact and regex
case-folded.

The selected find mode is persisted between sessions.

## Messages and logs

Messages of issues regarding tasks that are not accomplished, like trying
to close flow with unsaved files, as well as other information are shown
briefly in the bottom status bar; most recent messages can be seen in the
log view too, to open it, use ctrl+shift+p > `View log`; it's possible to
make it taller dragging the toolbar with the mouse up or downwards.

## Input Modes

Flow Control supports multiple input modes that may be changed
interactively at runtime. The current input mode (and some other settings)
is persisted in the configuration file automatically.

- f4 => Cycle major input modes (flow, emacs, vim, helix,...)

The current input mode is displayed at the left side of the statusbar.

- ctrl+shift+p or alt+x => Show the command palette

The command palette allows you to fuzzy search and select commands to run.
It also shows any available keybind that may be used to run the command
without opening the palette.

- ctrl+f2 => Show all available commands and keybinds

This shows all currently available commands. Including commands that are
normally only executed via a keybinding. Selecting a command in this view
will insert the command name into the current document instead of executing
it. This is very useful for editing keybinding definition files.

Run the `Edit keybindings` command to customize the current keybinding
mode. It will write a customization file for the current mode into the
`keys` directory, under the same name as the current mode, and open it for
editing. This file inherits everything from the built-in mode of the same
name. So keybindings that are added or changed by future updates of Flow
Control are picked up automatically. Each sub-mode is an empty section you
can fill in: add new keybindings or override one by binding the same key to
another command. Delete the file from the `keys` directory to revert
entirely to the built-in mode. Changes to keybinding files take effect on
restart.

You can also create additional, independently named keybinding modes by saving a
file under a new name in the same directory. You can select the new mode
with `f4`.

Keybinding modes may inherit all non-conflicting keybindings from another
mode by adding an `inherit` option to the `settings` section of the keybind
file like this:

```json
{
    "settings": {
        "inherit": "vim",
    },
    "normal": {
    ...
```

This allows you to make only minor additions/changes to an existing builtin
mode without copying the whole mode and is easier to keep up-to-date.

Use the special value `<<builtin>>` to inherit from the built-in mode with
the same name as your file. This lets a file customize a built-in mode
while still inheriting from it, and is what `Edit keybindings` writes:

```json
{
    "settings": {
        "inherit": "<<builtin>>",
    },
    ...
```

A sub-mode that is left out of your file entirely is inherited whole from the
mode you inherit from, so you only need to include the sub-modes you actually
want to change.

Additionally, individual sub-modes may inherit all non-conflicting
keybindings from another sub-mode of the same mode by adding an `inherit`
option to the sub-mode section like this:

```json
    "normal": {
        "inherit": "project",
        ...
```

Multiple inheritance is supported with the `inherits` options like this:

```json
    "normal": {
        "inherits": ["project", "tasks"],
        ...
```

A sub-mode may inherit only the keybindings that begin with a particular
prefix key by using the `inherit_prefix` option. Each entry is a prefix key
followed by one or more parent sub-modes to copy the matching keybindings
from. For example, this makes every keybinding that starts with `ctrl+alt+a`
in the `project` mode also work in the `terminal` mode:

```json
    "terminal": {
        "inherit_prefix": [["ctrl+alt+a", "project"]],
        ...
```

The `inherit_breakout` option copies every keybinding from a parent sub-mode
and prepends a "breakout" prefix key to each, claiming that key in this
sub-mode. It is used to implement vim's insert-normal (`CTRL-O`) behaviour:
pressing the breakout key in insert mode runs a single normal mode command
and then returns to insert mode. For example:

```json
    "insert": {
        "inherit_breakout": [["<C-o>", "normal"]],
        ...
```

A numeric count typed before the command (e.g. `<C-o>3w`) is not currently
supported.

### Flow mode

The default input mode, called just flow, is based on common GUI
programming editors. It most closely resembles Visual Studio Code, but also
takes some inspiration from Emacs and others. This mode focuses on powerful
multi cursor support with a find -> select -> modify cycle style of
editing.

See the `ctrl+f2` palette when flow mode is selected to see the full list
of keybindings for this mode.

### Vim mode

The vim modes, shown as NORMAL, INSERT or VISUAL in the status bar, follow
the basic modal editing style of vim. The basics follow vim closely, but
more advanced vim functions (e.g. macros and registers) are not supported
(yet). Keybindings from flow mode that do not conflict with vim keybindings
also work in vim mode.

### Helix mode

The helix modes, shown as NOR, INS or SEL in the status bar, follow the
basic modal editing style of helix. The basics are being adapted closely,
more advanced functions (e.g. surround, macros, selections, registers) are
not supported (yet). Usual keybinding with LSPs are used for tasks like 'go
to definition', 'go to reference' and 'inline documentation' featuring
inline diagnostics. Keybindings from flow mode that do not conflict with
helix keybindings also work in helix mode.

(work in progress)

## Mouse Commands

Mouse commands are NOT rebindable and are not listed in the command
palette.

- Left Click =>
  Clear all cursors and selections and the place cursor at the mouse
  pointer

- Double Left Click =>
  Select word at mouse pointer

- Triple Left Click =>
  Select line at mouse pointer

- Drag Left Click =>
  Extend selection to mouse pointer

- Alt + Left Click =>
  Add cursor at mouse click

- Ctrl + Left Click =>
  Goto definition of symbol at click

- hold Alt =>
  Enable jump/hover mouse mode

- Right Click =>
  Extend selection to mouse pointer

- Middle Click =>
  Close tab

- Back Button, Forward Button =>
  Jump to previous/next location in the location history

- Scroll Wheel =>
  Scroll

- Alt + Scroll Wheel =>
  Fast scroll

- Ctrl + Scroll Wheel =>
  Zoom (GUI only)

## Configuration

Configuration is stored in the standard location
`${XDG_CONFIG_HOME}/flow/config`. This is usually `~/.config/flow/config`.

The default configuration will be written the first time Flow Control is
started and looks similar to this:

```
frame_rate 60
theme "default"
input_mode "flow"
gutter_line_numbers true
gutter_line_numbers_relative false
enable_terminal_cursor false
highlight_current_line true
highlight_current_line_gutter true
show_whitespace false
animation_min_lag 0
animation_max_lag 150
```

Most of these options are fairly self explanatory.

`theme`, `input_mode` and `show_whitespace` are automatically persisted
when changed interactively with keybindings.

`frame_rate` can be tuned to control the maximum number of frames rendered.

`animation_max_lag` controls the maximum amount of time allowed for
rendering scrolling animations. Set to 0 to disable scrolling animation
altogether.

File types may be configured with the `Edit file type configuration`
command. You can also create a new file type by adding a new `.conf` file
to the `file_type` directory. Have a look at an existing file type to see
what options are available.

## Flags and options

As every respectable terminal program, flow provide various invoking
options that among others, will allow you to inspect various aspects of the
running session. Feel free to run `flow --help` to explore them.
