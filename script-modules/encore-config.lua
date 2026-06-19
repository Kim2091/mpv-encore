-- encore-config — reads mpv.net-specific options from encore.conf.
--
-- These are the "file = encore" settings the settings menu writes. Feature
-- scripts read them through this module, so a choice made in the settings menu
-- (e.g. remember-volume = yes) actually drives the corresponding feature.
--
-- Usage:
--   package.path = mp.command_native({"expand-path","~~/script-modules/?.lua"})
--                  .. ";" .. package.path
--   local config = require "encore-config"
--   if config.bool("remember-volume") then ... end

local M = {}

local cache

local function parse(path)
    local t = {}
    local f = io.open(path, "r")
    if not f then return t end

    for raw in f:lines() do
        local line = raw:gsub("\r", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" and line:sub(1, 1) ~= "[" then
            local k, v = line:match("^%-*([%w%-]+)%s*=%s*(.*)$")
            if not k then
                -- bare flag: "name" -> yes, "no-name" -> no
                local bare = line:match("^%-*([%w%-]+)$")
                if bare then
                    if bare:sub(1, 3) == "no-" then k, v = bare:sub(4), "no"
                    else k, v = bare, "yes" end
                end
            end
            if k then
                -- strip surrounding quotes from the value
                v = v:gsub("^['\"](.*)['\"]$", "%1")
                t[k:lower()] = v
            end
        end
    end
    f:close()
    return t
end

local function all()
    if not cache then
        cache = parse(mp.command_native({ "expand-path", "~~home/encore.conf" }))
    end
    return cache
end
M.all = all

function M.get(name, default)
    local v = all()[name]
    if v == nil then return default end
    return v
end

function M.bool(name, default)
    local v = all()[name]
    if v == nil then return default end
    return v == "yes" or v == "true" or v == "1"
end

function M.number(name, default)
    return tonumber(all()[name]) or default
end

return M
