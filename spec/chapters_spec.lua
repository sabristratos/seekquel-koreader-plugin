package.path = "/plugin/seekquel.koplugin/?.lua;/plugin/spec/?.lua;" .. package.path

local Chapters = require("seekquel_chapters")
local harness = require("harness")

local check = harness.check
local step = harness.step

local function document(pages, toc)
    return {
        document = {
            getPageCount = function()
                return pages
            end,
            getToc = function()
                return toc
            end,
        },
    }
end

local function loaded(pages, toc)
    return Chapters:new():load(document(pages, toc))
end

local NOVEL = {
    { title = "Cover", page = 1, depth = 1 },
    { title = "Chapter One", page = 11, depth = 1 },
    { title = "Chapter Two", page = 51, depth = 1 },
    { title = "Chapter Three", page = 91, depth = 1 },
}

step("A file with a contents page can name where the reader is")

do
    local chapters = loaded(100, NOVEL)

    check("every entry is counted, front matter included",
        chapters:count() == 4, chapters:count())
    check("the front of the book is the first entry",
        chapters:at(0) == 1, chapters:at(0))
    check("ten pages in is still the front matter",
        chapters:at(0.09) == 1, chapters:at(0.09))
    check("page eleven opens the first chapter",
        chapters:at(0.10) == 2, chapters:at(0.10))
    check("halfway through is the second chapter",
        chapters:at(0.60) == 3, chapters:at(0.60))
    check("the end of the book is the last entry",
        chapters:at(1) == 4, chapters:at(1))
end

step("A file that cannot answer says so, rather than guessing")

do
    check("no contents page at all",
        loaded(100, {}):count() == nil)
    check("a single stray heading is not a contents page",
        loaded(100, { { title = "Contents", page = 1, depth = 1 } }):count() == nil)
    check("and it names no chapter either",
        loaded(100, { { title = "Contents", page = 1, depth = 1 } }):at(0.5) == nil)
    check("a document with no page count",
        loaded(0, NOVEL):count() == nil)
    check("a reader with no position",
        loaded(100, NOVEL):at(nil) == nil)
end

step("The same subset of the contents the catalogue keeps, so a title can be resolved")

do
    local technical = loaded(100, {
        { title = "Part One", page = 1, depth = 1 },
        { title = "Chapter 1", page = 5, depth = 2 },
        { title = "Chapter 2", page = 25, depth = 2 },
        { title = "Part Two", page = 51, depth = 1 },
        { title = "Chapter 3", page = 55, depth = 2 },
    })

    check("levels are taken whole, shallowest first, and both of these fit",
        technical:count() == 5, technical:count())
    check("and the entries keep the order the book prints them in",
        technical:at(0.30) == 3, technical:at(0.30))
    check("so a position in the last chapter reports the last entry",
        technical:at(0.60) == 5, technical:at(0.60))

    local deep = {}

    for index = 1, 200 do
        table.insert(deep, { title = "Part " .. index, page = index, depth = 1 })
    end

    for index = 1, 200 do
        table.insert(deep, { title = "Chapter " .. index, page = index, depth = 2 })
    end

    local capped = loaded(400, deep)

    check("a level that would push the list past the cap is left out whole",
        capped:count() == 200, capped:count())
end

step("An entry the catalogue would drop is dropped here too")

do
    local untitled = loaded(100, {
        { title = "Chapter One", page = 1, depth = 1 },
        { title = "   ", page = 30, depth = 1 },
        { title = "Chapter Two", page = 51, depth = 1 },
    })

    check("a page with no title of its own is not a chapter",
        untitled:count() == 2, untitled:count())
    check("and the entries after it keep their positions",
        untitled:at(0.60) == 2, untitled:at(0.60))
end

step("A malformed entry is skipped rather than shifting everything after it")

do
    local ragged = loaded(100, {
        { title = "Chapter One", page = 1, depth = 1 },
        { title = "Broken", depth = 1 },
        { title = "Chapter Two", page = 51, depth = 1 },
    })

    check("an entry with no page is not counted",
        ragged:count() == 2, ragged:count())
    check("and the entries that remain keep their own order",
        ragged:at(0.60) == 2, ragged:at(0.60))
end

step("A position before the first entry still names a chapter")

do
    local late = loaded(100, {
        { title = "Chapter One", page = 11, depth = 1 },
        { title = "Chapter Two", page = 51, depth = 1 },
    })

    check("the front of a file whose contents start late reports the first entry",
        late:at(0) == 1, late:at(0))
    check("and a negative position is treated as the front",
        late:at(-0.5) == 1, late:at(-0.5))
end

harness.report()
