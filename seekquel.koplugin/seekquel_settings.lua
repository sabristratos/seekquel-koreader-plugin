local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local Settings = {}
Settings.__index = Settings

local FILENAME = "seekquel.lua"

local DEFAULT_SYNC_URL = "https://api.seekquel.app/koreader"
local DEFAULT_PAGES_BEFORE_PUSH = 60

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

function Settings:hasSyncedHistory(digest)
    local synced = self:get("history_synced", {})

    return synced[digest] == true
end

function Settings:markHistorySynced(digest)
    local synced = self:get("history_synced", {})
    synced[digest] = true
    self:set("history_synced", synced)
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
