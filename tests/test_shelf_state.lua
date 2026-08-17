local project_root = assert(os.getenv("PROJECT_ROOT"), "PROJECT_ROOT is required")
local ShelfState = assert(dofile(
    project_root .. "/goodreads.koplugin/shelfstate.lua"))

assert(ShelfState.isSupported(ShelfState.ACTION_WANT_TO_READ))
assert(ShelfState.isSupported(ShelfState.ACTION_READING))
assert(ShelfState.isSupported(ShelfState.ACTION_READ))
assert(not ShelfState.isSupported("unsupported"))
assert(ShelfState.key(ShelfState.ACTION_WANT_TO_READ) == "want_to_read")

local state, stored = ShelfState.set(
    nil,
    "B000000001",
    ShelfState.ACTION_WANT_TO_READ,
    0.46,
    100)
assert(stored, "a valid explicit shelf choice must be stored")
assert(state.B000000001.baseline_percent == 46,
    "the durable baseline must be a whole percentage")

local action, changed, suppress = ShelfState.resolve(
    state, "B000000001", 0.46, ShelfState.ACTION_READING)
assert(action == ShelfState.ACTION_WANT_TO_READ,
    "an unchanged checkpoint must preserve explicit Want to Read")
assert(not changed, "an unchanged checkpoint must retain the override")
assert(suppress, "Want to Read must suppress contradictory percentage writes")

action, changed, suppress = ShelfState.resolve(
    state, "B000000001", 0.47, ShelfState.ACTION_READING)
assert(action == ShelfState.ACTION_READING,
    "new reading progress must resume automatic Currently Reading")
assert(changed and not suppress,
    "resumed progress must remove the old override and restore progress sync")
assert(state.B000000001 == nil, "the consumed override must be deleted")

state = assert((ShelfState.set(
    state, "B000000001", ShelfState.ACTION_WANT_TO_READ, 0.46, 101)))
action, changed = ShelfState.resolve(
    state, "B000000001", 0.46, ShelfState.ACTION_READ)
assert(action == ShelfState.ACTION_READ and changed,
    "explicit completion must supersede an unchanged Want to Read baseline")

state = assert((ShelfState.set(
    state, "B000000001", ShelfState.ACTION_READING, 0.01, 102)))
action, changed, suppress = ShelfState.resolve(
    state, "B000000001", 0.01, nil)
assert(action == ShelfState.ACTION_READING and not changed and not suppress,
    "a one-percent Currently Reading override must remain valid")

local oversized = {
    invalid = {
        action = ShelfState.ACTION_READ,
        baseline_percent = 100,
        set_at = 9999,
    },
    B999999999 = {
        action = "unsupported",
        baseline_percent = 50,
        set_at = 9999,
    },
}
for index = 1, 100 do
    oversized[string.format("B%09d", index)] = {
        action = ShelfState.ACTION_READING,
        baseline_percent = index % 101,
        set_at = index,
    }
end
local sanitized = ShelfState.sanitize(oversized)
local count = 0
for asin in pairs(sanitized) do
    count = count + 1
    assert(asin:match("^B[A-Z0-9]+$"), "only valid ASIN keys may survive")
end
assert(count == ShelfState.MAX_OVERRIDES,
    "durable explicit choices must remain bounded")
assert(sanitized.B000000100 ~= nil and sanitized.B000000001 == nil,
    "the newest bounded choices must win deterministically")

local unchanged, invalid_stored = ShelfState.set(
    sanitized, "invalid", ShelfState.ACTION_READ, 1, 200)
assert(not invalid_stored, "invalid identifiers must fail closed")
local unchanged_count = 0
for _ in pairs(unchanged) do unchanged_count = unchanged_count + 1 end
assert(unchanged_count == ShelfState.MAX_OVERRIDES,
    "a rejected write must not grow durable state")

print("Shelf state tests passed.")
