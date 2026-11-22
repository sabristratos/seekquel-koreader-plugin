
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

step("A day says which hours of it were spent reading")

do
    local days = Stats:new():daysFor(DIGEST, nil, 0)

    local day = days[1]

    check("a day carries the hours it was read in", type(day.hours) == "table", type(day.hours))

    local hours = 0
    local seconds = 0

    for hour, value in pairs(day.hours) do
        hours = hours + 1
        seconds = seconds + value

        check("every hour is keyed as a string so it travels as an object, not a list",
            type(hour) == "string", type(hour))

        local number = tonumber(hour)

        check("and names an hour of the clock", number ~= nil and number >= 0 and number <= 23, hour)
    end

    check("the fixture's evening spans two of them", hours == 2, hours)

    check("and the hours account for the whole day, never more and never less",
        seconds == day.seconds, seconds .. " vs " .. day.seconds)

    local total = 0

    for _index, each in ipairs(days) do
        total = total + each.seconds
    end

    check("splitting a day by hour leaves the day totals untouched", total == 4800, total)

    check("and still counts the pages turned once, not once per hour",
        days[1].pages == 40, days[1].pages)
end

step("The hour of a day is the reader's own, not the device's")

do
    local shifted = Stats:new():daysFor(DIGEST, nil, 60)

    local hours = {}

    for hour in pairs(shifted[1].hours) do
        table.insert(hours, tonumber(hour))
    end

    table.sort(hours)

    check("an offset moves the reading an hour later on the clock",
        hours[1] == 21 and hours[2] == 22, table.concat(hours, ","))
end

step("A day is also a share of the book, which a font change cannot bend")

do
    local days = Stats:new():daysFor(DIGEST, nil, 0)
    local fraction = days[1].fraction or -1

    check("forty pages of a 1,280-page file are a thirty-second of the book",
        math.abs(fraction - (40 / 1280)) < 0.000001, fraction)
end

do
    local path = os.tmpname()
    local sql = table.concat({
        "CREATE TABLE book (id integer PRIMARY KEY, md5 text);",
        "CREATE TABLE page_stat_data (id_book integer, page integer, start_time integer, duration integer, total_pages integer);",
        "INSERT INTO book (id, md5) VALUES (1, '" .. DIGEST .. "');",
        "WITH RECURSIVE turn(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM turn WHERE n < 20)",
        "INSERT INTO page_stat_data SELECT 1, n, CAST(strftime('%s', 'now', 'start of day', '+20 hours') AS INTEGER) + n * 60, 40, 800 FROM turn;",
        "WITH RECURSIVE turn(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM turn WHERE n < 20)",
        "INSERT INTO page_stat_data SELECT 1, 30 + n, CAST(strftime('%s', 'now', 'start of day', '+21 hours') AS INTEGER) + n * 60, 40, 1200 FROM turn;",
    }, " ")

    local pipe = io.popen("sqlite3 " .. path, "w")
    pipe:write(sql)
    pipe:close()

    local stats = Stats:new()

    stats.path = function()
        return path
    end

    local days = stats:daysFor(DIGEST, nil, 0)
    local fraction = days[1] and days[1].fraction or -1

    check("twenty pages before a font change and twenty after count each at its own size",
        math.abs(fraction - (20 / 800 + 20 / 1200)) < 0.000001, fraction)

    check("while the page count alone still mixes the two numberings",
        days[1] and days[1].pages == 40, days[1] and days[1].pages)

    os.remove(path)
end

step("A file KOReader holds under two records is one book with all of its reading")

do
    local path = os.tmpname()
    local sql = table.concat({
        "CREATE TABLE book (id integer PRIMARY KEY, md5 text, title text, authors text);",
        "CREATE TABLE page_stat_data (id_book integer, page integer, start_time integer, duration integer, total_pages integer);",
        "INSERT INTO book (id, md5, title, authors) VALUES (1, '" .. DIGEST .. "', 'Old title', 'A');",
        "INSERT INTO book (id, md5, title, authors) VALUES (2, '" .. DIGEST .. "', 'New title', 'A');",
        "INSERT INTO page_stat_data VALUES (1, 1, CAST(strftime('%s', 'now', '-3 days') AS INTEGER), 60, 800);",
        "INSERT INTO page_stat_data VALUES (2, 5, CAST(strftime('%s', 'now') AS INTEGER) - 600, 90, 800);",
    }, " ")

    local pipe = io.popen("sqlite3 " .. path, "w")
    pipe:write(sql)
    pipe:close()

    local stats = Stats:new()

    stats.path = function()
        return path
    end

    local days, state = stats:daysFor(DIGEST, nil, 0)

    check("the read succeeds", state == Stats.OK, state)

    check("reading filed under either record comes back, one day each",
        #days == 2, #days)

    local total = 0

    for _index, day in ipairs(days) do
        total = total + day.seconds
    end

    check("carrying the seconds of both records, so the newer one is never hidden by the older",
        total == 150, total)

    os.remove(path)
end

step("The probe says which records KOReader holds for a file, without a file being sent")

do
    local path = os.tmpname()
    local sql = table.concat({
        "CREATE TABLE book (id integer PRIMARY KEY, md5 text, title text, authors text);",
        "CREATE TABLE page_stat_data (id_book integer, page integer, start_time integer, duration integer, total_pages integer);",
        "INSERT INTO book (id, md5, title, authors) VALUES (1, '" .. DIGEST .. "', 'Carl', 'M');",
        "INSERT INTO book (id, md5, title, authors) VALUES (2, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'Carl', 'M');",
        "INSERT INTO book (id, md5, title, authors) VALUES (3, 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'Other', 'N');",
        "INSERT INTO page_stat_data VALUES (1, 1, strftime('%s', '2026-11-19 10:00:00'), 60, 800);",
        "INSERT INTO page_stat_data VALUES (1, 2, strftime('%s', '2026-11-19 10:01:00'), 60, 800);",
        "INSERT INTO page_stat_data VALUES (2, 9, strftime('%s', '2026-11-22 10:00:00'), 60, 800);",
        "INSERT INTO page_stat_data VALUES (3, 1, strftime('%s', '2026-11-23 10:00:00'), 60, 800);",
    }, " ")

    local pipe = io.popen("sqlite3 " .. path, "w")
    pipe:write(sql)
    pipe:close()

    local stats = Stats:new()

    stats.path = function()
        return path
    end

    local probe = stats:probe(DIGEST)

    check("the file's own record is counted", probe.book_rows == 1, probe.book_rows)

    check("another record under the same title and authors is counted apart",
        probe.other_rows == 1, probe.other_rows)

    check("a record of an unrelated book is left out",
        probe.records ~= nil and not probe.records:find("^3") and not probe.records:find(";3"), probe.records)

    check("each record names its last day and how many page turns it holds, the other record's marked with a tilde",
        probe.records == "2~2026-11-22/1;1=2026-11-19/2", probe.records)

    check("the newest day any book was recorded is reported",
        probe.newest_day == "2026-11-23", probe.newest_day)

    check("so is the journal mode and the size of the database",
        probe.journal ~= nil and (probe.db_bytes or 0) > 0, tostring(probe.journal) .. " " .. tostring(probe.db_bytes))

    os.remove(path)
end

do
    local stats = Stats:new()

    stats.path = function()
        return "/nonexistent/statistics.sqlite3"
    end

    local probe = stats:probe(DIGEST)

    check("a database that cannot be read gives an empty probe, never an error", next(probe) == nil)
end

step("A window with nothing in it is a successful read, not a broken one")

do
    local days, state = Stats:new():daysFor(DIGEST, os.time() + 86400, 0)

    check("a floor past every recorded session still reports a good read",
        state == Stats.OK, state)

    check("with no days behind it", #days == 0, #days)
end

harness.report()
