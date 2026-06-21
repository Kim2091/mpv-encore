-- encore-bookmarks — named timestamp bookmarks per file.
--
-- mpv only remembers a single resume position per file (--save-position-on-quit).
-- This adds VLC-style bookmarks: drop a named marker at the current time, then
-- jump back to it later from a list. Bookmarks are keyed by file path (or URL)
-- and persisted as JSON in the config dir, so they survive restarts and apply
-- whenever you reopen the same file.
--
-- Management uses the shared two-pane panel (script-modules/encore-panel.lua):
-- the file's bookmarks are rows; Enter offers jump / rename / delete; an
-- "Add bookmark…" row captures the current position.
--
-- Bindings (script name "encore_bookmarks"):
--   script-binding encore_bookmarks/add      quick-add a bookmark at the current time
--   script-binding encore_bookmarks/open     open the bookmarks panel (jump/rename/delete)
-- Also as script-messages. add and delete take an optional argument to run with
-- no UI (e.g. for input.conf power users):
--   script-message-to encore_bookmarks add Intro       add named "Intro" now
--   script-message-to encore_bookmarks delete Intro    delete the one named "Intro"
--   script-message-to encore_bookmarks list            alias for open

package.path = mp.command_native({ "expand-path", "~~/script-modules/?.lua" })
    .. ";" .. package.path

local utils = require "mp.utils"
local msg = require "mp.msg"
local input = require "mp.input"
local panel = require "encore-panel"

local STORE = mp.command_native({ "expand-path", "~~home/encore-bookmarks.json" })

-- ---------------------------------------------------------------------------
-- Persistence: { [filekey] = { {pos=<seconds>, label=<string>}, ... }, ... }
-- ---------------------------------------------------------------------------

local function load_all()
    local f = io.open(STORE, "rb")
    if not f then return {} end
    local raw = f:read("*a"); f:close()
    if not raw or raw == "" then return {} end
    local data = utils.parse_json(raw)
    return type(data) == "table" and data or {}
end

local function save_all(data)
    local tmp = STORE .. ".encore-tmp"
    local w, err = io.open(tmp, "wb")
    if not w then
        msg.error("could not write " .. tmp .. ": " .. tostring(err))
        return false
    end
    w:write(utils.format_json(data))
    w:close()
    os.remove(STORE)                                   -- Windows rename won't overwrite
    local ok, rerr = os.rename(tmp, STORE)
    if not ok then
        msg.error("could not replace bookmarks store: " .. tostring(rerr))
        return false
    end
    return true
end

-- Stable key for the current file: absolute path for local files, the URL itself
-- for streams. Returns nil when nothing is playing.
local function current_key()
    local path = mp.get_property("path")
    if not path or path == "" then return nil end
    if path:match("^%a[%w%+%-%.]*://") then return path end   -- URL: use as-is
    local is_abs = path:match("^%a:[\\/]") or path:match("^[\\/]")
    if not is_abs then
        local cwd = mp.get_property("working-directory")
        if cwd and cwd ~= "" then path = utils.join_path(cwd, path) end
    end
    return path
end

-- ---------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------

local function timestamp(pos)
    pos = math.floor((pos or 0) + 0.5)
    local h, m, s = math.floor(pos / 3600), math.floor((pos % 3600) / 60), pos % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%02d:%02d", m, s)
end

-- "0:01:23  My label" — the label is omitted when it's just the bare timestamp.
local function describe(b)
    local ts = timestamp(b.pos)
    if b.label and b.label ~= "" and b.label ~= ts then
        return ts .. "  " .. b.label
    end
    return ts
end

-- bookmarks for the current file, sorted by position; or nil + reason
local function current_list()
    local key = current_key()
    if not key then return nil, "Nothing is playing." end
    local list = load_all()[key] or {}
    table.sort(list, function(a, b) return (a.pos or 0) < (b.pos or 0) end)
    return list, key
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

local function store_bookmark(key, pos, label)
    local data = load_all()
    data[key] = data[key] or {}
    table.insert(data[key], { pos = pos, label = label or "" })
    if save_all(data) then
        mp.osd_message("Bookmark added at " .. timestamp(pos), 2)
    else
        mp.osd_message("Could not save bookmark.", 3)
    end
end

local function remove_bookmark(key, victim)
    local data = load_all()
    local arr = data[key] or {}
    for j, b in ipairs(arr) do
        if b.pos == victim.pos and (b.label or "") == (victim.label or "") then
            table.remove(arr, j)
            break
        end
    end
    if #arr == 0 then data[key] = nil else data[key] = arr end
    if not save_all(data) then mp.osd_message("Could not save bookmarks.", 3) end
end

local function rename_bookmark(key, victim, label)
    local data = load_all()
    for _, b in ipairs(data[key] or {}) do
        if b.pos == victim.pos and (b.label or "") == (victim.label or "") then
            b.label = label or ""
            break
        end
    end
    save_all(data)
end

-- add()           prompt for a name (pre-filled with the timestamp), then save
-- add("Intro")    save immediately under that name, no prompt
local function add(label)
    local key = current_key()
    if not key then mp.osd_message("Nothing is playing.", 2); return end
    local pos = mp.get_property_number("time-pos")
    if not pos then mp.osd_message("No playback position yet.", 2); return end

    if label ~= nil then
        store_bookmark(key, pos, label)
        return
    end
    -- Pre-fill the prompt with the timestamp so a single Enter accepts it.
    input.get({
        prompt = "Bookmark name:",
        default_text = timestamp(pos),
        submit = function(text) store_bookmark(key, pos, text); input.terminate() end,
    })
end

-- delete("Intro")  remove the bookmark whose label (or timestamp) matches, no UI
-- delete()         open the management panel
local function open()  -- forward declaration target (defined below)
end

local function delete(arg)
    if arg == nil then return open() end
    local items, key = current_list()
    if not items then mp.osd_message(key, 2); return end
    for _, b in ipairs(items) do
        if (b.label or "") == arg or timestamp(b.pos) == arg then
            remove_bookmark(key, b)
            mp.osd_message("Bookmark deleted.", 1.5)
            return
        end
    end
    mp.osd_message("No bookmark named '" .. arg .. "'.", 2)
end

-- ---------------------------------------------------------------------------
-- Management panel (jump / rename / delete / add)
-- ---------------------------------------------------------------------------

local function defer(fn) mp.add_timeout(0, fn) end
local active        -- single-instance guard

-- redefined here (the forward declaration above keeps `delete` able to call it)
function open()
    local _, key = current_list()
    if not key then mp.osd_message("Nothing is playing.", 2); return end
    if active and not active.closed then return end

    -- current items: every bookmark for this file, plus an "add" row
    local function build_items()
        local list = current_list()
        local its = {}
        for _, b in ipairs(list) do
            local nm = (b.label ~= nil and b.label ~= "") and b.label or timestamp(b.pos)
            its[#its + 1] = { kind = "bookmark", ref = b, name = nm, cat = "Bookmarks" }
        end
        its[#its + 1] = { kind = "add", name = "＋ Add bookmark…", cat = "Bookmarks" }
        return its
    end

    active = panel.open({
        title = "bookmarks",
        start_in_list = true,
        items = build_items(),
        category_of = function(_, it) return it.cat end,
        label_of    = function(_, it) return it.name end,
        marker_of   = function() return "" end,
        value_of    = function(_, it)
            -- show the time as the value only when the name is the label
            if it.kind == "bookmark" and it.ref.label ~= nil and it.ref.label ~= "" then
                return timestamp(it.ref.pos)
            end
            return nil
        end,
        search_text = function(_, it) return it.name:lower() end,
        detail = function(_, it)
            if it.kind == "bookmark" then
                local b = it.ref
                return {
                    { t = "title", text = (b.label ~= "" and b.label) or timestamp(b.pos) },
                    { t = "sub", text = "at " .. timestamp(b.pos) },
                    { t = "gap" },
                    { t = "text", text = "Enter to jump to it, rename or delete it.", c = "dim" },
                }
            end
            return {
                { t = "title", text = "Add a bookmark" },
                { t = "gap" },
                { t = "text", text = "Save a marker at the current playback position." },
            }
        end,
        on_activate = function(menu, it)
            if it.kind == "add" then
                local pos = mp.get_property_number("time-pos") or 0
                menu:ask_text{
                    prompt = "Bookmark name", default = timestamp(pos),
                    on_submit = function(t)
                        local k = current_key()
                        if k then store_bookmark(k, pos, t) end
                        menu:reload(build_items())
                    end,
                }
                return
            end
            local b = it.ref
            menu:choose{
                title = describe(b),
                options = {
                    { label = "Jump to it", value = "jump" },
                    { label = "Rename…", value = "rename" },
                    { label = "Delete", value = "delete" },
                },
                on_pick = function(v) defer(function()
                    if v == "jump" then
                        mp.commandv("seek", b.pos, "absolute+exact")
                        mp.osd_message("Jumped to " .. describe(b), 1.5)
                        menu:close()
                    elseif v == "rename" then
                        menu:ask_text{
                            prompt = "Bookmark name", default = b.label,
                            on_submit = function(t)
                                local k = current_key()
                                if k then rename_bookmark(k, b, t) end
                                menu:reload(build_items())
                            end,
                        }
                    elseif v == "delete" then
                        local k = current_key()
                        if k then remove_bookmark(k, b) end
                        menu:reload(build_items())
                    end
                end) end,
            }
        end,
        empty_detail = "Select a bookmark.",
    })
end

mp.add_key_binding(nil, "add", add)
mp.add_key_binding(nil, "open", open)

mp.register_script_message("add", add)
mp.register_script_message("open", open)
mp.register_script_message("list", open)     -- alias
mp.register_script_message("delete", delete)
