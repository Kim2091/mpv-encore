-- encore-remember -- optionally carry player state across sessions.
--
-- mpv.net lets you "remember" things like volume, fullscreen and borderless
-- between launches. This recreates that for vanilla mpv WITHOUT a fork: when the
-- toggle is on, the current value of a few player properties is written into
-- mpv.conf on quit, so they become the defaults next time.
--
-- Enable it from the settings editor (General / Program Behavior -> "remember-
-- state"), or by hand in encore.conf:
--
--     remember-state=yes
--     remember-options=volume,mute,fullscreen,border,ontop    (optional)
--
-- Only the listed mpv.conf options are touched; the rest of the file (comments,
-- other settings, formatting) is preserved.

package.path = mp.command_native({ "expand-path", "~~/script-modules/?.lua" })
    .. ";" .. package.path

local config = require "encore-config"
local msg = require "mp.msg"

local MPV_CONF = mp.command_native({ "expand-path", "~~home/mpv.conf" })
local DEFAULT_OPTIONS = "volume,mute,fullscreen,border,ontop"

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

-- Update `key=value` for each pair in mpv.conf, in place, preserving comments,
-- other options, blank lines and formatting. Keys not already present are
-- appended; commented-out lines are left alone.
local function persist(pairs_list)
    local lines = {}
    local f = io.open(MPV_CONF, "r")
    if f then
        for l in f:lines() do lines[#lines + 1] = (l:gsub("\r$", "")) end
        f:close()
    end

    for _, kv in ipairs(pairs_list) do
        local key, val = kv[1], kv[2]
        local esc = key:gsub("%-", "%%-")          -- option names use '-'
        local replaced = false
        for i, l in ipairs(lines) do
            if l:gsub("^%s+", ""):sub(1, 1) ~= "#" and l:match("^%s*" .. esc .. "%s*=") then
                local indent = l:match("^(%s*)")
                lines[i] = indent .. key .. "=" .. val
                replaced = true
                break
            end
        end
        if not replaced then lines[#lines + 1] = key .. "=" .. val end
    end

    local w, err = io.open(MPV_CONF, "w")
    if not w then
        msg.error("could not write " .. MPV_CONF .. ": " .. tostring(err))
        return
    end
    w:write(table.concat(lines, "\n"))
    if #lines > 0 then w:write("\n") end
    w:close()
    msg.verbose("remembered " .. #pairs_list .. " option(s) to mpv.conf")
end

-- On quit: if enabled, snapshot the configured properties into mpv.conf.
mp.register_event("shutdown", function()
    config.reload()                                 -- pick up a mid-session toggle
    if not config.bool("remember-state", false) then return end

    local list = config.get("remember-options", DEFAULT_OPTIONS)
    local pairs_list = {}
    for name in list:gmatch("[^,%s]+") do
        local v = mp.get_property_native(name)
        if v ~= nil then
            pairs_list[#pairs_list + 1] = { name, format_value(v) }
        end
    end
    if #pairs_list > 0 then persist(pairs_list) end
end)
