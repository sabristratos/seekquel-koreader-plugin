package.path = "/plugin/seekquel.koplugin/?.lua;/plugin/spec/?.lua;" .. package.path

require("stubs")
local Seekquel = require("main")
local harness = require("harness")

local check = harness.check
local step = harness.step

local answers = {}
local calls = 0

local plugin = Seekquel:new({
    ui = {
        document = { file = "/books/test.epub" },
        menu = { registerToMainMenu = function() end },
    },
})

plugin.digest = "digest"
plugin.settings:setKey("test-key")
plugin.settings:set("history_fingerprint", {})
plugin.settings:set("history_refused", {})
plugin.refreshLink = function() return true end
plugin.sendProgress = function() return true end
plugin.sendStatusChange = function() end
plugin.sendFileMetadata = function() end
plugin.api = {
    isConfigured = function() return true end,
    pushSessions = function()
        calls = calls + 1

        return nil, answers[1]
    end,
}

local days = { { date = "2026-10-20", seconds = 600 } }

local function attempt(status)
    answers[1] = status
    plugin:pushNow(nil, false, false, { pending = {}, fingerprints = {}, days = days, history = "fingerprint" })
end

step("A temporary refusal of the reading time is retried, a permanent one is not")

for _, status in ipairs({ 408, 425, 429 }) do
    attempt(status)

    check(status .. " leaves the day waiting to be sent again",
        plugin.settings:refusedHistory("digest") == nil, plugin.settings:refusedHistory("digest"))
    check(status .. " does not count as sent", plugin.settings:historyFingerprint("digest") == nil)
end

for _, status in ipairs({ 400, 413, 422 }) do
    plugin.settings:markHistoryRefused("digest", nil)
    attempt(status)

    check(status .. " is held as refused", plugin.settings:refusedHistory("digest") == "fingerprint",
        plugin.settings:refusedHistory("digest"))
end

step("A refusal is not retried inside the run that met it")

calls = 0
plugin.settings:markHistoryRefused("digest", nil)
attempt(429)

check("one request per run", calls == 1, calls)

step("A server error is retried and a transport failure is retried")

plugin.settings:markHistoryRefused("digest", nil)
attempt(503)
check("503 is not held as refused", plugin.settings:refusedHistory("digest") == nil)
attempt(nil)
check("no answer at all is not held as refused", plugin.settings:refusedHistory("digest") == nil)

step("A day sent after a temporary refusal is recorded once")

answers[1] = nil
plugin.api.pushSessions = function()
    calls = calls + 1

    return {}, 200
end
calls = 0
plugin:pushNow(nil, false, false, { pending = {}, fingerprints = {}, days = days, history = "fingerprint" })

check("the day is marked as sent", plugin.settings:historyFingerprint("digest") == "fingerprint")
check("it took one request", calls == 1, calls)

harness.report()
