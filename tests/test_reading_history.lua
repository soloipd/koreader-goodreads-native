local project_root = assert(os.getenv("PROJECT_ROOT"), "PROJECT_ROOT is required")
local History = assert(dofile(
    project_root .. "/goodreads.koplugin/readinghistory.lua"))

local function at(day)
    return assert(os.time({
        year = 2026,
        month = 1,
        day = day,
        hour = 12,
        min = 0,
        sec = 0,
    }))
end

local asin = "B000000001"
local state = History.new()
assert(History.validate(state))

local changed, detail = History.record(state, asin, 0, "reading", at(1))
assert(not changed and detail == "no progress")
assert(state.sequence == 0 and state.books[asin] == nil,
    "opening at zero percent must not create a reading session")

assert(History.record(state, asin, 0.10, "reading", at(1)))
assert(state.sequence == 1)
assert(state.books[asin].sessions[1].start_bp == 1000)
assert(state.books[asin].sessions[1].outcome == "active")

changed, detail = History.record(state, asin, 0.10, "reading", at(1))
assert(not changed and detail == "unchanged" and state.sequence == 1,
    "an unchanged checkpoint must perform no durable write")

assert(History.record(state, asin, 0.99, "reading", at(2)))
assert(state.books[asin].sessions[1].outcome == "active",
    "99 percent must never be inferred as completion")
assert(state.books[asin].sessions[1].last_bp == 9900)

assert(History.record(state, asin, 0.99, "complete", at(2)))
assert(state.books[asin].sessions[1].outcome == "completed")
assert(state.books[asin].sessions[1].ended_at == at(2))

changed, detail = History.markCompleted(state, asin, 0.50, at(3))
assert(not changed and detail == "already completed")
assert(#state.books[asin].sessions == 1,
    "repeating Read at another position must not invent a completion")

changed, detail = History.record(state, asin, 0.99, "reading", at(3))
assert(not changed and detail == "ended session unchanged",
    "reopening an ended session at the same position must not invent a reread")

assert(History.record(state, asin, 0.20, "reading", at(3)))
assert(#state.books[asin].sessions == 2)
assert(state.books[asin].sessions[2].reason == "reread")
assert(History.record(state, asin, 0.40, "reading", at(4)))
assert(History.markDnf(state, asin, 0.40, at(4)))
assert(state.books[asin].sessions[2].outcome == "dnf")

assert(History.undoDnf(state, asin, at(5)))
assert(state.books[asin].sessions[2].outcome == "active")
assert(History.markDnf(state, asin, 0.40, at(5)))
assert(History.startReread(state, asin, 0.05, at(6)))
assert(#state.books[asin].sessions == 3)
assert(state.books[asin].sessions[3].reason == "manual")
assert(History.record(state, asin, 0.25, "reading", at(7)))

local before_stale = assert(History.encode(state))
changed, detail = History.record(state, asin, 0.30, "reading", at(6))
assert(not changed and detail == "stale checkpoint")
assert(History.encode(state) == before_stale,
    "a stale checkpoint must not mutate history")

assert(History.setAnnualGoal(state, 2026, 24))
local metrics = assert(History.metrics(state, at(7), asin))
assert(metrics.total_sessions == 3)
assert(metrics.completed_sessions == 1)
assert(metrics.dnf_sessions == 1)
assert(metrics.reread_sessions == 2)
assert(metrics.current_streak == 7 and metrics.longest_streak == 7)
assert(metrics.annual_completed == 1 and metrics.annual_goal == 24)
assert(metrics.annual_remaining == 23)
assert(metrics.current_session.ordinal == 3)
assert(metrics.current_session.active_days == 2)
assert(metrics.current_session.pace_percent_per_day == 10)
assert(metrics.current_session.projected_days == 8)

local body = assert(History.encode(state))
assert(body == History.encode(state), "history serialization must be deterministic")
assert(not body:find("title", 1, true)
        and not body:find("path", 1, true)
        and not body:find("note", 1, true),
    "durable history must contain no book or annotation text fields")

local checksum = string.rep("a", 64)
local packed = assert(History.pack(body, checksum))
local split_body, split_checksum = History.split(packed)
assert(split_body == body and split_checksum == checksum)
local decoded = assert(History.parse(split_body))
assert(History.encode(decoded) == body, "history codec must round-trip exactly")
assert(not History.split(packed .. "trailing"),
    "trailing bytes must invalidate the checksum envelope")
assert(not History.parse(body .. "unexpected=value\n"),
    "unknown durable fields must fail closed")
assert(not History.parse(body .. "sequence=1\n"),
    "duplicate durable fields must fail closed")
assert(not History.parse(body:gsub(
    "sequence=%d+", "sequence=" .. string.rep("9", 65), 1)),
    "oversized durable values must fail before numeric decoding")
assert(not History.parse(body .. "book.1000.asin=B000000099\n"),
    "out-of-capacity encoded indices must fail before table allocation")
assert(not History.parse(body .. string.rep("a", 193) .. "=1\n"),
    "oversized encoded lines must fail before table allocation")
assert(not History.parse(body:gsub(
    "book%.0%.session%.0%.day%.0=2026%-01%-01",
    "book.0.session.0.day.0=2026-02-31", 1)),
    "invalid calendar days must fail closed")

local csv = assert(History.toCSV(state))
local json = assert(History.toJSON(state, at(7)))
assert(csv:match("^asin,session_ordinal") and csv:match("B000000001,3,manual,active"))
assert(json:match('^%{"version":1')
        and json:match('"annual') == nil
        and json:match('"asin":"B000000001"')
        and json:match('"outcome":"dnf"'),
    "private JSON export must contain structured lifecycle facts only")
assert(not csv:find("private text", 1, true)
        and not json:find("private text", 1, true))

local capacity = History.new()
assert(History.record(capacity, asin, 0.01, "reading", at(1)))
assert(History.markDnf(capacity, asin, 0.01, at(1)))
for index = 2, History.MAX_SESSIONS_PER_BOOK do
    assert(History.startReread(capacity, asin, index / 100, at(1) + index))
    assert(History.markDnf(capacity, asin, index / 100, at(1) + index))
end
local capacity_body = assert(History.encode(capacity))
changed, detail = History.startReread(capacity, asin, 0.5, at(2))
assert(not changed and detail == "session capacity reached")
assert(History.encode(capacity) == capacity_body,
    "capacity rejection must not partially mutate state")

local stress = History.new()
assert(History.record(stress, "B000000002", 0.01, "reading", at(1)))
for index = 1, 1000 do
    local fraction = ((index % 98) + 1) / 100
    assert(History.record(
        stress, "B000000002", fraction, "reading", at(1) + index))
end
assert(History.validate(stress))
assert(#stress.books.B000000002.sessions[1].days == 1,
    "1,000 same-day checkpoints must not grow the day set")

print("Reading history tests passed.")
