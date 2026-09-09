package.path = "/plugin/seekquel.koplugin/?.lua;" .. package.path

local real_require = require

require = function(name)
    if name == "ffi/archiver" then
        error("module '" .. name .. "' not found (simulated)", 2)
    end

    return real_require(name)
end

local Updater = real_require("seekquel_updater")

require = real_require

local ROOT = "/tmp/seekquel-updater-noarchiver-spec"

local passed, failed = 0, 0

local function check(label, condition, detail)
    if condition then
        passed = passed + 1
        print("  ok   " .. label)
    else
        failed = failed + 1
        print("  FAIL " .. label .. (detail and ("  <- " .. tostring(detail)) or ""))
    end
end

local function step(label)
    print("\n" .. label)
end

step("a KOReader without ffi/archiver still loads the add-on")
check("the module loads", type(Updater) == "table")
check("version arithmetic works", Updater.isNewer("1.7.1", "1.7.0"))
check("name checking works", Updater.isSafeName("main.lua"))

step("and it says it cannot replace itself")
check("canInstall is false", Updater.canInstall() == false)

step("an update is refused before anything is downloaded or written")
local ok, reason = Updater:new({}):install(ROOT, { ["main.lua"] = "x" })

check("it refuses", not ok)
check("it names the reason", reason == "too_old", reason)
check("it wrote nothing", io.open(ROOT .. ".sq-staging", "r") == nil)

print(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
