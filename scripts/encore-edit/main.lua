-- encore-edit — open mpv's config files in the system text editor.
--
-- Recreates mpv.net's edit-conf-file / show-input-editor. Rather than editing
-- key bindings through an OSD field (clunky), it opens the real file in your
-- default editor — the same thing mpv.net's "edit config file" does. The file
-- is created from a stub if it doesn't exist yet.
--
-- Bindings (script name "encore_edit"):
--   script-binding encore_edit/menu          -- pick which file to edit
--   script-binding encore_edit/mpv-conf
--   script-binding encore_edit/input-conf
--   script-binding encore_edit/encore-conf

package.path = mp.command_native({ "expand-path", "~~/script-modules/?.lua" })
    .. ";" .. package.path

local ui = require "encore-ui"

local is_windows = mp.get_property_native("platform") == "windows"

local function path_of(name)
    return mp.command_native({ "expand-path", "~~home/" .. name })
end

-- Ensure the file exists so the editor has something to open.
local function ensure(path, stub)
    local f = io.open(path, "r")
    if f then f:close(); return end
    local w = io.open(path, "w")
    if w then w:write(stub or ""); w:close() end
end

local function open_in_editor(path)
    if is_windows then
        -- "start" via cmd uses the file's associated editor.
        mp.command_native({
            name = "subprocess",
            playback_only = false,
            args = { "cmd", "/c", "start", "", path },
        })
    else
        local editor = os.getenv("EDITOR") or "xdg-open"
        mp.command_native({
            name = "subprocess",
            playback_only = false,
            args = { editor, path },
        })
    end
    ui.osd("Opening " .. path, 2)
end

local files = {
    { name = "mpv.conf",    stub = "# mpv configuration\n" },
    { name = "input.conf",  stub = "# mpv key bindings\n# KEY  command  #menu: Label\n" },
    { name = "encore.conf", stub = "# mpv.net-specific options (managed by the settings menu)\n" },
}

local function edit(name, stub)
    local path = path_of(name)
    ensure(path, stub)
    open_in_editor(path)
end

local function show_menu()
    local items = {}
    for i, f in ipairs(files) do items[i] = f.name end
    ui.select({
        prompt = "Edit config file:",
        items = items,
        on_select = function(i) edit(files[i].name, files[i].stub) end,
    })
end

mp.add_key_binding(nil, "menu", show_menu)
mp.register_script_message("menu", show_menu)
mp.add_key_binding(nil, "mpv-conf", function() edit("mpv.conf", files[1].stub) end)
mp.add_key_binding(nil, "input-conf", function() edit("input.conf", files[2].stub) end)
mp.add_key_binding(nil, "encore-conf", function() edit("encore.conf", files[3].stub) end)
