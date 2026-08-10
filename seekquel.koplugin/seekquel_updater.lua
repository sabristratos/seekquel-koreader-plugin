local Archiver = require("ffi/archiver")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local sha256 = require("ffi/sha2").sha256
local util = require("util")

local Updater = {}
Updater.__index = Updater

local PLUGIN_PREFIX = "seekquel.koplugin/"
local STAGING_SUFFIX = ".sq-staging"
local PREVIOUS_SUFFIX = ".sq-previous"
local DOWNLOAD_SUFFIX = ".sq-download"
local SAFE_NAME = "^[%w%._%-/]+$"

function Updater:new(api)
    return setmetatable({ api = api }, self)
end

function Updater.parse(version)
    local parts = {}

    if type(version) ~= "string" and type(version) ~= "number" then
        return parts
    end

    for chunk in tostring(version):gmatch("%d+") do
        table.insert(parts, tonumber(chunk))
    end

    return parts
end

function Updater.isNewer(candidate, current)
    local left = Updater.parse(candidate)
    local right = Updater.parse(current)

    if #left == 0 then
        return false
    end

    for index = 1, math.max(#left, #right) do
        local a = left[index] or 0
        local b = right[index] or 0

        if a ~= b then
            return a > b
        end
    end

    return false
end

function Updater.isSafeName(name)
    return type(name) == "string"
        and name ~= ""
        and name:match(SAFE_NAME) ~= nil
        and not name:find("%.%.")
        and name:sub(1, 1) ~= "/"
end

function Updater:install(path, files)
    if type(path) ~= "string" or path == "" then
        return false, "no_path"
    end

    if type(files) ~= "table" or next(files) == nil then
        return false, "no_manifest"
    end

    for name in pairs(files) do
        if not self.isSafeName(name) then
            return false, "bad_manifest"
        end
    end

    local staging = path .. STAGING_SUFFIX
    local archive = path .. DOWNLOAD_SUFFIX

    local ok, reason = self:stage(staging, archive, files)

    os.remove(archive)

    if not ok then
        ffiUtil.purgeDir(staging)

        return false, reason
    end

    return self:swap(path, staging)
end

function Updater:stage(staging, archive, files)
    ffiUtil.purgeDir(staging)

    if not util.makePath(staging) then
        return false, "not_writable"
    end

    if not self.api:downloadPlugin(archive) then
        return false, "download_failed"
    end

    if not self:extract(archive, staging) then
        return false, "unreadable_archive"
    end

    return self:verify(staging, files)
end

function Updater:extract(archive, staging)
    local reader = Archiver.Reader:new()

    if not reader:open(archive) then
        return false
    end

    local extracted = 0

    for entry in reader:iterate() do
        local name = entry.path:sub(#PLUGIN_PREFIX + 1)

        if entry.mode == "file" and entry.path:sub(1, #PLUGIN_PREFIX) == PLUGIN_PREFIX and self.isSafeName(name) then
            local destination = staging .. "/" .. name

            util.makePath(destination:match("^(.*)/[^/]+$") or staging)

            if not reader:extractToPath(entry.path, destination) then
                logger.warn("Seekquel: could not extract", entry.path)
                reader:close()

                return false
            end

            extracted = extracted + 1
        end
    end

    reader:close()

    return extracted > 0
end

function Updater:verify(staging, files)
    for name, expected in pairs(files) do
        local handle = io.open(staging .. "/" .. name, "rb")

        if handle == nil then
            logger.warn("Seekquel: the download is missing", name)

            return false, "incomplete"
        end

        local bytes = handle:read("*a")
        handle:close()

        if bytes == nil or sha256(bytes) ~= expected then
            logger.warn("Seekquel: the download does not match for", name)

            return false, "corrupt"
        end
    end

    return true
end

function Updater:swap(path, staging)
    local previous = path .. PREVIOUS_SUFFIX

    ffiUtil.purgeDir(previous)

    if not os.rename(path, previous) then
        ffiUtil.purgeDir(staging)

        return false, "not_writable"
    end

    if not os.rename(staging, path) then
        local restored = os.rename(previous, path)
        ffiUtil.purgeDir(staging)

        if not restored then
            logger.warn("Seekquel: the add-on is at", previous, "and could not be moved back")

            return false, "stranded"
        end

        return false, "not_writable"
    end

    ffiUtil.purgeDir(previous)

    return true
end

return Updater
