# encore-settings

mpv.net's settings menu, recreated for **vanilla mpv** as a pure-Lua script — no
.NET, no external dependencies, and nothing to rebase when mpv updates (it lives
outside the mpv source tree and uses only the stable scripting API).

It reproduces mpv.net's data-driven config editor: 152 setting definitions
(145 real mpv/libplacebo options + 7 mpv.net options backed by the package's
feature scripts), organised into a category tree, with live search, live-apply,
and comment-preserving writes to `mpv.conf`.

## Install

Copy the `encore-settings/` folder into mpv's scripts directory:

- Windows: `%APPDATA%\mpv\scripts\encore-settings\`
- Linux/macOS: `~/.config/mpv/scripts/encore-settings/`

Then bind a key in `input.conf`:

```
Ctrl+s  script-binding encore_settings/open
```

(or open it from a menu via `script-message-to encore_settings open`).

## Usage

A custom OSD menu (`uimenu.lua`) drawn with ASS, so it can show a live
description panel — what mpv.net's GUI did, which mpv's built-in console menu
can't.

- **↑ / ↓** move, **Enter** select, **← / Backspace** go back a level, **Esc**
  close. Mouse wheel and PgUp/PgDn also work.
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

## mpv.net-specific options

145 of the settings are real mpv / libplacebo options. The other 7 are
`file = encore` options that the package's **feature scripts** implement:
`recent-count` and `auto-load-folder` (encore-playback), `remember-volume` and
`remember-audio-device` (encore-session), `autofit-image` and `autofit-audio`
(encore-window), and `menu-syntax` (encore-menu). They're written to
`encore.conf` and read by those scripts.

mpv.net options that have no equivalent in a script-only package (e.g.
`process-instance`, `remember-window-position`, the WPF theme options) were
removed from `editor_conf.txt` so the menu only shows settings that actually do
something.

## Tests

`../../tests/test_logic.lua` exercises the parser and config round-trip in mpv's
own Lua runtime:

```
mpv --no-config --idle=once --script=tests/test_logic.lua
```
