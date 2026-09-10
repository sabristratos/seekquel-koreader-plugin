package.path = "/plugin/seekquel.koplugin/?.lua;/plugin/spec/?.lua;" .. package.path

local recorder = require("stubs")
local Seekquel = require("main")
local harness = require("harness")

local check = harness.check
local step = harness.step
local current_percent = 0.25
local current_progress = "place-25"
local events = {}
local pushes = 0

local plugin = Seekquel:new({
    ui = {
        document = {
            file = "/books/test.epub",
            getPageCount = function() return 100 end,
        },
        doc_settings = {
            readSetting = function() return "digest" end,
        },
        rolling = {
            getLastProgress = function() return current_progress end,
            getLastPercent = function() return current_percent end,
        },
        menu = { registerToMainMenu = function() end },
        handleEvent = function(_, event)
            table.insert(events, event)
            current_percent = event.value / 100
            current_progress = "place-" .. tostring(event.value)
        end,
    },
})

plugin.digest = "digest"
plugin.document_state = { book = { title = "Test" } }
plugin.settings:setKey("test-key")
plugin.position:reset(100)
plugin.position:settle(current_progress, current_percent)
plugin.pushNow = function() pushes = pushes + 1 end
plugin.ensureChapters = function() end
plugin.reportDeviceIfDue = function() end
plugin.loadDocument = function()
    return {
        book = { title = "Test" },
        resume = { from_percentage = 0.25, to_percentage = 0.4 },
    }
end

step("A later Seekquel place waits for the reader")

plugin:scheduleOpeningSync("digest")
recorder.scheduled[#recorder.scheduled].task()

local dialog = recorder.dialogs[#recorder.dialogs]

check("the choice is shown before anything moves or syncs",
    current_percent == 0.25 and pushes == 0, current_percent)
check("the choice explains that the file gets the closest place",
    dialog.text:find("closest place", 1, true) ~= nil, dialog.text)

dialog.ok_callback()

check("KOReader receives a percentage jump", events[1].name == "GotoPercent" and events[1].value == 40,
    events[1] and events[1].value)

recorder.scheduled[#recorder.scheduled].task()

local _progress, percentage, covered = plugin.position:reportable()

check("the new place becomes the position sent next", percentage == 0.4, percentage)
check("the jump claims no pages as reading", covered == 0, covered)
check("the new local bookmark is sent", pushes == 1, pushes)

step("Keeping this file's place suppresses only the same offer")

current_percent = 0.25
current_progress = "place-25"
plugin.position:settle(current_progress, current_percent)
plugin:offerResume({ resume = { from_percentage = 0.25, to_percentage = 0.5 } }, true)
recorder.dialogs[#recorder.dialogs].cancel_callback()

check("the declined target is remembered", plugin.settings:dismissedResume("digest") == 0.5,
    plugin.settings:dismissedResume("digest"))
check("that target stays quiet", plugin:offerResume({ resume = { from_percentage = 0.25, to_percentage = 0.5 } }, true) == false,
    "offered")
check("a later target can be offered", plugin:offerResume({ resume = { from_percentage = 0.25, to_percentage = 0.6 } }, true) == true,
    "not offered")

harness.report()
