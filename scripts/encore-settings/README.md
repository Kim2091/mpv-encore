# encore-settings

mpv.net's settings menu, recreated for **vanilla mpv** as a pure-Lua script — no
.NET, no external dependencies, and nothing to rebase when mpv updates (it lives
outside the mpv source tree and uses only the stable scripting API).

It reproduces mpv.net's data-driven config editor: 153 setting definitions
(146 real mpv / libplacebo options + seven `file = encore` toggles read by the
encore-remember helper — a master plus six per-aspect toggles it reveals)
organised into a category tree, with live search, live-apply, and
comment-preserving writes to `mpv.conf`.

## Install

Copy the `encore-settings/` folder into mpv's scripts directory:

- Windows: `%APPDATA%\mpv\scripts\encore-settings\`
- Linux/macOS: `~/.config/mpv/scripts/encore-settings/`

Then open it from **right-click → Settings** (the bundled `menu.conf`), or bind
a key yourself — the package ships no `input.conf`:

```
c  script-binding encore_settings/open
```

(or trigger it via `script-message-to encore_settings open`).

## Usage

A custom OSD menu (`uimenu.lua`) drawn with ASS, so it can show a live
description panel — what mpv.net's GUI did, which mpv's built-in console menu
can't.

- **↑ / ↓** move, **Enter** select, **← / Backspace** go back a level, **Esc**
  close. PgUp/PgDn page; the mouse wheel scrolls (fast flicks included).
- **Mouse:** hover to highlight, click a category to expand/collapse, click a
  setting to edit, click outside the panel to close.
- **Just type** to search — it filters across *every* setting in every category
  at once (each result shows its category), not just the current level.
- A two-pane layout: the settings list on the left, and a **help panel on the
  right** that always shows the highlighted setting's help text, current value,
  default, and mpv manual URL.
- Pick a setting to change it: option settings show a choice list; text / number
  / color / folder settings open a text field.
- Changes apply live and are written to `mpv.conf` immediately, preserving your
  existing comments, sections, and formatting. Only non-default values are saved.

## How it maps to mpv.net

| mpv.net (C# / WPF)                | here (Lua)        |
|-----------------------------------|-------------------|
| `Resources/editor_conf.txt`       | `editor_conf.txt` (copied verbatim — same source of truth) |
| `Conf.cs` (`ConfParser`, `LoadConf`) | `conf.lua`     |
| `ConfWindow` config I/O (`LoadConf`/`GetContent`/`EscapeValue`/libplacebo) | `conffile.lua` |
| `ConfWindow` + WPF controls + search | `uimenu.lua` (custom ASS-drawn two-pane menu) |
| app wiring / live-apply / save    | `main.lua`        |

Because `editor_conf.txt` is kept in mpv.net's format, future additions to
mpv.net's setting list can be cross-ported by copying the relevant blocks.

## The `file = encore` options

Most former package-specific options are now provided by **native mpv** —
recent files (`--save-watch-history`), auto-load folder (`--autocreate-playlist`),
resume position (`--save-position-on-quit`), window sizing (`--autofit` /
`--geometry`) — so the editor exposes those real options and writes to `mpv.conf`.

Seven `file = encore` toggles remain, read by the **encore-remember** script
(which persists the matching properties to `mpv.conf` on quit — something no
single native option does). A master, **`remember-state`** (default off), turns
the feature on; six per-aspect toggles — **`remember-volume`** (volume + mute),
**`remember-fullscreen`**, **`remember-border`**, **`remember-ontop`**,
**`remember-window-scale`** and **`remember-audio-device`** — `depend` on it, so
the editor only shows them once the master is on, and each defaults on at that
point. (`depends = <name>` is the editor's conditional-visibility field.)

mpv.net options that have no mpv equivalent (e.g. `process-instance`,
`remember-window-position`, the WPF theme options) are omitted so the menu only
shows settings that actually do something.

## Tests

`../../tests/test_logic.lua` exercises the parser and config round-trip in mpv's
own Lua runtime:

```
mpv --no-config --idle=once --script=tests/test_logic.lua
```
