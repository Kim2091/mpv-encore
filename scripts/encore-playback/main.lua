-- encore-playback — auto-load-folder and recent files.
--
-- auto-load-folder: when a single file is opened, load the rest of its folder
-- into the playlist (mpv.net's auto-load-folder). The folder-scan + playlist
-- ordering replicate mpv's well-tested TOOLS/lua/autoload.lua for the
-- single-file-open case. Gated by auto-load-folder in encore.conf.
--
-- recent files: records opened files to ~~home/encore-recent.json (capped at
-- recent-count, default 15) and offers a picker.
--   script-binding encore_playback/recent

package.path = mp.command_native({ "expand-path", "~~/script-modules/?.lua" })
    .. ";" .. package.path

local utils = require "mp.utils"
local config = require "encore-config"
local ui = require "encore-ui"

-- ---------------------------------------------------------------------------
-- Extensions (defaults from autoload.lua)
-- ---------------------------------------------------------------------------

local function set(t)
    local s = {}
    for _, v in ipairs(t) do s[v] = true end
    return s
end

local EXTENSIONS = set {
    -- video
    "3g2", "3gp", "avi", "flv", "m2ts", "m4v", "mj2", "mkv", "mov", "mp4",
    "mpeg", "mpg", "ogv", "rmvb", "webm", "wmv", "y4m",
    -- audio
    "aiff", "ape", "au", "flac", "m4a", "mka", "mp3", "oga", "ogg", "ogm",
    "opus", "wav", "wma",
    -- images
    "avif", "bmp", "gif", "j2k", "jp2", "jpeg", "jpg", "jxl", "png", "svg",
    "tga", "tif", "tiff", "webp",
}

local function get_extension(path)
    return (path:match("%.([^%.]+)$") or ""):lower()
end

-- alphanumeric "natural" sort (from autoload.lua)
local function alphanumsort(filenames)
    local function padnum(n, d)
        return #d > 0 and ("%03d%s%.12f"):format(#n, n, tonumber(d) / (10 ^ #d))
            or ("%03d%s"):format(#n, n)
    end
    local tuples = {}
    for i, f in ipairs(filenames) do
        tuples[i] = { f:lower():gsub("0*(%d+)%.?(%d*)", padnum), f }
    end
    table.sort(tuples, function(a, b)
        return a[1] == b[1] and #b[2] < #a[2] or a[1] < b[1]
    end)
    for i, tuple in ipairs(tuples) do filenames[i] = tuple[2] end
    return filenames
end

-- ---------------------------------------------------------------------------
-- auto-load-folder
-- ---------------------------------------------------------------------------

local function load_folder()
    if not config.bool("auto-load-folder", false) then return end
    if mp.get_property_native("playback-abort") then return end

    -- Only act when a single file was opened (not a manual/built playlist).
    if mp.get_property_number("playlist-count", 1) ~= 1 then return end

    local path = mp.get_property("path", "")
    local dir = utils.split_path(path)
    if dir == "" or path:find("://", 1, true) then return end  -- not a local file

    local names = utils.readdir(dir, "files") or {}
    local files = {}
    for _, name in ipairs(names) do
        if EXTENSIONS[get_extension(name)] then
            files[#files + 1] = utils.join_path(dir, name)
        end
    end
    if #files <= 1 then return end
    alphanumsort(files)

    local current
    for i, f in ipairs(files) do
        if f == path then current = i; break end
    end
    if not current then return end

    -- Append every sibling (the current file is already playlist entry 0),
    -- then move the current file to its sorted position. This yields true
    -- folder order without interrupting playback.
    for i, f in ipairs(files) do
        if i ~= current then
            mp.commandv("loadfile", f, "append")
        end
    end
    mp.commandv("playlist-move", 0, current)
end

mp.register_event("start-file", load_folder)

-- ---------------------------------------------------------------------------
-- Recent files
-- ---------------------------------------------------------------------------

local RECENT_PATH = mp.command_native({ "expand-path", "~~home/encore-recent.json" })

local function load_recent()
    local f = io.open(RECENT_PATH, "r")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    local ok, parsed = pcall(utils.parse_json, content)
    return (ok and type(parsed) == "table") and parsed or {}
end

local function save_recent(list)
    local f = io.open(RECENT_PATH, "w")
    if not f then return end
    f:write(utils.format_json(list))
    f:close()
end

local function record_recent()
    local path = mp.get_property("path")
    if not path or path == "" then return end

    local title = mp.get_property("media-title") or path
    local list = load_recent()

    -- de-duplicate (move to front)
    for i = #list, 1, -1 do
        if list[i].path == path then table.remove(list, i) end
    end
    table.insert(list, 1, { path = path, title = title })

    local cap = config.number("recent-count", 15)
    while #list > cap do table.remove(list) end

    save_recent(list)
end

mp.register_event("file-loaded", record_recent)

local function show_recent()
    local list = load_recent()
    if #list == 0 then
        ui.osd("No recent files.", 3)
        return
    end
    local items = {}
    for i, e in ipairs(list) do items[i] = e.title or e.path end
    ui.select({
        prompt = "Recent files:",
        items = items,
        on_select = function(i)
            mp.commandv("loadfile", list[i].path)
        end,
    })
end

mp.add_key_binding(nil, "recent", show_recent)
mp.register_script_message("recent", show_recent)
