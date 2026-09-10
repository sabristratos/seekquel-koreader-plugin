local _ = require("gettext")
local T = require("ffi/util").template

local Recap = {}

local SECONDS_PER_MINUTE = 60

function Recap.reading(summary, state, synced)
    local lines = { _("Today's reading"), "" }

    if state == "unreadable" then
        table.insert(lines, _("KOReader's reading statistics could not be read."))
    elseif state == "untracked" then
        table.insert(lines, _("KOReader is not keeping reading statistics for this book."))
    elseif summary == nil then
        table.insert(lines, _("No reading recorded today."))
    else
        if state == "cached" then
            table.insert(lines, _("Last saved today:"))
        end

        local minutes = math.floor((tonumber(summary.seconds) or 0) / SECONDS_PER_MINUTE)
        local pages = math.floor(tonumber(summary.pages) or 0)

        table.insert(lines, T(_("%1 min"), tostring(minutes)))
        table.insert(lines, T(_("%1 pages"), tostring(pages)))

        if tonumber(summary.chapter) ~= nil and tonumber(summary.chapter_count) ~= nil then
            table.insert(lines, T(
                _("Chapter %1 of %2"),
                tostring(math.floor(tonumber(summary.chapter))),
                tostring(math.floor(tonumber(summary.chapter_count)))
            ))
        end

        if tonumber(summary.percentage) ~= nil then
            table.insert(lines, T(_("%1% through this book"), tostring(math.floor(tonumber(summary.percentage)))))
        end
    end

    if synced == false then
        table.insert(lines, "")
        table.insert(lines, _("Some reading is still waiting to sync."))
    end

    return table.concat(lines, "\n")
end

function Recap.account(snapshot, updated)
    if type(snapshot) ~= "table" then
        return _("No Seekquel summary yet. Connect this device, then try again.")
    end

    local lines = { _("Today in Seekquel"), "" }
    local minutes = math.floor(tonumber(snapshot.minutes_read) or 0)
    local minutes_target = math.floor(tonumber(snapshot.minutes_target) or 0)
    local pages = math.floor(tonumber(snapshot.pages_read) or 0)
    local pages_target = math.floor(tonumber(snapshot.pages_target) or 0)
    local goals = type(snapshot.goals_completed) == "table" and #snapshot.goals_completed or 0
    local streak = math.floor(tonumber(snapshot.current_streak) or 0)

    if updated ~= nil then
        table.insert(lines, T(_("Updated %1"), updated))
        table.insert(lines, "")
    end

    table.insert(lines, minutes_target > 0
        and T(_("%1 of %2 min today"), tostring(minutes), tostring(minutes_target))
        or T(_("%1 min today"), tostring(minutes)))
    table.insert(lines, pages_target > 0
        and T(_("%1 of %2 pages today"), tostring(pages), tostring(pages_target))
        or T(_("%1 pages today"), tostring(pages)))

    if goals == 1 then
        table.insert(lines, _("1 daily goal reached"))
    else
        table.insert(lines, T(_("%1 daily goals reached"), tostring(goals)))
    end

    if streak == 1 then
        table.insert(lines, _("1 day in your current streak"))
    else
        table.insert(lines, T(_("%1 days in your current streak"), tostring(streak)))
    end

    return table.concat(lines, "\n")
end

return Recap
