local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Annotations = require("seekquel_annotations")
local Api = require("seekquel_api")
local Metadata = require("seekquel_metadata")
local Settings = require("seekquel_settings")
local Stats = require("seekquel_stats")
local Updater = require("seekquel_updater")

local Seekquel = WidgetContainer:extend({
    name = "seekquel",
    is_doc_only = false,
})

local VERSION = "1.3.0"
local PAIRING_POLL_SECONDS = 3
local PAIRING_MIN_POLL_SECONDS = 2
local PAIRING_FALLBACK_SECONDS = 900
local PUSH_DEBOUNCE_SECONDS = 5
local METADATA_DELAY_SECONDS = 20
local COVER_DELAY_SECONDS = 60
local SYNC_BUDGET_SECONDS = 20
local HISTORY_OVERLAP_DAYS = 2
local SECONDS_PER_DAY = 86400
local SEARCH_MIN_LENGTH = 2

local STATUSES = {
    { key = "want_to_read", label = _("Want to read") },
    { key = "reading", label = _("Reading") },
    { key = "read", label = _("Read") },
    { key = "did_not_finish", label = _("Did not finish") },
}

local SWITCHES = {
    { key = "send_reading_time", default = true, label = _("Send reading time") },
    { key = "send_highlights", default = true, label = _("Send highlights and notes") },
    { key = "finish_at_end", default = true, label = _("Mark finished at the end of a book") },
    { key = "auto_sync", default = true, label = _("Sync while reading") },
    { key = "auto_sync_highlights", default = true, label = _("Send highlights automatically") },
    { key = "wifi_on_demand", default = false, label = _("Turn on Wi-Fi to sync") },
}

function Seekquel:init()
    self.settings = Settings:new()
    self.api = Api:new(self.settings)
    self.stats = Stats:new()
    self.annotations = Annotations:new()
    self.metadata_reader = Metadata:new()
    self.updater = Updater:new(self.api)

    self.digest = nil
    self.document_state = nil
    self.pages_turned = 0
    self.push_scheduled = false
    self.pairing_active = false
    self.run_deadline = nil

    local interrupted = self.settings:takeInterruption()

    if interrupted ~= nil then
        logger.warn("Seekquel: previous run stopped during", interrupted.label)
    end

    self.ui.menu:registerToMainMenu(self)
end

function Seekquel:onReaderReady()
    if not self:isReady() then
        return
    end

    self.digest = self:documentDigest()
    self.pages_turned = 0

    if self.digest == nil then
        return
    end

    self:whenOnline(function()
        self:beginRun()
        self:reportDevice()
        self:ensureDocument()
    end)

    self:scheduleFileDetails(self.digest)
end

function Seekquel:reportDevice()
    local answer = self.api:reportDevice({
        device_name = self:deviceName(),
        platform = Device.model,
        app_version = VERSION,
        settings = self:currentSettings(),
        diagnostics = self:diagnostics(),
    })

    self:applyServerAnswer(answer)

    if answer ~= nil then
        self.settings:clearInterruption()
    end
end

function Seekquel:diagnostics()
    local interruption = self.settings:lastInterruption()
    local slowest = self.settings:slowestCall()
    local synced_at, synced_ok = self.settings:lastSync()

    return {
        interrupted_during = interruption and interruption.label or nil,
        interrupted_at = interruption and interruption.at or nil,
        slowest_call = slowest and slowest.label or nil,
        slowest_seconds = slowest and slowest.seconds or nil,
        last_sync_at = synced_at,
        last_sync_ok = synced_ok,
    }
end

function Seekquel:currentSettings()
    local settings = {}

    for _index, switch in ipairs(SWITCHES) do
        settings[switch.key] = self.settings:isEnabled(switch.key, switch.default)
    end

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

    self.settings:markSettingsApplied(revision)
end

function Seekquel:ensureDocument()
    self:sendProgress()
    self.document_state = self.api:document(self.digest)

    return self.document_state
end

function Seekquel:scheduleFileDetails(digest)
    if self.settings:hasSentDetails(digest) and self.settings:hasSentCover(digest) then
        return
    end

    UIManager:scheduleIn(METADATA_DELAY_SECONDS, function()
        self:whenIdle(digest, function()
            self:sendFileMetadata()
        end)
    end)

    UIManager:scheduleIn(COVER_DELAY_SECONDS, function()
        self:whenIdle(digest, function()
            self:sendFileCover()
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

function Seekquel:sendFileCover()
    if self.digest == nil or self.settings:hasSentCover(self.digest) then
        return
    end

    local image, content_type = self.metadata_reader:cover(self.ui)

    if image == nil then
        self.settings:markCoverSent(self.digest)

        return
    end

    local answer = self.api:pushCover(self.digest, image, content_type)

    if type(answer) == "table" and answer.reason ~= "no_private_book" then
        self.settings:markCoverSent(self.digest)
    end
end

function Seekquel:sendProgress()
    local progress, percentage = self:currentPosition()

    if progress == nil then
        return true
    end

    return self.api:pushProgress(self.digest, progress, percentage, self:deviceName(), self:metadata()) ~= nil
end

function Seekquel:onPosUpdate()
    self:countPage()
end

function Seekquel:onPageUpdate()
    self:countPage()
end

function Seekquel:onCloseDocument()
    self:pushNow()
end

function Seekquel:onSuspend()
    self:pushNow()
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

    UIManager:scheduleIn(PUSH_DEBOUNCE_SECONDS, function()
        self.push_scheduled = false
        self:pushNow()
    end)
end

function Seekquel:beginRun()
    self.run_deadline = os.time() + SYNC_BUDGET_SECONDS
end

function Seekquel:hasBudget()
    return self.run_deadline == nil or os.time() < self.run_deadline
end

function Seekquel:pushNow(asked_for)
    if not self:isReady() or self.digest == nil then
        return
    end

    local digest = self.digest
    local highlights = self:collectHighlights(asked_for)
    local pending, fingerprints = self:unsentHighlights(digest, highlights)
    local days = self.settings:isEnabled("send_reading_time", true) and self:readingDays(digest) or {}

    self:whenOnline(function()
        self:beginRun()

        local sent = self:sendProgress()

        if not self:refreshLink(digest) then
            self.settings:recordSync(sent)

            return
        end

        if #days > 0 then
            if not self:hasBudget() then
                sent = false
            elseif type(self.api:pushSessions(digest, days)) == "table" then
                self.settings:markHistorySynced(digest)
            else
                sent = false
            end
        end

        if #pending > 0 then
            if not self:hasBudget() then
                sent = false
            elseif self.api:pushHighlights(digest, pending) ~= nil then
                self.settings:markHighlightsSent(digest, fingerprints)
            else
                sent = false
            end
        end

        if self:hasBudget() then
            self:sendFileMetadata()
        end

        self.settings:recordSync(sent)
    end)
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

    local state = self.api:document(digest)

    if type(state) == "table" then
        self.document_state = state
    end

    return self:isLinked()
end

function Seekquel:syncNow()
    local obstacle = self:syncObstacle()

    if obstacle ~= nil then
        self:notify(obstacle)

        return
    end

    self:pushNow(true)
    self:notify(_("Syncing in the background."))
end

function Seekquel:syncObstacle()
    if not self:isReady() then
        return _("Open a book first.")
    end

    if self.digest == nil then
        return _("KOReader has not finished reading this file, so there is nothing to send yet. Try again in a moment.")
    end

    if not self:canReachNetwork() then
        return _("No connection. Your reading will sync the next time you are online.")
    end

    return nil
end

function Seekquel:canReachNetwork()
    return NetworkMgr:isOnline() or self.settings:isEnabled("wifi_on_demand", false)
end

function Seekquel:readingDays(digest)
    local synced_at = self.settings:historySyncedAt(digest)
    local floor = synced_at and (synced_at - (HISTORY_OVERLAP_DAYS * SECONDS_PER_DAY)) or nil

    return self.stats:daysFor(digest, floor, self.settings:timezoneOffset())
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

function Seekquel:addToMainMenu(menu_items)
    menu_items.seekquel = {
        text = _("Seekquel"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:menuItems()
        end,
    }
end

function Seekquel:menuItems()
    if not self.api:isConfigured() then
        return {
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
            text = T(_("Update the add-on to %1"), update),
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
            text = _("Sync now"),
            enabled = self:isReady(),
            keep_menu_open = false,
            callback = function()
                self:syncNow()
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
            text = _("Settings"),
            sub_item_table = self:settingsItems(),
        },
    })
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

    if not self:canReachNetwork() then
        self:notify(_("No connection. Try updating again when you are online."))

        return
    end

    self:whenOnline(function()
        local waiting = InfoMessage:new({ text = _("Downloading the update.") })
        UIManager:show(waiting)
        UIManager:forceRePaint()

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
        UIManager:askForRestart(_("Seekquel is updated. Restart KOReader to start using it."))
    end)
end

function Seekquel:updateFailureText(reason)
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
        return _("Nothing is sent for this book until you tell Seekquel which book it is.")
    end

    local highlights, total = self:allHighlights()

    if total == 0 then
        return _("No highlights on this book yet.")
    end

    local lines = { self:highlightLine(highlights, total) }

    if total > #highlights then
        table.insert(lines, T(_("Only the first %1 are sent."), tostring(#highlights)))
    end

    return table.concat(lines, " ")
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
            callback = function()
                self:setStatus(status.key, status.label)
            end,
        })
    end

    return items
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

    table.insert(items, self:serverItem())
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
