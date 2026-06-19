-- encore-info — mpv.net's information dialogs, recreated as OSD lists.
--
-- Recreates GuiCommand.cs's show-commands / show-keys / show-bindings /
-- show-protocols / show-decoders / show-demuxers / show-profiles /
-- show-media-info / show-about, all from mpv's own properties — no native UI.
--
-- Bindings (input.conf), all under the script name "encore_info":
--   script-binding encore_info/menu            -- the info hub
--   script-binding encore_info/media-info
--   script-binding encore_info/commands  ... etc.

package.path = mp.command_native({ "expand-path", "~~/script-modules/?.lua" })
    .. ";" .. package.path

local ui = require "encore-ui"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function prop(name)
    return mp.get_property_native(name)
end

-- ---------------------------------------------------------------------------
-- Individual views (each re-openable, with Back -> hub)
-- ---------------------------------------------------------------------------

local show_menu  -- forward declaration so views can return to the hub

local function view_commands()
    local list = prop("command-list") or {}
    local lines = {}
    for _, c in ipairs(list) do
        local args = {}
        for _, a in ipairs(c.args or {}) do
            args[#args + 1] = "<" .. a.name .. ">"
        end
        lines[#lines + 1] = c.name .. (c.vararg and " ..." or "")
            .. (#args > 0 and (" " .. table.concat(args, " ")) or "")
    end
    table.sort(lines)
    ui.text_view("Commands (" .. #lines .. "):", lines, show_menu)
end

local function view_bindings()
    local list = prop("input-bindings") or {}
    local lines = {}
    for _, b in ipairs(list) do
        if b.key and b.key ~= "" then
            lines[#lines + 1] = string.format("%-22s %s", b.key, b.cmd or "")
        end
    end
    table.sort(lines)
    ui.text_view("Key bindings (" .. #lines .. "):", lines, show_menu)
end

local function view_string_list(prop_name, label)
    local list = prop(prop_name) or {}
    local lines = {}
    for _, v in ipairs(list) do lines[#lines + 1] = tostring(v) end
    table.sort(lines)
    ui.text_view(label .. " (" .. #lines .. "):", lines, show_menu)
end

local function view_decoders()
    local list = prop("decoder-list") or {}
    local lines = {}
    for _, d in ipairs(list) do
        lines[#lines + 1] = string.format("%-16s %-16s %s",
            d.codec or "", d.driver or "", d.description or "")
    end
    table.sort(lines)
    ui.text_view("Decoders (" .. #lines .. "):", lines, show_menu)
end

local function view_profiles()
    local list = prop("profile-list") or {}
    local lines = {}
    for _, p in ipairs(list) do lines[#lines + 1] = p.name or "" end
    table.sort(lines)
    ui.text_view("Profiles (" .. #lines .. "):", lines, show_menu)
end

-- Property browser: pick a property to OSD its current value.
local function view_properties()
    local names = prop("property-list") or {}
    table.sort(names)
    ui.select({
        prompt = "Properties — select to show value:",
        items = names,
        back = show_menu,
        stay = true,
        on_select = function(i)
            local name = names[i]
            local val = mp.get_property(name)
            ui.osd(name .. " = " .. (val ~= nil and val or "(unavailable)"), 5)
        end,
    })
end

-- Current-file media info, assembled from mpv properties.
local function view_media_info()
    local lines = {}
    local function add(label, value)
        if value ~= nil and value ~= "" then
            lines[#lines + 1] = string.format("%-16s %s", label .. ":", tostring(value))
        end
    end

    if not prop("path") then
        ui.osd("No file loaded.", 3)
        return
    end

    add("File", prop("filename"))
    add("Path", prop("path"))
    local size = prop("file-size")
    if size then add("Size", string.format("%.1f MiB", size / 1048576)) end
    add("Format", prop("file-format"))
    local dur = prop("duration")
    if dur then add("Duration", mp.format_time(dur)) end

    local w, h = prop("width"), prop("height")
    if w and h then add("Video", string.format("%dx%d", w, h)) end
    add("Video codec", prop("video-codec"))
    add("FPS", prop("container-fps") or prop("estimated-vf-fps"))
    add("Pixel format", prop("video-params/pixelformat"))

    add("Audio codec", prop("audio-codec"))
    local ch = prop("audio-params/channel-count")
    if ch then add("Channels", ch) end
    add("Sample rate", prop("audio-params/samplerate"))

    local tracks = prop("track-list") or {}
    add("Tracks", #tracks .. " total")

    ui.text_view("Media information:", lines, show_menu)
end

local function view_about()
    local lines = {
        "encore-info",
        "",
        "Part of the encore script package — recreating mpv.net's",
        "features for vanilla mpv, in pure Lua.",
        "",
        "mpv version:  " .. (mp.get_property("mpv-version") or "?"),
        "ffmpeg:       " .. (mp.get_property("ffmpeg-version") or "?"),
    }
    ui.text_view("About:", lines, show_menu)
end

-- ---------------------------------------------------------------------------
-- Hub
-- ---------------------------------------------------------------------------

local entries = {
    { "Media information",   view_media_info },
    { "Commands",            view_commands },
    { "Key bindings",        view_bindings },
    { "Properties",          view_properties },
    { "Protocols",           function() view_string_list("protocol-list", "Protocols") end },
    { "Decoders",            view_decoders },
    { "Demuxers",            function() view_string_list("demuxer-lavf-list", "Demuxers") end },
    { "Profiles",            view_profiles },
    { "About",               view_about },
}

show_menu = function()
    local items = {}
    for i, e in ipairs(entries) do items[i] = e[1] end
    ui.select({
        prompt = "Info:",
        items = items,
        on_select = function(i) entries[i][2]() end,
    })
end

-- ---------------------------------------------------------------------------
-- Bindings
-- ---------------------------------------------------------------------------

mp.add_key_binding(nil, "menu", show_menu)
mp.register_script_message("menu", show_menu)

mp.add_key_binding(nil, "media-info", view_media_info)
mp.add_key_binding(nil, "commands", view_commands)
mp.add_key_binding(nil, "bindings", view_bindings)
mp.add_key_binding(nil, "keys", view_bindings)
mp.add_key_binding(nil, "properties", view_properties)
mp.add_key_binding(nil, "protocols", function() view_string_list("protocol-list", "Protocols") end)
mp.add_key_binding(nil, "decoders", view_decoders)
mp.add_key_binding(nil, "demuxers", function() view_string_list("demuxer-lavf-list", "Demuxers") end)
mp.add_key_binding(nil, "profiles", view_profiles)
mp.add_key_binding(nil, "about", view_about)
