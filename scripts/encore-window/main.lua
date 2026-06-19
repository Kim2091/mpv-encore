-- encore-window — content-aware initial window size (autofit-image/audio).
--
-- Recreates mpv.net's autofit-image and autofit-audio: images and audio files
-- open at a different window height than video. Detection is by extension at
-- start-file (before the window is created), and the height percentage is
-- applied via mpv's autofit property as "100%xH%" — the full-width cap lets
-- the H% govern the window height for typical aspect ratios, matching
-- mpv.net's "initial window height in percent".
--
-- Only active when the option is present in encore.conf (set it via the
-- settings menu, Window section), so installing the package never changes
-- sizing unless you ask for it.
--
-- Not implemented (mpv exposes no window-geometry API to scripts, so these
-- few mpv.net options can't be reproduced in script form):
--   remember-window-position, minimum-aspect-ratio, start-size.

package.path = mp.command_native({ "expand-path", "~~/script-modules/?.lua" })
    .. ";" .. package.path

local config = require "encore-config"

local function set(t)
    local s = {}
    for _, v in ipairs(t) do s[v] = true end
    return s
end

local IMAGE_EXTS = set {
    "avif", "bmp", "gif", "j2k", "jp2", "jpeg", "jpg", "jxl", "png", "svg",
    "tga", "tif", "tiff", "webp",
}
local AUDIO_EXTS = set {
    "aiff", "ape", "au", "flac", "m4a", "mka", "mp3", "oga", "ogg", "ogm",
    "opus", "wav", "wma", "aac", "ac3", "dts",
}

-- Read configured heights only if the user actually set them.
local opts = config.all()
local image_h = opts["autofit-image"] and config.number("autofit-image", 80)
local audio_h = opts["autofit-audio"] and config.number("autofit-audio", 70)

if not image_h and not audio_h then
    return  -- nothing configured; stay inert
end

-- Remember the user's own autofit so video files are left untouched.
local original_autofit = mp.get_property("autofit", "")

local function extension(path)
    return (path:match("%.([^%.]+)$") or ""):lower()
end

mp.register_event("start-file", function()
    local path = mp.get_property("path", "")
    local ext = extension(path)

    if image_h and IMAGE_EXTS[ext] then
        mp.set_property("autofit", "100%x" .. image_h .. "%")
    elseif audio_h and AUDIO_EXTS[ext] then
        mp.set_property("autofit", "100%x" .. audio_h .. "%")
    else
        mp.set_property("autofit", original_autofit)
    end
end)
