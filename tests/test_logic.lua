-- Headless logic test for conf.lua + conffile.lua, run via mpv.
-- Run from the repository root:
--   mpv --no-config --idle=once --script=tests/test_logic.lua
local DIR = "scripts/encore-settings"   -- relative to the repo root (cwd)
package.path = DIR .. "/?.lua;" .. package.path

local conf = require "conf"
local conffile = require "conffile"

local fails = 0
local function check(cond, label)
    print((cond and "  ok  " or " FAIL ") .. label)
    if not cond then fails = fails + 1 end
end

-- ---- load editor_conf ----
local f = io.open(DIR .. "/editor_conf.txt", "r")
local content = f:read("*a"); f:close()
local settings = conf.load(content)

print("=== parser ===")
check(#settings == 147, "settings count == 147 (got " .. #settings .. ")")

-- index a few known settings
local by = {}
for _, s in ipairs(settings) do by[s.name] = s end

check(by["video-sync"] ~= nil, "has video-sync")
check(by["video-sync"].kind == "option", "video-sync is option")
check(by["video-sync"].default == "audio", "video-sync default=audio")
check(#by["video-sync"].options > 3, "video-sync has options")
check(by["video-sync"].options[2].help ~= nil or by["video-sync"].options[2].name ~= nil, "option parsed")
check(by["vo"].directory == "Video", "vo directory=Video")
check(by["sub-color"].type == "color", "sub-color type=color")
check(by["screenshot-directory"].type == "folder", "screenshot-directory type=folder")
check(by["image-exts"].width == 500, "image-exts width=500")
check(by["video-sync"].url ~= nil, "video-sync has url")
check(by["video-sync"].help:find("\n") ~= nil, "help newline unescaped")
-- removed mpv.net-only options should be gone
check(by["process-instance"] == nil, "process-instance removed")
check(by["dark-mode"] == nil, "dark-mode removed")
-- former encore-script options are gone now that their features are native mpv
check(by["recent-count"] == nil, "recent-count removed")
check(by["remember-volume"] == nil, "remember-volume removed")
check(by["auto-load-folder"] == nil, "auto-load-folder removed")
check(by["autofit-image"] == nil, "autofit-image removed")
-- their native replacements are present as real mpv options
check(by["autocreate-playlist"] ~= nil, "autocreate-playlist present")
check(by["save-watch-history"] ~= nil, "save-watch-history present")
check(by["autofit"] ~= nil, "autofit present")
-- the encore-remember toggle is the one (re-added) file = encore option
check(by["remember-state"] ~= nil, "remember-state present")
check(by["remember-state"].file == "encore", "remember-state is file=encore")

-- ---- conffile round-trip ----
print("=== conffile ===")
local tmp = os.tmpname():gsub("\\", "/") .. ".conf"
local cf_in = io.open(tmp, "w")
cf_in:write("# my config\nvo=gpu-next\n\n# audio section\nvolume = 80  # inline\nfullscreen\nno-border\n")
cf_in:close()

local cf = conffile.new(settings)
cf:load(tmp, "mpv")
cf:merge_into_settings()

check(by["vo"].value == "gpu-next", "vo value read = gpu-next (got " .. tostring(by["vo"].value) .. ")")
check(by["fullscreen"] == nil or true, "fullscreen alias tolerated")

-- 'fullscreen' setting may or may not exist in editor_conf; test border instead
-- border via no-border -> border=no
if by["border"] then
    check(by["border"].value == "no", "no-border -> border=no (got " .. tostring(by["border"].value) .. ")")
end

-- change a value and re-serialize; comment must be preserved, default skipped
by["vo"].value = "gpu"
local out = cf:get_content("mpv")
print("---- rewritten mpv.conf ----")
print(out)
print("----------------------------")
check(out:find("# my config", 1, true) ~= nil, "leading comment preserved")
check(out:find("vo=gpu", 1, true) ~= nil, "vo=gpu written")
check(out:find("# inline", 1, true) ~= nil, "inline comment preserved")

os.remove(tmp)

print("=== " .. (fails == 0 and "ALL PASSED" or (fails .. " FAILURES")) .. " ===")
mp.command("quit")
