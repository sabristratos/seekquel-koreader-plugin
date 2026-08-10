local dkjson = require("dkjson")
local ltn12 = require("ltn12")
local md5lib = require("md5")

local recorder = {
    messages = {},
    dialogs = {},
    scheduled = {},
}

local function preload(name, module)
    package.preload[name] = function()
        return module
    end
end

local function widget(kind)
    return {
        new = function(_, spec)
            spec = spec or {}
            spec.__kind = kind
            table.insert(recorder.dialogs, spec)

            if kind == "InfoMessage" and spec.text then
                table.insert(recorder.messages, spec.text)
            end

            spec.getInputText = function(self)
                return self.input
            end
            spec.onShowKeyboard = function() end

            return spec
        end,
    }
end

preload("ui/widget/infomessage", widget("InfoMessage"))
preload("ui/widget/inputdialog", widget("InputDialog"))
preload("ui/widget/buttondialog", widget("ButtonDialog"))

preload("ui/uimanager", {
    show = function(_, w) return w end,
    close = function() end,
    scheduleIn = function(_, seconds, task)
        table.insert(recorder.scheduled, { seconds = seconds, task = task })
    end,
    unschedule = function() end,
})

local WidgetContainer = {}
WidgetContainer.__index = WidgetContainer

function WidgetContainer:extend(subclass)
    subclass = subclass or {}
    subclass.__index = subclass
    subclass.extend = WidgetContainer.extend
    subclass.new = WidgetContainer.new
    setmetatable(subclass, { __index = self })

    return subclass
end

function WidgetContainer:new(instance)
    instance = instance or {}
    setmetatable(instance, self)

    if instance.init then
        instance:init()
    end

    return instance
end

preload("ui/widget/container/widgetcontainer", WidgetContainer)

preload("device", { model = "HarnessReader" })

preload("ui/network/manager", {
    isOnline = function() return true end,
    runWhenOnline = function(_, task) task() end,
})

preload("gettext", setmetatable({}, {
    __call = function(_, text) return text end,
}))

preload("ffi/util", {
    template = function(text, ...)
        local args = { ... }

        return (tostring(text):gsub("%%(%d+)", function(index)
            return tostring(args[tonumber(index)] or "")
        end))
    end,
})

preload("ffi/sha2", { md5 = md5lib.sumhexa })

preload("logger", {
    warn = function(...)
        local parts = {}
        for _, value in ipairs({ ... }) do
            table.insert(parts, tostring(value))
        end
        io.stderr:write("  [plugin warn] " .. table.concat(parts, " ") .. "\n")
    end,
    info = function() end,
    dbg = function() end,
})

preload("datastorage", {
    getSettingsDir = function() return os.getenv("HARNESS_SETTINGS_DIR") or "/tmp/koreader" end,
})

local LuaSettings = {}
LuaSettings.__index = LuaSettings

function LuaSettings:open(path)
    local instance = setmetatable({ path = path, data = {} }, self)
    local file = loadfile(path)

    if file then
        local ok, loaded = pcall(file)

        if ok and type(loaded) == "table" then
            instance.data = loaded
        end
    end

    return instance
end

function LuaSettings:readSetting(key)
    return self.data[key]
end

function LuaSettings:saveSetting(key, value)
    self.data[key] = value

    return self
end

local function serialise(value, indent)
    indent = indent or ""

    if type(value) == "table" then
        local parts = { "{\n" }

        for k, v in pairs(value) do
            local key = type(k) == "string" and string.format("[%q]", k) or "[" .. tostring(k) .. "]"
            table.insert(parts, indent .. "  " .. key .. " = " .. serialise(v, indent .. "  ") .. ",\n")
        end

        table.insert(parts, indent .. "}")

        return table.concat(parts)
    end

    if type(value) == "string" then
        return string.format("%q", value)
    end

    return tostring(value)
end

function LuaSettings:flush()
    local handle = io.open(self.path, "w")

    if handle == nil then
        return
    end

    handle:write("return " .. serialise(self.data) .. "\n")
    handle:close()
end

preload("luasettings", LuaSettings)

local SQ3 = {}
local Conn = {}
Conn.__index = Conn

local SEPARATOR = "\30"

function SQ3.open(path, _mode)
    local probe = io.open(path, "r")

    if probe == nil then
        return nil
    end

    probe:close()

    return setmetatable({ path = path }, Conn)
end

function Conn:run(sql)
    local script = os.tmpname()
    local handle = io.open(script, "w")
    handle:write(".separator \"" .. SEPARATOR .. "\"\n" .. sql .. "\n")
    handle:close()

    local pipe = io.popen("sqlite3 " .. self.path .. " < " .. script .. " 2>/dev/null")
    local output = pipe:read("*a")
    pipe:close()
    os.remove(script)

    local rows = {}

    for line in output:gmatch("[^\n]+") do
        local cells = {}

        for cell in (line .. SEPARATOR):gmatch("(.-)" .. SEPARATOR) do
            table.insert(cells, cell)
        end

        table.insert(rows, cells)
    end

    return rows
end

function Conn:rowexec(sql)
    local rows = self:run(sql)

    if #rows == 0 then
        return nil
    end

    return rows[1][1]
end

function Conn:exec(sql)
    local rows = self:run(sql)

    if #rows == 0 then
        return nil
    end

    local columns = {}

    for column = 1, #rows[1] do
        columns[column] = {}

        for row = 1, #rows do
            columns[column][row] = rows[row][column]
        end
    end

    return columns
end

function Conn:close() end

preload("lua-ljsqlite3/init", SQ3)

local function nullSentinel()
    return nullSentinel
end

local function asKoreaderJson(value)
    if type(value) ~= "table" then
        return value
    end

    for key, item in pairs(value) do
        if item == dkjson.null then
            value[key] = nullSentinel
        elseif type(item) == "table" then
            asKoreaderJson(item)
        end
    end

    return value
end

preload("json", {
    encode = function(value) return dkjson.encode(value) end,
    decode = function(text) return asKoreaderJson(dkjson.decode(text, 1, dkjson.null)) end,
})

preload("mime", {
    b64 = function(bytes) return (bytes:gsub(".", function() return "A" end)), nil end,
})

preload("socketutil", {
    set_timeout = function() end,
    reset_timeout = function() end,
    table_sink = function(t) return ltn12.sink.table(t) end,
})

return recorder
