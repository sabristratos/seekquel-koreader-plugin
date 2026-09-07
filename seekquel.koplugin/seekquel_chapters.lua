local Chapters = {}
Chapters.__index = Chapters

local MAX_CHAPTERS = 300
local MIN_CHAPTERS = 2
local MAX_PAYLOAD = 500

function Chapters:new()
    return setmetatable({}, self):reset()
end

function Chapters:reset()
    self.marks = nil

    return self
end

function Chapters:load(ui)
    self:reset()

    if ui == nil or ui.document == nil then
        return self
    end

    local pages = self:pageCount(ui)

    if pages == nil then
        return self
    end

    local ok, toc = pcall(function()
        return ui.document:getToc()
    end)

    if not ok or type(toc) ~= "table" then
        return self
    end

    local entries = self:entries(toc)
    local kept, cap = self:keptDepths(entries)

    if kept == nil then
        return self
    end

    local marks = {}

    for _index, entry in ipairs(entries) do
        if kept[entry.depth] then
            table.insert(marks, math.max(0, math.min(1, (entry.page - 1) / pages)))
        end

        if #marks >= cap then
            break
        end
    end

    if #marks < MIN_CHAPTERS then
        return self
    end

    self.marks = marks

    return self
end

function Chapters:entries(toc)
    local entries = {}

    for _index, entry in ipairs(toc) do
        if type(entry) == "table" and tonumber(entry.page) ~= nil and self:hasTitle(entry) then
            table.insert(entries, {
                page = tonumber(entry.page),
                depth = tonumber(entry.depth) or 1,
            })
        end

        if #entries >= MAX_PAYLOAD then
            break
        end
    end

    return entries
end

function Chapters:hasTitle(entry)
    if type(entry.title) ~= "string" then
        return false
    end

    return entry.title:gsub("^%s+", ""):gsub("%s+$", "") ~= ""
end

function Chapters:keptDepths(entries)
    local counts = {}
    local depths = {}

    for _index, entry in ipairs(entries) do
        if counts[entry.depth] == nil then
            counts[entry.depth] = 0
            table.insert(depths, entry.depth)
        end

        counts[entry.depth] = counts[entry.depth] + 1
    end

    if #depths == 0 then
        return nil, 0
    end

    table.sort(depths)

    local kept = {}
    local total = 0

    for _index, depth in ipairs(depths) do
        if total + counts[depth] > MAX_CHAPTERS then
            break
        end

        kept[depth] = true
        total = total + counts[depth]
    end

    if total == 0 then
        kept[depths[1]] = true

        return kept, MAX_CHAPTERS
    end

    return kept, total
end

function Chapters:pageCount(ui)
    local ok, count = pcall(function()
        return ui.document:getPageCount()
    end)

    if not ok or type(count) ~= "number" or count < 1 then
        return nil
    end

    return math.floor(count)
end

function Chapters:count()
    if self.marks == nil then
        return nil
    end

    return #self.marks
end

function Chapters:at(percent)
    if self.marks == nil then
        return nil
    end

    local reached = tonumber(percent)

    if reached == nil then
        return nil
    end

    if reached < 0 then
        reached = 0
    end

    local position = 1

    for index = 1, #self.marks do
        if self.marks[index] <= reached then
            position = index
        else
            break
        end
    end

    return position
end

return Chapters
