
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

step("A day set that has not moved is not sent again")

do
    local settings = fresh()

    check("a book nothing has been sent for has no print",
        settings:historyFingerprint("digest") == nil, "already printed")

    settings:markHistorySynced("digest", "2026-08-23:600:12")
    check("the print is kept once a batch lands",
        settings:historyFingerprint("digest") == "2026-08-23:600:12",
        settings:historyFingerprint("digest"))

    settings:markHistorySynced("digest")
    check("a landing with no print given leaves the last one standing",
        settings:historyFingerprint("digest") == "2026-08-23:600:12",
        settings:historyFingerprint("digest"))

    settings:markHistorySynced("other", "2026-08-23:60:2")
    check("prints are per book",
        settings:historyFingerprint("digest") == "2026-08-23:600:12",
        settings:historyFingerprint("digest"))

    settings:forgetBook("digest")
    check("forgetting a book forgets what it last sent",
        settings:historyFingerprint("digest") == nil, "still printed")
    check("and leaves the other book alone",
        settings:historyFingerprint("other") == "2026-08-23:60:2",
        settings:historyFingerprint("other"))
end

step("What ran out of budget last time goes first next time")

do
    local settings = fresh()

    check("a book whose runs have all fitted defers nothing",
        settings:deferredUpload("digest") == nil, settings:deferredUpload("digest"))

    settings:markUploadDeferred("digest", "reading_time")
    check("an upload the budget cut off is remembered",
        settings:deferredUpload("digest") == "reading_time", settings:deferredUpload("digest"))

    settings:markUploadDeferred("digest", "highlights")
    check("the last one cut off is the one promoted, so the two take turns and neither starves",
        settings:deferredUpload("digest") == "highlights", settings:deferredUpload("digest"))

    settings:markUploadDeferred("other", "reading_time")
    check("the debt is per book, since the budget is spent per book",
        settings:deferredUpload("digest") == "highlights", settings:deferredUpload("digest"))

    settings:clearUploadDeferred("digest")
    check("a run that sends everything clears it",
        settings:deferredUpload("digest") == nil, settings:deferredUpload("digest"))
    check("and leaves the other book owing what it owed",
        settings:deferredUpload("other") == "reading_time", settings:deferredUpload("other"))

    settings:forgetBook("other")
    check("forgetting a book forgets what it owed",
        settings:deferredUpload("other") == nil, settings:deferredUpload("other"))
end

step("The order a run sends in follows the debt")

do
    local settings = fresh()

    check("with nothing owed, highlights keep their place at the front",
        settings:readingTimeFirst("digest") == false, settings:readingTimeFirst("digest"))

    settings:markUploadDeferred("digest", Settings.UPLOAD_READING_TIME)
    check("reading time cut off last run is promoted for the next one",
        settings:readingTimeFirst("digest") == true, settings:readingTimeFirst("digest"))

    settings:markUploadDeferred("digest", Settings.UPLOAD_HIGHLIGHTS)
    check("highlights cut off in their turn hand the front back, so neither starves",
        settings:readingTimeFirst("digest") == false, settings:readingTimeFirst("digest"))

    settings:markUploadDeferred("other", Settings.UPLOAD_READING_TIME)
    check("promotion is per book",
        settings:readingTimeFirst("digest") == false, settings:readingTimeFirst("digest"))
    check("and the other book keeps its promotion",
        settings:readingTimeFirst("other") == true, settings:readingTimeFirst("other"))
end

step("A batch the server has refused is not offered again unchanged")

do
    local settings = fresh()

    check("a book nothing has been refused for has no refusal",
        settings:refusedHistory("digest") == nil, settings:refusedHistory("digest"))

    settings:markHistoryRefused("digest", "2026-08-29:600:12")
    check("the refused set is remembered, so a timer tick cannot re-offer it forever",
        settings:refusedHistory("digest") == "2026-08-29:600:12", settings:refusedHistory("digest"))

    settings:markHistoryRefused("other", "2026-08-29:60:2")
    check("refusals are per book",
        settings:refusedHistory("digest") == "2026-08-29:600:12", settings:refusedHistory("digest"))

    settings:markHistoryRefused("digest", "2026-08-30:900:20")
    check("a day set that has moved on replaces it, so reading on is offered again",
        settings:refusedHistory("digest") == "2026-08-30:900:20", settings:refusedHistory("digest"))

    settings:forgetBook("digest")
    check("relinking a file forgets the refusal",
        settings:refusedHistory("digest") == nil, settings:refusedHistory("digest"))

    settings:disconnect()
    check("so does disconnecting",
        settings:refusedHistory("other") == nil, settings:refusedHistory("other"))
end

step("Introducing the device is due on the hour, not on every wake")

do
    local settings = fresh()

    check("a device nothing has heard from is due immediately",
        settings:isDeviceReportDue() == true, settings:isDeviceReportDue())

    settings:markDeviceReported()
    check("one that has just reported is not due again",
        settings:isDeviceReportDue() == false, settings:isDeviceReportDue())

    settings.store.data.last_device_report_at = os.time() - 3599
    check("and is still not due a second short of the hour",
        settings:isDeviceReportDue() == false, settings:isDeviceReportDue())

    settings.store.data.last_device_report_at = os.time() - 3600
    check("the hour makes it due again",
        settings:isDeviceReportDue() == true, settings:isDeviceReportDue())
end

step("A device that has never introduced itself says so")
do
    local settings = fresh()

    check("a fresh device has never reported",
        settings:lastDeviceReport() == nil, settings:lastDeviceReport())

    settings:markDeviceReported()
    check("reporting records when",
        type(settings:lastDeviceReport()) == "number", settings:lastDeviceReport())

    check("and the recorded moment is now, not the epoch",
        math.abs(settings:lastDeviceReport() - os.time()) <= 1, settings:lastDeviceReport())

    settings:disconnect()
    check("disconnecting forgets it, so a re-paired device introduces itself immediately",
        settings:lastDeviceReport() == nil, settings:lastDeviceReport())
end

harness.report()
