-- encore-audio — loudness leveling / night mode (Roku-style volume smoothing).
--
-- The problem: movies swing from near-silent dialogue to deafening effects, so
-- you ride the volume all night. This evens that out in real time.
--
-- Three modes, cycled from a key or the right-click menu (Audio > Loudness):
--   * Off       — no processing.
--   * Leveling  — gentle loudness normalization so volume stays consistent
--                 across scenes and files, with minimal artifacts.
--   * Night     — aggressive dynamic-range compression: loud effects are
--                 tamed and quiet dialogue is lifted, with a sub-bass cut to
--                 keep rumble down. For late-night / quiet-room listening.
--
-- How each mode SOUNDS is tunable from the settings menu (Settings > Audio >
-- Loudness); those choices live in encore.conf. They're read at startup and
-- again whenever the settings editor saves one (it fires `reload`), so preset
-- edits take effect live. WHICH mode is active is a live playback control (this
-- script's JSON), and can be changed three ways — all routed through the `set`
-- message so they stay in sync: the right-click menu (Audio > Loudness), the
-- settings editor (Settings > Audio > Loudness > Loudness Mode, a live control
-- backed by the user-data/encore-audio-mode property), or a bound key.
--
-- Implementation: a single labeled audio filter (@loudness) built on FFmpeg's
-- acompressor + alimiter — a downward compressor with makeup gain, then a
-- look-ahead limiter to catch transients. See build_filters() for why
-- dynaudnorm (the obvious first choice, and what this used to use) is wrong
-- here: it can only normalise *up*, so it made loud passages louder. Because
-- the filter carries a label, `af add @loudness:...` REPLACES our own entry
-- without disturbing any other af the user has set, and `af remove @loudness`
-- strips it cleanly. The chosen mode is persisted to JSON and, unless
-- `loudness-remember` is turned off, re-applied on every launch.
--
-- Drive it from the right-click menu, or:
--   script-binding      encore_audio/cycle
--   script-message-to   encore_audio set off|leveling|night
--   script-message-to   encore_audio reload      (re-read settings, re-apply)

package.path = mp.command_native({ "expand-path", "~~/script-modules/?.lua" })
    .. ";" .. package.path

local utils = require "mp.utils"
local msg = require "mp.msg"
local config = require "encore-config"

local function expand(p) return mp.command_native({ "expand-path", p }) end

local STORE = expand("~~home/encore-audio.json")
local LABEL = "loudness"

-- Baked defaults for the tunable knobs. These MUST match the `default =` values
-- in encore-settings/editor_conf.txt: a setting left at its default isn't
-- written to encore.conf, so the fallback here has to reproduce it exactly.
local DEF = {
    night_strength  = "4",     -- acompressor ratio: how hard loud parts are pulled down
    night_boost     = "15",    -- makeup gain (dB) applied after compression
    night_threshold = "-30",   -- dBFS above which the compressor starts working
    night_release   = "300",   -- ms for gain to recover; higher = smoother, less pumping
    night_bass      = "-2.5",  -- lowshelf gain at 100 Hz; "0" disables the sub-bass cut
    leveling        = "2",     -- acompressor ratio for Leveling (gentler than Night)
}

-- Filter graphs, composed from the settings below. Built at startup (and on a
-- `reload` message) so preset changes take effect without editing this file.
local FILTERS = {}

-- Accept only a plain number (optionally signed / decimal). Anything else — a
-- typo or hand-edited encore.conf — falls back, so nothing foreign can leak into
-- the filter-graph string.
local function num(v, fallback)
    v = tostring(v or "")
    return (v:match("^%-?%d+%.?%d*$")) and v or fallback
end

local function off(v)
    v = tostring(v or ""):lower()
    return v == "" or v == "no" or v == "off" or v == "0" or v == "0.0"
end

-- Read a numeric setting and clamp it to the range libavfilter accepts. A stale
-- or hand-edited value then can't build a graph libavfilter would reject, which
-- would leave the audio silently unprocessed.
local function opt(key, default, lo, hi)
    local raw = tostring(config.get(key, default) or "")
    local v = tonumber(raw:match("^%-?%d+%.?%d*$") or "") or tonumber(default)
    if v < lo then v = lo elseif v > hi then v = hi end
    return v
end

-- dB is what makes sense in a menu; libavfilter wants a linear gain factor.
local function lin(db) return string.format("%.4f", 10 ^ (db / 20)) end

-- Trim a number for the graph string: 2 -> "2", 1.5 -> "1.5".
local function n(v) return (string.format("%.4f", v):gsub("0+$", ""):gsub("%.$", "")) end

-- Both modes are a downward compressor followed by a look-ahead limiter.
--
-- dynaudnorm was used here originally and is the wrong tool: it only ever
-- normalises *up* toward its peak target, so it cannot pull a loud passage
-- down. Measured on a quiet/loud test signal it made loud content 6.7 dB
-- LOUDER (to -1.2 dBFS, i.e. no headroom left for transients) and its
-- per-frame gain riding swung the level 13 dB on steady input — audible as
-- pumping and blown-out peaks. A compressor pulls loud parts down, makeup gain
-- lifts the whole result back to a comfortable level, and the limiter catches
-- transients so nothing clips. `level=0` stops alimiter auto-normalising the
-- output back up, which would undo the headroom we just bought.
local function compressor(thr_db, ratio, attack, release, makeup_db, limit)
    return string.format(
        "acompressor=threshold=%s:ratio=%s:attack=%s:release=%s:makeup=%s:knee=4:detection=rms"
        .. ",alimiter=limit=%s:level=0",
        lin(thr_db), n(ratio), n(attack), n(release), lin(makeup_db), limit)
end

local function build_filters()
    -- Night: pull loud effects down hard, lift quiet dialogue a long way.
    local night = compressor(
        opt("loudness-night-threshold", DEF.night_threshold, -60, -6),
        opt("loudness-night-strength",  DEF.night_strength,    1, 20),
        20,
        opt("loudness-night-release",   DEF.night_release,    10, 9000),
        opt("loudness-night-boost",     DEF.night_boost,       0, 36),
        "0.9")

    -- Optional sub-bass trim ahead of the compressor, so deep rumble doesn't
    -- drive the gain reduction for the whole mix.
    local bass = config.get("loudness-night-bass-cut", DEF.night_bass)
    if not off(bass) then
        night = "lowshelf=f=100:g=" .. num(bass, DEF.night_bass) .. "," .. night
    end

    -- Leveling: the same shape but gentle and slow — evens out scene-to-scene
    -- volume without squashing the mix.
    local lev = compressor(-24, opt("loudness-leveling-strength", DEF.leveling, 1, 20),
                           50, 500, 7.5, "0.95")

    FILTERS = {
        leveling = "lavfi=[" .. lev .. "]",
        night    = "lavfi=[" .. night .. "]",
    }
    msg.verbose("leveling filter: " .. FILTERS.leveling)
    msg.verbose("night filter: " .. FILTERS.night)
end

-- --------------------------------------------------------------------------
-- Persistence (which mode is active)
-- --------------------------------------------------------------------------

local mode = "off"

local function load_mode()
    local f = io.open(STORE, "rb")
    if not f then return end
    local raw = f:read("*a"); f:close()
    local data = raw and raw ~= "" and utils.parse_json(raw) or nil
    if type(data) == "table" and type(data.mode) == "string"
        and (data.mode == "off" or FILTERS[data.mode]) then
        mode = data.mode
    end
end

-- Small state file; a temp-then-rename keeps a crash from leaving it half-written.
local function save_mode()
    local tmp = STORE .. ".tmp"
    local w, err = io.open(tmp, "wb")
    if not w then msg.error("cannot write " .. tmp .. ": " .. tostring(err)); return end
    w:write(utils.format_json({ mode = mode })); w:close()
    os.remove(STORE)                 -- os.rename won't overwrite on Windows
    os.rename(tmp, STORE)
end

-- --------------------------------------------------------------------------
-- Applying the filter
-- --------------------------------------------------------------------------

-- Is our labeled filter currently in the af chain?
local function present()
    for _, f in ipairs(mp.get_property_native("af") or {}) do
        if f.label == LABEL then return true end
    end
    return false
end

-- Make the af chain match `mode`. Adding by label replaces our own previous
-- entry, so switching modes never stacks filters; removing is guarded so an
-- already-off state doesn't log a "filter not found" warning.
local function apply()
    if mode == "off" or not FILTERS[mode] then
        if present() then mp.commandv("af", "remove", "@" .. LABEL) end
    else
        mp.commandv("af", "add", "@" .. LABEL .. ":" .. FILTERS[mode])
    end
    -- Expose the mode as a property so menus / other scripts can read it.
    mp.set_property("user-data/encore-audio-mode", mode)
end

local LABELS = { off = "off", leveling = "Leveling", night = "Night mode" }

local function set_mode(m, announce)
    if m ~= "off" and not FILTERS[m] then
        msg.warn("unknown loudness mode: " .. tostring(m))
        return
    end
    mode = m
    apply()
    save_mode()
    if announce ~= false then
        mp.osd_message("Audio: " .. LABELS[mode], 2)
    end
end

local ORDER = { "off", "leveling", "night" }

local function cycle()
    local i = 1
    for k, v in ipairs(ORDER) do if v == mode then i = k; break end end
    set_mode(ORDER[(i % #ORDER) + 1])
end

-- --------------------------------------------------------------------------
-- Entry points + startup
-- --------------------------------------------------------------------------

mp.add_key_binding(nil, "cycle", cycle)
mp.register_script_message("cycle", cycle)
mp.register_script_message("set", function(m) set_mode(m) end)

-- Re-read the settings and re-apply the current mode live — lets preset changes
-- in the settings menu take effect without a restart. The settings editor calls
-- this with "quiet" (no OSD) after saving a preset, since the menu is its own
-- feedback; a manual `reload` with no argument shows a confirmation instead.
mp.register_script_message("reload", function(arg)
    config.reload()
    build_filters()
    apply()
    if arg ~= "quiet" then
        mp.osd_message("Audio: reloaded (" .. LABELS[mode] .. ")", 2)
    end
end)

build_filters()  -- compose graphs from settings before the mode is resolved

-- Restoring last session's mode is opt-out (`loudness-remember`, default yes —
-- must match the editor default). With it off we simply don't read the store,
-- so playback always starts Off; the mode is still saved, and turning the
-- setting back on picks up where you left off.
if config.bool("loudness-remember", true) then
    load_mode()
end

apply()          -- apply the restored mode (or ensure Off) with no OSD spam
