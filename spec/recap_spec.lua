package.path = "/plugin/seekquel.koplugin/?.lua;/plugin/spec/?.lua;" .. package.path

require("stubs")

local Recap = require("seekquel_recap")
local harness = require("harness")

local check = harness.check
local step = harness.step

step("A book recap says what happened today")

do
    local text = Recap.reading({
        seconds = 1470,
        pages = 18,
        chapter = 7,
        chapter_count = 31,
        percentage = 42,
    }, "ok", true)

    check("minutes are whole minutes", text:find("24 min", 1, true) ~= nil, text)
    check("pages are named", text:find("18 pages", 1, true) ~= nil, text)
    check("the chapter is named when the book has one", text:find("Chapter 7 of 31", 1, true) ~= nil, text)
    check("the book progress is named", text:find("42% through this book", 1, true) ~= nil, text)
    check("a clean sync carries no warning", text:find("still waiting", 1, true) == nil, text)
end

step("A partial sync keeps the local recap honest")

do
    local text = Recap.reading({ seconds = 60, pages = 1 }, "ok", false)

    check("the local reading remains visible", text:find("1 min", 1, true) ~= nil, text)
    check("and waiting work is named", text:find("Some reading is still waiting to sync.", 1, true) ~= nil, text)
end

step("An account snapshot is current status, not a reward message")

do
    local text = Recap.account({
        minutes_read = 30,
        minutes_target = 30,
        pages_read = 18,
        pages_target = 25,
        goals_completed = { "minutes" },
        current_streak = 7,
    }, "just now")

    check("the refresh time is visible", text:find("Updated just now", 1, true) ~= nil, text)
    check("minutes are set against their target", text:find("30 of 30 min today", 1, true) ~= nil, text)
    check("pages are set against their target", text:find("18 of 25 pages today", 1, true) ~= nil, text)
    check("completed goals are counted", text:find("1 daily goal reached", 1, true) ~= nil, text)
    check("the current streak is stated", text:find("7 days in your current streak", 1, true) ~= nil, text)
end

harness.report()
