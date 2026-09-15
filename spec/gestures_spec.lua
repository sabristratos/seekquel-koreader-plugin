package.path = "/plugin/seekquel.koplugin/?.lua;/plugin/spec/?.lua;" .. package.path

local recorder = require("stubs")
local harness = require("harness")

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

harness.report()
