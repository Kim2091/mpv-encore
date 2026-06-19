# Windows file associations

A small tool (Windows only) that registers **your** `mpv.exe` as a handler for
common video / audio / image files — the same convenience mpv.net's setup
offers. Encore is a configuration package and does **not** ship mpv, so this
points Windows at whatever mpv build you already have.

Everything is written under `HKEY_CURRENT_USER`, so it needs **no administrator
rights**, only affects the current user, and is **fully reversible**.

## Use it

1. **Register** — double-click **`Register-File-Associations.cmd`**.
   - If `mpv.exe` isn't on your `PATH`, it asks for the full path to it.
   - It then opens **Settings → Apps → Default apps**.
2. **Set the defaults** — Windows 10/11 won't let an app make itself the default
   automatically. In that Settings page, either search a file type (e.g. `.mkv`)
   and pick **Encore (mpv)**, or find **Encore (mpv)** in the app list and set
   the types you want.
3. **Undo** — double-click **`Unregister-File-Associations.cmd`** to remove
   everything the tool added.

Prefer the command line?

```powershell
# register (auto-detects mpv.exe on PATH, else prompts)
powershell -ExecutionPolicy Bypass -File .\Register-FileAssociations.ps1
# register a specific mpv
powershell -ExecutionPolicy Bypass -File .\Register-FileAssociations.ps1 -MpvPath "C:\path\to\mpv.exe"
# remove
powershell -ExecutionPolicy Bypass -File .\Register-FileAssociations.ps1 -Unregister
```

## What it changes

Under `HKCU\Software\Classes` and `HKCU\Software\Encore`:

- a `Encore.mpv` ProgID whose open command is `"<your mpv.exe>" "%1"`;
- each media extension gets `Encore.mpv` added to its **OpenWithProgids** (so mpv
  shows up under "Open with") — the extension's existing default is never
  touched;
- an application entry (**Encore (mpv)**) in *Default apps* via
  `RegisteredApplications` + `Capabilities`.

`Unregister` removes all of the above.

## Notes / limitations

- **Windows only.** On Linux/macOS use your desktop's own default-application
  settings (the desktop entry mpv installs already handles this).
- **You confirm the defaults.** Modern Windows protects the per-type default
  (UserChoice) and won't let a tool set it silently — hence the Settings step.
- **Selecting several files** and pressing Enter opens one mpv window per file
  (Encore doesn't add single-instance playlist queueing). Open a folder, or drag
  files onto one mpv window, to build a single playlist.
- Re-run **Register** after moving `mpv.exe` to update the path.
