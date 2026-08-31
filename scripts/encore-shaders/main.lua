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
-- Shaders the user already set in mpv.conf are detected at startup and offered
-- under "From mpv.conf"; importing one moves it out of mpv.conf and into Encore
-- (always-on) so there's a single owner and no dual-source conflicts.
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

-- Stored shaders: { {name=, path="~~/shaders/x.glsl", mode="always"|"key"|"manual",
--                    key=, opts={"param=value", ...}}, ... }
local shaders = {}

-- Stored presets: named, ordered groups of shader paths toggled together.
-- { {name=, members={path1, path2, ...}, key= (optional)}, ... }
local presets = {}

-- Shaders found in glsl-shaders at startup that Encore doesn't manage — i.e. ones
-- the user set in mpv.conf. Offered for import; not persisted by us until adopted.
local preconfigured = {}

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

-- The on-disk store is an object { shaders = [...], presets = [...] }. Older
-- versions wrote a bare ARRAY of shader objects; migrate that form transparently
-- (treat the array as `shaders` with no presets) so no user data is ever lost.
local function load_shaders()
    shaders = {}
    presets = {}
    local f = io.open(STORE, "rb")
    if not f then return end
    local raw = f:read("*a"); f:close()
    local data = raw and raw ~= "" and utils.parse_json(raw) or nil
    if type(data) ~= "table" then return end
    if data.shaders == nil and data.presets == nil then
        -- legacy array form: the whole document is the shader list
        shaders = data
    else
        shaders = type(data.shaders) == "table" and data.shaders or {}
        presets = type(data.presets) == "table" and data.presets or {}
    end
    -- defend against a hand-edited / malformed store so rendering can't crash
    for i = #shaders, 1, -1 do
        if type(shaders[i]) ~= "table" or type(shaders[i].path) ~= "string" then
            table.remove(shaders, i)
        end
    end
    for i = #presets, 1, -1 do
        local pre = presets[i]
        if type(pre) ~= "table" or type(pre.name) ~= "string" then
            table.remove(presets, i)
        elseif type(pre.members) ~= "table" then
            pre.members = {}
        end
    end
end

-- Write `bytes` to `path` as safely as we can: write a temp file, move the
-- original aside to a .bak, swap the temp in, then drop the .bak. On any failure
-- the original is restored, so a crash or error can't lose the user's file (this
-- matters: it also rewrites the user's hand-edited mpv.conf / input.conf).
local function atomic_replace(path, bytes)
    local tmp = path .. ".encore-tmp"
    local w, err = io.open(tmp, "wb")
    if not w then msg.error("cannot write " .. tmp .. ": " .. tostring(err)); return false end
    w:write(bytes); w:close()
    local bak = path .. ".encore-bak"
    os.remove(bak)
    os.rename(path, bak)                 -- move original aside (no-op if it didn't exist)
    local ok, rerr = os.rename(tmp, path)
    if not ok then
        os.rename(bak, path)            -- restore the original on failure
        msg.error("cannot replace " .. path .. ": " .. tostring(rerr))
        return false
    end
    os.remove(bak)
    return true
end

local function save_shaders()
    return atomic_replace(STORE, utils.format_json({ shaders = shaders, presets = presets }))
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

-- Does the shader file actually exist on disk? (~~ paths are expanded first.)
local function file_exists(path)
    return utils.file_info(expand(path)) ~= nil
end

-- glsl-shader-opts is a key/value list option. `append` takes "param=value";
-- `remove` deletes by KEY only. To keep one shader's options from clobbering
-- another's that happens to use the same parameter name, we scope each option to
-- the shader by name — the mpv manual's "shadername/param=value" form, where the
-- shader name is the base filename without extension. Options the user already
-- scoped (containing a "/") are passed through unchanged.
local function param_prefix(path)
    local b = (path:gsub("[/\\]+$", "")):match("([^/\\]+)$") or path
    return (b:gsub("%.%w+$", ""))
end

local function scoped_opt(name, o)
    if o:find("/", 1, true) then return o end       -- already targets a shader
    return name .. "/" .. o
end

local function add_opts(name, opts)
    if not opts then return end
    for _, o in ipairs(opts) do
        if o and o ~= "" then
            mp.commandv("change-list", "glsl-shader-opts", "append", scoped_opt(name, o))
        end
    end
end

local function remove_opts(name, opts)
    if not opts then return end
    for _, o in ipairs(opts) do
        if o and o ~= "" then
            local k = scoped_opt(name, o):match("^([^=]*)") or o   -- remove by key
            k = (k:gsub("%s+$", ""))
            if k ~= "" then mp.commandv("change-list", "glsl-shader-opts", "remove", k) end
        end
    end
end

-- Turn a shader ON and apply its options. Options are applied ONLY when the path
-- was actually added, so calling this on an already-active shader can't make its
-- options accumulate. unapply_shader is the exact mirror.
local function apply_shader(path, opts)
    if is_active(path) then return end
    mp.commandv("change-list", "glsl-shaders", "append", path)
    add_opts(param_prefix(path), opts)
end

local function unapply_shader(path, opts)
    if not is_active(path) then return end
    mp.commandv("change-list", "glsl-shaders", "remove", path)
    remove_opts(param_prefix(path), opts)
end

-- Look up a managed shader's opts by path (canonical match); nil if not managed.
local canon       -- forward declaration (defined below with the other path helpers)
local function opts_for(path)
    local c = canon(path)
    for _, sh in ipairs(shaders) do
        if canon(sh.path) == c then return sh.opts end
    end
    return nil
end

local function ensure_on(path)
    apply_shader(path, opts_for(path))
end

local function set_off(path)
    unapply_shader(path, opts_for(path))
end

-- Toggle a managed shader on/off, applying/removing its options to match.
local function toggle(path)
    warn_vo()
    if is_active(path) then unapply_shader(path, opts_for(path))
    else apply_shader(path, opts_for(path)) end
end

-- ---------------------------------------------------------------------------
-- Importing shaders that were preconfigured in mpv.conf
-- ---------------------------------------------------------------------------

-- Canonical form of a shader path for reliable comparison (resolves ~~, and on
-- Windows normalises slashes + case) so "~~/shaders/x" and its absolute form match.
-- Assigns to the forward-declared `canon` above (used by opts_for et al.).
function canon(p)
    local e = expand(p)
    if is_windows then e = e:gsub("/", "\\"):lower() end
    return e
end

local function basename(p)
    return (p:gsub("[/\\]+$", "")):match("([^/\\]+)$") or p
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- Is this path already one of our managed shaders?
local function is_managed(path)
    local c = canon(path)
    for _, sh in ipairs(shaders) do
        if canon(sh.path) == c then return true end
    end
    return false
end

local MPV_CONF = expand("~~home/mpv.conf")
local INPUT_CONF = expand("~~home/input.conf")
local GLSL_KEYS = {
    ["glsl-shaders"] = true, ["glsl-shader"] = true,
    ["glsl-shaders-append"] = true, ["glsl-shader-append"] = true,
}
local SEP = is_windows and ";" or ":"      -- mpv path lists use the OS separator

-- Strip an inline comment from an mpv.conf option value. Per the mpv manual,
-- everything after a '#' is a comment; but '#' inside a quoted value is literal.
-- Returns the bare value and the quote char used ("" if unquoted). Returns nil if
-- the line shouldn't be touched (unterminated quote, or %n% fixed-length quoting,
-- which is rare and risky to rewrite — we leave such lines alone).
local function parse_conf_value(value)
    local v = trim(value)
    local q = v:sub(1, 1)
    if q == '"' or q == "'" then
        local inner = v:match("^" .. q .. "(.-)" .. q)
        if not inner then return nil end          -- unterminated quote: don't touch
        return inner, q
    end
    if v:match("^%%%d") then return nil end        -- %n% fixed-length quoting: skip
    return trim((v:gsub("%s*#.*$", ""))), ""       -- drop trailing comment
end

-- Remove `raw_path` from any glsl-shaders option in the GLOBAL scope of mpv.conf.
-- Profiles ([name]) are skipped; the name "default" re-enters global scope (per the
-- mpv manual). Only the plural list option (glsl-shaders) is separator-joined; the
-- singular / -append aliases each carry exactly one path. Comments, other options,
-- ordering, quoting, BOM and line endings are preserved; the write is safe.
-- Returns true if an entry was found and removed.
local function remove_glsl_from_mpv_conf(raw_path)
    local f = io.open(MPV_CONF, "rb")
    if not f then return false end
    local raw = f:read("*a") or ""; f:close()

    local bom = ""
    if raw:sub(1, 3) == "\239\187\191" then bom = raw:sub(1, 3); raw = raw:sub(4) end
    local nl = raw:find("\r\n", 1, true) and "\r\n" or "\n"

    local norm = raw:gsub("\r\n", "\n"):gsub("\r", "\n")
    if norm:sub(-1) ~= "\n" then norm = norm .. "\n" end
    local lines = {}
    for line in norm:gmatch("(.-)\n") do lines[#lines + 1] = line end

    local target = canon(raw_path)
    local removed, delete = false, {}
    local in_global = true                          -- options before any [section] are global

    for i, l in ipairs(lines) do
        local section = l:match("^%s*%[(.-)%]")
        if section then
            in_global = (section == "default")     -- a profile scopes options; "default" returns to global
        elseif in_global then
            local indent, key = l:match("^(%s*)([%w%-]+)%s*=")
            if key and GLSL_KEYS[key:lower()] then
                local value = l:match("^%s*[%w%-]+%s*=%s*(.*)$")
                local v, q = parse_conf_value(value or "")
                if v then
                    local segs
                    if key:lower() == "glsl-shaders" then    -- the only list option
                        segs = {}
                        for seg in (v .. SEP):gmatch("(.-)" .. SEP) do
                            if seg ~= "" then segs[#segs + 1] = seg end
                        end
                    else
                        segs = { v }                          -- singular / -append: one path
                    end
                    local kept, changed = {}, false
                    for _, seg in ipairs(segs) do
                        if canon(trim(seg)) == target then changed = true
                        else kept[#kept + 1] = seg end
                    end
                    if changed then
                        removed = true
                        if #kept == 0 then delete[i] = true
                        else lines[i] = indent .. key .. "=" .. q .. table.concat(kept, SEP) .. q end
                    end
                end
            end
        end
    end

    if not removed then return false end

    local out = {}
    for i, l in ipairs(lines) do if not delete[i] then out[#out + 1] = l end end
    return atomic_replace(MPV_CONF, bom .. table.concat(out, nl) .. (#out > 0 and nl or ""))
end

-- Extract the first quoted-or-bare argument from `rest`, stripping a trailing
-- ";next-command" or "#comment" off an unquoted value. Returns the value or nil.
local function first_arg(rest)
    rest = trim(rest)
    local q = rest:sub(1, 1)
    if q == '"' or q == "'" then
        return rest:match("^" .. q .. "(.-)" .. q)
    end
    local p = rest:match("^(%S+)")           -- unquoted: up to whitespace
    return p and (p:gsub("[;#].*$", ""))     -- drop a ";next-command" or "#comment" if attached
end

-- Pull the shader path out of an input.conf command that turns a glsl shader on,
-- recognising the common idioms a user might bind a key to:
--   * `change-list glsl-shaders toggle <path>`   (the documented on/off toggle)
--   * `change-list glsl-shaders append <path>`   (enable; treated as a key shader)
--   * `change-list glsl-shaders set    <path>`   (enable; treated as a key shader)
--   * `cycle-values glsl-shaders "<path>" ""`    (the classic on/off cycle idiom)
-- `no-osd` prefixes, quoted/unquoted paths and trailing `; …` / `# …` are handled.
-- `apply-profile` is intentionally NOT handled (too indirect). Returns the path
-- (quotes stripped) or nil if the command isn't one we recognise.
local function shader_toggle_path(cmd)
    local rest = cmd:match("change%-list%s+glsl%-shaders%s+toggle%s+(.+)")
        or cmd:match("change%-list%s+glsl%-shaders%s+append%s+(.+)")
        or cmd:match("change%-list%s+glsl%-shaders%s+set%s+(.+)")
    if rest then return first_arg(rest) end
    -- cycle-values glsl-shaders "<path>" "" — first value is the path, second "".
    local cyc = cmd:match("cycle%-values%s+glsl%-shaders%s+(.+)")
    if cyc then return first_arg(cyc) end
    return nil
end

-- Keys in input.conf are matched case-insensitively by mpv; mirror that.
local function same_key(a, b) return a:lower() == b:lower() end

-- Forward declarations for the key-conflict helpers, which are defined later but
-- referenced from import_one (above their definition).
local key_conflict, warn_key_conflict

-- Scan input.conf for shader-toggle bindings -> { {key=, path=}, ... }.
local function scan_input_conf()
    local out = {}
    local f = io.open(INPUT_CONF, "rb")
    if not f then return out end
    for line in f:lines() do
        local s = trim((line:gsub("\r$", "")))
        if s ~= "" and s:sub(1, 1) ~= "#" then
            local key, cmd = s:match("^(%S+)%s+(.+)$")
            if key and cmd then
                local p = shader_toggle_path(cmd)
                if p and p ~= "" then out[#out + 1] = { key = key, path = p } end
            end
        end
    end
    f:close()
    return out
end

-- Remove the input.conf binding for (key -> toggle path), comment-preserving and
-- atomic. Returns true if a matching line was found and removed.
local function remove_binding_from_input_conf(key, path)
    local f = io.open(INPUT_CONF, "rb")
    if not f then return false end
    local raw = f:read("*a") or ""; f:close()

    local bom = ""
    if raw:sub(1, 3) == "\239\187\191" then bom = raw:sub(1, 3); raw = raw:sub(4) end
    local nl = raw:find("\r\n", 1, true) and "\r\n" or "\n"
    local norm = raw:gsub("\r\n", "\n"):gsub("\r", "\n")
    if norm:sub(-1) ~= "\n" then norm = norm .. "\n" end
    local lines = {}
    for line in norm:gmatch("(.-)\n") do lines[#lines + 1] = line end

    local target = canon(path)
    local removed, delete = false, {}
    for i, l in ipairs(lines) do
        local s = trim(l)
        if s ~= "" and s:sub(1, 1) ~= "#" then
            local k, cmd = s:match("^(%S+)%s+(.+)$")
            if k and cmd and same_key(k, key) then
                local p = shader_toggle_path(cmd)
                if p and canon(p) == target then delete[i] = true; removed = true end
            end
        end
    end
    if not removed then return false end

    local out = {}
    for i, l in ipairs(lines) do if not delete[i] then out[#out + 1] = l end end
    return atomic_replace(INPUT_CONF, bom .. table.concat(out, nl) .. (#out > 0 and nl or ""))
end

-- Detect shaders the user preconfigured but Encore doesn't manage: always-on ones
-- in mpv.conf (already in glsl-shaders), and toggle-key ones in input.conf. Merged
-- by canonical path; an entry may carry { in_conf=true } and/or { key=, in_input=true }.
local function detect_preconfigured()
    preconfigured = {}
    local seen = {}
    local function add(path, key)
        if is_managed(path) then return end
        local c = canon(path)
        local e = seen[c]
        if not e then
            e = { path = path }
            preconfigured[#preconfigured + 1] = e
            seen[c] = e
        end
        if key then e.key = key; e.in_input = true else e.in_conf = true end
    end
    for _, p in ipairs(mp.get_property_native("glsl-shaders") or {}) do add(p, nil) end
    for _, b in ipairs(scan_input_conf()) do add(b.path, b.key) end
end

-- Adopt a preconfigured shader: remove it from wherever the user set it (mpv.conf
-- and/or input.conf) and manage it in Encore, so there's a single owner — no dual
-- source. Always-on shaders become mode "always"; toggle-key ones become mode
-- "key" with that key. Returns true on success; false if a source couldn't be
-- cleaned (e.g. set inside a profile), in which case nothing is adopted.
--
-- Removals run before adoption, but the moment ANY removal succeeds we commit to
-- adopting, so a shader can never end up removed-from-config-but-not-managed (no
-- data loss). The only refusal is when the FIRST required removal fails outright.
local function import_one(e)
    if is_managed(e.path) then return true end
    local removed = false
    if e.in_conf then
        if remove_glsl_from_mpv_conf(e.path) then removed = true
        elseif not removed then return false end
    end
    if e.in_input then
        if remove_binding_from_input_conf(e.key, e.path) then removed = true
        elseif not removed then return false end
    end
    if not removed then return false end           -- nothing to remove (shouldn't happen)
    local mode = e.key and "key" or "always"
    if mode == "key" then warn_key_conflict(e.key, nil) end
    shaders[#shaders + 1] = {
        name = (basename(e.path):gsub("%.%w+$", "")), path = e.path, mode = mode, key = e.key,
    }
    save_shaders()
    if mode == "always" then ensure_on(e.path) end
    -- For key imports we do NOT register a binding now: the user's input.conf
    -- binding is still live in memory this session, so the key keeps working;
    -- next launch (input.conf cleaned) register_keys() binds it. Avoids a
    -- double-fire on the key this session.
    for i, x in ipairs(preconfigured) do
        if x == e then table.remove(preconfigured, i); break end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Shader ordering and live re-apply
-- ---------------------------------------------------------------------------

-- The order of `shaders` is the intended apply order of the always-on stack. After
-- a reorder, re-apply that order live: drop every managed always-on path currently
-- in glsl-shaders, then re-append them in array order. Non-managed entries (e.g.
-- shaders the user toggled on by hand) are left in place as best we can — they keep
-- their relative position because we only remove/re-add the managed always-on ones.
local function reapply_always_order()
    local ordered = {}             -- always-on managed shaders in array order
    for _, sh in ipairs(shaders) do
        if sh.mode == "always" then ordered[#ordered + 1] = sh end
    end
    -- remove any managed always-on path that's currently active (and its opts)
    for _, sh in ipairs(ordered) do
        if is_active(sh.path) then unapply_shader(sh.path, sh.opts) end
    end
    -- re-append in array order, skipping ones whose file is missing
    for _, sh in ipairs(ordered) do
        if file_exists(sh.path) then apply_shader(sh.path, sh.opts) end
    end
end

-- Swap shader at index i with its neighbour at i+delta (delta = -1 up, +1 down),
-- persist, and re-apply the live order. Returns the shader's new index or nil.
local function move_shader(sh, delta)
    local idx
    for i, s in ipairs(shaders) do if s == sh then idx = i; break end end
    if not idx then return nil end
    local j = idx + delta
    if j < 1 or j > #shaders then return nil end
    shaders[idx], shaders[j] = shaders[j], shaders[idx]
    save_shaders()
    reapply_always_order()
    return j
end

-- ---------------------------------------------------------------------------
-- Presets: named, ordered groups of shaders toggled together
-- ---------------------------------------------------------------------------

-- A preset is active when every member whose file EXISTS is currently in
-- glsl-shaders (missing members are ignored, so one missing file doesn't make a
-- preset un-toggleable). A preset with no existing members is never "active".
local function preset_active(pre)
    local any = false
    for _, p in ipairs(pre.members) do
        if file_exists(p) then
            any = true
            if not is_active(p) then return false end
        end
    end
    return any
end

-- Apply a member path with whatever opts the matching managed shader declares.
local function apply_member(path) apply_shader(path, opts_for(path)) end
local function unapply_member(path) unapply_shader(path, opts_for(path)) end

-- Mode of the managed shader at this path, or nil if the path isn't managed.
local function mode_of(path)
    local c = canon(path)
    for _, sh in ipairs(shaders) do
        if canon(sh.path) == c then return sh.mode end
    end
    return nil
end

-- Turn a whole preset on or off. On: append each existing member (in order) not
-- already active. Off: remove each member EXCEPT those the user keeps always-on
-- independently (so toggling a preset off never disables an always-on shader).
local function toggle_preset(pre)
    warn_vo()
    if preset_active(pre) then
        for _, p in ipairs(pre.members) do
            if mode_of(p) ~= "always" then unapply_member(p) end
        end
    else
        for _, p in ipairs(pre.members) do
            if file_exists(p) and not is_active(p) then apply_member(p) end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Key-conflict detection
-- ---------------------------------------------------------------------------

-- Keys in input.conf are matched case-insensitively by mpv; mirror that.
-- (Defined earlier as same_key; reused here for conflict checks.)

-- Find a managed shader or preset (other than `self_ref`) already bound to `key`.
-- Returns a human-readable description of the conflict, or nil if none.
-- (Assigns to the forward-declared locals above.)
key_conflict = function(key, self_ref)
    if not key or key == "" then return nil end
    for _, sh in ipairs(shaders) do
        if sh ~= self_ref and sh.mode == "key" and sh.key and same_key(sh.key, key) then
            return "shader “" .. sh.name .. "”"
        end
    end
    for _, pre in ipairs(presets) do
        if pre ~= self_ref and pre.key and same_key(pre.key, key) then
            return "preset “" .. pre.name .. "”"
        end
    end
    return nil
end

-- Warn (OSD) if assigning `key` to `self_ref` collides with another managed item.
warn_key_conflict = function(key, self_ref)
    local who = key_conflict(key, self_ref)
    if who then
        mp.osd_message("Warning: key " .. key .. " is already used by " .. who
            .. ". The last one registered will win.", 5)
    end
end

-- ---------------------------------------------------------------------------
-- Keybinds for mode == "key" shaders and presets (registered from JSON each launch)
-- ---------------------------------------------------------------------------

local registered = {}      -- list of binding names currently registered

local function unregister_keys()
    for _, name in ipairs(registered) do mp.remove_key_binding(name) end
    registered = {}
end

local function register_keys()
    unregister_keys()
    local used = {}        -- lower(key) -> description, to detect duplicate bindings
    local function note(key, what)
        local lk = key:lower()
        if used[lk] then
            msg.warn("key " .. key .. " is bound to both " .. used[lk]
                .. " and " .. what .. "; the last registered wins")
        end
        used[lk] = what
    end
    for i, sh in ipairs(shaders) do
        if sh.mode == "key" and sh.key and sh.key ~= "" then
            local name = "encore_shader_" .. i
            local path = sh.path
            local label = sh.name
            note(sh.key, "shader “" .. label .. "”")
            mp.add_key_binding(sh.key, name, function()
                toggle(path)
                mp.osd_message((is_active(path) and "Shader on: " or "Shader off: ") .. label, 2)
            end)
            registered[#registered + 1] = name
        end
    end
    for i, pre in ipairs(presets) do
        if pre.key and pre.key ~= "" then
            local name = "encore_preset_" .. i
            local p = pre
            local label = pre.name
            note(pre.key, "preset “" .. label .. "”")
            mp.add_key_binding(pre.key, name, function()
                toggle_preset(p)
                mp.osd_message((preset_active(p) and "Preset on: " or "Preset off: ") .. label, 2)
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
    -- exclude shaders we already manage or that are offered under "From mpv.conf"
    local seen = {}
    for _, sh in ipairs(shaders) do seen[canon(sh.path)] = true end
    for _, e in ipairs(preconfigured) do seen[canon(e.path)] = true end
    table.sort(files)
    for _, f in ipairs(files) do
        local lf = f:lower()
        if lf:match("%.glsl$") or lf:match("%.hook$") or lf:match("%.glslc$") then
            local path = "~~/shaders/" .. f
            if not seen[canon(path)] then out[#out + 1] = { name = f, path = path } end
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
local CAT_PRESETS = "Presets"
local CAT_ADD  = "Add from Folder"
local CAT_PRE  = "Preconfigured"

-- Does any managed shader currently reference a file that's gone from disk?
local function any_missing()
    for _, sh in ipairs(shaders) do
        if not file_exists(sh.path) then return true end
    end
    return false
end

local function build_items()
    local items = {}
    for _, sh in ipairs(shaders) do
        items[#items + 1] = { kind = "shader", ref = sh, name = sh.name, cat = CAT_MINE }
    end
    items[#items + 1] = { kind = "add", name = "＋ Add shader…", cat = CAT_MINE }
    if any_missing() then
        items[#items + 1] = { kind = "prune", name = "⚠ Prune missing shaders", cat = CAT_MINE }
    end
    -- presets: named, ordered groups toggled together
    for _, pre in ipairs(presets) do
        items[#items + 1] = { kind = "preset", ref = pre, name = pre.name, cat = CAT_PRESETS }
    end
    items[#items + 1] = { kind = "newpreset", name = "＋ New preset…", cat = CAT_PRESETS }
    for _, f in ipairs(scan_folder()) do
        items[#items + 1] = { kind = "browse", name = f.name, path = f.path, cat = CAT_ADD }
    end
    -- shaders the user set in mpv.conf / input.conf, offered for adoption
    if #preconfigured > 0 then
        for _, e in ipairs(preconfigured) do
            items[#items + 1] = { kind = "ext", entry = e, name = basename(e.path), cat = CAT_PRE }
        end
        items[#items + 1] = { kind = "importall", name = "↓ Import all to Encore", cat = CAT_PRE }
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
local preset_actions, edit_members, new_preset

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
                        if k and k ~= "" then
                            warn_key_conflict(k, sh)
                            sh.mode = "key"; sh.key = k
                        end
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
    local missing = not file_exists(sh.path)
    -- index in the shaders array, for the move affordances
    local idx
    for i, s in ipairs(shaders) do if s == sh then idx = i; break end end

    local options = {}
    if missing then
        options[#options + 1] = { label = "Remove (missing file)", value = "remove" }
    else
        options[#options + 1] = { label = on and "Turn off now" or "Turn on now", value = "toggle" }
    end
    options[#options + 1] = { label = "Change how it runs…", value = "mode" }
    options[#options + 1] = { label = "Set options…", value = "opts" }
    if idx and idx > 1 then
        options[#options + 1] = { label = "Move up", value = "up" }
    end
    if idx and idx < #shaders then
        options[#options + 1] = { label = "Move down", value = "down" }
    end
    options[#options + 1] = { label = "Rename…", value = "rename" }
    if not missing then
        options[#options + 1] = { label = "Remove", value = "remove" }
    end

    menu:choose{
        title = "Shader: " .. sh.name,
        options = options,
        on_pick = function(v) defer(function()
            if v == "toggle" then
                toggle(sh.path); menu:refresh()
            elseif v == "mode" then
                configure_shader(menu, sh)
            elseif v == "opts" then
                menu:ask_text{
                    prompt = "Options for “" .. sh.name
                        .. "” (param=value, comma-separated)",
                    default = sh.opts and table.concat(sh.opts, ", ") or "",
                    on_submit = function(t)
                        local pfx = param_prefix(sh.path)
                        -- remove any currently-applied opts before replacing them
                        if is_active(sh.path) then remove_opts(pfx, sh.opts) end
                        local list = {}
                        for piece in ((t or "") .. ","):gmatch("(.-),") do
                            local o = trim(piece)
                            if o ~= "" then list[#list + 1] = o end
                        end
                        sh.opts = #list > 0 and list or nil
                        if is_active(sh.path) then add_opts(pfx, sh.opts) end
                        save_shaders(); menu:reload(build_items())
                    end }
            elseif v == "up" then
                move_shader(sh, -1); menu:reload(build_items())
            elseif v == "down" then
                move_shader(sh, 1); menu:reload(build_items())
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

-- Remove every managed shader whose file is missing on disk (turning each off
-- first), persist, re-register keys, and reload.
local function prune_missing(menu)
    local removed = 0
    for i = #shaders, 1, -1 do
        local sh = shaders[i]
        if not file_exists(sh.path) then
            set_off(sh.path)
            table.remove(shaders, i)
            removed = removed + 1
        end
    end
    if removed > 0 then save_shaders(); register_keys() end
    mp.osd_message("Pruned " .. removed .. " missing shader" .. (removed == 1 and "" or "s") .. ".", 3)
    menu:reload(build_items())
end

-- A short label for a preset value/marker: "on · N shaders" plus its key, if any.
local function preset_value(pre)
    local n = #pre.members
    local s = (preset_active(pre) and "on" or "off") .. " · " .. n
        .. " shader" .. (n == 1 and "" or "s")
    if pre.key and pre.key ~= "" then s = s .. " · key: " .. pre.key end
    return s
end

-- Edit which managed shaders belong to a preset. Lists every managed shader as a
-- toggleable membership row (active members are dotted, in their current order at
-- the top); picking one adds or removes it. A "Done" row closes the editor.
edit_members = function(menu, pre)
    local options = {}
    -- in-preset members first, in order, so the list reflects apply order
    local in_preset = {}
    for _, p in ipairs(pre.members) do in_preset[canon(p)] = true end
    for _, p in ipairs(pre.members) do
        local name = basename(p)
        for _, sh in ipairs(shaders) do
            if canon(sh.path) == canon(p) then name = sh.name; break end
        end
        options[#options + 1] = { label = "● " .. name, value = "toggle:" .. p }
    end
    -- then the managed shaders not yet in the preset
    for _, sh in ipairs(shaders) do
        if not in_preset[canon(sh.path)] then
            options[#options + 1] = { label = "  " .. sh.name, value = "toggle:" .. sh.path }
        end
    end
    options[#options + 1] = { label = "Done", value = "__done__" }

    menu:choose{
        title = "Members of “" .. pre.name .. "” (Enter toggles)",
        options = options,
        on_pick = function(v) defer(function()
            if v == "__done__" then
                menu:reload(build_items())
                return
            end
            local path = v:match("^toggle:(.+)$")
            if path then
                local c = canon(path)
                local found
                for i, p in ipairs(pre.members) do
                    if canon(p) == c then found = i; break end
                end
                if found then table.remove(pre.members, found)
                else pre.members[#pre.members + 1] = path end
                save_shaders()
                -- re-open the editor so the user can keep toggling members
                edit_members(menu, pre)
            end
        end) end,
    }
end

-- The "＋ New preset…" flow: name it, create it empty, then edit its members.
new_preset = function(menu)
    menu:ask_text{
        prompt = "Preset name",
        on_submit = function(t)
            if not t or t == "" then return end
            local pre = { name = t, members = {} }
            presets[#presets + 1] = pre
            save_shaders()
            menu:reload(build_items())
            defer(function() edit_members(menu, pre) end)
        end }
end

-- The per-preset action chooser (Enter on a preset row).
preset_actions = function(menu, pre)
    local active = preset_active(pre)
    menu:choose{
        title = "Preset: " .. pre.name,
        options = {
            { label = active and "Turn off now" or "Turn on now", value = "toggle" },
            { label = "Assign a key…", value = "key" },
            { label = "Edit members…", value = "members" },
            { label = "Rename…", value = "rename" },
            { label = "Remove", value = "remove" },
        },
        on_pick = function(v) defer(function()
            if v == "toggle" then
                toggle_preset(pre); menu:refresh()
            elseif v == "key" then
                menu:ask_text{
                    prompt = "Key for preset “" .. pre.name .. "” (e.g. Ctrl+a)",
                    default = pre.key,
                    on_submit = function(k)
                        if k and k ~= "" then
                            warn_key_conflict(k, pre)
                            pre.key = k
                        else
                            pre.key = nil
                        end
                        save_shaders(); register_keys(); menu:reload(build_items())
                    end }
            elseif v == "members" then
                edit_members(menu, pre)
            elseif v == "rename" then
                menu:ask_text{ prompt = "Preset name", default = pre.name,
                    on_submit = function(t)
                        if t and t ~= "" then pre.name = t end
                        save_shaders(); menu:reload(build_items())
                    end }
            elseif v == "remove" then
                for i, p in ipairs(presets) do if p == pre then table.remove(presets, i); break end end
                save_shaders(); register_keys(); menu:reload(build_items())
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
            if not file_exists(it.ref.path) then return "missing · " .. mode_label(it.ref) end
            return (is_active(it.ref.path) and "on" or "off") .. " · " .. mode_label(it.ref)
        elseif it.kind == "preset" then
            return preset_value(it.ref)
        elseif it.kind == "ext" then
            local e = it.entry
            if e.key then return "key: " .. e.key .. " · input.conf" end
            return (is_active(e.path) and "on" or "off") .. " · mpv.conf"
        end
        return nil
    end,

    marker_of = function(_, it)
        if it.kind == "shader" then
            if not file_exists(it.ref.path) then return "⚠" end
            if is_active(it.ref.path) then return "●" end
        end
        if it.kind == "preset" and preset_active(it.ref) then return "●" end
        -- only always-on preconfigured shaders are currently active
        if it.kind == "ext" and not it.entry.key and is_active(it.entry.path) then return "●" end
        return ""
    end,

    detail = function(_, it)
        if it.kind == "shader" then
            local sh = it.ref
            local missing = not file_exists(sh.path)
            local status = missing and "MISSING (file not found)"
                or (is_active(sh.path) and "ON" or "off")
            local b = {
                { t = "title", text = sh.name },
                { t = "sub", text = sh.path },
                { t = "gap" },
                { t = "text", text = "Status:  " .. status },
                { t = "text", text = "Runs:    " .. mode_label(sh) },
            }
            if sh.opts and #sh.opts > 0 then
                b[#b + 1] = { t = "text", text = "Options: " .. table.concat(sh.opts, ", ") }
            end
            b[#b + 1] = { t = "gap" }
            if missing then
                b[#b + 1] = { t = "text",
                    text = "This shader file no longer exists on disk. It won't be applied; "
                        .. "Enter to remove it, or restore the file.", c = "dim" }
            else
                b[#b + 1] = { t = "text",
                    text = "Enter to toggle it now, change how it runs, set options, "
                        .. "reorder, rename or remove it.", c = "dim" }
            end
            if not vo_supports_shaders() then
                b[#b + 1] = { t = "gap" }
                b[#b + 1] = { t = "text",
                    text = "Note: your video output is " .. tostring(mp.get_property("current-vo"))
                        .. "; shaders need vo=gpu or gpu-next.", c = "faint" }
            end
            return b
        elseif it.kind == "preset" then
            local pre = it.ref
            local b = {
                { t = "title", text = pre.name },
                { t = "gap" },
                { t = "text", text = "Status:  " .. (preset_active(pre) and "ON (all members on)" or "off") },
            }
            if pre.key and pre.key ~= "" then
                b[#b + 1] = { t = "text", text = "Key:     " .. pre.key }
            end
            b[#b + 1] = { t = "gap" }
            b[#b + 1] = { t = "text", text = "Members (apply order):", c = "dim" }
            if #pre.members == 0 then
                b[#b + 1] = { t = "text", text = "(none yet — use Edit members…)", c = "faint" }
            else
                for i, p in ipairs(pre.members) do
                    local name = basename(p)
                    for _, sh in ipairs(shaders) do
                        if canon(sh.path) == canon(p) then name = sh.name; break end
                    end
                    local miss = file_exists(p) and "" or "  ⚠ missing"
                    b[#b + 1] = { t = "text", text = "  " .. i .. ". " .. name .. miss, c = "dim" }
                end
            end
            b[#b + 1] = { t = "gap" }
            b[#b + 1] = { t = "text",
                text = "Enter to toggle the whole group, assign a key, edit members, "
                    .. "rename or remove it.", c = "dim" }
            return b
        elseif it.kind == "prune" then
            return {
                { t = "title", text = "Prune missing shaders" },
                { t = "gap" },
                { t = "text", text = "Remove every managed shader whose file no longer exists "
                    .. "on disk. Presets are not changed." },
            }
        elseif it.kind == "newpreset" then
            return {
                { t = "title", text = "New preset" },
                { t = "gap" },
                { t = "text", text = "Create a named group of shaders that toggle together "
                    .. "(e.g. a multi-pass upscaling mode). You'll pick its members next." },
            }
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
        elseif it.kind == "ext" then
            local e = it.entry
            local where = e.key and ("input.conf, bound to " .. e.key)
                or "mpv.conf (always on)"
            local how = e.key
                and ("Enter to import it as a " .. e.key .. " toggle — the binding moves out "
                    .. "of input.conf and Encore takes it over.")
                or "Enter to import it (always-on) — it moves out of mpv.conf into Encore."
            return {
                { t = "title", text = it.name },
                { t = "sub", text = e.path },
                { t = "gap" },
                { t = "text", text = "Set in your " .. where .. "." },
                { t = "gap" },
                { t = "text", text = how, c = "dim" },
            }
        elseif it.kind == "importall" then
            return {
                { t = "title", text = "Import all" },
                { t = "gap" },
                { t = "text", text = "Move every preconfigured shader into Encore — always-on ones "
                    .. "out of mpv.conf, toggle-key ones out of input.conf — so Encore manages them." },
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
        elseif it.kind == "preset" then
            preset_actions(menu, it.ref)
        elseif it.kind == "newpreset" then
            defer(function() new_preset(menu) end)
        elseif it.kind == "prune" then
            defer(function() prune_missing(menu) end)
        elseif it.kind == "add" then
            add_flow(menu)
        elseif it.kind == "browse" then
            defer(function() add_shader(menu, it.path) end)
        elseif it.kind == "ext" then
            local e = it.entry
            menu:choose{
                title = "Preconfigured: " .. it.name,
                options = {
                    { label = "Import to Encore", value = "import" },
                    { label = "Toggle now", value = "toggle" },
                },
                on_pick = function(v) defer(function()
                    if v == "import" then
                        if import_one(e) then
                            mp.osd_message("Imported " .. it.name .. " into Encore.", 2)
                        else
                            mp.osd_message("Couldn't import " .. it.name
                                .. " — it may be set inside a profile.", 4)
                        end
                        menu:reload(build_items())
                    else
                        toggle(e.path); menu:refresh()
                    end
                end) end,
            }
        elseif it.kind == "importall" then
            defer(function()
                local list = {}
                for _, p in ipairs(preconfigured) do list[#list + 1] = p end
                local ok = 0
                for _, p in ipairs(list) do if import_one(p) then ok = ok + 1 end end
                mp.osd_message("Imported " .. ok .. " of " .. #list .. " from mpv.conf.", 3)
                menu:reload(build_items())
            end)
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

-- On startup: detect shaders the user preconfigured in mpv.conf / input.conf (and
-- not yet managed) BEFORE we apply our own, so they can be offered for import;
-- then apply the always-on shaders and bind the key ones.
load_shaders()
detect_preconfigured()
for _, sh in ipairs(shaders) do
    -- Skip always-on shaders whose file is gone: applying a missing path just
    -- spams mpv errors. It stays listed (flagged "missing") so the user can fix
    -- or prune it.
    if sh.mode == "always" and file_exists(sh.path) then ensure_on(sh.path) end
end
register_keys()
