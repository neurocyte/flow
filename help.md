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

For other editors you will probably have to disable or rebind them each
individually.

## Searching

Press ctrl+f to search this help file. Type a search term and press 
ctrl+n/ctrl+p or f3/shift+f3 to jump through the matches. Press Enter
to exit find mode at the current match or Escape to return to your
starting point.

## Input Modes

Flow Control supports multiple input modes that may be changed
interactively at runtime. The current input mode (and some other
settings) is persisted in the configuration file automatically.

- f4 => Cycle major input modes (flow, vim, ...)

The current input mode is displayed in the at the left side of the statusbar.

- ctrl+shift+p or alt+x => Show the command palette

The command palette allows you to fuzzy search and select commands to run. It
also shows any available keybind that may be used to run the command without
opening the palette.

- ctrl+f2 => Show all available commands and keybinds

This shows all currently available commands. Including commands that are
normally only executed via a keybinding. Selecting a command in this view
will insert the command name into the current document instead of executing
it. This is very useful for editing keybinding definition files.

Run the `Edit keybindings` command to save the current keybinding mode to a
file in the configuration `keys` directory and open it for editing. Save your
customized keybinds under a new name in the same directory to create an
entirely new keybinding mode that can be selected with `f4`. Delete the
keybinding file from the configuration `keys` directory to revert the mode
to it's built-in definition (if there is one). Changes to keybinding files
will take effect on restart.

Keybinding modes may inherit all non-conflicting keybindings from another mode
by adding an `inherit` option to the `settings` section of the keybind file
like this:

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

## Flow mode

The default input mode, called just flow, is based on common GUI
programming editors. It most closely resembles Visual Studio Code, but
also takes some inspiration from Emacs and others. This mode focuses
on powerful multi cursor support with a find -> select -> modify 
cycle style of editing.

See the `ctrl+f2` palette when flow mode is selected to see the full
list of keybindings for this mode.

## Vim mode

The vim modes, shown as NORMAL, INSERT or VISUAL in the status bar,
follow the basic modal editing style of vim. The basics follow vim
closely, but more advanced vim functions (e.g. macrosand registers)
are not supported (yet). Keybindings from flow mode that do not conflict
with vim keybindings also work in vim mode.

(work in progress)

### Mouse Commands

Mouse commands are not rebindable and are not listed in the command palette.

- Left Click =>
        Clear all cursors and selections and the place cursor at the mouse pointer

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

## Configuration

Configuration is stored in the standard location
`${XDG_CONFIG_HOME}/flow/config.json`. This is usually
`~/.config/flow/config.json`.

The default configuration will be written the first time
Flow Control is started and looks similar to this:
```
{
    "frame_rate": 60,
    "theme": "default",
    "input_mode": "flow",
    "gutter_line_numbers": true,
    "gutter_line_numbers_relative": false,
    "enable_terminal_cursor": false,
    "highlight_current_line": true,
    "highlight_current_line_gutter": true,
    "show_whitespace": false,
    "animation_min_lag": 0,
    "animation_max_lag": 150
}
```

Most of these options are fairly self explanitory.

`theme`, `input_mode` and `show_whitespace` are automatically
persisted when changed interactively with keybindings.

`frame_rate` can be tuned to control the maximum number
of frames rendered.

`animation_max_lag` controls the maximum amount of time allowed
for rendering scrolling animations. Set to 0 to disable scrolling
animation altogether.
