# mpv-settings — native settings window (optional)

> **Status: optional alternative.** The default settings UI is the cross-platform
> two-pane OSD menu (`scripts/encore-settings/uimenu.lua`). This native Win32
> window is kept as a Windows-only alternative / reference. It is **not** launched
> by the package by default.

A native Win32 settings window for mpv, in the style of mpv.net's config editor:
a category **tree** on the left, the selected category's settings on the right
with inline editors (combobox / text field / color + folder pickers), an
always-visible **help/description pane**, and a **search** box. Mouse-driven,
resizable, real window.

It's a single C file with no dependency on mpv's libraries, so it builds with
just Visual Studio's compiler + the Windows SDK.

## Build

```
gui\build.bat
```

(Requires Visual Studio 2022 with the C++ workload. The script finds `vcvars64`
via `vswhere`, compiles `mpv-settings.c`, and copies the exe into
`scripts/encore-settings/` so the Lua launcher picks it up.)

Manual build:

```
cl /nologo /O2 mpv-settings.c /Fe:mpv-settings.exe ^
   /link user32.lib comctl32.lib gdi32.lib shell32.lib ole32.lib comdlg32.lib
```

## Run / arguments

```
mpv-settings.exe <editor_conf.txt> <mpv.conf> <encore.conf> [--ipc=PIPE] [--set=file:name=value]
```

- Reads setting definitions from `editor_conf.txt` (same file the Lua package uses).
- Loads current values from `mpv.conf` / `encore.conf`.
- On close: writes both files back (preserving comments, dropping defaults) and,
  if `--ipc` points at a running mpv's `--input-ipc-server` pipe, live-applies
  changed mpv options via JSON IPC.
- `--set=file:name=value` is a headless self-test: apply one change, save, exit.

## How it's wired to mpv today

`scripts/encore-settings/main.lua` launches this exe on Windows (falling back to
the in-player OSD menu elsewhere), passing the conf paths and the IPC pipe if
`input-ipc-server` is set. When the window closes, the script re-applies
`mpv.conf` to the running player. No fork required — it works with stock mpv.

## Integrating into a forked mpv

The same C window can live inside a forked mpv with a minimal touchpoint, so the
rest of the fork stays close to upstream and is cheap to rebase:

1. Drop `mpv-settings.c` into the mpv tree (e.g. `osdep/win32/settings_gui.c`),
   exposing one entry point, e.g. `void mpv_settings_open(struct MPContext *mpctx)`,
   that creates the window on its own thread.
2. Embed `editor_conf.txt` via meson the same way mpv embeds its Lua scripts
   (`player/lua/meson.build` shows the pattern), or read it from the config dir.
3. Add it to the Windows build in `meson.build` (one `files()` entry, guarded by
   `win32`).
4. Register a command — the **touchpoint** — so a key/menu can open it, e.g. add
   `mpv-settings` to the command table in `input/cmd.c` / `player/command.c`
   that calls `mpv_settings_open`. That single command registration plus the
   `files()` entry are the only edits to existing files.
5. Apply changes in-process through `m_config_set_option_*` instead of IPC, and
   write `mpv.conf` with the embedded writer.

This keeps the fork's delta to a couple of new files + ~2 lines of touchpoints,
which is the cheap-to-rebase shape we were after.
