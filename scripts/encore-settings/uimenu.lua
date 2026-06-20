-- uimenu.lua — a custom ASS-drawn settings menu.
--
-- The built-in mp.input.select menu can't show a per-item description or update
-- it as the selection moves, and its type-to-filter only covers the current
-- list. This module draws its own OSD menu so it can provide what mpv.net's GUI
-- did: a live help/description panel (tooltips), type-anywhere global search,
-- and proper back navigation through the category tree.
--
-- Layout is master–detail:
--   * left pane  = the category tree ONLY (expand/collapse sub-categories);
--   * right-top  = the selected category's direct settings (name = value);
--   * right-bot  = the live help/description for the focused setting.
-- Focus is either the tree (left) or the settings list (right); the active pane
-- gets the bright accent selection bar, the inactive one a dim outline.
--
-- It still uses mp.input.get for free-text value entry (which needs a real text
-- cursor); everything else is handled here with forced key bindings.

local assdraw = require "mp.assdraw"
local input = require "mp.input"

local M = {}

-- Package version, shown in the menu header alongside the mpv version.
local ENCORE_VERSION = "1.1.2"

-- mpv's version string with the trailing git hash dropped, e.g.
-- "mpv v0.41.0-dev-g2d5dfb343" -> "mpv v0.41.0-dev".
local function mpv_version()
    return (mp.get_property("mpv-version", "mpv"):gsub("%-g%x+.*$", ""))
end

-- Open a URL in the system browser. Uses a detached subprocess with each
-- platform's canonical "open this in the default handler" launcher — on Windows
-- rundll32's FileProtocolHandler, which is reliable for http(s) URLs (the `run`
-- command + cmd's `start` proved flaky here).
local function open_url(url)
    local platform = mp.get_property_native("platform")
    local args
    if platform == "windows" then
        args = { "rundll32.exe", "url.dll,FileProtocolHandler", url }
    elseif platform == "darwin" then
        args = { "open", url }
    else
        args = { "xdg-open", url }
    end
    mp.msg.verbose("opening url: " .. url)
    mp.command_native({
        name = "subprocess",
        args = args,
        playback_only = false,
        detach = true,
    })
end

-- ---------------------------------------------------------------------------
-- Category tree
-- ---------------------------------------------------------------------------

local function build_tree(settings)
    local root = { name = "", path = "", children = {}, order = {}, settings = {},
                   depth = -1, expanded = true }
    for _, s in ipairs(settings) do
        local node = root
        local path = ""
        local depth = 0
        for part in (s.directory or ""):gmatch("[^/]+") do
            path = path == "" and part or (path .. "/" .. part)
            if not node.children[part] then
                local child = { name = part, path = path, children = {}, order = {},
                                settings = {}, depth = depth, expanded = false,
                                parent = node }
                node.children[part] = child
                node.order[#node.order + 1] = part
            end
            node = node.children[part]
            depth = depth + 1
        end
        node.settings[#node.settings + 1] = s
    end
    return root
end

-- ---------------------------------------------------------------------------
-- Menu state
-- ---------------------------------------------------------------------------

local Menu = {}
Menu.__index = Menu

local VISIBLE_ROWS = 16

function M.open(settings, on_change)
    local self = setmetatable({}, Menu)
    self.settings = settings
    self.tree = build_tree(settings)
    self.on_change = on_change or function() end
    -- name -> setting, for resolving `depends` (conditional visibility)
    self.by_name = {}
    for _, s in ipairs(settings) do self.by_name[s.name] = s end
    -- Friendlier default: expand the top level of categories so the user sees
    -- the major sections at a glance (their sub-categories stay collapsed).
    for _, name in ipairs(self.tree.order) do
        self.tree.children[name].expanded = true
    end
    self.query = ""
    self.focus = "tree"              -- "tree" | "list"
    self.mode = "browse"             -- "browse" | "options" | "search"
    self.option_setting = nil

    -- two independent scroll/selection cursors
    self.tree_sel = 1
    self.tree_scroll = 0
    self.list_sel = 1
    self.list_scroll = 0
    self.help_scroll = 0             -- scroll offset for the help/description pane
    self._help_for = nil             -- setting the help_scroll currently applies to

    self.overlay = mp.create_osd_overlay("ass-events")
    self.closed = false
    self:bind_keys()
    self:rebuild_tree()
    self:rebuild_list()
    self:render()
    return self
end

-- ---------------------------------------------------------------------------
-- Row labels / formatting
-- ---------------------------------------------------------------------------

local function changed(s) return (s.value or "") ~= (s.start_value or "") end
local function non_default(s) return (s.value or "") ~= (s.default or "") end

local function value_of(s)
    local v = s.value
    if v == nil or v == "" then return "(unset)" end
    return v
end

-- Words that should render as acronyms / special cases rather than Title-Case.
local ACRONYM = {
    gpu = "GPU", hdr = "HDR", sdr = "SDR", vo = "VO", ao = "AO", api = "API",
    osd = "OSD", osc = "OSC", fps = "FPS", rgb = "RGB", yuv = "YUV", icc = "ICC",
    lut = "LUT", lut3d = "LUT3D", csp = "CSP", ar = "AR", uhd = "UHD", id = "ID",
    url = "URL", png = "PNG", jpeg = "JPEG", jpg = "JPG", hwdec = "HWDEC",
    dxva2 = "DXVA2", d3d11va = "D3D11VA", vaapi = "VAAPI", vdpau = "VDPAU",
    cuda = "CUDA", nvdec = "NVDEC", pq = "PQ", hlg = "HLG", av1 = "AV1",
    hevc = "HEVC", ["3d"] = "3D", ["2d"] = "2D", ictcp = "ICtCp", ipt = "IPT",
    -- a couple of friendlier expansions
    exts = "Extensions",
}

-- Turn a raw option name into a friendly display label: split on dashes /
-- underscores, map known acronyms, Title-Case the rest ("hdr-compute-peak" ->
-- "HDR Compute Peak", "video-sync" -> "Video Sync"). Display only — the real
-- s.name is kept untouched for matching/saving/applying.
local function prettify(name)
    local out = {}
    for word in tostring(name):gmatch("[^%-_]+") do
        local lw = word:lower()
        if ACRONYM[lw] then
            out[#out + 1] = ACRONYM[lw]
        else
            out[#out + 1] = word:sub(1, 1):upper() .. word:sub(2)
        end
    end
    return table.concat(out, " ")
end

-- The little status glyph shown to the left of a setting row.
--   *  modified this session   ●  differs from default   (blank otherwise)
local function setting_marker(s)
    if changed(s) then return "*" end
    if non_default(s) then return "●" end
    return ""
end

-- ---------------------------------------------------------------------------
-- Row list construction
-- ---------------------------------------------------------------------------

-- Walk the tree depth-first, emitting one row per category node (settings are
-- NOT shown here — they live in the right pane).
function Menu:flatten_tree(node, rows)
    for _, name in ipairs(node.order) do
        local child = node.children[name]
        rows[#rows + 1] = {
            ref = child, depth = child.depth, label = name,
            expandable = #child.order > 0,
            has_settings = #child.settings > 0,
        }
        if child.expanded then
            self:flatten_tree(child, rows)
        end
    end
end

-- Build self.tree_rows from the current expand/collapse state.
function Menu:rebuild_tree()
    local rows = {}
    self:flatten_tree(self.tree, rows)
    self.tree_rows = rows
    if self.tree_sel > #rows then self.tree_sel = #rows end
    if self.tree_sel < 1 then self.tree_sel = 1 end
end

-- The node currently highlighted in the tree.
function Menu:current_node()
    local row = self.tree_rows[self.tree_sel]
    return row and row.ref or nil
end

local function truthy(v)
    v = (tostring(v or "")):lower()
    return v == "yes" or v == "true" or v == "1"
end

-- A setting may declare `depends = <other setting name>`; it is only shown while
-- that other setting is currently truthy. Used for master/sub toggles, e.g. the
-- per-option remember-* toggles depend on the remember-state master.
function Menu:visible(s)
    if not s.depends then return true end
    local dep = self.by_name[s.depends]
    if not dep then return true end          -- unknown dependency: don't hide
    return truthy(dep.value or dep.default)
end

-- Build self.list_rows: depends on mode.
--   options : the option choices for the setting being edited
--   search  : flat matches across ALL settings (each tagged with its category)
--   browse  : the direct settings of the currently-selected tree node
-- `keep_sel` preserves list_sel where sensible; otherwise it resets to 1.
function Menu:rebuild_list(keep_sel)
    local rows = {}

    if self.mode == "options" then
        local s = self.option_setting
        for _, opt in ipairs(s.options) do
            local sel = (opt.name == s.value)
            rows[#rows + 1] = { kind = "option", label = opt.text or opt.name,
                                ref = opt, hint = opt.help, dot = sel }
        end
    elseif self.query ~= "" then
        local q = self.query:lower()
        for _, s in ipairs(self.settings) do
            local hay = (s.name .. " " .. (s.directory or "") .. " " .. (s.help or "")):lower()
            if self:visible(s) and hay:find(q, 1, true) then
                rows[#rows + 1] = { kind = "setting", ref = s,
                    marker = setting_marker(s), hint = s.directory or "" }
            end
        end
    else
        local node = self:current_node()
        if node then
            for _, s in ipairs(node.settings) do
                if self:visible(s) then
                    rows[#rows + 1] = { kind = "setting", ref = s,
                        marker = setting_marker(s) }
                end
            end
        end
    end

    self.list_rows = rows
    if not keep_sel then self.list_sel = 1 end
    if self.list_sel > #rows then self.list_sel = #rows end
    if self.list_sel < 1 then self.list_sel = 1 end
end

-- Generic scroll clamp for a list of length `total` given a cursor `sel`,
-- current `scroll`, and visible window `vis`. Returns the new scroll offset.
local function clamp_scroll(sel, scroll, vis, total)
    if sel > scroll + vis then scroll = sel - vis end
    if sel <= scroll then scroll = sel - 1 end
    if scroll < 0 then scroll = 0 end
    if total <= vis then scroll = 0 end
    return scroll
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function ass_escape(s)
    -- neutralise ASS control characters and collapse newlines to spaces
    return (tostring(s):gsub("\\", "/"):gsub("[{}]", ""):gsub("[\r\n]+", " "))
end

-- word-wrap plain text to a column width, returning ASS with \N breaks
local function wrap(text, width)
    text = tostring(text):gsub("\r", "")
    local out = {}
    for paragraph in (text .. "\n"):gmatch("(.-)\n") do
        local line = ""
        for word in paragraph:gmatch("%S+") do
            if #line + #word + 1 > width then
                out[#out + 1] = line
                line = word
            else
                line = line == "" and word or (line .. " " .. word)
            end
        end
        out[#out + 1] = line
    end
    return table.concat(out, "\\N")
end

-- The setting whose help should be shown in the bottom-right pane.
function Menu:focused_setting()
    if self.mode == "options" then return self.option_setting end
    local row = self.list_rows[self.list_sel]
    if row and row.kind == "setting" then return row.ref end
    return nil
end

-- Colours are ASS BGR (&HBBGGRR&). Tuned to match mpv's native (Windows 11)
-- context menu: flat dark-grey panels, white text, a neutral grey hover/
-- selection bar, and a single restrained blue accent reserved for state (the
-- "modified" marker) — no warm tint.
local C_PANEL   = "&H2B2B2B&"   -- panel fill (#2B2B2B)
local C_RIGHT   = "&H2F2F2F&"   -- slightly lighter detail-pane fill (#2F2F2F)
local C_TEXT    = "&HF5F5F5&"   -- near-white body text
local C_DIM     = "&H9D9D9D&"   -- secondary text (shortcuts / values)
local C_FAINT   = "&H6E6E6E&"   -- tertiary / placeholder / disabled
local C_ACCENT  = "&HC8C8C8&"   -- neutral "accent": arrows, dots, titles (light grey)
local C_NODE    = "&HD0D0D0&"   -- category text
local C_SELTXT  = "&HFFFFFF&"   -- text on the selection bar (white on grey)
local C_SELBG   = "&H454545&"   -- selection / hover bar fill (neutral grey)
local C_DIVIDER = "&H3A3A3A&"   -- subtle divider line
local C_MODIFIED = "&HFFCD60&"  -- "*" modified marker (Windows accent blue #60CDFF)
local C_LINK    = "&HFFCD60&"   -- clickable URL (blue, underlined)
local C_FOOT    = "&HB0B0B0&"   -- footer status-bar text
-- tree hierarchy tiers
local C_TOPHEAD  = "&HFFFFFF&"  -- top-level category text (bright white, bold)
local C_SUBHEAD  = "&HD0D0D0&"  -- sub-category text (light grey, bold)
local C_SETNAME  = "&HE0E0E0&"  -- setting name
local C_SETVAL   = "&H9D9D9D&"  -- setting value (dimmer)

-- Truncate a plain string to at most `n` characters, appending an ellipsis.
local function truncate(s, n)
    s = tostring(s)
    if #s <= n then return s end
    if n <= 1 then return "…" end
    return s:sub(1, n - 1) .. "…"
end

-- Breadcrumb for the selected category, e.g. "Video › libplacebo › Debanding".
local function node_breadcrumb(node)
    local parts = {}
    local n = node
    while n and n.path ~= "" do
        table.insert(parts, 1, n.name)
        n = n.parent
    end
    return table.concat(parts, " › ")
end

function Menu:render()
    local osd_w, osd_h = mp.get_osd_size()
    if not osd_h or osd_h == 0 then osd_h = 720; osd_w = 1280 end

    local function I(v) return math.floor(v + 0.5) end

    -- overall panel box
    local boxL = I(osd_w * 0.05)
    local boxR = I(osd_w * 0.95)
    local boxT = I(osd_h * 0.06)
    local boxB = I(osd_h * 0.94)
    local pad  = I(osd_h * 0.03)

    local fs       = I(osd_h / 32)        -- list rows
    local title_fs = I(osd_h / 22)        -- header
    local help_fs  = I(osd_h / 34)        -- description text
    local foot_fs  = I(osd_h / 44)
    local rowH     = I(fs * 1.5)
    -- approximate average glyph width for truncation maths
    local glyphW   = fs * 0.52

    -- columns: left = tree, right = list (top) + help (bottom)
    local divX   = I(boxL + (boxR - boxL) * 0.40)
    local treeX  = boxL + pad
    local treeW  = divX - treeX - I(pad * 0.5)
    local rightX = divX + pad
    local rightW = boxR - pad - rightX

    -- vertical layout (shared header rows)
    local titleY  = boxT + pad
    local searchY = titleY + I(title_fs * 1.55)
    local bodyTop = searchY + I(fs * 2.1)
    local footY   = boxB - pad - foot_fs
    local bodyBot = footY - I(foot_fs * 0.8)

    -- the tree spans the whole body height on the left
    local treeTop = bodyTop
    local treeBot = bodyBot

    -- the right pane is split: settings list on top, help on the bottom. Give
    -- the list only as much height as it needs, so short categories leave plenty
    -- of room for the description; cap it so long lists still scroll.
    local bodyH = bodyBot - bodyTop
    local nList = #self.list_rows
    local listCap  = I(bodyH * 0.52)
    local listMin  = I(bodyH * 0.26)
    local listWant = nList * rowH + I(rowH * 0.3)
    local listH    = math.max(listMin, math.min(listWant, listCap))
    local listTop = bodyTop
    local listBot = bodyTop + listH
    local helpTop = listBot + I(pad * 0.7)
    local helpBot = bodyBot

    -- visible-row windows for each pane (independent)
    self.tree_visible = math.max(1, math.floor((treeBot - treeTop) / rowH))
    self.list_visible = math.max(1, math.floor((listBot - listTop) / rowH))

    -- clamp both scrolls now that we know the visible window sizes
    self.tree_scroll = clamp_scroll(self.tree_sel, self.tree_scroll,
        self.tree_visible, #self.tree_rows)
    self.list_scroll = clamp_scroll(self.list_sel, self.list_scroll,
        self.list_visible, #self.list_rows)

    local a = assdraw.ass_new()

    local function box(x0, y0, x1, y1, colour, alpha)
        a:new_event()
        a:pos(0, 0)
        a:append(string.format("{\\bord0\\shad0\\1c%s\\1a%s}", colour, alpha or "&H00&"))
        a:draw_start()
        a:rect_cw(I(x0), I(y0), I(x1), I(y1))
        a:draw_stop()
    end

    -- an outlined (hollow) rectangle, used for the inactive-pane cursor
    local function outline(x0, y0, x1, y1, colour, alpha, th)
        th = th or I(osd_h * 0.003)
        box(x0, y0, x1, y0 + th, colour, alpha)
        box(x0, y1 - th, x1, y1, colour, alpha)
        box(x0, y0, x0 + th, y1, colour, alpha)
        box(x1 - th, y0, x1, y1, colour, alpha)
    end

    -- the footer status bar occupies the band below bodyBot; the panes and the
    -- vertical divider stop above it so the footer reads as one clean strip.
    local footSepY = bodyBot + I(foot_fs * 0.5)

    -- 1) background panel (left + right tinted differently) with subtle shadow.
    -- Near-opaque so it reads as a solid native menu surface rather than a HUD.
    box(boxL + 3, boxT + 3, boxR + 3, boxB + 3, "&H000000&", "&H50&")  -- drop shadow
    box(boxL, boxT, boxR, boxB, C_PANEL, "&H0A&")
    box(divX, boxT, boxR, footSepY, C_RIGHT, "&H0A&")
    -- thin native-style hairline border around the whole panel
    outline(boxL, boxT, boxR, boxB, C_DIVIDER, "&H10&")

    -- 2) header underline + vertical divider + right horizontal split + footer rule
    box(treeX, searchY - I(fs * 0.7), boxR - pad, searchY - I(fs * 0.7) + I(osd_h * 0.0025),
        C_DIVIDER, "&H30&")
    box(divX, boxT, divX + I(osd_h * 0.002), footSepY, C_DIVIDER, "&H30&")
    local splitY = I((listBot + helpTop) / 2)
    box(rightX, splitY, boxR - pad, splitY + I(osd_h * 0.002), C_DIVIDER, "&H30&")
    box(boxL + pad, footSepY, boxR - pad, footSepY + I(osd_h * 0.0025), C_DIVIDER, "&H30&")

    local tree_active = (self.focus == "tree")
    local list_active = (self.focus == "list") or (self.mode == "options")

    -- =====================================================================
    -- LEFT PANE — category tree
    -- =====================================================================
    local tTotal = #self.tree_rows
    local tFrom = self.tree_scroll + 1
    local tTo = math.min(self.tree_scroll + self.tree_visible, tTotal)

    -- selection / cursor bar for the tree
    if tTotal > 0 and self.tree_sel >= tFrom and self.tree_sel <= tTo then
        local j = self.tree_sel - tFrom
        local y = treeTop + j * rowH
        local x0 = boxL + I(pad * 0.4)
        local x1 = divX - I(pad * 0.4)
        local y1 = y + rowH - I(fs * 0.18)
        if tree_active then
            box(x0, y, x1, y1, C_SELBG, "&H0A&")
        else
            outline(x0, y, x1, y1, C_ACCENT, "&H66&")
        end
    end

    for i = tFrom, tTo do
        local row = self.tree_rows[i]
        local y = treeTop + (i - tFrom) * rowH + I(rowH / 2)
        local sel = (i == self.tree_sel)
        local top = (row.depth or 0) == 0
        local indent = I((row.depth or 0) * fs * 0.95)
        local x = treeX + I(pad * 0.4) + I(fs * 0.4) + indent
        local avail = math.max(6, math.floor((divX - I(pad * 0.6) - x) / glyphW))

        local on_bar = sel and tree_active
        local marker = row.expandable and (row.ref.expanded and "▾" or "▸") or "·"
        local mcol = on_bar and C_SELTXT or C_ACCENT
        local ncol = on_bar and C_SELTXT or (top and C_TOPHEAD or C_SUBHEAD)
        local label = truncate(row.label, avail - 2)
        local sztag = top and ("\\fs" .. I(fs * 1.06)) or ""

        a:new_event()
        a:append(string.format("{\\an4\\pos(%d,%d)\\fs%d\\bord0\\shad0\\q2}", x, y, fs))
        a:append(string.format("{\\1c%s}%s {\\1c%s\\b1%s}%s{\\b0}",
            mcol, marker, ncol, sztag, ass_escape(label)))
    end

    -- tree scroll indicators
    if tFrom > 1 then
        a:new_event()
        a:append(string.format("{\\an6\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s}▲ %d",
            divX - I(pad * 0.5), treeTop - I(fs * 0.2), foot_fs, C_FAINT, tFrom - 1))
    end
    if tTotal > tTo then
        a:new_event()
        a:append(string.format("{\\an9\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s}▼ %d more",
            divX - I(pad * 0.5), treeBot - I(foot_fs * 1.1), foot_fs, C_DIM, tTotal - tTo))
    end

    -- =====================================================================
    -- RIGHT-TOP PANE — settings list (or search results / option choices)
    -- =====================================================================
    local lTotal = #self.list_rows
    local lFrom = self.list_scroll + 1
    local lTo = math.min(self.list_scroll + self.list_visible, lTotal)

    -- right list label / breadcrumb
    local listTitle
    if self.mode == "options" then
        listTitle = "Choose: " .. prettify(self.option_setting.name)
    elseif self.query ~= "" then
        listTitle = string.format("Search results (%d)", lTotal)
    else
        local node = self:current_node()
        listTitle = node and node_breadcrumb(node) or "Settings"
    end
    a:new_event()
    a:append(string.format("{\\an7\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s\\b1}%s{\\b0}",
        rightX, listTop - I(fs * 1.35), help_fs, C_ACCENT,
        ass_escape(truncate(listTitle, math.floor(rightW / (help_fs * 0.52))))))

    -- selection / cursor bar for the list
    if lTotal > 0 and self.list_sel >= lFrom and self.list_sel <= lTo then
        local j = self.list_sel - lFrom
        local y = listTop + j * rowH
        local x0 = rightX - I(pad * 0.2)
        local x1 = boxR - pad + I(pad * 0.2)
        local y1 = y + rowH - I(fs * 0.18)
        if list_active then
            box(x0, y, x1, y1, C_SELBG, "&H0A&")
        else
            outline(x0, y, x1, y1, C_ACCENT, "&H66&")
        end
    end

    if lTotal == 0 then
        a:new_event()
        local msg = self.query ~= "" and ("No settings match “" .. self.query .. "”.")
            or "This category has no direct settings."
        a:append(string.format("{\\an7\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s}%s",
            rightX, listTop + I(rowH * 0.4), fs, C_DIM, ass_escape(msg)))
    end

    for i = lFrom, lTo do
        local row = self.list_rows[i]
        local y = listTop + (i - lFrom) * rowH + I(rowH / 2)
        local sel = (i == self.list_sel)
        local on_bar = sel and list_active
        local x = rightX + I(fs * 0.4)
        local maincol = on_bar and C_SELTXT or C_TEXT
        local avail = math.max(6, math.floor((boxR - pad - I(fs * 0.4) - x) / glyphW))

        a:new_event()
        a:append(string.format("{\\an4\\pos(%d,%d)\\fs%d\\bord0\\shad0\\q2}", x, y, fs))

        if row.kind == "option" then
            local dot = row.dot and "● " or "   "
            local dcol = on_bar and C_SELTXT or C_ACCENT
            a:append(string.format("{\\1c%s}%s{\\1c%s}%s",
                dcol, dot, maincol, ass_escape(truncate(row.label, avail - 3))))
        else -- setting: marker + "name = value"
            local mk = row.marker or ""
            local mcol = on_bar and C_SELTXT
                or (mk == "*" and C_MODIFIED or (mk == "●" and C_ACCENT or C_DIM))
            local s = row.ref
            local nm = prettify(s.name)
            local val = value_of(s)
            -- reserve room for the search category hint if present
            local hintLen = (row.hint and row.hint ~= "") and (math.min(#row.hint, 22) + 3) or 0
            local budget = avail - 2 - hintLen
            local nmShown = nm
            if #nm + 3 + #val > budget then
                local valBudget = math.max(6, math.floor((budget - #nm - 3)))
                if valBudget < 8 then
                    nmShown = truncate(nm, budget - 6)
                    valBudget = math.max(4, budget - #nmShown - 3)
                end
                val = truncate(val, valBudget)
            end
            local mkText = (mk ~= "") and (mk .. " ") or "  "
            local nmcol = on_bar and C_SELTXT or C_SETNAME
            local valcol = on_bar and C_SELTXT or C_SETVAL
            a:append(string.format("{\\1c%s}%s{\\1c%s}%s {\\1c%s}= {\\1c%s}%s",
                mcol, mkText, nmcol, ass_escape(nmShown),
                on_bar and C_SELTXT or C_FAINT, valcol, ass_escape(val)))

            if row.hint and row.hint ~= "" then
                a:append(string.format("   {\\fs%d\\1c%s}[%s]",
                    I(fs * 0.78), on_bar and C_SELTXT or C_FAINT,
                    ass_escape(truncate(row.hint, 22))))
            end
        end
    end

    -- list scroll indicators
    if lFrom > 1 then
        a:new_event()
        a:append(string.format("{\\an6\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s}▲ %d",
            boxR - pad, listTop - I(fs * 0.2), foot_fs, C_FAINT, lFrom - 1))
    end
    if lTotal > lTo then
        a:new_event()
        a:append(string.format("{\\an9\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s}▼ %d more",
            boxR - pad, listBot - I(foot_fs * 1.1), foot_fs, C_DIM, lTotal - lTo))
    end

    -- =====================================================================
    -- HEADER — title + search box
    -- =====================================================================
    a:new_event()
    a:append(string.format("{\\an7\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s\\b1}Encore{\\b0}"
        .. "{\\fs%d\\1c%s}  settings", treeX, titleY, title_fs, C_TEXT,
        I(title_fs * 0.72), C_DIM))

    -- version line, right-aligned in the header: Encore + mpv versions
    a:new_event()
    a:append(string.format("{\\an6\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s}Encore v%s   ·   %s",
        boxR - pad, titleY + I(title_fs * 0.5), foot_fs, C_DIM,
        ENCORE_VERSION, ass_escape(mpv_version())))

    a:new_event()
    if self.query ~= "" then
        a:append(string.format("{\\an7\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s}Search:  {\\1c%s}%s{\\1c%s}▌",
            treeX, searchY, fs, C_DIM, C_TEXT,
            ass_escape(truncate(self.query, math.floor(treeW / glyphW) - 9)), C_ACCENT))
    else
        a:append(string.format("{\\an7\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s}Search:  {\\1c%s}type to filter all settings…",
            treeX, searchY, fs, C_DIM, C_FAINT))
    end

    -- =====================================================================
    -- RIGHT-BOTTOM PANE — help / description for the focused setting
    -- =====================================================================
    self:render_detail(a, rightX, helpTop, rightW, helpBot, title_fs, help_fs, fs)

    -- =====================================================================
    -- FOOTER — context-sensitive key hints
    -- =====================================================================
    local hint
    if self.mode == "options" then
        hint = "↑↓ move    Enter choose    ←/Esc cancel"
    elseif self.query ~= "" then
        hint = "↑↓ move    Enter edit    type to refine    Backspace clear    Esc close"
    elseif self.focus == "tree" then
        hint = "↑↓ category    →/Enter expand · enter settings    ← collapse · parent    type to search    Esc close"
    else
        hint = "↑↓ setting    Enter edit    ←/Esc back    type to search"
    end
    -- mention help scrolling when the description overflows its pane
    if (self.help_max_scroll or 0) > 0 and self.mode ~= "options" then
        hint = hint .. "    ⇧↑↓/wheel scroll help"
    end
    -- mention the manual link when the focused setting has one
    if self.url_value and self.mode ~= "options" then
        hint = hint .. "    Ctrl+O open link"
    end
    local footTextY = I((footSepY + (boxB - pad)) / 2)
    a:new_event()
    a:append(string.format("{\\an4\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s}%s",
        treeX + I(pad * 0.2), footTextY, foot_fs, C_FOOT, hint))

    -- Hit-test geometry for mouse support, recomputed each render. Each pane's
    -- visible rows occupy [top + (i-from)*rowH, +rowH] within [x0,x1].
    self.tree_hit  = { x0 = boxL + I(pad * 0.4), x1 = divX - I(pad * 0.4),
                       top = treeTop, rowH = rowH, from = tFrom, to = tTo }
    self.list_hit  = { x0 = rightX - I(pad * 0.2), x1 = boxR - pad + I(pad * 0.2),
                       top = listTop, rowH = rowH, from = lFrom, to = lTo }
    self.panel_rect = { x0 = boxL, y0 = boxT, x1 = boxR, y1 = boxB }

    -- Pin the ASS coordinate space to the OSD size we measured. Without this,
    -- under Windows display scaling get_osd_size() reports physical pixels while
    -- the overlay defaults to logical pixels, so every position is off by the
    -- scale factor (the menu spills off the right/bottom).
    self.overlay.res_x = osd_w
    self.overlay.res_y = osd_h
    self.overlay.data = a.text
    self.overlay:update()
end

-- Bottom-right pane: details/help for the focused setting.
function Menu:render_detail(a, x, top, w, bot, title_fs, help_fs, fs)
    local function I(v) return math.floor(v + 0.5) end
    local cols = math.max(16, math.floor(w / (help_fs * 0.52)))
    local paneH = bot - top

    local s = self:focused_setting()
    if not s then
        -- nothing focused (e.g. an empty category): show a gentle placeholder
        a:new_event()
        a:append(string.format("{\\an7\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s}%s",
            x, top, help_fs, C_FAINT,
            "Select a setting to see its description."))
        return
    end

    -- clickable-URL state, recomputed each render (see the render loop below)
    self.url_value = nil
    self.url_rect = nil

    -- collect the body as wrapped lines, then clip to the pane height
    local lines = {}
    local function add(text, colour, fontsz)
        for piece in (wrap(text, cols) .. "\\N"):gmatch("(.-)\\N") do
            lines[#lines + 1] = { text = piece, colour = colour, fs = fontsz }
        end
    end
    -- a wrapped link: tagged so it renders blue + underlined and is hit-tested
    local url_first, url_last
    local function add_link(text)
        url_first = #lines + 1
        for piece in (wrap(text, cols) .. "\\N"):gmatch("(.-)\\N") do
            lines[#lines + 1] = { text = piece, colour = C_LINK, fs = help_fs, link = true }
        end
        url_last = #lines
    end
    -- a small spacer (half a line) instead of a full blank line, so the
    -- description gets as many lines as possible
    local function gap() lines[#lines + 1] = { text = "", colour = C_DIM, fs = I(help_fs * 0.45) } end

    -- header: friendly name (bigger, accent) + the raw option name beneath it
    lines[#lines + 1] = { text = wrap(ass_escape(prettify(s.name)), cols), colour = C_ACCENT,
                          fs = title_fs, bold = true }
    lines[#lines + 1] = { text = ass_escape(s.name), colour = C_FAINT, fs = help_fs }
    gap()

    -- value
    add("value:  " .. ass_escape(value_of(s)), C_TEXT, help_fs)

    -- help
    if s.help and s.help ~= "" then
        gap()
        add(ass_escape(s.help):gsub("/n", " "), C_TEXT, help_fs)
    end
    gap()

    -- meta
    local meta = {}
    if s.default and s.default ~= "" then meta[#meta + 1] = "default: " .. s.default end
    if s.type and s.type ~= "" then meta[#meta + 1] = "type: " .. s.type end
    meta[#meta + 1] = "file: " .. (s.file or "?")
    add(ass_escape(table.concat(meta, "      ")), C_DIM, help_fs, false)

    if s.url and s.url ~= "" then
        self.url_value = s.url
        add_link(ass_escape(s.url))
    end

    -- Show the FULL description. If it overflows the pane, scroll it (mouse
    -- wheel over this pane, or Shift+Up/Down) rather than truncating. Reset the
    -- scroll whenever the focused setting changes so each starts at the top.
    if self._help_for ~= s then
        self._help_for = s
        self.help_scroll = 0
    end
    self.help_rect = { x0 = x, y0 = top, x1 = x + w, y1 = bot }

    local function line_h(fsz) return fsz * 1.28 end

    -- largest scroll offset that still fills the pane (can't scroll past the end)
    local function fits_from(startIdx)
        local used = 0
        for i = startIdx, #lines do
            used = used + line_h(lines[i].fs)
            if used > paneH then return false end
        end
        return true
    end
    local max_scroll = (#lines > 0) and (#lines - 1) or 0
    for off = 0, #lines - 1 do
        if fits_from(off + 1) then max_scroll = off; break end
    end
    self.help_max_scroll = max_scroll
    if self.help_scroll > max_scroll then self.help_scroll = max_scroll end
    if self.help_scroll < 0 then self.help_scroll = 0 end

    -- render the visible window starting from the scroll offset
    local startIdx = self.help_scroll + 1
    a:new_event()
    a:append(string.format("{\\an7\\pos(%d,%d)\\bord0\\shad0}", x, top))
    local used, lastIdx = 0, self.help_scroll
    for i = startIdx, #lines do
        local h = line_h(lines[i].fs)
        if used + h > paneH then break end
        local line_top = top + used
        used = used + h
        if i > startIdx then a:append("\\N") end
        a:append(string.format("{\\fs%d\\1c%s%s%s}%s",
            lines[i].fs, lines[i].colour,
            lines[i].bold and "\\b1" or "\\b0",
            lines[i].link and "\\u1" or "\\u0", lines[i].text))
        -- record the on-screen box of the URL line(s) so a click can open it
        if url_first and i >= url_first and i <= url_last then
            if not self.url_rect then
                self.url_rect = { x0 = x, y0 = line_top, x1 = x + w, y1 = line_top + h }
            else
                self.url_rect.y1 = line_top + h
            end
        end
        lastIdx = i
    end

    -- scroll indicators (only when there's hidden content in that direction)
    if self.help_scroll > 0 then
        a:new_event()
        a:append(string.format("{\\an9\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s}▲",
            x + w, top - I(help_fs * 0.1), I(help_fs * 0.85), C_ACCENT))
    end
    if lastIdx < #lines then
        a:new_event()
        a:append(string.format("{\\an3\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s}▼ scroll",
            x + w, bot, I(help_fs * 0.8), C_ACCENT))
    end
end

-- ---------------------------------------------------------------------------
-- Navigation — tree pane
-- ---------------------------------------------------------------------------

function Menu:tree_move(delta)
    if #self.tree_rows == 0 then return end
    self.tree_sel = self.tree_sel + delta
    if self.tree_sel < 1 then self.tree_sel = #self.tree_rows end
    if self.tree_sel > #self.tree_rows then self.tree_sel = 1 end
    -- moving the tree selection re-derives the right-hand settings list
    self:rebuild_list()
    self:render()
end

-- Re-point tree_sel at a given node by identity (keeps it visible after a
-- rebuild that may have changed row indices).
function Menu:select_node(node)
    for i, r in ipairs(self.tree_rows) do
        if r.ref == node then self.tree_sel = i; return true end
    end
    return false
end

function Menu:toggle_node(expand)
    local row = self.tree_rows[self.tree_sel]
    if not row or not row.expandable then return false end
    local node = row.ref
    if expand == nil then
        node.expanded = not node.expanded
    else
        node.expanded = expand
    end
    self:rebuild_tree()
    self:select_node(node)
    self:rebuild_list()
    self:render()
    return true
end

-- RIGHT / ENTER in the tree: expand a collapsed expandable node; otherwise
-- (already expanded, or it has direct settings) move focus into the list.
function Menu:tree_forward()
    local row = self.tree_rows[self.tree_sel]
    if not row then return end
    if row.expandable and not row.ref.expanded then
        self:toggle_node(true)
    else
        -- enter the settings list if there is anything to edit
        if #self.list_rows > 0 then
            self.focus = "list"
            self.list_sel = math.max(1, math.min(self.list_sel, #self.list_rows))
            self:render()
        elseif row.expandable then
            -- expanded but empty of direct settings: collapse/expand toggle is
            -- the only sensible action; do nothing else.
            self:render()
        end
    end
end

-- LEFT in the tree: collapse an expanded node; else jump to the parent.
function Menu:tree_back()
    local row = self.tree_rows[self.tree_sel]
    if not row then return end
    if row.expandable and row.ref.expanded then
        self:toggle_node(false)
    else
        local parent = row.ref.parent
        if parent and parent.path ~= "" then
            self:select_node(parent)
            self:rebuild_list()
            self:render()
        end
    end
end

-- ---------------------------------------------------------------------------
-- Navigation — list pane
-- ---------------------------------------------------------------------------

function Menu:list_move(delta)
    if #self.list_rows == 0 then return end
    self.list_sel = self.list_sel + delta
    if self.list_sel < 1 then self.list_sel = #self.list_rows end
    if self.list_sel > #self.list_rows then self.list_sel = 1 end
    self:render()
end

-- Return focus from the list to the tree (without closing the menu).
function Menu:list_back()
    self.focus = "tree"
    self:render()
end

-- ENTER in the list: edit a setting, choose an option.
function Menu:list_activate()
    local row = self.list_rows[self.list_sel]
    if not row then return end
    if row.kind == "option" then
        local s = self.option_setting
        s.value = row.ref.name
        self.on_change(s)
        self:exit_options(s)
    elseif row.kind == "setting" then
        self:edit(row.ref)
    end
end

-- ---------------------------------------------------------------------------
-- Editing
-- ---------------------------------------------------------------------------

function Menu:edit(s)
    self.return_setting = s
    if s.kind == "option" then
        self.mode = "options"
        self.option_setting = s
        self.focus = "list"
        self.saved_list_sel = self.list_sel        -- to restore on cancel
        self.list_sel = 1
        self.list_scroll = 0
        -- preselect the current value
        for i, opt in ipairs(s.options) do
            if opt.name == s.value then self.list_sel = i; break end
        end
        self:rebuild_list(true)
        self:render()
    else
        -- free-text value: hand off to the console input, hide our overlay
        self.overlay:remove()
        self:unbind_keys()
        local hint = s.type and (" [" .. s.type .. "]") or ""
        input.get({
            prompt = s.name .. hint .. ":",
            default_text = s.value or "",
            submit = function(text)
                s.value = text
                self.on_change(s)
                input.terminate()
            end,
            closed = function()
                -- resume the menu, keeping the edited setting focused
                self.overlay = mp.create_osd_overlay("ass-events")
                self:bind_keys()
                self:rebuild_list(true)
                self:select_list_setting(s)
                self:render()
            end,
        })
    end
end

-- Leave option-edit mode, restoring the browse/search list and re-focusing the
-- setting that was being edited.
function Menu:exit_options(focus_setting)
    self.mode = "browse"
    local s = focus_setting or self.option_setting
    self.option_setting = nil
    self.list_sel = self.saved_list_sel or 1
    self.list_scroll = 0
    self.focus = "list"
    self:rebuild_list(true)
    if s then self:select_list_setting(s) end
    self:render()
end

-- Point list_sel at the row holding a given setting (after a rebuild).
function Menu:select_list_setting(s)
    for i, r in ipairs(self.list_rows) do
        if r.kind == "setting" and r.ref == s then self.list_sel = i; return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------

function Menu:enter_search_if_needed()
    if self.query ~= "" then
        -- search results live in the right list and are edited there
        self.focus = "list"
        self.mode = "browse"
    end
end

function Menu:type_char(c)
    if self.mode == "options" then return end   -- typing doesn't filter choices
    self.query = self.query .. c
    self.list_sel = 1
    self.list_scroll = 0
    self:rebuild_list()
    self:enter_search_if_needed()
    self:render()
end

function Menu:backspace()
    if self.mode == "options" then return end
    if self.query ~= "" then
        self.query = self.query:sub(1, -2)
        self.list_sel = 1
        self.list_scroll = 0
        self:rebuild_list()
        if self.query == "" then
            -- back to normal browse: focus the tree again
            self.focus = "tree"
        end
        self:render()
    end
end

-- ---------------------------------------------------------------------------
-- Key dispatch (focus-aware)
-- ---------------------------------------------------------------------------

function Menu:on_down()
    if self.focus == "list" or self.mode == "options" then self:list_move(1)
    else self:tree_move(1) end
end
function Menu:on_up()
    if self.focus == "list" or self.mode == "options" then self:list_move(-1)
    else self:tree_move(-1) end
end
function Menu:on_page(delta)
    if self.focus == "list" or self.mode == "options" then
        self:list_move(delta * (self.list_visible or VISIBLE_ROWS))
    else
        self:tree_move(delta * (self.tree_visible or VISIBLE_ROWS))
    end
end

function Menu:on_enter()
    if self.focus == "list" or self.mode == "options" then self:list_activate()
    else self:tree_forward() end
end

-- Scroll the help/description pane by `delta` lines (clamped).
function Menu:help_scroll_by(delta)
    local maxs = self.help_max_scroll or 0
    local v = (self.help_scroll or 0) + delta
    if v < 0 then v = 0 end
    if v > maxs then v = maxs end
    if v ~= self.help_scroll then
        self.help_scroll = v
        self:render()
    end
end

-- Mouse wheel. Bound as a complex binding so each physical tick arrives with
-- its `scale`: mpv collapses rapid identical key-down events, so a plain binding
-- would register fast scrolling as a single step (or none). Fast scrolling sends
-- fewer events each carrying a larger scale, so we multiply the step count by it.
-- Scrolls the help pane if the cursor is over it, otherwise moves the focused
-- list/tree selection.
function Menu:on_wheel(dir, e)
    if e then
        local ev = e.event
        if ev ~= "down" and ev ~= "press" and ev ~= "repeat" then return end
    end
    local scale = (e and tonumber(e.scale)) or 1
    local steps = math.max(1, math.floor(scale + 0.5))
    local pos = mp.get_property_native("mouse-pos")
    local r = self.help_rect
    if pos and r and pos.x and pos.x >= r.x0 and pos.x <= r.x1
        and pos.y >= r.y0 and pos.y <= r.y1 then
        self:help_scroll_by(dir * steps)
    elseif self.focus == "list" or self.mode == "options" then
        self:list_move(dir * steps)
    else
        self:tree_move(dir * steps)
    end
end

function Menu:on_right()
    if self.mode == "options" then return end
    if self.focus == "list" then self:list_activate()
    else self:tree_forward() end
end

function Menu:on_left()
    if self.mode == "options" then
        self:exit_options(self.option_setting)
        -- exit_options leaves focus on the list; LEFT cancels back to it
        self.list_sel = self.saved_list_sel or self.list_sel
        self:render()
    elseif self.focus == "list" then
        if self.query ~= "" then
            -- clearing a search returns to the tree
            self.query = ""
            self.list_sel = 1
            self.list_scroll = 0
            self.focus = "tree"
            self:rebuild_list()
            self:render()
        else
            self:list_back()
        end
    else
        self:tree_back()
    end
end

function Menu:on_esc()
    if self.mode == "options" then
        self:exit_options(self.option_setting)
    elseif self.focus == "list" then
        if self.query ~= "" then
            self.query = ""
            self.list_sel = 1
            self.list_scroll = 0
            self.focus = "tree"
            self:rebuild_list()
            self:render()
        else
            self:list_back()
        end
    else
        self:close()
    end
end

-- ---------------------------------------------------------------------------
-- Mouse
-- ---------------------------------------------------------------------------

-- Map a cursor position to (pane, row). pane is "tree" | "list" | "help" | nil;
-- row is the 1-based row index for "tree"/"list", nil otherwise.
function Menu:hit_test(x, y)
    local th = self.tree_hit
    if th and x >= th.x0 and x <= th.x1 then
        for i = th.from, th.to do
            local ytop = th.top + (i - th.from) * th.rowH
            if y >= ytop and y < ytop + th.rowH then return "tree", i end
        end
    end
    local lh = self.list_hit
    if lh and x >= lh.x0 and x <= lh.x1 then
        for i = lh.from, lh.to do
            local ytop = lh.top + (i - lh.from) * lh.rowH
            if y >= ytop and y < ytop + lh.rowH then return "list", i end
        end
    end
    local r = self.help_rect
    if r and x >= r.x0 and x <= r.x1 and y >= r.y0 and y <= r.y1 then
        return "help", nil
    end
    return nil, nil
end

-- Hover: highlight the row under the cursor (and, in browse mode, select the
-- hovered category so its settings show on the right). Only re-renders when the
-- target row actually changes, so pixel-by-pixel motion is cheap.
function Menu:on_mouse_move(x, y)
    if self.closed then return end
    self.mouse_x, self.mouse_y = x, y
    local pane, idx = self:hit_test(x, y)
    if pane == "tree" then
        if self.mode == "options" or self.query ~= "" then return end
        if self.focus ~= "tree" or self.tree_sel ~= idx then
            self.focus = "tree"
            self.tree_sel = idx
            self:rebuild_list()
            self:render()
        end
    elseif pane == "list" then
        if self.list_sel ~= idx or (self.mode ~= "options" and self.focus ~= "list") then
            if self.mode ~= "options" then self.focus = "list" end
            self.list_sel = idx
            self:render()
        end
    end
end

-- Left click: activate the row under the cursor. Clicking a category toggles
-- its expansion; clicking a setting/option edits it; clicking outside the panel
-- closes the menu.
function Menu:on_mouse_click()
    if self.closed then return end
    local x, y = self.mouse_x, self.mouse_y
    if not x then
        local p = mp.get_property_native("mouse-pos")
        if p then x, y = p.x, p.y end
    end
    if not x then return end
    -- a click on the help pane's URL line opens it in the browser
    local ur = self.url_rect
    if self.url_value and ur and x >= ur.x0 and x <= ur.x1
        and y >= ur.y0 and y <= ur.y1 then
        open_url(self.url_value)
        return
    end
    local pane, idx = self:hit_test(x, y)
    if pane == "tree" then
        if self.mode == "options" or self.query ~= "" then return end
        self.focus = "tree"
        self.tree_sel = idx
        local row = self.tree_rows[idx]
        if row and row.expandable then
            self:toggle_node()
        else
            self:rebuild_list()
            self:render()
        end
    elseif pane == "list" then
        if self.mode ~= "options" then self.focus = "list" end
        self.list_sel = idx
        self:list_activate()
    elseif pane == nil then
        local pr = self.panel_rect
        if pr and not (x >= pr.x0 and x <= pr.x1 and y >= pr.y0 and y <= pr.y1) then
            self:close()
        end
    end
end

-- Open the focused setting's manual URL in the browser (Ctrl+O).
function Menu:open_focused_url()
    local s = self:focused_setting()
    if s and s.url and s.url ~= "" then open_url(s.url) end
end

-- ---------------------------------------------------------------------------
-- Key bindings
-- ---------------------------------------------------------------------------

local PRINTABLE = "abcdefghijklmnopqrstuvwxyz0123456789-_."

function Menu:bind_keys()
    local function bind(key, name, fn, rep)
        mp.add_forced_key_binding(key, "uimenu_" .. name, fn,
            rep and { repeatable = true } or nil)
    end

    bind("DOWN", "down", function() self:on_down() end, true)
    bind("UP", "up", function() self:on_up() end, true)
    bind("PGDWN", "pgdn", function() self:on_page(1) end, true)
    bind("PGUP", "pgup", function() self:on_page(-1) end, true)
    -- scroll the help/description pane from the keyboard
    bind("Shift+DOWN", "hdown", function() self:help_scroll_by(1) end, true)
    bind("Shift+UP", "hup", function() self:help_scroll_by(-1) end, true)
    bind("ENTER", "enter", function() self:on_enter() end)
    bind("RIGHT", "right", function() self:on_right() end)
    bind("ESC", "esc", function() self:on_esc() end)
    bind("LEFT", "left", function() self:on_left() end)
    bind("BS", "bs", function() self:backspace() end, true)
    bind("SPACE", "space", function() self:type_char(" ") end, true)
    -- open the focused setting's manual URL (also clickable in the help pane)
    bind("Ctrl+o", "openurl", function() self:open_focused_url() end)

    -- printable characters feed the search box
    for i = 1, #PRINTABLE do
        local c = PRINTABLE:sub(i, i)
        bind(c, "key_" .. i, function() self:type_char(c) end, true)
    end

    -- Mouse. Wheel is `complex` so we can read its scale (fast-scroll fix);
    -- MBTN_LEFT activates on press; hover tracking comes from the mouse-pos
    -- property observer.
    mp.add_forced_key_binding("WHEEL_DOWN", "uimenu_wdown",
        function(e) self:on_wheel(1, e) end, { complex = true })
    mp.add_forced_key_binding("WHEEL_UP", "uimenu_wup",
        function(e) self:on_wheel(-1, e) end, { complex = true })
    mp.add_forced_key_binding("MBTN_LEFT", "uimenu_click",
        function(e) if e.event == "down" then self:on_mouse_click() end end,
        { complex = true })
    self._mouse_cb = function(_, pos)
        if pos and pos.x then self:on_mouse_move(pos.x, pos.y) end
    end
    mp.observe_property("mouse-pos", "native", self._mouse_cb)
end

function Menu:unbind_keys()
    for _, n in ipairs({ "down", "up", "wdown", "wup", "pgdn", "pgup", "enter",
                         "right", "esc", "left", "bs", "space", "hdown", "hup",
                         "click", "openurl" }) do
        mp.remove_key_binding("uimenu_" .. n)
    end
    for i = 1, #PRINTABLE do
        mp.remove_key_binding("uimenu_key_" .. i)
    end
    if self._mouse_cb then
        mp.unobserve_property(self._mouse_cb)
    end
end

function Menu:close()
    if self.closed then return end
    self.closed = true
    self:unbind_keys()
    self.overlay:remove()
end

return M
