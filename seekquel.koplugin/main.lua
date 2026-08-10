local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template

local Annotations = require("seekquel_annotations")
local Api = require("seekquel_api")
local Metadata = require("seekquel_metadata")
local Settings = require("seekquel_settings")
local Stats = require("seekquel_stats")

local Seekquel = WidgetContainer:extend({
    name = "seekquel",
    is_doc_only = false,
})

local VERSION = "1.0.0"
local PAIRING_POLL_SECONDS = 3
local PAIRING_MAX_POLLS = 100
local PUSH_DEBOUNCE_SECONDS = 5
local RECENT_HISTORY_DAYS = 7
local SEARCH_MIN_LENGTH = 2

local STATUSES = {
    { key = "want_to_read", label = _("Want to read") },
    { key = "reading", label = _("Reading") },
    { key = "read", label = _("Read") },
    { key = "did_not_finish", label = _("Did not finish") },
}

function Seekquel:init()
    self.settings = Settings:new()
    self.api = Api:new(self.settings)
    self.stats = Stats:new()
    self.annotations = Annotations:new()
    self.metadata_reader = Metadata:new()

    self.digest = nil
    self.document_state = nil
    self.pages_turned = 0
    self.push_scheduled = false

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
        self:reportDevice()
        self:ensureDocument()
    end)
end

function Seekquel:reportDevice()
    self.api:reportDevice({
        device_name = self:deviceName(),
        platform = Device.model,
        app_version = VERSION,
        settings = {
            send_reading_time = self.settings:isEnabled("send_reading_time", true),
            send_highlights = self.settings:isEnabled("send_highlights", true),
            finish_at_end = self.settings:isEnabled("finish_at_end", true),
            auto_sync = self.settings:isEnabled("auto_sync", true),
            wifi_on_demand = self.settings:isEnabled("wifi_on_demand", false),
        },
    })
end

function Seekquel:ensureDocument()
    self:sendProgress()
    self.document_state = self.api:document(self.digest)
    self:sendFileDetails()

    return self.document_state
end

function Seekquel:sendFileDetails()
    if self.digest == nil then
        return
    end

    self:sendFileMetadata()
    self:sendFileCover()
end

function Seekquel:sendFileMetadata()
    if self.settings:hasSentDetails(self.digest) then
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

    if type(state.book) == "table" then
        self.settings:markDetailsSent(self.digest)
    end
end

function Seekquel:sendFileCover()
    if self.settings:hasSentCover(self.digest) then
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
        return
    end

    self.api:pushProgress(self.digest, progress, percentage, self:deviceName(), self:metadata())
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

function Seekquel:pushNow()
    if not self:isReady() or self.digest == nil then
        return
    end

    local digest = self.digest
    local highlights = self.settings:isEnabled("send_highlights", true)
        and self.annotations:collect(self.ui.annotation and self.ui.annotation.annotations)
        or {}
    local days = self.settings:isEnabled("send_reading_time", true) and self:readingDays(digest) or {}
    local linked = self:isLinked()

    self:whenOnline(function()
        self:sendProgress()

        if not linked then
            return
        end

        if #days > 0 then
            self.api:pushSessions(digest, days)
            self.settings:markHistorySynced(digest)
        end

        if #highlights > 0 then
            self.api:pushHighlights(digest, highlights)
        end
    end)
end

function Seekquel:syncNow()
    local obstacle = self:syncObstacle()

    if obstacle ~= nil then
        self:notify(obstacle)

        return
    end

    self:pushNow()
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
    local since = self.settings:hasSyncedHistory(digest) and RECENT_HISTORY_DAYS or nil

    return self.stats:daysFor(digest, since)
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

    return {
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
            text = _("Settings"),
            sub_item_table = self:settingsItems(),
        },
    }
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
    return {
        {
            text = _("Send reading time"),
            checked_func = function()
                return self.settings:isEnabled("send_reading_time", true)
            end,
            callback = function()
                self.settings:toggle("send_reading_time", true)
            end,
        },
        {
            text = _("Send highlights and notes"),
            checked_func = function()
                return self.settings:isEnabled("send_highlights", true)
            end,
            callback = function()
                self.settings:toggle("send_highlights", true)
            end,
        },
        {
            text = _("Mark finished at the end of a book"),
            checked_func = function()
                return self.settings:isEnabled("finish_at_end", true)
            end,
            callback = function()
                self.settings:toggle("finish_at_end", true)
            end,
        },
        {
            text = _("Sync while reading"),
            checked_func = function()
                return self.settings:isEnabled("auto_sync", true)
            end,
            callback = function()
                self.settings:toggle("auto_sync", true)
            end,
        },
        {
            text = _("Turn on Wi-Fi to sync"),
            checked_func = function()
                return self.settings:isEnabled("wifi_on_demand", false)
            end,
            callback = function()
                self.settings:toggle("wifi_on_demand", false)
            end,
        },
        self:serverItem(),
        {
            text = _("Disconnect this device"),
            keep_menu_open = false,
            callback = function()
                self.settings:disconnect()
                self.document_state = nil
                self:notify(_("Disconnected. Your reading stays in Seekquel."))
            end,
        },
    }
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
    local message = InfoMessage:new({
        text = T(
            _("On your phone, open Settings, Integrations, KOReader and enter:\n\n%1\n\nWaiting for you to approve it."),
            started.user_code
        ),
        timeout = nil,
    })

    UIManager:show(message)
    self:pollPairing(started.device_code, message, 0)
end

function Seekquel:pollPairing(device_code, message, attempt)
    if attempt >= PAIRING_MAX_POLLS then
        UIManager:close(message)
        self:notify(_("That code expired. Try connecting again."))

        return
    end

    UIManager:scheduleIn(PAIRING_POLL_SECONDS, function()
        local collected = self.api:pollPairing(device_code)

        if collected ~= nil and collected.key ~= nil then
            UIManager:close(message)
            self:finishPairing(collected)

            return
        end

        self:pollPairing(device_code, message, attempt + 1)
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
