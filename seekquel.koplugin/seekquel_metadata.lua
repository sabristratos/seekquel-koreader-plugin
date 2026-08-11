local Metadata = {}
Metadata.__index = Metadata

local MAX_CHAPTERS = 500
local MAX_DESCRIPTION = 8000
local MAX_TEXT = 500

function Metadata:new()
    return setmetatable({}, self)
end

function Metadata:collect(ui)
    if ui == nil or ui.document == nil then
        return nil
    end

    local props = ui.doc_props or {}
    local raw = self:rawProps(ui)
    local file = ui.document.file

    return {
        title = self:text(props.display_title or props.title or raw.title),
        authors = self:text(props.authors or raw.authors),
        series = self:text(props.series or raw.series),
        series_index = tonumber(props.series_index or raw.series_index),
        language = self:text(props.language or raw.language),
        description = self:text(props.description or raw.description, MAX_DESCRIPTION),
        keywords = self:text(props.keywords or raw.keywords, MAX_DESCRIPTION),
        identifiers = self:text(raw.identifiers, MAX_DESCRIPTION),
        page_count = self:pageCount(ui),
        format = self:format(file),
        filename = file and file:match("[^/\\]+$") or nil,
        file_size = self:fileSize(file),
        chapters = self:chapters(ui),
    }
end

function Metadata:rawProps(ui)
    local ok, props = pcall(function()
        return ui.document:getProps()
    end)

    if ok and type(props) == "table" then
        return props
    end

    return {}
end

function Metadata:pageCount(ui)
    local ok, count = pcall(function()
        return ui.document:getPageCount()
    end)

    if ok and type(count) == "number" and count > 0 then
        return math.floor(count)
    end

    return nil
end

function Metadata:format(file)
    if type(file) ~= "string" then
        return nil
    end

    local extension = file:match("%.([%a%d]+)$")

    return extension and extension:lower() or nil
end

function Metadata:fileSize(file)
    if type(file) ~= "string" then
        return nil
    end

    local handle = io.open(file, "rb")

    if handle == nil then
        return nil
    end

    local size = handle:seek("end")
    handle:close()

    return size
end

function Metadata:chapters(ui)
    local ok, toc = pcall(function()
        return ui.document:getToc()
    end)

    if not ok or type(toc) ~= "table" then
        return nil
    end

    local chapters = {}

    for _index, entry in ipairs(toc) do
        if type(entry) == "table" and self:text(entry.title) ~= nil then
            table.insert(chapters, {
                title = self:text(entry.title),
                page = tonumber(entry.page),
                depth = tonumber(entry.depth),
            })
        end

        if #chapters >= MAX_CHAPTERS then
            break
        end
    end

    if #chapters == 0 then
        return nil
    end

    return chapters
end

function Metadata:text(value, limit)
    if type(value) ~= "string" then
        return nil
    end

    local trimmed = value:gsub("^%s+", ""):gsub("%s+$", "")

    if trimmed == "" then
        return nil
    end

    return trimmed:sub(1, limit or MAX_TEXT)
end

return Metadata
