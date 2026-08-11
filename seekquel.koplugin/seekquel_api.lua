local http = require("socket.http")
local json = require("json")
local logger = require("logger")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local url = require("socket.url")

local BLOCK_TIMEOUT = 5
local TOTAL_TIMEOUT = 12
local UPLOAD_BLOCK_TIMEOUT = 10
local UPLOAD_TOTAL_TIMEOUT = 30
local DOWNLOAD_BLOCK_TIMEOUT = 15
local DOWNLOAD_TOTAL_TIMEOUT = 120
local LEAVING_BLOCK_TIMEOUT = 1
local LEAVING_TOTAL_TIMEOUT = 2
local SLOW_CALL_SECONDS = 5
local BACKOFF_SECONDS = 120

local UPLOAD_TIMEOUT = { block = UPLOAD_BLOCK_TIMEOUT, total = UPLOAD_TOTAL_TIMEOUT }

local Api = {}
Api.__index = Api
Api.LEAVING_TIMEOUT = { block = LEAVING_BLOCK_TIMEOUT, total = LEAVING_TOTAL_TIMEOUT }

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

function Api:clearBackoff()
    self.settings:clearUnreachable()
end

function Api:request(method, path, body, query, timeout)
    if self.settings:isUnreachable() then
        logger.warn("Seekquel: skipping", method, path, "until the server answers again")

        return nil, nil
    end

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

    local block = timeout and timeout.block or BLOCK_TIMEOUT
    local total = timeout and timeout.total or TOTAL_TIMEOUT

    socketutil:set_timeout(block, total)

    local label = method .. " " .. path
    local started = os.time()

    self.settings:markBusy(label)

    local ok, result, code = pcall(requester, {
        url = endpoint,
        method = method,
        headers = headers,
        source = payload and ltn12.source.string(payload) or nil,
        sink = socketutil.table_sink(sink),
    })

    socketutil:reset_timeout()

    local elapsed = os.time() - started

    self.settings:clearBusy()
    self.settings:recordTiming(label, elapsed)

    if elapsed >= SLOW_CALL_SECONDS then
        logger.warn("Seekquel:", label, "took", elapsed, "seconds")
    end

    if not ok or result == nil then
        logger.warn("Seekquel: could not reach", method, path, tostring(code))
        self.settings:markUnreachable(BACKOFF_SECONDS)

        return nil, nil
    end

    self.settings:clearUnreachable()

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

function Api:pluginManifest()
    return self:request("GET", "/plugin/manifest")
end

function Api:downloadPlugin(destination)
    local endpoint = self.settings:syncUrl() .. "/plugin.zip"
    local parsed = url.parse(endpoint)

    if not parsed then
        return false
    end

    local file = io.open(destination, "wb")

    if file == nil then
        return false
    end

    local requester = parsed.scheme == "https" and require("ssl.https").request or http.request
    local label = "GET /plugin.zip"

    socketutil:set_timeout(DOWNLOAD_BLOCK_TIMEOUT, DOWNLOAD_TOTAL_TIMEOUT)
    self.settings:markBusy(label)

    local ok, result, code = pcall(requester, {
        url = endpoint,
        method = "GET",
        headers = { ["accept"] = "application/zip" },
        sink = ltn12.sink.file(file),
    })

    socketutil:reset_timeout()
    self.settings:clearBusy()

    local status = tonumber(code)

    if not ok or result == nil or status == nil or status < 200 or status > 299 then
        logger.warn("Seekquel: could not download the add-on", tostring(code))
        os.remove(destination)

        return false
    end

    return true
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

function Api:pushProgress(digest, progress, percentage, device, metadata, timeout)
    return self:request("PUT", "/syncs/progress", {
        document = digest,
        progress = tostring(progress),
        percentage = percentage,
        device = device,
        device_id = self.settings:get("device_id"),
        metadata = metadata,
    }, nil, timeout)
end

function Api:pushMetadata(digest, metadata)
    local body = self:request("PUT", "/documents/" .. digest .. "/metadata", metadata)

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

function Api:setRating(digest, rating)
    local body = self:request("PUT", "/documents/" .. digest .. "/rating", { rating = rating })

    return body and body.data or nil
end

function Api:searchBooks(query)
    local body = self:request("GET", "/books/search", nil, { q = query })

    return body and body.data or {}
end

function Api:pushSessions(digest, days, timeout)
    return self:request("POST", "/sessions", { document = digest, days = days }, nil, timeout or UPLOAD_TIMEOUT)
end

function Api:pushHighlights(digest, highlights, timeout)
    return self:request("POST", "/highlights", { document = digest, highlights = highlights }, nil, timeout or UPLOAD_TIMEOUT)
end

return Api
