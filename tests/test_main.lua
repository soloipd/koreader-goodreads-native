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

-- Annotation handoff must repair a stale kindle.koplugin source_path from the
-- current catalog. It may never guess when more than one readable local row
-- survives the strict catalog filter.
local function testHex(value)
    return (value:gsub(".", function(character)
        return string.format("%02x", string.byte(character))
    end))
end
local catalog_native_path = "/mnt/us/documents/current local copy.kfx"
local stale_native_path = "/mnt/us/documents/removed copy.kfx"
local catalog_epub_path = "/mnt/us/koreader/cache/kindle.koplugin/cc_test.epub"
package.loaded["lua/readerui_ext"] = {
    virtual_library = {
        getVirtualPath = function(_, value) return value end,
        getBook = function()
            return {
                cde_key = "B099999999",
                source_path = stale_native_path,
            }
        end,
    },
}
local annotation_catalog_reader = {
    document = {
        file = "/mnt/us/koreader/cache/kindle.koplugin/cc_test.epub",
        virtual_path = "KINDLE_VIRTUAL://B099999999/book.epub",
    },
    annotation = {
        annotations = {
            { drawer = "lighten", pos0 = "/body/p[1].0", pos1 = "/body/p[1].1" },
        },
    },
}
local annotation_catalog_plugin = newPlugin(settings({ annotation_sync_enabled = true }))
local original_catalog_open = io.open
io.open = function(path, mode)
    if (path == catalog_native_path or path == catalog_epub_path)
        and mode == "rb"
    then
        return { close = function() end }
    end
    return original_catalog_open(path, mode)
end
io.popen = function(command)
    assert(command:match("SELECT DISTINCT lower%(hex%(p_location%)%)"),
        "native path lookup must use a text-free catalog protocol")
    assert(command:match("p_cdeKey='B099999999'"),
        "native path lookup must use the strictly validated ASIN")
    assert(command:match("p_isArchived,0%)=0")
        and command:match("p_isDownloading,0%)=0")
        and command:match("p_isVisibleInHome,1%)=1"),
        "native path lookup must reject archived, downloading, and hidden rows")
    local values = { testHex(catalog_native_path) }
    return {
        lines = function()
            local index = 0
            return function()
                index = index + 1
                return values[index]
            end
        end,
        close = function() end,
    }
end
local captured_catalog_snapshot = assert(
    annotation_catalog_plugin:captureAnnotationSnapshot(
        annotation_catalog_reader, "catalog_repair"))
assert(captured_catalog_snapshot.native_path == catalog_native_path,
    "annotation handoff must replace a stale mapped path with the unique local catalog path")

io.open = function(path, mode)
    if (path == catalog_native_path
            or path == "/mnt/us/documents/second.kfx"
            or path == stale_native_path)
        and mode == "rb"
    then
        return { close = function() end }
    end
    return original_catalog_open(path, mode)
end
io.popen = function()
    local values = {
        testHex(catalog_native_path),
        testHex("/mnt/us/documents/second.kfx"),
    }
    return {
        lines = function()
            local index = 0
            return function()
                index = index + 1
                return values[index]
            end
        end,
        close = function() end,
    }
end
local ambiguous_snapshot, ambiguous_error =
    annotation_catalog_plugin:captureAnnotationSnapshot(
        annotation_catalog_reader, "catalog_ambiguous")
assert(not ambiguous_snapshot and ambiguous_error == "Kindle source paths unavailable",
    "annotation handoff must fail closed for ambiguous readable catalog rows")
io.open = original_catalog_open
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
    asin = "B0FLB24198",
    snapshot_complete = true,
    items = {
        { start_long = "AAAAAAAAAAA1", end_long = "AAAAAAAAAAA2", note = "native fills empty" },
        { start_long = "AAAAAAAAAAA3", end_long = "AAAAAAAAAAA4", note = "native conflict" },
        { start_long = "AAAAAAAAAAA5", end_long = "AAAAAAAAAAA6", note = "" },
        { start_long = "AAAAAAAAAAA7", end_long = "AAAAAAAAAAA8", note = "native new note" },
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
assert(imported_event.args.nb_highlights_added == nil,
    "one filled note and one plain added highlight must have zero net highlight delta")
assert(imported_event.args.nb_notes_added == 2,
    "native import event must count new and filled notes")
assert(empty_note.goodreads_native_provenance.highlight_created == false
    and empty_note.goodreads_native_provenance.note_imported == true,
    "an imported note on an existing highlight must own only the note")
assert(conflict.goodreads_native_provenance == nil,
    "a conflicting KOReader note must never acquire native ownership")
assert(imported_annotations[3].goodreads_native_provenance.highlight_created == true,
    "a newly imported range must record native highlight ownership")
assert(io.open(import_snapshot_path, "r") == nil,
    "native snapshot must be acknowledged after the persistence event")

-- Component-level provenance makes native deletions safe. A native-created
-- highlight may be removed only while its range, note, and style remain at the
-- imported baseline. Existing KOReader highlights can own an imported note
-- without giving native sync ownership of the highlight itself.
local import_case_sequence = 0
local function newImportReader(initial)
    local annotations = initial or {}
    local events = {}
    return {
        annotation = {
            annotations = annotations,
            addItem = function(_, item)
                table.insert(annotations, item)
                return #annotations
            end,
        },
        document = {
            virtual_path = "KINDLE_VIRTUAL://B0FLB24198/book.epub",
            getTextFromXPointers = function(_, first, second)
                return first .. second
            end,
        },
        view = { highlight = { saved_drawer = "lighten" } },
        toc = { getTocTitleByPage = function() return nil end },
        events = events,
        handleEvent = function(_, event) table.insert(events, event) end,
    }, annotations
end

local function completeNativeSnapshot(plugin_, reader_, specs, fixed_path)
    import_case_sequence = import_case_sequence + 1
    local path = fixed_path
        or ("/tmp/goodreads-native-provenance-test-" .. import_case_sequence)
    local file = assert(io.open(path, "w"))
    file:write("private test snapshot")
    file:close()
    local items, translated = {}, {}
    for _, spec in ipairs(specs) do
        table.insert(items, {
            start_long = string.format("A%011d", spec.id * 2 - 1),
            end_long = string.format("A%011d", spec.id * 2),
            note = spec.note or "",
        })
        table.insert(translated, {
            start = { xpointer = spec.pos0 },
            ["end"] = { xpointer = spec.pos1 },
        })
    end
    local ok_, detail_ = plugin_:applyNativeAnnotationImport(reader_, {
        path = path,
        asin = "B0FLB24198",
        snapshot_complete = true,
        items = items,
    }, translated)
    return ok_, detail_, path
end

local owned_plugin = newPlugin(settings({ native_annotation_import_enabled = true }))
local owned_reader, owned = newImportReader()
assert(completeNativeSnapshot(owned_plugin, owned_reader, {
    { id = 1, pos0 = "/owned.1", pos1 = "/owned.2", note = "native first" },
}))
assert(#owned == 1 and owned[1].goodreads_native_provenance.highlight_created,
    "new native highlight must record highlight ownership")
assert(owned[1].goodreads_native_provenance.note_value == "native first",
    "native note baseline must stay private in KOReader metadata")

local no_echo_plugin = newPlugin(settings({ native_annotation_import_enabled = true }))
local no_echo_reader, no_echo_annotations = newImportReader()
local no_echo_schedules = 0
no_echo_plugin.ui = no_echo_reader
no_echo_plugin.scheduleAnnotationReconcile = function()
    no_echo_schedules = no_echo_schedules + 1
end
no_echo_reader.handleEvent = function(_, event)
    no_echo_plugin:onAnnotationsModified(event.args)
end
assert(completeNativeSnapshot(no_echo_plugin, no_echo_reader, {
    { id = 9, pos0 = "/no-echo.1", pos1 = "/no-echo.2", note = "native" },
}))
assert(#no_echo_annotations == 1, "native import must still persist the annotation")
assert(no_echo_schedules == 0,
    "native import persistence event must not schedule an outbound echo")
no_echo_plugin:onAnnotationsModified({ no_echo_annotations[1] })
assert(no_echo_schedules == 1,
    "a later user annotation event must still schedule outbound reconciliation")

local startup_flow_plugin = newPlugin(settings({ native_annotation_import_enabled = true }))
local startup_flow_reader = newImportReader()
startup_flow_plugin.ui = startup_flow_reader
local startup_flow = {}
startup_flow_plugin.scheduleAnnotationReconcile = function(_, trigger)
    table.insert(startup_flow, trigger)
end
startup_flow_plugin.queueAnnotationReconcile = function(_, _, trigger)
    table.insert(startup_flow, trigger)
    return true, "queued"
end
startup_flow_plugin.queueNativeAnnotationImport = function(_, _, completion)
    table.insert(startup_flow, "import_first")
    completion(true)
    completion(true) -- defensive duplicate completion must remain idempotent
    return true, "queued", true
end
startup_flow_plugin:startReaderReadyAnnotationFlow(startup_flow_reader)
assert(startup_flow[1] == "import_first"
    and startup_flow[2] == "reader_ready_converged" and #startup_flow == 2,
    "ReaderReady must import before capturing the converged outbound snapshot")

startup_flow = {}
startup_flow_plugin.queueNativeAnnotationImport = function()
    return false, "no_snapshot", false
end
startup_flow_plugin:startReaderReadyAnnotationFlow(startup_flow_reader)
assert(startup_flow[1] == "reader_ready_converged" and #startup_flow == 1,
    "ReaderReady without a native snapshot must retain normal outbound sync")

startup_flow = {}
startup_flow_plugin.queueNativeAnnotationImport = function()
    return false, "invalid native import metadata", true
end
startup_flow_plugin:startReaderReadyAnnotationFlow(startup_flow_reader)
assert(#startup_flow == 0,
    "invalid pending native snapshot must block a destructive pre-import outbound snapshot")

local private_test_root = assert(os.getenv("GOODREADS_PRIVATE_STATE_DIR"))
local pending_import_dir = private_test_root .. "/native-import"
original_execute("mkdir -p " .. pending_import_dir)
local pending_import_path = pending_import_dir .. "/B0FLB24198"
local pending_import_file = assert(io.open(pending_import_path, "w"))
pending_import_file:write("complete private snapshot fixture")
pending_import_file:close()
local stale_queue_plugin = newPlugin(settings({
    annotation_sync_enabled = true,
    native_annotation_import_enabled = true,
}))
local stale_queued, stale_detail = stale_queue_plugin:queueAnnotationSnapshot({
    asin = "B0FLB24198",
    trigger = "reader_ready",
    desired = {},
})
assert(not stale_queued
    and stale_detail == "native import must resolve before queued outbound snapshot",
    "resumed stale outbox must not run while the same book has a pending native import")
os.remove(pending_import_path)

owned_reader.events = {}
owned_reader.handleEvent = function(_, event) table.insert(owned_reader.events, event) end
assert(completeNativeSnapshot(owned_plugin, owned_reader, {
    { id = 1, pos0 = "/owned.1", pos1 = "/owned.2", note = "native edited" },
}))
assert(owned[1].note == "native edited", "unchanged imported note must accept a native edit")
assert(#owned_reader.events == 1, "native note edit must persist exactly once")

owned_reader.events = {}
assert(completeNativeSnapshot(owned_plugin, owned_reader, {
    { id = 1, pos0 = "/owned.1", pos1 = "/owned.2", note = "" },
}))
assert(owned[1].note == nil, "native note removal must remove an unchanged imported note")
assert(owned_reader.events[1].args.nb_highlights_added == 1
    and owned_reader.events[1].args.nb_notes_added == -1,
    "note removal must report KOReader's note-to-highlight type transition")

owned_reader.events = {}
assert(completeNativeSnapshot(owned_plugin, owned_reader, {}))
assert(#owned == 0, "unchanged native-owned highlight must follow native deletion")
assert(owned_reader.events[1].args.nb_highlights_added == -1,
    "native highlight deletion must report the removal delta")

local existing_item = {
    drawer = "lighten", pos0 = "/existing.1", pos1 = "/existing.2", note = "",
}
local existing_plugin = newPlugin(settings({ native_annotation_import_enabled = true }))
local existing_reader, existing_annotations = newImportReader({ existing_item })
assert(completeNativeSnapshot(existing_plugin, existing_reader, {
    { id = 2, pos0 = "/existing.1", pos1 = "/existing.2", note = "native-only note" },
}))
assert(existing_item.goodreads_native_provenance.highlight_created == false,
    "pre-existing KOReader range must never become native-owned")
existing_reader.events = {}
existing_reader.handleEvent = function(_, event) table.insert(existing_reader.events, event) end
assert(completeNativeSnapshot(existing_plugin, existing_reader, {}))
assert(#existing_annotations == 1 and existing_item.note == nil,
    "native deletion may remove its note but must preserve a KOReader highlight")
assert(existing_item.goodreads_native_provenance == nil,
    "removed native note must detach its component provenance")

local local_note_plugin = newPlugin(settings({ native_annotation_import_enabled = true }))
local local_note_reader, local_note_annotations = newImportReader()
assert(completeNativeSnapshot(local_note_plugin, local_note_reader, {
    { id = 3, pos0 = "/local-note.1", pos1 = "/local-note.2", note = "native baseline" },
}))
local_note_annotations[1].note = "locally edited"
assert(completeNativeSnapshot(local_note_plugin, local_note_reader, {}))
assert(#local_note_annotations == 1 and local_note_annotations[1].note == "locally edited",
    "local note edit must protect the entire annotation from native deletion")
assert(local_note_annotations[1].goodreads_native_provenance == nil,
    "local note edit must detach native ownership")

local removed_note_plugin = newPlugin(settings({ native_annotation_import_enabled = true }))
local removed_note_reader, removed_note_annotations = newImportReader()
local removed_note_spec = {
    { id = 7, pos0 = "/removed-note.1", pos1 = "/removed-note.2", note = "native baseline" },
}
assert(completeNativeSnapshot(removed_note_plugin, removed_note_reader, removed_note_spec))
removed_note_annotations[1].note = nil
assert(completeNativeSnapshot(removed_note_plugin, removed_note_reader, removed_note_spec))
assert(#removed_note_annotations == 1 and removed_note_annotations[1].note == nil,
    "local note removal must not be immediately re-imported from a stale native snapshot")
assert(removed_note_annotations[1].goodreads_native_provenance.note_value
    == "native baseline",
    "stale native snapshot must retain the pre-edit baseline until Kindle echoes the edit")
local removed_note_echo = {
    { id = 7, pos0 = "/removed-note.1", pos1 = "/removed-note.2", note = "" },
}
assert(completeNativeSnapshot(removed_note_plugin, removed_note_reader, removed_note_echo))
assert(removed_note_annotations[1].goodreads_native_provenance.note_value == "",
    "matching native echo must rebase the locally removed note")
assert(completeNativeSnapshot(removed_note_plugin, removed_note_reader, {}))
assert(#removed_note_annotations == 0,
    "after native echo convergence, a later native highlight deletion must propagate")

local tombstone_plugin = newPlugin(settings({ native_annotation_import_enabled = true }))
local tombstone_reader, tombstone_annotations = newImportReader()
tombstone_plugin.ui = tombstone_reader
local tombstone_spec = {
    { id = 8, pos0 = "/tombstone.1", pos1 = "/tombstone.2", note = "stale native" },
}
assert(completeNativeSnapshot(tombstone_plugin, tombstone_reader, tombstone_spec))
local locally_deleted = table.remove(tombstone_annotations, 1)
local deletion_event = { locally_deleted, index_modified = -1 }
tombstone_plugin:onAnnotationsModified(deletion_event)
local tombstone_key = locally_deleted.goodreads_native_provenance.key
assert(tombstone_plugin.settings.native_annotation_tombstones.B0FLB24198[tombstone_key],
    "local deletion must persist a coordinate-only native tombstone")
assert(completeNativeSnapshot(tombstone_plugin, tombstone_reader, tombstone_spec))
assert(#tombstone_annotations == 0,
    "stale native snapshot must not recreate a locally deleted highlight")
assert(tombstone_plugin.settings.native_annotation_tombstones.B0FLB24198[tombstone_key],
    "tombstone must remain until native deletion is observed")

local incomplete_path = "/tmp/goodreads-native-incomplete-test"
local incomplete_file = assert(io.open(incomplete_path, "w"))
incomplete_file:write("incomplete test snapshot")
incomplete_file:close()
assert(tombstone_plugin:applyNativeAnnotationImport(tombstone_reader, {
    path = incomplete_path,
    asin = "B0FLB24198",
    snapshot_complete = false,
    items = {},
}, {}))
assert(tombstone_plugin.settings.native_annotation_tombstones.B0FLB24198[tombstone_key],
    "incomplete snapshot must not acknowledge a deletion tombstone")
assert(completeNativeSnapshot(tombstone_plugin, tombstone_reader, {}))
assert(tombstone_plugin.settings.native_annotation_tombstones.B0FLB24198 == nil,
    "complete native snapshot without the key must acknowledge the tombstone")

local style_plugin = newPlugin(settings({ native_annotation_import_enabled = true }))
local style_reader, style_annotations = newImportReader()
assert(completeNativeSnapshot(style_plugin, style_reader, {
    { id = 4, pos0 = "/style.1", pos1 = "/style.2", note = "native style note" },
}))
style_annotations[1].drawer = "underscore"
assert(completeNativeSnapshot(style_plugin, style_reader, {}))
assert(#style_annotations == 1 and style_annotations[1].drawer == "underscore",
    "local style edit must preserve the highlight on native deletion")
assert(style_annotations[1].note == nil,
    "native deletion may still remove its unchanged imported note component")

local legacy_item = {
    drawer = "lighten", pos0 = "/legacy.1", pos1 = "/legacy.2",
    goodreads_native_import = true,
}
local legacy_plugin = newPlugin(settings({ native_annotation_import_enabled = true }))
local legacy_reader, legacy_annotations = newImportReader({ legacy_item })
assert(completeNativeSnapshot(legacy_plugin, legacy_reader, {}))
assert(#legacy_annotations == 1 and legacy_item.goodreads_native_import == nil,
    "ambiguous v0.7 ownership must migrate by preserving and detaching")

local idempotent_plugin = newPlugin(settings({ native_annotation_import_enabled = true }))
local idempotent_reader, idempotent_annotations = newImportReader()
local idempotent_spec = {
    { id = 5, pos0 = "/idempotent.1", pos1 = "/idempotent.2", note = "same" },
}
assert(completeNativeSnapshot(idempotent_plugin, idempotent_reader, idempotent_spec))
idempotent_reader.events = {}
idempotent_reader.handleEvent = function(_, event) table.insert(idempotent_reader.events, event) end
assert(completeNativeSnapshot(idempotent_plugin, idempotent_reader, idempotent_spec))
assert(#idempotent_annotations == 1 and #idempotent_reader.events == 0,
    "replaying an identical complete snapshot must be idempotent")

local retry_plugin = newPlugin(settings({ native_annotation_import_enabled = true }))
local retry_reader, retry_annotations = newImportReader()
local retry_path = "/tmp/goodreads-native-provenance-retry"
retry_reader.handleEvent = function() error("injected persistence failure") end
local retry_ok = completeNativeSnapshot(retry_plugin, retry_reader, {
    { id = 6, pos0 = "/retry.1", pos1 = "/retry.2", note = "retry" },
}, retry_path)
assert(not retry_ok and io.open(retry_path, "r") ~= nil,
    "failed KOReader persistence event must retain the native snapshot")
retry_reader.events = {}
retry_reader.handleEvent = function(_, event) table.insert(retry_reader.events, event) end
assert(completeNativeSnapshot(retry_plugin, retry_reader, {
    { id = 6, pos0 = "/retry.1", pos1 = "/retry.2", note = "retry" },
}, retry_path))
assert(#retry_annotations == 1 and #retry_reader.events == 1,
    "retry must re-emit the failed persistence event without duplicating data")
assert(io.open(retry_path, "r") == nil,
    "snapshot may be acknowledged only after persistence retry succeeds")

-- Exercise the full per-book import limit in one complete snapshot, then
-- delete it natively after 250 local note edits and 250 local style edits.
-- Exactly the 500 locally changed annotations must survive and detach.
local provenance_stress_plugin = newPlugin(settings({
    native_annotation_import_enabled = true,
}))
local provenance_stress_reader, provenance_stress_annotations = newImportReader()
local provenance_stress_specs = {}
for index = 1, 1000 do
    table.insert(provenance_stress_specs, {
        id = 1000 + index,
        pos0 = string.format("/stress.%d.1", index),
        pos1 = string.format("/stress.%d.2", index),
        note = index % 2 == 0 and "native stress note" or "",
    })
end
assert(completeNativeSnapshot(
    provenance_stress_plugin, provenance_stress_reader, provenance_stress_specs
))
assert(#provenance_stress_annotations == 1000,
    "maximum-size native snapshot must import all 1,000 annotations")
for index = 1, 250 do
    provenance_stress_annotations[index].note = "local stress edit"
end
for index = 251, 500 do
    provenance_stress_annotations[index].drawer = "underscore"
end
assert(completeNativeSnapshot(provenance_stress_plugin, provenance_stress_reader, {}))
assert(#provenance_stress_annotations == 500,
    "native mass deletion must preserve exactly the 500 locally edited annotations")
for index, item in ipairs(provenance_stress_annotations) do
    assert(item.goodreads_native_provenance == nil,
        "surviving stress annotation must detach native ownership")
    if index <= 250 then
        assert(item.note == "local stress edit", "stress deletion must preserve local notes")
    else
        assert(item.drawer == "underscore", "stress deletion must preserve local styles")
    end
end

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
local resume_failure_status
restart_plugin.debugLog = function(_, event, fields)
    if event == "annotations_outbox_resume_failed" then
        resume_failure_status = fields.status
    end
end
restart_plugin.startAnnotationReconcile = function(self, queued)
    self.annotation_sync_inflight = queued
    table.insert(resumed, queued)
    return true
end
local migrated_native_path = "/mnt/us/documents/Replaced_B012345678.kfx"
local migrated_uuid = "12345678-1234-1234-1234-123456789abc"
local migrated_epub_path = "/mnt/us/koreader/cache/kindle.koplugin/cc_"
    .. migrated_uuid .. ".epub"
local resume_original_open = io.open
local resume_original_popen = io.popen
io.open = function(path, mode)
    if (path == migrated_native_path or path == migrated_epub_path)
        and mode == "rb"
    then
        return { close = function() end }
    end
    return resume_original_open(path, mode)
end
io.popen = function(command, mode)
    if command:match("^/usr/bin/sqlite3 %-readonly /var/local/cc%.db") then
        local value = command:match("hex%(p_uuid%)")
            and testHex(migrated_uuid)
            or testHex(migrated_native_path)
        local values = { value }
        return {
            lines = function()
                local index = 0
                return function()
                    index = index + 1
                    return values[index]
                end
            end,
            close = function() end,
        }
    end
    return resume_original_popen(command, mode)
end
restart_plugin:resumeAnnotationOutbox()
assert(#resumed == 1, "KOReader restart must resume one coalesced source snapshot: "
    .. tostring(resume_failure_status))
assert(resumed[1].sequence == 1063,
    "stale-path migration must advance the durable sequence exactly once")
assert(resumed[1].native_path == migrated_native_path,
    "restart must repair an existing stale outbox from the current catalog")
assert(resumed[1].epub_path == migrated_epub_path,
    "restart must repair the converted cache path in the same durable sequence")
assert(resumed[1].desired[1].finish == storage_snapshot.desired[1].finish,
    "restart must resume the newest user intent")
io.open = resume_original_open
io.popen = resume_original_popen

os.execute = original_execute

print("Plugin behavior tests passed.")
