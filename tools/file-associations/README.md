# Windows file associations

A tool (Windows only) that registers **your** `mpv.exe` as a handler for ~70
video / audio / image file types and the `ytdl`/`rtsp`/`srt`/`srtp` streaming
protocols — a port of how mpv.net's setup registers itself. Encore is a
configuration package and does **not** ship mpv, so this points Windows at
whatever mpv build you already have.

It writes everything under `HKEY_CURRENT_USER`, so it needs **no administrator
rights**, only affects the current user, and is **fully reversible**. It is also
**safe by default**: it makes mpv the default only for file types that have **no
association yet**, and never overwrites one you (or another program, like
mpv.net) already set. For those, you either pick mpv in Settings, or opt into the
override mode below — which still backs up and restores the displaced handler.

## Use it

1. **Register** — double-click **`Register-File-Associations.cmd`**.
   - If `mpv.exe` isn't on your `PATH`, it asks for the full path to it.
   - It makes mpv the default for any *unassociated* types right away, then opens
     **Settings → Apps → Default apps**.
2. **Set the rest (optional)** — for types another program already owns, search
   the type (e.g. `.mkv`) in that Settings page and pick **mpv (Encore)**.
   Windows requires you to confirm these; no app may take them silently.
3. **Undo** — double-click **`Unregister-File-Associations.cmd`**. Removes
   everything and restores anything the tool displaced.

**Take over everything (opt-in):** double-click
**`Register-File-Associations-(override).cmd`** to also claim types other programs
own. The displaced associations are backed up and restored by Unregister.
(Windows-protected per-type defaults — "UserChoice" — still need a Settings
confirmation even here.)

Prefer the command line?

```powershell
# register (auto-detects mpv.exe on PATH, else prompts; claims only free types)
powershell -ExecutionPolicy Bypass -File .\Register-FileAssociations.ps1
# register a specific mpv
powershell -ExecutionPolicy Bypass -File .\Register-FileAssociations.ps1 -MpvPath "C:\path\to\mpv.exe"
# also take over types other programs own (reversible)
powershell -ExecutionPolicy Bypass -File .\Register-FileAssociations.ps1 -OverrideExisting
# remove (and restore anything displaced)
powershell -ExecutionPolicy Bypass -File .\Register-FileAssociations.ps1 -Unregister
```

## What it changes

It mirrors mpv.net's registration, but per-user (HKCU) instead of machine-wide.
Under `HKCU\Software\Classes`, `HKCU\Software\Clients\Media\Encore` and
`HKCU\Software\RegisteredApplications`:

- a per-extension ProgID (`Encore.<ext>`) for each type, opening `"<your
  mpv.exe>" "%1"` with mpv's icon;
- each extension gets that ProgID added to its **OpenWithProgids** (so mpv shows
  up under "Open with"), plus a `PerceivedType` if it had none. mpv is made the
  extension's **default only if it had none** (or for every type with
  `-OverrideExisting`, which first backs up the displaced handler);
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
