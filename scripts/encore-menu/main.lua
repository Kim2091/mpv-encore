-- encore-menu — the mpv.net context menu, built from input.conf.
--
-- mpv.net lets you define a hierarchical context menu directly in input.conf by
-- annotating bindings with a "#menu:" comment, e.g.
--
--     c   script-binding encore_settings/open   #menu: Settings
--     o   script-message-to encore_files open-files  #menu: File > Open Files
--     -   ignore   #menu: File > -                 (a separator)
--
-- The path is split on ">"; the last segment is the item label, the rest are
-- submenus. The marker prefix is configurable via menu-syntax (default
-- "#menu:"; uosc-style "#!" also works). mpv exposes each binding's trailing
-- comment via the input-bindings property, so no file parsing is needed.
--
-- Bind it (typically to right-click):
--     MBTN_RIGHT  script-binding encore_menu/menu
--
-- Rendering is a custom ASS-drawn popup that matches the settings menu theme
-- (uimenu.lua): a dark rounded panel with a warm accent selection bar. The
-- popup opens at the mouse cursor and cascades submenus to the side, clamped to
-- stay on screen.

package.path = mp.command_native({ "expand-path", "~~/script-modules/?.lua" })
    .. ";" .. package.path

local config = require "encore-config"
local assdraw = require "mp.assdraw"

-- "#menu:" -> match comments beginning "menu:" (mpv strips the leading '#').
local function comment_prefix()
    local syntax = config.get("menu-syntax", "#menu:")
    return (syntax:gsub("^#", ""))
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Build the menu tree from the current input bindings.
local function build_tree()
    local prefix = comment_prefix()
    local root = { children = {}, order = {}, items = {} }

    for _, b in ipairs(mp.get_property_native("input-bindings") or {}) do
        local comment = b.comment
        if comment and comment:sub(1, #prefix) == prefix then
            local path = trim(comment:sub(#prefix + 1))
            if path ~= "" then
                -- split on ">"
                local parts = {}
                for seg in (path .. ">"):gmatch("(.-)>") do
                    parts[#parts + 1] = trim(seg)
                end

                local label = parts[#parts]
                local node = root
                for i = 1, #parts - 1 do
                    local name = parts[i]
                    if not node.children[name] then
                        node.children[name] = { children = {}, order = {}, items = {} }
                        node.order[#node.order + 1] = { kind = "node", name = name }
                    end
                    node = node.children[name]
                end

                if label == "-" or label == "" then
                    node.order[#node.order + 1] = { kind = "sep" }
                else
                    node.order[#node.order + 1] =
                        { kind = "item", name = label, cmd = b.cmd, key = b.key }
                end
            end
        end
    end

    return root
end

-- ---------------------------------------------------------------------------
-- Theme — colours lifted from the settings menu (uimenu.lua). ASS BGR.
-- ---------------------------------------------------------------------------
local C_PANEL   = "&H1C1714&"   -- dark panel fill
local C_TEXT    = "&HF2F2F2&"   -- near-white
local C_DIM     = "&H9A9A9A&"   -- secondary text (key hints)
local C_FAINT   = "&H666058&"   -- tertiary
local C_ACCENT  = "&HE8A85A&"   -- accent (warm, BGR)
local C_SELTXT  = "&H1A1410&"   -- text on the selection bar
local C_SELBG   = "&HE8A85A&"   -- selection bar fill (accent)
local C_DIVIDER = "&H3A322C&"   -- subtle divider line

local function ass_escape(s)
    return (tostring(s):gsub("\\", "/"):gsub("[{}]", ""):gsub("[\r\n]+", " "))
end

-- ---------------------------------------------------------------------------
-- Popup menu
-- ---------------------------------------------------------------------------
local Menu = {}
Menu.__index = Menu

-- A "level" is one open panel. The stack holds the chain of cascaded panels
-- (root -> submenu -> nested submenu). `sel` is the highlighted row (1-based,
-- by visible-row index). Rendering computes each level's geometry from its
-- anchor and content, then the active (top) level owns the keyboard selection.

local function open_menu(root)
    local self = setmetatable({}, Menu)
    self.overlay = mp.create_osd_overlay("ass-events")
    self.levels = {}            -- stack of { node, sel, geom }
    -- Seed the cursor position synchronously so the very first render opens at
    -- the mouse (the property observer fires async, a frame too late).
    local pos = mp.get_property_native("mouse-pos")
    self.mouse = (pos and pos.x) and { x = pos.x, y = pos.y } or { x = -1, y = -1 }
    self.closed = false
    -- Freeze the root panel's top-left at the cursor (it must NOT follow the
    -- mouse afterwards). Negative seed -> centre fallback resolved in layout.
    local root_anchor = (self.mouse.x >= 0)
        and { x = self.mouse.x, y = self.mouse.y } or nil
    self:push(root, root_anchor)
    self:bind_keys()
    self:observe_mouse()
    self:render()
    return self
end

-- A row is selectable if it's an item or a node (not a separator).
local function selectable(entry) return entry.kind == "item" or entry.kind == "node" end

-- First selectable row index in a node (for initial selection), or 0.
local function first_selectable(node)
    for i, e in ipairs(node.order) do
        if selectable(e) then return i end
    end
    return 0
end

function Menu:push(node, anchor)
    self.levels[#self.levels + 1] = {
        node = node,
        anchor = anchor,            -- { x, y } top-left hint, or nil for root
        sel = first_selectable(node),
        geom = nil,                 -- filled in by render
    }
end

function Menu:top() return self.levels[#self.levels] end

function Menu:pop()
    if #self.levels <= 1 then
        self:close()
        return
    end
    self.levels[#self.levels] = nil
    self:top().open_row = nil       -- the parent's cascade is now closed
    self:render()
end

-- ---------------------------------------------------------------------------
-- Geometry + rendering
-- ---------------------------------------------------------------------------

local function I(v) return math.floor(v + 0.5) end

-- Measured layout metrics, recomputed each render from the OSD size.
function Menu:metrics()
    local osd_w, osd_h = mp.get_osd_size()
    if not osd_h or osd_h == 0 then osd_w, osd_h = 1280, 720 end
    local fs    = I(osd_h / 36)            -- row text
    local rowH  = I(fs * 1.55)
    local sepH  = I(rowH * 0.5)
    local padX  = I(fs * 0.9)              -- horizontal text padding
    local padY  = I(fs * 0.5)              -- vertical panel padding
    local gapKey = I(fs * 2.0)             -- gap between label and key/arrow
    local glyphW = fs * 0.52               -- approx label glyph width
    return {
        osd_w = osd_w, osd_h = osd_h, fs = fs, rowH = rowH, sepH = sepH,
        padX = padX, padY = padY, gapKey = gapKey, glyphW = glyphW,
    }
end

-- Compute a level's pixel geometry given the metrics and a desired top-left.
-- Returns a geom table with panel rect, content width, and per-row rects.
function Menu:layout(level, m)
    local node = level.node
    -- widest content: label width + gap + (key or arrow) width
    local maxLabel, maxRight = 0, 0
    for _, e in ipairs(node.order) do
        if e.kind == "node" then
            maxLabel = math.max(maxLabel, #e.name * m.glyphW)
            maxRight = math.max(maxRight, m.fs)              -- "▸"
        elseif e.kind == "item" then
            maxLabel = math.max(maxLabel, #e.name * m.glyphW)
            if e.key and e.key ~= "" then
                maxRight = math.max(maxRight, #e.key * m.glyphW * 0.92)
            end
        end
    end
    local contentW = maxLabel + (maxRight > 0 and (m.gapKey + maxRight) or 0)
    local panelW = I(contentW + m.padX * 2)
    -- minimum sane width
    if panelW < I(m.fs * 6) then panelW = I(m.fs * 6) end

    -- height
    local h = m.padY * 2
    local rows = {}
    for _, e in ipairs(node.order) do
        local rh = (e.kind == "sep") and m.sepH or m.rowH
        rows[#rows + 1] = { entry = e, h = rh }
        h = h + rh
    end
    local panelH = I(h)

    -- desired top-left
    local x, y
    if level.anchor then
        x, y = level.anchor.x, level.anchor.y
    else
        x, y = self.mouse.x, self.mouse.y
        if x < 0 then x = I(m.osd_w * 0.5); y = I(m.osd_h * 0.4) end
    end

    -- clamp to screen
    local margin = I(m.fs * 0.3)
    if x + panelW > m.osd_w - margin then
        if level.anchor and level.anchor.flipLeftBase then
            -- submenu: open to the left of the parent instead
            x = level.anchor.flipLeftBase - panelW
        else
            x = m.osd_w - margin - panelW
        end
    end
    if x < margin then x = margin end
    if y + panelH > m.osd_h - margin then y = m.osd_h - margin - panelH end
    if y < margin then y = margin end

    -- per-row rects (absolute)
    local ry = y + m.padY
    for _, r in ipairs(rows) do
        r.x0, r.y0, r.x1, r.y1 = x, ry, x + panelW, ry + r.h
        ry = ry + r.h
    end

    level.geom = {
        x = x, y = y, w = panelW, h = panelH, rows = rows,
        right = x + panelW, bottom = y + panelH,
    }
    return level.geom
end

function Menu:render()
    if self.closed then return end
    local m = self:metrics()
    local a = assdraw.ass_new()

    local function box(x0, y0, x1, y1, colour, alpha)
        a:new_event()
        a:pos(0, 0)
        a:append(string.format("{\\bord0\\shad0\\1c%s\\1a%s}", colour, alpha or "&H00&"))
        a:draw_start()
        a:rect_cw(I(x0), I(y0), I(x1), I(y1))
        a:draw_stop()
    end

    -- empty menu: themed message panel
    if #self.levels == 1 and #self:top().node.order == 0 then
        self:render_empty(a, m, box)
        self.overlay.res_x = m.osd_w
        self.overlay.res_y = m.osd_h
        self.overlay.data = a.text
        self.overlay:update()
        return
    end

    -- lay out every open level (parents first so anchors resolve in order)
    for _, level in ipairs(self.levels) do
        self:layout(level, m)
    end

    local activeLevel = self:top()

    for li, level in ipairs(self.levels) do
        local g = level.geom
        local active = (level == activeLevel)

        -- drop shadow + panel
        box(g.x + 4, g.y + 4, g.right + 4, g.bottom + 4, "&H000000&", "&H60&")
        box(g.x, g.y, g.right, g.bottom, C_PANEL, "&H0A&")
        -- a faint accent hairline along the top of the panel
        box(g.x, g.y, g.right, g.y + I(m.osd_h * 0.0022), C_DIVIDER, "&H20&")

        for ri, r in ipairs(g.rows) do
            local e = r.entry
            if e.kind == "sep" then
                local cy = I((r.y0 + r.y1) / 2)
                box(g.x + m.padX, cy, g.right - m.padX, cy + I(m.osd_h * 0.0022),
                    C_DIVIDER, "&H1A&")
            else
                local on_bar = active and (ri == level.sel)
                -- parent row whose submenu is open: keep a dim accent bar so the
                -- breadcrumb stays visible while the cascade is active.
                local parent_open = (not active) and (ri == level.open_row)
                if on_bar then
                    box(g.x + I(m.fs * 0.2), r.y0 + I(m.fs * 0.1),
                        g.right - I(m.fs * 0.2), r.y1 - I(m.fs * 0.1),
                        C_SELBG, "&H10&")
                elseif parent_open then
                    box(g.x + I(m.fs * 0.2), r.y0 + I(m.fs * 0.1),
                        g.right - I(m.fs * 0.2), r.y1 - I(m.fs * 0.1),
                        C_SELBG, "&H9A&")
                end
                local ty = I((r.y0 + r.y1) / 2)
                local lx = g.x + m.padX
                local rx = g.right - m.padX
                local labelcol = on_bar and C_SELTXT or C_TEXT

                -- label (left, vertically centred)
                a:new_event()
                a:append(string.format("{\\an4\\pos(%d,%d)\\fs%d\\bord0\\shad0\\q2\\1c%s}%s",
                    lx, ty, m.fs, labelcol, ass_escape(e.name)))

                -- right side: submenu arrow or key binding
                if e.kind == "node" then
                    a:new_event()
                    a:append(string.format("{\\an6\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s}▸",
                        rx, ty, m.fs, on_bar and C_SELTXT or C_ACCENT))
                elseif e.key and e.key ~= "" then
                    a:new_event()
                    a:append(string.format("{\\an6\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s}%s",
                        rx, ty, I(m.fs * 0.9), on_bar and C_SELTXT or C_DIM,
                        ass_escape(e.key)))
                end
            end
        end
    end

    -- Pin ASS coordinate space to the measured OSD size so positions are
    -- correct under Windows display scaling (see uimenu.lua).
    self.overlay.res_x = m.osd_w
    self.overlay.res_y = m.osd_h
    self.overlay.data = a.text
    self.overlay:update()
end

function Menu:render_empty(a, m, box)
    local lines = {
        "No context menu defined.",
        "Add #menu: comments to bindings in input.conf.",
    }
    local fs = m.fs
    local padX = I(fs * 1.2)
    local padY = I(fs * 0.9)
    local lineH = I(fs * 1.5)
    local maxW = 0
    for _, ln in ipairs(lines) do maxW = math.max(maxW, #ln * m.glyphW) end
    local w = I(maxW + padX * 2)
    local h = I(#lines * lineH + padY * 2)
    local x = self.mouse.x >= 0 and self.mouse.x or I((m.osd_w - w) / 2)
    local y = self.mouse.y >= 0 and self.mouse.y or I((m.osd_h - h) / 2)
    local margin = I(fs * 0.3)
    if x + w > m.osd_w - margin then x = m.osd_w - margin - w end
    if x < margin then x = margin end
    if y + h > m.osd_h - margin then y = m.osd_h - margin - h end
    if y < margin then y = margin end

    box(x + 4, y + 4, x + w + 4, y + h + 4, "&H000000&", "&H60&")
    box(x, y, x + w, y + h, C_PANEL, "&H0A&")
    for i, ln in ipairs(lines) do
        a:new_event()
        a:append(string.format("{\\an7\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s}%s",
            x + padX, y + padY + (i - 1) * lineH, fs,
            i == 1 and C_TEXT or C_DIM, ass_escape(ln)))
    end
    -- stash geom so a click anywhere / outside still closes via hit-test
    self.empty_geom = { x = x, y = y, right = x + w, bottom = y + h }
end

-- ---------------------------------------------------------------------------
-- Selection / activation
-- ---------------------------------------------------------------------------

-- Move selection within the active level, skipping separators.
function Menu:move(delta)
    local level = self:top()
    local order = level.node.order
    if #order == 0 then return end
    local i = level.sel
    for _ = 1, #order do
        i = i + delta
        if i < 1 then i = #order end
        if i > #order then i = 1 end
        if selectable(order[i]) then
            level.sel = i
            self:render()
            return
        end
    end
end

-- Activate the current selection of the active level.
function Menu:activate()
    local level = self:top()
    local entry = level.node.order[level.sel]
    if not entry then return end
    if entry.kind == "item" then
        local cmd = entry.cmd
        self:close()
        if cmd and cmd ~= "" then mp.command(cmd) end
    elseif entry.kind == "node" then
        self:enter_submenu(level, level.sel)
    end
end

-- Open the submenu for row `ri` of `level`, anchored to its right edge.
function Menu:enter_submenu(level, ri)
    local entry = level.node.order[ri]
    if not entry or entry.kind ~= "node" then return end
    local child = level.node.children[entry.name]
    if not child then return end
    level.open_row = ri               -- remember which row spawned the cascade
    local m = self:metrics()
    self:layout(level, m)             -- ensure geom current
    local r = level.geom.rows[ri]
    local anchor = {
        x = level.geom.right - I(m.fs * 0.2),   -- slight overlap to the right
        y = r.y0,
        flipLeftBase = level.geom.x + I(m.fs * 0.2),  -- left edge to flip against
    }
    self:push(child, anchor)
    self:render()
end

-- ---------------------------------------------------------------------------
-- Mouse
-- ---------------------------------------------------------------------------

-- Hit-test: returns level-index, row-index of the row under (mx,my), or nil.
function Menu:hit(mx, my)
    -- topmost level first so overlapping cascade rows resolve to the front
    for li = #self.levels, 1, -1 do
        local g = self.levels[li].geom
        if g and mx >= g.x and mx <= g.right and my >= g.y and my <= g.bottom then
            for ri, r in ipairs(g.rows) do
                if my >= r.y0 and my <= r.y1 then
                    return li, ri
                end
            end
            return li, nil          -- inside panel padding, no specific row
        end
    end
    return nil, nil
end

function Menu:on_mouse_move(mx, my)
    self.mouse.x, self.mouse.y = mx, my
    if self.closed then return end
    if #self.levels == 1 and #self:top().node.order == 0 then return end
    local li, ri = self:hit(mx, my)
    if not li then return end       -- outside all panels: leave selection as-is

    local level = self.levels[li]

    -- Special case: a submenu can flip LEFT and overlap its parent, so the
    -- cursor sitting on the parent's own row would otherwise keep collapsing
    -- the cascade. If we're hovering exactly the row that owns the open
    -- submenu, leave everything as-is.
    if li < #self.levels and ri and level.open_row == ri then
        return
    end

    -- Hovering a parent level collapses cascades down to it so the hovered
    -- panel becomes active.
    while #self.levels > li do
        self.levels[#self.levels] = nil
    end
    level.open_row = nil            -- its cascade (if any) is now closed
    if ri and selectable(level.node.order[ri]) then
        local changed = (level.sel ~= ri)
        level.sel = ri
        -- hovering a node row auto-opens its submenu (classic context menu).
        -- Fire whenever its cascade isn't already the one open, not only on a
        -- selection change (the row may already be selected from the open hover).
        local entry = level.node.order[ri]
        if entry.kind == "node" and level.open_row ~= ri then
            self:enter_submenu(level, ri)
            return
        end
        if changed then self:render() end
        return
    end
    self:render()
end

function Menu:on_click()
    local mx, my = self.mouse.x, self.mouse.y
    -- empty-message popup: any click closes it
    if #self.levels == 1 and #self:top().node.order == 0 then
        self:close()
        return
    end
    local li, ri = self:hit(mx, my)
    if not li then
        -- clicked outside every panel: close
        self:close()
        return
    end
    local level = self.levels[li]
    -- collapse to the clicked level
    while #self.levels > li do
        self.levels[#self.levels] = nil
    end
    if ri and selectable(level.node.order[ri]) then
        level.sel = ri
        self:activate()
    else
        self:render()
    end
end

function Menu:observe_mouse()
    self._mouse_obs = function(_, pos)
        if not pos then return end
        self:on_mouse_move(pos.x, pos.y)
    end
    mp.observe_property("mouse-pos", "native", self._mouse_obs)
end

-- ---------------------------------------------------------------------------
-- Key bindings
-- ---------------------------------------------------------------------------

function Menu:bind_keys()
    local function bind(key, name, fn, rep)
        mp.add_forced_key_binding(key, "encore_menu_" .. name, fn,
            rep and { repeatable = true } or nil)
    end
    bind("DOWN", "down", function() self:move(1) end, true)
    bind("UP", "up", function() self:move(-1) end, true)
    bind("WHEEL_DOWN", "wdown", function() self:move(1) end, true)
    bind("WHEEL_UP", "wup", function() self:move(-1) end, true)
    bind("ENTER", "enter", function() self:activate() end)
    bind("RIGHT", "right", function()
        local level = self:top()
        local e = level.node.order[level.sel]
        if e and e.kind == "node" then self:enter_submenu(level, level.sel) end
    end)
    bind("LEFT", "left", function() self:pop() end)
    bind("BS", "bs", function() self:pop() end)
    bind("ESC", "esc", function() self:close() end)
    bind("MBTN_LEFT", "click", function() self:on_click() end)
end

function Menu:unbind_keys()
    for _, n in ipairs({ "down", "up", "wdown", "wup", "enter", "right",
                         "left", "bs", "esc", "click" }) do
        mp.remove_key_binding("encore_menu_" .. n)
    end
end

function Menu:close()
    if self.closed then return end
    self.closed = true
    self:unbind_keys()
    if self._mouse_obs then mp.unobserve_property(self._mouse_obs) end
    self.overlay:remove()
end

-- ---------------------------------------------------------------------------
-- Entry points
-- ---------------------------------------------------------------------------

local active

local function show_menu()
    if active and not active.closed then
        active:close()
    end
    active = open_menu(build_tree())
end

mp.add_key_binding(nil, "menu", show_menu)
mp.register_script_message("menu", show_menu)
