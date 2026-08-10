package.path = "/plugin/seekquel.koplugin/?.lua;" .. package.path

local Archiver = require("ffi/archiver")
local Updater = require("seekquel_updater")
local lfs = require("libs/libkoreader-lfs")
local sha256 = require("ffi/sha2").sha256

local ROOT = "/tmp/seekquel-updater-spec"

local BODIES = {
    ["main.lua"] = 'local VERSION = "9.9.9"\nreturn {}\n',
    ["seekquel_api.lua"] = "return { fresh = true }\n",
    ["nested/deep.lua"] = "return 1\n",
}

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

local function write(path, body)
    local handle = assert(io.open(path, "wb"))
    handle:write(body)
    handle:close()
end

local function read(path)
    local handle = io.open(path, "rb")

    if handle == nil then
        return nil
    end

    local body = handle:read("*a")
    handle:close()

    return body
end

local function buildArchive(path)
    local writer = Archiver.Writer:new({})
    assert(writer:open(path, "zip"), "could not create the fixture archive")

    for name, body in pairs(BODIES) do
        writer:addFileFromMemory("seekquel.koplugin/" .. name, body)
    end

    writer:addFileFromMemory("LICENSE", "not inside the plugin directory")
    writer:addFileFromMemory("README.md", "also not")
    writer:close()
end

local function manifest()
    local files = {}

    for name, body in pairs(BODIES) do
        files[name] = sha256(body)
    end

    return files
end

local function freshInstall(name)
    local path = ROOT .. "/" .. name
    os.execute("rm -rf " .. path .. " && mkdir -p " .. path)
    write(path .. "/main.lua", "the copy that is already running")

    return path
end

os.execute("rm -rf " .. ROOT .. " && mkdir -p " .. ROOT)
buildArchive(ROOT .. "/plugin.zip")

local updater = Updater:new({
    downloadPlugin = function(_, destination)
        write(destination, read(ROOT .. "/plugin.zip"))

        return true
    end,
})

step("a version is only newer when it is actually newer")
check("a newer patch", Updater.isNewer("1.2.1", "1.2.0"))
check("a newer minor beats a higher patch", Updater.isNewer("1.3.0", "1.2.9"))
check("the same version is not", not Updater.isNewer("1.2.0", "1.2.0"))
check("an older version is not", not Updater.isNewer("1.1.9", "1.2.0"))
check("a version the server did not send is not", not Updater.isNewer(nil, "1.2.0"))
check("something that is not a version is not", not Updater.isNewer("unknown", "1.2.0"))
check("a shorter equal prefix is not", not Updater.isNewer("1.2", "1.2.0"))
check("a value that is not a version at all is not", not Updater.isNewer({}, "1.2.0"))
check("a table cannot pass as a version through its address", not Updater.isNewer(setmetatable({}, {}), "1.2.0"))

step("a manifest cannot name a file outside the add-on")
check("a plain file is allowed", Updater.isSafeName("main.lua"))
check("a nested file is allowed", Updater.isSafeName("lib/thing.lua"))
check("traversal is refused", not Updater.isSafeName("../../etc/passwd"))
check("an absolute path is refused", not Updater.isSafeName("/etc/passwd"))
check("traversal in the middle is refused", not Updater.isSafeName("a/../../b"))
check("an empty name is refused", not Updater.isSafeName(""))
check("a name that is not a string is refused", not Updater.isSafeName(nil))
check("a shell character is refused", not Updater.isSafeName("main.lua; rm -rf /"))

step("a good download replaces the add-on")
local live = freshInstall("live")
write(live .. "/dropped.lua", "a file the new version does not have")

local ok, reason = updater:install(live, manifest())

check("it reports success", ok, reason)
check("every file is the new one", read(live .. "/main.lua") == BODIES["main.lua"])
check("a nested file arrives", read(live .. "/nested/deep.lua") == BODIES["nested/deep.lua"])
check("a file the new version drops is gone", read(live .. "/dropped.lua") == nil)
check("nothing outside the add-on directory is written", read(live .. "/LICENSE") == nil)
check("no staging directory is left behind", lfs.attributes(live .. ".sq-staging") == nil)
check("no previous directory is left behind", lfs.attributes(live .. ".sq-previous") == nil)
check("no download is left behind", lfs.attributes(live .. ".sq-download") == nil)

step("a download that does not match the manifest changes nothing")
local corrupt = freshInstall("corrupt")
local ok2, reason2 = updater:install(corrupt, { ["main.lua"] = sha256("something else") })

check("it reports failure", not ok2)
check("it says the download was corrupt", reason2 == "corrupt", reason2)
check("the running copy is untouched", read(corrupt .. "/main.lua") == "the copy that is already running")
check("nothing is left staged", lfs.attributes(corrupt .. ".sq-staging") == nil)

step("a manifest naming a file the download lacks changes nothing")
local short = freshInstall("short")
local expected = manifest()
expected["absent.lua"] = sha256("x")
local ok3, reason3 = updater:install(short, expected)

check("it reports failure", not ok3)
check("it says the download was incomplete", reason3 == "incomplete", reason3)
check("the running copy is untouched", read(short .. "/main.lua") == "the copy that is already running")

step("a hostile manifest is refused before anything is downloaded")
local hostile = freshInstall("hostile")
local ok4, reason4 = updater:install(hostile, { ["../../../etc/passwd"] = sha256("x") })

check("it reports failure", not ok4)
check("it says the manifest was bad", reason4 == "bad_manifest", reason4)
check("the running copy is untouched", read(hostile .. "/main.lua") == "the copy that is already running")

step("a swap that cannot be completed says the add-on is stranded")
local stranded = freshInstall("stranded")
local blocked = Updater:new({
    downloadPlugin = function(_, destination)
        write(destination, read(ROOT .. "/plugin.zip"))

        return true
    end,
})

local realRename = os.rename
local renames = 0
os.rename = function(from, to)
    renames = renames + 1

    if renames == 1 then
        return realRename(from, to)
    end

    return nil
end

local ok5, reason5 = blocked:install(stranded, manifest())
os.rename = realRename

check("it reports failure", not ok5)
check("it says the add-on is stranded rather than that nothing happened", reason5 == "stranded", reason5)
check("the old copy is still on disk under the previous name", read(stranded .. ".sq-previous/main.lua") == "the copy that is already running")

print(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
