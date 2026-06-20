-- conf.lua — parser for editor_conf.txt
--
-- Faithful Lua port of mpv.net's Conf.cs (ConfParser + Conf.LoadConf) and
-- Settings.cs (the Setting model). The editor_conf.txt format is a sequence of
-- blank-line-separated sections, each a set of "key = value" lines describing
-- one setting. This keeps the exact same source-of-truth format as mpv.net so
-- definitions can be cross-ported between the two projects.
--
-- A Setting is a plain table with these fields:
--   name, file, directory, help, url, type, default, value, start_value
--   width (int), option_name_width (int, default 100)
--   kind         = "option" | "string"
--   options      = array of { name, help, text } (only for kind == "option")

local M = {}

-- Splits a string on a single-character separator, keeping empty fields.
local function split_lines(content)
    local lines = {}
    -- Strip a leading UTF-8 BOM, then normalise CRLF/CR to LF so the section
    -- logic is newline-agnostic.
    if content:sub(1, 3) == "\239\187\191" then content = content:sub(4) end
    content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
    local start = 1
    while true do
        local nl = content:find("\n", start, true)
        if not nl then
            lines[#lines + 1] = content:sub(start)
            break
        end
        lines[#lines + 1] = content:sub(start, nl - 1)
        start = nl + 1
    end
    return lines
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Port of ConfParser.Parse: split the content into sections. Each section is a
-- list of { name = ..., value = ... } pairs. A blank line begins a new section;
-- lines starting with '#' are comments and skipped.
local function parse_sections(content)
    local sections = {}
    local current = nil

    for _, raw in ipairs(split_lines(content)) do
        local line = trim(raw)

        if line:sub(1, 1) == "#" then
            -- comment, ignore
        elseif line == "" then
            current = { items = {} }
            sections[#sections + 1] = current
        else
            local eq = line:find("=", 1, true)
            if eq and current then
                local name = trim(line:sub(1, eq - 1))
                local value = trim(line:sub(eq + 1))
                current.items[#current.items + 1] = { name = name, value = value }
            end
        end
    end

    return sections
end

-- Section helpers (port of ConfSection.HasName / GetValue / GetValues).
local function section_get(section, name)
    for _, item in ipairs(section.items) do
        if item.name == name then
            return item.value
        end
    end
    return nil
end

local function section_get_all(section, name)
    local out = {}
    for _, item in ipairs(section.items) do
        if item.name == name then
            out[#out + 1] = item.value
        end
    end
    return out
end

-- Port of Conf.LoadConf: turn parsed sections into Setting tables.
function M.load(content)
    local settings = {}

    for _, section in ipairs(parse_sections(content)) do
        -- Skip empty sections (e.g. the leading blank line or accidental
        -- double blank lines), which carry no "name".
        local name = section_get(section, "name")
        if name then
            local setting = {
                options = {},
                option_name_width = 100,
                width = 0,
            }

            local default = section_get(section, "default")

            if section_get(section, "option") ~= nil then
                setting.kind = "option"
                setting.default = default
                setting.value = default

                for _, opt_value in ipairs(section_get_all(section, "option")) do
                    local opt = { option_setting = setting }
                    local sp = opt_value:find(" ", 1, true)
                    if sp then
                        opt.name = opt_value:sub(1, sp - 1)
                        opt.help = trim(opt_value:sub(sp))
                    else
                        opt.name = opt_value
                    end

                    if opt.name == setting.default then
                        opt.text = opt.name .. " (Default)"
                    end

                    setting.options[#setting.options + 1] = opt
                end
            else
                setting.kind = "string"
                setting.default = default or ""
            end

            setting.name = name
            setting.file = section_get(section, "file")
            setting.directory = section_get(section, "directory")
            setting.help = section_get(section, "help")
            setting.url = section_get(section, "url")
            setting.type = section_get(section, "type")
            -- optional: only show this setting when another setting (by name) is
            -- truthy. Used for master/sub toggles (e.g. remember-* depends on
            -- remember-state).
            setting.depends = section_get(section, "depends")

            local width = section_get(section, "width")
            if width then setting.width = tonumber(width) or 0 end

            local onw = section_get(section, "option-name-width")
            if onw then setting.option_name_width = tonumber(onw) or 100 end

            -- Help text in the data file escapes newlines as literal "\n".
            if setting.help and setting.help:find("\\n", 1, true) then
                setting.help = setting.help:gsub("\\n", "\n")
            end

            settings[#settings + 1] = setting
        end
    end

    return settings
end

return M
