
package.path = "/plugin/seekquel.koplugin/?.lua;/plugin/spec/?.lua;" .. package.path

require("stubs")

local Settings = require("seekquel_settings")
local harness = require("harness")

local check = harness.check
local step = harness.step

local function fresh()
    local settings = Settings:new()

    settings.store.data = {}

    return settings
end

step("The slowest call is a window, not a souvenir")

do
    local settings = fresh()

    settings:recordTiming("PUT /device", 8)
    local reported = settings:slowestCall()

    check("a call is recorded with the label and the seconds",
        reported ~= nil and reported.label == "PUT /device" and reported.seconds == 8,
        reported and reported.seconds)

    settings:recordTiming("POST /sessions", 3)
    check("a faster call does not displace the slowest",
        settings:slowestCall().seconds == 8, settings:slowestCall().seconds)

    settings:recordTiming("POST /highlights", 11)
    check("a slower one does",
        settings:slowestCall().seconds == 11, settings:slowestCall().seconds)

    settings:clearTiming(settings:slowestCall())
    check("reporting it clears it, so the next report describes the period since",
        settings:slowestCall() == nil, "still stored")
end

do
    local settings = fresh()

    local nothing_pending = settings:slowestCall()
    check("nothing is pending at report time", nothing_pending == nil, "something stored")

    settings:recordTiming("PUT /device", 8)
    settings:clearTiming(nothing_pending)

    check("a call recorded during the report it was not part of survives",
        settings:slowestCall() ~= nil and settings:slowestCall().seconds == 8,
        settings:slowestCall() and settings:slowestCall().seconds)
end

do
    local settings = fresh()

    settings:recordTiming("PUT /device", 6)
    local reported = settings:slowestCall()

    settings:recordTiming("POST /highlights", 30)
    settings:clearTiming(reported)

    check("a slower call recorded mid-report is not cleared by that report",
        settings:slowestCall() ~= nil and settings:slowestCall().seconds == 30,
        settings:slowestCall() and settings:slowestCall().seconds)
end

do
    local settings = fresh()

    settings:clearTiming(nil)
    check("clearing an empty record is harmless", settings:slowestCall() == nil, "invented one")
end

step("The sync interval")

do
    local settings = fresh()

    check("it defaults to fifteen minutes", settings:syncIntervalMinutes() == 15,
        settings:syncIntervalMinutes())

    settings:setSyncIntervalMinutes(30)
    check("a choice is kept", settings:syncIntervalMinutes() == 30, settings:syncIntervalMinutes())

    settings:setSyncIntervalMinutes(0)
    check("off is a real answer and does not fall back to the default",
        settings:syncIntervalMinutes() == 0, settings:syncIntervalMinutes())

    settings.store.data.sync_interval_minutes = "not a number"
    check("an unreadable value falls back rather than arming a broken timer",
        settings:syncIntervalMinutes() == 15, settings:syncIntervalMinutes())
end

step("Disconnecting leaves nothing about the server behind")

do
    local settings = fresh()

    settings:setKey("ABCD1234ABCD1234")
    settings:recordTiming("PUT /device", 61)
    settings:markUnreachable(120)
    settings:markHistorySynced("digest")

    settings:disconnect()

    check("the key goes", settings:isConnected() == false, "still connected")
    check("the slowest call goes with it", settings:slowestCall() == nil, "still stored")
    check("the backoff goes with it", settings:isUnreachable() == false, "still backing off")
    check("the per-book marks go too", settings:historySyncedAt("digest") == nil, "still marked")
end

step("The unreachable window")

do
    local settings = fresh()

    check("a device that has failed nothing is reachable", settings:isUnreachable() == false, "backing off")

    settings:markUnreachable(120)
    check("a failure closes it", settings:isUnreachable() == true, "still reachable")

    settings:clearUnreachable()
    check("waking or reconnecting opens it again", settings:isUnreachable() == false, "still backing off")
end

harness.report()
