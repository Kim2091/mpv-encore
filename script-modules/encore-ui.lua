-- encore-ui — shared OSD menu helpers for the encore script package.
--
-- Thin wrappers over mpv's mp.input (the same primitives the settings menu and
-- select.lua use) so every script in the package gets consistent navigable
-- lists and text input without duplicating boilerplate.
--
-- Scripts load it with:
--   package.path = mp.command_native({"expand-path", "~~/script-modules/?.lua"})
--                  .. ";" .. package.path
--   local ui = require "encore-ui"

local input = require "mp.input"

local M = {}

-- A navigable, fuzzy-filterable list.
--   t.prompt        prompt string
--   t.items         array of display strings
--   t.on_select(i)  called with the 1-based index into t.items
--   t.back          optional function; adds a "← Back" entry that calls it
--   t.default_item  optional 1-based preselected index into t.items
--   t.stay          if true, re-open this list after on_select (browse mode)
function M.select(t)
    local items = {}
    local offset = 0

    if t.back then
        items[1] = "← Back"
        offset = 1
    end
    for i, v in ipairs(t.items) do
        items[i + offset] = v
    end

    input.select({
        prompt = t.prompt,
        items = items,
        default_item = (t.default_item or 1) + offset,
        keep_open = true,
        submit = function(idx)
            if t.back and idx == 1 then
                t.back()
                return
            end
            local real = idx - offset
            if t.on_select then t.on_select(real) end
            if t.stay then M.select(t) end
        end,
    })
end

-- A text input field.
--   t.prompt, t.default, t.on_submit(text), t.back (optional)
function M.input(t)
    input.get({
        prompt = t.prompt,
        default_text = t.default or "",
        keep_open = true,
        submit = function(text)
            if t.on_submit then t.on_submit(text) end
        end,
    })
end

-- A read-only, scrollable/filterable text view (one string per line). Selecting
-- a line just keeps the view open; Esc closes it. `back` adds a Back entry.
function M.text_view(prompt, lines, back)
    M.select({ prompt = prompt, items = lines, back = back, stay = true,
               on_select = function() end })
end

function M.osd(text, duration)
    mp.osd_message(text, duration or 5)
end

return M
