package.path = "/plugin/seekquel.koplugin/?.lua;/plugin/spec/?.lua;" .. package.path

local recorder = require("stubs")
local harness = require("harness")
local dkjson = require("dkjson")

local server = { routes = {}, calls = {} }

local function answerRequest(request)
    local path = request.url:match("/koreader(/[^?]*)")
    local body = nil

    if request.source ~= nil then
        local chunk = request.source()

        body = chunk and dkjson.decode(chunk) or nil
    end

    local key = request.method .. " " .. tostring(path)
    table.insert(server.calls, { key = key, body = body })

    local route = server.routes[key]

    if route == nil then
        return nil, "closed"
    end

    local status, answer = route(body)

    if status == nil then
        return nil, "timeout"
    end

    if answer ~= nil then
        request.sink(dkjson.encode(answer))
    end

    return 1, status
end

package.loaded["socket.http"] = { request = answerRequest }
package.loaded["ssl.https"] = { request = answerRequest }

local Seekquel = require("main")

local check = harness.check
local step = harness.step

local DIGEST = "0f0e0d0c0b0a09080706050403020100"
local SETTINGS_DIR = os.getenv("HARNESS_SETTINGS_DIR") or "/tmp/koreader"

os.execute("mkdir -p " .. SETTINGS_DIR)
os.remove(SETTINGS_DIR .. "/seekquel.lua")

local function build(opened, linked)
    local plugin = Seekquel:new({
        ui = {
            menu = { registerToMainMenu = function() end },
            document = opened and { file = "/books/toll-the-hounds.epub" } or nil,
        },
    })

    if opened then
        plugin.digest = DIGEST
    end

    if linked then
        plugin.document_state = { book = { title = "Toll the Hounds", status = "reading" } }
    end

    plugin.settings:set("show_reading_summary", false)

    return plugin
end

local function lastMessage()
    return recorder.messages[#recorder.messages]
end

local function saidSomething()
    local before = #recorder.messages

    return function()
        return #recorder.messages > before
    end
end

step("Every registered action is one KOReader can actually fire")

do
    build(false, false)

    local expected = {
        "seekquel_sync_now",
        "seekquel_sync_status",
        "seekquel_todays_reading",
        "seekquel_resume",
        "seekquel_set_status",
    }

    for _index, name in ipairs(expected) do
        local action = recorder.actions[name]

        check(name .. " is registered", action ~= nil)

        if action ~= nil then
            check(name .. " has a handler", type(Seekquel["on" .. tostring(action.event)]) == "function", action.event)
            check(name .. " carries a title", type(action.title) == "string" and action.title ~= "")
        end
    end
end

step("The status action offers the same four statuses as the menu")

do
    local action = recorder.actions["seekquel_set_status"]

    check("it is a value-carrying action", action.category == "string", action.category)
    check("four statuses are offered", #action.args == 4, #action.args)
    check("each value has a label", #action.args == #action.toggle, #action.toggle)
    check("the first value is the first status", action.args[1] == "want_to_read", action.args[1])
    check("the last value is the last status", action.args[4] == "did_not_finish", action.args[4])
    check("labels are human words", action.toggle[4] == "Did not finish", action.toggle[4])
end

step("A gesture with no book open says so instead of doing nothing")

do
    local plugin = build(false, false)

    for _index, fire in ipairs({ "onSeekquelTodaysReading", "onSeekquelResume", "onSeekquelSetStatus" }) do
        local spoke = saidSomething()
        local handled = plugin[fire](plugin, "read")

        check(fire .. " answers the reader", spoke(), fire)
        check(fire .. " names the missing book", lastMessage() == "Open a book first.", lastMessage())
        check(fire .. " consumes the event", handled == true)
    end
end

step("A gesture on a file the catalogue has not placed says why")

do
    local plugin = build(true, false)

    plugin:onSeekquelSetStatus("read")

    check(
        "the reader is told the file is not linked",
        lastMessage() == "Nothing is sent for this book until you tell Seekquel which book it is.",
        lastMessage()
    )
end

step("Sync status answers from anywhere, with no book and no network")

do
    local plugin = build(false, false)
    local spoke = saidSomething()

    check("it consumes the event", plugin:onSeekquelSyncStatus() == true)
    check("it answers the reader", spoke())
end

step("The status gesture carries its value through to the status it names")

do
    local plugin = build(true, true)
    local recorded = nil

    plugin.setStatus = function(_self, status, label)
        recorded = { status = status, label = label }
    end

    plugin:onSeekquelSetStatus("did_not_finish")

    check("the chosen status is the one saved", recorded ~= nil and recorded.status == "did_not_finish", recorded and recorded.status)
    check("its label comes from the same list", recorded ~= nil and recorded.label == "Did not finish", recorded and recorded.label)

    recorded = nil
    plugin:onSeekquelSetStatus("nonsense")

    check("a value the add-on does not know saves nothing", recorded == nil)
end

step("A repeated sync gesture does not start a second run")

do
    local plugin = build(true, true)
    local runs = 0

    plugin.pushNow = function(_self, _asked_for, _leaving, _continuing, _prepared, completed)
        runs = runs + 1

        if completed ~= nil then
            completed(true)
        end
    end

    plugin:onSeekquelSyncNow()
    plugin:onSeekquelSyncNow()
    plugin:onSeekquelSyncNow()

    check("only the first gesture ran", runs == 1, runs)

    plugin.manual_sync_at = os.time() - 10
    plugin:onSeekquelSyncNow()

    check("a later gesture runs again", runs == 2, runs)
end

step("A run that never completes leaves the next gesture free")

do
    local plugin = build(true, true)
    local runs = 0

    plugin.pushNow = function()
        runs = runs + 1
    end

    plugin:onSeekquelSyncNow()
    plugin:onSeekquelSyncNow()

    check("both gestures ran", runs == 2, runs)
end

step("A sync of a file the catalogue has not placed says so instead of claiming success")

do
    local plugin = build(true, false)

    plugin.document_state = { book = nil }
    plugin.pushNow = function(_self, _asked_for, _leaving, _continuing, _prepared, completed)
        completed(true)
    end

    plugin:onSeekquelSyncNow()

    local message = lastMessage()

    check("it does not report a completed sync", message ~= nil and not message:find("Sync complete", 1, true), message)
    check("it asks which book this is", message ~= nil and message:find("which book it is", 1, true) ~= nil, message)
end

step("A sync whose book lookup never answered does not call the book unlinked")

do
    local plugin = build(true, false)

    plugin.pushNow = function(_self, _asked_for, _leaving, _continuing, _prepared, completed)
        completed(false)
    end

    plugin:onSeekquelSyncNow()

    local message = lastMessage()

    check("it does not ask which book this is", message ~= nil and message:find("which book it is", 1, true) == nil, message)
    check("it says reading is still waiting", message == "Some reading is still waiting to sync.", message)
end

step("A sync of a linked book still reports success")

do
    local plugin = build(true, true)

    plugin.pushNow = function(_self, _asked_for, _leaving, _continuing, _prepared, completed)
        completed(true)
    end

    plugin:onSeekquelSyncNow()

    check("it reports a completed sync", lastMessage() == "Sync complete.", lastMessage())
end

step("A book put on hold in KOReader is paused in Seekquel")

do
    local plugin = build(true, true)
    local sent = {}

    plugin.ui.doc_settings = {
        readSetting = function(_self, key)
            if key == "summary" then
                return { status = "abandoned" }
            end
        end,
    }
    plugin.hasBudget = function()
        return true
    end
    plugin.recordStatusMark = function() end
    plugin.api.setStatus = function(_self, _digest, status)
        table.insert(sent, status)

        return { book = { status = status } }
    end

    check("on hold reads as paused", plugin:documentStatus() == "paused", plugin:documentStatus())

    plugin.settings:markStatus(DIGEST, "reading")
    plugin:sendStatusChange(DIGEST)

    check("putting it on hold sends paused", sent[1] == "paused", sent[1])

    sent = {}
    plugin.settings:markStatus(DIGEST, "did_not_finish")
    plugin:sendStatusChange(DIGEST)

    check("a book already on hold before the update sends nothing", #sent == 0, #sent)
    check("and is remembered as paused from now on", plugin.settings:lastStatus(DIGEST) == "paused", plugin.settings:lastStatus(DIGEST))
end

step("A star rating given in KOReader reaches Seekquel without overwriting one set there")

do
    local plugin = build(true, true)
    local sent = {}
    local device_rating = 4

    plugin.ui.doc_settings = {
        readSetting = function(_self, key)
            if key == "summary" then
                return { status = "reading", rating = device_rating }
            end
        end,
    }
    plugin.hasBudget = function()
        return true
    end
    plugin.api.setRating = function(_self, _digest, rating)
        table.insert(sent, rating)

        return { book = { rating = rating } }
    end

    check("a whole star is read from the device", plugin:documentRating() == 4, plugin:documentRating())

    plugin.document_state = { book = { rating = nil } }
    plugin:sendRatingChange(DIGEST)

    check("a first rating on a book Seekquel has none for is sent", sent[1] == 4, sent[1])

    sent = {}
    plugin:sendRatingChange(DIGEST)

    check("the same rating is not sent twice", #sent == 0, #sent)

    device_rating = 5
    plugin:sendRatingChange(DIGEST)

    check("a changed rating is sent", sent[1] == 5, sent[1])

    sent = {}
    plugin.settings:markRating(DIGEST, nil)
    plugin.document_state = { book = { rating = 4.3 } }
    plugin:sendRatingChange(DIGEST)

    check("a first sight never overwrites a rating Seekquel already holds", #sent == 0, #sent)
    check("and is remembered so only a later change is sent", plugin.settings:lastRating(DIGEST) == 5, plugin.settings:lastRating(DIGEST))

    device_rating = nil
    plugin:sendRatingChange(DIGEST)

    check("a star taken away on the device clears nothing in Seekquel", #sent == 0, #sent)

    device_rating = 0
    check("zero stars is no rating", plugin:documentRating() == nil, plugin:documentRating())
end

step("A change made while Seekquel is not syncing the book stays pending until it is")

do
    local plugin = build(true, true)
    local calls = 0
    local paused = true
    local device_status = "complete"
    local device_rating = 4

    plugin.ui.doc_settings = {
        readSetting = function(_self, key)
            if key == "summary" then
                return { status = device_status, rating = device_rating }
            end
        end,
    }
    plugin.hasBudget = function()
        return true
    end
    plugin.recordStatusMark = function() end
    plugin.api.setStatus = function(_self, _digest, status)
        calls = calls + 1

        return { book = { status = status, device_sync_paused = paused } }, paused
    end
    plugin.api.setRating = function(_self, _digest, rating)
        calls = calls + 1

        return { book = { rating = rating, device_sync_paused = paused } }, paused
    end

    plugin.document_state = { book = { rating = nil, device_sync_paused = false } }
    plugin.settings:markStatus(DIGEST, "reading")
    plugin.settings:markRating(DIGEST, 2)

    plugin:sendStatusChange(DIGEST)
    check("a status the server discarded is not recorded as seen",
        plugin.settings:lastStatus(DIGEST) == "reading", plugin.settings:lastStatus(DIGEST))

    plugin.document_state = { book = { rating = nil, device_sync_paused = false } }
    plugin:sendRatingChange(DIGEST)
    check("a rating the server discarded is not recorded as seen",
        plugin.settings:lastRating(DIGEST) == 2, plugin.settings:lastRating(DIGEST))

    check("both were tried once", calls == 2, calls)

    plugin:sendStatusChange(DIGEST)
    plugin:sendRatingChange(DIGEST)
    check("once the book is known to be switched off nothing more is sent for it",
        calls == 2, calls)

    check("the switched-off state is remembered for the book",
        plugin.settings:isSyncPaused(DIGEST) == true, tostring(plugin.settings:isSyncPaused(DIGEST)))

    paused = false
    plugin.document_state = { book = { rating = nil, device_sync_paused = false } }
    plugin:sendStatusChange(DIGEST)
    plugin:sendRatingChange(DIGEST)

    check("after it is switched back on the pending status is sent",
        plugin.settings:lastStatus(DIGEST) == "read", plugin.settings:lastStatus(DIGEST))
    check("and so is the pending rating", plugin.settings:lastRating(DIGEST) == 4,
        plugin.settings:lastRating(DIGEST))
    check("and the remembered state is cleared", plugin.settings:isSyncPaused(DIGEST) == false,
        tostring(plugin.settings:isSyncPaused(DIGEST)))
end

step("The file details wait while Seekquel is not syncing the book")

do
    local plugin = build(true, true)
    local pushed = 0

    plugin.metadata_reader = {
        collect = function()
            return { title = "Toll the Hounds" }
        end,
    }
    plugin.api.pushMetadata = function()
        pushed = pushed + 1

        return { details_stored = true, book = { device_sync_paused = false } }
    end

    plugin.document_state = { book = { device_sync_paused = true } }
    plugin:sendFileMetadata()

    check("nothing is collected or sent for a switched-off book", pushed == 0, pushed)
    check("and they stay unsent", plugin.settings:hasSentDetails(DIGEST) == false,
        tostring(plugin.settings:hasSentDetails(DIGEST)))

    plugin.document_state = { book = { device_sync_paused = false } }
    plugin:sendFileMetadata()

    check("they go once it is switched back on", pushed == 1, pushed)
    check("and are then marked sent", plugin.settings:hasSentDetails(DIGEST) == true,
        tostring(plugin.settings:hasSentDetails(DIGEST)))
end

step("Switching syncing for a book says why when it cannot be done")

do
    local plugin = build(true, true)
    local requested = 0

    plugin.settings:setKey("KEY")

    local spoke = saidSomething()

    plugin.api.setSyncPaused = function()
        requested = requested + 1

        return nil, 404
    end

    plugin:setSyncPaused(true)

    check("an older server is named as the reason", spoke() and lastMessage():find("cannot switch syncing", 1, true) ~= nil,
        lastMessage())
    check("and the book is not marked as switched off", plugin.settings:isSyncPaused(DIGEST) == false,
        tostring(plugin.settings:isSyncPaused(DIGEST)))

    plugin.api.setSyncPaused = function()
        return nil, nil
    end

    plugin:setSyncPaused(true)

    check("an unreachable server is a connection problem", lastMessage():find("connection", 1, true) ~= nil,
        lastMessage())

    plugin.canReachNetwork = function()
        return false
    end
    plugin.api.setSyncPaused = function()
        requested = requested + 1

        return {}, 200
    end

    local before = requested
    local spoke_offline = saidSomething()

    plugin:setSyncPaused(true)

    check("with no way to connect it says so rather than doing nothing", spoke_offline(), "silent")
    check("and asks the server nothing", requested == before, requested)
end

local PAUSED_TEXT = "Syncing is switched off for this book in Seekquel, so nothing is kept for it."
local PAUSED_UNCONFIRMED_TEXT = "Syncing may be switched off for this book in Seekquel. Connect to check."
local PAUSED_REMINDER_TEXT = "Seekquel is not syncing this book. You switched it off."
local NOT_LINKED_TEXT = "Nothing is sent for this book until you tell Seekquel which book it is."
local LOOKUP = "GET /documents/" .. DIGEST
local POSITION = "PUT /syncs/progress"
local STATUS_WRITE = "PUT /documents/" .. DIGEST .. "/status"
local RATING_WRITE = "PUT /documents/" .. DIGEST .. "/rating"
local SYNC_SWITCH = "PUT /documents/" .. DIGEST .. "/sync"
local DISCARDED = { data = { book = { device_sync_paused = true } }, paused = true }

local function connected(document_state)
    local plugin = build(true, false)

    plugin.settings.store.data = {}
    plugin.settings:setKey("KEY")
    plugin.settings:set("show_reading_summary", false)
    plugin.settings:markDetailsSent(DIGEST)
    plugin.document_state = document_state
    plugin.position:reset(100)
    plugin.position:settle("place-25", 0.25)
    plugin.ensureChapters = function() end
    plugin.reportDeviceIfDue = function() end
    plugin.ui.rolling = {
        getLastProgress = function() return "place-25" end,
        getLastPercent = function() return 0.25 end,
    }

    server.routes = {}
    server.calls = {}

    return plugin
end

local function serve(key, handler)
    server.routes[key] = handler
end

local function asked(key)
    local count = 0

    for _index, call in ipairs(server.calls) do
        if call.key == key then
            count = count + 1
        end
    end

    return count
end

local function askedAt(key)
    for index, call in ipairs(server.calls) do
        if call.key == key then
            return index
        end
    end

    return nil
end

local function bodyOf(key)
    for _index, call in ipairs(server.calls) do
        if call.key == key then
            return call.body
        end
    end

    return nil
end

local function unreachable()
    return nil
end

local function answers(status, body)
    return function()
        return status, body
    end
end

local function pausedBook()
    return { title = "Toll the Hounds", device_sync_paused = true }
end

local function syncingBook()
    return { title = "Toll the Hounds", device_sync_paused = false }
end

local function saidSince(before, text)
    for index = before + 1, #recorder.messages do
        if recorder.messages[index] == text then
            return true
        end
    end

    return false
end

step("Opening the Seekquel menu on a poor connection does not stop the next tap")

do
    local plugin = connected({ book = syncingBook() })

    serve(LOOKUP, unreachable)
    plugin:menuItems()

    check("the menu looked the book up", asked(LOOKUP) == 1, asked(LOOKUP))
    check("a lookup that timed out does not mark the server unreachable",
        plugin.settings:isUnreachable() == false, tostring(plugin.settings:isUnreachable()))

    serve(STATUS_WRITE, answers(200, DISCARDED))
    plugin:setStatus("read", "Read")

    check("the next Mark as tap still reaches Seekquel", asked(STATUS_WRITE) == 1, asked(STATUS_WRITE))
    check("a status Seekquel discarded says nothing was kept", lastMessage() == PAUSED_TEXT, lastMessage())
    check("and the book is remembered as switched off", plugin.settings:isSyncPaused(DIGEST) == true,
        tostring(plugin.settings:isSyncPaused(DIGEST)))

    serve(RATING_WRITE, answers(200, DISCARDED))
    plugin:setRating(3, "Rated 3 stars.")

    check("a rating Seekquel discarded says the same", lastMessage() == PAUSED_TEXT, lastMessage())
end

step("The menu and Sync status ask Seekquel at most once a minute")

do
    local plugin = connected({ book = syncingBook() })

    serve(LOOKUP, answers(200, { data = { book = pausedBook() } }))
    plugin:menuItems()

    check("the first opening asks", asked(LOOKUP) == 1, asked(LOOKUP))

    local status = plugin:syncStatusText()

    check("Sync status right after it does not ask again", asked(LOOKUP) == 1, asked(LOOKUP))
    check("and states the answer as confirmed", status:find(PAUSED_TEXT, 1, true) ~= nil, status)

    plugin.document_checked_at = os.time() - 61
    plugin:menuItems()

    check("a minute later the menu asks again", asked(LOOKUP) == 2, asked(LOOKUP))
end

step("A book switched off in Seekquel says so when it opens")

do
    local plugin = connected({ book = syncingBook() })

    serve(LOOKUP, answers(200, { data = { book = pausedBook() } }))
    serve(POSITION, answers(200, {}))

    local before = #recorder.messages

    plugin:scheduleOpeningSync(DIGEST)
    recorder.scheduled[#recorder.scheduled].task()

    check("the reader is reminded once Seekquel answers", saidSince(before, PAUSED_REMINDER_TEXT), lastMessage())

    plugin = connected({ book = pausedBook() })
    plugin.settings:markSyncPaused(DIGEST, true)
    serve(LOOKUP, unreachable)

    before = #recorder.messages
    plugin:scheduleOpeningSync(DIGEST)
    recorder.scheduled[#recorder.scheduled].task()

    check("a book opened without an answer gets no reminder", not saidSince(before, PAUSED_REMINDER_TEXT),
        lastMessage())
end

step("Sync now on a switched-off book says nothing was kept")

do
    local plugin = connected({ book = syncingBook() })

    serve(POSITION, answers(200, {}))
    serve(LOOKUP, answers(200, { data = { book = pausedBook() } }))

    plugin:onSeekquelSyncNow()

    check("it names the switch rather than a summary", lastMessage() == PAUSED_TEXT, lastMessage())
    check("it looks the book up once", asked(LOOKUP) == 1, asked(LOOKUP))
    check("after the position is sent", (askedAt(POSITION) or 0) < (askedAt(LOOKUP) or 0),
        tostring(askedAt(POSITION)) .. " then " .. tostring(askedAt(LOOKUP)))
end

step("Sync now without an answer from Seekquel does not claim the book is off")

do
    local plugin = connected({ book = pausedBook() })

    plugin.settings:markSyncPaused(DIGEST, true)
    serve(POSITION, answers(200, {}))
    serve(LOOKUP, unreachable)

    plugin:onSeekquelSyncNow()

    check("it says syncing may be off", lastMessage() == PAUSED_UNCONFIRMED_TEXT, lastMessage())
    check("and the lookup that failed leaves later taps free", plugin.settings:isUnreachable() == false,
        tostring(plugin.settings:isUnreachable()))
end

step("Only Sync now looks the book up, and only once")

do
    local plugin = connected({ book = syncingBook() })

    serve(POSITION, answers(200, {}))
    serve(LOOKUP, answers(200, { data = { book = syncingBook() } }))

    plugin:pushNow(true)

    check("a follow-up push after a resume offer asks nothing", asked(LOOKUP) == 0, asked(LOOKUP))

    plugin = connected({ book = nil })
    serve(POSITION, answers(200, {}))
    serve(LOOKUP, answers(200, { data = { book = dkjson.null } }))

    plugin:onSeekquelSyncNow()

    check("a file that is not linked is looked up once, not twice", asked(LOOKUP) == 1, asked(LOOKUP))
    check("and the reader is asked which book it is", lastMessage() == NOT_LINKED_TEXT, lastMessage())
end

step("Switching syncing back on sends the current place at once")

do
    local plugin = connected({ book = pausedBook() })

    plugin.settings:markSyncPaused(DIGEST, true)
    plugin.pushed_progress = "place-25"

    serve(SYNC_SWITCH, answers(200, { data = { book = syncingBook() } }))
    serve(POSITION, answers(200, {}))

    plugin:setSyncPaused(false)

    local sent = bodyOf(SYNC_SWITCH)

    check("Seekquel is asked to switch it back on", sent ~= nil and sent.paused == false, sent and tostring(sent.paused))
    check("the reader is told", lastMessage() == "Seekquel is syncing this book again.", lastMessage())
    check("the place already sent is sent again", asked(POSITION) == 1, asked(POSITION))
    check("and becomes the place sent", plugin.pushed_progress == "place-25", plugin.pushed_progress)
    check("the stored switch is cleared", plugin.settings:isSyncPaused(DIGEST) == false,
        tostring(plugin.settings:isSyncPaused(DIGEST)))
    check("and the book reads as syncing", plugin:isPaused() == false, tostring(plugin:isPaused()))
end

step("Switching syncing for a file Seekquel no longer links says so")

do
    local plugin = connected({ book = syncingBook() })

    serve(SYNC_SWITCH, answers(409, { error = "document_not_linked" }))
    serve(LOOKUP, answers(200, { data = { book = dkjson.null } }))

    plugin:setSyncPaused(true)

    check("the reader is asked which book it is", lastMessage() == NOT_LINKED_TEXT, lastMessage())
    check("the book is looked up again", asked(LOOKUP) == 1, asked(LOOKUP))
    check("and no longer reads as linked", plugin:isLinked() == false, tostring(plugin:isLinked()))
end

harness.report()
