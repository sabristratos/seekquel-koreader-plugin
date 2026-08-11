local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local Settings = {}
Settings.__index = Settings

local FILENAME = "seekquel.lua"

local DEFAULT_SYNC_URL = "https://api.seekquel.app/koreader"
local DEFAULT_PAGES_BEFORE_PUSH = 60
local SECONDS_PER_DAY = 86400
local LEGACY_HISTORY_DAYS = 7

local PER_BOOK_KEYS = {
    "history_synced",
    "details_sent",
    "cover_sent",
    "highlights_sent",
    "status_seen",
}

function Settings:new()
    local instance = setmetatable({}, self)
    instance.store = LuaSettings:open(DataStorage:getSettingsDir() .. "/" .. FILENAME)

    return instance
end

function Settings:get(key, fallback)
    local value = self.store:readSetting(key)

    if value == nil then
        return fallback
    end

    return value
end

function Settings:set(key, value)
    self.store:saveSetting(key, value)
    self.store:flush()
end

function Settings:syncUrl()
    return self:get("sync_url", DEFAULT_SYNC_URL)
end

function Settings:setSyncUrl(value)
    self:set("sync_url", value)
end

function Settings:key()
    return self:get("key")
end

function Settings:setKey(value)
    self:set("key", value)
end

function Settings:isConnected()
    local key = self:key()

    return key ~= nil and key ~= ""
end

function Settings:disconnect()
    self:set("key", nil)
    self:set("device_id", nil)
    self:set("applied_settings_revision", nil)
    self:set("timezone_offset", nil)
    self:set("latest_version", nil)
    self:set("pending_restart", nil)

    for _index, key in ipairs(PER_BOOK_KEYS) do
        self:set(key, nil)
    end
end

function Settings:isEnabled(key, fallback)
    return self:get(key, fallback) == true
end

function Settings:toggle(key, fallback)
    local next_value = not self:isEnabled(key, fallback)
    self:set(key, next_value)

    return next_value
end

function Settings:pagesBeforePush()
    return self:get("pages_before_push", DEFAULT_PAGES_BEFORE_PUSH)
end

function Settings:markBusy(label)
    self:set("busy", { label = label, at = os.time() })
end

function Settings:clearBusy()
    self:set("busy", nil)
end

function Settings:takeInterruption()
    local busy = self:get("busy")

    if busy == nil then
        return nil
    end

    self:set("busy", nil)
    self:set("last_interruption", busy)

    return busy
end

function Settings:lastInterruption()
    return self:get("last_interruption")
end

function Settings:clearInterruption()
    self:set("last_interruption", nil)
end

function Settings:recordTiming(label, seconds)
    local slowest = self:get("slowest_call")

    if slowest ~= nil and slowest.seconds >= seconds then
        return
    end

    self:set("slowest_call", { label = label, seconds = seconds, at = os.time() })
end

function Settings:slowestCall()
    return self:get("slowest_call")
end

function Settings:lastSync()
    return self:get("last_sync_at"), self:get("last_sync_ok")
end

function Settings:recordSync(ok)
    self:set("last_sync_at", os.time())
    self:set("last_sync_ok", ok == true)
end

function Settings:appliedSettingsRevision()
    return tonumber(self:get("applied_settings_revision", 0)) or 0
end

function Settings:markSettingsApplied(revision)
    self:set("applied_settings_revision", revision)
end

function Settings:latestVersion()
    return self:get("latest_version")
end

function Settings:setLatestVersion(value)
    self:set("latest_version", value)
end

function Settings:pendingRestart()
    return self:get("pending_restart")
end

function Settings:setPendingRestart(from, to)
    self:set("pending_restart", from and { from = from, to = to } or nil)
end

function Settings:timezoneOffset()
    return tonumber(self:get("timezone_offset"))
end

function Settings:setTimezoneOffset(minutes)
    self:set("timezone_offset", minutes)
end

function Settings:historySyncedAt(digest)
    local synced = self:get("history_synced", {})
    local stamp = synced[digest]

    if stamp == true then
        return os.time() - (LEGACY_HISTORY_DAYS * SECONDS_PER_DAY)
    end

    return tonumber(stamp)
end

function Settings:markHistorySynced(digest)
    local synced = self:get("history_synced", {})
    synced[digest] = os.time()
    self:set("history_synced", synced)
end

function Settings:forgetBook(digest)
    for _index, key in ipairs(PER_BOOK_KEYS) do
        local stored = self:get(key, {})

        if stored[digest] ~= nil then
            stored[digest] = nil
            self:set(key, stored)
        end
    end
end

function Settings:lastStatus(digest)
    local seen = self:get("status_seen", {})

    return seen[digest]
end

function Settings:markStatus(digest, status)
    local seen = self:get("status_seen", {})
    seen[digest] = status
    self:set("status_seen", seen)
end

function Settings:sentHighlights(digest)
    local sent = self:get("highlights_sent", {})

    return sent[digest] or {}
end

function Settings:markHighlightsSent(digest, fingerprints)
    local sent = self:get("highlights_sent", {})
    local book = sent[digest] or {}

    for external_id, fingerprint in pairs(fingerprints) do
        book[external_id] = fingerprint
    end

    sent[digest] = book
    self:set("highlights_sent", sent)
end

function Settings:hasSentDetails(digest)
    local sent = self:get("details_sent", {})

    return sent[digest] == true
end

function Settings:markDetailsSent(digest)
    local sent = self:get("details_sent", {})
    sent[digest] = true
    self:set("details_sent", sent)
end

function Settings:hasSentCover(digest)
    local sent = self:get("cover_sent", {})

    return sent[digest] == true
end

function Settings:markCoverSent(digest)
    local sent = self:get("cover_sent", {})
    sent[digest] = true
    self:set("cover_sent", sent)
end

return Settings
