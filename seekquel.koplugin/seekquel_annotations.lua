local md5 = require("ffi/sha2").md5

local Annotations = {}
Annotations.__index = Annotations

local MAX_HIGHLIGHTS = 500

function Annotations:new()
    return setmetatable({}, self)
end

function Annotations:collect(annotations)
    if type(annotations) ~= "table" then
        return {}
    end

    local collected = {}

    for _, annotation in ipairs(annotations) do
        if self:isHighlight(annotation) then
            table.insert(collected, self:toPayload(annotation))
        end

        if #collected >= MAX_HIGHLIGHTS then
            break
        end
    end

    return collected
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

function Annotations:identify(annotation)
    local anchor = annotation.pos0 or annotation.page or annotation.pageno or ""

    return md5(tostring(annotation.datetime or "") .. "|" .. tostring(anchor))
end

return Annotations
