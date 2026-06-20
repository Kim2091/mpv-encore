-- encore-config -- read the package's own options from ~~/encore.conf.
--
-- The settings editor (encore-settings) stores `file = encore` options in
-- encore.conf (only non-default values are written). Feature scripts read them
-- through this tiny helper.
--
--   package.path = mp.command_native({"expand-path", "~~/script-modules/?.lua"})
--                  .. ";" .. package.path
--   local config = require "encore-config"
--   if config.bool("remember-state", false) then ... end

local mp = require "mp"

local M = {}

local cache
local loaded = false

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function load()
    cache = {}
    loaded = true
    local path = mp.command_native({ "expand-path", "~~home/encore.conf" })
    local f = io.open(path, "r")
    if not f then return end
    for line in f:lines() do
        local s = trim((line:gsub("\r$", "")))
        if s ~= "" and s:sub(1, 1) ~= "#" then
            local k, v = s:match("^([^=]+)=(.*)$")
            if k then cache[trim(k)] = trim(v) end
        end
    end
    f:close()
end

-- Force a fresh read next access (e.g. at shutdown, after the user may have
-- changed settings mid-session).
function M.reload() loaded = false end

function M.get(name, default)
    if not loaded then load() end
    local v = cache[name]
    if v == nil or v == "" then return default end
    return v
end

function M.bool(name, default)
    local v = M.get(name, nil)
    if v == nil then return default end
    v = v:lower()
    return v == "yes" or v == "true" or v == "1"
end

return M
