local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")

local Stats = {}
Stats.__index = Stats

local DB_NAME = "statistics.sqlite3"
local MAX_DAYS = 400

function Stats:new()
    return setmetatable({}, self)
end

function Stats:path()
    return DataStorage:getSettingsDir() .. "/" .. DB_NAME
end

function Stats:daysFor(digest, since_time, offset_minutes)
    local rows = self:query(digest, since_time, offset_minutes)

    if rows == nil then
        return {}
    end

    return rows
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

            return nil
        end

        local floor = math.max(0, math.floor(tonumber(since_time) or 0))

        local sql = string.format([[
            SELECT date(start_time, 'unixepoch', %s) AS day,
                   SUM(duration) AS seconds,
                   COUNT(DISTINCT page) AS pages
            FROM page_stat_data
            WHERE id_book = %d AND start_time >= %d
            GROUP BY day
            ORDER BY day DESC
            LIMIT %d;
        ]], self:dayModifier(offset_minutes), tonumber(book_id), floor, MAX_DAYS)

        local columns = conn:exec(sql)
        conn:close()

        if columns == nil then
            return nil
        end

        local days = {}

        for index = 1, #columns[1] do
            table.insert(days, {
                date = columns[1][index],
                seconds = math.floor(tonumber(columns[2][index]) or 0),
                pages = math.floor(tonumber(columns[3][index]) or 0),
            })
        end

        return days
    end)

    if not ok then
        logger.warn("Seekquel: could not read the reading statistics", result)

        return nil
    end

    return result
end

function Stats:quote(value)
    return "'" .. tostring(value):gsub("'", "''") .. "'"
end

return Stats
