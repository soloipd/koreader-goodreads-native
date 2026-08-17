-- Durable policy for explicit Goodreads shelf choices.
--
-- The native bridge exposes only the three canonical Goodreads shelves. An
-- explicit choice temporarily wins over automatic progress-derived state until
-- the whole-number reading percentage changes. This prevents a periodic tick
-- from immediately undoing a user's choice while still allowing resumed
-- reading or a later completion to move the book naturally.

local ShelfState = {}

ShelfState.ACTION_READ = "com.amazon.home.actions.goodread_read"
ShelfState.ACTION_READING = "com.amazon.home.actions.goodread_reading"
ShelfState.ACTION_WANT_TO_READ = "com.amazon.home.actions.goodread_want_to_read"
ShelfState.MAX_OVERRIDES = 64

local ACTIONS = {
    [ShelfState.ACTION_READ] = "read",
    [ShelfState.ACTION_READING] = "currently_reading",
    [ShelfState.ACTION_WANT_TO_READ] = "want_to_read",
}

local function isAsin(value)
    return type(value) == "string"
        and value:match(
            "^B[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]"
                .. "[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]$"
        ) ~= nil
end

local function wholePercent(value)
    if type(value) ~= "number" or value ~= value then return nil end
    local percent = value
    if percent >= 0 and percent <= 1 then
        percent = percent * 100
    end
    percent = math.floor(percent + 0.5)
    if percent < 0 or percent > 100 then return nil end
    return percent
end

local function validTimestamp(value)
    return type(value) == "number"
        and value >= 1
        and value == math.floor(value)
end

local function validWholePercent(value)
    return type(value) == "number"
        and value >= 0
        and value <= 100
        and value == math.floor(value)
end

local function validOverride(asin, item)
    return isAsin(asin)
        and type(item) == "table"
        and ACTIONS[item.action] ~= nil
        and validWholePercent(item.baseline_percent)
        and validTimestamp(item.set_at)
end

function ShelfState.isSupported(action)
    return ACTIONS[action] ~= nil
end

function ShelfState.key(action)
    return ACTIONS[action]
end

function ShelfState.sanitize(value)
    local entries = {}
    if type(value) == "table" then
        for asin, item in pairs(value) do
            if validOverride(asin, item) then
                table.insert(entries, {
                    asin = asin,
                    action = item.action,
                    baseline_percent = item.baseline_percent,
                    set_at = item.set_at,
                })
            end
        end
    end

    table.sort(entries, function(left, right)
        if left.set_at == right.set_at then
            return left.asin < right.asin
        end
        return left.set_at > right.set_at
    end)

    local sanitized = {}
    for index = 1, math.min(#entries, ShelfState.MAX_OVERRIDES) do
        local entry = entries[index]
        sanitized[entry.asin] = {
            action = entry.action,
            baseline_percent = entry.baseline_percent,
            set_at = entry.set_at,
        }
    end
    return sanitized
end

function ShelfState.set(value, asin, action, percent, set_at)
    local baseline = wholePercent(percent)
    if not isAsin(asin)
        or not ShelfState.isSupported(action)
        or baseline == nil
        or not validTimestamp(set_at)
    then
        return ShelfState.sanitize(value), false
    end

    local updated = ShelfState.sanitize(value)
    updated[asin] = {
        action = action,
        baseline_percent = baseline,
        set_at = set_at,
    }
    return ShelfState.sanitize(updated), true
end

function ShelfState.resolve(value, asin, percent, automatic_action)
    if not isAsin(asin) then
        return automatic_action, false, false
    end
    local item = type(value) == "table" and value[asin] or nil
    if not validOverride(asin, item) then
        if type(value) == "table" then value[asin] = nil end
        return automatic_action, false, false
    end

    local current_percent = wholePercent(percent)
    local completed_now = automatic_action == ShelfState.ACTION_READ
        and item.action ~= ShelfState.ACTION_READ
    if current_percent == nil
        or current_percent ~= item.baseline_percent
        or completed_now
    then
        value[asin] = nil
        return automatic_action, true, false
    end

    local suppress_progress = item.action ~= ShelfState.ACTION_READING
    return item.action, false, suppress_progress
end

return ShelfState
