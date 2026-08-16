local project_root = assert(os.getenv("PROJECT_ROOT"), "PROJECT_ROOT is required")
local Outbox = assert(dofile(project_root .. "/goodreads.koplugin/annotationoutbox.lua"))

local snapshot = {
    asin = "B012345678",
    epub_path = "/mnt/us/koreader/cache/kindle.koplugin/example.epub",
    native_path = "/mnt/us/documents/Example_B012345678.kfx",
    trigger = "annotations_modified",
    desired = {
        { start = "/body/p[1].0", finish = "/body/p[1].8", note = "" },
        { start = "/body/p[2].3", finish = "/body/p[2].9", note = "private note" },
    },
}

local body = assert(Outbox.encode(snapshot, 42, 1000))
assert(not body:find("private note", 1, true), "serialized outbox must hex-encode annotation text")
local checksum = string.rep("a", 64)
local packed = assert(Outbox.pack(body, checksum))
local split_body, split_checksum = assert(Outbox.split(packed))
assert(split_body == body and split_checksum == checksum, "checksum envelope must round-trip")
local decoded = assert(Outbox.parse(split_body, snapshot.asin))
assert(decoded.sequence == 42 and decoded.created_at == 1000, "sequence metadata must round-trip")
assert(decoded.desired[2].note == "private note", "note must round-trip only after validated parsing")
assert(decoded.desired[1].start == snapshot.desired[1].start, "range must round-trip")

assert(not Outbox.parse(split_body, "B099999999"), "ASIN mismatch must be rejected")
assert(not Outbox.split(packed .. "extra=true\n"), "trailing fields must be rejected")
assert(not Outbox.parse(body .. "trigger=duplicate\n", snapshot.asin), "duplicate fields must be rejected")
assert(not Outbox.pack(body, string.rep("z", 64)), "non-hex checksum must be rejected")

-- Exercise the roadmap's 1,000 rapid latest-snapshot replacements at the pure
-- state boundary. Every sequence must decode exactly to the newest user intent.
for sequence = 1, 1000 do
    snapshot.desired[1].finish = "/body/p[1]." .. tostring(sequence)
    snapshot.desired[2].note = sequence % 3 == 0 and "edited note" or ""
    local encoded = assert(Outbox.encode(snapshot, sequence, 1000 + sequence))
    local current = assert(Outbox.parse(encoded, snapshot.asin))
    assert(current.sequence == sequence, "sequence must remain monotonic")
    assert(current.desired[1].finish == snapshot.desired[1].finish,
        "decoded snapshot must preserve newest range")
    assert(current.desired[2].note == snapshot.desired[2].note,
        "decoded snapshot must preserve newest note edit/removal")
end

print("Annotation outbox codec tests passed.")
