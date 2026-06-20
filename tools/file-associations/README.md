# Windows file associations

A tool (Windows only) that registers **your** `mpv.exe` as a handler for ~70
video / audio / image file types and the `ytdl`/`rtsp`/`srt`/`srtp` streaming
protocols — a port of how mpv.net's setup registers itself. Encore is a
configuration package and does **not** ship mpv, so this points Windows at
whatever mpv build you already have.

It writes everything under `HKEY_CURRENT_USER`, so it needs **no administrator
rights**, only affects the current user, and is **fully reversible**. It is also
**non-destructive**: it never overwrites the handler a file type already has, so
existing associations (mpv.net's, or anything else) are left intact — you choose
mpv as the default yourself in Settings.

## Use it

1. **Register** — double-click **`Register-File-Associations.cmd`**.
   - If `mpv.exe` isn't on your `PATH`, it asks for the full path to it.
   - It then opens **Settings → Apps → Default apps**.
2. **Set the defaults** — Windows 10/11 won't let an app make itself the default
   automatically. In that Settings page, either search a file type (e.g. `.mkv`)
   and pick **mpv (Encore)**, or find **mpv (Encore)** in the app list and set
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

It mirrors mpv.net's registration, but per-user (HKCU) instead of machine-wide.
Under `HKCU\Software\Classes`, `HKCU\Software\Clients\Media\Encore` and
`HKCU\Software\RegisteredApplications`:

- a per-extension ProgID (`Encore.<ext>`) for each type, opening `"<your
  mpv.exe>" "%1"` with mpv's icon;
- each extension gets that ProgID added to its **OpenWithProgids** (so mpv shows
  up under "Open with"), plus a `PerceivedType` if it had none — the extension's
  existing **default handler is never changed**;
- the `ytdl` / `rtsp` / `srt` / `srtp` URL protocols;
- an **App Paths** entry (run `mpv` from the Run dialog) and an
  `Applications\mpv.exe` entry with a `FriendlyAppName` + `SupportedTypes`;
- mpv added to the video/audio/image **OpenWithList**;
- application **Capabilities** + a **RegisteredApplications** entry, so
  **mpv (Encore)** appears in *Settings > Default apps*.

`Unregister` removes all of the above and leaves every extension's existing
default exactly as it was.

## Notes / limitations

- **Windows only.** On Linux/macOS use your desktop's own default-application
  settings (the desktop entry mpv installs already handles this).
- **You confirm the defaults.** Modern Windows protects the per-type default
  (UserChoice) and won't let a tool set it silently — hence the Settings step.
- **Selecting several files** and pressing Enter opens one mpv window per file
  (Encore doesn't add single-instance playlist queueing). Open a folder, or drag
  files onto one mpv window, to build a single playlist.
- Re-run **Register** after moving `mpv.exe` to update the path.
