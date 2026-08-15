--- Native Goodreads shelf synchronization for KOReader on jailbroken Kindles.
---
--- This plugin deliberately uses the Kindle's native KAF/LIPC Goodreads
--- action.  It does not store or transmit Goodreads credentials and does not
--- require a Goodreads API key.

local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local logger = require("logger")

local LIPC_HASH_TOOL = "/usr/bin/lipc-hash-prop"
local KAF_PUBLISHER = "com.lab126.kppkaf"
local KAF_PROPERTY = "kppAddToGoodreadShelf"
local ACTION_READING = "com.amazon.home.actions.goodread_reading"
local ACTION_READ = "com.amazon.home.actions.goodread_read"
local PROGRESS_HELPER = "/mnt/us/koreader/plugins/goodreads.koplugin/bin/sync-progress"
local RATING_HELPER = "/mnt/us/koreader/plugins/goodreads.koplugin/bin/sync-rating"
local RATING_RESULT_PREFIX = "/tmp/goodreads-rating-result"

local Goodreads = WidgetContainer:extend({
    name = "goodreads_native",
    is_doc_only = false,
})

local function isAsin(value)
    return type(value) == "string" and value:match("^B[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]$") ~= nil
end

local function extractAsin(path)
    if type(path) ~= "string" then
        return nil
    end

    local virtual_id = path:match("^KINDLE_VIRTUAL://([^/]+)/")
    if isAsin(virtual_id) then
        return virtual_id
    end

    local file_id = path:match("_([A-Z0-9]+)%.%w+$")
    if isAsin(file_id) then
        return file_id
    end

    return nil
end

local function getDocumentPath(reader)
    local document = reader and reader.document
    local settings = reader and reader.doc_settings

    if document then
        if document.virtual_path then
            return document.virtual_path
        end
        if document.file then
            return document.file
        end
    end

    if settings and settings.data and settings.data.doc_path then
        return settings.data.doc_path
    end

    return nil
end

local function getBookState(reader)
    local settings = reader and reader.doc_settings
    if not settings then
        return nil, nil
    end

    local percent = settings:readSetting("percent_finished") or 0
    local summary = settings:readSetting("summary") or {}
    return percent, summary.status
end

local function actionForState(percent, status)
    if status == "complete" or percent >= 0.99 then
        return ACTION_READ
    end

    -- Do not put a book on Currently Reading merely because it was opened and
    -- immediately closed without making progress.
    if percent > 0 then
        return ACTION_READING
    end

    return nil
end

local function percentageForProgress(percent)
    if type(percent) ~= "number" then
        return nil
    end

    local rounded = math.floor(percent * 100 + 0.5)
    return math.max(0, math.min(100, rounded))
end

local function makeCommand(asin, action)
    -- asin and action are generated from fixed constants/strict allowlists.
    -- Keeping them inside single quotes prevents shell interpretation of the
    -- hash-array payload.
    local payload = string.format('{action = "%s", cdekey = "%s"}', action, asin)
    return string.format(
        "printf '%%s\\n' '%s' | %s %s %s",
        payload,
        LIPC_HASH_TOOL,
        KAF_PUBLISHER,
        KAF_PROPERTY
    )
end

local function makeProgressCommand(asin, percent)
    -- Both values have already passed strict allowlists.
    return string.format("%s %s %d", PROGRESS_HELPER, asin, percent)
end

local function makeRatingCommand(asin, rating, request_id)
    return string.format("%s %s %d %s", RATING_HELPER, asin, rating, request_id)
end

function Goodreads:init()
    self.settings = G_reader_settings:readSetting("goodreads_native") or {}
    if self.settings.enabled == nil then
        self.settings.enabled = true
    end
    if self.settings.dedupe_seconds == nil then
        self.settings.dedupe_seconds = 300
    end
    if self.settings.percentage_enabled == nil then
        self.settings.percentage_enabled = true
    end
    if self.settings.percentage_delay_seconds == nil then
        self.settings.percentage_delay_seconds = 3
    end
    if self.settings.rating_prompt_enabled == nil then
        self.settings.rating_prompt_enabled = true
    end
    if type(self.settings.rating_prompted) ~= "table" then
        self.settings.rating_prompted = {}
    end
    if type(self.settings.ratings) ~= "table" then
        self.settings.ratings = {}
    end
    G_reader_settings:saveSetting("goodreads_native", self.settings)

    self.last_sync = nil
    self.last_progress_sync = nil
    self.rating_prompt_scheduled = {}
    self.ui.menu:registerToMainMenu(self)
    self:applyReaderHook()
end

function Goodreads:saveSettings()
    G_reader_settings:saveSetting("goodreads_native", self.settings)
end

function Goodreads:applyReaderHook()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or not ReaderUI or type(ReaderUI.onClose) ~= "function" then
        logger.warn("GoodreadsNative: ReaderUI.onClose is unavailable")
        return
    end

    if ReaderUI._goodreads_native_sync_installed then
        return
    end

    local original_on_close = ReaderUI.onClose
    local plugin = self

    ReaderUI.onClose = function(reader, ...)
        local path = getDocumentPath(reader)
        local asin = extractAsin(path)
        local percent, status = getBookState(reader)

        local result = original_on_close(reader, ...)

        if asin and percent then
            local action = actionForState(percent, status)
            if action and plugin.settings.enabled then
                plugin:syncAsin(asin, action, percent, false)
            end
            if action and plugin.settings.percentage_enabled then
                plugin:syncProgress(asin, percent)
            end
            if action == ACTION_READ then
                plugin.settings.last_completed_asin = asin
                plugin:saveSettings()

                if plugin.settings.rating_prompt_enabled
                    and not plugin.settings.rating_prompted[asin]
                    and not plugin.settings.ratings[asin]
                    and not plugin.rating_prompt_scheduled[asin]
                then
                    plugin.rating_prompt_scheduled[asin] = true
                    UIManager:scheduleIn(0.8, function()
                        plugin.rating_prompt_scheduled[asin] = nil
                        if not plugin.settings.rating_prompted[asin]
                            and not plugin.settings.ratings[asin]
                        then
                            plugin.settings.rating_prompted[asin] = os.time()
                            plugin:saveSettings()
                            plugin:showRatingDialog(asin)
                        end
                    end)
                end
            end
        end

        return result
    end

    ReaderUI._goodreads_native_sync_installed = true
    logger.info("GoodreadsNative: ReaderUI close hook installed")
end

function Goodreads:rateBook(asin, rating, on_complete)
    if not isAsin(asin) then
        return false, "not an Amazon ASIN"
    end

    rating = tonumber(rating)
    if not rating or rating ~= math.floor(rating) or rating < 0 or rating > 5 then
        return false, "rating must be a whole number from 0 to 5"
    end

    local request_id = string.format("%d%d%d", os.time(), rating, math.random(1000, 9999))
    local result_file = string.format("%s-%s.log", RATING_RESULT_PREFIX, request_id)
    os.remove(result_file)
    os.execute("(" .. makeRatingCommand(asin, rating, request_id) .. ") >/dev/null 2>&1 &")

    local attempts = 0
    local function pollResult()
        attempts = attempts + 1
        local file = io.open(result_file, "r")
        if file then
            local fields = {}
            for line in file:lines() do
                local key, value = line:match("^([a-z_]+)=(.*)$")
                if key then
                    fields[key] = value
                end
            end
            file:close()
            os.remove(result_file)

            local valid_result = fields.asin == asin and tonumber(fields.rating) == rating
            if valid_result and fields.success == "true" then
                self.settings.rating_prompted[asin] = os.time()
                if rating == 0 then
                    self.settings.ratings[asin] = nil
                else
                    self.settings.ratings[asin] = rating
                    self.settings.last_completed_asin = asin
                end
                self:saveSettings()

                if rating > 0 and self.settings.enabled then
                    self:syncAsin(asin, ACTION_READ, 1, false)
                end
                logger.info("GoodreadsNative: native rating sent", asin, rating)
                if on_complete then
                    on_complete(true, "sent")
                end
            else
                local detail = fields.native_exit == "143"
                    and "native Goodreads service timed out"
                    or "native Goodreads service rejected the rating"
                logger.warn("GoodreadsNative: native rating failed", asin, rating, detail)
                if on_complete then
                    on_complete(false, detail)
                end
            end
            return
        end

        if attempts < 70 then
            UIManager:scheduleIn(0.5, pollResult)
        elseif on_complete then
            on_complete(false, "native Goodreads service did not return a result")
        end
    end

    UIManager:scheduleIn(0.5, pollResult)
    return true, "queued"
end

function Goodreads:showRatingDialog(asin)
    if not isAsin(asin) then
        UIManager:show(InfoMessage:new({
            text = _("No Amazon ASIN is available to rate."),
            timeout = 3,
        }))
        return
    end

    local current_rating = self.settings.ratings[asin]
    local title = string.format(_("Rate this book on Goodreads\n%s"), asin)
    if current_rating then
        title = title .. string.format(_("\nCurrent rating: %d stars"), current_rating)
    end

    local dialog
    local function submitRating(value)
        UIManager:close(dialog)
        local queued, detail = self:rateBook(asin, value, function(ok, result_detail)
            local message
            if ok and value == 0 then
                message = _("Goodreads rating cleared.")
            elseif ok then
                message = string.format(_("Goodreads rating updated to %d stars."), value)
            elseif value == 0 then
                message = string.format(_("Could not clear rating: %s"), result_detail or _("unknown error"))
            else
                message = string.format(_("Goodreads rating failed: %s"), result_detail or _("unknown error"))
            end
            UIManager:show(InfoMessage:new({
                text = message,
                timeout = 5,
            }))
        end)
        if queued then
            UIManager:show(InfoMessage:new({
                text = _("Sending rating through the Kindle Goodreads service…"),
                timeout = 2,
            }))
        else
            UIManager:show(InfoMessage:new({
                text = string.format(_("Could not start rating update: %s"), detail or _("unknown error")),
                timeout = 5,
            }))
        end
    end

    local function ratingButton(value)
        return {
            text = string.format(_("%d ★"), value),
            callback = function()
                submitRating(value)
            end,
        }
    end

    dialog = ButtonDialog:new({
        title = title,
        title_align = "center",
        width_factor = 0.9,
        buttons = {
            { ratingButton(1), ratingButton(2), ratingButton(3) },
            { ratingButton(4), ratingButton(5) },
            {
                {
                    text = _("Clear rating"),
                    callback = function()
                        submitRating(0)
                    end,
                },
                {
                    text = _("Not now"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    })
    UIManager:show(dialog)
end

function Goodreads:rateCurrentBook()
    local reader = self.ui and self.ui.document and self.ui
    local asin = reader and extractAsin(getDocumentPath(reader))
    if not asin then
        UIManager:show(InfoMessage:new({
            text = _("Open a Kindle ASIN book in KOReader first."),
            timeout = 3,
        }))
        return
    end
    self:showRatingDialog(asin)
end

function Goodreads:rateLastCompletedBook()
    local asin = self.settings.last_completed_asin
    if not isAsin(asin) then
        UIManager:show(InfoMessage:new({
            text = _("No completed Kindle ASIN book has been recorded yet."),
            timeout = 3,
        }))
        return
    end
    self:showRatingDialog(asin)
end

function Goodreads:syncAsin(asin, action, percent, wait_for_result)
    if not isAsin(asin) then
        return false, "not an Amazon ASIN"
    end

    if action ~= ACTION_READING and action ~= ACTION_READ then
        return false, "unsupported native action"
    end

    local now = os.time()
    if self.last_sync
        and self.last_sync.asin == asin
        and self.last_sync.action == action
        and now - self.last_sync.time < (self.settings.dedupe_seconds or 300)
    then
        return true, "already sent recently"
    end

    local command = makeCommand(asin, action)
    local output = ""

    if wait_for_result then
        local pipe = io.popen(command .. " 2>&1", "r")
        if pipe then
            output = pipe:read("*a") or ""
            pipe:close()
        end
    else
        -- The shell delay survives a full KOReader exit and gives
        -- kindle.koplugin time to finish its native cc.db write.
        os.execute("(sleep 1; " .. command .. ") >/dev/null 2>&1 &")
    end

    self.last_sync = {
        asin = asin,
        action = action,
        percent = percent,
        time = now,
    }

    logger.info("GoodreadsNative: sent native shelf action", asin, action, percent or 0)

    if wait_for_result then
        if output == "" then
            return false, "native Goodreads action returned no response"
        end
        return true, output:gsub("%s+$", "")
    end

    return true, "queued"
end

function Goodreads:syncProgress(asin, fraction)
    if not isAsin(asin) then
        return false, "not an Amazon ASIN"
    end

    local percent = percentageForProgress(fraction)
    if not percent or percent < 1 then
        return false, "no percentage progress yet"
    end

    local now = os.time()
    if self.last_progress_sync
        and self.last_progress_sync.asin == asin
        and self.last_progress_sync.percent == percent
        and now - self.last_progress_sync.time < 15
    then
        return true, "already queued recently"
    end

    local delay = tonumber(self.settings.percentage_delay_seconds) or 3
    delay = math.max(0, math.min(30, math.floor(delay)))
    local command = makeProgressCommand(asin, percent)
    os.execute(string.format(
        "(sleep %d; %s) >/dev/null 2>&1 &",
        delay,
        command
    ))

    self.last_progress_sync = {
        asin = asin,
        percent = percent,
        time = now,
    }

    logger.info("GoodreadsNative: queued silent percentage", asin, percent)
    return true, "queued"
end

function Goodreads:syncCurrentBook()
    local reader = self.ui and self.ui.document and self.ui
    if not reader then
        UIManager:show(InfoMessage:new({
            text = _("Open a Kindle ASIN book in KOReader first."),
            timeout = 3,
        }))
        return
    end

    local path = getDocumentPath(reader)
    local asin = extractAsin(path)
    local percent, status = getBookState(reader)
    local action = actionForState(percent or 0, status)

    if not asin then
        UIManager:show(InfoMessage:new({
            text = _("This file has no Amazon ASIN in its filename."),
            timeout = 4,
        }))
        return
    end

    if not action then
        UIManager:show(InfoMessage:new({
            text = _("No progress yet; Goodreads was not changed."),
            timeout = 3,
        }))
        return
    end

    local ok, detail = self:syncAsin(asin, action, percent, true)
    local progress_ok = self:syncProgress(asin, percent)
    local message
    if ok and progress_ok then
        message = string.format(_("Goodreads shelf updated; percentage queued for %s."), asin)
    else
        message = string.format(_("Goodreads sync failed: %s"), detail or _("unknown error"))
    end

    UIManager:show(InfoMessage:new({
        text = message,
        timeout = 5,
    }))
end

function Goodreads:addToMainMenu(menu_items)
    menu_items.goodreads_native = {
        text = _("Goodreads (native Kindle sync)"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Automatic shelf sync"),
                checked_func = function()
                    return self.settings.enabled == true
                end,
                callback = function()
                    self.settings.enabled = not self.settings.enabled
                    self:saveSettings()
                end,
            },
            {
                text = _("Silent percentage sync"),
                checked_func = function()
                    return self.settings.percentage_enabled == true
                end,
                callback = function()
                    self.settings.percentage_enabled = not self.settings.percentage_enabled
                    self:saveSettings()
                end,
            },
            {
                text = _("Prompt to rate completed books"),
                checked_func = function()
                    return self.settings.rating_prompt_enabled == true
                end,
                callback = function()
                    self.settings.rating_prompt_enabled = not self.settings.rating_prompt_enabled
                    self:saveSettings()
                end,
            },
            {
                text = _("Rate current book…"),
                callback = function()
                    self:rateCurrentBook()
                end,
            },
            {
                text = _("Rate last completed book…"),
                enabled_func = function()
                    return isAsin(self.settings.last_completed_asin)
                end,
                callback = function()
                    self:rateLastCompletedBook()
                end,
            },
            {
                text = _("Sync current book now"),
                callback = function()
                    self:syncCurrentBook()
                end,
            },
            {
                text = _("About native Goodreads sync"),
                callback = function()
                    UIManager:show(InfoMessage:new({
                        text = _(
                            "Uses the Kindle's built-in Goodreads action. "
                            .. "It updates Currently Reading or Read, sends whole-number progress, and submits "
                            .. "an explicit 0–5 star choice through the native Goodreads rating service "
                            .. "for books with an Amazon ASIN. "
                            .. "It does not use a Goodreads password, API key, or background Goodreads API."
                        ),
                        timeout = 8,
                    }))
                end,
            },
        },
    }
end

return Goodreads
