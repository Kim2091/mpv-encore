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

-- On quit: if enabled, snapshot the configured properties into mpv.conf.
mp.register_event("shutdown", function()
    config.reload()                                 -- pick up a mid-session toggle
    if not config.bool("remember-state", false) then return end

    local list = config.get("remember-options", DEFAULT_OPTIONS)
    local pairs_list = {}
    for name in list:gmatch("[^,%s]+") do
        local v = mp.get_property_native(name)
        local t = type(v)
        -- only persist scalar values; a list/table-typed option would otherwise
        -- write a Lua table address that mpv rejects on next launch.
        if t == "boolean" or t == "number" or t == "string" then
            pairs_list[#pairs_list + 1] = { name, format_value(v) }
        end
    end
    if #pairs_list > 0 then persist(pairs_list) end
end)
