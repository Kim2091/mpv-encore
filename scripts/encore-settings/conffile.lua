-- conffile.lua — read/write mpv config files, preserving comments & sections.
--
-- Faithful Lua port of the config I/O in mpv.net's ConfWindow.xaml.cs:
--   LoadConf            -> ConfFile:load
--   GetContent          -> ConfFile:get_content
--   EscapeValue         -> escape_value
--   LoadLibplaceboConf  -> ConfFile:load_libplacebo
--   LoadKeyValueList    -> ConfFile:load_key_value_list
--   GetKeyValueContent  -> ConfFile:get_key_value_content
--   the merge in LoadSettings -> ConfFile:merge_into_settings
--
-- The design mirrors mpv.net exactly: a single list of "conf items" (one per
-- line of meaningful config) is shared across every config file, tagged by a
-- file name ("mpv", "encore", "libplacebo"). Items carry their leading comment,
-- inline comment, and [section] so the file can be rewritten with formatting
-- intact. Only values that differ from their default are written.

local M = {}

local CF = {}
CF.__index = CF

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function contains(s, sub)
    return s:find(sub, 1, true) ~= nil
end

local function starts_with(s, prefix)
    return s:sub(1, #prefix) == prefix
end

local function ends_with(s, suffix)
    return suffix == "" or s:sub(-#suffix) == suffix
end

-- Port of EscapeValue.
local function escape_value(value)
    if contains(value, "'") then
        return '"' .. value .. '"'
    end

    if contains(value, '"') then
        return "'" .. value .. "'"
    end

    if contains(value, '"') or contains(value, "#") or starts_with(value, "%")
        or starts_with(value, " ") or ends_with(value, " ") then
        return "'" .. value .. "'"
    end

    return value
end
M.escape_value = escape_value

-- settings: the list produced by conf.load(). Indexed lookups are built lazily.
function M.new(settings)
    local self = setmetatable({}, CF)
    self.settings = settings
    self.items = {}          -- list of conf items (ConfItem equivalents)
    self.use_space = 0       -- "name = value" style count
    self.use_no_space = 0    -- "name=value" style count
    return self
end

-- Reads lines from a file path, returns an array of lines, or nil if missing.
local function read_lines(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    -- Strip a leading UTF-8 BOM (matches C#'s File.ReadAllLines), otherwise the
    -- first line is unrecognised and dropped.
    if content:sub(1, 3) == "\239\187\191" then content = content:sub(4) end
    content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
    local lines = {}
    for line in (content .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

-- Port of LoadConf: parse one config file into conf items tagged with file_tag.
function CF:load(path, file_tag)
    local lines = read_lines(path)
    if not lines then return end

    local comment = ""
    local section = ""
    local is_section_item = false

    for _, raw in ipairs(lines) do
        local line = trim(raw)

        if starts_with(line, "-") then
            line = line:gsub("^%-+", "")
        end

        if line == "" then
            comment = comment .. "\n"
        elseif starts_with(line, "#") then
            comment = comment .. trim(line) .. "\n"
        elseif starts_with(line, "[") and contains(line, "]") then
            if not is_section_item and comment ~= "" and comment ~= "\n" then
                self.items[#self.items + 1] = {
                    comment = comment, file = file_tag, name = "", value = "",
                    section = "", line_comment = "", is_section_item = false,
                }
            end
            section = line:sub(1, (line:find("]", 1, true)))
            comment = ""
            is_section_item = true
        elseif contains(line, "=") or line:match("^[%w%-]+$") then
            if not contains(line, "=") then
                if starts_with(line, "no-") then
                    line = line:sub(4) .. "=no"
                else
                    line = line .. "=yes"
                end
            end

            if contains(line, " =") or contains(line, "= ") then
                self.use_space = self.use_space + 1
            else
                self.use_no_space = self.use_no_space + 1
            end

            local item = {
                file = file_tag, is_section_item = is_section_item,
                comment = comment, section = section,
                line_comment = "", name = "", value = "",
            }
            comment = ""
            section = ""

            if contains(line, "#") and not contains(line, "'") and not contains(line, '"') then
                local h = line:find("#", 1, true)
                item.line_comment = trim(line:sub(h))
                line = trim(line:sub(1, h - 1))
            end

            local pos = line:find("=", 1, true)
            local left = trim(line:sub(1, pos - 1)):lower():gsub("^%-+", "")
            local right = trim(line:sub(pos + 1))

            if starts_with(right, "'") and ends_with(right, "'") then
                right = right:gsub("^'+", ""):gsub("'+$", "")
            end
            if starts_with(right, '"') and ends_with(right, '"') then
                right = right:gsub('^"+', ""):gsub('"+$', "")
            end

            if left == "fs" then left = "fullscreen" end
            if left == "loop" then left = "loop-file" end

            item.name = left
            item.value = right
            self.items[#self.items + 1] = item
        end
    end
end

-- Port of LoadLibplaceboConf + LoadKeyValueList: expand a "libplacebo-opts"
-- value (a comma-separated key=value list) into individual "libplacebo" items.
function CF:load_libplacebo()
    for _, item in ipairs({ table.unpack and table.unpack(self.items) or unpack(self.items) }) do
        if item.name == "libplacebo-opts" then
            self:load_key_value_list(item.value, "libplacebo")
        end
    end
end

function CF:load_key_value_list(options, file_tag)
    for pair in (options or ""):gmatch("[^,]+") do
        local eq = pair:find("=", 1, true)
        if eq then
            local left = trim(pair:sub(1, eq - 1)):lower()
            local right = trim(pair:sub(eq + 1))
            self.items[#self.items + 1] = {
                name = left, value = right, file = file_tag,
                comment = "", section = "", line_comment = "",
                is_section_item = false,
            }
        end
    end
end

-- Port of the merge loop in LoadSettings: copy values from conf items onto the
-- matching settings and link them, so rewriting can reuse the original item.
function CF:merge_into_settings()
    for _, setting in ipairs(self.settings) do
        setting.start_value = setting.value

        for _, item in ipairs(self.items) do
            if setting.name == item.name and setting.file == item.file
                and item.section == "" and not item.is_section_item then
                setting.value = item.value
                setting.start_value = setting.value
                setting.conf_item = item
                item.setting_base = setting
            end
        end
    end
end

-- Port of GetKeyValueContent: serialise non-default settings of a file as a
-- comma-separated key=value list (used to rebuild libplacebo-opts).
function CF:get_key_value_content(file_tag)
    local pairs_out = {}
    for _, setting in ipairs(self.settings) do
        if setting.file == file_tag then
            if (setting.value or "") ~= setting.default then
                pairs_out[#pairs_out + 1] = setting.name .. "=" .. escape_value(setting.value)
            end
        end
    end
    return table.concat(pairs_out, ",")
end

-- Port of GetContent: rebuild a config file's text from the conf items and
-- settings, preserving comments/sections and writing only non-default values.
function CF:get_content(file_tag)
    local sb = {}
    local names_written = {}
    local eq = self.use_space > self.use_no_space and " = " or "="

    local function append(s) sb[#sb + 1] = s end
    local function joined() return table.concat(sb) end

    -- 1) Non-section items.
    for _, item in ipairs(self.items) do
        if file_tag == item.file and item.section == "" and not item.is_section_item then
            if item.comment ~= "" then append(item.comment) end

            if item.setting_base == nil then
                if item.name ~= "" then
                    append(item.name .. eq .. escape_value(item.value))
                    if item.line_comment ~= "" then append(" " .. item.line_comment) end
                    append("\n")
                    names_written[item.name] = true
                end
            elseif (item.setting_base.value or "") ~= item.setting_base.default then
                append(item.name .. eq .. escape_value(item.setting_base.value))
                if item.line_comment ~= "" then append(" " .. item.line_comment) end
                append("\n")
                names_written[item.name] = true
            end
        end
    end

    -- 2) Settings not already written (new, non-default values).
    for _, setting in ipairs(self.settings) do
        if file_tag == setting.file and not names_written[setting.name] then
            if (setting.value or "") ~= setting.default then
                append(setting.name .. eq .. escape_value(setting.value) .. "\n")
            end
        end
    end

    -- 3) Section items (verbatim, preserving [section] grouping).
    for _, item in ipairs(self.items) do
        if file_tag == item.file and not (item.section == "" and not item.is_section_item) then
            if item.section ~= "" then
                if not ends_with(joined(), "\n\n") then append("\n") end
                append(item.section .. "\n")
            end
            if item.comment ~= "" then append(item.comment) end
            append(item.name .. eq .. escape_value(item.value))
            if item.line_comment ~= "" then append(" " .. item.line_comment) end
            append("\n")
            names_written[item.name] = true
        end
    end

    return "\n" .. trim(joined()) .. "\n"
end

return M
