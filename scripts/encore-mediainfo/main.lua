-- encore-mediainfo — a detailed media report for the current file.
--
-- mpv.net had `show-media-info`: a static report of the container and streams,
-- distinct from playback statistics. mpv's own stats.lua shows live render/timing
-- metrics; this instead summarises WHAT the file is — container, size, duration,
-- overall bitrate, and every video/audio/subtitle stream with codec, resolution,
-- frame rate, colour/HDR, channels, sample rate and language.
--
-- Built entirely from mpv properties (track-list + video-params), so it needs no
-- external tool and works on every platform.
--
-- Shown in the shared two-pane panel (script-modules/encore-panel.lua): streams
-- are categories on the left, fields are rows on the right, the focused field's
-- full value fills the detail pane, and Enter copies a value to the clipboard.
--
-- Bindings (script name "encore_mediainfo"):
--   script-binding encore_mediainfo/show
-- and the same as a script-message:  script-message-to encore_mediainfo show

package.path = mp.command_native({ "expand-path", "~~/script-modules/?.lua" })
    .. ";" .. package.path

local msg = require "mp.msg"
local panel = require "encore-panel"

-- ---------------------------------------------------------------------------
-- Formatting helpers
-- ---------------------------------------------------------------------------

local function human_size(bytes)
    if not bytes or bytes <= 0 then return nil end
    local units = { "B", "KiB", "MiB", "GiB", "TiB" }
    local n, i = bytes, 1
    while n >= 1024 and i < #units do n = n / 1024; i = i + 1 end
    if i == 1 then return string.format("%d %s", n, units[i]) end
    return string.format("%.2f %s", n, units[i])
end

local function human_duration(s)
    if not s or s <= 0 then return nil end
    s = math.floor(s + 0.5)
    local h, m, sec = math.floor(s / 3600), math.floor((s % 3600) / 60), s % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, sec) end
    return string.format("%d:%02d", m, sec)
end

local function human_bitrate(bits_per_sec)
    if not bits_per_sec or bits_per_sec <= 0 then return nil end
    if bits_per_sec >= 1e6 then return string.format("%.2f Mb/s", bits_per_sec / 1e6) end
    return string.format("%d kb/s", math.floor(bits_per_sec / 1000 + 0.5))
end

-- ---------------------------------------------------------------------------
-- Report builder — an ordered list of sections, each with key/value fields
-- ---------------------------------------------------------------------------

local Report = {}
Report.__index = Report

local function new_report()
    return setmetatable({ sections = {} }, Report)
end

function Report:section(title)
    self.cur = { title = title, fields = {} }
    self.sections[#self.sections + 1] = self.cur
end

-- Add a { key, value } field to the current section (skips nil/empty values).
function Report:field(key, value)
    if value == nil or value == "" then return end
    self.cur.fields[#self.cur.fields + 1] = { key = key, value = tostring(value) }
end

local function flags_of(track)
    local f = {}
    if track.default then f[#f + 1] = "default" end
    if track.forced then f[#f + 1] = "forced" end
    if track.external then f[#f + 1] = "external" end
    if track["hearing-impaired"] then f[#f + 1] = "hearing-impaired" end
    if track["visual-impaired"] then f[#f + 1] = "visual-impaired" end
    if #f == 0 then return nil end
    return table.concat(f, ", ")
end

local function codec_string(track)
    local c = track["codec-desc"] or track.codec
    if c and track["codec-profile"] then
        return c .. " (" .. track["codec-profile"] .. ")"
    end
    return c
end

-- Count tracks of each type, e.g. "1 video, 2 audio, 3 subtitle".
local function track_summary(tracks)
    local n = { video = 0, audio = 0, sub = 0 }
    for _, t in ipairs(tracks) do if n[t.type] then n[t.type] = n[t.type] + 1 end end
    local parts = {}
    if n.video > 0 then parts[#parts + 1] = n.video .. " video" end
    if n.audio > 0 then parts[#parts + 1] = n.audio .. " audio" end
    if n.sub > 0 then parts[#parts + 1] = n.sub .. " subtitle" end
    if #parts == 0 then return nil end
    return table.concat(parts, ", ")
end

-- Tidy a raw metadata key ("creation_time" -> "Creation time") for display.
local function nice_key(k)
    k = k:gsub("[_%-]", " "):lower()
    return (k:gsub("^%l", string.upper))
end

local function add_video(r, t, vparams)
    r:section(string.format("Video #%d%s", t["src-id"] or t.id or 0,
        t.selected and "  (active)" or ""))
    r:field("Codec", codec_string(t))
    r:field("Decoder", t["decoder-desc"])
    if t.selected then
        local hw = mp.get_property("hwdec-current")
        if hw and hw ~= "" and hw ~= "no" then r:field("Hardware decoder", hw) end
    end

    -- storage resolution, and the display resolution when it differs (anamorphic)
    if t["demux-w"] and t["demux-h"] then
        r:field("Resolution", string.format("%d × %d", t["demux-w"], t["demux-h"]))
    end
    if vparams and vparams.dw and vparams.dh
        and (vparams.dw ~= vparams.w or vparams.dh ~= vparams.h) then
        r:field("Display size", string.format("%d × %d", vparams.dw, vparams.dh))
    end
    if vparams then
        r:field("Aspect ratio", vparams["aspect-name"])
        -- pixel aspect ratio: only meaningful (and shown) for anamorphic content
        local par = vparams.par
        if par and math.abs(par - 1) > 0.01 then
            r:field("Pixel aspect", string.format("%.3f", par))
        end
    end
    local rot = (vparams and vparams.rotate) or t["demux-rotation"]
    if rot and rot ~= 0 then r:field("Rotation", rot .. "°") end

    local fps = t["demux-fps"]
    if fps then r:field("Frame rate", string.format("%.3f fps", fps)) end
    r:field("Bitrate", human_bitrate(t["demux-bitrate"]))

    -- colour / HDR detail is only exposed for the *selected* video track
    if t.selected and vparams then
        r:field("Pixel format", vparams.pixelformat or vparams["hw-pixelformat"])
        if vparams["average-bpp"] then r:field("Bits per pixel", vparams["average-bpp"]) end
        r:field("Chroma location", vparams["chroma-location"])
        r:field("Colour range", vparams.colorlevels)
        r:field("Primaries", vparams.primaries)
        r:field("Transfer", vparams.gamma)
        r:field("Matrix", vparams.colormatrix)
        if vparams["sig-peak"] and vparams["sig-peak"] > 1 then
            r:field("HDR peak", string.format("%.0f%% of SDR", vparams["sig-peak"] * 100))
        end
        if vparams["max-luma"] and vparams["max-luma"] > 0 then
            r:field("Mastering luminance", string.format("%g – %g cd/m²",
                vparams["min-luma"] or 0, vparams["max-luma"]))
        end
        if vparams["max-cll"] and vparams["max-cll"] > 0 then
            r:field("MaxCLL / MaxFALL", string.format("%g / %g cd/m²",
                vparams["max-cll"], vparams["max-fall"] or 0))
        end
    end

    r:field("Language", t.lang)
    r:field("Title", t.title)
    r:field("Flags", flags_of(t))
end

local function add_audio(r, t, aparams)
    r:section(string.format("Audio #%d%s", t["src-id"] or t.id or 0,
        t.selected and "  (active)" or ""))
    r:field("Codec", codec_string(t))
    r:field("Decoder", t["decoder-desc"])
    local ch = t["demux-channel-count"]
    if ch then
        r:field("Channels", t["demux-channels"]
            and string.format("%d (%s)", ch, t["demux-channels"]) or tostring(ch))
    end
    local sr = t["demux-samplerate"]
    if sr then r:field("Sample rate", string.format("%d Hz", sr)) end
    if t.selected and aparams then r:field("Sample format", aparams.format) end
    r:field("Bitrate", human_bitrate(t["demux-bitrate"]))
    r:field("Language", t.lang)
    r:field("Title", t.title)
    r:field("Flags", flags_of(t))
end

local function add_sub(r, t)
    r:section(string.format("Subtitle #%d%s", t["src-id"] or t.id or 0,
        t.selected and "  (active)" or ""))
    r:field("Codec", codec_string(t))
    r:field("Language", t.lang)
    r:field("Title", t.title)
    r:field("File", t["external-filename"])
    r:field("Flags", flags_of(t))
end

-- A "Tags" section listing container metadata (artist/album/encoder/comment/…),
-- sorted, skipping the title we already showed and over-long values (lyrics etc.).
local function add_tags(r)
    local meta = mp.get_property_native("metadata")
    if type(meta) ~= "table" then return end
    local keys = {}
    for k in pairs(meta) do
        if k:lower() ~= "title" then keys[#keys + 1] = k end
    end
    if #keys == 0 then return end
    table.sort(keys, function(a, b) return a:lower() < b:lower() end)
    r:section("Tags")
    for _, k in ipairs(keys) do
        local v = tostring(meta[k]):gsub("[\r\n]+", " ")
        if #v > 200 then v = v:sub(1, 197) .. "…" end
        r:field(nice_key(k), v)
    end
end

local function build_report()
    local r = new_report()
    local tracks = mp.get_property_native("track-list") or {}

    -- General -----------------------------------------------------------------
    r:section("General")
    r:field("Title", mp.get_property("media-title"))
    r:field("File", mp.get_property("filename"))
    local path = mp.get_property("path")
    if path and path ~= mp.get_property("filename") then r:field("Path", path) end
    r:field("Format", mp.get_property("file-format"))

    local size = mp.get_property_number("file-size")
    r:field("Size", human_size(size))
    local duration = mp.get_property_number("duration")
    r:field("Duration", human_duration(duration))
    if size and duration and duration > 0 then
        r:field("Overall bitrate", human_bitrate(size * 8 / duration))
    end
    r:field("Streams", track_summary(tracks))
    local chapters = mp.get_property_number("chapter-list/count")
    if chapters and chapters > 0 then r:field("Chapters", chapters) end
    local editions = mp.get_property_number("edition-list/count")
    if editions and editions > 1 then r:field("Editions", editions) end

    -- Per-stream --------------------------------------------------------------
    local vparams = mp.get_property_native("video-params")    -- selected video only
    local aparams = mp.get_property_native("audio-params")    -- selected audio only

    for _, t in ipairs(tracks) do
        if t.type == "video" and not t.albumart then
            add_video(r, t, t.selected and vparams or nil)
        elseif t.type == "audio" then
            add_audio(r, t, t.selected and aparams or nil)
        elseif t.type == "sub" then
            add_sub(r, t)
        end
    end

    -- Container tags ----------------------------------------------------------
    add_tags(r)

    return r.sections
end

-- ---------------------------------------------------------------------------
-- Command
-- ---------------------------------------------------------------------------

local active        -- single-instance guard

local function show()
    if mp.get_property_native("idle-active") or not mp.get_property("path") then
        mp.osd_message("Nothing is playing.", 2)
        return
    end
    if active and not active.closed then return end

    local sections = build_report()

    -- flatten sections -> panel items (one per field), and log a copy at verbose
    local items = {}
    for _, sec in ipairs(sections) do
        msg.verbose("── " .. sec.title .. " ──")
        for _, f in ipairs(sec.fields) do
            msg.verbose("  " .. f.key .. ": " .. f.value)
            items[#items + 1] = { name = f.key, value = f.value, cat = sec.title }
        end
    end

    active = panel.open({
        title = "media info",
        items = items,
        category_of = function(_, it) return it.cat end,
        label_of    = function(_, it) return it.name end,
        value_of    = function(_, it) return it.value end,
        marker_of   = function() return "" end,
        search_text = function(_, it) return (it.name .. " " .. it.value .. " " .. it.cat):lower() end,
        detail = function(_, it)
            return {
                { t = "title", text = it.name },
                { t = "sub", text = it.cat },
                { t = "gap" },
                { t = "text", text = it.value },
            }
        end,
        on_activate = function(_, it)
            mp.set_property("clipboard/text", it.value)
            mp.osd_message("Copied: " .. it.value, 2)
        end,
        empty_detail = "Select a field to see its full value.",
    })
end

mp.add_key_binding(nil, "show", show)
mp.register_script_message("show", show)
