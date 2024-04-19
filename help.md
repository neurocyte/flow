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

Press Ctrl-f to search this help file. Type a search term and press 
Ctrl-n/Ctrl-p or F3/Shift-F3 to jump through the matches. Press Enter
to exit find mode at the current match or Escape to return to your
starting point.

## Input Modes

Flow Control supports multiple input modes that may be changed
interactively at runtime. The current input mode (and some other
settings) is persisted in the configuration file automatically.

- F2 => Cycle major input modes (flow, vim, ...)

The current input mode Input mode is displayed in the `modestatus`
widget at the left side of the statusbar.

## Flow mode

The default input mode, called just flow, is based on common GUI
programming editors. It most closely resembles Visual Studio Code, but
also takes some inspiration from Emacs and others. This mode focuses
on powerful multi cursor support with a find -> select -> modify 
cycle style of editing.

### Navigation Commands

- Up, Down, Left, Right =>
        Move the cursor

- Home, End =>
        Move to the beginning/end of the line

- PageUp, PageDown =>
        Move up/down one screen

- Ctrl-Left, Ctrl-Right, Alt-b, Alt-f =>
        Move the cursor word wise

- Ctrl-Home, Ctrl-End =>
        Move to the beginning/end of the file

- Alt-Left, Alt-Right, MouseBack, MouseForward =>
        Jump to previous/next location in the location history

- Ctrl-f =>
        Enter find mode

- Ctrl-g =>
        Enter goto line mode

- Ctrl-t, Ctrl-b =>
        Enter move to next/previous character mode

- Ctrl-n, Ctrl-p, F3, Shift-F3, Alt-n, Alt-p =>
        Goto next/previous match

- Ctrl-l =>
        Scroll cursor to center of screen, cycle cursor to
        top/bottom of screen

- MouseLeft =>
        Clear all cursors and selections and place cursor at mouse pointer

- MouseWheel =>
        Scroll
        
- Ctrl-MouseWheel =>
        Fast scroll

### Selection Commands

- Shift-Left, Shift-Right =>
        Add next character to selection

- Ctrl-Shift-Left, Ctrl-Shift-Right =>
        Add next word to selection

- Shift-Up, Shift-Down =>
        Add next line to selection

- Ctrl-Shift-Up, Ctrl-Shift-Down =>
        Add next line to selection and scroll

- Shift-Home, Shift-End =>
        Add begging/end of line to selection

- Ctrl-Shift-Home, Ctrl-Shift-End =>
        Add begging/end of file to selection

- Shift-PageUp, Shift-PageDown =>
        Add next screen to selection

- Ctrl-a =>
        Select entire file

- Ctrl-d =>
        Select word under cursor, or add cursor at next match
        (see Multi Cursor Commands)

- Ctrl-Space =>
        Reverse selection direction

- Double-MouseLeft =>
        Select word at mouse pointer

- Triple-MouseLeft =>
        Select line at mouse pointer

- Drag-MouseLeft =>
        Extend selection to mouse pointer

- MouseRight =>
        Extend selection to mouse pointer

### Multi Cursor Commands

- Ctrl-d =>
        Add cursor at next match (either find match, or auto match)

- Alt-Shift-Down, Alt-Shift-Up =>
        Add cursor on the previous/next line

- Ctrl-Shift-l =>
        Add cursors to all matches

- Shift-Alt-i =>
        Add cursors to line ends

- Ctrl-MouseLeft =>
        Add cursor at mouse click

- Ctrl-u =>
        Remove last added cursor (pop)

- Ctrl-k -> Ctrl-d =>
        Move primary cursor to next match (skip)

- Escape =>
        Remove all cursors and selections

### Editing Commands

- Ctrl-Enter, Ctrl-Shift-Enter =>
        Insert new line after/before current line

- Ctrl-Backspace, Ctrl-Delete =>
        Delete word left/right

- Ctrl-k -> Ctrl-u =>
        Delete to beginning of line

- Ctrl-k -> Ctrl-k =>
        Delete to end of line

- Ctrl-Shift-d, Alt-Shift-d =>
        Duplicate current line or selection down/up

- Alt-Down, Alt-Up =>
        Pull current line or selection down/up

- Ctrl-c =>
        Copy selected text

- Ctrl-x =>
        Cut selected text, or line if there is no selection

- Ctrl-v =>
        Paste previously copied/cut text

- Ctrl-z =>
        Undo last change

- Ctrl-Shift-z, Ctrl-y =>
        Redo last undone change

- Tab, Shift-Tab =>
        Indent/Unindent line

- Ctrl-/ =>
        Toggle comment prefix in line

- Alt-s =>
        Sort file or selection

- Alt-Shift-f =>
        Reformat file or selection

### File Commands

- Ctrl-s =>
        Save file

- Ctrl-o =>
        Open file

- Ctrl-e =>
        Open recent file, repeat for quick select

- Ctrl-q =>
        Exit

- Ctrl-q =>
        Exit

- Ctrl-q =>
        Exit

- Ctrl-Shift-q =>
        Force exit without saving

- Ctrl-Shift-r =>
        Restart Flow Control/reload file

### Configuration Commands

- F9 =>
        Select previous theme

- F10 =>
        Select next theme

- Ctrl-F10 =>
        Toggle visible whitespace mode

- Alt-F10 =>
        Change gutter mode

### Language Server Commands

- Alt-n, Alt-p
        Goto next/previous diagnostic

- F12 =>
        Goto definition of symbol at cursor

- Alt-MouseLeft =>
        Goto definition of symbol at click

### Debugging Commands

- F5, Ctrl-Shift-i =>
        Toggle inspector view

- F6 =>
        Dump buffer AST for current line to log view

- F7 =>
        Dump current line to log view

- F11, Ctrl-J, Alt-l =>
        Toggle log view

- Ctrl-Shift-/ =>
        Dump current widget tree to log view

## Vim mode

The vim mode, called NOR or INS, follows the basic modal editing
style of vim. Normal and insert mode basics follow vim closely,
but more advanced vim functions (e.g. macros and registers) are
not supported yet. Keybindings from flow mode that do not
conflict with common vim keybindings also work in vim mode.

The vim command prompt (:) is not available yet. To save/load/quit
you will have to use the flow mode keybindings.

(work in progress)

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
    "modestate_show": true,
    "selectionstate_show": true,
    "modstate_show": false,
    "keystate_show": false,
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

`*state_show` toggle various parts of the statusbar.

`animation_max_lag` controls the maximum amount of time allowed
for rendering scrolling animations. Set to 0 to disable scrolling
animation altogether.
