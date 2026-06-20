-- encore-remember -- optionally carry player state across sessions.
--
-- mpv.net lets you "remember" things like volume, fullscreen and borderless
-- between launches. This recreates that for vanilla mpv WITHOUT a fork: when a
-- toggle is on, the current value of the matching player properties is written
-- into mpv.conf on quit, so they become the defaults next time.
--
-- Each thing you can remember is a separate per-property toggle (mpv.net-style),
-- enabled from the settings editor (Program Behavior) or by hand in encore.conf:
--
--     remember-volume=yes          # persists volume AND mute (grouped)
--     remember-fullscreen=yes      # persists fullscreen
--     remember-border=yes          # persists border (borderless)
--     remember-ontop=yes           # persists ontop
--     remember-window-scale=yes    # reads current-window-scale, writes window-scale
--     remember-audio-device=yes    # persists audio-device
--
-- Window POSITION can't be remembered: mpv exposes no current-position property,
-- so there is nothing to read back at quit (window scale/size can, via
-- current-window-scale -> the settable window-scale startup option).
--
-- A power-user escape hatch, not shown in the editor, always-remembers extra
-- properties (read name == write name); default empty:
--
--     remember-extra=brightness,contrast
--
-- Only the affected mpv.conf options are touched; the rest of the file (comments,
-- other settings, formatting, sections/profiles) is preserved.

package.path = mp.command_native({ "expand-path", "~~/script-modules/?.lua" })
    .. ";" .. package.path

local config = require "encore-config"
local msg = require "mp.msg"

local MPV_CONF = mp.command_native({ "expand-path", "~~home/mpv.conf" })

-- Each group: an encore.conf toggle option name, and the properties it remembers.
-- A property is { read = "<get-property name>", write = "<mpv.conf option name>" };
-- read and write match except where they intentionally differ (current-window-
-- scale is read-only/actual, window-scale is the settable startup option).
local function prop(read, write) return { read = read, write = write or read } end
local GROUPS = {
    { opt = "remember-volume",       props = { prop("volume"), prop("mute") } },
    { opt = "remember-fullscreen",   props = { prop("fullscreen") } },
    { opt = "remember-border",       props = { prop("border") } },
    { opt = "remember-ontop",        props = { prop("ontop") } },
    { opt = "remember-window-scale", props = { prop("current-window-scale", "window-scale") } },
    { opt = "remember-audio-device", props = { prop("audio-device") } },
}

-- Some window properties (e.g. current-window-scale) read back nil at the
-- `shutdown` event because the VO is already being torn down. Observe every read
-- property live so the last value seen during playback is still available then.
local last_seen = {}
local observing = {}
local function observe(name)
    if observing[name] then return end              -- already observing
    observing[name] = true
    mp.observe_property(name, "native", function(_, v)
        if v ~= nil then last_seen[name] = v end     -- may legitimately be `false`
    end)
end
for _, group in ipairs(GROUPS) do
    for _, p in ipairs(group.props) do observe(p.read) end
end

-- Render a property value the way it should appear in mpv.conf.
local function format_value(v)
    if type(v) == "boolean" then
        return v and "yes" or "no"
    elseif type(v) == "number" then
        if v % 1 == 0 then return tostring(math.floor(v)) end
        return string.format("%g", v)
    end
    return tostring(v)
end

-- Update `key=value` for each pair in mpv.conf, only in the GLOBAL (section-less)
-- scope, in place. Comments, other options, `[sections]`/`[profiles]`, blank
-- lines, the file's line endings and a leading BOM are all preserved. Keys not
-- already present are inserted just before the first `[section]` (never inside a
-- profile, where a global option could be mis-scoped or rejected). The write goes
-- through a temp file + rename, so a crash mid-write can't truncate the config.
local function persist(pairs_list)
    local raw = ""
    local f = io.open(MPV_CONF, "rb")
    if f then raw = f:read("*a") or ""; f:close() end

    local bom = ""
    if raw:sub(1, 3) == "\239\187\191" then bom = raw:sub(1, 3); raw = raw:sub(4) end
    local nl = raw:find("\r\n", 1, true) and "\r\n" or "\n"

    local lines = {}
    if raw ~= "" then
        local norm = raw:gsub("\r\n", "\n"):gsub("\r", "\n")
        if norm:sub(-1) ~= "\n" then norm = norm .. "\n" end
        for line in norm:gmatch("(.-)\n") do lines[#lines + 1] = line end
    end

    -- last line index of the global region (everything before the first section)
    local global_end = #lines
    for i, l in ipairs(lines) do
        if l:match("^%s*%[") then global_end = i - 1; break end
    end

    for _, kv in ipairs(pairs_list) do
        local key, val = kv[1], kv[2]
        local esc = key:gsub("%-", "%%-")          -- option names use '-'
        local replaced = false
        for i = 1, global_end do
            local l = lines[i]
            if l:gsub("^%s+", ""):sub(1, 1) ~= "#" and l:match("^%s*" .. esc .. "%s*=") then
                lines[i] = (l:match("^(%s*)")) .. key .. "=" .. val
                replaced = true
                break
            end
        end
        if not replaced then
            table.insert(lines, global_end + 1, key .. "=" .. val)
            global_end = global_end + 1
        end
    end

    -- atomic-ish replace: write a temp file, then rename over the original
    local tmp = MPV_CONF .. ".encore-tmp"
    local w, err = io.open(tmp, "wb")
    if not w then
        msg.error("could not write " .. tmp .. ": " .. tostring(err))
        return
    end
    w:write(bom .. table.concat(lines, nl))
    if #lines > 0 then w:write(nl) end
    w:close()

    os.remove(MPV_CONF)                            -- Windows rename won't overwrite
    local ok, rerr = os.rename(tmp, MPV_CONF)
    if not ok then
        msg.error("could not replace mpv.conf (" .. tostring(rerr) ..
                  "); new content saved at " .. tmp)
        return
    end
    msg.verbose("remembered " .. #pairs_list .. " option(s) to mpv.conf")
end

-- Read property `read`, and if it's a scalar, queue { write, value } onto out.
-- Only scalar values are persisted; a list/table-typed option would otherwise
-- write a Lua table address that mpv rejects on next launch.
local function collect(read, write, out)
    local v = mp.get_property_native(read)
    if v == nil then v = last_seen[read] end        -- fall back to last observed value
    local t = type(v)
    if t == "boolean" or t == "number" or t == "string" then
        out[#out + 1] = { write, format_value(v) }
    end
end

-- On quit: for each enabled toggle, snapshot its properties into mpv.conf.
mp.register_event("shutdown", function()
    config.reload()                                 -- pick up mid-session toggles

    local pairs_list = {}
    for _, group in ipairs(GROUPS) do
        if config.bool(group.opt, false) then
            for _, p in ipairs(group.props) do
                collect(p.read, p.write, pairs_list)
            end
        end
    end

    -- escape hatch: always-remember extra properties (read name == write name)
    for name in config.get("remember-extra", ""):gmatch("[^,%s]+") do
        collect(name, name, pairs_list)
    end

    if #pairs_list > 0 then persist(pairs_list) end
end)
