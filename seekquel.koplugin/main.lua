local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local QRMessage = require("ui/widget/qrmessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Annotations = require("seekquel_annotations")
local Api = require("seekquel_api")
local Chapters = require("seekquel_chapters")
local Metadata = require("seekquel_metadata")
local Position = require("seekquel_position")
local Recap = require("seekquel_recap")
local Settings = require("seekquel_settings")
local Stats = require("seekquel_stats")
local Updater = require("seekquel_updater")

local Seekquel = WidgetContainer:extend({
    name = "seekquel",
    is_doc_only = false,
})

local VERSION = "1.10.1"
local PAIRING_POLL_SECONDS = 3
local PAIRING_MIN_POLL_SECONDS = 2
local PAIRING_FALLBACK_SECONDS = 900
local PUSH_DEBOUNCE_SECONDS = 5
local MANUAL_SYNC_REPEAT_SECONDS = 3
local OPEN_DELAY_SECONDS = 3
local RESUME_SETTLE_DELAY_SECONDS = 0.1
local METADATA_DELAY_SECONDS = 20
local SYNC_BUDGET_SECONDS = 20
local LEAVING_BUDGET_SECONDS = 5
local HISTORY_OVERLAP_DAYS = 2
local SECONDS_PER_DAY = 86400
local SECONDS_PER_MINUTE = 60
local SEARCH_MIN_LENGTH = 2
local APP_QR_SIZE = 400
local CLIENT_ERROR_FLOOR = 400
local SERVER_ERROR_FLOOR = 500

local TIME_DISABLED = "disabled"
local TIME_NONE = "none"
local TIME_SENT = "sent"
local TIME_REFUSED = "refused"
local TIME_WAITING = "waiting"

local SYNC_INTERVALS = { 0, 5, 15, 30, 60 }
local APP_LINK_URL = "https://seekquel.app/links"

local STATUSES = {
    { key = "want_to_read", label = _("Want to read") },
    { key = "reading", label = _("Reading") },
    { key = "read", label = _("Read") },
    { key = "did_not_finish", label = _("Did not finish") },
}

local KOREADER_STATUSES = {
    complete = "read",
    abandoned = "did_not_finish",
    reading = "reading",
}

local NO_STATUS = "none"

local NOT_LINKED_TEXT = _("Nothing is sent for this book until you tell Seekquel which book it is.")

local RATINGS = { 1, 2, 3, 4, 5 }

local SWITCHES = {
    { key = "send_reading_time", default = true, label = _("Send reading time") },
    { key = "send_highlights", default = true, label = _("Send highlights and notes") },
    { key = "send_status", default = true, label = _("Send status changes from this device") },
    { key = "finish_at_end", default = true, label = _("Mark finished at the end of a book") },
    { key = "auto_sync", default = true, label = _("Sync while reading") },
    { key = "auto_sync_highlights", default = true, label = _("Send highlights automatically") },
    { key = "wifi_on_demand", default = false, label = _("Turn on Wi-Fi to sync") },
    { key = "show_reading_summary", default = true, label = _("Show a reading summary after Sync now") },
}

function Seekquel:init()
    self.settings = Settings:new()
    self.api = Api:new(self.settings)
    self.stats = Stats:new()
    self.annotations = Annotations:new()
    self.metadata_reader = Metadata:new()
    self.chapters = Chapters:new()
    self.position = Position:new()
    self.updater = Updater:new(self.api)

    self.digest = nil
    self.document_state = nil
    self.pages_turned = 0
    self.pushed_progress = nil
    self.push_scheduled = false
    self.pairing_active = false
    self.run_deadline = nil
    self.manual_sync_at = nil
    self.scheduled = {}
    self.interval_task = nil

    local interrupted = self.settings:takeInterruption()

    if interrupted ~= nil then
        logger.warn("Seekquel: previous run stopped during", interrupted.label)
    end

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Seekquel:onReaderReady()
    if not self:isReady() then
        return
    end

    self.digest = self:documentDigest()
    self.pages_turned = 0
    self.pushed_progress = nil

    self.position:reset(self.metadata_reader:pageCount(self.ui))
    self.chapters:load(self.ui)

    if self.digest == nil then
        return
    end

    self:observeStatus(self.digest)
    self:scheduleOpeningSync(self.digest)
    self:scheduleFileDetails(self.digest)
    self:scheduleIntervalSync()
end

function Seekquel:scheduleTask(seconds, task)
    local wrapped

    wrapped = function()
        self.scheduled[wrapped] = nil
        task()
    end

    self.scheduled[wrapped] = true
    UIManager:scheduleIn(seconds, wrapped)

    return wrapped
end

function Seekquel:cancelTask(handle)
    if handle == nil then
        return
    end

    UIManager:unschedule(handle)
    self.scheduled[handle] = nil
end

function Seekquel:cancelScheduled()
    for task in pairs(self.scheduled) do
        UIManager:unschedule(task)
    end

    self.scheduled = {}
    self.push_scheduled = false
    self.interval_task = nil
end

function Seekquel:scheduleIntervalSync()
    self:cancelTask(self.interval_task)
    self.interval_task = nil

    local minutes = self.settings:syncIntervalMinutes()

    if minutes <= 0 then
        return
    end

    self.interval_task = self:scheduleTask(minutes * SECONDS_PER_MINUTE, function()
        self.interval_task = nil
        self:runIntervalSync()
    end)
end

function Seekquel:runIntervalSync()
    if not self:isReady() or self.digest == nil then
        return
    end

    if self.settings:isEnabled("auto_sync", true) then
        local batch = self:unsyncedBatch()

        if batch ~= nil then
            self:pushNow(false, false, false, batch)
        end
    end

    self:scheduleIntervalSync()
end

function Seekquel:unsyncedBatch()
    local digest = self.digest
    local pending, fingerprints = self:unsentHighlights(digest, self:collectHighlights())
    local days, history = {}, nil

    if self:isLinked() then
        days, history = self:unsentReadingDays(digest)
    end

    local progress = self.position:reportable()
    local moved = progress ~= nil and progress ~= self.pushed_progress

    if not moved and #pending == 0 and #days == 0 then
        return nil
    end

    return { pending = pending, fingerprints = fingerprints, days = days, history = history }
end

function Seekquel:scheduleOpeningSync(digest)
    self:scheduleTask(OPEN_DELAY_SECONDS, function()
        if self.digest ~= digest then
            return
        end

        self.position:settle(self:currentPosition())
        self:ensureChapters()

        self:whenOnline(function()
            self:reportDeviceIfDue()
            local state = self:loadDocument(digest)

            if self:offerResume(state, true) then
                return
            end

            local batch = self:unsyncedBatch()

            if batch ~= nil then
                self:pushNow(false, false, false, batch)
            end
        end)
    end)
end

function Seekquel:reportDeviceIfDue()
    if not self.settings:isDeviceReportDue() then
        return
    end

    self:reportDevice()
end

function Seekquel:scheduleDeviceReport()
    self:scheduleTask(PUSH_DEBOUNCE_SECONDS, function()
        self:whenOnline(function()
            self:reportDeviceIfDue()
        end)
    end)
end

function Seekquel:reportDevice()
    local slowest = self.settings:slowestCall()

    local answer = self.api:reportDevice({
        device_name = self:deviceName(),
        platform = Device.model,
        app_version = VERSION,
        settings = self:currentSettings(),
        diagnostics = self:diagnostics(slowest),
    })

    self:applyServerAnswer(answer)

    if answer ~= nil then
        self.settings:markDeviceReported()
        self.settings:clearInterruption()
        self.settings:clearTiming(slowest)
    end

    return answer
end

function Seekquel:diagnostics(slowest)
    local interruption = self.settings:lastInterruption()
    local synced_at, synced_ok = self.settings:lastSync()
    local reading_time, reading_time_recorded = self.settings:readingTime()

    return {
        interrupted_during = interruption and interruption.label or nil,
        interrupted_at = interruption and interruption.at or nil,
        slowest_call = slowest and slowest.label or nil,
        slowest_seconds = slowest and slowest.seconds or nil,
        last_sync_at = synced_at,
        last_sync_ok = synced_ok,
        reading_time = reading_time,
        reading_time_recorded = reading_time_recorded,
    }
end

function Seekquel:currentSettings()
    local settings = {}

    for _index, switch in ipairs(SWITCHES) do
        settings[switch.key] = self.settings:isEnabled(switch.key, switch.default)
    end

    settings.sync_interval_minutes = self.settings:syncIntervalMinutes()

    return settings
end

function Seekquel:applyServerAnswer(answer)
    if type(answer) ~= "table" then
        return
    end

    local offset = tonumber(answer.timezone_offset)

    if offset ~= nil then
        self.settings:setTimezoneOffset(offset)
    end

    if type(answer.plugin_version) == "string" then
        self.settings:setLatestVersion(answer.plugin_version)
    end

    if type(answer.reading_snapshot) == "table" then
        self.settings:setReadingSnapshot(answer.reading_snapshot)
    end

    self:applyRequestedSettings(answer)
end

function Seekquel:restartPending()
    local pending = self.settings:pendingRestart()

    if type(pending) ~= "table" then
        return false
    end

    if pending.from ~= VERSION or not Updater.isNewer(pending.to, VERSION) then
        self.settings:setPendingRestart(nil)

        return false
    end

    return true
end

function Seekquel:updateAvailable()
    if self.path == nil or self:restartPending() then
        return nil
    end

    local latest = self.settings:latestVersion()

    return Updater.isNewer(latest, VERSION) and latest or nil
end

function Seekquel:applyRequestedSettings(answer)
    if type(answer.apply) ~= "table" then
        return
    end

    local revision = tonumber(answer.apply_revision)

    if revision == nil or revision <= self.settings:appliedSettingsRevision() then
        return
    end

    for _index, switch in ipairs(SWITCHES) do
        local wanted = answer.apply[switch.key]

        if type(wanted) == "boolean" then
            self.settings:set(switch.key, wanted)
        end
    end

    self:applyRequestedInterval(answer.apply.sync_interval_minutes)
    self.settings:markSettingsApplied(revision)
end

function Seekquel:applyRequestedInterval(wanted)
    local minutes = tonumber(wanted)

    if minutes == nil or minutes == self.settings:syncIntervalMinutes() then
        return
    end

    for _index, choice in ipairs(SYNC_INTERVALS) do
        if choice == minutes then
            self.settings:setSyncIntervalMinutes(minutes)
            self:scheduleIntervalSync()

            return
        end
    end
end

function Seekquel:ensureDocument()
    self:sendProgress()

    return self:loadDocument(self.digest)
end

function Seekquel:loadDocument(digest)
    local state = self.api:document(digest)

    if type(state) == "table" then
        self.document_state = state
    end

    return state
end

function Seekquel:offerResume(state, automatic)
    if type(state) ~= "table" or self.digest == nil then
        return false
    end

    local digest = self.digest
    local dismissed = automatic and self.settings:dismissedResume(digest) or nil
    local target = self.position:resumeTarget(state.resume, dismissed)

    if target == nil then
        return false
    end

    local percentage = math.floor((target * 100) + 0.5)

    UIManager:show(ConfirmBox:new({
        text = T(_("Seekquel has this book at %1%%. KOReader will move to the closest place in this file."), tostring(percentage)),
        ok_text = _("Continue there"),
        ok_callback = function()
            if self.digest ~= digest then
                return
            end

            self.settings:setDismissedResume(digest, nil)
            self:goToResume(target)
        end,
        cancel_text = _("Keep this place"),
        cancel_callback = function()
            if self.digest ~= digest then
                return
            end

            self.settings:setDismissedResume(digest, target)
            self:pushNow(true)
        end,
    }))

    return true
end

function Seekquel:goToResume(target)
    local digest = self.digest
    local ok = pcall(function()
        if self.ui.paging ~= nil then
            local page_count = tonumber(self.metadata_reader:pageCount(self.ui))

            if page_count == nil or page_count < 1 then
                error("page count unavailable")
            end

            local page = math.max(1, math.min(page_count, math.floor((target * page_count) + 0.5)))
            self.ui:handleEvent(Event:new("GotoPage", page))
        else
            self.ui:handleEvent(Event:new("GotoPercent", target * 100))
        end
    end)

    if not ok then
        self:notify(_("KOReader could not move to that place."))

        return
    end

    self:scheduleTask(RESUME_SETTLE_DELAY_SECONDS, function()
        if self.digest ~= digest then
            return
        end

        local progress, percentage = self:currentPosition()

        if progress == nil then
            self:notify(_("KOReader could not save that place."))

            return
        end

        self.position:settle(progress, percentage)
        self.pushed_progress = nil

        if type(self.document_state) == "table" then
            self.document_state.resume = nil
        end

        self:pushNow(true)
    end)
end

function Seekquel:scheduleFileDetails(digest)
    if self.settings:hasSentDetails(digest) then
        return
    end

    self:scheduleTask(METADATA_DELAY_SECONDS, function()
        self:whenIdle(digest, function()
            self:sendFileMetadata()
        end)
    end)
end

function Seekquel:whenIdle(digest, task)
    if self.digest ~= digest or not self.api:isConfigured() or not NetworkMgr:isOnline() then
        return
    end

    task()
end

function Seekquel:sendFileMetadata()
    if self.digest == nil or self.settings:hasSentDetails(self.digest) then
        return
    end

    local details = self.metadata_reader:collect(self.ui)

    if details == nil then
        return
    end

    local state = self.api:pushMetadata(self.digest, details)

    if state == nil then
        return
    end

    self.document_state = state

    if state.details_stored == true then
        self.settings:markDetailsSent(self.digest)
    end
end

function Seekquel:sendProgress(timeout)
    local progress, percentage, covered = self.position:reportable()

    if progress == nil then
        return true
    end

    if progress == self.pushed_progress then
        return true
    end

    local sent = self.api:pushProgress(
        self.digest,
        progress,
        percentage,
        covered,
        self:deviceName(),
        self:metadata(),
        timeout,
        self.chapters:at(percentage),
        self.chapters:count()
    ) ~= nil

    if sent then
        self.pushed_progress = progress
        self.position:commit()
    end

    return sent
end

function Seekquel:onPosUpdate()
    self:trackPosition()
end

function Seekquel:onPageUpdate()
    self:trackPosition()
end

function Seekquel:trackPosition()
    if not self:isReady() then
        return
    end

    self.position:observe(self:currentPosition())
    self:countPage()
end

function Seekquel:onCloseDocument()
    self:pushNow()
end

function Seekquel:onSuspend()
    self:leaveQuietly()
end

function Seekquel:onRequestSuspend()
    self:leaveQuietly()
end

function Seekquel:leaveQuietly()
    self:cancelScheduled()
    self:pushNow(false, true)
end

function Seekquel:onResume()
    self:resumeSyncing()
end

function Seekquel:onRequestResume()
    self:resumeSyncing()
end

function Seekquel:resumeSyncing()
    self.api:clearBackoff()
    self:scheduleDeviceReport()
    self:schedulePush()
    self:scheduleIntervalSync()
end

function Seekquel:onEndOfBook()
    if not self.settings:isEnabled("finish_at_end", true) then
        return
    end

    self:whenOnline(function()
        if self.digest and self:isLinked() then
            self.document_state = self.api:setStatus(self.digest, "read") or self.document_state
        end
    end)
end

function Seekquel:onNetworkConnected()
    self.api:clearBackoff()
    self:scheduleDeviceReport()
    self:pushNow()
end

function Seekquel:onNetworkDisconnecting()
    self:pushNow()
end

function Seekquel:countPage()
    if not self:isReady() or not self.settings:isEnabled("auto_sync", true) then
        return
    end

    self.pages_turned = self.pages_turned + 1

    if self.pages_turned < self.settings:pagesBeforePush() then
        return
    end

    self.pages_turned = 0
    self:schedulePush()
end

function Seekquel:schedulePush()
    if self.push_scheduled then
        return
    end

    self.push_scheduled = true

    self:scheduleTask(PUSH_DEBOUNCE_SECONDS, function()
        self.push_scheduled = false
        self:pushNow()
    end)
end

function Seekquel:beginRun(seconds)
    self.run_deadline = os.time() + (seconds or SYNC_BUDGET_SECONDS)
end

function Seekquel:hasBudget()
    return self.run_deadline == nil or os.time() < self.run_deadline
end

function Seekquel:pushNow(asked_for, leaving, continuing, prepared, completed)
    if not self:isReady() or self.digest == nil then
        return
    end

    local digest = self.digest
    local pending, fingerprints, days, history

    if prepared ~= nil then
        pending, fingerprints = prepared.pending, prepared.fingerprints
        days, history = prepared.days, prepared.history
    else
        pending, fingerprints = self:unsentHighlights(digest, self:collectHighlights(asked_for))
        days, history = self:unsentReadingDays(digest)
    end

    local timeout = leaving and Api.LEAVING_TIMEOUT or nil

    local run = function()
        if not continuing then
            self:beginRun(leaving and LEAVING_BUDGET_SECONDS or nil)
        end

        local sent = self:sendProgress(timeout)

        if not self:refreshLink(digest) then
            self.settings:recordSync(sent)

            if completed ~= nil then
                completed(sent)
            end

            return
        end

        local sendHighlights = function()
            if #pending == 0 then
                return true, nil
            end

            if not self:hasBudget() then
                return false, Settings.UPLOAD_HIGHLIGHTS
            end

            if self.api:pushHighlights(digest, pending, timeout) == nil then
                return false, nil
            end

            self.settings:markHighlightsSent(digest, fingerprints)

            return true, nil
        end

        local sendReadingTime = function()
            if #days == 0 then
                return true, nil
            end

            if not self:hasBudget() then
                return false, Settings.UPLOAD_READING_TIME
            end

            local answer, status = self.api:pushSessions(digest, days, timeout)

            if type(answer) ~= "table" then
                if status ~= nil and status >= CLIENT_ERROR_FLOOR and status < SERVER_ERROR_FLOOR then
                    self.settings:markHistoryRefused(digest, history)
                end

                return false, nil
            end

            self.settings:markHistorySynced(digest, history)

            return true, nil
        end

        local uploads = { sendHighlights, sendReadingTime }

        if self.settings:readingTimeFirst(digest) then
            uploads = { sendReadingTime, sendHighlights }
        end

        local deferred = nil

        for _index, upload in ipairs(uploads) do
            local ok, cut = upload()

            if not ok then
                sent = false
            end

            if cut ~= nil then
                deferred = cut
            end
        end

        if deferred ~= nil then
            self.settings:markUploadDeferred(digest, deferred)
        else
            self.settings:clearUploadDeferred(digest)
        end

        if self:hasBudget() then
            self:sendStatusChange(digest)
        end

        if not leaving and self:hasBudget() then
            self:sendFileMetadata()
        end

        self.settings:recordSync(sent)

        if completed ~= nil then
            completed(sent)
        end
    end

    if leaving then
        if NetworkMgr:isOnline() and self.api:isConfigured() then
            run()
        end

        return
    end

    self:whenOnline(run)
end

function Seekquel:documentStatus()
    if self.ui.doc_settings == nil then
        return nil
    end

    local ok, summary = pcall(function()
        return self.ui.doc_settings:readSetting("summary")
    end)

    if not ok or type(summary) ~= "table" then
        return nil
    end

    return KOREADER_STATUSES[summary.status]
end

function Seekquel:observeStatus(digest)
    if self.settings:lastStatus(digest) ~= nil then
        return
    end

    self.settings:markStatus(digest, self:documentStatus() or NO_STATUS)
end

function Seekquel:sendStatusChange(digest)
    if not self.settings:isEnabled("send_status", true) or not self:hasBudget() then
        return
    end

    local status = self:documentStatus()

    if status == nil then
        return
    end

    local seen = self.settings:lastStatus(digest)

    if seen == status then
        return
    end

    if seen == nil then
        self.settings:markStatus(digest, status)

        return
    end

    local state = self.api:setStatus(digest, status)

    if state ~= nil then
        self.document_state = state
        self.settings:markStatus(digest, status)
    end
end

function Seekquel:allHighlights()
    return self.annotations:collect(self.ui.annotation and self.ui.annotation.annotations)
end

function Seekquel:collectHighlights(asked_for)
    if not self.settings:isEnabled("send_highlights", true) then
        return {}
    end

    if not asked_for and not self.settings:isEnabled("auto_sync_highlights", true) then
        return {}
    end

    return (self:allHighlights())
end

function Seekquel:unsentHighlights(digest, highlights)
    local sent = self.settings:sentHighlights(digest)
    local pending = {}
    local fingerprints = {}

    for _index, highlight in ipairs(highlights) do
        local fingerprint = self.annotations:fingerprint(highlight)

        if sent[highlight.external_id] ~= fingerprint then
            table.insert(pending, highlight)
            fingerprints[highlight.external_id] = fingerprint
        end
    end

    return pending, fingerprints
end

function Seekquel:refreshLink(digest)
    if self:isLinked() then
        return true
    end

    self:loadDocument(digest)

    return self:isLinked()
end

function Seekquel:syncedJustNow()
    return self.manual_sync_at ~= nil and (os.time() - self.manual_sync_at) < MANUAL_SYNC_REPEAT_SECONDS
end

function Seekquel:syncNow()
    if self:syncedJustNow() then
        return
    end

    if self:blockedBy(self:syncObstacle()) then
        return
    end

    self.api:clearBackoff()
    self:pushNow(true, false, false, nil, function(synced)
        self.manual_sync_at = os.time()

        if self.settings:isEnabled("show_reading_summary", true) then
            self:showReadingSummary(synced)
        elseif synced then
            self:notify(_("Sync complete."))
        else
            self:notify(_("Some reading is still waiting to sync."))
        end
    end)
end

function Seekquel:resumeFromSeekquel()
    if self:blockedBy(self:syncObstacle()) then
        return
    end

    self.api:clearBackoff()
    self:whenOnline(function()
        local state = self:loadDocument(self.digest)

        if not self:offerResume(state, false) then
            self:notify(_("Seekquel has no newer place for this book."))
        end
    end)
end

function Seekquel:todayDate()
    local offset = self.settings:timezoneOffset()

    if offset == nil then
        return os.date("%Y-%m-%d")
    end

    return os.date("!%Y-%m-%d", os.time() + (offset * SECONDS_PER_MINUTE))
end

function Seekquel:readingSummary()
    if self.digest == nil then
        return nil, Stats.UNTRACKED
    end

    local today = self:todayDate()
    local days, state = self:readingDays(self.digest)

    if state ~= Stats.OK then
        local cached = self.settings:readingSummary(self.digest)

        if type(cached) == "table" and cached.date == today then
            return cached, "cached"
        end

        return nil, state
    end

    local day = nil

    for _index, candidate in ipairs(days) do
        if candidate.date == today then
            day = candidate
            break
        end
    end

    local _, percentage = self.position:reportable()
    local chapter = day and day.chapter or self.chapters:at(percentage)
    local summary = {
        date = today,
        seconds = day and day.seconds or 0,
        pages = day and day.pages or 0,
        chapter = chapter,
        chapter_count = self.chapters:count(),
        percentage = percentage and math.floor((percentage * 100) + 0.5) or nil,
        recorded_at = os.time(),
    }

    self.settings:recordReadingSummary(self.digest, summary)

    return summary, state
end

function Seekquel:showReadingSummary(synced)
    local summary, state = self:readingSummary()

    self:notify(Recap.reading(summary, state, synced))
end

function Seekquel:showAccountSnapshot()
    local display = function()
        local snapshot = self.settings:readingSnapshot()
        local updated = type(snapshot) == "table" and tonumber(snapshot.generated_at) or nil

        self:notify(Recap.account(snapshot, updated and self:agoLabel(updated) or nil))
    end

    if not self:canReachNetwork() then
        display()

        return
    end

    self.api:clearBackoff()
    self:whenOnline(function()
        self:reportDevice()
        display()
    end)
end

function Seekquel:bookObstacle()
    if not self:isReady() then
        return _("Open a book first.")
    end

    if self.digest == nil then
        return _("KOReader has not finished reading this file, so there is nothing to send yet. Try again in a moment.")
    end

    return nil
end

function Seekquel:linkObstacle()
    local obstacle = self:bookObstacle()

    if obstacle ~= nil then
        return obstacle
    end

    if not self:isLinked() then
        return NOT_LINKED_TEXT
    end

    return nil
end

function Seekquel:syncObstacle()
    local obstacle = self:bookObstacle()

    if obstacle ~= nil then
        return obstacle
    end

    if not self:canReachNetwork() then
        return _("No connection. Your reading will sync the next time you are online.")
    end

    return nil
end

function Seekquel:blockedBy(obstacle)
    if obstacle == nil then
        return false
    end

    self:notify(obstacle)

    return true
end

function Seekquel:canReachNetwork()
    return NetworkMgr:isOnline() or self.settings:isEnabled("wifi_on_demand", false)
end

function Seekquel:buildHistoryFingerprint(days)
    local parts = {}

    for _index, day in ipairs(days) do
        table.insert(parts, table.concat({ day.date, day.seconds, day.pages }, ":"))
    end

    return table.concat(parts, "|")
end

function Seekquel:readingDays(digest)
    local synced_at = self.settings:historySyncedAt(digest)
    local floor = synced_at and (synced_at - (HISTORY_OVERLAP_DAYS * SECONDS_PER_DAY)) or nil

    local days, state = self.stats:daysFor(digest, floor, self.settings:timezoneOffset())

    return self:withChapters(days), state
end

function Seekquel:ensureChapters()
    if self.chapters:count() == nil then
        self.chapters:load(self.ui)
    end
end

function Seekquel:withChapters(days)
    if type(days) ~= "table" then
        return days
    end

    for _index, day in ipairs(days) do
        day.chapter = self.chapters:at(day.reached)
        day.reached = nil
    end

    return days
end

function Seekquel:unsentReadingDays(digest)
    if not self.settings:isEnabled("send_reading_time", true) then
        return self:noReadingDays(TIME_DISABLED)
    end

    local days, state = self:readingDays(digest)

    if state ~= Stats.OK then
        return self:noReadingDays(state)
    end

    if #days == 0 then
        return self:noReadingDays(TIME_NONE)
    end

    local fingerprint = self:buildHistoryFingerprint(days)

    if fingerprint == self.settings:historyFingerprint(digest) then
        return self:noReadingDays(TIME_SENT, days)
    end

    if fingerprint == self.settings:refusedHistory(digest) then
        return self:noReadingDays(TIME_REFUSED, days)
    end

    self.settings:recordReadingTime(TIME_WAITING, self:latestRecordedDay(days))

    return days, fingerprint, TIME_WAITING
end

function Seekquel:noReadingDays(state, days)
    self.settings:recordReadingTime(state, self:latestRecordedDay(days))

    return {}, nil, state
end

function Seekquel:latestRecordedDay(days)
    if type(days) ~= "table" or days[1] == nil then
        return nil
    end

    return days[1].date
end

function Seekquel:whenOnline(task)
    if not self.api:isConfigured() then
        return
    end

    if NetworkMgr:isOnline() then
        task()

        return
    end

    if not self.settings:isEnabled("wifi_on_demand", false) then
        return
    end

    NetworkMgr:runWhenOnline(task)
end

function Seekquel:isReady()
    return self.ui ~= nil and self.ui.document ~= nil
end

function Seekquel:isLinked()
    return self:book() ~= nil
end

function Seekquel:book()
    if type(self.document_state) ~= "table" or type(self.document_state.book) ~= "table" then
        return nil
    end

    return self.document_state.book
end

function Seekquel:documentDigest()
    if self.ui.doc_settings == nil then
        return nil
    end

    local ok, digest = pcall(function()
        return self.ui.doc_settings:readSetting("partial_md5_checksum")
    end)

    if ok and type(digest) == "string" and digest ~= "" then
        return digest
    end

    return nil
end

function Seekquel:currentPosition()
    local view = self.ui.paging or self.ui.rolling

    if view == nil then
        return nil, nil
    end

    local ok, progress, percentage = pcall(function()
        return view:getLastProgress(), view:getLastPercent()
    end)

    if not ok or progress == nil then
        return nil, nil
    end

    return progress, percentage or 0
end

function Seekquel:metadata()
    local props = self.ui.doc_props or {}

    return {
        title = props.display_title or props.title,
        authors = props.authors,
        filename = self.ui.document.file and self.ui.document.file:match("[^/\\]+$") or nil,
    }
end

function Seekquel:deviceName()
    return self.settings:get("device_name") or Device.model or "KOReader"
end

function Seekquel:onDispatcherRegisterActions()
    local keys, labels = {}, {}

    for _index, status in ipairs(STATUSES) do
        table.insert(keys, status.key)
        table.insert(labels, status.label)
    end

    Dispatcher:registerAction("seekquel_sync_now", {
        category = "none",
        event = "SeekquelSyncNow",
        title = _("Seekquel: sync now"),
        reader = true,
    })

    Dispatcher:registerAction("seekquel_sync_status", {
        category = "none",
        event = "SeekquelSyncStatus",
        title = _("Seekquel: sync status"),
        general = true,
    })

    Dispatcher:registerAction("seekquel_todays_reading", {
        category = "none",
        event = "SeekquelTodaysReading",
        title = _("Seekquel: today's reading"),
        reader = true,
    })

    Dispatcher:registerAction("seekquel_resume", {
        category = "none",
        event = "SeekquelResume",
        title = _("Seekquel: resume from Seekquel"),
        reader = true,
    })

    Dispatcher:registerAction("seekquel_set_status", {
        category = "string",
        event = "SeekquelSetStatus",
        title = _("Seekquel: set the book's status"),
        args = keys,
        toggle = labels,
        reader = true,
        separator = true,
    })
end

function Seekquel:onSeekquelSyncNow()
    self:syncNow()

    return true
end

function Seekquel:onSeekquelSyncStatus()
    self:notify(self:syncStatusText())

    return true
end

function Seekquel:onSeekquelTodaysReading()
    if not self:blockedBy(self:bookObstacle()) then
        self:showReadingSummary()
    end

    return true
end

function Seekquel:onSeekquelResume()
    if not self:blockedBy(self:linkObstacle()) then
        self:resumeFromSeekquel()
    end

    return true
end

function Seekquel:onSeekquelSetStatus(status)
    if self:blockedBy(self:linkObstacle()) then
        return true
    end

    for _index, candidate in ipairs(STATUSES) do
        if candidate.key == status then
            self:setStatus(candidate.key, candidate.label)

            break
        end
    end

    return true
end

function Seekquel:addToMainMenu(menu_items)
    menu_items.seekquel = {
        text = _("Seekquel"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:menuItems()
        end,
    }
end

function Seekquel:showAppQr()
    UIManager:show(QRMessage:new({
        text = APP_LINK_URL,
        width = APP_QR_SIZE,
        height = APP_QR_SIZE,
    }))
end

function Seekquel:appQrItem()
    return {
        text = _("Get the Seekquel app"),
        keep_menu_open = true,
        callback = function()
            self:showAppQr()
        end,
    }
end

function Seekquel:menuItems()
    if not self.api:isConfigured() then
        return {
            self:appQrItem(),
            {
                text = _("Connect this device"),
                keep_menu_open = false,
                callback = function()
                    self:beginPairing()
                end,
            },
            self:serverItem(),
        }
    end

    local items = {}
    local update = self:updateAvailable()

    if self:restartPending() then
        table.insert(items, {
            text = _("Restart KOReader to finish updating"),
            keep_menu_open = false,
            callback = function()
                UIManager:askForRestart()
            end,
        })
    elseif update ~= nil then
        table.insert(items, {
            text = self:updateItemText(update),
            keep_menu_open = false,
            callback = function()
                self:installUpdate()
            end,
        })
    end

    return self:appendMenuItems(items, {
        {
            text = self:bookLabel(),
            enabled = self:isReady(),
            keep_menu_open = false,
            callback = function()
                self:openLinkDialog()
            end,
        },
        {
            text = _("Update status"),
            enabled = self:isLinked(),
            sub_item_table = self:statusItems(),
        },
        {
            text = _("Rate this book"),
            enabled = self:isLinked(),
            sub_item_table = self:ratingItems(),
        },
        {
            text = _("Sync now"),
            enabled = self:isReady(),
            keep_menu_open = false,
            callback = function()
                self:syncNow()
            end,
        },
        {
            text = _("Resume from Seekquel"),
            enabled = self:isLinked(),
            keep_menu_open = false,
            callback = function()
                self:resumeFromSeekquel()
            end,
        },
        {
            text = _("Sync status"),
            keep_menu_open = false,
            callback = function()
                self:notify(self:syncStatusText())
            end,
        },
        {
            text = _("Today's reading"),
            enabled = self:isReady(),
            keep_menu_open = false,
            callback = function()
                self:showReadingSummary()
            end,
        },
        {
            text = _("Today in Seekquel"),
            keep_menu_open = false,
            callback = function()
                self:showAccountSnapshot()
            end,
        },
        {
            text = _("Settings"),
            sub_item_table = self:settingsItems(),
        },
    })
end

function Seekquel:updateItemText(version)
    if not Updater.canInstall() then
        return T(_("Version %1 needs a computer to install"), version)
    end

    return T(_("Update the add-on to %1"), version)
end

function Seekquel:appendMenuItems(items, more)
    for _index, item in ipairs(more) do
        table.insert(items, item)
    end

    return items
end

function Seekquel:installUpdate()
    if self.path == nil then
        self:notify(_("This copy cannot update itself. Download the add-on from Seekquel instead."))

        return
    end

    if not Updater.canInstall() then
        self:notify(self:updateFailureText("too_old"))

        return
    end

    if not self:canReachNetwork() then
        self:notify(_("No connection. Try updating again when you are online."))

        return
    end

    self:whenOnline(function()
        local waiting = InfoMessage:new({ text = _("Downloading the update.") })
        UIManager:show(waiting)
        UIManager:forceRePaint()

        self.api:clearBackoff()

        local manifest = self.api:pluginManifest()
        local ok, reason = false, "no_manifest"

        if type(manifest) == "table" and type(manifest.files) == "table" and type(manifest.version) == "string" then
            ok, reason = self.updater:install(self.path, manifest.files)
        end

        UIManager:close(waiting)

        if not ok then
            self:notify(self:updateFailureText(reason))

            return
        end

        self.settings:setPendingRestart(VERSION, manifest.version)
        self.settings:setLatestVersion(nil)

        UIManager:show(ConfirmBox:new({
            text = _("Seekquel is updated. Close KOReader now to finish?"),
            ok_text = _("Close now"),
            ok_callback = function()
                UIManager:broadcastEvent(Event:new("Exit", function()
                    Device:saveSettings()
                    UIManager:quit(85)
                end))
            end,
            cancel_text = _("Later"),
            cancel_callback = function()
                self:notify(_("The update will finish the next time you open KOReader."))
            end,
        }))
    end)
end

function Seekquel:updateFailureText(reason)
    if reason == "too_old" then
        return _("This version of KOReader cannot update the add-on by itself. Copy the new files across from a computer instead.")
    end

    if reason == "stranded" then
        return _("The update could not be put in place and the old copy could not be restored. Copy the add-on across from a computer to get Seekquel back.")
    end

    if reason == "not_writable" then
        return _("This device will not let the add-on replace itself. Copy the new files across from a computer instead.")
    end

    if reason == "corrupt" or reason == "incomplete" then
        return _("The download did not arrive intact, so nothing was changed. Try again on a better connection.")
    end

    return _("Could not reach Seekquel for the update. Nothing was changed.")
end

function Seekquel:syncStatusText()
    local lines = { self:lastSyncLine() }

    if not self:isReady() then
        table.insert(lines, _("Open a book to see what is waiting for it."))

        return table.concat(lines, "\n\n")
    end

    local book = self:book()

    if book ~= nil then
        table.insert(lines, T(_("Linked to %1"), book.title or _("a book")))
    end

    table.insert(lines, self:waitingLine())

    return table.concat(lines, "\n\n")
end

function Seekquel:lastSyncLine()
    local at, ok = self.settings:lastSync()

    if at == nil then
        return _("Nothing has synced yet.")
    end

    if ok then
        return T(_("Last sync: %1."), self:agoLabel(at))
    end

    return T(_("Last try: %1, and some of it did not go through. It will be sent again."), self:agoLabel(at))
end

function Seekquel:waitingLine()
    if not self:isLinked() then
        return NOT_LINKED_TEXT
    end

    local lines = {}
    local highlights, total = self:allHighlights()

    if total == 0 then
        table.insert(lines, _("No highlights on this book yet."))
    else
        table.insert(lines, self:highlightLine(highlights, total))

        if total > #highlights then
            table.insert(lines, T(_("Only the first %1 are sent."), tostring(#highlights)))
        end
    end

    self:unsentReadingDays(self.digest)

    local state, recorded = self.settings:readingTime()
    local reading_time = self:readingTimeLine(state, recorded)

    if reading_time ~= nil then
        table.insert(lines, reading_time)
    end

    return table.concat(lines, " ")
end

function Seekquel:readingTimeLine(state, recorded)
    if state == TIME_DISABLED then
        return _("This device is set not to send reading time.")
    end

    if state == Stats.UNREADABLE then
        return _("Reading time cannot be sent: KOReader's reading statistics could not be read on this device.")
    end

    if state == Stats.UNTRACKED then
        return _("Reading time cannot be sent: KOReader is not keeping reading statistics for this book.")
    end

    if state == TIME_NONE then
        return _("KOReader has recorded no reading time for this book since the last sync.")
    end

    if state == TIME_REFUSED then
        return _("Reading time was not accepted and will be offered again after more reading.")
    end

    if state == TIME_WAITING then
        return _("Reading time is waiting to be sent.")
    end

    if state == TIME_SENT then
        if recorded == nil then
            return _("Reading time is up to date.")
        end

        return T(_("Reading time is up to date. The last reading KOReader recorded for this book was %1."), recorded)
    end

    return nil
end

function Seekquel:highlightLine(highlights, total)
    if not self.settings:isEnabled("send_highlights", true) then
        return T(_("%1 highlights on this book. This device is set not to send them."), tostring(total))
    end

    local pending = self:unsentHighlights(self.digest, highlights)

    if #pending == 0 then
        return T(_("%1 highlights on this book, all sent."), tostring(total))
    end

    if self.settings:isEnabled("auto_sync_highlights", true) then
        return T(_("%1 highlights on this book, %2 still to send."), tostring(total), tostring(#pending))
    end

    return T(_("%1 highlights on this book, %2 sent when you tap Sync now."), tostring(total), tostring(#pending))
end

function Seekquel:agoLabel(at)
    local seconds = os.time() - at

    if seconds < 60 then
        return _("just now")
    end

    if seconds < 3600 then
        return T(_("%1 minutes ago"), tostring(math.floor(seconds / 60)))
    end

    if seconds < 86400 then
        return T(_("%1 hours ago"), tostring(math.floor(seconds / 3600)))
    end

    return T(_("%1 days ago"), tostring(math.floor(seconds / 86400)))
end

function Seekquel:bookLabel()
    if not self:isReady() then
        return _("Open a book to link it")
    end

    local book = self:book()

    if book == nil then
        return _("Not linked yet. Tap to find this book")
    end

    return T(_("Linked to %1"), book.title or _("a book"))
end

function Seekquel:statusItems()
    local items = {}

    for _index, status in ipairs(STATUSES) do
        table.insert(items, {
            text = status.label,
            keep_menu_open = false,
            checked_func = function()
                return self:currentStatus() == status.key
            end,
            callback = function()
                self:setStatus(status.key, status.label)
            end,
        })
    end

    return items
end

function Seekquel:currentStatus()
    local book = self:book()

    return book and book.status or nil
end

function Seekquel:currentRating()
    local book = self:book()

    return book and tonumber(book.rating) or nil
end

function Seekquel:ratingItems()
    local items = {}

    for _index, stars in ipairs(RATINGS) do
        table.insert(items, {
            text = T(_("%1 stars"), tostring(stars)),
            keep_menu_open = false,
            checked_func = function()
                return self:currentRating() == stars
            end,
            callback = function()
                self:setRating(stars, T(_("Rated %1 stars."), tostring(stars)))
            end,
        })
    end

    table.insert(items, {
        text = _("No rating"),
        keep_menu_open = false,
        checked_func = function()
            return self:isLinked() and self:currentRating() == nil
        end,
        callback = function()
            self:setRating(nil, _("Rating removed."))
        end,
    })

    return items
end

function Seekquel:setRating(rating, confirmation)
    local digest = self.digest

    if digest == nil then
        return
    end

    self:whenOnline(function()
        local state = self.api:setRating(digest, rating)

        if state == nil then
            self:notify(_("Could not save that. Try again when you have a connection."))

            return
        end

        self.document_state = state
        self:notify(confirmation)
    end)
end

function Seekquel:settingsItems()
    local items = {}

    for _index, switch in ipairs(SWITCHES) do
        table.insert(items, {
            text = switch.label,
            checked_func = function()
                return self.settings:isEnabled(switch.key, switch.default)
            end,
            callback = function()
                self.settings:toggle(switch.key, switch.default)
            end,
        })
    end

    table.insert(items, {
        text = _("Sync on a timer"),
        sub_item_table = self:syncIntervalItems(),
    })
    table.insert(items, self:serverItem())
    table.insert(items, self:appQrItem())
    table.insert(items, {
        text = _("Disconnect this device"),
        keep_menu_open = false,
        callback = function()
            self.settings:disconnect()
            self.document_state = nil
            self:notify(_("Disconnected. Your reading stays in Seekquel."))
        end,
    })

    return items
end

function Seekquel:syncIntervalItems()
    local items = {}

    for _index, minutes in ipairs(SYNC_INTERVALS) do
        table.insert(items, {
            text = minutes == 0 and _("Off") or T(_("Every %1 minutes"), tostring(minutes)),
            checked_func = function()
                return self.settings:syncIntervalMinutes() == minutes
            end,
            callback = function()
                self.settings:setSyncIntervalMinutes(minutes)
                self:scheduleIntervalSync()
            end,
        })
    end

    return items
end

function Seekquel:serverItem()
    return {
        text = _("Server address"),
        keep_menu_open = false,
        callback = function()
            self:editSyncUrl()
        end,
    }
end

function Seekquel:beginPairing()
    NetworkMgr:runWhenOnline(function()
        self.api:clearBackoff()

        local started = self.api:startPairing(self:deviceName(), Device.model)

        if started == nil or started.device_code == nil then
            self:notify(_("Could not reach Seekquel. Check the server address and your connection."))

            return
        end

        self:showPairingCode(started)
    end)
end

function Seekquel:showPairingCode(started)
    local interval = math.max(tonumber(started.interval) or PAIRING_POLL_SECONDS, PAIRING_MIN_POLL_SECONDS)
    local lifetime = tonumber(started.expires_in) or PAIRING_FALLBACK_SECONDS

    self.pairing_active = true

    local dialog
    dialog = ButtonDialog:new({
        title = T(
            _("On your phone, open Settings, Integrations, KOReader and enter:\n\n%1\n\nWaiting for you to approve it."),
            started.user_code
        ),
        title_align = "center",
        buttons = {
            { {
                text = _("Cancel"),
                callback = function()
                    self.pairing_active = false
                    UIManager:close(dialog)
                end,
            } },
        },
    })

    UIManager:show(dialog)
    self:pollPairing(started.device_code, dialog, os.time() + lifetime, interval)
end

function Seekquel:pollPairing(device_code, dialog, deadline, interval)
    if not self.pairing_active then
        return
    end

    if os.time() >= deadline then
        self.pairing_active = false
        UIManager:close(dialog)
        self:notify(_("That code expired. Try connecting again."))

        return
    end

    UIManager:scheduleIn(interval, function()
        if not self.pairing_active then
            return
        end

        self.api:clearBackoff()

        local collected = self.api:pollPairing(device_code)

        if collected ~= nil and collected.key ~= nil then
            self.pairing_active = false
            UIManager:close(dialog)
            self:finishPairing(collected)

            return
        end

        self:pollPairing(device_code, dialog, deadline, interval)
    end)
end

function Seekquel:finishPairing(collected)
    self.settings:setKey(collected.key)

    if collected.device_id then
        self.settings:set("device_id", collected.device_id)
    end

    self:notify(_("Connected. Your reading will sync from now on."))

    if self:isReady() then
        self:onReaderReady()
    end
end

function Seekquel:openLinkDialog()
    if not self:isReady() then
        return
    end

    local props = self.ui.doc_props or {}
    local suggestion = props.display_title or props.title or ""

    local dialog
    dialog = InputDialog:new({
        title = _("Which book is this?"),
        input = suggestion,
        input_hint = _("Title, or title and author"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Not in the catalogue"),
                    callback = function()
                        UIManager:close(dialog)
                        self:link(nil, _("Saved as your own book."))
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local query = dialog:getInputText()
                        UIManager:close(dialog)
                        self:searchAndChoose(query)
                    end,
                },
            },
        },
    })

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Seekquel:searchAndChoose(query)
    if query == nil or #query < SEARCH_MIN_LENGTH then
        self:notify(_("Type at least a couple of letters to search."))

        return
    end

    self:whenOnline(function()
        local results = self.api:searchBooks(query)

        if #results == 0 then
            self:notify(_("No match in the catalogue. You can save it as your own book instead."))

            return
        end

        self:showResults(results)
    end)
end

function Seekquel:showResults(results)
    local buttons = {}

    for _index, book in ipairs(results) do
        table.insert(buttons, { {
            text = self:resultLabel(book),
            callback = function()
                UIManager:close(self.results_dialog)
                self:link(book.work_id, T(_("Linked to %1."), book.title))
            end,
        } })
    end

    table.insert(buttons, { {
        text = _("None of these"),
        callback = function()
            UIManager:close(self.results_dialog)
            self:link(nil, _("Saved as your own book."))
        end,
    } })

    self.results_dialog = ButtonDialog:new({
        title = _("Pick this book"),
        title_align = "center",
        buttons = buttons,
    })

    UIManager:show(self.results_dialog)
end

function Seekquel:resultLabel(book)
    local label = book.title or _("Untitled")

    if book.authors and book.authors ~= "" then
        label = T(_("%1 by %2"), label, book.authors)
    end

    if book.year then
        label = T(_("%1 (%2)"), label, tostring(book.year))
    end

    return label
end

function Seekquel:link(work_id, confirmation)
    local digest = self.digest

    if digest == nil then
        self:notify(_("KOReader has not finished reading this file, so there is nothing to link yet."))

        return
    end

    self:whenOnline(function()
        if self.document_state == nil then
            self:ensureDocument()
        end

        local state = self.api:linkDocument(digest, work_id)

        if state == nil then
            self:notify(_("Could not save that. Try again when you have a connection."))

            return
        end

        self.document_state = state
        self.settings:forgetBook(digest)
        self.pushed_progress = nil
        self:observeStatus(digest)
        self:notify(confirmation)
        self:pushNow()
    end)
end

function Seekquel:setStatus(status, label)
    local digest = self.digest

    if digest == nil then
        return
    end

    self:whenOnline(function()
        local state = self.api:setStatus(digest, status)

        if state == nil then
            self:notify(_("Could not save that. Try again when you have a connection."))

            return
        end

        self.document_state = state
        self:notify(T(_("Marked as %1."), label))
    end)
end

function Seekquel:editSyncUrl()
    local dialog
    dialog = InputDialog:new({
        title = _("Seekquel server address"),
        input = self.settings:syncUrl(),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local value = dialog:getInputText()
                        UIManager:close(dialog)

                        if value and value ~= "" then
                            self.settings:setSyncUrl(value:gsub("/+$", ""))
                        end
                    end,
                },
            },
        },
    })

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Seekquel:notify(text)
    UIManager:show(InfoMessage:new({ text = text }))
end

return Seekquel
