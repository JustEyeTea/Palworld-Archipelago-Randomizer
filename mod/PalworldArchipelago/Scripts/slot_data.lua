-- Slot data: what the APWorld sends this slot when it connects (fill_slot_data), read through the APConnector's
-- AP_SlotData as text. SLOT.KEYS lists every key the mod reads and what for, so one place says what the mod depends
-- on; the mod reads slot data only through SLOT.text, SLOT.flag and SLOT.number, which refuse a key not listed.
-- Tests: mod/test/tests/rules.lua, group "slot data" (tools/lua_harness.sh, in CI): every key is one the APWorld
-- sends, and no other file calls AP_SlotData.

local SLOT = {}

-- Key (as AP_SlotData takes it: "options.<option>" for one of the APWorld's SLOT_DATA_OPTIONS, else a top-level key
-- of fill_slot_data) -> what the mod does with it. `old` marks a key only seeds from an older APWorld send.
SLOT.KEYS = {
    ["slot"] = { use = "this player's slot number (connection.lua)" },
    ["seed"] = { use = "the seed's name, which the save file is kept under (connection.lua)" },
    ["research_techs"] = { use = "techs left as normal research, not checks (connection.lua, tech_lock.lua)" },
    ["beyond_goal_areas"] = { use = "locks whose pass is not in this seed (connection.lua)" },
    ["relics_needed"] = { use = "the relics that win the Relic Hunt goal, a count (checks.lua, items.lua)" },
    ["options.goal"] = { use = "which goal wins (checks.lua)" },
    ["options.tower_count"] = { use = "the towers the Towers goal needs (checks.lua)" },
    ["options.paldeck_count"] = { use = "the Pals the Paldeck goal needs (checks.lua)" },
    ["options.area_locks"] = { use = "whether walls go up (connection.lua; perf.lua times the read)" },
    ["options.lock_size"] = { use = "the 15 regions or the 75 areas (connection.lua)" },
    ["options.area_size"] = { use = "Lock Size under its old name (connection.lua)", old = true },
    ["options.beyond_goal"] = { use = "locked, passes or open beyond the goal (connection.lua)" },
    ["options.run_style"] = { use = "Standard or Nomad (run_style.lua)" },
    ["options.speed_boost"] = { use = "whether Speed Boost raises the world's speeds (run_style.lua)" },
    ["options.boost_exp_rate"] = { use = "Speed Boost's EXP multiplier (run_style.lua)" },
    ["options.boost_work_speed"] = { use = "Speed Boost's work speed multiplier (run_style.lua)" },
    ["options.boost_gather_rate"] = { use = "Speed Boost's gathering multiplier (run_style.lua)" },
    ["options.trap_chance"] = { use = "the share of filler items that are traps, for the log (connection.lua)" },
    ["options.death_link"] = { use = "whether Death Link is on (death_link.lua)" },
    ["options.death_link_amnesty"] = { use = "deaths forgiven before one is sent (death_link.lua)" },
    ["options.crate_sphere_weight"] = { use = "a crate kind's weight (items.lua, crates.lua WEIGHT_KEYS)" },
    ["options.crate_food_weight"] = { use = "a crate kind's weight (items.lua, crates.lua WEIGHT_KEYS)" },
    ["options.crate_common_weight"] = { use = "a crate kind's weight (items.lua, crates.lua WEIGHT_KEYS)" },
    ["options.crate_rare_weight"] = { use = "a crate kind's weight (items.lua, crates.lua WEIGHT_KEYS)" },
    ["options.crate_jackpot_weight"] = { use = "a crate kind's weight (items.lua, crates.lua WEIGHT_KEYS)" },
}

-- The text slot data holds for `key` ("" when it holds none). Raises an error for a key not in SLOT.KEYS.
function SLOT.text(key)
    if not SLOT.KEYS[key] then
        error("slot data key " .. tostring(key) .. " is not listed in slot_data.lua's SLOT.KEYS", 2)
    end
    return AP_SlotData(key)
end

-- Whether slot data's `key` is on: a flag arrives as "1" or "true".
function SLOT.flag(key)
    local text = SLOT.text(key)
    return text == "1" or text == "true"
end

-- Slot data's `key` as a number, or `default` when it holds none.
function SLOT.number(key, default)
    return tonumber(SLOT.text(key)) or default
end

return SLOT
