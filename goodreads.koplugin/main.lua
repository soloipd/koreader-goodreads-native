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
local json = require("json")
local util = require("util")
local Event = require("ui/event")
local AnnotationOutbox = require("annotationoutbox")

local LIPC_HASH_TOOL = "/usr/bin/lipc-hash-prop"
local SQLITE_TOOL = "/usr/bin/sqlite3"
local CONTENT_CATALOG = "/var/local/cc.db"
local KAF_PUBLISHER = "com.lab126.kppkaf"
local KAF_PROPERTY = "kppAddToGoodreadShelf"
local ACTION_READING = "com.amazon.home.actions.goodread_reading"
local ACTION_READ = "com.amazon.home.actions.goodread_read"
local PROGRESS_HELPER = "/mnt/us/koreader/plugins/goodreads.koplugin/bin/sync-progress"
local ANNOTATION_HELPER = "/mnt/us/koreader/plugins/goodreads.koplugin/bin/sync-annotations"
local RECEIPT_HELPER = "/mnt/us/koreader/plugins/goodreads.koplugin/bin/manage-sync-receipts"
local KINDLE_HELPER_PATHS = {
    "/mnt/us/koreader/plugins/kindle.koplugin/kindle-helper",
    "/mnt/us/koreader/plugins/kindle.koplugin/bin/kindle-helper",
}
local ANNOTATION_STATE_DIR = "/mnt/us/koreader/settings/goodreads_native_annotations"
local SYNC_RECEIPT_DIR = "/mnt/us/koreader/settings/goodreads_native_sync_receipts"
local SUPPORT_BUNDLE_FILE = "/mnt/us/koreader/settings/goodreads_native_support.txt"
local PRIVATE_STATE_DIR = os.getenv("GOODREADS_PRIVATE_STATE_DIR")
    or "/var/local/koreader-goodreads-native"
local ANNOTATION_PENDING_DIR = PRIVATE_STATE_DIR .. "/annotation-pending"
local ANNOTATION_OUTBOX_DIR = PRIVATE_STATE_DIR .. "/annotation-outbox"
local NATIVE_IMPORT_DIR = PRIVATE_STATE_DIR .. "/native-import"
local NATIVE_IMPORT_ENABLED_FILE = PRIVATE_STATE_DIR .. "/native-import-enabled"
local NATIVE_IMPORT_WATCHER = "/mnt/us/koreader/plugins/goodreads.koplugin/bin/watch-native-annotations"
local ANNOTATION_SEQUENCE_DIR = PRIVATE_STATE_DIR .. "/annotation-sequences"
local SHA256_TOOL = os.getenv("GOODREADS_SHA256_TOOL") or "/usr/bin/sha256sum"
local RATING_HELPER = "/mnt/us/koreader/plugins/goodreads.koplugin/bin/sync-rating"
local RATING_RESULT_PREFIX = "/tmp/goodreads-rating-result"
local PROGRESS_RESULT_FILE = "/tmp/goodreads-progress-result.log"
local ANNOTATION_RESULT_FILE = "/tmp/goodreads-annotation-result.log"
local PROGRESS_STATE_DIR = "/mnt/us/koreader/settings/goodreads_native_progress"
local DEBUG_LOG_FILE = "/mnt/us/koreader/settings/goodreads_native_debug.log"
local DEBUG_LOG_MAX_BYTES = 128 * 1024
local DEFAULT_PROGRESS_INTERVAL_SECONDS = 300
local PROGRESS_RESULT_KEYS = {
    asin = true,
    percent = true,
    started_at = true,
    finished_at = true,
    http_status = true,
    response_valid = true,
    error_envelope = true,
    success = true,
    failed_stage = true,
    error_class = true,
}
local ANNOTATION_RESULT_KEYS = {
    asin = true,
    request_id = true,
    requested = true,
    local_success = true,
    local_verified = true,
    native_notified = true,
    ksdk_synced = true,
    legacy_journaled = true,
    native_cloud_queued = true,
    cloud_synced = true,
    cloud_snapshot_synced = true,
    success = true,
    failed_stage = true,
    error_class = true,
    highlights_created = true,
    highlights_deleted = true,
    notes_created = true,
    notes_updated = true,
    notes_deleted = true,
    native_notifications = true,
    zero_endpoint_repairs = true,
    terminal_endpoint_repairs = true,
    cloud_edits = true,
    cloud_snapshots = true,
    ksdk_writes = true,
    native_journal_edits = true,
    native_upload_requests = true,
    legacy_cloud_deletes = true,
    book_source = true,
    sync_enqueued = true,
    outbox_sequence = true,
    outbox_acknowledged = true,
}
local SYNC_RECEIPT_KEYS = {
    version = true,
    asin = true,
    state = true,
    updated_at = true,
    saved_at = true,
    waiting_at = true,
    queued_at = true,
    desired_count = true,
    note_count = true,
    retry_count = true,
    retry_reason = true,
    agent_generation = true,
    trigger = true,
    local_verified = true,
    native_notified = true,
    journal_lane = true,
    upload_requested = true,
    sync_enqueued = true,
    cloud_observed = true,
    outbox_sequence = true,
    outbox_acknowledged = true,
}
local DEBUG_FIELD_ORDER = {
    "trigger",
    "asin",
    "percent",
    "rating",
    "resolver",
    "action",
    "status",
    "http_status",
    "response_valid",
    "error_envelope",
    "success",
    "local_success",
    "local_verified",
    "native_notified",
    "ksdk_synced",
    "legacy_journaled",
    "native_cloud_queued",
    "cloud_synced",
    "cloud_snapshot_synced",
    "failed_stage",
    "error_class",
    "changed",
    "annotations",
    "highlights",
    "notes",
    "bookmarks",
    "highlights_created",
    "highlights_deleted",
    "notes_created",
    "notes_updated",
    "notes_deleted",
    "native_notifications",
    "zero_endpoint_repairs",
    "terminal_endpoint_repairs",
    "cloud_edits",
    "cloud_snapshots",
    "ksdk_writes",
    "native_journal_edits",
    "native_upload_requests",
    "legacy_cloud_deletes",
    "book_source",
    "sync_enqueued",
    "outbox_sequence",
    "outbox_acknowledged",
    "interval_seconds",
    "attempt",
    "duplicates_collapsed",
    "ownership_detached",
    "legacy_detached",
    "tombstones_blocked",
    "tombstones_cleared",
}
local DEBUG_ALLOWED_FIELDS = {}
for _, key in ipairs(DEBUG_FIELD_ORDER) do
    DEBUG_ALLOWED_FIELDS[key] = true
end

local Goodreads = WidgetContainer:extend({
    name = "goodreads_native",
    is_doc_only = false,
})
local outbox_resume_scheduled = false

local function isAsin(value)
    return type(value) == "string" and value:match("^B[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]$") ~= nil
end

local function hexDecode(value, maximum)
    if type(value) ~= "string" or #value % 2 ~= 0 or #value > maximum * 2
        or value:find("[^0-9a-f]")
    then
        return nil
    end
    return (value:gsub("..", function(pair)
        return string.char(tonumber(pair, 16))
    end))
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

local function getKindleLibraryBook(reader)
    local reader_ext = package.loaded["lua/readerui_ext"]
        or package.loaded["lua/showreader_ext"]
    local virtual_library = reader_ext and reader_ext.virtual_library
    if not virtual_library or type(virtual_library.getBook) ~= "function" then
        return nil
    end

    local document = reader and reader.document
    local settings = reader and reader.doc_settings
    local candidates = {}
    if document and document.virtual_path then
        table.insert(candidates, document.virtual_path)
    end
    if document and document.file then
        table.insert(candidates, document.file)
    end
    if settings and settings.data and settings.data.doc_path then
        table.insert(candidates, settings.data.doc_path)
    end

    for _, candidate in ipairs(candidates) do
        if candidate then
            local lookup = candidate
            if type(virtual_library.getVirtualPath) == "function" then
                local ok_virtual, virtual_path = pcall(
                    virtual_library.getVirtualPath,
                    virtual_library,
                    candidate
                )
                if ok_virtual and virtual_path then
                    lookup = virtual_path
                end
            end

            local ok_book, book = pcall(
                virtual_library.getBook,
                virtual_library,
                lookup
            )
            if ok_book and book then
                return book
            end
        end
    end

    -- After a KOReader restart, ReadHistory may reopen the converted EPUB
    -- directly. kindle.koplugin names those files from cc.db IDs by replacing
    -- the `cc:` prefix with `cc_`; recover the internal ID and ask its already
    -- loaded virtual-library index for the original record.
    local cache_name = document
        and document.file
        and document.file:match("/([^/]+)%.epub$")
    local id_prefix, id_value = cache_name and cache_name:match("^(cc)_(.+)$")
    if not id_prefix and cache_name then
        id_prefix, id_value = cache_name:match("^(sha1)_(.+)$")
    end
    if id_prefix and id_value then
        local ok_book, book = pcall(
            virtual_library.getBook,
            virtual_library,
            id_prefix .. ":" .. id_value
        )
        if ok_book and book then
            return book
        end
    end

    -- Future scanners may introduce other ID schemes. Match the cache
    -- manager's documented sanitization against the loaded catalog instead of
    -- assuming a particular title, ASIN, UUID, or filename.
    if cache_name and type(virtual_library.books_by_id) == "table" then
        for book_id, book in pairs(virtual_library.books_by_id) do
            local safe_id = tostring(book_id):gsub("[^%w%.%-_]", "_")
            if safe_id == cache_name then
                return book
            end
        end
    end

    return nil
end

local function getAsinFromContentCatalog(reader)
    local file = reader and reader.document and reader.document.file
    local uuid = file and file:match("/cc_([%x%-]+)%.epub$")
    if not uuid or #uuid ~= 36 then
        return nil
    end

    local compact_uuid, hyphen_count = uuid:gsub("%-", "")
    if #compact_uuid ~= 32 or hyphen_count ~= 4 or not compact_uuid:match("^%x+$") then
        return nil
    end

    -- uuid has a strict hex-and-hyphen allowlist, and both executable/database
    -- paths are constants. The read-only query returns only p_cdeKey; no title,
    -- annotation, account, or session data is accessed.
    local query = string.format(
        "SELECT p_cdeKey FROM Entries WHERE p_uuid='%s' LIMIT 1;",
        uuid
    )
    local command = string.format(
        "%s -readonly %s \"%s\" 2>/dev/null",
        SQLITE_TOOL,
        CONTENT_CATALOG,
        query
    )
    local pipe = io.popen(command, "r")
    if not pipe then
        return nil
    end
    local cde_key = pipe:read("*l")
    pipe:close()
    if isAsin(cde_key) then
        return cde_key
    end
    return nil
end

local function getBookAsin(reader)
    local asin = extractAsin(getDocumentPath(reader))
    if asin then
        return asin, "document_path"
    end

    local book = getKindleLibraryBook(reader)
    if book then
        if isAsin(book.cde_key) then
            return book.cde_key, "kindle_library"
        end
        asin = extractAsin(book.source_path) or extractAsin(book.virtual_path)
        if asin then
            return asin, "kindle_library_path"
        end
    end

    asin = getAsinFromContentCatalog(reader)
    if asin then
        return asin, "content_catalog"
    end
    return nil, "unresolved"
end

local function getBookState(reader)
    local settings = reader and reader.doc_settings
    local percent

    -- percent_finished in doc_settings is persisted by onSaveSettings and can
    -- be stale while a book remains open. ReaderPaging/ReaderRolling expose
    -- the live in-memory position used by KOReader's own footer.
    local progress_module = reader and (reader.paging or reader.rolling)
    if progress_module and type(progress_module.getLastPercent) == "function" then
        local ok, live_percent = pcall(progress_module.getLastPercent, progress_module)
        if ok and type(live_percent) == "number" then
            percent = live_percent
        end
    end

    if percent == nil
        and reader
        and reader.view
        and reader.view.footer
        and type(reader.view.footer.percent_finished) == "number"
    then
        percent = reader.view.footer.percent_finished
    end

    if percent == nil and settings then
        percent = settings:readSetting("percent_finished") or 0
    end

    if type(percent) == "number" then
        percent = math.max(0, math.min(1, percent))
    end

    local summary = settings and settings:readSetting("summary") or {}
    return percent, summary and summary.status
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

local function readKeyValueFile(path, allowed_keys)
    local file = io.open(path, "r")
    if not file then
        return nil
    end

    local fields = {}
    for line in file:lines() do
        local key, value = line:match("^([a-z_]+)=(.*)$")
        if key and (not allowed_keys or allowed_keys[key]) then
            fields[key] = value
        end
    end
    file:close()
    return fields
end

local function readFirstLine(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local value = file:read("*l")
    file:close()
    return value
end

local function readWholeFile(path, maximum)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local content = file:read((maximum or 1024 * 1024) + 1)
    file:close()
    if not content or #content > (maximum or 1024 * 1024) then
        return nil
    end
    return content
end

local function sha256File(path)
    if type(path) ~= "string" or not path:match("^/[%w%._/%-]+$") then
        return nil
    end
    local pipe = io.popen(util.shell_escape({ SHA256_TOOL, path }) .. " 2>/dev/null", "r")
    if not pipe then
        return nil
    end
    local line = pipe:read("*l")
    pipe:close()
    local digest = line and line:match("^([0-9a-f]+)")
    return digest and #digest == 64 and digest or nil
end

local function formatReceiptTime(value)
    local timestamp = tonumber(value)
    if not timestamp or timestamp < 1 then
        return _("not recorded")
    end
    return os.date("%Y-%m-%d %H:%M", timestamp)
end

local function receiptEnum(value, allowed, fallback)
    if type(value) == "string" and allowed[value] then
        return value
    end
    return fallback
end

local function receiptCount(value)
    local count = tonumber(value)
    if not count or count < 0 or count > 100000 or count ~= math.floor(count) then
        return "0"
    end
    return tostring(count)
end

local function safeDebugValue(value)
    local rendered = tostring(value)
        :gsub("[\r\n\t=]", "_")
        :gsub("[^%w%._:%-/]", "_")
    if #rendered > 96 then
        rendered = rendered:sub(1, 96)
    end
    return rendered
end

local function annotationStats(reader)
    local annotations = reader
        and reader.annotation
        and reader.annotation.annotations
        or {}
    local stats = {
        total = #annotations,
        highlights = 0,
        notes = 0,
        bookmarks = 0,
    }

    for _, item in ipairs(annotations) do
        if item.drawer then
            stats.highlights = stats.highlights + 1
            if item.note and item.note ~= "" then
                stats.notes = stats.notes + 1
            end
        else
            stats.bookmarks = stats.bookmarks + 1
        end
    end

    return stats
end

local function hexEncode(value)
    return (tostring(value or ""):gsub(".", function(character)
        return string.format("%02x", string.byte(character))
    end))
end

local function isReadable(path)
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

local function openPrivateFile(path)
    local status = os.execute("umask 077; : > " .. util.shell_escape({ path }))
    if status ~= 0 then
        return nil
    end
    return io.open(path, "w")
end

local function readAnnotationOutbox(asin)
    if not isAsin(asin) then
        return nil, "invalid ASIN"
    end
    local content = readWholeFile(ANNOTATION_OUTBOX_DIR .. "/" .. asin, 1024 * 1024)
    if not content then
        return nil, "outbox missing"
    end
    local body, checksum, split_error = AnnotationOutbox.split(content)
    if not body then
        return nil, split_error
    end
    local verify_path = string.format("/tmp/goodreads-outbox-verify-%d%d", os.time(), math.random(1000, 9999))
    local verify = openPrivateFile(verify_path)
    if not verify then
        return nil, "cannot create checksum input"
    end
    verify:write(body)
    verify:close()
    local actual = sha256File(verify_path)
    os.remove(verify_path)
    if actual ~= checksum then
        return nil, "outbox checksum mismatch"
    end
    local snapshot, parse_error = AnnotationOutbox.parse(body, asin)
    if not snapshot then
        return nil, parse_error
    end
    snapshot.outbox_checksum = checksum
    return snapshot
end

local function persistAnnotationOutbox(snapshot, fault_stage)
    local mkdir_status = os.execute(
        "umask 077; mkdir -p " .. util.shell_escape({ ANNOTATION_OUTBOX_DIR })
            .. " " .. util.shell_escape({ ANNOTATION_SEQUENCE_DIR })
            .. "; chmod 700 " .. util.shell_escape({ PRIVATE_STATE_DIR })
            .. " " .. util.shell_escape({ ANNOTATION_OUTBOX_DIR })
            .. " " .. util.shell_escape({ ANNOTATION_SEQUENCE_DIR })
    )
    if mkdir_status ~= 0 then
        return false, "cannot create private outbox"
    end
    local sequence = tonumber(readFirstLine(ANNOTATION_SEQUENCE_DIR .. "/" .. snapshot.asin)) or 0
    local existing = readAnnotationOutbox(snapshot.asin)
    if existing and existing.sequence > sequence then
        sequence = existing.sequence
    end
    sequence = sequence + 1
    local body, encode_error = AnnotationOutbox.encode(snapshot, sequence, os.time())
    if not body then
        return false, encode_error
    end
    local temp_path = string.format("%s/%s.%d", ANNOTATION_OUTBOX_DIR, snapshot.asin, math.random(100000, 999999))
    local temp = openPrivateFile(temp_path)
    if not temp then
        return false, "cannot create outbox temporary file"
    end
    temp:write(body)
    temp:close()
    if fault_stage == "after_body_write" then
        return false, "injected interruption after body write"
    end
    local checksum = sha256File(temp_path)
    local packed = checksum and AnnotationOutbox.pack(body, checksum) or nil
    if not packed then
        os.remove(temp_path)
        return false, "cannot checksum annotation outbox"
    end
    if fault_stage == "after_checksum" then
        return false, "injected interruption after checksum"
    end
    temp = io.open(temp_path, "wb")
    if not temp then
        os.remove(temp_path)
        return false, "cannot finalize annotation outbox"
    end
    temp:write(packed)
    temp:close()
    if fault_stage == "after_envelope_write" then
        return false, "injected interruption after envelope write"
    end
    os.execute("chmod 600 " .. util.shell_escape({ temp_path }))
    local final_path = ANNOTATION_OUTBOX_DIR .. "/" .. snapshot.asin
    if not os.rename(temp_path, final_path) then
        os.remove(temp_path)
        return false, "cannot commit annotation outbox"
    end
    if fault_stage == "after_outbox_commit" then
        return false, "injected interruption after outbox commit"
    end
    local sequence_temp = string.format("%s/%s.%d", ANNOTATION_SEQUENCE_DIR, snapshot.asin, math.random(100000, 999999))
    local sequence_file = openPrivateFile(sequence_temp)
    if not sequence_file then
        return false, "cannot persist annotation sequence"
    end
    sequence_file:write(tostring(sequence), "\n")
    sequence_file:close()
    if fault_stage == "after_sequence_write" then
        return false, "injected interruption after sequence write"
    end
    os.execute("chmod 600 " .. util.shell_escape({ sequence_temp }))
    if not os.rename(sequence_temp, ANNOTATION_SEQUENCE_DIR .. "/" .. snapshot.asin) then
        os.remove(sequence_temp)
        return false, "cannot commit annotation sequence"
    end
    if fault_stage == "after_sequence_commit" then
        return false, "injected interruption after sequence commit"
    end
    snapshot.sequence = sequence
    snapshot.token = sequence
    snapshot.outbox_checksum = checksum
    return true
end

function Goodreads:persistAnnotationOutbox(snapshot)
    return persistAnnotationOutbox(snapshot, self.annotation_outbox_fault_stage)
end

local function isSupportedNativeBookPath(path)
    if type(path) ~= "string"
        or not path:match("^/mnt/us/documents/.+")
        or path:find("[\r\n%z]")
    then
        return false
    end
    local extension = path:lower():match("%.([%w]+)$")
    return extension == "kfx"
        or extension == "azw"
        or extension == "azw3"
        or extension == "mobi"
        or extension == "prc"
end

local function resolveNativeBookPathFromCatalog(asin)
    if not isAsin(asin) then return nil, "invalid" end

    -- kindle.koplugin's in-memory source_path can outlive a catalog move or
    -- replacement. Resolve only complete, visible, local ebook rows and return
    -- a path only when exactly one distinct readable candidate exists. hex()
    -- keeps arbitrary catalog path bytes out of sqlite's line protocol.
    local query = string.format([[
SELECT DISTINCT lower(hex(p_location))
FROM Entries
WHERE p_cdeKey='%s'
  AND p_cdeType IN ('EBOK','PDOC')
  AND COALESCE(p_isArchived,0)=0
  AND COALESCE(p_isDownloading,0)=0
  AND COALESCE(p_isVisibleInHome,1)=1
  AND COALESCE(p_contentState,1)=1
  AND p_location LIKE '/mnt/us/documents/%%'
  AND (lower(p_location) GLOB '*.kfx'
    OR lower(p_location) GLOB '*.azw'
    OR lower(p_location) GLOB '*.azw3'
    OR lower(p_location) GLOB '*.mobi'
    OR lower(p_location) GLOB '*.prc')
LIMIT 3;]], asin)
    local command = string.format(
        "%s -readonly %s \"%s\" 2>/dev/null",
        SQLITE_TOOL,
        CONTENT_CATALOG,
        query
    )
    local pipe = io.popen(command, "r")
    if not pipe then return nil, "unavailable" end
    local candidates = {}
    for encoded in pipe:lines() do
        local path = hexDecode(encoded, 4096)
        if path and isSupportedNativeBookPath(path) and isReadable(path) then
            table.insert(candidates, path)
        end
    end
    pipe:close()
    if #candidates == 1 then return candidates[1], "unique" end
    if #candidates > 1 then return nil, "ambiguous" end
    return nil, "not_found"
end

local function getAnnotationBookPaths(reader, asin)
    local document = reader and reader.document
    local epub_path = document and document.file
    local book = getKindleLibraryBook(reader)
    local mapped_path = book and book.source_path
    local native_path, catalog_status = resolveNativeBookPathFromCatalog(asin)
    if not native_path
        and catalog_status ~= "ambiguous"
        and isSupportedNativeBookPath(mapped_path)
        and isReadable(mapped_path)
    then
        native_path = mapped_path
    end
    if type(epub_path) ~= "string"
        or not epub_path:match("^/mnt/us/koreader/cache/.+%.epub$")
        or not isSupportedNativeBookPath(native_path)
    then
        return nil, nil
    end
    return epub_path, native_path
end

local function refreshResumedAnnotationSnapshot(snapshot)
    if type(snapshot) ~= "table" or not isAsin(snapshot.asin) then
        return false, "invalid resumed snapshot"
    end
    local catalog_path, catalog_status =
        resolveNativeBookPathFromCatalog(snapshot.asin)
    if catalog_path then
        if catalog_path == snapshot.native_path then return true end
        snapshot.native_path = catalog_path
        local persisted, detail = persistAnnotationOutbox(snapshot)
        if not persisted then
            return false, detail or "cannot persist repaired outbox"
        end
        return true, "catalog_path_repaired"
    end
    if catalog_status ~= "ambiguous"
        and isSupportedNativeBookPath(snapshot.native_path)
        and isReadable(snapshot.native_path)
    then
        return true
    end
    if catalog_status == "ambiguous" then
        return false, "ambiguous native catalog paths"
    end
    return false, "stored native path is stale"
end

local function readAnnotationState(asin)
    local keys = {}
    local file = io.open(ANNOTATION_STATE_DIR .. "/" .. asin, "r")
    if not file then
        return keys
    end
    for line in file:lines() do
        if line:match("^A[%w%+/]+:A[%w%+/]+:[01]$") then
            table.insert(keys, line)
        end
    end
    file:close()
    return keys
end


function Goodreads:collectDesiredAnnotations(annotations)
    local desired = {}
    local by_range = {}
    local duplicates_collapsed = 0
    for _, item in ipairs(annotations or {}) do
        if item.drawer and type(item.pos0) == "string" and type(item.pos1) == "string" then
            local note = type(item.note) == "string" and item.note or ""
            if #note > 65536 then
                return nil, nil, nil, "one annotation note exceeds the safe sync limit"
            end
            local first = item.pos0 < item.pos1 and item.pos0 or item.pos1
            local second = item.pos0 < item.pos1 and item.pos1 or item.pos0
            local range_key = first .. "\0" .. second
            local existing = by_range[range_key]
            if existing then
                duplicates_collapsed = duplicates_collapsed + 1
                if existing.note == "" and note ~= "" then
                    existing.note = note
                end
            else
                local normalized = {
                    start = item.pos0,
                    finish = item.pos1,
                    note = note,
                }
                by_range[range_key] = normalized
                table.insert(desired, normalized)
            end
        end
    end

    local note_bytes = 0
    for _, item in ipairs(desired) do
        note_bytes = note_bytes + #item.note
    end
    return desired, note_bytes, duplicates_collapsed
end

function Goodreads:captureAnnotationSnapshot(reader, trigger)
    if not self.settings.annotation_sync_enabled then
        return nil, "annotation sync disabled"
    end
    local asin = getBookAsin(reader)
    local epub_path, native_path = getAnnotationBookPaths(reader, asin)
    if not asin or not epub_path or not native_path then
        self:debugLog("annotations_sync_skipped", {
            trigger = trigger,
            asin = asin,
            status = "book_paths_unavailable",
        })
        return nil, "Kindle source paths unavailable"
    end
    if self.settings.native_annotation_import_enabled
        and (self.native_import_inflight
            or isReadable(NATIVE_IMPORT_DIR .. "/" .. asin))
    then
        self:debugLog("annotations_sync_skipped", {
            trigger = trigger,
            asin = asin,
            status = "native_import_must_resolve_first",
        })
        return nil, "native import must resolve before outbound snapshot"
    end

    local annotations = reader.annotation and reader.annotation.annotations or {}
    local desired, note_bytes, duplicates_collapsed, collect_error =
        self:collectDesiredAnnotations(annotations)
    if not desired then
        return nil, collect_error
    end
    if #desired > 1000 or note_bytes > 200 * 1024 then
        return nil, "annotation payload exceeds the safe sync limit"
    end
    if duplicates_collapsed > 0 then
        self:debugLog("annotations_deduplicated", {
            trigger = trigger,
            asin = asin,
            annotations = #desired,
            duplicates_collapsed = duplicates_collapsed,
            status = "exact_ranges_collapsed",
        })
    end

    local token = (self.annotation_snapshot_tokens[asin] or 0) + 1
    self.annotation_snapshot_tokens[asin] = token
    local snapshot = {
        asin = asin,
        epub_path = epub_path,
        native_path = native_path,
        desired = desired,
        trigger = trigger,
        token = token,
        attempt = 0,
    }
    local persisted, persist_error = self:persistAnnotationOutbox(snapshot)
    if not persisted then
        self:debugLog("annotations_sync_skipped", {
            trigger = trigger,
            asin = asin,
            annotations = #desired,
            status = "outbox_persist_failed",
        })
        return nil, persist_error
    end
    self.annotation_snapshot_tokens[asin] = snapshot.sequence
    return snapshot
end

function Goodreads:enqueuePendingAnnotationSnapshot(snapshot)
    local asin = snapshot.asin
    local existing = self.annotation_pending_snapshots[asin]
    if existing and (existing.token or 0) > (snapshot.token or 0) then
        return
    end
    if not existing then
        table.insert(self.annotation_pending_order, asin)
    end
    self.annotation_pending_snapshots[asin] = snapshot
    self:debugLog("annotations_sync_coalesced", {
        trigger = snapshot.trigger,
        asin = asin,
        annotations = #snapshot.desired,
        attempt = snapshot.attempt,
        status = "latest_snapshot_queued",
    })
end

function Goodreads:dequeuePendingAnnotationSnapshot()
    while #self.annotation_pending_order > 0 do
        local asin = table.remove(self.annotation_pending_order, 1)
        local snapshot = self.annotation_pending_snapshots[asin]
        self.annotation_pending_snapshots[asin] = nil
        if snapshot and snapshot.token == self.annotation_snapshot_tokens[asin] then
            return snapshot
        end
    end
    return nil
end


function Goodreads:queueAnnotationReconcile(reader, trigger)
    local snapshot, detail = self:captureAnnotationSnapshot(reader, trigger)
    if not snapshot then
        return false, detail
    end
    return self:queueAnnotationSnapshot(snapshot)
end

function Goodreads:queueAnnotationSnapshot(snapshot)
    if not self.settings.annotation_sync_enabled then
        return false, "annotation sync disabled"
    end
    if self.settings.native_annotation_import_enabled
        and isAsin(snapshot.asin)
        and isReadable(NATIVE_IMPORT_DIR .. "/" .. snapshot.asin)
    then
        self:debugLog("annotations_sync_skipped", {
            trigger = snapshot.trigger,
            asin = snapshot.asin,
            annotations = type(snapshot.desired) == "table" and #snapshot.desired or 0,
            status = "native_import_must_resolve_first",
        })
        return false, "native import must resolve before queued outbound snapshot"
    end
    if self.annotation_sync_inflight then
        self:enqueuePendingAnnotationSnapshot(snapshot)
        return true, "coalesced"
    end
    return self:startAnnotationReconcile(snapshot)
end

local function validateTranslatedPositions(result, desired_count)
    if not result or not result.ok or type(result.positions) ~= "table"
        or #result.positions ~= desired_count
    then
        return nil, "position translation failed"
    end
    for _, position in ipairs(result.positions) do
        local start_long = position and position.start and position.start.long
        local start_short = position and position.start and position.start.pid
        local end_long = position and position["end"] and position["end"].long
        local end_short = position and position["end"] and position["end"].pid
        if type(start_long) ~= "string" or #start_long ~= 12
            or not start_long:match("^A[%w%+/]+$")
            or type(start_short) ~= "number" or start_short < 0
            or start_short > 2147483647 or start_short ~= math.floor(start_short)
            or type(end_long) ~= "string" or #end_long ~= 12
            or not end_long:match("^A[%w%+/]+$")
            or type(end_short) ~= "number" or end_short < 0
            or end_short > 2147483647 or end_short ~= math.floor(end_short)
        then
            return nil, "position translation returned invalid coordinates"
        end
    end
    return result.positions
end

function Goodreads:cleanupAnnotationTranslation(snapshot)
    for _, key in ipairs({
        "translation_request_path",
        "translation_result_path",
        "translation_temporary_path",
        "translation_failure_path",
    }) do
        local path = snapshot[key]
        if path then
            os.remove(path)
            snapshot[key] = nil
        end
    end
end

function Goodreads:startTranslatedAnnotationReconcile(snapshot, translated)
    local asin = snapshot.asin
    local native_path = snapshot.native_path
    local desired = snapshot.desired
    local trigger = snapshot.trigger

    local request_id = string.format("%d%d", os.time(), math.random(1000, 9999))
    local payload_path = "/tmp/goodreads-annotations-" .. request_id .. ".properties"
    local payload = openPrivateFile(payload_path)
    if not payload then
        self:finishAnnotationReconcile(snapshot, false, true)
        return false, "cannot create annotation payload"
    end
    payload:write("version=1\n")
    payload:write("asin=", asin, "\n")
    payload:write("request_id=", request_id, "\n")
    payload:write("outbox_sequence=", tostring(snapshot.sequence or 0), "\n")
    payload:write("outbox_checksum=", tostring(snapshot.outbox_checksum or "legacy"), "\n")
    payload:write("retry_count=", tostring(snapshot.attempt or 0), "\n")
    payload:write("trigger=", tostring(trigger or "unknown"), "\n")
    payload:write("native_path_hex=", hexEncode(native_path), "\n")
    payload:write("desired_count=", tostring(#desired), "\n")
    for index, item in ipairs(desired) do
        local position = translated[index]
        local base = "desired." .. tostring(index - 1) .. "."
        payload:write(base, "start=", position.start.long, "\n")
        payload:write(base, "start_short=", tostring(position.start.pid), "\n")
        payload:write(base, "end=", position["end"].long, "\n")
        payload:write(base, "end_short=", tostring(position["end"].pid), "\n")
        payload:write(base, "note_hex=", hexEncode(item.note), "\n")
    end
    local previous = readAnnotationState(asin)
    payload:write("previous_count=", tostring(#previous), "\n")
    for index, key in ipairs(previous) do
        payload:write("previous.", tostring(index - 1), "=", key, "\n")
    end
    payload:close()
    os.execute("chmod 600 " .. util.shell_escape({ payload_path }))
    local helper_status = os.execute(
        "(" .. util.shell_escape({ ANNOTATION_HELPER, payload_path })
            .. ") >/dev/null 2>&1 &"
    )
    if helper_status ~= 0 then
        os.remove(payload_path)
        self:finishAnnotationReconcile(snapshot, false, true)
        return false, "cannot start annotation helper"
    end
    self:debugLog("annotations_sync_queued", {
        trigger = trigger,
        asin = asin,
        annotations = #desired,
        highlights = #desired,
        attempt = snapshot.attempt,
        status = "queued",
    })
    snapshot.request_id = request_id
    self.annotation_sync_inflight = snapshot
    self.annotation_request_ids[asin] = request_id
    self:pollAnnotationResult(snapshot)
    return true
end

function Goodreads:pollAnnotationTranslation(snapshot)
    local asin = snapshot.asin
    local translation_id = snapshot.request_id
    local attempts = 0
    local function fail(status, detail, retryable)
        self:cleanupAnnotationTranslation(snapshot)
        self:debugLog("annotations_sync_skipped", {
            trigger = snapshot.trigger,
            asin = asin,
            annotations = #snapshot.desired,
            status = status,
        })
        self:finishAnnotationReconcile(snapshot, false, retryable)
        return false, detail
    end
    local function poll()
        if self.annotation_sync_inflight ~= snapshot
            or self.annotation_request_ids[asin] ~= translation_id
        then
            self:cleanupAnnotationTranslation(snapshot)
            return
        end
        attempts = attempts + 1
        if isReadable(snapshot.translation_failure_path) then
            fail("position_translation_failed", "position translation failed", true)
            return
        end
        local output = readWholeFile(snapshot.translation_result_path, 1024 * 1024)
        if output then
            self:cleanupAnnotationTranslation(snapshot)
            local ok_json, result = pcall(json.decode, output)
            local translated, detail
            if ok_json then
                translated, detail = validateTranslatedPositions(result, #snapshot.desired)
            end
            if not translated then
                fail(
                    detail == "position translation returned invalid coordinates"
                        and "position_translation_invalid"
                        or "position_translation_failed",
                    detail or "position translation failed",
                    false
                )
                return
            end
            self:startTranslatedAnnotationReconcile(snapshot, translated)
            return
        end
        if attempts < 120 then
            UIManager:scheduleIn(1, poll)
        else
            fail("position_translation_timeout", "position translation timed out", true)
        end
    end
    UIManager:scheduleIn(1, poll)
end

function Goodreads:startAnnotationReconcile(snapshot)
    local asin = snapshot.asin
    local desired = snapshot.desired
    local trigger = snapshot.trigger
    self.annotation_sync_inflight = snapshot

    if #desired == 0 then
        return self:startTranslatedAnnotationReconcile(snapshot, {})
    end

    local kindle_helper
    for _, candidate in ipairs(KINDLE_HELPER_PATHS) do
        if isReadable(candidate) then
            kindle_helper = candidate
            break
        end
    end
    if not kindle_helper then
        self:debugLog("annotations_sync_skipped", {
            trigger = trigger,
            asin = asin,
            status = "position_helper_unavailable",
        })
        self:finishAnnotationReconcile(snapshot, false, false)
        return false, "position helper unavailable"
    end

    local translation_id = string.format("%d%d", os.time(), math.random(1000, 9999))
    local base_path = "/tmp/goodreads-position-result-" .. translation_id
    snapshot.translation_request_path = base_path .. ".request.json"
    snapshot.translation_result_path = base_path .. ".json"
    snapshot.translation_temporary_path = base_path .. ".tmp"
    snapshot.translation_failure_path = base_path .. ".failed"
    local request_items = {}
    for _, item in ipairs(desired) do
        table.insert(request_items, { start = item.start, ["end"] = item.finish })
    end
    local request_file = openPrivateFile(snapshot.translation_request_path)
    if not request_file then
        self:cleanupAnnotationTranslation(snapshot)
        self:finishAnnotationReconcile(snapshot, false, true)
        return false, "cannot create position request"
    end
    request_file:write(json.encode(request_items))
    request_file:close()
    os.execute("chmod 600 " .. util.shell_escape({ snapshot.translation_request_path }))

    snapshot.request_id = "translation-" .. translation_id
    self.annotation_request_ids[asin] = snapshot.request_id
    local helper_command = util.shell_escape({
        kindle_helper,
        "translate-positions",
        "--epub",
        snapshot.epub_path,
        "--request",
        snapshot.translation_request_path,
    })
    local command = string.format(
        "(umask 077; if %s > %s 2>/dev/null; then mv -f %s %s; "
            .. "else rm -f %s; : > %s; fi; rm -f %s) >/dev/null 2>&1 &",
        helper_command,
        util.shell_escape({ snapshot.translation_temporary_path }),
        util.shell_escape({ snapshot.translation_temporary_path }),
        util.shell_escape({ snapshot.translation_result_path }),
        util.shell_escape({ snapshot.translation_temporary_path }),
        util.shell_escape({ snapshot.translation_failure_path }),
        util.shell_escape({ snapshot.translation_request_path })
    )
    local status = os.execute(command)
    if status ~= 0 then
        self:cleanupAnnotationTranslation(snapshot)
        self:finishAnnotationReconcile(snapshot, false, true)
        return false, "cannot start position translation"
    end
    self:debugLog("annotations_translation_queued", {
        trigger = trigger,
        asin = asin,
        annotations = #desired,
        attempt = snapshot.attempt,
        status = "queued",
    })
    self:pollAnnotationTranslation(snapshot)
    return true
end

function Goodreads:resumeAnnotationOutbox()
    if not self.settings.annotation_sync_enabled then
        return
    end
    local pipe = io.popen(
        "find " .. util.shell_escape({ ANNOTATION_OUTBOX_DIR })
            .. " -maxdepth 1 -type f -name 'B?????????' 2>/dev/null",
        "r"
    )
    if not pipe then
        return
    end
    local snapshots = {}
    for path in pipe:lines() do
        local asin = path:match("/([^/]+)$")
        if isAsin(asin) and path == ANNOTATION_OUTBOX_DIR .. "/" .. asin then
            local snapshot, detail = readAnnotationOutbox(asin)
            if snapshot then
                local refreshed, refresh_detail =
                    refreshResumedAnnotationSnapshot(snapshot)
                if refreshed then
                    table.insert(snapshots, snapshot)
                else
                    self:debugLog("annotations_outbox_resume_failed", {
                        asin = asin,
                        status = safeDebugValue(
                            refresh_detail or "native_path_unavailable"),
                    })
                end
            else
                self:debugLog("annotations_outbox_resume_failed", {
                    asin = asin,
                    status = safeDebugValue(detail or "invalid_outbox"),
                })
            end
        end
    end
    pipe:close()
    table.sort(snapshots, function(left, right)
        return left.sequence < right.sequence
    end)
    for _, snapshot in ipairs(snapshots) do
        self.annotation_snapshot_tokens[snapshot.asin] = snapshot.sequence
        self:queueAnnotationSnapshot(snapshot)
    end
end

function Goodreads:drainPendingAnnotationSnapshots()
    if self.annotation_sync_inflight then
        return
    end
    local snapshot = self:dequeuePendingAnnotationSnapshot()
    if not snapshot then
        return
    end
    UIManager:scheduleIn(0, function()
        if self.annotation_sync_inflight then
            self:enqueuePendingAnnotationSnapshot(snapshot)
            return
        end
        local queued = self:queueAnnotationSnapshot(snapshot)
        if not queued then
            self:drainPendingAnnotationSnapshots()
        end
    end)
end

function Goodreads:finishAnnotationReconcile(snapshot, success, retryable)
    if self.annotation_sync_inflight ~= snapshot then
        return
    end
    self.annotation_sync_inflight = nil
    if self.annotation_request_ids[snapshot.asin] == snapshot.request_id then
        self.annotation_request_ids[snapshot.asin] = nil
    end

    if success then
        self.annotation_retry_counts[snapshot.asin] = 0
    elseif retryable and snapshot.attempt < 3 then
        local token = snapshot.token
        self.annotation_retry_counts[snapshot.asin] = snapshot.attempt + 1
        self:debugLog("annotations_sync_retry", {
            trigger = snapshot.trigger,
            asin = snapshot.asin,
            annotations = #snapshot.desired,
            attempt = snapshot.attempt + 1,
            status = "scheduled_in_15_seconds",
        })
        UIManager:scheduleIn(15, function()
            if self.settings.annotation_sync_enabled
                and self.annotation_snapshot_tokens[snapshot.asin] == token
            then
                snapshot.attempt = snapshot.attempt + 1
                snapshot.request_id = nil
                self:queueAnnotationSnapshot(snapshot)
            end
        end)
    end
    self:drainPendingAnnotationSnapshots()
end

function Goodreads:pollAnnotationResult(snapshot)
    local asin = snapshot.asin
    local request_id = snapshot.request_id
    local trigger = snapshot.trigger
    local attempts = 0
    local function poll()
        if self.annotation_sync_inflight ~= snapshot
            or self.annotation_request_ids[asin] ~= request_id
        then
            return
        end
        attempts = attempts + 1
        local result = readKeyValueFile(ANNOTATION_RESULT_FILE, ANNOTATION_RESULT_KEYS)
        if result and result.asin == asin and result.request_id == request_id then
            local success = result.success == "true"
                and result.local_verified == "true"
                and result.native_notified == "true"
                and (result.ksdk_synced == "true" or result.ksdk_synced == "unavailable")
                and (result.legacy_journaled == "true"
                    or result.legacy_journaled == "unavailable")
                and result.native_cloud_queued == "true"
                and (result.cloud_snapshot_synced == "true"
                    or result.cloud_snapshot_synced == "unavailable")
                and result.sync_enqueued == "true"
                and result.outbox_sequence == tostring(snapshot.sequence)
                and result.outbox_acknowledged == "true"
            self:debugLog("annotations_sync_result", {
                trigger = trigger,
                asin = asin,
                annotations = result.requested,
                status = success and "accepted" or "failed",
                success = success,
                local_success = result.local_success,
                local_verified = result.local_verified,
                native_notified = result.native_notified,
                ksdk_synced = result.ksdk_synced,
                legacy_journaled = result.legacy_journaled,
                native_cloud_queued = result.native_cloud_queued,
                cloud_synced = result.cloud_synced,
                cloud_snapshot_synced = result.cloud_snapshot_synced,
                failed_stage = result.failed_stage,
                error_class = result.error_class,
                highlights_created = result.highlights_created,
                highlights_deleted = result.highlights_deleted,
                notes_created = result.notes_created,
                notes_updated = result.notes_updated,
                notes_deleted = result.notes_deleted,
                native_notifications = result.native_notifications,
                zero_endpoint_repairs = result.zero_endpoint_repairs,
                terminal_endpoint_repairs = result.terminal_endpoint_repairs,
                cloud_edits = result.cloud_edits,
                cloud_snapshots = result.cloud_snapshots,
                ksdk_writes = result.ksdk_writes,
                native_journal_edits = result.native_journal_edits,
                native_upload_requests = result.native_upload_requests,
                legacy_cloud_deletes = result.legacy_cloud_deletes,
                book_source = result.book_source,
                sync_enqueued = result.sync_enqueued,
                outbox_sequence = result.outbox_sequence,
                outbox_acknowledged = result.outbox_acknowledged,
            })
            self.last_annotation_sync_result = result
            self:finishAnnotationReconcile(
                snapshot,
                success,
                not success and result.failed_stage ~= "validate_payload"
                    and result.failed_stage ~= "outbox_superseded"
            )
            return
        end
        if attempts < 120 then
            UIManager:scheduleIn(1, poll)
        else
            self:debugLog("annotations_sync_result", {
                trigger = trigger,
                asin = asin,
                status = "no_result_within_120_seconds",
                success = false,
            })
            self:finishAnnotationReconcile(snapshot, false, true)
        end
    end
    UIManager:scheduleIn(1, poll)
end

local function readNativeImportSnapshot(asin)
    local path = NATIVE_IMPORT_DIR .. "/" .. asin
    local content = readWholeFile(path, 512 * 1024)
    if not content then return nil, "native import snapshot unavailable" end
    local fields = {}
    for line in content:gmatch("[^\r\n]+") do
        local key, value = line:match("^([%w_%.]+)=(.*)$")
        if not key or fields[key] ~= nil then return nil, "invalid native import snapshot" end
        fields[key] = value
    end
    local count = tonumber(fields.count)
    local native_path = hexDecode(fields.native_path_hex, 4096)
    if fields.version ~= "1" or fields.success ~= "true"
        or fields.snapshot_complete ~= "true" or fields.asin ~= asin
        or not count or count < 0 or count > 1000 or count ~= math.floor(count)
        or not native_path or not native_path:match("^/mnt/us/documents/")
        or type(fields.request_id) ~= "string" or not fields.request_id:match("^%d+$")
    then
        return nil, "invalid native import metadata"
    end
    local allowed = {
        version = true, success = true, snapshot_complete = true,
        asin = true, request_id = true,
        native_path_hex = true, count = true,
    }
    local items, note_bytes = {}, 0
    for index = 0, count - 1 do
        local base = "item." .. index .. "."
        local start_long, end_long = fields[base .. "start"], fields[base .. "end"]
        local start_short, end_short = tonumber(fields[base .. "start_short"]),
            tonumber(fields[base .. "end_short"])
        local note = hexDecode(fields[base .. "note_hex"], 65536)
        allowed[base .. "start"], allowed[base .. "start_short"] = true, true
        allowed[base .. "end"], allowed[base .. "end_short"] = true, true
        allowed[base .. "note_hex"] = true
        if type(start_long) ~= "string" or not start_long:match("^A[%w%+/]+$")
            or #start_long ~= 12 or type(end_long) ~= "string"
            or not end_long:match("^A[%w%+/]+$") or #end_long ~= 12
            or not start_short or start_short < 0 or start_short > 2147483647
            or start_short ~= math.floor(start_short)
            or not end_short or end_short < 0 or end_short > 2147483647
            or end_short ~= math.floor(end_short)
            or not note
        then
            return nil, "invalid native import range"
        end
        note_bytes = note_bytes + #note
        if note_bytes > 200 * 1024 then return nil, "native import notes exceed limit" end
        table.insert(items, { start_long = start_long, end_long = end_long, note = note })
    end
    for key in pairs(fields) do
        if not allowed[key] then return nil, "unexpected native import field" end
    end
    return {
        path = path,
        asin = asin,
        native_path = native_path,
        snapshot_complete = true,
        items = items,
    }
end

function Goodreads:startNativeAnnotationWatcher()
    if not isReadable(NATIVE_IMPORT_WATCHER) then return false end
    os.execute("mkdir -p " .. util.shell_escape({ PRIVATE_STATE_DIR })
        .. " && chmod 700 " .. util.shell_escape({ PRIVATE_STATE_DIR })
        .. " && umask 077 && : > " .. util.shell_escape({ NATIVE_IMPORT_ENABLED_FILE }))
    os.execute("(" .. util.shell_escape({ NATIVE_IMPORT_WATCHER }) .. ") >/dev/null 2>&1 &")
    return true
end

local function nativeAnnotationKey(item)
    if type(item) ~= "table" or type(item.start_long) ~= "string"
        or type(item.end_long) ~= "string"
    then
        return nil
    end
    return item.start_long .. ":" .. item.end_long
end

local function xpointerRangeKey(pos0, pos1)
    if type(pos0) ~= "string" or type(pos1) ~= "string" then return nil end
    local first = pos0 < pos1 and pos0 or pos1
    local second = pos0 < pos1 and pos1 or pos0
    return first .. "\0" .. second
end

local function validNativeKey(key)
    if type(key) ~= "string" then return false end
    local start_long, end_long = key:match("^(A[%w%+/]+):(A[%w%+/]+)$")
    return start_long ~= nil and #start_long == 12 and #end_long == 12
end

local function validNativeProvenance(item)
    local provenance = type(item) == "table" and item.goodreads_native_provenance
    if type(provenance) ~= "table" or provenance.version ~= 1
        or type(provenance.key) ~= "string"
        or type(provenance.highlight_created) ~= "boolean"
        or type(provenance.note_imported) ~= "boolean"
        or type(provenance.note_value) ~= "string" or #provenance.note_value > 65536
        or type(provenance.drawer) ~= "string" or #provenance.drawer > 64
        or (provenance.color ~= nil
            and (type(provenance.color) ~= "string" or #provenance.color > 64))
    then
        return nil
    end
    if not validNativeKey(provenance.key) then return nil end
    return provenance
end

local function setNativeProvenance(item, key, highlight_created, note_imported, note_value)
    item.goodreads_native_import = true -- retained for v0.7 sidecar compatibility
    item.goodreads_native_provenance = {
        version = 1,
        key = key,
        highlight_created = highlight_created == true,
        note_imported = note_imported == true,
        -- This private value remains inside KOReader's own annotation metadata.
        -- It is never copied to receipts, diagnostics, or logs.
        note_value = note_value or "",
        drawer = type(item.drawer) == "string" and item.drawer or "",
        color = type(item.color) == "string" and item.color or nil,
    }
    return item.goodreads_native_provenance
end

local function clearNativeProvenance(item)
    item.goodreads_native_import = nil
    item.goodreads_native_provenance = nil
end

local function nativeStyleUnchanged(item, provenance)
    return (item.drawer or "") == provenance.drawer
        and (item.color or "") == (provenance.color or "")
end

function Goodreads:rememberNativeAnnotationDeletion(items)
    local asin = getBookAsin(self.ui)
    if type(items) ~= "table" or type(items.index_modified) ~= "number"
        or items.index_modified >= 0 or not isAsin(asin)
    then
        return false
    end
    local provenance = validNativeProvenance(items[1])
    if not provenance then return false end
    local tombstones = self.settings.native_annotation_tombstones
    if type(tombstones) ~= "table" then
        tombstones = {}
        self.settings.native_annotation_tombstones = tombstones
    end
    local book = tombstones[asin]
    if type(book) ~= "table" then
        book = {}
        tombstones[asin] = book
    end
    local count, oldest_key, oldest_time = 0, nil, math.huge
    for key, timestamp in pairs(book) do
        if validNativeKey(key) and type(timestamp) == "number" then
            count = count + 1
            if timestamp < oldest_time then oldest_key, oldest_time = key, timestamp end
        else
            book[key] = nil
        end
    end
    if book[provenance.key] == nil and count >= 1000 and oldest_key then
        book[oldest_key] = nil
    end
    book[provenance.key] = os.time()
    self:saveSettings()
    self:debugLog("native_annotation_tombstoned", {
        trigger = "local_delete",
        annotations = 1,
        status = "waiting_native_echo",
    })
    return true
end

function Goodreads:applyNativeAnnotationImport(reader, snapshot, positions)
    local allow_deletions = snapshot.snapshot_complete == true
    local annotations = reader.annotation and reader.annotation.annotations or {}
    local existing = {}
    for _, item in ipairs(annotations) do
        if item.drawer and type(item.pos0) == "string" and type(item.pos1) == "string" then
            existing[xpointerRangeKey(item.pos0, item.pos1)] = item
        end
    end

    local modified, modified_set = {}, {}
    local function markModified(item)
        if not modified_set[item] then
            modified_set[item] = true
            table.insert(modified, item)
        end
    end

    local native_keys, additions = {}, {}
    local tombstones = isAsin(snapshot.asin)
        and type(self.settings.native_annotation_tombstones) == "table"
        and self.settings.native_annotation_tombstones[snapshot.asin] or nil
    if type(tombstones) ~= "table" then tombstones = {} end
    local tombstones_to_clear = {}
    local tombstones_blocked = 0
    local highlight_delta, note_delta = 0, 0
    local added, deleted, notes_added, notes_updated, notes_deleted = 0, 0, 0, 0, 0
    local ownership_detached, legacy_detached = 0, 0

    for index, imported in ipairs(snapshot.items) do
        local translated = positions[index]
        local pos0, pos1 = translated.start.xpointer, translated["end"].xpointer
        local native_key = nativeAnnotationKey(imported)
        local position_key = xpointerRangeKey(pos0, pos1)
        if not native_key or not position_key then return false, "invalid native import identity" end
        native_keys[native_key] = true
        local current = existing[position_key]
        if tombstones[native_key] ~= nil and not current then
            -- Suppress a stale native echo until a complete snapshot omits the
            -- key and thereby confirms the outbound deletion.
            tombstones_blocked = tombstones_blocked + 1
        elseif current then
            if tombstones[native_key] ~= nil then
                -- The range exists locally again, so the user recreated or kept it.
                tombstones_to_clear[native_key] = true
            end
            local had_native_metadata = current.goodreads_native_import ~= nil
                or current.goodreads_native_provenance ~= nil
            local provenance = validNativeProvenance(current)
            if not provenance and had_native_metadata
            then
                -- v0.7 did not distinguish a created highlight from an
                -- existing highlight whose empty note was filled. Preserve it
                -- and detach that ambiguous legacy marker instead of guessing.
                clearNativeProvenance(current)
                markModified(current)
                legacy_detached = legacy_detached + 1
            elseif provenance then
                local changed = false
                if provenance.key ~= native_key then
                    provenance.key = native_key
                    changed = true
                end
                if provenance.highlight_created
                    and not nativeStyleUnchanged(current, provenance)
                then
                    provenance.highlight_created = false
                    changed = true
                end

                local current_note = current.note or ""
                if current_note ~= provenance.note_value then
                    -- A local note edit wins over a stale native snapshot. If
                    -- Kindle later echoes that exact edit, rebase the private
                    -- baseline so subsequent two-way changes remain safe.
                    if imported.note == current_note then
                        provenance.note_value = current_note
                        provenance.note_imported = current_note ~= ""
                        changed = true
                    end
                elseif imported.note ~= provenance.note_value
                    and (imported.note ~= "" or allow_deletions)
                then
                    local old_note = current_note
                    current.note = imported.note ~= "" and imported.note or nil
                    provenance.note_value = imported.note
                    provenance.note_imported = imported.note ~= ""
                    changed = true
                    if old_note == "" and imported.note ~= "" then
                        highlight_delta = highlight_delta - 1
                        note_delta = note_delta + 1
                        notes_added = notes_added + 1
                    elseif old_note ~= "" and imported.note == "" then
                        highlight_delta = highlight_delta + 1
                        note_delta = note_delta - 1
                        notes_deleted = notes_deleted + 1
                    else
                        notes_updated = notes_updated + 1
                    end
                end

                if provenance and not provenance.highlight_created
                    and not provenance.note_imported
                then
                    clearNativeProvenance(current)
                    provenance = nil
                    changed = true
                end
                if changed then markModified(current) end
            end

            if not had_native_metadata and not validNativeProvenance(current)
                and imported.note ~= "" and (current.note == nil or current.note == "")
            then
                current.note = imported.note
                setNativeProvenance(current, native_key, false, true, imported.note)
                markModified(current)
                highlight_delta = highlight_delta - 1
                note_delta = note_delta + 1
                notes_added = notes_added + 1
            end
        else
            table.insert(additions, {
                imported = imported,
                native_key = native_key,
                position_key = position_key,
                pos0 = pos0,
                pos1 = pos1,
            })
        end
    end

    for key in pairs(tombstones) do
        if allow_deletions and validNativeKey(key) and not native_keys[key] then
            tombstones_to_clear[key] = true
        end
    end

    -- Reconcile removals before adding new items so array indices cannot move
    -- underneath the descending deletion pass.
    for annotation_index = #annotations, 1, -1 do
        local item = annotations[annotation_index]
        local provenance = validNativeProvenance(item)
        if allow_deletions and provenance and not native_keys[provenance.key] then
            local current_note = item.note or ""
            local note_unchanged = current_note == provenance.note_value
            if provenance.highlight_created and note_unchanged
                and nativeStyleUnchanged(item, provenance)
            then
                table.remove(annotations, annotation_index)
                clearNativeProvenance(item)
                markModified(item)
                deleted = deleted + 1
                if current_note == "" then
                    highlight_delta = highlight_delta - 1
                else
                    note_delta = note_delta - 1
                    notes_deleted = notes_deleted + 1
                end
            else
                if provenance.note_imported and note_unchanged and current_note ~= "" then
                    item.note = nil
                    highlight_delta = highlight_delta + 1
                    note_delta = note_delta - 1
                    notes_deleted = notes_deleted + 1
                end
                clearNativeProvenance(item)
                markModified(item)
                ownership_detached = ownership_detached + 1
            end
        elseif not provenance and (item.goodreads_native_import ~= nil
            or item.goodreads_native_provenance ~= nil)
        then
            clearNativeProvenance(item)
            markModified(item)
            legacy_detached = legacy_detached + 1
        end
    end

    for _, pending in ipairs(additions) do
        local imported, pos0, pos1 = pending.imported, pending.pos0, pending.pos1
        local ok_text, text = pcall(reader.document.getTextFromXPointers,
            reader.document, pos0, pos1)
        local chapter
        if reader.toc and type(reader.toc.getTocTitleByPage) == "function" then
            local ok_chapter, value = pcall(reader.toc.getTocTitleByPage,
                reader.toc, pos0)
            if ok_chapter and value ~= "" then chapter = value end
        end
        local item = {
            page = pos0,
            pos0 = pos0,
            pos1 = pos1,
            text = ok_text and text or "",
            drawer = reader.view and reader.view.highlight
                and reader.view.highlight.saved_drawer or "lighten",
            note = imported.note ~= "" and imported.note or nil,
            chapter = chapter,
        }
        setNativeProvenance(item, pending.native_key, true,
            imported.note ~= "", imported.note)
        reader.annotation:addItem(item)
        existing[pending.position_key] = item
        markModified(item)
        added = added + 1
        if item.note then
            note_delta = note_delta + 1
            notes_added = notes_added + 1
        else
            highlight_delta = highlight_delta + 1
        end
    end

    if #modified == 0 and self.native_import_retry_path == snapshot.path
        and type(self.native_import_retry_event) == "table"
    then
        modified = self.native_import_retry_event
    end
    if #modified > 0 then
        if highlight_delta ~= 0 then modified.nb_highlights_added = highlight_delta end
        if note_delta ~= 0 then modified.nb_notes_added = note_delta end
        local previous_import_event = self.native_import_event_inflight
        self.native_import_event_inflight = true
        local ok_event = pcall(reader.handleEvent, reader,
            Event:new("AnnotationsModified", modified))
        self.native_import_event_inflight = previous_import_event
        if not ok_event then
            self.native_import_retry_path = snapshot.path
            self.native_import_retry_event = modified
            return false, "KOReader annotation event failed"
        end
    end
    self.native_import_retry_path = nil
    self.native_import_retry_event = nil
    local tombstones_cleared = 0
    for key in pairs(tombstones_to_clear) do
        if tombstones[key] ~= nil then
            tombstones[key] = nil
            tombstones_cleared = tombstones_cleared + 1
        end
    end
    if tombstones_cleared > 0 then
        local has_tombstones = false
        for _ in pairs(tombstones) do has_tombstones = true break end
        if not has_tombstones and isAsin(snapshot.asin)
            and type(self.settings.native_annotation_tombstones) == "table"
        then
            self.settings.native_annotation_tombstones[snapshot.asin] = nil
        end
        self:saveSettings()
    end
    os.remove(snapshot.path)
    self:debugLog("native_annotations_imported", {
        trigger = "native_import",
        annotations = added,
        highlights_created = added,
        highlights_deleted = deleted,
        notes = notes_added,
        notes_created = notes_added,
        notes_updated = notes_updated,
        notes_deleted = notes_deleted,
        ownership_detached = ownership_detached,
        legacy_detached = legacy_detached,
        tombstones_blocked = tombstones_blocked,
        tombstones_cleared = tombstones_cleared,
        status = #modified > 0 and "merged" or "already_current",
    })
    return true
end

function Goodreads:queueNativeAnnotationImport(reader, completion)
    if not self.settings.native_annotation_import_enabled then
        return false, "disabled", false
    end
    if self.native_import_inflight then
        return false, "inflight", true
    end
    local asin = getBookAsin(reader)
    local epub_path, native_path = getAnnotationBookPaths(reader, asin)
    if not asin or not epub_path or not native_path then
        return false, "book_paths_unavailable", false
    end
    local snapshot_path = NATIVE_IMPORT_DIR .. "/" .. asin
    if not isReadable(snapshot_path) then return false, "no_snapshot", false end
    local snapshot, snapshot_error = readNativeImportSnapshot(asin)
    if not snapshot then return false, snapshot_error or "invalid_snapshot", true end
    if snapshot.native_path ~= native_path then
        return false, "snapshot_path_mismatch", true
    end
    local helper
    for _, candidate in ipairs(KINDLE_HELPER_PATHS) do
        if isReadable(candidate) then helper = candidate break end
    end
    if not helper then return false, "position_helper_unavailable", true end
    local request_id = string.format("%d%d", os.time(), math.random(1000, 9999))
    local base = "/tmp/goodreads-native-import-" .. request_id
    local request_path, temp_path, result_path, failed_path =
        base .. ".request", base .. ".tmp", base .. ".json", base .. ".failed"
    local requests = {}
    for _, item in ipairs(snapshot.items) do
        table.insert(requests, { start = item.start_long, ["end"] = item.end_long })
    end
    local request = openPrivateFile(request_path)
    if not request then return false, "request_unavailable", true end
    request:write(json.encode(requests))
    request:close()
    os.execute("chmod 600 " .. util.shell_escape({ request_path }))
    local command = string.format(
        "(umask 077; if %s > %s 2>/dev/null; then mv -f %s %s; else : > %s; fi; rm -f %s) >/dev/null 2>&1 &",
        util.shell_escape({ helper, "translate-native-positions", "--epub", epub_path,
            "--request", request_path }),
        util.shell_escape({ temp_path }), util.shell_escape({ temp_path }),
        util.shell_escape({ result_path }), util.shell_escape({ failed_path }),
        util.shell_escape({ request_path }))
    if os.execute(command) ~= 0 then
        os.remove(request_path)
        return false, "translation_start_failed", true
    end
    self.native_import_inflight = true
    local attempts = 0
    local function cleanup()
        for _, path in ipairs({ request_path, temp_path, result_path, failed_path }) do os.remove(path) end
        self.native_import_inflight = false
    end
    local function complete(success, detail)
        if type(completion) == "function" then completion(success, detail) end
    end
    local function poll()
        attempts = attempts + 1
        if isReadable(failed_path) then
            cleanup()
            complete(false, "position_translation_failed")
            return
        end
        local output = readWholeFile(result_path, 1024 * 1024)
        if output then
            local ok, result = pcall(json.decode, output)
            if ok and result and result.ok and type(result.positions) == "table"
                and #result.positions == #snapshot.items
            then
                for _, position in ipairs(result.positions) do
                    if type(position.start) ~= "table" or type(position.start.xpointer) ~= "string"
                        or type(position["end"]) ~= "table"
                        or type(position["end"].xpointer) ~= "string"
                        or #position.start.xpointer > 65536
                        or #position["end"].xpointer > 65536
                        or position.start.xpointer:sub(1, 1) ~= "/"
                        or position["end"].xpointer:sub(1, 1) ~= "/"
                    then
                        cleanup()
                        complete(false, "position_translation_invalid")
                        return
                    end
                end
                cleanup()
                local imported, detail =
                    self:applyNativeAnnotationImport(reader, snapshot, result.positions)
                complete(imported == true, detail)
                return
            end
            cleanup()
            complete(false, "position_translation_invalid")
            return
        end
        if attempts < 120 then
            UIManager:scheduleIn(1, poll)
        else
            cleanup()
            complete(false, "position_translation_timeout")
        end
    end
    UIManager:scheduleIn(1, poll)
    return true, "queued", true
end

function Goodreads:queueConvergedAnnotationReconcile(reader, trigger, completion)
    local completed = false
    local function finish(success, detail)
        if completed then return end
        completed = true
        if type(completion) == "function" then completion(success, detail) end
    end
    local function queueOutbound()
        if completed then return false, "annotation flow already completed" end
        if self.ui ~= reader or not reader.document then
            finish(false, "reader changed before annotation reconciliation")
            return false, "reader changed before annotation reconciliation"
        end
        local queued, detail = self:queueAnnotationReconcile(reader, trigger)
        finish(queued == true, detail)
        return queued, detail
    end
    local queued, detail, blocks_outbound = self:queueNativeAnnotationImport(
        reader,
        function(success, import_detail)
            if success then
                queueOutbound()
            else
                finish(false, import_detail or "native import failed")
            end
        end
    )
    if not queued and not blocks_outbound then
        return queueOutbound()
    elseif not queued and detail == "inflight" then
        UIManager:scheduleIn(1, function()
            if self.ui == reader and reader.document then
                self:queueConvergedAnnotationReconcile(reader, trigger, completion)
            else
                finish(false, "reader changed before native import completed")
            end
        end)
        return true, "waiting_for_native_import"
    elseif not queued then
        finish(false, detail)
    end
    return queued, detail, blocks_outbound
end

function Goodreads:startReaderReadyAnnotationFlow(reader)
    return self:queueConvergedAnnotationReconcile(
        reader,
        "reader_ready_converged",
        function(success, detail)
            if not success then
                self:debugLog("annotations_sync_skipped", {
                    trigger = "reader_ready",
                    status = safeDebugValue(detail or "native_import_failed"),
                })
            end
        end
    )
end

function Goodreads:scheduleAnnotationReconcile(trigger)
    self.annotation_sync_generation = (self.annotation_sync_generation or 0) + 1
    local generation = self.annotation_sync_generation
    UIManager:scheduleIn(2, function()
        if generation == self.annotation_sync_generation and self.ui and self.ui.document then
            self:queueAnnotationReconcile(self.ui, trigger)
        end
    end)
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
    if self.settings.periodic_progress_enabled == nil then
        self.settings.periodic_progress_enabled = true
    end
    local progress_interval = tonumber(self.settings.progress_interval_seconds)
    if not progress_interval or progress_interval < 120 or progress_interval > 900 then
        self.settings.progress_interval_seconds = DEFAULT_PROGRESS_INTERVAL_SECONDS
    else
        self.settings.progress_interval_seconds = math.floor(progress_interval)
    end
    if self.settings.debug_enabled == nil then
        self.settings.debug_enabled = false
    end
    if self.settings.rating_prompt_enabled == nil then
        self.settings.rating_prompt_enabled = true
    end
    if self.settings.annotation_sync_enabled == nil then
        self.settings.annotation_sync_enabled = true
    end
    if self.settings.native_annotation_import_enabled == nil then
        self.settings.native_annotation_import_enabled = false
    end
    if type(self.settings.rating_prompted) ~= "table" then
        self.settings.rating_prompted = {}
    end
    if type(self.settings.ratings) ~= "table" then
        self.settings.ratings = {}
    end
    if type(self.settings.native_annotation_tombstones) ~= "table" then
        self.settings.native_annotation_tombstones = {}
    end
    G_reader_settings:saveSetting("goodreads_native", self.settings)

    self.last_sync = nil
    self.last_progress_sync = nil
    self.last_checkpoint = nil
    self.last_native_progress_result = nil
    self.last_annotation_event = nil
    self.progress_timer_scheduled = false
    self.progress_timer_generation = 0
    self.rating_prompt_scheduled = {}
    self.annotation_sync_generation = 0
    self.annotation_retry_counts = {}
    self.annotation_request_ids = {}
    self.annotation_snapshot_tokens = {}
    self.annotation_sync_inflight = nil
    self.annotation_pending_snapshots = {}
    self.annotation_pending_order = {}
    self.native_import_inflight = false
    self.native_import_retry_path = nil
    self.native_import_retry_event = nil
    self.ui.menu:registerToMainMenu(self)
    self:applyReaderHook()
    if not outbox_resume_scheduled then
        outbox_resume_scheduled = true
        UIManager:scheduleIn(0, function()
            self:resumeAnnotationOutbox()
        end)
    end
    if self.settings.native_annotation_import_enabled then
        self:startNativeAnnotationWatcher()
    end
end

function Goodreads:saveSettings()
    G_reader_settings:saveSetting("goodreads_native", self.settings)
end

function Goodreads:debugLog(event, fields)
    if not self.settings.debug_enabled then
        return
    end

    local existing = io.open(DEBUG_LOG_FILE, "rb")
    if existing then
        local size = existing:seek("end") or 0
        existing:close()
        if size >= DEBUG_LOG_MAX_BYTES then
            os.remove(DEBUG_LOG_FILE .. ".old")
            os.rename(DEBUG_LOG_FILE, DEBUG_LOG_FILE .. ".old")
        end
    end

    local parts = {
        os.date("!%Y-%m-%dT%H:%M:%SZ"),
        "event=" .. safeDebugValue(event),
    }
    fields = fields or {}
    for _, key in ipairs(DEBUG_FIELD_ORDER) do
        if DEBUG_ALLOWED_FIELDS[key] and fields[key] ~= nil then
            table.insert(parts, key .. "=" .. safeDebugValue(fields[key]))
        end
    end

    local file = io.open(DEBUG_LOG_FILE, "a")
    if not file then
        logger.warn("GoodreadsNative: could not append the redacted debug log")
        return
    end
    file:write(table.concat(parts, " "), "\n")
    file:close()
end

function Goodreads:rememberAsin(asin)
    if isAsin(asin) and self.settings.last_synced_asin ~= asin then
        self.settings.last_synced_asin = asin
        self:saveSettings()
    end
end

function Goodreads:pollProgressResult(asin, percent, previous_started_at, trigger, initial_delay)
    if not self.settings.debug_enabled then
        return
    end

    local attempts = 0
    local function poll()
        if not self.settings.debug_enabled then
            return
        end

        attempts = attempts + 1
        local fields = readKeyValueFile(PROGRESS_RESULT_FILE, PROGRESS_RESULT_KEYS)
        local matches = fields
            and fields.asin == asin
            and tonumber(fields.percent) == percent
            and fields.started_at
            and fields.started_at ~= previous_started_at
            and (fields.success ~= nil or fields.failed_stage ~= nil)

        if matches then
            local accepted = fields.success == "true"
            self.last_native_progress_result = {
                asin = asin,
                percent = percent,
                success = accepted,
                http_status = fields.http_status,
                failed_stage = fields.failed_stage,
                finished_at = fields.finished_at,
            }
            self:debugLog("progress_result", {
                trigger = trigger,
                asin = asin,
                percent = percent,
                http_status = fields.http_status or "none",
                response_valid = fields.response_valid or "unknown",
                error_envelope = fields.error_envelope or "unknown",
                success = fields.success or "false",
                failed_stage = fields.failed_stage,
                error_class = fields.error_class,
            })
            return
        end

        local saved_percent = tonumber(readFirstLine(PROGRESS_STATE_DIR .. "/" .. asin))
        if saved_percent == percent and attempts >= 3 then
            self.last_native_progress_result = {
                asin = asin,
                percent = percent,
                success = true,
                persisted = true,
            }
            self:debugLog("progress_result", {
                trigger = trigger,
                asin = asin,
                percent = percent,
                status = "accepted_and_persisted",
                success = true,
            })
            return
        end

        if attempts < 60 then
            UIManager:scheduleIn(0.5, poll)
        else
            self.last_native_progress_result = {
                asin = asin,
                percent = percent,
                success = false,
                timed_out = true,
            }
            self:debugLog("progress_result", {
                trigger = trigger,
                asin = asin,
                percent = percent,
                status = "no_result_within_30_seconds",
                success = false,
            })
        end
    end

    UIManager:scheduleIn(initial_delay or 0.5, poll)
end

function Goodreads:syncCapturedCheckpoint(asin, percent, status, trigger, resolver)
    if not isAsin(asin) or type(percent) ~= "number" then
        self:debugLog("checkpoint_skipped", {
            trigger = trigger,
            resolver = resolver or "unknown",
            status = isAsin(asin) and "missing_progress" or "missing_asin",
        })
        return false, "book has no syncable ASIN or progress"
    end

    local action = actionForState(percent, status)
    local whole_percent = percentageForProgress(percent)
    self.last_checkpoint = {
        asin = asin,
        percent = whole_percent,
        trigger = trigger,
        resolver = resolver,
        time = os.time(),
    }
    self:rememberAsin(asin)
    self:debugLog("checkpoint", {
        trigger = trigger,
        asin = asin,
        percent = whole_percent,
        resolver = resolver or "unknown",
        action = action == ACTION_READ and "read"
            or action == ACTION_READING and "currently_reading"
            or "none",
        status = status or "none",
    })

    if not action then
        return false, "no reading progress yet"
    end

    local shelf_ok = true
    local progress_ok = true
    -- The native shelf action changes membership (Currently Reading/Read); it
    -- is not the percentage transport. Re-publishing the same action at every
    -- periodic percentage checkpoint keeps waking KPP and, on some firmware,
    -- can leave KOReader and powerd in an event loop behind the native reader.
    if self.settings.enabled and trigger ~= "periodic" then
        shelf_ok = self:syncAsin(asin, action, percent, false, trigger)
    end
    if self.settings.percentage_enabled then
        progress_ok = self:syncProgress(asin, percent, trigger)
    end
    return shelf_ok and progress_ok, "checkpoint processed"
end

function Goodreads:syncReaderCheckpoint(reader, trigger)
    if not reader or not reader.document then
        return false, "no open document"
    end

    local asin, resolver = getBookAsin(reader)
    local percent, status = getBookState(reader)
    return self:syncCapturedCheckpoint(asin, percent, status, trigger, resolver)
end

function Goodreads:scheduleProgressTimer()
    if self.progress_timer_scheduled
        or not self.settings.periodic_progress_enabled
        or not self.ui
        or not self.ui.document
    then
        return
    end

    local interval = tonumber(self.settings.progress_interval_seconds)
        or DEFAULT_PROGRESS_INTERVAL_SECONDS
    local generation = self.progress_timer_generation
    self.progress_timer_scheduled = true
    UIManager:scheduleIn(interval, function()
        if generation ~= self.progress_timer_generation then
            return
        end
        self.progress_timer_scheduled = false
        if self.ui and self.ui.document and self.settings.periodic_progress_enabled then
            self:syncReaderCheckpoint(self.ui, "periodic")
            self:scheduleProgressTimer()
        end
    end)
end

function Goodreads:resetProgressTimer()
    self.progress_timer_generation = (self.progress_timer_generation or 0) + 1
    self.progress_timer_scheduled = false
    self:scheduleProgressTimer()
end

function Goodreads:setProgressInterval(seconds)
    if seconds ~= 120 and seconds ~= 300 and seconds ~= 600 and seconds ~= 900 then
        return
    end
    self.settings.progress_interval_seconds = seconds
    self:saveSettings()
    self:debugLog("interval_changed", {
        trigger = "menu",
        interval_seconds = seconds,
        status = "applied_immediately",
    })
    self:resetProgressTimer()
end

function Goodreads:onReaderReady()
    self:scheduleProgressTimer()
    UIManager:scheduleIn(0.5, function()
        if self.ui and self.ui.document then
            self:startReaderReadyAnnotationFlow(self.ui)
        end
    end)
    UIManager:scheduleIn(3, function()
        if self.ui and self.ui.document and self.settings.periodic_progress_enabled then
            self:syncReaderCheckpoint(self.ui, "reader_ready")
        end
    end)
end

function Goodreads:onPageUpdate()
    self:scheduleProgressTimer()
end

function Goodreads:onPosUpdate()
    self:scheduleProgressTimer()
end

function Goodreads:onSuspend()
    if self.ui and self.ui.document then
        self:syncReaderCheckpoint(self.ui, "suspend")
        self:queueAnnotationReconcile(self.ui, "suspend")
    end
end

function Goodreads:onResume()
    UIManager:scheduleIn(3, function()
        if self.ui and self.ui.document then
            local reader = self.ui
            self:queueNativeAnnotationImport(reader, function(success)
                if success and self.ui == reader and reader.document then
                    self:scheduleAnnotationReconcile("resume_after_native_import")
                end
            end)
            self:syncReaderCheckpoint(self.ui, "resume")
            self:scheduleProgressTimer()
        end
    end)
end

function Goodreads:onAnnotationsModified(items)
    if self.native_import_event_inflight then
        local stats = annotationStats(self.ui)
        self.last_annotation_event = {
            time = os.time(),
            changed = type(items) == "table" and #items or 0,
            stats = stats,
        }
        self:debugLog("annotations_modified", {
            trigger = "native_import",
            changed = self.last_annotation_event.changed,
            annotations = stats.total,
            highlights = stats.highlights,
            notes = stats.notes,
            bookmarks = stats.bookmarks,
            status = "native_import_persisted_without_echo",
        })
        return true
    end
    self:rememberNativeAnnotationDeletion(items)
    local stats = annotationStats(self.ui)
    local changed = type(items) == "table" and #items or 0
    self.last_annotation_event = {
        time = os.time(),
        changed = changed,
        stats = stats,
    }
    self:debugLog("annotations_modified", {
        trigger = "event",
        changed = changed,
        annotations = stats.total,
        highlights = stats.highlights,
        notes = stats.notes,
        bookmarks = stats.bookmarks,
        status = self.settings.annotation_sync_enabled and "sync_scheduled" or "sync_disabled",
    })
    self:scheduleAnnotationReconcile("annotations_modified")
end

function Goodreads:maybePromptForRating(asin)
    if not isAsin(asin) then
        return
    end

    self.settings.last_completed_asin = asin
    self:saveSettings()
    if not self.settings.rating_prompt_enabled
        or self.settings.rating_prompted[asin]
        or self.settings.ratings[asin]
        or self.rating_prompt_scheduled[asin]
    then
        return
    end

    self.rating_prompt_scheduled[asin] = true
    UIManager:scheduleIn(0.8, function()
        self.rating_prompt_scheduled[asin] = nil
        if not self.settings.rating_prompted[asin]
            and not self.settings.ratings[asin]
        then
            self.settings.rating_prompted[asin] = os.time()
            self:saveSettings()
            self:showRatingDialog(asin)
        end
    end)
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
        -- The hook is installed first by the file-manager instance. Resolve
        -- the active ReaderUI instance so menu settings changed while reading
        -- are honored by automatic close synchronization.
        local active_plugin = reader.goodreads_native or plugin
        local asin, resolver = getBookAsin(reader)
        local percent, status = getBookState(reader)
        local stats = annotationStats(reader)

        active_plugin:queueAnnotationReconcile(reader, "close")

        local result = original_on_close(reader, ...)

        if asin and percent then
            local action = actionForState(percent, status)
            active_plugin:syncCapturedCheckpoint(asin, percent, status, "close", resolver)
            active_plugin:debugLog("annotations_reconciled", {
                trigger = "close",
                asin = asin,
                annotations = stats.total,
                highlights = stats.highlights,
                notes = stats.notes,
                bookmarks = stats.bookmarks,
                status = active_plugin.settings.annotation_sync_enabled and "sync_queued" or "sync_disabled",
            })
            if action == ACTION_READ then
                active_plugin:maybePromptForRating(asin)
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
    self:debugLog("rating_queued", {
        trigger = "manual_choice",
        asin = asin,
        rating = rating,
        status = "queued",
    })

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
                    self:syncAsin(asin, ACTION_READ, 1, false, "rating")
                end
                self:debugLog("rating_result", {
                    trigger = "manual_choice",
                    asin = asin,
                    rating = rating,
                    status = "accepted",
                    success = true,
                })
                logger.info("GoodreadsNative: native rating sent", asin, rating)
                if on_complete then
                    on_complete(true, "sent")
                end
            else
                local detail = fields.native_exit == "143"
                    and "native Goodreads service timed out"
                    or "native Goodreads service rejected the rating"
                self:debugLog("rating_result", {
                    trigger = "manual_choice",
                    asin = asin,
                    rating = rating,
                    status = fields.native_exit == "143" and "timed_out" or "rejected",
                    success = false,
                })
                logger.warn("GoodreadsNative: native rating failed", asin, rating, detail)
                if on_complete then
                    on_complete(false, detail)
                end
            end
            return
        end

        if attempts < 70 then
            UIManager:scheduleIn(0.5, pollResult)
        else
            self:debugLog("rating_result", {
                trigger = "manual_choice",
                asin = asin,
                rating = rating,
                status = "no_result_within_35_seconds",
                success = false,
            })
            if on_complete then
                on_complete(false, "native Goodreads service did not return a result")
            end
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
    local asin = reader and getBookAsin(reader)
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

function Goodreads:syncAsin(asin, action, percent, wait_for_result, trigger)
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
        self:debugLog("shelf_skipped", {
            trigger = trigger or "unknown",
            asin = asin,
            percent = percentageForProgress(percent),
            action = action == ACTION_READ and "read" or "currently_reading",
            status = "recent_duplicate",
        })
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
            self:debugLog("shelf_result", {
                trigger = trigger or "manual",
                asin = asin,
                percent = percentageForProgress(percent),
                action = action == ACTION_READ and "read" or "currently_reading",
                status = "no_native_response",
                success = false,
            })
            return false, "native Goodreads action returned no response"
        end
        self:debugLog("shelf_result", {
            trigger = trigger or "manual",
            asin = asin,
            percent = percentageForProgress(percent),
            action = action == ACTION_READ and "read" or "currently_reading",
            status = "native_response_received",
            success = true,
        })
        return true, output:gsub("%s+$", "")
    end

    self:debugLog("shelf_queued", {
        trigger = trigger or "automatic",
        asin = asin,
        percent = percentageForProgress(percent),
        action = action == ACTION_READ and "read" or "currently_reading",
        status = "queued",
    })
    return true, "queued"
end

function Goodreads:syncProgress(asin, fraction, trigger)
    if not isAsin(asin) then
        return false, "not an Amazon ASIN"
    end

    local percent = percentageForProgress(fraction)
    if not percent or percent < 1 then
        self:debugLog("progress_skipped", {
            trigger = trigger or "unknown",
            asin = asin,
            percent = percent or 0,
            status = "below_one_percent",
        })
        return false, "no percentage progress yet"
    end

    local saved_percent = tonumber(readFirstLine(PROGRESS_STATE_DIR .. "/" .. asin))
    if saved_percent == percent then
        self.last_native_progress_result = {
            asin = asin,
            percent = percent,
            success = true,
            persisted = true,
        }
        self:debugLog("progress_skipped", {
            trigger = trigger or "unknown",
            asin = asin,
            percent = percent,
            status = "already_accepted",
            success = true,
        })
        return true, "already accepted"
    end

    local now = os.time()
    if self.last_progress_sync
        and self.last_progress_sync.asin == asin
        and self.last_progress_sync.percent == percent
        and now - self.last_progress_sync.time < 15
    then
        self:debugLog("progress_skipped", {
            trigger = trigger or "unknown",
            asin = asin,
            percent = percent,
            status = "recent_duplicate",
        })
        return true, "already queued recently"
    end

    local delay = tonumber(self.settings.percentage_delay_seconds) or 3
    delay = math.max(0, math.min(30, math.floor(delay)))
    local previous_result = readKeyValueFile(PROGRESS_RESULT_FILE, PROGRESS_RESULT_KEYS)
    local previous_started_at = previous_result and previous_result.started_at
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
    self:debugLog("progress_queued", {
        trigger = trigger or "automatic",
        asin = asin,
        percent = percent,
        status = "queued",
    })
    self:pollProgressResult(
        asin,
        percent,
        previous_started_at,
        trigger or "automatic",
        delay + 0.5
    )
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

    local asin = getBookAsin(reader)
    local percent, status = getBookState(reader)
    local action = actionForState(percent or 0, status)

    if not asin then
        UIManager:show(InfoMessage:new({
            text = _("This file has no Amazon ASIN in its filename."),
            timeout = 4,
        }))
        return
    end

    self:queueNativeAnnotationImport(reader)

    if not action then
        UIManager:show(InfoMessage:new({
            text = _("No progress yet; Goodreads was not changed."),
            timeout = 3,
        }))
        return
    end

    local ok, detail = self:syncAsin(asin, action, percent, true, "manual")
    local progress_ok = self:syncProgress(asin, percent, "manual")
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

function Goodreads:showDiagnostics()
    local reader = self.ui and self.ui.document and self.ui
    local current_asin = reader and getBookAsin(reader) or nil
    local current_percent = reader and select(1, getBookState(reader)) or nil
    local asin = current_asin or self.settings.last_synced_asin
    local accepted_percent = isAsin(asin)
        and tonumber(readFirstLine(PROGRESS_STATE_DIR .. "/" .. asin))
        or nil
    local native = readKeyValueFile(PROGRESS_RESULT_FILE, PROGRESS_RESULT_KEYS)
    local receipt = isAsin(asin)
        and readKeyValueFile(SYNC_RECEIPT_DIR .. "/" .. asin, SYNC_RECEIPT_KEYS)
        or nil
    local pending = isAsin(asin) and (
        isReadable(ANNOTATION_PENDING_DIR .. "/" .. asin)
            or isReadable(ANNOTATION_OUTBOX_DIR .. "/" .. asin)
    )

    local lines = {
        _("Goodreads native sync diagnostics"),
        "",
        string.format(
            _("Automatic shelf sync: %s"),
            self.settings.enabled and _("enabled") or _("disabled")
        ),
        string.format(
            _("Silent percentage sync: %s"),
            self.settings.percentage_enabled and _("enabled") or _("disabled")
        ),
        string.format(
            _("Periodic while reading: %s (%d min)"),
            self.settings.periodic_progress_enabled and _("enabled") or _("disabled"),
            math.floor((tonumber(self.settings.progress_interval_seconds)
                or DEFAULT_PROGRESS_INTERVAL_SECONDS) / 60)
        ),
        string.format(
            _("Redacted debug log: %s"),
            self.settings.debug_enabled and _("enabled") or _("disabled")
        ),
        "",
    }

    if isAsin(current_asin) and current_percent then
        table.insert(lines, string.format(
            _("Live book: %s at %d%%"),
            current_asin,
            percentageForProgress(current_percent)
        ))
    elseif isAsin(asin) then
        table.insert(lines, string.format(_("Last ASIN: %s"), asin))
    else
        table.insert(lines, _("No ASIN-backed book has been observed yet."))
    end

    if accepted_percent then
        table.insert(lines, string.format(
            _("Last accepted percentage: %d%%"),
            accepted_percent
        ))
    else
        table.insert(lines, _("Last accepted percentage: none recorded"))
    end

    if native and isAsin(native.asin) and native.percent then
        local result = native.success == "true" and _("accepted") or _("failed")
        local suffix = native.http_status and " HTTP " .. native.http_status
            or native.failed_stage and " stage " .. native.failed_stage
            or ""
        table.insert(lines, string.format(
            _("Latest native result: %s, %s%%, %s%s"),
            native.asin,
            native.percent,
            result,
            suffix
        ))
    else
        table.insert(lines, _("Latest native result: none available"))
    end

    if self.last_annotation_event then
        local stats = self.last_annotation_event.stats
        table.insert(lines, string.format(
            _("Annotation events: last change %d item(s); %d highlight(s), %d note(s) observed"),
            self.last_annotation_event.changed,
            stats.highlights,
            stats.notes
        ))
    else
        table.insert(lines, _("Annotation events: none observed this session"))
    end
    if self.last_annotation_sync_result then
        local result = self.last_annotation_sync_result
        local journal_ok = result.ksdk_synced == "true"
            or result.legacy_journaled == "true"
        local snapshot_ok = result.cloud_snapshot_synced == "true"
            or result.cloud_snapshot_synced == "unavailable"
        table.insert(lines, string.format(
            _("Latest annotation sync: %s; local readback %s; KPP notification %s; native journal %s; upload request %s; system queue %s; %s highlight(s) created, %s note(s) created, %s note(s) updated"),
            result.success == "true" and result.local_verified == "true"
                and result.native_notified == "true"
                and (result.ksdk_synced == "true" or result.ksdk_synced == "unavailable")
                and (result.legacy_journaled == "true"
                    or result.legacy_journaled == "unavailable")
                and journal_ok
                and result.native_cloud_queued == "true"
                and snapshot_ok
                and result.sync_enqueued == "true"
                and _("accepted") or _("failed"),
            result.local_verified == "true" and _("verified") or _("not verified"),
            result.native_notified == "true" and _("notified") or _("not notified"),
            journal_ok and _("written") or _("not written"),
            result.native_cloud_queued == "true" and _("requested") or _("not requested"),
            result.sync_enqueued == "true" and _("accepted") or _("not queued"),
            result.highlights_created or "0",
            result.notes_created or "0",
            result.notes_updated or "0"
        ))
    else
        table.insert(lines, _("Latest annotation sync: none available this session"))
    end
    table.insert(lines, self.settings.annotation_sync_enabled
        and _("Annotation sync: enabled for converted Kindle books with a position map")
        or _("Annotation sync: disabled"))

    table.insert(lines, "")
    table.insert(lines, _("Durable annotation receipt"))
    if receipt and receipt.asin == asin then
        local effective_state = pending and "waiting_native" or receiptEnum(receipt.state, {
            saved_locally = true,
            waiting_native = true,
            queued_amazon = true,
            cloud_observed = true,
            failed = true,
            discarded = true,
        }, "unknown")
        local journal_lane = receiptEnum(receipt.journal_lane, {
            legacy = true,
            ksdk = true,
            unavailable = true,
        }, "unavailable")
        local local_verified = receiptEnum(receipt.local_verified, {
            ["true"] = true,
            ["false"] = true,
            unavailable = true,
        }, "unavailable")
        local upload_requested = receiptEnum(receipt.upload_requested, {
            ["true"] = true,
            ["false"] = true,
            unavailable = true,
        }, "unavailable")
        local sync_enqueued = receiptEnum(receipt.sync_enqueued, {
            ["true"] = true,
            ["false"] = true,
            unavailable = true,
        }, "unavailable")
        local outbox_acknowledged = receiptEnum(receipt.outbox_acknowledged, {
            ["true"] = true,
            ["false"] = true,
            unavailable = true,
        }, "unavailable")
        local outbox_sequence = receiptCount(receipt.outbox_sequence)
        local retry_reason = receiptEnum(receipt.retry_reason, {
            none = true,
            wait_for_active_book = true,
            native_sync_enqueue = true,
            validate_payload = true,
            transfer_payload = true,
            enable_sync_lanes = true,
            attach_agent = true,
            wait_for_result = true,
            lock_busy = true,
            user_discarded = true,
        }, "unavailable")
        local agent_generation = receipt.agent_generation == "27" and "27" or "unknown"
        local state_label = ({
            saved_locally = _("saved locally"),
            waiting_native = _("waiting for native reader"),
            queued_amazon = _("queued to Amazon"),
            cloud_observed = _("cloud observed"),
            failed = _("failed; retry available"),
            discarded = _("pending snapshot discarded"),
        })[effective_state] or _("unknown")
        table.insert(lines, string.format(_("State: %s"), state_label))
        table.insert(lines, string.format(
            _("Snapshot: %s annotation(s), %s note(s); saved %s"),
            receiptCount(receipt.desired_count),
            receiptCount(receipt.note_count),
            formatReceiptTime(receipt.saved_at)
        ))
        table.insert(lines, string.format(
            _("Native lane: %s; local readback %s; upload request %s; system queue %s"),
            journal_lane,
            local_verified,
            upload_requested,
            sync_enqueued
        ))
        table.insert(lines, string.format(
            _("Retry: %s attempt(s); reason %s; agent %s"),
            receiptCount(receipt.retry_count),
            retry_reason,
            agent_generation
        ))
        table.insert(lines, string.format(
            _("Outbox: sequence %s; acknowledged deletion %s"),
            outbox_sequence,
            outbox_acknowledged
        ))
        table.insert(lines, string.format(
            _("Cloud observation: %s"),
            receipt.cloud_observed == "true" and _("verified") or _("unavailable")
        ))
    elseif isAsin(asin) then
        table.insert(lines, _("No durable annotation receipt exists for this book yet."))
    else
        table.insert(lines, _("Open an ASIN-backed book to view its receipt."))
    end

    if self.settings.debug_enabled then
        table.insert(lines, "")
        table.insert(lines, DEBUG_LOG_FILE)
    end

    UIManager:show(InfoMessage:new({
        text = table.concat(lines, "\n"),
        timeout = 15,
    }))
end

function Goodreads:getReceiptAsin()
    local reader = self.ui and self.ui.document and self.ui
    local asin = reader and getBookAsin(reader) or self.settings.last_synced_asin
    return isAsin(asin) and asin or nil
end

function Goodreads:retryPendingAnnotations()
    local asin = self:getReceiptAsin()
    local has_outbox = asin and isReadable(ANNOTATION_OUTBOX_DIR .. "/" .. asin)
    local has_pending = asin and isReadable(ANNOTATION_PENDING_DIR .. "/" .. asin)
    if not asin or (not has_outbox and not has_pending) then
        UIManager:show(InfoMessage:new({
            text = _("No pending annotation snapshot exists for the selected book."),
            timeout = 4,
        }))
        return false
    end
    if has_outbox then
        local snapshot, detail = readAnnotationOutbox(asin)
        if not snapshot then
            UIManager:show(InfoMessage:new({
                text = string.format(_("Pending outbox is invalid: %s"), detail or _("unknown error")),
                timeout = 5,
            }))
            return false
        end
        self.annotation_snapshot_tokens[asin] = snapshot.sequence
        self:queueAnnotationSnapshot(snapshot)
    else
        os.execute(
            util.shell_escape({ RECEIPT_HELPER, "retry", asin }) .. " >/dev/null 2>&1"
        )
    end
    UIManager:show(InfoMessage:new({
        text = _("Pending annotation retry requested."),
        timeout = 3,
    }))
    return true
end

function Goodreads:showDiscardPendingDialog()
    local asin = self:getReceiptAsin()
    if not asin or not isReadable(ANNOTATION_PENDING_DIR .. "/" .. asin) then
        UIManager:show(InfoMessage:new({
            text = _("No pending annotation snapshot exists for the selected book."),
            timeout = 4,
        }))
        return
    end

    local dialog
    dialog = ButtonDialog:new({
        title = _("Discard the pending annotation snapshot?\nThis does not delete annotations already saved in KOReader or Kindle."),
        title_align = "center",
        width_factor = 0.9,
        buttons = {
            {
                {
                    text = _("Discard pending"),
                    callback = function()
                        UIManager:close(dialog)
                        local status = os.execute(
                            util.shell_escape({ RECEIPT_HELPER, "discard", asin })
                                .. " >/dev/null 2>&1"
                        )
                        UIManager:show(InfoMessage:new({
                            text = status == 0 and _("Pending snapshot discarded.")
                                or _("Could not discard the pending snapshot."),
                            timeout = 4,
                        }))
                    end,
                },
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    })
    UIManager:show(dialog)
end

function Goodreads:exportRedactedSupportBundle()
    local status = os.execute(
        util.shell_escape({ RECEIPT_HELPER, "export" }) .. " >/dev/null 2>&1"
    )
    UIManager:show(InfoMessage:new({
        text = status == 0
            and string.format(_("Redacted support summary saved to:\n%s"), SUPPORT_BUNDLE_FILE)
            or _("Could not create the support summary."),
        timeout = 7,
    }))
    return status == 0
end

function Goodreads:clearDebugLog()
    os.remove(DEBUG_LOG_FILE)
    os.remove(DEBUG_LOG_FILE .. ".old")
    UIManager:show(InfoMessage:new({
        text = _("Goodreads debug logs cleared."),
        timeout = 3,
    }))
end

local function debugLogExists()
    local file = io.open(DEBUG_LOG_FILE, "r")
    if not file then
        file = io.open(DEBUG_LOG_FILE .. ".old", "r")
    end
    if not file then
        return false
    end
    file:close()
    return true
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
                text = _("Sync periodically while reading"),
                checked_func = function()
                    return self.settings.periodic_progress_enabled == true
                end,
                callback = function()
                    self.settings.periodic_progress_enabled = not self.settings.periodic_progress_enabled
                    self:saveSettings()
                    self:debugLog("periodic_sync_changed", {
                        trigger = "menu",
                        interval_seconds = self.settings.progress_interval_seconds,
                        status = self.settings.periodic_progress_enabled and "enabled" or "disabled",
                    })
                    self:resetProgressTimer()
                    if self.settings.periodic_progress_enabled and self.ui and self.ui.document then
                        self:syncReaderCheckpoint(self.ui, "periodic_enabled")
                    end
                end,
            },
            {
                text = _("Periodic sync interval"),
                enabled_func = function()
                    return self.settings.periodic_progress_enabled == true
                end,
                sub_item_table = {
                    {
                        text = _("2 minutes"),
                        checked_func = function()
                            return self.settings.progress_interval_seconds == 120
                        end,
                        callback = function()
                            self:setProgressInterval(120)
                        end,
                    },
                    {
                        text = _("5 minutes"),
                        checked_func = function()
                            return self.settings.progress_interval_seconds == 300
                        end,
                        callback = function()
                            self:setProgressInterval(300)
                        end,
                    },
                    {
                        text = _("10 minutes"),
                        checked_func = function()
                            return self.settings.progress_interval_seconds == 600
                        end,
                        callback = function()
                            self:setProgressInterval(600)
                        end,
                    },
                    {
                        text = _("15 minutes"),
                        checked_func = function()
                            return self.settings.progress_interval_seconds == 900
                        end,
                        callback = function()
                            self:setProgressInterval(900)
                        end,
                    },
                },
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
                text = _("Sync notes and highlights"),
                checked_func = function()
                    return self.settings.annotation_sync_enabled == true
                end,
                callback = function()
                    self.settings.annotation_sync_enabled = not self.settings.annotation_sync_enabled
                    self:saveSettings()
                    if self.settings.annotation_sync_enabled and self.ui and self.ui.document then
                        self:scheduleAnnotationReconcile("annotation_sync_enabled")
                    end
                end,
            },
            {
                text = _("Import native Kindle highlights (experimental)"),
                checked_func = function()
                    return self.settings.native_annotation_import_enabled == true
                end,
                callback = function()
                    self.settings.native_annotation_import_enabled =
                        not self.settings.native_annotation_import_enabled
                    self:saveSettings()
                    if self.settings.native_annotation_import_enabled then
                        self:startNativeAnnotationWatcher()
                        if self.ui and self.ui.document then
                            self:queueConvergedAnnotationReconcile(
                                self.ui, "native_import_enabled")
                        end
                    else
                        os.remove(NATIVE_IMPORT_ENABLED_FILE)
                    end
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
                text = _("Sync notes and highlights now"),
                enabled_func = function()
                    return self.ui and self.ui.document and self.settings.annotation_sync_enabled
                end,
                callback = function()
                    local reader = self.ui
                    self:queueConvergedAnnotationReconcile(
                        reader,
                        "manual_converged",
                        function(ok, detail)
                            UIManager:show(InfoMessage:new({
                                text = ok and _("Annotation sync queued.")
                                    or tostring(detail),
                                timeout = 4,
                            }))
                        end
                    )
                end,
            },
            {
                text = _("Redacted debug log"),
                checked_func = function()
                    return self.settings.debug_enabled == true
                end,
                callback = function()
                    if self.settings.debug_enabled then
                        self:debugLog("debug_disabled", { status = "disabled_by_user" })
                        self.settings.debug_enabled = false
                    else
                        self.settings.debug_enabled = true
                        self:debugLog("debug_enabled", {
                            status = "enabled_by_user",
                            interval_seconds = self.settings.progress_interval_seconds,
                        })
                    end
                    self:saveSettings()
                end,
            },
            {
                text = _("Show sync diagnostics"),
                callback = function()
                    self:showDiagnostics()
                end,
            },
            {
                text = _("Sync receipts and recovery"),
                sub_item_table = {
                    {
                        text = _("Retry pending annotations"),
                        enabled_func = function()
                            local asin = self:getReceiptAsin()
                            return asin and (
                                isReadable(ANNOTATION_PENDING_DIR .. "/" .. asin)
                                    or isReadable(ANNOTATION_OUTBOX_DIR .. "/" .. asin)
                            )
                        end,
                        callback = function()
                            self:retryPendingAnnotations()
                        end,
                    },
                    {
                        text = _("Discard pending annotations…"),
                        enabled_func = function()
                            local asin = self:getReceiptAsin()
                            return asin and (
                                isReadable(ANNOTATION_PENDING_DIR .. "/" .. asin)
                                    or isReadable(ANNOTATION_OUTBOX_DIR .. "/" .. asin)
                            )
                        end,
                        callback = function()
                            self:showDiscardPendingDialog()
                        end,
                    },
                    {
                        text = _("Export redacted support summary"),
                        callback = function()
                            self:exportRedactedSupportBundle()
                        end,
                    },
                },
            },
            {
                text = _("Clear debug log"),
                enabled_func = debugLogExists,
                callback = function()
                    self:clearDebugLog()
                end,
            },
            {
                text = _("About native Goodreads sync"),
                callback = function()
                    UIManager:show(InfoMessage:new({
                        text = _(
                            "Uses the Kindle's built-in Goodreads action. "
                            .. "It updates Currently Reading or Read, periodically sends live whole-number progress, and submits "
                            .. "an explicit 0–5 star choice through the native Goodreads rating service "
                            .. "for books with an Amazon ASIN. "
                            .. "The optional diagnostics log is redacted. For converted Kindle books with a position map, "
                            .. "highlights and private notes are reconciled with the native Kindle annotation store. "
                            .. "It does not use a Goodreads password, API key, or background Goodreads API."
                        ),
                        timeout = 12,
                    }))
                end,
            },
        },
    }
end

return Goodreads
