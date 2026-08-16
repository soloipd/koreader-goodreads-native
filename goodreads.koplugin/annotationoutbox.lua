-- Deterministic, text-safe serialization for the crash-safe annotation outbox.
-- The caller stores these snapshots in a private filesystem and verifies the
-- SHA-256 returned by split() before parse() is allowed to reconstruct text.

local Outbox = {}

local function isAsin(value)
    return type(value) == "string" and value:match("^B[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]$") ~= nil
end

local function integer(value, minimum, maximum)
    return type(value) == "number"
        and value == math.floor(value)
        and value >= minimum
        and value <= maximum
end

local function hexEncode(value)
    return (value:gsub(".", function(character)
        return string.format("%02x", string.byte(character))
    end))
end

local function hexDecode(value, maximum)
    if type(value) ~= "string" or #value % 2 ~= 0 or #value > maximum * 2
        or value:find("[^0-9a-f]")
    then
        return nil
    end
    return (value:gsub("..", function(byte)
        return string.char(tonumber(byte, 16))
    end))
end

function Outbox.encode(snapshot, sequence, created_at)
    if type(snapshot) ~= "table" or not isAsin(snapshot.asin)
        or not integer(sequence, 1, 9007199254740991)
        or not integer(created_at, 1, 9007199254740991)
        or type(snapshot.epub_path) ~= "string" or #snapshot.epub_path > 4096
        or type(snapshot.native_path) ~= "string" or #snapshot.native_path > 4096
        or type(snapshot.desired) ~= "table" or #snapshot.desired > 1000
    then
        return nil, "invalid snapshot envelope"
    end

    local trigger = type(snapshot.trigger) == "string" and snapshot.trigger or "unknown"
    if not trigger:match("^[a-z0-9_]+$") or #trigger > 64 then
        trigger = "unknown"
    end

    local lines = {
        "outbox_version=1",
        "asin=" .. snapshot.asin,
        "sequence=" .. tostring(sequence),
        "created_at=" .. tostring(created_at),
        "trigger=" .. trigger,
        "epub_path_hex=" .. hexEncode(snapshot.epub_path),
        "native_path_hex=" .. hexEncode(snapshot.native_path),
        "desired_count=" .. tostring(#snapshot.desired),
    }
    local note_bytes = 0
    for index, item in ipairs(snapshot.desired) do
        if type(item) ~= "table" or type(item.start) ~= "string"
            or type(item.finish) ~= "string" or type(item.note) ~= "string"
            or #item.start > 65536 or #item.finish > 65536 or #item.note > 65536
        then
            return nil, "invalid desired annotation"
        end
        note_bytes = note_bytes + #item.note
        if note_bytes > 200 * 1024 then
            return nil, "annotation notes exceed safe limit"
        end
        local base = "desired." .. tostring(index - 1) .. "."
        table.insert(lines, base .. "start_hex=" .. hexEncode(item.start))
        table.insert(lines, base .. "end_hex=" .. hexEncode(item.finish))
        table.insert(lines, base .. "note_hex=" .. hexEncode(item.note))
    end
    return table.concat(lines, "\n") .. "\n"
end

function Outbox.pack(body, checksum)
    if type(body) ~= "string" or body:sub(-1) ~= "\n"
        or body:find("\nchecksum=", 1, true)
        or type(checksum) ~= "string" or #checksum ~= 64
        or checksum:find("[^0-9a-f]")
    then
        return nil, "invalid outbox body or checksum"
    end
    return body .. "checksum=" .. checksum .. "\n"
end

function Outbox.split(content)
    if type(content) ~= "string" or #content > 1024 * 1024 then
        return nil, nil, "invalid outbox size"
    end
    local body, checksum = content:match("^(.*\n)checksum=([0-9a-f]+)\n$")
    if not body or #checksum ~= 64 or body:find("\nchecksum=", 1, true) then
        return nil, nil, "invalid outbox checksum envelope"
    end
    return body, checksum
end

function Outbox.parse(body, expected_asin)
    if type(body) ~= "string" or #body > 1024 * 1024 or body:sub(-1) ~= "\n" then
        return nil, "invalid outbox body"
    end
    local fields = {}
    for line in body:gmatch("([^\n]*)\n") do
        local key, value = line:match("^([a-z0-9_.]+)=(.*)$")
        if not key or fields[key] ~= nil then
            return nil, "invalid or duplicate outbox field"
        end
        fields[key] = value
    end
    if fields.outbox_version ~= "1" or not isAsin(fields.asin)
        or (expected_asin and fields.asin ~= expected_asin)
    then
        return nil, "invalid outbox identity"
    end
    local sequence = tonumber(fields.sequence)
    local created_at = tonumber(fields.created_at)
    local desired_count = tonumber(fields.desired_count)
    if not integer(sequence, 1, 9007199254740991)
        or not integer(created_at, 1, 9007199254740991)
        or not integer(desired_count, 0, 1000)
        or type(fields.trigger) ~= "string" or not fields.trigger:match("^[a-z0-9_]+$")
    then
        return nil, "invalid outbox metadata"
    end
    local epub_path = hexDecode(fields.epub_path_hex, 4096)
    local native_path = hexDecode(fields.native_path_hex, 4096)
    if not epub_path or not native_path then
        return nil, "invalid outbox paths"
    end

    local desired = {}
    local allowed = {
        outbox_version = true,
        asin = true,
        sequence = true,
        created_at = true,
        trigger = true,
        epub_path_hex = true,
        native_path_hex = true,
        desired_count = true,
    }
    local note_bytes = 0
    for index = 0, desired_count - 1 do
        local base = "desired." .. tostring(index) .. "."
        local start_key = base .. "start_hex"
        local end_key = base .. "end_hex"
        local note_key = base .. "note_hex"
        allowed[start_key], allowed[end_key], allowed[note_key] = true, true, true
        local start = hexDecode(fields[start_key], 65536)
        local finish = hexDecode(fields[end_key], 65536)
        local note = hexDecode(fields[note_key], 65536)
        if not start or not finish or not note then
            return nil, "invalid desired annotation encoding"
        end
        note_bytes = note_bytes + #note
        if note_bytes > 200 * 1024 then
            return nil, "annotation notes exceed safe limit"
        end
        table.insert(desired, { start = start, finish = finish, note = note })
    end
    for key in pairs(fields) do
        if not allowed[key] then
            return nil, "unexpected outbox field"
        end
    end
    return {
        asin = fields.asin,
        sequence = sequence,
        created_at = created_at,
        trigger = fields.trigger,
        epub_path = epub_path,
        native_path = native_path,
        desired = desired,
        attempt = 0,
        token = sequence,
    }
end

return Outbox
