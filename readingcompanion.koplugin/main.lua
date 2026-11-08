local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Event = require("ui/event")
local TextWidget = require("ui/widget/textwidget")
local Font = require("ui/font")
local Blitbuffer = require("ffi/blitbuffer")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local Policy = require("readingcompanion_policy")
local json = require("json")
local Companion = WidgetContainer:extend{ name = "readingcompanion", is_doc_only = true }
local busy = false -- one request across all book instances

function Companion:init()
    self.alive = true
    self.ui.menu:registerToMainMenu(self)
end

function Companion:addToMainMenu(menu)
    menu.readingcompanion = {
        text = "Quiet reading companion",
        sub_item_table = {
            { text = "Show spoiler-safe recap", callback = function() self:showRecap(false) end },
            { text = "Automatic recap on book open", checked_func = function()
                return G_reader_settings:readSetting("readingcompanion_auto", true)
              end, callback = function()
                G_reader_settings:saveSetting("readingcompanion_auto", not G_reader_settings:readSetting("readingcompanion_auto", true))
              end },
        },
    }
end

function Companion:onReaderReady()
    self.ready_task = function()
        if self.alive and self.ui.document then self:installHeader() end
    end
    UIManager:nextTick(self.ready_task)
end

function Companion:installHeader()
    if self.ui.document.info.has_pages then return end
    local initial_xp = self.ui.rolling.xpointer or self.ui.document:getXPointer()
    if self.ui.document.configurable.status_line ~= 0 then
        self.ui.document.configurable.status_line = 0
        self.ui:handleEvent(Event:new("SetStatusLine", 0))
        if initial_xp then self.ui.rolling:onGotoXPointer(initial_xp) end
    end
    self.ui.view:registerViewModule("readingcompanion", self)
    UIManager:setDirty(self.ui, "ui")
    self.ui:registerTouchZones({{
        id = "readingcompanion_recap", ges = "tap",
        screen_zone = { ratio_x = 0.25, ratio_y = 0, ratio_w = 0.5, ratio_h = 0.045 },
        overrides = { "readermenu_tap", "readerconfigmenu_tap" },
        handler = function(ges)
            local h = self.ui.document:getHeaderHeight()
            if ges.pos and ges.pos.y <= h then self:showRecap(false); return true end
        end,
    }})
    self.auto_task = function()
        if self.alive and G_reader_settings:readSetting("readingcompanion_auto", true) then self:showRecap(true) end
    end
    UIManager:scheduleIn(1.5, self.auto_task)
end

-- Paint only inside the native reserved header. No overlay above menus, no
-- independent refresh loop, no margins or reading position changes.
function Companion:paintTo(bb, x, y)
    if not self.alive or not self.ui.document or self.ui.view.view_mode ~= "page" then return end
    local h = self.ui.document:getHeaderHeight()
    if h < 10 then return end
    local w = Device.screen:getWidth()
    local power = Device:getPowerDevice()
    local chapter = self.ui.toc:getTocTitleByPage(self.ui.document:getXPointer())
    local labels = { os.date("%H:%M"), "Recap" .. (chapter and chapter ~= "" and "  ·  " .. chapter or ""),
        (power:isCharging() and "↯ " or "") .. power:getCapacity() .. "%" }
    bb:paintRect(x, y, w, h, Blitbuffer.COLOR_WHITE)
    self.header_widgets = self.header_widgets or {}
    for i, text in ipairs(labels) do
        local old = self.header_widgets[i]
        if not old or old.text ~= text then
            if old then old:free() end
            old = TextWidget:new{ text = text, face = Font:getFace("cfont", 16), max_width = w * (i == 2 and 0.48 or 0.23) }
            self.header_widgets[i] = old
        end
        local size = old:getSize()
        local px = i == 1 and Device.screen:scaleBySize(12) or (i == 2 and (w-size.w)/2 or w-size.w-Device.screen:scaleBySize(12))
        old:paintTo(bb, x+px, y+math.max(0, math.floor((h-size.h)/2)))
    end
end

function Companion:display(text)
    if not self.alive then return end
    if self.viewer then UIManager:close(self.viewer) end
    self.viewer = TextViewer:new{
        title = "Your AI recap · read so far",
        text = text,
        buttons_table = {{{ text = "Continue reading", callback = function()
            UIManager:close(self.viewer); self.viewer = nil
        end }}},
    }
    UIManager:show(self.viewer)
end

function Companion:showRecap(automatic)
    if not self.alive or self.pending or busy then return end
    local ok, ctx, reason = pcall(Policy.capture, self.ui.document)
    if not ok or not ctx then
        self.last_status = "no_safe_context"
        if not automatic then UIManager:show(InfoMessage:new{ text = reason or "Cannot safely extract earlier text.", timeout = 3 }) end
        return
    end
    local cache = self.ui.doc_settings:readSetting("readingcompanion_recap")
    if Policy.cacheMatches(cache, ctx) then self.last_status = "cache_verified"; self:display(cache.text); return end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then
        self.last_status = "offline"
        if not automatic then UIManager:show(InfoMessage:new{ text = "Offline: no recap cached for this exact position.", timeout = 3 }) end
        return
    end
    local koa = self.ui.koassistant
    if not koa then self.last_status = "koassistant_unavailable"; return end
    if not automatic then
        UIManager:show(require("ui/widget/notification"):new{ text = "Preparing a spoiler-safe recap…", timeout = 2 })
    end
    koa:ensureInitialized()
    local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/koassistant_settings.lua")
    local f = settings:readSetting("features") or {}
    local History = require("koassistant.request.message_history")
    local Query = require("koassistant.request.gpt_query")
    local config = {
        provider = f.provider or settings:readSetting("provider"), model = f.model or settings:readSetting("model"),
        features = { enable_streaming = false, hidden_streaming = true,
            loading_message = "Preparing your AI recap…\nUsing only text before your reading position.",
            hidden_streaming_label = "Preparing your AI recap…",
            hidden_streaming_note = "Using only the text before your reading position.",
            _background_request = true, enable_web_search = false, enable_book_tools = false,
            provider = f.provider, model = f.model, custom_providers = f.custom_providers },
        api_params = { max_tokens = 4000 },
    }
    self.expired = nil; self.last_error = nil; self.pending = true; busy = true; self.last_status = "generating"
    self.watchdog = function()
        self.expired = true; self.pending = nil; self.last_status = "timed_out"
        -- Keep the cross-instance lock until the transport reports completion.
    end
    local function complete(success, response, err)
        busy = false; self.pending = nil
        UIManager:unschedule(self.watchdog)
        if not self.alive or self.expired then return end
        if not self.ui.document or self.ui.document:getXPointer() ~= ctx.xp then
            self.last_status = "stale_response_discarded"; return
        end
        if not success or type(response) ~= "string" then
            self.last_status = "request_failed"; self.last_error = tostring(err or "Unknown request error"):sub(1,500)
            require("logger").warn("ReadingCompanion: recap failed", self.last_error:match("^Recap rejected: .+$") or "transport/cancelled")
            if not automatic then UIManager:show(InfoMessage:new{ text = "Recap unavailable: " .. self.last_error, timeout = 8 }) end
            return
        end
        local text = response
        local current_ok, current = pcall(Policy.capture, self.ui.document)
        if not current_ok or not current or current.file ~= ctx.file or current.xp ~= ctx.xp or current.source ~= ctx.source then
            self.last_status = "stale_response_discarded"; return
        end
        self.ui.doc_settings:saveSetting("readingcompanion_recap", {
            version = Policy.version, file = ctx.file, xp = ctx.xp, source = ctx.source, text = text,
        })
        self.last_status = "generated_grounded"
        require("logger").info("ReadingCompanion: AI recap ready; source bytes", #ctx.source, "chunks", #Policy.chunks(ctx.source))
        self:display(text)
    end
    local function alive()
        return self.alive and not self.expired and self.ui.document
            and self.ui.document.file == ctx.file and self.ui.document:getXPointer() == ctx.xp
    end
    local function ask(prompt, input, callback)
        local history = History:new(prompt)
        history:addUserMessage(input)
        config.system = { text = prompt }
        UIManager:unschedule(self.watchdog)
        UIManager:scheduleIn(120, self.watchdog)
        local sent, query_error = pcall(Query.query, history:getMessages(), config, callback, settings)
        if not sent then callback(false, nil, query_error) end
    end
    local sent, err = pcall(require("readingcompanion_summary").run, ctx.source, ask, json.decode, alive, complete)
    if not sent then complete(false,nil,err) end
end

function Companion:onCloseDocument()
    self.alive = false
    if self.ready_task then UIManager:unschedule(self.ready_task) end
    if self.auto_task then UIManager:unschedule(self.auto_task) end
    if self.viewer then UIManager:close(self.viewer); self.viewer = nil end
    for _, widget in ipairs(self.header_widgets or {}) do widget:free() end
    self.header_widgets = nil
end

return Companion
