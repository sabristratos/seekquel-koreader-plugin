package.path = "/plugin/seekquel.koplugin/?.lua;/plugin/spec/?.lua;" .. package.path

local Position = require("seekquel_position")
local harness = require("harness")

local check = harness.check
local step = harness.step

local PAGES = 300
local EPSILON = 1e-9

local function at(page)
    return page / PAGES
end

local function about(value, expected)
    return value ~= nil and math.abs(value - expected) < EPSILON
end

local function opened(page)
    local position = Position:new()

    position:reset(PAGES)
    position:observe("page-" .. page, at(page))

    return position
end

local function turn(position, from, pages)
    for index = 1, pages do
        position:observe("page-" .. (from + index), at(from + index))
    end

    return from + pages
end

local function reported(position)
    return select(2, position:reportable())
end

local function claimed(position)
    return select(3, position:reportable())
end

step("Opening a book fixes where the reader is")

do
    local position = opened(39)
    local progress, percent, covered = position:reportable()

    check("the position the file restored to is what gets reported",
        progress == "page-39" and about(percent, at(39)), progress)
    check("nothing has been read yet, so no ground is claimed", about(covered, 0), covered)
end

step("Turning pages moves the reader and claims the ground covered")

do
    local position = opened(39)
    local page = turn(position, 39, 3)
    local progress, percent, covered = position:reportable()

    check("the reported position follows the reader", about(percent, at(page)), percent)
    check("the progress string follows too", progress == "page-42", progress)
    check("three pages of ground is claimed, no more", about(covered, at(3)), covered)
end

step("Looking something up at the back of the book is not reading it")

do
    local position = opened(39)
    turn(position, 39, 3)

    position:observe("page-282", at(282))

    local progress, percent, covered = position:reportable()

    check("the reader is still reported where they were reading",
        progress == "page-42" and about(percent, at(42)), percent)
    check("the jump claims no ground", about(covered, at(3)), covered)

    position:observe("page-283", at(283))
    check("paging around the index does not move them either",
        about(reported(position), at(42)), reported(position))

    position:observe("page-42", at(42))
    check("coming back leaves them where they were", about(reported(position), at(42)), reported(position))
    check("and the whole visit is still worth nothing", about(claimed(position), at(3)), claimed(position))
end

step("A reader who skips ahead and reads on is followed there")

do
    local position = opened(39)

    position:observe("page-90", at(90))
    check("the skip is held until it is earned", about(reported(position), at(39)), reported(position))

    local page = turn(position, 90, 3)
    local progress, percent, covered = position:reportable()

    check("three pages of reading confirms the new spot", about(percent, at(page)), percent)
    check("the progress string moves with it", progress == "page-93", progress)
    check("only the pages actually turned are claimed, never the skip",
        about(covered, at(3)), covered)
end

step("Turning back is always accepted, and is never new reading")

do
    local position = opened(180)

    position:observe("page-15", at(15))

    check("re-reading an earlier chapter moves the reader straight away",
        about(reported(position), at(15)), reported(position))
    check("going backwards claims nothing", about(claimed(position), 0), claimed(position))
end

step("One look after another still adds up to nothing")

do
    local position = opened(15)

    position:observe("page-180", at(180))
    position:observe("page-270", at(270))
    position:observe("page-271", at(271))
    position:observe("page-15", at(15))

    check("a second jump replaces the first rather than confirming it",
        about(reported(position), at(15)), reported(position))
    check("and none of it is claimed as reading", about(claimed(position), 0), claimed(position))
end

step("Ground is claimed once")

do
    local position = opened(39)

    turn(position, 39, 3)
    check("what has been read is waiting to be sent", about(claimed(position), at(3)), claimed(position))

    position:commit()
    check("a sync that lands clears it", about(claimed(position), 0), claimed(position))

    turn(position, 42, 2)
    check("and the next pages start again from nothing", about(claimed(position), at(2)), claimed(position))
end

step("Only moving counts towards earning a new spot")

do
    local position = opened(39)

    position:observe("page-282", at(282))

    for _index = 1, 5 do
        position:observe("page-282", at(282))
    end

    check("redrawing the same page is not reading it",
        about(reported(position), at(39)), reported(position))
end

step("Ground claimed can never exceed the book")

do
    local position = opened(0)

    for page = 1, PAGES do
        position:observe("page-" .. page, at(page))
    end

    turn(position, PAGES, 20)

    check("a sync that never landed cannot claim more than the whole book",
        about(claimed(position), 1), claimed(position))
end

step("Opening a book fixes where the reader is, whenever the file gets around to saying")

do
    local position = opened(0)

    position:observe("page-160", at(160))
    check("a position restored after the file loaded reads as a jump at first",
        about(reported(position), at(0)), reported(position))

    position:settle("page-160", at(160))
    check("settling on open takes it as the reader's place",
        about(reported(position), at(160)), reported(position))

    position:observe("page-161", at(161))
    check("and reading on from there follows them", about(reported(position), at(161)), reported(position))
end

step("How far a single move may carry depends on the length of the book")

do
    local long = Position:new()

    long:reset(1000)
    long:observe("start", 0.5)
    long:observe("two-pages-on", 0.502)
    check("two pages of a thousand is still reading", about(reported(long), 0.502), reported(long))

    long:observe("thirty-pages-on", 0.532)
    check("thirty is a jump", about(reported(long), 0.502), reported(long))

    local unknown = Position:new()

    unknown:reset(nil)
    unknown:observe("start", 0.5)
    unknown:observe("nudge", 0.505)
    check("a file that will not say how long it is still moves on a small step",
        about(reported(unknown), 0.505), reported(unknown))

    local short = Position:new()

    short:reset(4)
    short:observe("start", 0.5)
    short:observe("quarter-on", 0.56)
    check("and a very short file cannot make every move a continuous one",
        about(reported(short), 0.5), reported(short))
end

harness.report()
