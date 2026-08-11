package.path = "/plugin/seekquel.koplugin/?.lua;/plugin/spec/?.lua;" .. package.path

local recorder = require("stubs")
local http = require("socket.http")
local ltn12 = require("ltn12")
local dkjson = require("dkjson")

local BASE = assert(os.getenv("SEEKQUEL_URL"), "SEEKQUEL_URL is required")
local API = assert(os.getenv("SEEKQUEL_API"), "SEEKQUEL_API is required")
local TOKEN = assert(os.getenv("SEEKQUEL_TOKEN"), "SEEKQUEL_TOKEN is required")
local DIGEST = os.getenv("HARNESS_DIGEST") or "0f0e0d0c0b0a09080706050403020100"
local SETTINGS_DIR = os.getenv("HARNESS_SETTINGS_DIR") or "/tmp/koreader"

local APPROVAL_TIMEOUT_SECONDS = 180
local POLL_INTERVAL_SECONDS = 3

local passed, failed = 0, 0

local function check(label, condition, detail)
    if condition then
        passed = passed + 1
        print("  ok   " .. label)
    else
        failed = failed + 1
        print("  FAIL " .. label .. (detail and ("  <- " .. tostring(detail)) or ""))
    end
end

local function step(label)
    print("\n" .. label)
end

local function asReader(method, path, body)
    local payload = body and dkjson.encode(body) or nil
    local sink = {}

    http.request({
        url = API .. path,
        method = method,
        headers = {
            ["authorization"] = "Bearer " .. TOKEN,
            ["accept"] = "application/json",
            ["content-type"] = payload and "application/json" or nil,
            ["content-length"] = payload and tostring(#payload) or nil,
        },
        source = payload and ltn12.source.string(payload) or nil,
        sink = ltn12.sink.table(sink),
    })

    return dkjson.decode(table.concat(sink)) or {}
end

local function drainScheduled(limit)
    for _ = 1, (limit or 20) do
        local pending = table.remove(recorder.scheduled, 1)

        if pending == nil then
            return
        end

        pending.task()
    end
end

os.execute("mkdir -p " .. SETTINGS_DIR)
os.remove(SETTINGS_DIR .. "/seekquel.lua")

local Seekquel = require("main")

local plugin = Seekquel:new({
    ui = {
        document = {
            file = "/mnt/onboard/books/toll-the-hounds.epub",
            getPageCount = function() return 1280 end,
            getToc = function()
                return {
                    { title = "Book One: Ruin", page = 11, depth = 1 },
                    { title = "Chapter One", page = 17, depth = 2 },
                }
            end,
            getProps = function()
                return {
                    title = "Toll the Hounds",
                    authors = "Steven Erikson",
                    language = "en",
                    keywords = "Epic Fantasy, Malazan",
                    description = "The eighth tale of the Malazan Book of the Fallen.",
                    identifiers = "isbn:9780553813227",
                }
            end,
            getCoverPageImage = function() return nil end,
        },
        doc_props = {
            display_title = "Toll the Hounds",
            authors = "Steven Erikson",
        },
        doc_settings = {
            data = { partial_md5_checksum = DIGEST },
            readSetting = function(self, key)
                return self.data[key]
            end,
        },
        rolling = {
            getLastProgress = function() return "/body/DocFragment[6]/body/p[41]/text().0" end,
            getLastPercent = function() return 0.4137 end,
        },
        annotation = {
            annotations = {
                {
                    datetime = "2026-08-08 22:41:10",
                    text = "Children are dying.",
                    note = "the refrain",
                    chapter = "Book One",
                    pageno = 219,
                    pos0 = "/body/DocFragment[6]/body/p[41]/text().0",
                    drawer = "lighten",
                },
                {
                    datetime = "2026-08-08 23:02:55",
                    text = "A bookmark, not a highlight",
                    pageno = 240,
                },
            },
        },
        menu = { registerToMainMenu = function() end },
    },
})

plugin.settings:setSyncUrl(BASE)

step("1. The plugin starts a pairing and shows a code")

local started_device_code = nil
local original_start = plugin.api.startPairing
plugin.api.startPairing = function(api, name, platform)
    local started = original_start(api, name, platform)
    started_device_code = started and started.device_code or nil

    return started
end

plugin:beginPairing()

local shown = recorder.messages[#recorder.messages] or ""
local user_code = shown:match("([A-Z0-9][A-Z0-9%-]+[A-Z0-9])%s*\n")
check("a code is shown to the reader", user_code ~= nil, shown)

step("2. The reader approves it on their phone")

if os.getenv("HARNESS_WAIT_FOR_APPROVAL") then
    local handle = io.open("/plugin/spec/.pairing-code", "w")
    handle:write(user_code)
    handle:close()

    print("  waiting for " .. user_code .. " to be approved in the app...")
    io.stdout:flush()

    local socket = require("socket")
    local waited = 0

    while waited < APPROVAL_TIMEOUT_SECONDS and not plugin.settings:isConnected() do
        socket.sleep(POLL_INTERVAL_SECONDS)
        waited = waited + POLL_INTERVAL_SECONDS

        local collected = plugin.api:pollPairing(started_device_code)

        if collected ~= nil and collected.key ~= nil then
            plugin:finishPairing(collected)
        end
    end

    os.remove("/plugin/spec/.pairing-code")
    check("a person approved the code in the real app", plugin.settings:isConnected(),
        "gave up after " .. waited .. "s")
else
    local approved = asReader("POST", "/api/integrations/koreader/pair/approve", { user_code = user_code })
    check("the account accepts the code", approved.message ~= nil, dkjson.encode(approved))
end

step("3. The plugin collects its key")
drainScheduled()
check("the device is connected", plugin.settings:isConnected(), "no key stored")
check("the key survives a restart", require("seekquel_settings"):new():isConnected())

step("4. Opening the book")
plugin:onReaderReady()
check("the file is identified by the checksum KOReader stores", plugin.digest == DIGEST,
    tostring(plugin.digest))
check("the document is known to the server", plugin.document_state ~= nil)
local devices = asReader("GET", "/api/integrations/devices")
local reported = nil
for _, d in ipairs(devices.data or {}) do
    if d.provider == "koreader" and d.reported_settings then reported = d end
end
check("the device reported what it is set to send", reported ~= nil,
    devices.data and dkjson.encode(devices.data))
check("the account can see the switches without owning them",
    reported and reported.reported_settings.send_reading_time == true and reported.app_version ~= nil,
    reported and dkjson.encode(reported.reported_settings))

check("the position was recorded on open",
    plugin.document_state and plugin.document_state.percentage ~= nil,
    plugin.document_state and dkjson.encode(plugin.document_state))

step("5. The file's own details reach the account")
local details = plugin.metadata_reader:collect(plugin.ui)
check("the table of contents is read off the file", details and #(details.chapters or {}) == 2,
    details and dkjson.encode(details.chapters))
check("the identifiers carry the ISBN", details and details.identifiers ~= nil, details and details.identifiers)
check("the length is the device's own page count", details and details.page_count == 1280,
    details and tostring(details.page_count))

step("6. The reader searches the catalogue and picks a book")
plugin:searchAndChoose("Toll the Hounds")
local chooser = recorder.dialogs[#recorder.dialogs]
check("a list of books is offered", chooser and chooser.__kind == "ButtonDialog", chooser and chooser.__kind)

if chooser and chooser.buttons and chooser.buttons[1] then
    chooser.buttons[1][1].callback()
end

check("the file is linked to a book", plugin:isLinked(), plugin.document_state and dkjson.encode(plugin.document_state))
check("it is the book the reader picked",
    plugin.document_state and plugin.document_state.book and plugin.document_state.book.title == "Toll the Hounds",
    plugin.document_state and plugin.document_state.book and plugin.document_state.book.title)

step("7. Reading time, from the statistics database")
local days = plugin.stats:daysFor(DIGEST, nil)
check("the device's own reading days are read", #days > 0,
    "#days = " .. #days .. " looking in " .. plugin.stats:path())
check("a day carries a date and seconds", days[1] and days[1].date ~= nil and days[1].seconds > 0,
    days[1] and dkjson.encode(days[1]))

step("8. A sync sends everything")
plugin:pushNow()
local document = asReader("GET", "/api/integrations/devices")
check("the reader's devices list still answers", document.data ~= nil)

step("9. Going to sleep syncs, whichever word the device uses for it")
local pushes = 0
local original_push = plugin.pushNow
plugin.pushNow = function() pushes = pushes + 1 end
plugin:onSuspend()
check("a Kobo or Kindle sleeping syncs", pushes == 1, "pushes = " .. pushes)
plugin:onRequestSuspend()
check("an Android reader sleeping syncs", pushes == 2, "pushes = " .. pushes)
plugin.pushNow = original_push

step("10. A status set in KOReader's own screens reaches the account")
check("opening the book remembers the status it had, so the app's is not overwritten",
    plugin.settings:lastStatus(DIGEST) == "none", tostring(plugin.settings:lastStatus(DIGEST)))

plugin.ui.doc_settings.data.summary = { status = "complete" }
plugin:sendStatusChange(DIGEST)
check("marking a book finished on the device sends it",
    plugin.document_state and plugin.document_state.book and plugin.document_state.book.status == "read",
    plugin.document_state and plugin.document_state.book and plugin.document_state.book.status)

step("11. A star from the reader")
plugin:setRating(4, "rated")
drainScheduled()
check("the rating reaches the book",
    plugin.document_state and plugin.document_state.book and tonumber(plugin.document_state.book.rating) == 4,
    plugin.document_state and plugin.document_state.book and tostring(plugin.document_state.book.rating))

step("12. Highlights are picked out of the annotations")
local highlights = plugin.annotations:collect(plugin.ui.annotation.annotations)
check("only the highlight is sent, not the bookmark", #highlights == 1, "#highlights = " .. #highlights)
check("the passage and the note both travel",
    highlights[1] and highlights[1].text == "Children are dying." and highlights[1].note == "the refrain")

step("13. Reaching the end finishes the book")
plugin:onEndOfBook()
check("the book reads as finished",
    plugin.document_state and plugin.document_state.book and plugin.document_state.book.status == "read",
    plugin.document_state and plugin.document_state.book and plugin.document_state.book.status)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
