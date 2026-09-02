
package.path = "/plugin/seekquel.koplugin/?.lua;/plugin/spec/?.lua;" .. package.path

require("stubs")

local Stats = require("seekquel_stats")
local harness = require("harness")

local check = harness.check
local step = harness.step

local DIGEST = os.getenv("HARNESS_DIGEST") or "0f0e0d0c0b0a09080706050403020100"
local UNKNOWN_DIGEST = "ffffffffffffffffffffffffffffffff"

step("A statistics database that cannot be read is not an empty one")

do
    local stats = Stats:new()

    stats.path = function()
        return "/nonexistent/statistics.sqlite3"
    end

    local days, state = stats:daysFor(DIGEST, nil, 0)

    check("a statistics database that will not open reports that it could not be read",
        state == Stats.UNREADABLE, state)

    check("and returns no days, so nothing is inferred from a failed read",
        #days == 0, #days)
end

step("A book the statistics have never seen is not a book with no reading")

do
    local days, state = Stats:new():daysFor(UNKNOWN_DIGEST, nil, 0)

    check("a digest with no book row reports the book as untracked",
        state == Stats.UNTRACKED, state)

    check("and returns no days", #days == 0, #days)
end

step("A tracked book answers with its reading")

do
    local days, state = Stats:new():daysFor(DIGEST, nil, 0)

    check("the read succeeds", state == Stats.OK, state)

    check("and the fixture's three evenings come back", #days == 3, #days)

    local total = 0

    for _index, day in ipairs(days) do
        total = total + day.seconds
    end

    check("carrying every second KOReader recorded", total == 4800, total)

    check("dated a day at a time",
        days[1].date ~= nil and days[1].date:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil,
        days[1].date)

    check("and counting the pages turned", days[1].pages == 40, days[1].pages)
end

step("A window with nothing in it is a successful read, not a broken one")

do
    local days, state = Stats:new():daysFor(DIGEST, os.time() + 86400, 0)

    check("a floor past every recorded session still reports a good read",
        state == Stats.OK, state)

    check("with no days behind it", #days == 0, #days)
end

harness.report()
