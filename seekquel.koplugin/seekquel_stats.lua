local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")

local Stats = {}
Stats.__index = Stats

local DB_NAME = "statistics.sqlite3"
local MAX_DAYS = 400
local HOURS_PER_DAY = 24
local PROBE_MAX_RECORDS = 4

Stats.OK = "ok"
Stats.UNREADABLE = "unreadable"
Stats.UNTRACKED = "untracked"

function Stats:new()
    return setmetatable({}, self)
end

function Stats:path()
    return DataStorage:getSettingsDir() .. "/" .. DB_NAME
end

function Stats:daysFor(digest, since_time, offset_minutes)
    local result = self:query(digest, since_time, offset_minutes)

    if type(result) ~= "table" then
        return {}, Stats.UNREADABLE
    end

    return result.days, result.state
end

function Stats:dayModifier(offset_minutes)
    local offset = tonumber(offset_minutes)

    if offset == nil then
        return "'localtime'"
    end

    return string.format("'%+d minutes'", math.floor(offset))
end

function Stats:query(digest, since_time, offset_minutes)
    local ok, result = pcall(function()
        local conn = SQ3.open(self:path(), "ro")

        if conn == nil then
            return nil
        end

        local book_ids = self:bookIds(conn, digest)

        if book_ids == nil then
            conn:close()

            return { days = {}, state = Stats.UNTRACKED }
        end

        local floor = math.max(0, math.floor(tonumber(since_time) or 0))

        local sql = string.format([[
            SELECT date(start_time, 'unixepoch', %s) AS day,
                   SUM(duration) AS seconds,
                   COUNT(DISTINCT page) AS pages,
                   MAX(CASE WHEN total_pages >= 1
                            THEN (page - 1) * 1.0 / total_pages
                       END) AS reached
            FROM page_stat_data
            WHERE id_book IN (%s) AND start_time >= %d
            GROUP BY day
            ORDER BY day DESC
            LIMIT %d;
        ]], self:dayModifier(offset_minutes), book_ids, floor, MAX_DAYS)

        local columns = conn:exec(sql)

        if columns == nil then
            conn:close()

            return { days = {}, state = Stats.OK }
        end

        local days = {}
        local byDate = {}

        for index = 1, #columns[1] do
            local day = {
                date = columns[1][index],
                seconds = math.floor(tonumber(columns[2][index]) or 0),
                pages = math.floor(tonumber(columns[3][index]) or 0),
                reached = self:reached(columns[4][index]),
            }

            table.insert(days, day)
            byDate[day.date] = day
        end

        pcall(function()
            self:attachHours(conn, byDate, book_ids, floor, offset_minutes)
        end)

        pcall(function()
            self:attachFractions(conn, byDate, book_ids, floor, offset_minutes)
        end)

        conn:close()

        return { days = days, state = Stats.OK }
    end)

    if not ok then
        logger.warn("Seekquel: could not read the reading statistics", result)

        return nil
    end

    return result
end

function Stats:fileSize(path)
    local file = io.open(path, "rb")

    if file == nil then
        return nil
    end

    local size = file:seek("end")

    file:close()

    return size
end

function Stats:probe(digest)
    local ok, result = pcall(function()
        local conn = SQ3.open(self:path(), "ro")

        if conn == nil then
            return nil
        end

        local quoted = self:quote(digest)

        local columns = conn:exec(string.format([[
            SELECT b.id,
                   b.md5 = %s AS same_file,
                   COALESCE(date(MAX(p.start_time), 'unixepoch'), '') AS newest,
                   COUNT(p.start_time) AS turns
            FROM book b
            LEFT JOIN page_stat_data p ON p.id_book = b.id
            WHERE b.md5 = %s
               OR (b.title, b.authors) IN (SELECT title, authors FROM book WHERE md5 = %s)
            GROUP BY b.id
            ORDER BY newest DESC
            LIMIT %d;
        ]], quoted, quoted, quoted, PROBE_MAX_RECORDS))

        local records = {}
        local book_rows = 0
        local other_rows = 0

        if columns ~= nil then
            for index = 1, #columns[1] do
                local same_file = tonumber(columns[2][index]) == 1

                if same_file then
                    book_rows = book_rows + 1
                else
                    other_rows = other_rows + 1
                end

                table.insert(records, string.format(
                    "%d%s%s/%d",
                    tonumber(columns[1][index]),
                    same_file and "=" or "~",
                    tostring(columns[3][index]),
                    tonumber(columns[4][index]) or 0
                ))
            end
        end

        local newest_day = conn:rowexec("SELECT date(MAX(start_time), 'unixepoch') FROM page_stat_data;")
        local journal = conn:rowexec("PRAGMA journal_mode;")

        conn:close()

        return {
            records = table.concat(records, ";"),
            book_rows = book_rows,
            other_rows = other_rows,
            newest_day = newest_day ~= nil and tostring(newest_day) or nil,
            journal = journal ~= nil and tostring(journal) or nil,
            db_bytes = self:fileSize(self:path()),
            wal_bytes = self:fileSize(self:path() .. "-wal"),
        }
    end)

    if not ok or type(result) ~= "table" then
        return {}
    end

    return result
end

function Stats:bookIds(conn, digest)
    local columns = conn:exec(string.format(
        "SELECT id FROM book WHERE md5 = %s;",
        self:quote(digest)
    ))

    if columns == nil then
        return nil
    end

    local ids = {}

    for index = 1, #columns[1] do
        table.insert(ids, string.format("%d", tonumber(columns[1][index])))
    end

    return table.concat(ids, ",")
end

function Stats:attachHours(conn, byDate, book_ids, floor, offset_minutes)
    local modifier = self:dayModifier(offset_minutes)

    local sql = string.format([[
        SELECT date(start_time, 'unixepoch', %s) AS day,
               CAST(strftime('%%H', start_time, 'unixepoch', %s) AS INTEGER) AS hour,
               SUM(duration) AS seconds
        FROM page_stat_data
        WHERE id_book IN (%s) AND start_time >= %d
        GROUP BY day, hour
        ORDER BY day DESC
        LIMIT %d;
    ]], modifier, modifier, book_ids, floor, MAX_DAYS * HOURS_PER_DAY)

    local columns = conn:exec(sql)

    if columns == nil then
        return
    end

    for index = 1, #columns[1] do
        local day = byDate[columns[1][index]]

        if day ~= nil then
            local hour = tonumber(columns[2][index])
            local seconds = math.floor(tonumber(columns[3][index]) or 0)

            if hour ~= nil and seconds > 0 then
                day.hours = day.hours or {}
                day.hours[tostring(math.floor(hour))] = seconds
            end
        end
    end
end

function Stats:attachFractions(conn, byDate, book_ids, floor, offset_minutes)
    local sql = string.format([[
        SELECT day, SUM(1.0 / total_pages) AS fraction
        FROM (
            SELECT DISTINCT date(start_time, 'unixepoch', %s) AS day, page, total_pages
            FROM page_stat_data
            WHERE id_book IN (%s) AND start_time >= %d AND total_pages >= 1
        )
        GROUP BY day
        ORDER BY day DESC
        LIMIT %d;
    ]], self:dayModifier(offset_minutes), book_ids, floor, MAX_DAYS)

    local columns = conn:exec(sql)

    if columns == nil then
        return
    end

    for index = 1, #columns[1] do
        local day = byDate[columns[1][index]]
        local fraction = tonumber(columns[2][index])

        if day ~= nil and fraction ~= nil then
            day.fraction = math.max(0, math.min(1, fraction))
        end
    end
end

function Stats:reached(value)
    local fraction = tonumber(value)

    if fraction == nil then
        return nil
    end

    return math.max(0, math.min(1, fraction))
end

function Stats:quote(value)
    return "'" .. tostring(value):gsub("'", "''") .. "'"
end

return Stats
