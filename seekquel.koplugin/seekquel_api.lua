local http = require("socket.http")
local json = require("json")
local logger = require("logger")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local url = require("socket.url")

local Api = {}
Api.__index = Api

local BLOCK_TIMEOUT = 10
local TOTAL_TIMEOUT = 25

local function withoutNulls(value)
    if type(value) ~= "table" then
        return value
    end

    for key, item in pairs(value) do
        if type(item) == "function" then
            value[key] = nil
        elseif type(item) == "table" then
            withoutNulls(item)
        end
    end

    return value
end

function Api:new(settings)
    return setmetatable({ settings = settings }, self)
end

function Api:isConfigured()
    return self.settings:isConnected()
end

function Api:request(method, path, body, query)
    local endpoint = self.settings:syncUrl() .. path

    if query then
        endpoint = endpoint .. "?" .. self:encodeQuery(query)
    end

    local parsed = url.parse(endpoint)

    if not parsed then
        logger.warn("Seekquel: could not parse", endpoint)

        return nil, nil
    end

    local requester = parsed.scheme == "https" and require("ssl.https").request or http.request
    local payload = body and json.encode(body) or nil
    local sink = {}

    local headers = {
        ["accept"] = "application/json",
    }

    local key = self.settings:key()

    if key then
        headers["x-auth-user"] = key
    end

    if payload then
        headers["content-type"] = "application/json"
        headers["content-length"] = tostring(#payload)
    end

    socketutil:set_timeout(BLOCK_TIMEOUT, TOTAL_TIMEOUT)

    local ok, result, code = pcall(requester, {
        url = endpoint,
        method = method,
        headers = headers,
        source = payload and ltn12.source.string(payload) or nil,
        sink = socketutil.table_sink(sink),
    })

    socketutil:reset_timeout()

    if not ok or result == nil then
        logger.warn("Seekquel: could not reach", method, path, tostring(code))

        return nil, nil
    end

    local status = tonumber(code)
    local content = table.concat(sink)

    if status == nil or status < 200 or status > 299 then
        logger.warn("Seekquel:", method, path, "answered", tostring(code))

        return nil, status
    end

    if content == "" then
        return {}, status
    end

    local decoded_ok, decoded = pcall(json.decode, content)

    if not decoded_ok then
        logger.warn("Seekquel: could not read the answer to", path)

        return nil, status
    end

    return withoutNulls(decoded), status
end

function Api:encodeQuery(query)
    local parts = {}

    for name, value in pairs(query) do
        table.insert(parts, name .. "=" .. url.escape(tostring(value)))
    end

    return table.concat(parts, "&")
end

function Api:startPairing(device_name, platform)
    return self:request("POST", "/pair/start", {
        device_name = device_name,
        platform = platform,
    })
end

function Api:pollPairing(device_code)
    return self:request("POST", "/pair/poll", { device_code = device_code })
end

function Api:reportDevice(payload)
    return self:request("PUT", "/device", payload)
end

function Api:pushProgress(digest, progress, percentage, device, metadata)
    return self:request("PUT", "/syncs/progress", {
        document = digest,
        progress = tostring(progress),
        percentage = percentage,
        device = device,
        device_id = self.settings:get("device_id"),
        metadata = metadata,
    })
end

function Api:pushMetadata(digest, metadata)
    local body = self:request("PUT", "/documents/" .. digest .. "/metadata", metadata)

    return body and body.data or nil
end

function Api:pushCover(digest, image, content_type)
    local body = self:request("PUT", "/documents/" .. digest .. "/cover", {
        image = image,
        content_type = content_type,
    })

    return body and body.data or nil
end

function Api:document(digest)
    local body = self:request("GET", "/documents/" .. digest)

    return body and body.data or nil
end

function Api:linkDocument(digest, work_id)
    local body = self:request("PUT", "/documents/" .. digest .. "/link", { work_id = work_id })

    return body and body.data or nil
end

function Api:setStatus(digest, status)
    local body = self:request("PUT", "/documents/" .. digest .. "/status", { status = status })

    return body and body.data or nil
end

function Api:searchBooks(query)
    local body = self:request("GET", "/books/search", nil, { q = query })

    return body and body.data or {}
end

function Api:pushSessions(digest, days)
    return self:request("POST", "/sessions", { document = digest, days = days })
end

function Api:pushHighlights(digest, highlights)
    return self:request("POST", "/highlights", { document = digest, highlights = highlights })
end

return Api
