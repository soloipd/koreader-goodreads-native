-- Private, bounded reading-lifecycle state for Goodreads Native Sync.
--
-- The state contains identifiers, timestamps, percentages, outcomes, and day
-- keys only. It deliberately stores no title, author, path, note, highlight,
-- account, device, or authentication-session data.

local History = {}

History.VERSION = 1
History.MAX_BOOKS = 1000
History.MAX_SESSIONS = 4096
History.MAX_SESSIONS_PER_BOOK = 32
History.MAX_DAY_ENTRIES = 20000
History.MAX_DAYS_PER_SESSION = 2000
History.MAX_BODY_BYTES = 4 * 1024 * 1024
History.MAX_ENCODED_FIELDS = 4 + (2 * 130) + (3 * History.MAX_BOOKS)
    + (10 * History.MAX_SESSIONS) + History.MAX_DAY_ENTRIES
History.MAX_ENCODED_LINE_BYTES = 192

local MAX_INTEGER = 9007199254740991
local MAX_TIMESTAMP = 4102444799 -- 2099-12-31; safe on the target firmware.
local OUTCOMES = { active = true, completed = true, dnf = true }
local REASONS = { initial = true, reread = true, manual = true }

local function isAsin(value)
    return type(value) == "string"
        and value:match(
            "^B[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]"
                .. "[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]$"
        ) ~= nil
end

local function integer(value, minimum, maximum)
    return type(value) == "number"
        and value == math.floor(value)
        and value >= minimum
        and value <= maximum
end

local function timestamp(value)
    return integer(value, 1, MAX_TIMESTAMP)
end

local function basisPoints(fraction)
    if type(fraction) ~= "number" or fraction ~= fraction
        or fraction < 0 or fraction > 1
    then
        return nil
    end
    return math.max(0, math.min(10000, math.floor(fraction * 10000 + 0.5)))
end

local function validDayKey(value)
    if type(value) ~= "string" then return false end
    local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    if not year or year < 1970 or year > 2099
        or month < 1 or month > 12 or day < 1 or day > 31
    then
        return false
    end
    local month_days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    local leap = year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
    if leap then month_days[2] = 29 end
    return day <= month_days[month]
end

local function dayKey(at)
    if not timestamp(at) then return nil end
    local ok, value = pcall(os.date, "%Y-%m-%d", at)
    return ok and validDayKey(value) and value or nil
end

local function julianDay(value)
    if not validDayKey(value) then return nil end
    local year, month, day = value:match("^(%d+)%-(%d+)%-(%d+)$")
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    local a = math.floor((14 - month) / 12)
    local y = year + 4800 - a
    local m = month + 12 * a - 3
    return day + math.floor((153 * m + 2) / 5) + 365 * y
        + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400)
        - 32045
end

local function addDay(session, key)
    if not validDayKey(key) then return false end
    local days = session.days
    if days[#days] == key then return false end
    for _, existing in ipairs(days) do
        if existing == key then return false end
    end
    if #days >= History.MAX_DAYS_PER_SESSION then return false end
    table.insert(days, key)
    table.sort(days)
    return true
end

local function countTable(value)
    local count = 0
    for _ in pairs(value or {}) do count = count + 1 end
    return count
end

local function sortedKeys(value)
    local keys = {}
    for key in pairs(value or {}) do table.insert(keys, key) end
    table.sort(keys)
    return keys
end

local function currentSession(book)
    local sessions = book and book.sessions or nil
    local session = sessions and sessions[#sessions] or nil
    return session and session.outcome == "active" and session or nil
end

local function latestSession(book)
    local sessions = book and book.sessions or nil
    return sessions and sessions[#sessions] or nil
end

local function totalCounts(state)
    local books, sessions, days = 0, 0, 0
    for _, book in pairs(state.books or {}) do
        books = books + 1
        sessions = sessions + #(book.sessions or {})
        for _, session in ipairs(book.sessions or {}) do
            days = days + #(session.days or {})
        end
    end
    return books, sessions, days
end

local function addStateDay(state, session, key)
    if not validDayKey(key) then return nil, "invalid reading date" end
    for _, existing in ipairs(session.days) do
        if existing == key then return false end
    end
    local _, _, day_count = totalCounts(state)
    if day_count >= History.MAX_DAY_ENTRIES
        or #session.days >= History.MAX_DAYS_PER_SESSION
    then
        return nil, "reading-day capacity reached"
    end
    return addDay(session, key)
end

function History.new()
    return {
        version = History.VERSION,
        sequence = 0,
        goals = {},
        books = {},
    }
end

function History.validate(state)
    if type(state) ~= "table" or state.version ~= History.VERSION
        or not integer(state.sequence, 0, MAX_INTEGER)
        or type(state.goals) ~= "table" or type(state.books) ~= "table"
    then
        return false, "invalid history envelope"
    end

    if countTable(state.goals) > 130 then
        return false, "too many annual goals"
    end
    for year, target in pairs(state.goals) do
        local numeric_year = tonumber(year)
        if type(year) ~= "string" or not year:match("^%d%d%d%d$")
            or not integer(numeric_year, 1970, 2099)
            or not integer(target, 1, 1000)
        then
            return false, "invalid annual goal"
        end
    end

    local book_count, session_count, day_count = 0, 0, 0
    for asin, book in pairs(state.books) do
        book_count = book_count + 1
        if not isAsin(asin) or type(book) ~= "table"
            or not timestamp(book.updated_at) or type(book.sessions) ~= "table"
            or #book.sessions < 1
            or #book.sessions > History.MAX_SESSIONS_PER_BOOK
        then
            return false, "invalid history book"
        end
        local previous_end = 0
        for index, session in ipairs(book.sessions) do
            session_count = session_count + 1
            if type(session) ~= "table" or session.ordinal ~= index
                or not REASONS[session.reason] or not OUTCOMES[session.outcome]
                or not timestamp(session.started_at)
                or not timestamp(session.last_at)
                or session.last_at < session.started_at
                or not integer(session.start_bp, 0, 10000)
                or not integer(session.last_bp, 0, 10000)
                or not integer(session.max_bp, 0, 10000)
                or session.max_bp < session.start_bp
                or session.max_bp < session.last_bp
                or type(session.days) ~= "table"
                or #session.days < 1
                or #session.days > History.MAX_DAYS_PER_SESSION
                or session.started_at < previous_end
            then
                return false, "invalid reading session"
            end
            if session.outcome == "active" then
                if session.ended_at ~= nil or index ~= #book.sessions then
                    return false, "invalid active session"
                end
            elseif not timestamp(session.ended_at)
                or session.ended_at < session.last_at
            then
                return false, "invalid ended session"
            else
                previous_end = session.ended_at
            end
            local previous_day
            for _, key in ipairs(session.days) do
                day_count = day_count + 1
                if not validDayKey(key) or (previous_day and key <= previous_day) then
                    return false, "invalid reading day"
                end
                previous_day = key
            end
        end
        local last = book.sessions[#book.sessions]
        local last_time = last.ended_at or last.last_at
        if book.updated_at < last_time then
            return false, "invalid book update time"
        end
    end
    if book_count > History.MAX_BOOKS or session_count > History.MAX_SESSIONS
        or day_count > History.MAX_DAY_ENTRIES
    then
        return false, "history exceeds safe bounds"
    end
    return true
end

local function beginSession(state, asin, bp, at, reason)
    local book = state.books[asin]
    local book_count, session_count, day_count = totalCounts(state)
    local key = dayKey(at)
    if not key then return nil, "invalid reading date" end
    if session_count >= History.MAX_SESSIONS
        or day_count >= History.MAX_DAY_ENTRIES
    then
        return nil, "session capacity reached"
    end
    if not book then
        if book_count >= History.MAX_BOOKS then return nil, "book capacity reached" end
        book = { updated_at = at, sessions = {} }
        state.books[asin] = book
    end
    if #book.sessions >= History.MAX_SESSIONS_PER_BOOK then
        return nil, "session capacity reached"
    end
    local latest = latestSession(book)
    if latest and at < (latest.ended_at or latest.last_at) then
        return nil, "stale session start"
    end
    local ordinal = #book.sessions + 1
    local session = {
        ordinal = ordinal,
        reason = ordinal == 1 and "initial" or (reason or "reread"),
        outcome = "active",
        started_at = at,
        start_bp = bp,
        last_at = at,
        last_bp = bp,
        max_bp = bp,
        ended_at = nil,
        days = { key },
    }
    table.insert(book.sessions, session)
    book.updated_at = at
    return session
end

local function commitChange(state, book, at)
    state.sequence = state.sequence + 1
    book.updated_at = math.max(book.updated_at or 0, at)
end

local function finalize(state, book, session, outcome, bp, at)
    if at < session.last_at then return false, "stale lifecycle action" end
    local day_added, day_error = addStateDay(state, session, dayKey(at))
    if day_added == nil then return false, day_error end
    session.last_at = at
    session.last_bp = bp
    session.max_bp = math.max(session.max_bp, bp)
    session.outcome = outcome
    session.ended_at = at
    commitChange(state, book, at)
    return true, outcome
end

function History.checkpointNeeded(state, asin, fraction, status)
    local valid = History.validate(state)
    local bp = basisPoints(fraction)
    if not valid or not isAsin(asin) or bp == nil then return true end
    status = status == "complete" and "complete"
        or status == "reading" and "reading" or "unknown"
    local book = state.books[asin]
    local active = currentSession(book)
    if active then
        return status == "complete" or bp ~= active.last_bp
    end
    local latest = latestSession(book)
    if latest then return status == "reading" and bp ~= latest.last_bp end
    return bp > 0 or status == "complete"
end

function History.record(state, asin, fraction, status, at)
    local valid, detail = History.validate(state)
    local bp = basisPoints(fraction)
    if not valid then return false, detail end
    if not isAsin(asin) or bp == nil or not timestamp(at) then
        return false, "invalid checkpoint"
    end
    status = status == "complete" and "complete"
        or status == "reading" and "reading" or "unknown"
    local book = state.books[asin]
    local active = currentSession(book)
    if active then
        if at < active.last_at then return false, "stale checkpoint" end
        local changed = bp ~= active.last_bp
        if changed then
            local day_added, day_error = addStateDay(state, active, dayKey(at))
            if day_added == nil then return false, day_error end
            active.last_at = at
            active.last_bp = bp
            active.max_bp = math.max(active.max_bp, bp)
        end
        if status == "complete" then
            return finalize(state, book, active, "completed", bp, at)
        end
        if changed then
            commitChange(state, book, at)
            return true, "progress"
        end
        return false, "unchanged"
    end

    local latest = latestSession(book)
    if latest then
        if status == "reading" and bp ~= latest.last_bp then
            local session, start_error = beginSession(state, asin, bp, at, "reread")
            if not session then return false, start_error end
            commitChange(state, state.books[asin], at)
            return true, "reread_started"
        end
        return false, "ended session unchanged"
    end
    if bp == 0 and status ~= "complete" then
        return false, "no progress"
    end
    local session, start_error = beginSession(state, asin, bp, at, "initial")
    if not session then return false, start_error end
    if status == "complete" then
        return finalize(state, state.books[asin], session, "completed", bp, at)
    end
    commitChange(state, state.books[asin], at)
    return true, "started"
end

function History.markCompleted(state, asin, fraction, at)
    local valid, detail = History.validate(state)
    local bp = basisPoints(fraction)
    if not valid then return false, detail end
    if not isAsin(asin) or bp == nil or not timestamp(at) then
        return false, "invalid completion"
    end
    local book = state.books[asin]
    local active = currentSession(book)
    if not active then
        local latest = latestSession(book)
        -- Repeating the explicit Read action is idempotent. A changed current
        -- position is not enough evidence to invent another completed session;
        -- a reread must first become active through reading or a manual action.
        if latest and latest.outcome == "completed" then
            return false, "already completed"
        end
        local start_error
        active, start_error = beginSession(
            state, asin, bp, at, latest and "manual" or "initial")
        if not active then return false, start_error end
        book = state.books[asin]
    end
    return finalize(state, book, active, "completed", bp, at)
end

function History.markDnf(state, asin, fraction, at)
    local valid, detail = History.validate(state)
    local bp = basisPoints(fraction)
    if not valid then return false, detail end
    if not isAsin(asin) or bp == nil or not timestamp(at) then
        return false, "invalid DNF"
    end
    local book = state.books[asin]
    local active = currentSession(book)
    if not active then
        local latest = latestSession(book)
        if latest then
            return false, latest.outcome == "dnf" and "already DNF"
                or "completed session requires a reread"
        end
        local start_error
        active, start_error = beginSession(state, asin, bp, at, "initial")
        if not active then return false, start_error end
        book = state.books[asin]
    end
    return finalize(state, book, active, "dnf", bp, at)
end

function History.undoDnf(state, asin, at)
    local valid, detail = History.validate(state)
    if not valid then return false, detail end
    if not isAsin(asin) or not timestamp(at) then return false, "invalid undo" end
    local book = state.books[asin]
    local latest = latestSession(book)
    if not latest or latest.outcome ~= "dnf" then return false, "no DNF to undo" end
    if at < latest.ended_at then return false, "stale lifecycle action" end
    local day_added, day_error = addStateDay(state, latest, dayKey(at))
    if day_added == nil then return false, day_error end
    latest.outcome = "active"
    latest.ended_at = nil
    latest.last_at = at
    commitChange(state, book, at)
    return true, "dnf_undone"
end

function History.startReread(state, asin, fraction, at)
    local valid, detail = History.validate(state)
    local bp = basisPoints(fraction)
    if not valid then return false, detail end
    if not isAsin(asin) or bp == nil or not timestamp(at) then
        return false, "invalid reread"
    end
    local book = state.books[asin]
    if not book or #book.sessions == 0 then
        return false, "no prior session"
    end
    if currentSession(book) then return false, "session already active" end
    local session, start_error = beginSession(state, asin, bp, at, "manual")
    if not session then return false, start_error end
    commitChange(state, book, at)
    return true, "reread_started"
end

function History.markReading(state, asin, fraction, at)
    local valid, detail = History.validate(state)
    local bp = basisPoints(fraction)
    if not valid then return false, detail end
    if not isAsin(asin) or bp == nil or not timestamp(at) then
        return false, "invalid reading start"
    end
    local book = state.books[asin]
    if currentSession(book) then return false, "session already active" end
    local latest = latestSession(book)
    local session, start_error = beginSession(
        state, asin, bp, at, latest and "manual" or "initial")
    if not session then return false, start_error end
    commitChange(state, state.books[asin], at)
    return true, latest and "reread_started" or "started"
end

function History.setAnnualGoal(state, year, target)
    local valid, detail = History.validate(state)
    year, target = tonumber(year), tonumber(target)
    if not valid then return false, detail end
    if not integer(year, 1970, 2099) or not integer(target, 0, 1000) then
        return false, "invalid annual goal"
    end
    local key = string.format("%04d", year)
    local previous = state.goals[key]
    if target == 0 then state.goals[key] = nil else state.goals[key] = target end
    if previous == state.goals[key] then return false, "unchanged" end
    state.sequence = state.sequence + 1
    return true, target == 0 and "goal_disabled" or "goal_updated"
end

local function percentString(bp)
    return string.format("%d.%02d", math.floor(bp / 100), bp % 100)
end

function History.metrics(state, now, current_asin)
    local valid, detail = History.validate(state)
    if not valid or not timestamp(now) then return nil, detail or "invalid time" end
    local unique_days = {}
    local stats = {
        total_sessions = 0,
        completed_sessions = 0,
        dnf_sessions = 0,
        reread_sessions = 0,
        current_streak = 0,
        longest_streak = 0,
    }
    local current_year = os.date("%Y", now)
    stats.annual_completed = 0
    stats.annual_goal = state.goals[current_year]
    for _, book in pairs(state.books) do
        for _, session in ipairs(book.sessions) do
            stats.total_sessions = stats.total_sessions + 1
            if session.ordinal > 1 then stats.reread_sessions = stats.reread_sessions + 1 end
            if session.outcome == "completed" then
                stats.completed_sessions = stats.completed_sessions + 1
                if os.date("%Y", session.ended_at) == current_year then
                    stats.annual_completed = stats.annual_completed + 1
                end
            elseif session.outcome == "dnf" then
                stats.dnf_sessions = stats.dnf_sessions + 1
            end
            for _, key in ipairs(session.days) do unique_days[key] = true end
        end
    end
    local serials = {}
    for key in pairs(unique_days) do table.insert(serials, julianDay(key)) end
    table.sort(serials)
    local run = 0
    local previous
    for _, serial in ipairs(serials) do
        run = previous and serial == previous + 1 and run + 1 or 1
        stats.longest_streak = math.max(stats.longest_streak, run)
        previous = serial
    end
    local today = julianDay(dayKey(now))
    if #serials > 0
        and (serials[#serials] == today or serials[#serials] == today - 1)
    then
        local expected = serials[#serials]
        for index = #serials, 1, -1 do
            if serials[index] ~= expected then break end
            stats.current_streak = stats.current_streak + 1
            expected = expected - 1
        end
    end
    if stats.annual_goal then
        stats.annual_remaining = math.max(
            0, stats.annual_goal - stats.annual_completed)
    end

    local book = isAsin(current_asin) and state.books[current_asin] or nil
    local active = currentSession(book)
    if active then
        local gained = math.max(0, active.max_bp - active.start_bp)
        local active_days = math.max(1, #active.days)
        local pace = gained / 100 / active_days
        stats.current_session = {
            ordinal = active.ordinal,
            started_at = active.started_at,
            last_percent = percentString(active.last_bp),
            max_percent = percentString(active.max_bp),
            active_days = #active.days,
            pace_percent_per_day = pace,
        }
        if pace > 0 and active.last_bp < 10000 then
            local remaining = (10000 - active.last_bp) / 100
            local projected_days = math.ceil(remaining / pace)
            stats.current_session.projected_days = projected_days
            stats.current_session.projected_at = math.min(
                MAX_TIMESTAMP, now + projected_days * 86400)
        end
    end
    return stats
end

function History.encode(state)
    local valid, detail = History.validate(state)
    if not valid then return nil, detail end
    local years = sortedKeys(state.goals)
    local asins = sortedKeys(state.books)
    local lines = {
        "history_version=" .. tostring(History.VERSION),
        "sequence=" .. tostring(state.sequence),
        "goal_count=" .. tostring(#years),
    }
    for index, year in ipairs(years) do
        local base = "goal." .. tostring(index - 1) .. "."
        table.insert(lines, base .. "year=" .. year)
        table.insert(lines, base .. "target=" .. tostring(state.goals[year]))
    end
    table.insert(lines, "book_count=" .. tostring(#asins))
    for book_index, asin in ipairs(asins) do
        local book = state.books[asin]
        local base = "book." .. tostring(book_index - 1) .. "."
        table.insert(lines, base .. "asin=" .. asin)
        table.insert(lines, base .. "updated_at=" .. tostring(book.updated_at))
        table.insert(lines, base .. "session_count=" .. tostring(#book.sessions))
        for session_index, session in ipairs(book.sessions) do
            local sb = base .. "session." .. tostring(session_index - 1) .. "."
            table.insert(lines, sb .. "ordinal=" .. tostring(session.ordinal))
            table.insert(lines, sb .. "reason=" .. session.reason)
            table.insert(lines, sb .. "outcome=" .. session.outcome)
            table.insert(lines, sb .. "started_at=" .. tostring(session.started_at))
            table.insert(lines, sb .. "start_bp=" .. tostring(session.start_bp))
            table.insert(lines, sb .. "last_at=" .. tostring(session.last_at))
            table.insert(lines, sb .. "last_bp=" .. tostring(session.last_bp))
            table.insert(lines, sb .. "max_bp=" .. tostring(session.max_bp))
            table.insert(lines, sb .. "ended_at=" .. tostring(session.ended_at or 0))
            table.insert(lines, sb .. "day_count=" .. tostring(#session.days))
            for day_index, key in ipairs(session.days) do
                table.insert(lines, sb .. "day." .. tostring(day_index - 1) .. "=" .. key)
            end
        end
    end
    local body = table.concat(lines, "\n") .. "\n"
    if #body > History.MAX_BODY_BYTES then return nil, "history body too large" end
    return body
end

function History.pack(body, checksum)
    if type(body) ~= "string" or #body > History.MAX_BODY_BYTES
        or body:sub(-1) ~= "\n" or body:find("\nchecksum=", 1, true)
        or type(checksum) ~= "string" or #checksum ~= 64
        or checksum:find("[^0-9a-f]")
    then
        return nil, "invalid history body or checksum"
    end
    return body .. "checksum=" .. checksum .. "\n"
end

function History.split(content)
    if type(content) ~= "string" or #content > History.MAX_BODY_BYTES + 80 then
        return nil, nil, "invalid history size"
    end
    local body, checksum = content:match("^(.*\n)checksum=([0-9a-f]+)\n$")
    if not body or #checksum ~= 64 or body:find("\nchecksum=", 1, true) then
        return nil, nil, "invalid history checksum envelope"
    end
    return body, checksum
end

local HEADER_FIELDS = {
    history_version = true,
    sequence = true,
    goal_count = true,
    book_count = true,
}

local BOOK_FIELDS = {
    asin = true,
    updated_at = true,
    session_count = true,
}

local SESSION_FIELDS = {
    ordinal = true,
    reason = true,
    outcome = true,
    started_at = true,
    start_bp = true,
    last_at = true,
    last_bp = true,
    max_bp = true,
    ended_at = true,
    day_count = true,
}

local function plausibleEncodedKey(key)
    if HEADER_FIELDS[key] then return true end

    local index, name = key:match("^goal%.(%d+)%.([a-z_]+)$")
    if index then
        return integer(tonumber(index), 0, 129)
            and (name == "year" or name == "target")
    end

    local book_index, session_index, day_index = key:match(
        "^book%.(%d+)%.session%.(%d+)%.day%.(%d+)$")
    if book_index then
        return integer(tonumber(book_index), 0, History.MAX_BOOKS - 1)
            and integer(
                tonumber(session_index), 0, History.MAX_SESSIONS_PER_BOOK - 1)
            and integer(tonumber(day_index), 0, History.MAX_DAYS_PER_SESSION - 1)
    end

    book_index, session_index, name = key:match(
        "^book%.(%d+)%.session%.(%d+)%.([a-z_]+)$")
    if book_index then
        return integer(tonumber(book_index), 0, History.MAX_BOOKS - 1)
            and integer(
                tonumber(session_index), 0, History.MAX_SESSIONS_PER_BOOK - 1)
            and SESSION_FIELDS[name] == true
    end

    book_index, name = key:match("^book%.(%d+)%.([a-z_]+)$")
    return book_index ~= nil
        and integer(tonumber(book_index), 0, History.MAX_BOOKS - 1)
        and BOOK_FIELDS[name] == true
end

function History.parse(body)
    if type(body) ~= "string" or #body > History.MAX_BODY_BYTES
        or body:sub(-1) ~= "\n"
    then
        return nil, "invalid history body"
    end
    local fields, field_count = {}, 0
    for line in body:gmatch("([^\n]*)\n") do
        local key, value = line:match("^([a-z0-9_.]+)=(.*)$")
        field_count = field_count + 1
        if #line > History.MAX_ENCODED_LINE_BYTES
            or field_count > History.MAX_ENCODED_FIELDS
            or not key or #key > 96 or #value > 64
            or not plausibleEncodedKey(key) or fields[key] ~= nil
        then
            return nil, "invalid or duplicate history field"
        end
        fields[key] = value
    end
    local sequence = tonumber(fields.sequence)
    local goal_count = tonumber(fields.goal_count)
    local book_count = tonumber(fields.book_count)
    if fields.history_version ~= tostring(History.VERSION)
        or not integer(sequence, 0, MAX_INTEGER)
        or not integer(goal_count, 0, 130)
        or not integer(book_count, 0, History.MAX_BOOKS)
    then
        return nil, "invalid history metadata"
    end
    local allowed = {
        history_version = true,
        sequence = true,
        goal_count = true,
        book_count = true,
    }
    local state = History.new()
    state.sequence = sequence
    local decoded_sessions, decoded_days = 0, 0
    for index = 0, goal_count - 1 do
        local base = "goal." .. tostring(index) .. "."
        local year_key, target_key = base .. "year", base .. "target"
        allowed[year_key], allowed[target_key] = true, true
        local year, target = fields[year_key], tonumber(fields[target_key])
        if type(year) ~= "string" or not year:match("^%d%d%d%d$")
            or not integer(tonumber(year), 1970, 2099)
            or not integer(target, 1, 1000) or state.goals[year]
        then
            return nil, "invalid encoded annual goal"
        end
        state.goals[year] = target
    end
    for book_index = 0, book_count - 1 do
        local base = "book." .. tostring(book_index) .. "."
        local asin_key = base .. "asin"
        local updated_key = base .. "updated_at"
        local count_key = base .. "session_count"
        allowed[asin_key], allowed[updated_key], allowed[count_key] = true, true, true
        local asin = fields[asin_key]
        local updated_at = tonumber(fields[updated_key])
        local session_count = tonumber(fields[count_key])
        if not isAsin(asin) or state.books[asin] or not timestamp(updated_at)
            or not integer(session_count, 1, History.MAX_SESSIONS_PER_BOOK)
        then
            return nil, "invalid encoded book"
        end
        decoded_sessions = decoded_sessions + session_count
        if decoded_sessions > History.MAX_SESSIONS then
            return nil, "encoded history exceeds session capacity"
        end
        local book = { updated_at = updated_at, sessions = {} }
        state.books[asin] = book
        for session_index = 0, session_count - 1 do
            local sb = base .. "session." .. tostring(session_index) .. "."
            local names = {
                "ordinal", "reason", "outcome", "started_at", "start_bp",
                "last_at", "last_bp", "max_bp", "ended_at", "day_count",
            }
            for _, name in ipairs(names) do allowed[sb .. name] = true end
            local day_count = tonumber(fields[sb .. "day_count"])
            if not integer(day_count, 1, History.MAX_DAYS_PER_SESSION) then
                return nil, "invalid encoded day count"
            end
            decoded_days = decoded_days + day_count
            if decoded_days > History.MAX_DAY_ENTRIES then
                return nil, "encoded history exceeds day capacity"
            end
            local session = {
                ordinal = tonumber(fields[sb .. "ordinal"]),
                reason = fields[sb .. "reason"],
                outcome = fields[sb .. "outcome"],
                started_at = tonumber(fields[sb .. "started_at"]),
                start_bp = tonumber(fields[sb .. "start_bp"]),
                last_at = tonumber(fields[sb .. "last_at"]),
                last_bp = tonumber(fields[sb .. "last_bp"]),
                max_bp = tonumber(fields[sb .. "max_bp"]),
                ended_at = tonumber(fields[sb .. "ended_at"]),
                days = {},
            }
            if session.ended_at == 0 then session.ended_at = nil end
            for day_index = 0, day_count - 1 do
                local key = sb .. "day." .. tostring(day_index)
                allowed[key] = true
                table.insert(session.days, fields[key])
            end
            table.insert(book.sessions, session)
        end
    end
    for key in pairs(fields) do
        if not allowed[key] then return nil, "unexpected history field" end
    end
    local valid, detail = History.validate(state)
    if not valid then return nil, detail end
    return state
end

function History.toCSV(state)
    local valid, detail = History.validate(state)
    if not valid then return nil, detail end
    local lines = {
        "asin,session_ordinal,reason,outcome,started_at,ended_at,start_percent,last_percent,max_percent,active_days",
    }
    for _, asin in ipairs(sortedKeys(state.books)) do
        for _, session in ipairs(state.books[asin].sessions) do
            table.insert(lines, table.concat({
                asin,
                tostring(session.ordinal),
                session.reason,
                session.outcome,
                tostring(session.started_at),
                tostring(session.ended_at or ""),
                percentString(session.start_bp),
                percentString(session.last_bp),
                percentString(session.max_bp),
                tostring(#session.days),
            }, ","))
        end
    end
    return table.concat(lines, "\n") .. "\n"
end

function History.toJSON(state, generated_at)
    local valid, detail = History.validate(state)
    if not valid or not timestamp(generated_at) then
        return nil, detail or "invalid export time"
    end
    local parts = {
        '{"version":', tostring(History.VERSION),
        ',"generated_at":', tostring(generated_at), ',"goals":{',
    }
    local years = sortedKeys(state.goals)
    for index, year in ipairs(years) do
        if index > 1 then table.insert(parts, ",") end
        table.insert(parts, string.format('"%s":%d', year, state.goals[year]))
    end
    table.insert(parts, '},"books":[')
    for book_index, asin in ipairs(sortedKeys(state.books)) do
        if book_index > 1 then table.insert(parts, ",") end
        table.insert(parts, string.format('{"asin":"%s","sessions":[', asin))
        for session_index, session in ipairs(state.books[asin].sessions) do
            if session_index > 1 then table.insert(parts, ",") end
            table.insert(parts, string.format(
                '{"ordinal":%d,"reason":"%s","outcome":"%s",'
                    .. '"started_at":%d,"ended_at":%s,"start_percent":%s,'
                    .. '"last_percent":%s,"max_percent":%s,"days":[',
                session.ordinal, session.reason, session.outcome,
                session.started_at, session.ended_at and tostring(session.ended_at) or "null",
                percentString(session.start_bp), percentString(session.last_bp),
                percentString(session.max_bp)))
            for day_index, key in ipairs(session.days) do
                if day_index > 1 then table.insert(parts, ",") end
                table.insert(parts, string.format('"%s"', key))
            end
            table.insert(parts, "]}")
        end
        table.insert(parts, "]}")
    end
    table.insert(parts, "]}\n")
    return table.concat(parts)
end

return History
