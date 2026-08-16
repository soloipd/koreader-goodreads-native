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
package.preload["ui/event"] = function()
    return {
        new = function(_, name, args)
            return { name = name, args = args }
        end,
    }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, message)
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
package.preload["annotationoutbox"] = function()
    return assert(dofile(project_root .. "/goodreads.koplugin/annotationoutbox.lua"))
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
        persistAnnotationOutbox = function(_, snapshot)
            snapshot.sequence = snapshot.token
            snapshot.outbox_checksum = string.rep("a", 64)
            return true
        end,
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

-- Periodic ticks transport percentage only. Re-sending an unchanged native
-- shelf action wakes KPP unnecessarily and can trigger a firmware event loop
-- when KOReader remains behind the native reader.
local periodic_plugin = newPlugin(settings({ enabled = true }))
commands = {}
assert(periodic_plugin:syncCapturedCheckpoint(
    "B0FLB24198", 0.46, "reading", "periodic", "test"
))
assert(#commands == 1 and commands[1]:match("sync%-progress B0FLB24198 46"),
    "periodic checkpoint must send only silent percentage")
assert(not commands[1]:match("lipc%-hash%-prop"),
    "periodic checkpoint must not republish the native shelf action")
commands = {}
assert(periodic_plugin:syncCapturedCheckpoint(
    "B0FLB24198", 0.46, "reading", "reader_ready", "test"
))
assert(commands[1]:match("lipc%-hash%-prop"),
    "reader-ready checkpoint must still publish the native shelf state")
commands = {}
for _ = 1, 1000 do
    assert(periodic_plugin:syncCapturedCheckpoint(
        "B0FLB24198", 0.46, "reading", "periodic", "stress"
    ))
end
for _, command in ipairs(commands) do
    assert(not command:match("lipc%-hash%-prop"),
        "1,000 periodic checkpoints must publish zero shelf actions")
end

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

-- Native imports are additive: create missing ranges, fill only an empty note,
-- preserve a conflicting KOReader note, emit one persistence event, and
-- acknowledge the private snapshot only after that event succeeds.
local import_plugin = newPlugin(settings({
    annotation_sync_enabled = true,
    native_annotation_import_enabled = true,
}))
local import_snapshot_path = "/tmp/goodreads-native-import-merge-test"
local snapshot_file = assert(io.open(import_snapshot_path, "w"))
snapshot_file:write("private test snapshot")
snapshot_file:close()
local empty_note = { drawer = "lighten", pos0 = "/a.1", pos1 = "/a.2", note = "" }
local conflict = { drawer = "lighten", pos0 = "/b.1", pos1 = "/b.2", note = "KOReader wins" }
local imported_annotations = { empty_note, conflict }
local imported_event
local import_reader = {
    annotation = {
        annotations = imported_annotations,
        addItem = function(_, item)
            table.insert(imported_annotations, item)
            return #imported_annotations
        end,
    },
    document = {
        getTextFromXPointers = function(_, first, second)
            return first .. second
        end,
    },
    view = { highlight = { saved_drawer = "underscore" } },
    toc = { getTocTitleByPage = function() return "Chapter" end },
    handleEvent = function(_, event) imported_event = event end,
}
local import_snapshot = {
    path = import_snapshot_path,
    items = {
        { note = "native fills empty" },
        { note = "native conflict" },
        { note = "" },
        { note = "native new note" },
    },
}
local import_positions = {
    { start = { xpointer = "/a.1" }, ["end"] = { xpointer = "/a.2" } },
    { start = { xpointer = "/b.2" }, ["end"] = { xpointer = "/b.1" } },
    { start = { xpointer = "/c.1" }, ["end"] = { xpointer = "/c.2" } },
    { start = { xpointer = "/d.1" }, ["end"] = { xpointer = "/d.2" } },
}
assert(import_plugin:applyNativeAnnotationImport(
    import_reader, import_snapshot, import_positions))
assert(empty_note.note == "native fills empty", "native import should fill an empty note")
assert(conflict.note == "KOReader wins", "native import must preserve a conflicting KOReader note")
assert(#imported_annotations == 4, "native import should add only missing ranges")
assert(imported_annotations[3].drawer == "underscore", "import should inherit the reader drawer")
assert(imported_annotations[4].note == "native new note", "new native note should be retained")
assert(imported_event and imported_event.name == "AnnotationsModified",
    "native import must emit KOReader's persistence event")
assert(imported_event.args.nb_highlights_added == 2,
    "native import event must count newly added highlights")
assert(imported_event.args.nb_notes_added == 2,
    "native import event must count new and filled notes")
assert(io.open(import_snapshot_path, "r") == nil,
    "native snapshot must be acknowledged after the persistence event")

-- Position translation must be detached from KOReader's UI thread. Closing,
-- suspending, or editing an annotation may persist a snapshot synchronously,
-- but must only spawn the translator and poll for its atomic result.
local nonblocking = newPlugin(settings({ annotation_sync_enabled = true }))
local nonblocking_snapshot = {
    asin = "B0FLB24198",
    epub_path = "/mnt/us/koreader/cache/kindle.koplugin/test.epub",
    native_path = "/mnt/us/documents/Test_B0FLB24198.kfx",
    desired = {
        { start = "/body/p[1].0", finish = "/body/p[1].10", note = "" },
    },
    trigger = "close",
    token = 1,
    sequence = 1,
    outbox_checksum = string.rep("a", 64),
    attempt = 0,
}
nonblocking.annotation_snapshot_tokens.B0FLB24198 = 1
local original_nonblocking_open = io.open
local original_nonblocking_popen = io.popen
io.open = function(path, mode)
    if path == "/mnt/us/koreader/plugins/kindle.koplugin/kindle-helper"
        and mode == "rb"
    then
        return { close = function() end }
    end
    if type(path) == "string"
        and path:match("^/tmp/goodreads%-position%-result%-.+%.request%.json$")
    then
        return {
            write = function() end,
            close = function() end,
        }
    end
    if path == nonblocking_snapshot.translation_result_path and mode == "rb" then
        return {
            read = function() return "coordinate-only result" end,
            close = function() end,
        }
    end
    if type(path) == "string"
        and path:match("^/tmp/goodreads%-annotations%-.+%.properties$")
    then
        return {
            write = function() end,
            close = function() end,
        }
    end
    return original_nonblocking_open(path, mode)
end
io.popen = function()
    error("position translation must not use blocking io.popen")
end
local commands_before_translation = #commands
local scheduled_before_translation = #scheduled
assert(nonblocking:startAnnotationReconcile(nonblocking_snapshot))
assert(nonblocking.annotation_sync_inflight == nonblocking_snapshot,
    "background translation must reserve the single-flight lane")
assert(#commands >= commands_before_translation + 2,
    "background translation must create a private request and spawn a worker")
local translation_command = commands[#commands]
assert(translation_command:match("translate%-positions"),
    "background worker must invoke the batch position translator")
assert(translation_command:match("&$"),
    "position translator must be detached from KOReader's UI thread")
assert(#scheduled == scheduled_before_translation + 1,
    "translation result must be polled asynchronously")
local original_json_decode = package.loaded.json.decode
package.loaded.json.decode = function()
    return {
        ok = true,
        positions = {
            {
                start = { long = "AAAAAAAAAAAA", pid = 1 },
                ["end"] = { long = "AAAAAAAAAAAB", pid = 2 },
            },
        },
    }
end
local translation_poll = table.remove(scheduled, scheduled_before_translation + 1)
translation_poll()
assert(commands[#commands]:match("sync%-annotations"),
    "validated coordinates must queue the native annotation helper")
assert(nonblocking_snapshot.translation_result_path == nil,
    "successful translation must remove transient coordinate files")
assert(#scheduled == scheduled_before_translation + 1,
    "native annotation result must be polled asynchronously")
table.remove(scheduled)
package.loaded.json.decode = original_json_decode
nonblocking.annotation_sync_inflight = nil
io.open = original_nonblocking_open
io.popen = original_nonblocking_popen

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

-- Durable receipt diagnostics must survive outside session state, overlay a
-- real pending file, and reject arbitrary values rather than displaying them.
local original_open = io.open
local receipt_path = "/mnt/us/koreader/settings/goodreads_native_sync_receipts/B0FLB24198"
local pending_path = assert(os.getenv("GOODREADS_PRIVATE_STATE_DIR"))
    .. "/annotation-pending/B0FLB24198"
io.open = function(path, mode)
    if path == receipt_path then
        local receipt_lines = {
            "version=1",
            "asin=B0FLB24198",
            "state=queued_amazon",
            "saved_at=1786885000",
            "desired_count=2",
            "note_count=1",
            "retry_count=3",
            "retry_reason=private text must not be displayed",
            "agent_generation=27",
            "local_verified=true",
            "journal_lane=legacy",
            "upload_requested=true",
            "sync_enqueued=true",
            "outbox_sequence=12",
            "outbox_acknowledged=true",
            "cloud_observed=unavailable",
        }
        return {
            lines = function()
                local index = 0
                return function()
                    index = index + 1
                    return receipt_lines[index]
                end
            end,
            close = function() end,
        }
    end
    if path == pending_path and mode == "rb" then
        return { close = function() end }
    end
    return original_open(path, mode)
end
shown_messages = {}
active.ui = reader
reader.document = { virtual_path = "KINDLE_VIRTUAL://B0FLB24198/book.epub" }
active:showDiagnostics()
local receipt_message = shown_messages[#shown_messages] and shown_messages[#shown_messages].text or ""
assert(receipt_message:match("Durable annotation receipt"), "diagnostics must include durable receipts")
assert(receipt_message:match("waiting for native reader"), "pending state must override a stale queued receipt")
assert(receipt_message:match("Cloud observation: unavailable"), "upload must not imply cloud observation")
assert(receipt_message:match("Outbox: sequence 12; acknowledged deletion true"),
    "diagnostics must expose durable outbox acknowledgement")
assert(not receipt_message:match("private text"), "receipt diagnostics must reject arbitrary values")
io.open = original_open

-- Exercise the real atomic storage implementation. Simulated interruption
-- artifacts, a sequence file behind/ahead of the committed snapshot, and a
-- corrupt previous snapshot must never prevent the newest state from winning.
os.execute = original_execute
local private_root = assert(os.getenv("GOODREADS_PRIVATE_STATE_DIR"))
local outbox_dir = private_root .. "/annotation-outbox"
local sequence_dir = private_root .. "/annotation-sequences"
local storage_plugin = setmetatable({}, { __index = Goodreads })
local storage_snapshot = {
    asin = "B012345678",
    epub_path = "/mnt/us/koreader/cache/kindle.koplugin/test.epub",
    native_path = "/mnt/us/documents/Test_B012345678.kfx",
    trigger = "fault_test",
    desired = {
        { start = "/body/p[1].0", finish = "/body/p[1].1", note = "" },
    },
}
assert(storage_plugin:persistAnnotationOutbox(storage_snapshot))
assert(storage_snapshot.sequence == 1, "first durable sequence must be one")

local interrupted = assert(io.open(outbox_dir .. "/B012345678.interrupted", "w"))
interrupted:write("partial write")
interrupted:close()
local sequence_file = assert(io.open(sequence_dir .. "/B012345678", "w"))
sequence_file:write("50\n")
sequence_file:close()
storage_snapshot.desired[1].finish = "/body/p[1].2"
assert(storage_plugin:persistAnnotationOutbox(storage_snapshot))
assert(storage_snapshot.sequence == 51, "persisted sequence high-water mark must win")

sequence_file = assert(io.open(sequence_dir .. "/B012345678", "w"))
sequence_file:write("1\n")
sequence_file:close()
storage_snapshot.desired[1].finish = "/body/p[1].3"
assert(storage_plugin:persistAnnotationOutbox(storage_snapshot))
assert(storage_snapshot.sequence == 52, "valid committed outbox must repair a stale sequence file")

local corrupt = assert(io.open(outbox_dir .. "/B012345678", "w"))
corrupt:write("corrupt committed snapshot\n")
corrupt:close()
storage_snapshot.desired[1].finish = "/body/p[1].4"
assert(storage_plugin:persistAnnotationOutbox(storage_snapshot))
assert(storage_snapshot.sequence == 53, "sequence file must recover from a corrupt outbox")

local handoff_stages = {
    "after_body_write",
    "after_checksum",
    "after_envelope_write",
    "after_outbox_commit",
    "after_sequence_write",
    "after_sequence_commit",
}
for index, stage in ipairs(handoff_stages) do
    storage_snapshot.desired[1].finish = "/body/fault[" .. tostring(index) .. "]"
    storage_plugin.annotation_outbox_fault_stage = stage
    assert(not storage_plugin:persistAnnotationOutbox(storage_snapshot),
        "fault stage must interrupt persistence: " .. stage)
    storage_plugin.annotation_outbox_fault_stage = nil
    assert(storage_plugin:persistAnnotationOutbox(storage_snapshot),
        "next launch must recover after interruption: " .. stage)
end
assert(storage_snapshot.sequence == 62, "handoff recovery must preserve monotonic sequence state")

for transition = 1, 1000 do
    storage_snapshot.desired[1].finish = "/body/p[1]." .. tostring(transition + 4)
    storage_snapshot.desired[1].note = transition % 2 == 0 and "latest private note" or ""
    assert(storage_plugin:persistAnnotationOutbox(storage_snapshot))
end
assert(storage_snapshot.sequence == 1062, "1,000 replacements must remain monotonic")
local final_file = assert(original_open(outbox_dir .. "/B012345678", "rb"))
local final_content = final_file:read("*a")
final_file:close()
local outbox_codec = assert(package.loaded.annotationoutbox)
local final_body, final_checksum = assert(outbox_codec.split(final_content))
local final_snapshot = assert(outbox_codec.parse(final_body, "B012345678"))
assert(final_snapshot.sequence == 1062, "final outbox must contain the newest sequence")
assert(final_snapshot.desired[1].finish == storage_snapshot.desired[1].finish,
    "final outbox must contain the newest range")
assert(final_snapshot.desired[1].note == storage_snapshot.desired[1].note,
    "final outbox must contain the newest note edit/removal")
assert(#final_checksum == 64, "final outbox must carry a SHA-256 checksum")
local checksum_input = private_root .. "/checksum-input"
local checksum_file = assert(original_open(checksum_input, "wb"))
checksum_file:write(final_body)
checksum_file:close()
local checksum_pipe = assert(io.popen(
    assert(os.getenv("GOODREADS_SHA256_TOOL")) .. " " .. checksum_input,
    "r"
))
local computed_checksum = assert(checksum_pipe:read("*l")):match("^([0-9a-f]+)")
checksum_pipe:close()
assert(computed_checksum == final_checksum, "final outbox checksum must verify")

local resumed = {}
local restart_plugin = newPlugin(settings({ annotation_sync_enabled = true }))
restart_plugin.startAnnotationReconcile = function(self, queued)
    self.annotation_sync_inflight = queued
    table.insert(resumed, queued)
    return true
end
restart_plugin:resumeAnnotationOutbox()
assert(#resumed == 1, "KOReader restart must resume one coalesced source snapshot")
assert(resumed[1].sequence == 1062, "restart must resume the newest durable sequence")
assert(resumed[1].desired[1].finish == storage_snapshot.desired[1].finish,
    "restart must resume the newest user intent")

os.execute = original_execute

print("Plugin behavior tests passed.")
