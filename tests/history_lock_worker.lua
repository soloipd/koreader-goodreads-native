local project_root = assert(os.getenv("PROJECT_ROOT"), "PROJECT_ROOT is required")

local function simpleWidget()
    return { new = function(_, options) return options end }
end

package.preload["ui/widget/infomessage"] = simpleWidget
package.preload["ui/widget/buttondialog"] = simpleWidget
package.preload["ui/event"] = function()
    return { new = function(_, name, args) return { name = name, args = args } end }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        close = function() end,
        scheduleIn = function() end,
    }
end
package.preload["ui/widget/container/widgetcontainer"] = function()
    local container = {}
    function container:extend(definition) return definition end
    return container
end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["logger"] = function()
    return { info = function() end, warn = function() end }
end
package.preload["json"] = function()
    return { encode = function() return "[]" end, decode = function() return {} end }
end
package.preload["util"] = function()
    return {
        shell_escape = function(arguments)
            local quoted = {}
            for index, value in ipairs(arguments) do
                quoted[index] = "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
            end
            return table.concat(quoted, " ")
        end,
    }
end
package.preload["annotationoutbox"] = function()
    return assert(dofile(project_root .. "/goodreads.koplugin/annotationoutbox.lua"))
end
package.preload["shelfstate"] = function()
    return assert(dofile(project_root .. "/goodreads.koplugin/shelfstate.lua"))
end
local History = assert(dofile(project_root .. "/goodreads.koplugin/readinghistory.lua"))
package.preload["readinghistory"] = function() return History end
package.preload["apps/reader/readerui"] = function()
    return { onClose = function() end }
end

G_reader_settings = {
    readSetting = function() return nil end,
    saveSetting = function() end,
}

local Goodreads = assert(dofile(project_root .. "/goodreads.koplugin/main.lua"))
local plugin = setmetatable({ settings = {} }, { __index = Goodreads })
local mode = assert(arg[1], "worker mode is required")

if mode == "probe_busy" then
    local called = false
    local changed, detail = plugin:updateReadingHistory(function()
        called = true
        return true
    end)
    assert(not changed and not called and detail == "reading history is busy",
        "special-file lock owner must fail immediately as busy")
    return
end

if mode == "probe_invalid_history" then
    local state, detail = plugin:reloadReadingHistory()
    assert(not state and detail == "history file is not a regular file",
        "special lifecycle state must fail closed without being opened")
    return
end

if mode == "verify" then
    local expected = assert(tonumber(arg[2]), "expected worker count is required")
    local state = assert(plugin:reloadReadingHistory())
    local books = 0
    for _ in pairs(state.books) do books = books + 1 end
    assert(books == expected, "concurrent lifecycle writes were lost")
    assert(state.sequence == expected, "lifecycle sequence is not serial")
    assert(History.validate(state))
    return
end

assert(mode == "write", "unsupported worker mode")
local worker = assert(tonumber(arg[2]), "worker number is required")
local asin = string.format("B%09d", worker)
for _ = 1, 1000 do
    local changed, detail = plugin:updateReadingHistory(function(state)
        return History.record(state, asin, 0.01, "reading", os.time())
    end)
    if changed then return end
    assert(detail == "reading history is busy", detail or "history write failed")
    os.execute("sleep 0.01")
end
error("timed out waiting for the lifecycle lock")
