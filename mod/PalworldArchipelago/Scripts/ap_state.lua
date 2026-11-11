-- What the mod knows of the Archipelago session: the connection, the seed and slot, and the seed's progress (the ap
-- table), and how slot data is read. Every core file reads and writes the same table.
-- Tests: mod/test/harness.lua (run by tools/lua_harness.sh): every group from "connect and receive" on.
local STATE = {}

-- Archipelago state. The server is the truth: on every connection it sends all items received so far and every
-- location already checked, so most of this is rebuilt each time. Only one-off effects (points, bundles, traps) need
-- memory: the index of the last item applied, the mailbox's contents, the traps still to fire and the Death Link amnesty
-- count, kept per seed and slot in a save file next to the mod.
local ap = {
    status = "disconnected",
    ready = false,        -- connected and the first batch of items is in: safe to lock techs
    shown = false,        -- the shop has been labelled at least once (cards keep their labels through reconnects)
    connectedTick = nil,
    me = nil,             -- our slot number
    seed = nil,
    checked = {},         -- location id -> true
    bought = {},          -- location id -> true: checks the mod sent itself (purchases, removed slots), not read
                          -- from the game's records; sent again on every connection and kept in the save file
    sent = {},            -- location id -> true: sent this session (waiting for the server to confirm)
    scouted = {},         -- location id -> { item, player, game, flags, own }
    items = {},           -- index -> item id, every item received
    techs = {},           -- tech id -> true: unlocked by an item
    passes = {},          -- area -> true
    level = 0,            -- the player's level, as last read
    beaten = {},          -- tower boss type -> true
    given = -1,           -- highest item index whose one-off effect has been applied
    from = {},            -- index -> the player who sent a trap item (nil: found in our own world)
    forgiven = 0,         -- own faints forgiven since a death was last sent (Death Link amnesty; in the save file)
    visited = {},         -- area -> true: open areas the player has stood in (the map's open stamps; in the save file)
    goalSent = false,     -- sent on this connection (cleared on connecting, so a goal lost on the wire goes again)
    goalShown = false,    -- the goal's banner and notice have been shown (once per seed; in the save file)
    world = nil,          -- the world save this seed is played in (its folder name), kept in the save file
    slotName = nil,       -- the slot whose progress is in memory, set with the seed on connecting (names the save)
    beyond = {},          -- area -> true: beyond the seed's goal (slot data beyond_goal_areas)
    beyondOpen = false,   -- those areas are open from the start (options.beyond_goal: open), else sealed for good
}
STATE.ap = ap

-- Slot data values arrive as text (AP_SlotData): a flag is "1" or "true", a number its digits.
function STATE.slotFlag(path)
    local v = AP_SlotData(path)
    return v == "1" or v == "true"
end
function STATE.slotNumber(path, default) return tonumber(AP_SlotData(path)) or default end

return STATE
