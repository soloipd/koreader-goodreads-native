local project_root = assert(os.getenv("PROJECT_ROOT"), "PROJECT_ROOT is required")

local shown_messages = {}
local scheduled = {}

local function simpleWidget()
    return {
        new = function(_, options)
            return options
        end,
    }
end

package.preload["ui/widget/infomessage"] = simpleWidget
package.preload["ui/widget/buttondialog"] = simpleWidget
package.preload["ui/uimanager"] = function()
    return {
        show = function(message)
            table.insert(shown_messages, message)
        end,
        close = function() end,
        scheduleIn = function(_, delay, callback)
            assert(type(delay) == "number", "scheduled delay must be numeric")
            assert(type(callback) == "function", "scheduled callback must be callable")
            table.insert(scheduled, callback)
        end,
    }
end
package.preload["ui/widget/container/widgetcontainer"] = function()
    local container = {}
    function container:extend(definition)
        return definition
    end
    return container
end
package.preload["gettext"] = function()
    return function(value)
        return value
    end
end
package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
    }
end
package.preload["json"] = function()
    return {
        encode = function() return "[]" end,
        decode = function() return { ok = false } end,
    }
end
package.preload["util"] = function()
    return {
        shell_escape = function(arguments)
            return table.concat(arguments, " ")
        end,
    }
end

local ReaderUI = {
    onClose = function(reader)
        reader.document = nil
        return "closed"
    end,
}
package.preload["apps/reader/readerui"] = function()
    return ReaderUI
end

local saved_settings
G_reader_settings = {
    readSetting = function()
        return nil
    end,
    saveSetting = function(_, _, value)
        saved_settings = value
    end,
}

local Goodreads = assert(dofile(project_root .. "/goodreads.koplugin/main.lua"))

local function newPlugin(settings)
    return setmetatable({
        settings = settings,
        last_sync = nil,
        last_progress_sync = nil,
        last_checkpoint = nil,
        last_native_progress_result = nil,
        last_annotation_event = nil,
        progress_timer_scheduled = false,
        progress_timer_generation = 0,
        rating_prompt_scheduled = {},
        annotation_retry_counts = {},
        annotation_request_ids = {},
        annotation_snapshot_tokens = {},
        annotation_sync_inflight = nil,
        annotation_pending_snapshots = {},
        annotation_pending_order = {},
    }, { __index = Goodreads })
end

local function settings(overrides)
    local value = {
        enabled = false,
        percentage_enabled = true,
        percentage_delay_seconds = 0,
        periodic_progress_enabled = true,
        progress_interval_seconds = 300,
        debug_enabled = false,
        rating_prompt_enabled = false,
        annotation_sync_enabled = false,
        rating_prompted = {},
        ratings = {},
        dedupe_seconds = 300,
    }
    for key, override in pairs(overrides or {}) do
        value[key] = override
    end
    return value
end

local live_percent = 0.46
local reader = {
    document = {
        virtual_path = "KINDLE_VIRTUAL://B0FLB24198/book.epub",
    },
    rolling = {
        getLastPercent = function()
            return live_percent
        end,
    },
    view = {
        footer = {
            percent_finished = 0.46,
        },
    },
    doc_settings = {
        readSetting = function(_, key)
            if key == "percent_finished" then
                return 0.0072202
            end
            if key == "summary" then
                return { status = "reading" }
            end
        end,
    },
    annotation = {
        annotations = {},
    },
}

local plugin = newPlugin(settings())
plugin.ui = reader
reader.goodreads_native = plugin

local commands = {}
local original_execute = os.execute
os.execute = function(command)
    table.insert(commands, command)
    return 0
end

local ok = plugin:syncReaderCheckpoint(reader, "test_live")
assert(ok, "live checkpoint should be processed")
assert(plugin.last_checkpoint.percent == 46, "live progress must win over stale sidecar progress")
assert(commands[#commands]:match("sync%-progress B0FLB24198 46"), "queued command must contain live 46 percent")
assert(saved_settings == plugin.settings, "the observed ASIN should be persisted in plugin settings")

-- ReadHistory reopens converted Kindle books by their cache path after a
-- restart. Resolve the sanitized cc.db UUID through kindle.koplugin's loaded
-- virtual-library index and use its cde_key.
local fake_catalog = {
    ["cc:f82913d4-094a-43c6-8166-e330d40c1d7c"] = {
        id = "cc:f82913d4-094a-43c6-8166-e330d40c1d7c",
        cde_key = "B0FLB24198",
        source_path = "/mnt/us/documents/Book_B0FLB24198.kfx",
    },
    ["sha1:abcdef0123456789"] = {
        id = "sha1:abcdef0123456789",
        cde_key = "B012345678",
        source_path = "/mnt/us/documents/Another_B012345678.kfx",
    },
}
package.loaded["lua/readerui_ext"] = {
    virtual_library = {
        books_by_id = fake_catalog,
        getVirtualPath = function()
            return nil
        end,
        getBook = function(_, key)
            return fake_catalog[key]
        end,
    },
}

local history_plugin = newPlugin(settings())
reader.document = {
    file = "/mnt/us/koreader/cache/kindle.koplugin/cc_f82913d4-094a-43c6-8166-e330d40c1d7c.epub",
}
reader.goodreads_native = history_plugin
history_plugin.ui = reader
commands = {}

assert(history_plugin:syncReaderCheckpoint(reader, "history_reopen"))
assert(history_plugin.last_checkpoint.asin == "B0FLB24198", "cache UUID must resolve to the native ASIN")
assert(history_plugin.last_checkpoint.percent == 46, "history reopen must still use live progress")
assert(commands[#commands]:match("sync%-progress B0FLB24198 46"), "history reopen must queue the resolved ASIN")

local second_history_plugin = newPlugin(settings())
reader.document = {
    file = "/mnt/us/koreader/cache/kindle.koplugin/sha1_abcdef0123456789.epub",
}
reader.goodreads_native = second_history_plugin
second_history_plugin.ui = reader
commands = {}

assert(second_history_plugin:syncReaderCheckpoint(reader, "second_history_reopen"))
assert(second_history_plugin.last_checkpoint.asin == "B012345678", "resolver must work for unrelated catalog books")
assert(commands[#commands]:match("sync%-progress B012345678 46"), "resolver must not depend on one ASIN or UUID")

-- The catalog query is the durable restart fallback and must not depend on
-- kindle.koplugin's in-memory mapping being initialized before ReaderReady.
package.loaded["lua/readerui_ext"] = nil
package.loaded["lua/showreader_ext"] = nil
local original_popen = io.popen
io.popen = function(command)
    assert(command:match("/usr/bin/sqlite3 %-readonly /var/local/cc%.db"), "catalog lookup must be read-only")
    assert(command:match("aaaaaaaa%-bbbb%-cccc%-dddd%-eeeeeeeeeeee"), "catalog lookup must use the cache UUID")
    return {
        read = function()
            return "B099999999"
        end,
        close = function() end,
    }
end

local catalog_plugin = newPlugin(settings())
reader.document = {
    file = "/mnt/us/koreader/cache/kindle.koplugin/cc_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.epub",
}
reader.goodreads_native = catalog_plugin
catalog_plugin.ui = reader
commands = {}

assert(catalog_plugin:syncReaderCheckpoint(reader, "catalog_fallback"))
assert(catalog_plugin.last_checkpoint.asin == "B099999999", "catalog UUID must resolve to p_cdeKey")
assert(catalog_plugin.last_checkpoint.resolver == "content_catalog", "catalog fallback must be observable")
assert(commands[#commands]:match("sync%-progress B099999999 46"), "catalog fallback must queue the resolved ASIN")
io.popen = original_popen

local scheduled_before_interval_change = #scheduled
catalog_plugin:setProgressInterval(120)
assert(catalog_plugin.settings.progress_interval_seconds == 120, "menu interval must persist")
assert(catalog_plugin.progress_timer_generation == 1, "interval change must invalidate the old timer")
assert(#scheduled == scheduled_before_interval_change + 1, "interval change must schedule a fresh timer immediately")

-- The global close hook may be installed by the file-manager instance. Verify
-- it resolves the active reader plugin, which has different settings/state.
local installer = newPlugin(settings({ percentage_enabled = false }))
installer:applyReaderHook()

local active = newPlugin(settings())
active.ui = reader
reader.goodreads_native = active
reader.document = {
    virtual_path = "KINDLE_VIRTUAL://B0FLB24198/book.epub",
}
live_percent = 0.47
commands = {}

assert(ReaderUI.onClose(reader) == "closed", "wrapped close should preserve the original result")
assert(active.last_checkpoint.percent == 47, "close hook should capture live reader progress")
assert(commands[#commands]:match("sync%-progress B0FLB24198 47"), "active reader settings must control close sync")
assert(installer.last_checkpoint == nil, "file-manager plugin instance must not process reader close")

reader.document = {
    virtual_path = "KINDLE_VIRTUAL://B0FLB24198/book.epub",
}
reader.annotation.annotations = {
    { drawer = "lighten" },
    { drawer = "underscore", note = "private text that must not be retained" },
    { page = 10 },
}
active:onAnnotationsModified({ reader.annotation.annotations[2] })
assert(active.last_annotation_event.changed == 1, "annotation event count should be recorded")
assert(active.last_annotation_event.stats.highlights == 2, "highlight totals should be counted")
assert(active.last_annotation_event.stats.notes == 1, "note totals should be counted")
assert(active.last_annotation_event.stats.bookmarks == 1, "bookmark totals should be counted")
assert(active.last_annotation_event.text == nil, "annotation text must never enter diagnostics state")

local duplicate_ranges = {
    { drawer = "lighten", pos0 = "/body/p[1].0", pos1 = "/body/p[1].10" },
    { drawer = "lighten", pos0 = "/body/p[1].0", pos1 = "/body/p[1].10" },
    {
        drawer = "underscore",
        pos0 = "/body/p[2].20",
        pos1 = "/body/p[2].5",
        note = "",
    },
    {
        drawer = "underscore",
        pos0 = "/body/p[2].5",
        pos1 = "/body/p[2].20",
        note = "note retained without logging its text",
    },
}
local normalized_ranges, normalized_note_bytes, collapsed_ranges =
    active:collectDesiredAnnotations(duplicate_ranges)
assert(#normalized_ranges == 2, "exact and reversed duplicate ranges must collapse")
assert(collapsed_ranges == 2, "duplicate collapse count must be observable")
assert(normalized_ranges[2].note ~= "", "a non-empty duplicate note must be retained")
assert(normalized_note_bytes == #normalized_ranges[2].note,
    "payload limits must count only retained duplicate-note bytes")

-- Only one native annotation agent may run at once. New changes for the same
-- book must replace the queued snapshot, while changes for another book remain
-- queued behind it.
local durable = newPlugin(settings({ annotation_sync_enabled = true }))
local started = {}
durable.startAnnotationReconcile = function(self, snapshot)
    self.annotation_sync_inflight = snapshot
    table.insert(started, snapshot)
    return true
end
local function snapshot(asin, token, trigger)
    durable.annotation_snapshot_tokens[asin] = token
    return {
        asin = asin,
        desired = {},
        trigger = trigger,
        token = token,
        attempt = 0,
    }
end

local first = snapshot("B0FLB24198", 1, "reader_ready")
local stale = snapshot("B0FLB24198", 2, "annotations_modified")
local latest = snapshot("B0FLB24198", 3, "close")
local other = snapshot("B012345678", 1, "close")
assert(durable:queueAnnotationSnapshot(first), "first annotation snapshot should start")
assert(durable:queueAnnotationSnapshot(stale), "overlapping snapshot should coalesce")
assert(durable:queueAnnotationSnapshot(latest), "newest snapshot should replace stale queued work")
assert(durable:queueAnnotationSnapshot(other), "another book should remain queued")
assert(#started == 1 and started[1] == first, "only one native annotation sync may be active")

local scheduled_before_drain = #scheduled
durable:finishAnnotationReconcile(first, true, false)
assert(#scheduled == scheduled_before_drain + 1, "successful completion should schedule queued work")
scheduled[scheduled_before_drain + 1]()
assert(#started == 2 and started[2] == latest, "latest same-book snapshot must run next")

local scheduled_before_other = #scheduled
durable:finishAnnotationReconcile(latest, true, false)
scheduled[scheduled_before_other + 1]()
assert(#started == 3 and started[3] == other, "different-book snapshot must not be discarded")

-- A reported transient failure retries the captured snapshot even when its
-- ReaderUI has already closed. A newer same-book token cancels a stale retry.
local retrying = newPlugin(settings({ annotation_sync_enabled = true }))
local retry_starts = {}
retrying.startAnnotationReconcile = function(self, queued)
    self.annotation_sync_inflight = queued
    table.insert(retry_starts, queued)
    return true
end
local retry_snapshot = {
    asin = "B0FLB24198",
    desired = {},
    trigger = "close",
    token = 1,
    attempt = 0,
}
retrying.annotation_snapshot_tokens.B0FLB24198 = 1
assert(retrying:queueAnnotationSnapshot(retry_snapshot))
local scheduled_before_retry = #scheduled
retrying:finishAnnotationReconcile(retry_snapshot, false, true)
scheduled[scheduled_before_retry + 1]()
assert(#retry_starts == 2, "transient annotation failure should retry")
assert(retry_starts[2].attempt == 1, "retry attempt should be bounded and observable")

local obsolete = retry_starts[2]
local scheduled_before_obsolete_retry = #scheduled
retrying:finishAnnotationReconcile(obsolete, false, true)
local replacement = {
    asin = "B0FLB24198",
    desired = {},
    trigger = "annotations_modified",
    token = 2,
    attempt = 0,
}
retrying.annotation_snapshot_tokens.B0FLB24198 = 2
assert(retrying:queueAnnotationSnapshot(replacement))
scheduled[scheduled_before_obsolete_retry + 1]()
assert(#retry_starts == 3 and retry_starts[3] == replacement,
    "new same-book snapshot must cancel the stale retry")

local suspend = newPlugin(settings({ annotation_sync_enabled = true }))
suspend.ui = { document = {} }
local suspend_progress = 0
local suspend_annotations = 0
suspend.syncReaderCheckpoint = function()
    suspend_progress = suspend_progress + 1
end
suspend.queueAnnotationReconcile = function(_, _, trigger)
    assert(trigger == "suspend", "suspend annotation trigger should be explicit")
    suspend_annotations = suspend_annotations + 1
end
suspend:onSuspend()
assert(suspend_progress == 1, "suspend should capture progress immediately")
assert(suspend_annotations == 1, "suspend should capture annotations before sleeping")

os.execute = original_execute

print("Plugin behavior tests passed.")
