-- What the mod knows of the Archipelago session: the connection, the seed and slot, and the seed's progress (the ap
-- table), and how slot data is read. Every core file reads and writes the same table.
-- Tests: every group in mod/test/tests/ from "connect and receive" on (tools/lua_harness.sh, in CI).
local STATE = {}

-- Archipelago state. The server is the truth: on every connection it sends all items received so far and every
-- location already checked, so most of this is rebuilt each time. What it cannot send again (which one-off effects
-- were applied, the mailbox, the traps still to fire, the crates, the Death Link amnesty count, the seed's world and
-- more) is kept per seed and slot in a save file next to the mod; save.lua lists its lines.
--
-- State: the connection, ap.status. Forgotten: never (a new seed and a new world keep the connection).
--   disconnected -> connecting    the mod asked the connector to connect (the menu's connect), or the connector
--                                 says it is trying; the player can play, nothing is sent
--   connecting   -> connected     the server accepted the slot: checks are sent and items arrive
--   connecting   -> refused       the server said no; the player is told why, and the title menu shows it
--   any          -> disconnected  the connection dropped, or the player chose Disconnect
-- STATE.setStatus() is the only code that writes ap.status. ap.ready, ap.shopOpen and ap.connectedTick go with it.
--
-- Each field says when it is forgotten. "A new seed" is resetSeed in main.lua (STATE.forgetSeed); "each connection"
-- is main.lua's onConnected.
local ap = {
    status = "disconnected",  -- the connection's state, in the list above: forgotten never
    ready = false,        -- connected, and WAIT.firstItems has passed since (a fixed wait stands in for the first batch
                          -- of items): safe to lock techs. Forgotten on disconnecting and on a new seed
    shopOpen = false,     -- the seed is known this session: it has been ready once, or the world loaded offline is
                          -- the seed's (worlds.txt). Tech cards are shop slots from now on, also while disconnected
                          -- (cards keep their labels through reconnects). Forgotten on a new seed
    connectedTick = nil,  -- the update the last connection was accepted on (markReady's wait): forgotten never
    me = nil,             -- our slot number: set each connection
    seed = nil,           -- the seed whose progress is in memory: replaced when another seed connects, or offline
                          -- when another seed's world loads (CONNECTION.knowSeedOffline)
    checked = {},         -- location id -> true: forgotten on a new seed
    bought = {},          -- location id -> true: checks the mod sent itself (purchases, removed slots), not read
                          -- from the game's records; sent again on every connection and kept in the save file.
                          -- Forgotten on a new seed
    sent = {},            -- location id -> true: handed to the connector this connection, while connected (waiting
                          -- for the server to confirm). Forgotten each connection and on a new seed
    scouted = {},         -- location id -> { id, item, player, game, flags, own }: what a shop slot holds (id is the
                          -- item's id, which the shop reads). Rebuilt each connection, forgotten on a new seed
    items = {},           -- index -> item id, every item received: rebuilt each connection, forgotten on a new seed
    techs = {},           -- tech id -> true: unlocked by an item. Rebuilt each connection, forgotten on a new seed
    passes = {},          -- lock -> true: rebuilt each connection, forgotten on a new seed
    level = 0,            -- the player's level, as last read: forgotten never (read again every cycle)
    beaten = {},          -- tower boss type -> true: forgotten never (read again every cycle)
    given = -1,           -- highest item index whose one-off effect has been applied: in the save file, forgotten on
                          -- a new seed (items are numbered from 0)
    from = {},            -- index -> the player who sent a trap item (nil: found in our own world). Forgotten on a
                          -- new seed
    forgiven = 0,         -- own faints forgiven since a death was last sent (Death Link amnesty; in the save file).
                          -- Forgotten on a new seed
    visited = {},         -- lock -> true: open locks the player has stood in (the map's open stamps; in the save
                          -- file). Forgotten on a new seed (a new table: main.lua hands it to the walls again)
    goalSent = false,     -- sent on this connection (cleared on connecting, so a goal lost on the wire goes again).
                          -- Forgotten each connection and on a new seed
    goalShown = false,    -- the goal's banner and notice have been shown (once per seed; in the save file).
                          -- Forgotten on a new seed
    world = nil,          -- the world save this seed is played in (its folder name), kept in the save file.
                          -- Forgotten on a new seed
    slotName = nil,       -- the slot whose progress is in memory, set with the seed on connecting (names the save)
    beyond = {},          -- lock -> true: beyond the seed's goal (slot data beyond_goal_areas): set each connection
    beyondOpen = false,   -- those locks are open from the start (options.beyond_goal: open), else sealed for good:
                          -- set each connection
}
STATE.ap = ap

-- The connection's states (ap.status), each with what it means for the player (see the list above).
local STATUSES = { disconnected = true, connecting = true, connected = true, refused = true }

-- Moves the connection to `state`, one of STATUSES. The only writer of ap.status.
function STATE.setStatus(state)
    if not STATUSES[state] then
        error("unknown connection state: " .. tostring(state))
    end
    ap.status = state
end

-- Forgets the last seed's progress (a different seed or slot connected): every field above marked "forgotten on a
-- new seed". The save file of the new seed is read after this.
function STATE.forgetSeed()
    ap.checked, ap.sent, ap.scouted, ap.items, ap.techs, ap.passes = {}, {}, {}, {}, {}, {}
    ap.bought = {}
    ap.given, ap.goalSent, ap.ready, ap.shopOpen = -1, false, false, false     -- items are numbered from 0
    ap.goalShown = false
    ap.world = nil
    ap.from, ap.forgiven = {}, 0
    ap.visited = {}
end

return STATE
