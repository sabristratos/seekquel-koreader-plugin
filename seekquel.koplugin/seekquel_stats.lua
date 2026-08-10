local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")

local Stats = {}
Stats.__index = Stats

local DB_NAME = "statistics.sqlite3"
local SECONDS_PER_DAY = 86400
local MAX_DAYS = 400

function Stats:new()
    return setmetatable({}, self)
end

function Stats:path()
    return DataStorage:getSettingsDir() .. "/" .. DB_NAME
end

function Stats:daysFor(digest, since_days)
    local rows = self:query(digest, since_days)

    if rows == nil then
        return {}
    end

    return rows
end

function Stats:query(digest, since_days)
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

        local floor = 0

        if since_days ~= nil then
            floor = os.time() - (since_days * SECONDS_PER_DAY)
        end

        local sql = string.format([[
            SELECT date(start_time, 'unixepoch', 'localtime') AS day,
                   SUM(duration) AS seconds,
                   COUNT(DISTINCT page) AS pages
            FROM page_stat_data
            WHERE id_book = %d AND start_time >= %d
            GROUP BY day
            ORDER BY day DESC
            LIMIT %d;
        ]], tonumber(book_id), floor, MAX_DAYS)

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
