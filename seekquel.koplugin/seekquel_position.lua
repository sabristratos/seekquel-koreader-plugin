local Position = {}
Position.__index = Position

local DEFAULT_PAGE_COUNT = 300
local STEP_PAGES = 3
local CONFIRM_TURNS = 3
local MIN_TOLERANCE = 0.001
local MAX_TOLERANCE = 0.05
local MAX_COVERED = 1

function Position:new()
    return setmetatable({}, self):reset()
end

function Position:reset(page_count)
    local pages = tonumber(page_count)

    self.page_count = (pages ~= nil and pages > 0) and pages or nil
    self.anchor = nil
    self.visit = nil
    self.covered = 0

    return self
end

function Position:tolerance()
    local span = STEP_PAGES / (self.page_count or DEFAULT_PAGE_COUNT)

    if span < MIN_TOLERANCE then
        return MIN_TOLERANCE
    end

    if span > MAX_TOLERANCE then
        return MAX_TOLERANCE
    end

    return span
end

function Position:observe(progress, percent)
    if progress == nil then
        return
    end

    local reached = tonumber(percent) or 0

    if self.anchor == nil then
        self.anchor = { progress = progress, percent = reached }

        return
    end

    if self.visit ~= nil then
        self:continueVisit(progress, reached)

        return
    end

    if reached > self.anchor.percent + self:tolerance() then
        self.visit = { progress = progress, percent = reached, turns = 0, covered = 0 }

        return
    end

    self:moveTo(progress, reached)
end

function Position:continueVisit(progress, reached)
    local drift = reached - self.visit.percent
    local tolerance = self:tolerance()

    if drift > tolerance or drift < -tolerance then
        if reached > self.anchor.percent + tolerance then
            self.visit = { progress = progress, percent = reached, turns = 0, covered = 0 }
        else
            self.visit = nil
            self:moveTo(progress, reached)
        end

        return
    end

    if drift > 0 then
        self.visit.covered = self.visit.covered + drift
        self.visit.turns = self.visit.turns + 1
    end

    self.visit.progress = progress
    self.visit.percent = reached

    if self.visit.turns < CONFIRM_TURNS then
        return
    end

    self.covered = self.covered + self.visit.covered
    self.anchor = { progress = progress, percent = reached }
    self.visit = nil
end

function Position:moveTo(progress, reached)
    local gained = reached - self.anchor.percent

    if gained > 0 then
        self.covered = self.covered + gained
    end

    self.anchor = { progress = progress, percent = reached }
end

function Position:reportable()
    if self.anchor == nil then
        return nil, nil, nil
    end

    local covered = self.covered

    if covered > MAX_COVERED then
        covered = MAX_COVERED
    end

    return self.anchor.progress, self.anchor.percent, covered
end

function Position:settle(progress, percent)
    if progress == nil then
        return
    end

    self.anchor = { progress = progress, percent = tonumber(percent) or 0 }
    self.visit = nil
end

function Position:commit()
    self.covered = 0
end

return Position
