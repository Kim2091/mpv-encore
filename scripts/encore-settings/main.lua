-- encore-settings — mpv.net's settings menu, recreated as a pure-Lua mpv script.
--
-- Drops into mpv's ~~/scripts/ as a directory script. No mpv source changes, no
-- .NET, no external dependencies — it uses only mpv's built-in scripting API, so
-- future mpv updates require no rebasing.
--
-- Bind a key in input.conf, e.g.:
--     Ctrl+s  script-binding encore_settings/open
-- or trigger via:  script-message-to encore_settings open
-- (mpv normalises the script directory name "encore-settings" to "encore_settings".)

local mp = require "mp"
local msg = require "mp.msg"

local conf = require "conf"
local conffile = require "conffile"
local menu = require "uimenu"

-- ---------------------------------------------------------------------------
-- Paths
-- ---------------------------------------------------------------------------

local function expand(path)
    return mp.command_native({ "expand-path", path })
end

local MPV_CONF = expand("~~home/mpv.conf")
local ENCORE_CONF = expand("~~home/encore.conf")

-- ---------------------------------------------------------------------------
-- Load the setting definitions and merge in existing config values
-- ---------------------------------------------------------------------------

local settings, cf

local function load_data()
    local dir = mp.get_script_directory()
    if not dir then
        msg.error("could not determine script directory")
        return false
    end

    local f = io.open(dir .. "/editor_conf.txt", "r")
    if not f then
        msg.error("editor_conf.txt not found in " .. dir)
        return false
    end
    local content = f:read("*a")
    f:close()

    settings = conf.load(content)

    cf = conffile.new(settings)
    cf:load(MPV_CONF, "mpv")
    cf:load(ENCORE_CONF, "encore")
    cf:load_libplacebo()
    cf:merge_into_settings()

    msg.info(string.format("loaded %d settings", #settings))
    return true
end

-- ---------------------------------------------------------------------------
-- Persist + live-apply
-- ---------------------------------------------------------------------------

local function find_setting(name, file)
    for _, s in ipairs(settings) do
        if s.name == name and s.file == file then return s end
    end
    return nil
end

-- Rebuild the libplacebo-opts value from the individual libplacebo settings,
-- mirroring mpv.net's behaviour on save.
local function sync_libplacebo()
    local opts = find_setting("libplacebo-opts", "mpv")
    if opts then
        opts.value = cf:get_key_value_content("libplacebo")
    end
    return opts
end

local function write_file(path, text)
    local f, err = io.open(path, "w")
    if not f then
        msg.error("cannot write " .. path .. ": " .. tostring(err))
        return
    end
    f:write(text)
    f:close()
end

local function apply_property(name, value)
    local ok, err = pcall(mp.set_property, name, value or "")
    if not ok then
        msg.verbose(string.format("could not apply %s=%s live (%s)", name, tostring(value), tostring(err)))
    end
end

-- Called after any single setting is committed in the menu.
local function on_change(setting)
    if setting.file == "libplacebo" then
        local opts = sync_libplacebo()
        if opts then apply_property("libplacebo-opts", opts.value) end
    elseif setting.file == "mpv" then
        apply_property(setting.name, setting.value)
    end
    -- encore-tagged settings persist to encore.conf but are not applied live;
    -- that behaviour is provided later by the fork-touchpoint modules.

    -- Persist immediately so changes survive even if the user just escapes.
    sync_libplacebo()
    write_file(MPV_CONF, cf:get_content("mpv"))
    write_file(ENCORE_CONF, cf:get_content("encore"))
end

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

local function open_menu()
    if not settings then
        if not load_data() then
            mp.osd_message("encore-settings: failed to load (see log)")
            return
        end
    end
    menu.open(settings, on_change)
end

mp.add_key_binding(nil, "open", open_menu)
mp.register_script_message("open", open_menu)

-- Load eagerly so errors surface at startup rather than on first keypress.
load_data()
