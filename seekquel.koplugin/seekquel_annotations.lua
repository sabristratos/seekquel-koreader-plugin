local md5 = require("ffi/sha2").md5

local Annotations = {}
Annotations.__index = Annotations

local MAX_HIGHLIGHTS = 500

function Annotations:new()
    return setmetatable({}, self)
end

function Annotations:collect(annotations)
    if type(annotations) ~= "table" then
        return {}, 0
    end

    local collected = {}
    local total = 0

    for _, annotation in ipairs(annotations) do
        if self:isHighlight(annotation) then
            total = total + 1

            if #collected < MAX_HIGHLIGHTS then
                table.insert(collected, self:toPayload(annotation))
            end
        end
    end

    return collected, total
end

function Annotations:fingerprint(payload)
    return md5(tostring(payload.text or "") .. "|" .. tostring(payload.note or ""))
end

function Annotations:isHighlight(annotation)
    return type(annotation) == "table"
        and annotation.drawer ~= nil
        and type(annotation.text) == "string"
        and annotation.text ~= ""
end

function Annotations:toPayload(annotation)
    return {
        external_id = self:identify(annotation),
        text = annotation.text,
        note = annotation.note,
        chapter = annotation.chapter,
        page = tonumber(annotation.pageno),
        created_at = annotation.datetime,
    }
end

function Annotations:anchor(value)
    if type(value) == "string" then
        return value
    end

    if type(value) == "number" then
        return tostring(value)
    end

    if type(value) ~= "table" then
        return ""
    end

    local page = value.page or value.pageno

    if page == nil then
        return ""
    end

    return table.concat({
        tostring(page),
        tostring(value.x or ""),
        tostring(value.y or ""),
    }, ",")
end

function Annotations:identify(annotation)
    local anchor = self:anchor(annotation.pos0)

    if anchor == "" then
        anchor = self:anchor(annotation.page)
    end

    if anchor == "" then
        anchor = self:anchor(annotation.pageno)
    end

    return md5(tostring(annotation.datetime or "") .. "|" .. anchor)
end

return Annotations
