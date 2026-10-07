local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local QRWidget = require("ui/widget/qrwidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local Screen = Device.screen

local DIALOG_WIDTH_RATIO = 0.85
local QR_HEIGHT_RATIO = 0.4
local CODE_FONT_SIZE = 32

local PairingDialog = InputContainer:extend({
    modal = true,
    instructions = nil,
    code = nil,
    link = nil,
    cancel_callback = nil,
})

function PairingDialog:init()
    if Device:hasKeys() then
        self.key_events.Cancel = { { Device.input.group.Back } }
    end

    local width = math.floor(Screen:getWidth() * DIALOG_WIDTH_RATIO)
    local padding = Size.padding.large
    local inner = width - 2 * (padding + Size.border.window)
    local span = Size.span.vertical_large

    local group = VerticalGroup:new({ align = "center" })

    table.insert(group, TextBoxWidget:new({
        text = self.instructions,
        face = Font:getFace("infofont"),
        width = inner,
        alignment = "center",
    }))

    if self.link then
        local side = math.min(inner, math.floor(Screen:getHeight() * QR_HEIGHT_RATIO))

        table.insert(group, VerticalSpan:new({ width = span }))
        table.insert(group, QRWidget:new({
            text = self.link,
            width = side,
            height = side,
        }))
    end

    table.insert(group, VerticalSpan:new({ width = span }))
    table.insert(group, TextWidget:new({
        text = self.code,
        face = Font:getFace("infofont", CODE_FONT_SIZE),
    }))
    table.insert(group, VerticalSpan:new({ width = span }))
    table.insert(group, Button:new({
        text = _("Cancel"),
        width = inner,
        show_parent = self,
        callback = function()
            self:onCancel()
        end,
    }))

    self.frame = FrameContainer:new({
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = padding,
        group,
    })

    self[1] = CenterContainer:new({
        dimen = Screen:getSize(),
        self.frame,
    })
end

function PairingDialog:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.frame.dimen
    end)

    return true
end

function PairingDialog:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "ui", self.frame.dimen
    end)
end

function PairingDialog:onCancel()
    if self.cancel_callback then
        self.cancel_callback()
    end

    return true
end

return PairingDialog
