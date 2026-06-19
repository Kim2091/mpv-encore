-- encore-session — remembers volume and audio device across mpv sessions.
--
-- Recreates mpv.net's remember-volume and remember-audio-device options. Both
-- are read from encore.conf (set them via the settings menu, General section).
-- State is stored as JSON in ~~home/encore-session.json.
--
-- Note: mpv.net's remember-window-position is intentionally not implemented —
-- mpv exposes no API for a script to read/set the window's screen position, so
-- it is one of the few mpv.net features that cannot be done in script form.

package.path = mp.command_native({ "expand-path", "~~/script-modules/?.lua" })
    .. ";" .. package.path

local utils = require "mp.utils"
local msg = require "mp.msg"
local config = require "encore-config"

local STATE_PATH = mp.command_native({ "expand-path", "~~home/encore-session.json" })

local remember_volume = config.bool("remember-volume", false)
local remember_device = config.bool("remember-audio-device", false)

-- Nothing to do; stay inert (no observers, no file writes).
if not remember_volume and not remember_device then
    return
end

-- ---------------------------------------------------------------------------
-- State load / save
-- ---------------------------------------------------------------------------

local function load_state()
    local f = io.open(STATE_PATH, "r")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    local ok, parsed = pcall(utils.parse_json, content)
    return (ok and type(parsed) == "table") and parsed or {}
end

local state = load_state()

-- Coalesce rapid changes into a single write.
local save_pending = false
local function save_state()
    if save_pending then return end
    save_pending = true
    mp.add_timeout(0.5, function()
        save_pending = false
        local f, err = io.open(STATE_PATH, "w")
        if not f then
            msg.warn("cannot write session state: " .. tostring(err))
            return
        end
        f:write(utils.format_json(state))
        f:close()
    end)
end

-- ---------------------------------------------------------------------------
-- Restore (once, at startup) then begin tracking
-- ---------------------------------------------------------------------------

if remember_volume then
    if state.volume ~= nil then
        mp.set_property_number("volume", state.volume)
    end
    if state.mute ~= nil then
        mp.set_property_bool("mute", state.mute)
    end

    mp.observe_property("volume", "number", function(_, v)
        if v ~= nil then state.volume = v; save_state() end
    end)
    mp.observe_property("mute", "bool", function(_, v)
        if v ~= nil then state.mute = v; save_state() end
    end)
end

if remember_device then
    if state.audio_device ~= nil then
        mp.set_property("audio-device", state.audio_device)
    end

    mp.observe_property("audio-device", "string", function(_, v)
        -- Ignore the transient "auto" mpv reports before a device is chosen.
        if v ~= nil and v ~= "" then state.audio_device = v; save_state() end
    end)
end

msg.verbose(string.format("session memory active (volume=%s device=%s)",
    tostring(remember_volume), tostring(remember_device)))
