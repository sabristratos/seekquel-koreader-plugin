local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")

local Stats = {}
Stats.__index = Stats

local DB_NAME = "statistics.sqlite3"
local MAX_DAYS = 400
local HOURS_PER_DAY = 24

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

        local book_id = conn:rowexec(string.format(
            "SELECT id FROM book WHERE md5 = %s LIMIT 1;",
            self:quote(digest)
        ))

        if book_id == nil then
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
            WHERE id_book = %d AND start_time >= %d
            GROUP BY day
            ORDER BY day DESC
            LIMIT %d;
        ]], self:dayModifier(offset_minutes), tonumber(book_id), floor, MAX_DAYS)

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
            self:attachHours(conn, byDate, book_id, floor, offset_minutes)
        end)

        pcall(function()
            self:attachFractions(conn, byDate, book_id, floor, offset_minutes)
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

function Stats:attachHours(conn, byDate, book_id, floor, offset_minutes)
    local modifier = self:dayModifier(offset_minutes)

    local sql = string.format([[
        SELECT date(start_time, 'unixepoch', %s) AS day,
               CAST(strftime('%%H', start_time, 'unixepoch', %s) AS INTEGER) AS hour,
               SUM(duration) AS seconds
        FROM page_stat_data
        WHERE id_book = %d AND start_time >= %d
        GROUP BY day, hour
        ORDER BY day DESC
        LIMIT %d;
    ]], modifier, modifier, tonumber(book_id), floor, MAX_DAYS * HOURS_PER_DAY)

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

function Stats:attachFractions(conn, byDate, book_id, floor, offset_minutes)
    local sql = string.format([[
        SELECT day, SUM(1.0 / total_pages) AS fraction
        FROM (
            SELECT DISTINCT date(start_time, 'unixepoch', %s) AS day, page, total_pages
            FROM page_stat_data
            WHERE id_book = %d AND start_time >= %d AND total_pages >= 1
        )
        GROUP BY day
        ORDER BY day DESC
        LIMIT %d;
    ]], self:dayModifier(offset_minutes), tonumber(book_id), floor, MAX_DAYS)

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
