-- encore-shaders — a GLSL shader manager with the settings menu's look.
--
-- Pick a shader file, choose how it runs (always on / a toggle key / manual),
-- done. Managed shaders are persisted to JSON, so "always on" ones are applied
-- and "key" ones are bound automatically on every launch — no input.conf edits
-- and no mpv.conf list-merging. It reuses the shared two-pane panel renderer
-- (script-modules/encore-panel.lua), the same UI as the settings editor.
--
-- mpv does the on/off work itself: `change-list glsl-shaders toggle <path>`
-- adds a shader if absent and removes it if present, and the `glsl-shaders`
-- property is the live list. GLSL shaders require --vo=gpu or gpu-next.
--
-- Open it from the right-click menu (Shaders), or:
--   script-binding encore_shaders/open   /   script-message-to encore_shaders open

package.path = mp.command_native({ "expand-path", "~~/script-modules/?.lua" })
    .. ";" .. package.path

local utils = require "mp.utils"
local msg = require "mp.msg"
local panel = require "encore-panel"

local function expand(p) return mp.command_native({ "expand-path", p }) end

local STORE = expand("~~home/encore-shaders.json")
local SHADERS_DIR = expand("~~home/shaders")
local is_windows = mp.get_property_native("platform") == "windows"

-- Stored shaders: { {name=, path="~~/shaders/x.glsl", mode="always"|"key"|"manual", key=}, ... }
local shaders = {}

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local function load_shaders()
    local f = io.open(STORE, "rb")
    if not f then shaders = {}; return end
    local raw = f:read("*a"); f:close()
    local data = raw and raw ~= "" and utils.parse_json(raw) or nil
    shaders = type(data) == "table" and data or {}
end

local function save_shaders()
    local tmp = STORE .. ".encore-tmp"
    local w, err = io.open(tmp, "wb")
    if not w then msg.error("cannot write " .. tmp .. ": " .. tostring(err)); return end
    w:write(utils.format_json(shaders))
    w:close()
    os.remove(STORE)                                  -- Windows rename won't overwrite
    local ok, rerr = os.rename(tmp, STORE)
    if not ok then msg.error("cannot replace shader store: " .. tostring(rerr)) end
end

-- ---------------------------------------------------------------------------
-- glsl-shaders helpers
-- ---------------------------------------------------------------------------

local function vo_supports_shaders()
    local vo = mp.get_property("current-vo")
    return vo == nil or vo == "gpu" or vo == "gpu-next"
end

local function active_set()
    local set = {}
    for _, p in ipairs(mp.get_property_native("glsl-shaders") or {}) do set[p] = true end
    return set
end

local function is_active(path) return active_set()[path] == true end

local function warn_vo()
    if not vo_supports_shaders() then
        mp.osd_message("Shaders need --vo=gpu or gpu-next to take effect.", 4)
    end
end

local function ensure_on(path)
    if not is_active(path) then mp.commandv("change-list", "glsl-shaders", "append", path) end
end

local function set_off(path)
    if is_active(path) then mp.commandv("change-list", "glsl-shaders", "remove", path) end
end

local function toggle(path)
    warn_vo()
    mp.commandv("change-list", "glsl-shaders", "toggle", path)
end

-- ---------------------------------------------------------------------------
-- Keybinds for mode == "key" shaders (registered from JSON each launch)
-- ---------------------------------------------------------------------------

local registered = {}      -- list of binding names currently registered

local function unregister_keys()
    for _, name in ipairs(registered) do mp.remove_key_binding(name) end
    registered = {}
end

local function register_keys()
    unregister_keys()
    for i, sh in ipairs(shaders) do
        if sh.mode == "key" and sh.key and sh.key ~= "" then
            local name = "encore_shader_" .. i
            local path = sh.path
            local label = sh.name
            mp.add_key_binding(sh.key, name, function()
                toggle(path)
                mp.osd_message((is_active(path) and "Shader on: " or "Shader off: ") .. label, 2)
            end)
            registered[#registered + 1] = name
        end
    end
end

-- ---------------------------------------------------------------------------
-- Folder scan: shader files in ~~/shaders not already managed
-- ---------------------------------------------------------------------------

local function scan_folder()
    local out = {}
    local files = utils.readdir(SHADERS_DIR, "files")
    if not files then return out end
    local managed = {}
    for _, sh in ipairs(shaders) do managed[sh.path] = true end
    table.sort(files)
    for _, f in ipairs(files) do
        local lf = f:lower()
        if lf:match("%.glsl$") or lf:match("%.hook$") or lf:match("%.glslc$") then
            local path = "~~/shaders/" .. f
            if not managed[path] then out[#out + 1] = { name = f, path = path } end
        end
    end
    return out
end

-- A native file picker on Windows. The chosen file is COPIED into ~~/shaders
-- (the folder is created if missing) so shaders live alongside the config and
-- stay portable; cb is called with the resulting "~~/shaders/<name>" path. If the
-- file is already in that folder it's used in place (no self-copy).
local function browse_dialog(cb)
    if not is_windows then
        mp.osd_message("Put shader files in " .. SHADERS_DIR .. " to add them.", 4)
        return
    end
    local dir = SHADERS_DIR:gsub("/", "\\"):gsub("'", "''")
    local script = table.concat({
        "Add-Type -AssemblyName System.Windows.Forms;",
        "$d = New-Object System.Windows.Forms.OpenFileDialog;",
        "$d.Title='Select a shader';",
        "$d.Filter='Shaders|*.glsl;*.hook;*.glslc|All files|*.*';",
        "$dir='" .. dir .. "';",
        "$d.InitialDirectory=$dir;",
        "if ($d.ShowDialog() -eq 'OK') {",
        "  $src=$d.FileName;",
        "  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null };",
        "  $name=[System.IO.Path]::GetFileName($src);",
        "  $dest=Join-Path $dir $name;",
        "  if ([System.IO.Path]::GetFullPath($src) -ne [System.IO.Path]::GetFullPath($dest)) { Copy-Item -LiteralPath $src -Destination $dest -Force };",
        "  [Console]::Out.Write($name)",
        "}",
    }, " ")
    mp.command_native_async({
        name = "subprocess", playback_only = false, capture_stdout = true,
        args = { "powershell", "-NoProfile", "-NonInteractive", "-STA", "-Command", script },
    }, function(ok, res)
        local name = (ok and res and res.status == 0 and (res.stdout or "")) or ""
        name = name:gsub("%s+$", "")
        if name == "" then return end
        cb("~~/shaders/" .. name)        -- always portable, now inside the folder
    end)
end

-- ---------------------------------------------------------------------------
-- Menu model
-- ---------------------------------------------------------------------------

local CAT_MINE = "My Shaders"
local CAT_ADD  = "Add from Folder"

local function build_items()
    local items = {}
    for _, sh in ipairs(shaders) do
        items[#items + 1] = { kind = "shader", ref = sh, name = sh.name, cat = CAT_MINE }
    end
    items[#items + 1] = { kind = "add", name = "＋ Add shader…", cat = CAT_MINE }
    for _, f in ipairs(scan_folder()) do
        items[#items + 1] = { kind = "browse", name = f.name, path = f.path, cat = CAT_ADD }
    end
    return items
end

local function mode_label(sh)
    if sh.mode == "always" then return "always on" end
    if sh.mode == "key" then return "key: " .. (sh.key or "?") end
    return "manual"
end

-- defer UI work until after the panel finishes the current click handler, so we
-- never re-render/ask-text in the middle of list_activate's continuation.
local function defer(fn) mp.add_timeout(0, fn) end

local active_menu       -- single-instance guard

-- forward declarations (mutually recursive flows)
local configure_shader, shader_actions, add_flow

-- choose the run mode for a shader, then persist + apply
configure_shader = function(menu, sh)
    menu:choose{
        title = "How should “" .. sh.name .. "” run?",
        options = {
            { label = "Always on", value = "always" },
            { label = "Assign a key…", value = "key" },
            { label = "Manual (toggle from this menu)", value = "manual" },
        },
        current = sh.mode,
        on_pick = function(m) defer(function()
            if m == "key" then
                menu:ask_text{
                    prompt = "Key for “" .. sh.name .. "” (e.g. F2, Ctrl+s)",
                    default = sh.key,
                    -- runs after the menu is restored (see Menu:ask_text)
                    on_submit = function(k)
                        if k and k ~= "" then sh.mode = "key"; sh.key = k end
                        save_shaders(); register_keys(); menu:reload(build_items())
                    end,
                }
                return
            elseif m == "always" then
                sh.mode = "always"; sh.key = nil; warn_vo(); ensure_on(sh.path)
            else
                sh.mode = "manual"; sh.key = nil
            end
            save_shaders(); register_keys(); menu:reload(build_items())
        end) end,
    }
end

-- the per-shader action chooser (Enter on a managed shader)
shader_actions = function(menu, sh)
    local on = is_active(sh.path)
    menu:choose{
        title = "Shader: " .. sh.name,
        options = {
            { label = on and "Turn off now" or "Turn on now", value = "toggle" },
            { label = "Change how it runs…", value = "mode" },
            { label = "Rename…", value = "rename" },
            { label = "Remove", value = "remove" },
        },
        on_pick = function(v) defer(function()
            if v == "toggle" then
                toggle(sh.path); menu:refresh()
            elseif v == "mode" then
                configure_shader(menu, sh)
            elseif v == "rename" then
                menu:ask_text{ prompt = "Shader name", default = sh.name,
                    on_submit = function(t)
                        if t and t ~= "" then sh.name = t end
                        save_shaders(); menu:reload(build_items())
                    end }
            elseif v == "remove" then
                set_off(sh.path)
                for i, s in ipairs(shaders) do if s == sh then table.remove(shaders, i); break end end
                save_shaders(); register_keys(); menu:reload(build_items())
            end
        end) end,
    }
end

-- add a shader by path, then ask how it should run
local function add_shader(menu, path)
    -- derive a friendly default name from the file name
    local name = (path:gsub("[/\\]+$", "")):match("([^/\\]+)$") or path
    name = name:gsub("%.%w+$", "")
    local sh = { name = name, path = path, mode = "manual" }
    shaders[#shaders + 1] = sh
    save_shaders()
    menu:reload(build_items())
    defer(function() configure_shader(menu, sh) end)
end

-- the "＋ Add shader…" flow: pick from the folder, or browse (Windows)
add_flow = function(menu)
    local opts = {}
    for _, f in ipairs(scan_folder()) do
        opts[#opts + 1] = { label = f.name, value = f.path }
    end
    if is_windows then
        opts[#opts + 1] = { label = "Browse for a file…", value = "__browse__" }
    end
    if #opts == 0 then
        mp.osd_message("No new shaders in " .. SHADERS_DIR, 4)
        return
    end
    menu:choose{
        title = "Add a shader",
        options = opts,
        on_pick = function(v) defer(function()
            if v == "__browse__" then
                browse_dialog(function(path) defer(function() add_shader(menu, path) end) end)
            else
                add_shader(menu, v)
            end
        end) end,
    }
end

local MODEL = {
    title = "shaders",
    category_of = function(_, it) return it.cat end,
    label_of    = function(_, it) return it.name end,
    search_text = function(_, it) return (it.name .. " " .. (it.path or "")):lower() end,

    value_of = function(_, it)
        if it.kind == "shader" then
            return (is_active(it.ref.path) and "on" or "off") .. " · " .. mode_label(it.ref)
        end
        return nil
    end,

    marker_of = function(_, it)
        if it.kind == "shader" and is_active(it.ref.path) then return "●" end
        return ""
    end,

    detail = function(_, it)
        if it.kind == "shader" then
            local sh = it.ref
            local b = {
                { t = "title", text = sh.name },
                { t = "sub", text = sh.path },
                { t = "gap" },
                { t = "text", text = "Status:  " .. (is_active(sh.path) and "ON" or "off") },
                { t = "text", text = "Runs:    " .. mode_label(sh) },
            }
            b[#b + 1] = { t = "gap" }
            b[#b + 1] = { t = "text",
                text = "Enter to toggle it now, change how it runs, rename or remove it.",
                c = "dim" }
            if not vo_supports_shaders() then
                b[#b + 1] = { t = "gap" }
                b[#b + 1] = { t = "text",
                    text = "Note: your video output is " .. tostring(mp.get_property("current-vo"))
                        .. "; shaders need vo=gpu or gpu-next.", c = "faint" }
            end
            return b
        elseif it.kind == "add" then
            return {
                { t = "title", text = "Add a shader" },
                { t = "gap" },
                { t = "text", text = "Pick a shader file to manage"
                    .. (is_windows and " (from your shaders folder, or browse for one)" or "") .. "." },
                { t = "gap" },
                { t = "text", text = "Shader files live in:", c = "dim" },
                { t = "text", text = SHADERS_DIR, c = "dim" },
            }
        else -- browse
            return {
                { t = "title", text = it.name },
                { t = "sub", text = it.path },
                { t = "gap" },
                { t = "text", text = "Press Enter to add this shader and choose how it runs." },
            }
        end
    end,

    on_activate = function(menu, it)
        if it.kind == "shader" then
            shader_actions(menu, it.ref)
        elseif it.kind == "add" then
            add_flow(menu)
        elseif it.kind == "browse" then
            defer(function() add_shader(menu, it.path) end)
        end
    end,

    empty_detail = "Select a shader to manage it.",
}

-- ---------------------------------------------------------------------------
-- Entry point + startup
-- ---------------------------------------------------------------------------

local function open_manager()
    if active_menu and not active_menu.closed then return end
    MODEL.items = build_items()
    active_menu = panel.open(MODEL)
end

mp.add_key_binding(nil, "open", open_manager)
mp.register_script_message("open", open_manager)

-- On startup: apply the always-on shaders and bind the key-toggle shaders.
load_shaders()
for _, sh in ipairs(shaders) do
    if sh.mode == "always" then ensure_on(sh.path) end
end
register_keys()
