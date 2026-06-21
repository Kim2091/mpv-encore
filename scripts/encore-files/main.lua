-- encore-files — file operations via native Windows dialogs.
--
-- Recreates mpv.net's open-files / load-sub / load-audio / open-clipboard /
-- open-optical-media. Native file pickers aren't part of mpv's scripting API,
-- so we drive PowerShell's WinForms OpenFileDialog (and Get-Clipboard) through
-- mpv's subprocess command — still pure "script", no compiled helper.
--
-- Bindings (script name "encore_files"):
--   script-binding encore_files/open-files
--   script-binding encore_files/load-sub
--   script-binding encore_files/load-audio
--   script-binding encore_files/open-clipboard
--   script-binding encore_files/open-dvd
--   script-binding encore_files/open-bluray
--   script-binding encore_files/reveal-in-folder   (cross-platform)

package.path = mp.command_native({ "expand-path", "~~/script-modules/?.lua" })
    .. ";" .. package.path

local msg = require "mp.msg"
local utils = require "mp.utils"

local is_windows = mp.get_property_native("platform") == "windows"

-- Runs a PowerShell snippet and returns its stdout (trimmed) to `cb`.
local function powershell(script, cb)
    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        args = { "powershell", "-NoProfile", "-NonInteractive", "-STA", "-Command", script },
    }, function(success, res)
        if not success or not res or res.status ~= 0 then
            msg.warn("powershell failed")
            cb(nil)
            return
        end
        cb((res.stdout or ""):gsub("%s+$", ""))
    end)
end

-- Shows an OpenFileDialog; calls cb with an array of selected paths.
local function open_dialog(title, filter, multiselect, cb)
    if not is_windows then
        mp.osd_message("Native file dialogs are Windows-only.", 3)
        return
    end
    local script = table.concat({
        "Add-Type -AssemblyName System.Windows.Forms;",
        "$d = New-Object System.Windows.Forms.OpenFileDialog;",
        "$d.Multiselect = $" .. tostring(multiselect) .. ";",
        "$d.Title = '" .. title .. "';",
        "$d.Filter = '" .. filter .. "';",
        "if ($d.ShowDialog() -eq 'OK') { [Console]::Out.Write(($d.FileNames -join \"`n\")) }",
    }, " ")

    powershell(script, function(out)
        local paths = {}
        if out and out ~= "" then
            for line in (out .. "\n"):gmatch("(.-)\n") do
                line = line:gsub("[\r\n]", "")
                if line ~= "" then paths[#paths + 1] = line end
            end
        end
        cb(paths)
    end)
end

local MEDIA_FILTER = "Media files|*.mp4;*.mkv;*.avi;*.mov;*.webm;*.flv;*.wmv;*.m4v;*.mpg;*.mpeg;"
    .. "*.mp3;*.flac;*.m4a;*.opus;*.ogg;*.wav;*.wma;*.aac;"
    .. "*.png;*.jpg;*.jpeg;*.gif;*.webp;*.bmp|All files|*.*"
local SUB_FILTER = "Subtitles|*.srt;*.ass;*.ssa;*.sub;*.idx;*.vtt;*.sup|All files|*.*"
local AUDIO_FILTER = "Audio|*.mp3;*.flac;*.m4a;*.opus;*.ogg;*.wav;*.wma;*.aac;*.ac3;*.dts|All files|*.*"

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

local function open_files()
    open_dialog("Open files", MEDIA_FILTER, true, function(paths)
        if #paths == 0 then return end
        for i, p in ipairs(paths) do
            mp.commandv("loadfile", p, i == 1 and "replace" or "append")
        end
        mp.osd_message("Opened " .. #paths .. " file(s).", 2)
    end)
end

local function load_sub()
    open_dialog("Load subtitle", SUB_FILTER, false, function(paths)
        if paths[1] then
            mp.commandv("sub-add", paths[1])
            mp.osd_message("Subtitle added.", 2)
        end
    end)
end

local function load_audio()
    open_dialog("Load audio", AUDIO_FILTER, false, function(paths)
        if paths[1] then
            mp.commandv("audio-add", paths[1])
            mp.osd_message("Audio track added.", 2)
        end
    end)
end

local function open_clipboard()
    if not is_windows then
        mp.osd_message("Clipboard open is Windows-only.", 3)
        return
    end
    powershell("Get-Clipboard -Raw", function(text)
        if not text or text == "" then
            mp.osd_message("Clipboard is empty.", 2)
            return
        end
        -- take the first non-empty line (a path or URL)
        local target = text:match("([^\r\n]+)")
        if target then
            mp.commandv("loadfile", target)
            mp.osd_message("Opened from clipboard.", 2)
        end
    end)
end

local function open_optical(prefix, label)
    mp.commandv("loadfile", prefix)
    mp.osd_message("Opening " .. label .. "…", 2)
end

-- Reveal the current file in the OS file manager, selecting it where possible.
-- Cross-platform (unlike the dialogs above) and needs no PowerShell: Windows uses
-- Explorer's /select, macOS uses `open -R`, everything else opens the containing
-- folder with xdg-open (selecting a file isn't portable on Linux).
local function reveal_in_folder()
    local path = mp.get_property("path")
    if not path or path == "" then
        mp.osd_message("Nothing is playing.", 2)
        return
    end
    -- streams/URLs have no folder to reveal
    if path:match("^%a[%w%+%-%.]*://") then
        mp.osd_message("Can't reveal a stream/URL in a file manager.", 3)
        return
    end
    -- resolve relative paths against mpv's working directory
    local is_abs = path:match("^%a:[\\/]") or path:match("^[\\/]")
    if not is_abs then
        local cwd = mp.get_property("working-directory")
        if cwd and cwd ~= "" then path = utils.join_path(cwd, path) end
    end

    local platform = mp.get_property_native("platform")
    if platform == "windows" then
        -- Explorer parses its own command line in a non-standard way: the correct
        -- invocation is exactly  explorer.exe /select,"<path>"  with the quotes
        -- ONLY around the path. mpv's subprocess quotes whole argv tokens, so a
        -- path containing a space ends up as "/select,C:\...\my file.mkv" — one
        -- quoted token — which Explorer can't parse, so it silently opens the
        -- default folder (Documents) instead. We launch it through .NET's
        -- Process.Start, whose raw arguments string reaches CreateProcess
        -- verbatim, letting us place the quotes exactly where Explorer needs them.
        local win = path:gsub("/", "\\"):gsub("'", "''")   -- '' escapes ' inside the PS literal
        local ps = "[Diagnostics.Process]::Start('explorer.exe','/select,\"" .. win .. "\"') | Out-Null"
        msg.verbose("reveal-in-folder (windows): " .. ps)
        powershell(ps, function() end)
    else
        local args
        if platform == "darwin" then
            args = { "open", "-R", path }
        else
            args = { "xdg-open", (utils.split_path(path)) }   -- open containing folder
        end
        msg.verbose("reveal-in-folder: " .. utils.format_json(args))
        mp.command_native_async({
            name = "subprocess", playback_only = false, args = args,
        }, function(success)
            if not success then msg.warn("reveal-in-folder: launch failed") end
        end)
    end
    mp.osd_message("Revealing in file manager…", 1.5)
end

mp.add_key_binding(nil, "open-files", open_files)
mp.add_key_binding(nil, "load-sub", load_sub)
mp.add_key_binding(nil, "load-audio", load_audio)
mp.add_key_binding(nil, "open-clipboard", open_clipboard)
mp.add_key_binding(nil, "open-dvd", function() open_optical("dvd://", "DVD") end)
mp.add_key_binding(nil, "open-bluray", function() open_optical("bd://", "Blu-ray") end)
mp.add_key_binding(nil, "reveal-in-folder", reveal_in_folder)

mp.register_script_message("open-files", open_files)
mp.register_script_message("open-clipboard", open_clipboard)
mp.register_script_message("reveal-in-folder", reveal_in_folder)
