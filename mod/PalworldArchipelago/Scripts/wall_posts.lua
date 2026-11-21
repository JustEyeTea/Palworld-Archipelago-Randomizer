-- Corner posts: the art pak's SM_APWallPost (the Art lane's paw post) in M_APWallPost, standing where wall pieces meet
-- at a bend or a border ends, hiding the wedge where their see-through boxes overlap and the pattern showed twice.
-- tools/wall_posts.py places them in the walls files (posts: x, y, yaw, pieces). A post stands while any piece it
-- touches is raised or still opening, is shown and hidden by distance as the pieces are, and stands in the colour its
-- first piece's wall wears. Only while the walls wear a skin on the pak's M_APWall (paws, regions), and only with the
-- pak's post: without it, none, said once. Visual only: no collision.
-- A part of walls.lua, loaded fresh for each copy of walls.lua.
-- Tests: mod/test/tests/wall_posts.lua (tools/lua_harness.sh, in CI).
local WALL_POSTS = {}
local UTIL = require("util")
local MESH_ACTORS = require("mesh_actors")
local log = UTIL.log

local ART_FOLDER = "/Game/Mods/PalworldArchipelagoArt/"
local MESH, MATERIAL = "SM_APWallPost", "M_APWallPost"     -- logicmod/make_wall_post.py makes them
local POST_CM = 100           -- the post mesh's height at scale 1 (the Art lane's FBX): scaled up to the walls' height
local NEVER_CULLED = true     -- MESH_ACTORS.spawn: 3 km tall, a post's middle is far past the game's 50 m cull distance
local WALK_PER_TICK = 80      -- posts looked at an update: the 75 areas' 1,157 in 15 updates (4.5 s)
local SPAWNS_PER_TICK = 30    -- posts raised an update at most, as the walls' PER_TICK, to spread the work
-- M_APWallPost's parameters the mod sets (logicmod/make_wall_post.py's list; change both): the rest keep the
-- material's own defaults (its layer, CellSize, Brightness, the glow's radius, strength and colour).
local BACK, FADE_START, FADE_END, PLAYER_POS = "Back", "FadeStart", "FadeEnd", "PlayerPos"
-- The posts' report (report): after a world's FIRST_REPORT_WALK-th full walk (about 18 s for the 75 areas: the walls
-- are up by then), then every REPORT_EVERY_WALKS walks (about 45 s), at most REPORTS_LOGGED a session: enough to tell
-- a post never raised from one raised but not seen.
local FIRST_REPORT_WALK = 4
local REPORT_EVERY_WALKS = 10
local REPORTS_LOGGED = 12
local DRAWN_WITHIN_S = 0.5    -- WasRecentlyRendered's tolerance: drawn in the last half second counts as drawn
local CM_PER_M = 100
-- The test key's tries (Ctrl+Shift+F4, test_tools.lua), to find what keeps the posts from being drawn: "post" as made;
-- "grid", the engine's grid material in place of M_APWallPost (is it the material?); "short", the grid material and
-- SHORT_CM tall from the player's feet (is it their 3 km height, their foot 1 km down?).
local TRIES = { "post", "grid", "short" }
local GRID_MATERIAL = "/Engine/EngineMaterials/WorldGridMaterial.WorldGridMaterial"
local SHORT_CM = 1000             -- the "short" try's height: 10 m, well above the player
local FEET_BELOW_MIDDLE_CM = 200  -- its foot this far below the player's middle: just under the ground they stand on

-- Handed over by install: W (radius, fade, keepInPlace), the cut's layout, walls.lua's pieces (raised, opening),
-- WALL_SKINS (backOf, glowSpot, modAsset, MID_FLAGS) and walls.lua's sizes (HEIGHT_CM, MID_Z_CM, HIDE_MARGIN).
local W, layout, pieces, WALL_SKINS, sizes = nil, nil, nil, nil, nil
-- State: the posts up. Forgotten: those of a world that is gone (reset), all at a change of cut (takeAllDown) and in
-- the perf probe's "none" state.
local up = {}                 -- post index -> its actor
local upAt = {}               -- post index -> its actor's address, to tell it is still there without calling it
local wears = {}              -- post index -> the colour (hex) it wears
local hidden = {}             -- post index -> true while hidden by distance
local walkAt = 0              -- the post the walk looks at next (wraps round)
local walks = 0               -- full walks over the posts in this world (reset), for the report's schedule
local reports = 0             -- reports logged this session
local try = "post"            -- the test key's try (TRIES); "post" but for a test
-- State: what the posts are made of. Forgotten: looks and their spot told at a world change (reset: a dead material
-- called crashed the game, as wall_skins.lua says); assets never once found, or once found missing (the pak is
-- mounted at start-up or not at all).
local assets = nil            -- { mesh, material } once found; false when the pak has no post
local looks = {}              -- colour (hex) -> its M_APWallPost instance in this world
local keptAt = {}             -- colour (hex) -> its place in the kept objects (W.keepInPlace)
local spotTold = nil          -- the player's spot last told to the looks (PlayerPos)

-- The pak's post mesh and material, looked up once; false (said once) when the pak has none.
local function postAssets()
    if assets ~= nil then return assets end
    local mesh = WALL_SKINS.modAsset(ART_FOLDER .. MESH, MESH, {})
    local material = WALL_SKINS.modAsset(ART_FOLDER .. MATERIAL, MATERIAL, {})
    if not (mesh and material) then
        assets = false
        log("wall posts: none this session: the PalworldArchipelagoArt pak has no "
            .. ((mesh and MATERIAL) or (material and MESH) or (MESH .. ", " .. MATERIAL)))
        return false
    end
    W.keepAlive(mesh)
    W.keepAlive(material)
    assets = { mesh = mesh, material = material }
    log("wall posts: " .. MESH .. " and " .. MATERIAL .. " found")
    return assets
end

-- The post look in colour `hex` in this world: an M_APWallPost instance with that Back and the walls' fade, made on
-- first use and kept; or nil and why not.
local function lookIn(hex)
    if looks[hex] then return looks[hex] end
    local gameInstance = UTIL.gameInstance()
    local library = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
    if not gameInstance then return nil, "no game instance to own its look" end
    if not UTIL.isValid(library) then return nil, "no KismetMaterialLibrary to make its look" end
    local look = library:CreateDynamicMaterialInstance(gameInstance, assets.material, FName("None"),
        WALL_SKINS.MID_FLAGS)
    if not UTIL.isValid(look) then return nil, "CreateDynamicMaterialInstance gave no look" end
    look:SetVectorParameterValue(FName(BACK), UTIL.linear(hex))
    look:SetScalarParameterValue(FName(FADE_START), W.fade[1])
    look:SetScalarParameterValue(FName(FADE_END), W.fade[2])
    keptAt[hex] = W.keepInPlace(keptAt[hex], look)
    looks[hex] = look
    return look
end

-- Whether post k is wanted: any piece it touches is raised or still opening (opening: walls.lua's list of pieces on
-- their way down, by index).
local function wanted(post, openingNow)
    local raised = pieces.raised()
    for _, i in ipairs(post.pieces) do
        if raised[i] or openingNow[i] then return true end
    end
    return false
end

-- The look a post goes up in: its M_APWallPost look in colour hex, or the engine's grid material for the test key's
-- tries; or nil and why not.
local function raiseLook(hex)
    if try == "post" then return lookIn(hex) end
    local grid = StaticFindObject(GRID_MATERIAL)
    if UTIL.isValid(grid) then return grid end
    return nil, "no " .. GRID_MATERIAL
end

-- Where a post's foot stands and how tall it is (cm): at the walls' foot, as tall as they are; for the "short" try,
-- SHORT_CM from just under the player's feet.
local function postSpan(ctx)
    if try == "short" and ctx.pz then return ctx.pz - FEET_BELOW_MIDDLE_CM, SHORT_CM end
    return sizes.MID_Z_CM - sizes.HEIGHT_CM / 2, sizes.HEIGHT_CM
end

-- Raises post k in colour hex: the pak's post, turned by its yaw, its base at the walls' foot, as tall as they are.
-- True when it went up.
local function raise(k, hex, ctx)
    local post = layout.posts[k]
    local look, lookWhy = raiseLook(hex)
    if not look then
        UTIL.onceErr("wall posts look", lookWhy, "wall posts: could not raise post " .. k .. ": " .. tostring(lookWhy))
        return false
    end
    local yaw, foot, tall = math.rad(post.yaw), postSpan(ctx)
    local t = { Rotation = { X = 0, Y = 0, Z = math.sin(yaw / 2), W = math.cos(yaw / 2) },
                Translation = { X = post.x, Y = post.y, Z = foot },
                Scale3D = { X = 1, Y = 1, Z = tall / POST_CM } }
    local actor, why = MESH_ACTORS.spawn(ctx.pawn, assets.mesh, look, t, NEVER_CULLED)
    if not actor then
        UTIL.onceErr("wall posts raise", why, "wall posts: could not raise post " .. k .. ": " .. tostring(why))
        return false
    end
    up[k], upAt[k], wears[k], hidden[k] = actor, UTIL.addr(actor), hex, nil
    return true
end

-- Takes post k down (destroyed, if the game still has it) and forgets it.
local function takeDown(k)
    local actor = up[k]
    up[k], upAt[k], wears[k], hidden[k] = nil, nil, nil, nil
    if actor then pcall(function() if actor:IsValid() then actor:K2_DestroyActor() end end) end
end

-- Shows post k near the player and hides it far off, as the pieces (within W.radius; hidden past it plus the
-- margin; between, as it was). px nil (no position) or W.radius 0: shown.
local function showOrHide(k, px, py)
    local post, actor = layout.posts[k], up[k]
    local d = px and math.sqrt((post.x - px) ^ 2 + (post.y - py) ^ 2)
    local hide = (d and W.radius > 0 and d > W.radius + sizes.HIDE_MARGIN) and true or nil
    if d and not hide and hidden[k] and d > W.radius then hide = true end
    if hide ~= hidden[k] and actor:IsValid() then
        pcall(function() actor:SetActorHiddenInGame(hide == true) end)
        hidden[k] = hide
    end
end

-- Puts post k (up) in the look of colour hex: a recolour, or a new look after the last world's looks were let go.
local function redress(k, hex)
    local look, lookWhy = lookIn(hex)
    if not look then
        UTIL.onceErr("wall posts look", lookWhy, "wall posts: could not dress post " .. k .. ": " .. tostring(lookWhy))
        return
    end
    local ok, err = pcall(function() up[k].StaticMeshComponent:SetMaterial(0, look) end)
    if ok then
        wears[k] = hex
    else
        UTIL.onceErr("wall posts dress", err, "wall posts: could not dress post " .. k .. ": " .. tostring(err))
    end
end

-- One post looked at: forgotten if the game removed it, raised, taken down, put in its colour, shown or hidden.
-- Returns how many spawns it used.
local function lookAt(k, ctx)
    if up[k] and not up[k]:IsValid() then
        up[k], upAt[k], wears[k], hidden[k] = nil, nil, nil, nil
    end
    local post = layout.posts[k]
    local hex = wanted(post, ctx.opening) and WALL_SKINS.backOf(post.pieces[1], ctx.passes) or nil
    if not up[k] then
        return (hex and ctx.spawns > 0 and raise(k, hex, ctx)) and 1 or 0
    end
    if not hex then
        takeDown(k)
        return 0
    end
    if hex ~= wears[k] and try == "post" then redress(k, hex) end
    showOrHide(k, ctx.px, ctx.py)
    return 0
end

-- The PlayerPos the walls' glow last used (WALL_SKINS.glowSpot), told to this world's post looks when it moved.
local function tellSpot()
    local spot = WALL_SKINS.glowSpot()
    if not spot or spot == spotTold then return end
    spotTold = spot
    for _, look in pairs(looks) do
        look:SetVectorParameterValue(FName(PLAYER_POS), spot)
    end
end

-- The post nearest (px, py) and how far it is in metres; nil without a position.
local function nearestPost(px, py)
    if not px then return nil end
    local best, bestD2 = nil, math.huge
    for k, post in ipairs(layout.posts) do
        local d2 = (post.x - px) ^ 2 + (post.y - py) ^ 2
        if d2 < bestD2 then best, bestD2 = k, d2 end
    end
    return best, math.sqrt(bestD2) / CM_PER_M
end

-- A call's result made into text for the report, or "?" when the call fails or gives nothing.
local function asText(fn)
    local ok, text = pcall(fn)
    return (ok and text ~= nil) and tostring(text) or "?"
end

-- A vector as "x, y, z" in whole units, for the report.
local function xyz(v) return string.format("%.0f, %.0f, %.0f", v.X, v.Y, v.Z) end

-- Whether the engine drew an actor in the last DRAWN_WITHIN_S: "yes", "no" or "?".
local function drawnLately(actor)
    return asText(function() return actor:WasRecentlyRendered(DRAWN_WITHIN_S) and "yes" or "no" end)
end

-- What the game says of post k's actor: where it stands, its scale, its mesh's corners, its material, whether it is
-- hidden and whether the engine drew it lately.
local function actorFacts(k)
    local actor = up[k]
    local at = asText(function() return xyz(actor:K2_GetActorLocation()) end)
    local scale = asText(function() return xyz(actor:GetActorScale3D()) end)
    local box = asText(function()
        local b = assets.mesh:GetBoundingBox()
        return xyz(b.Min) .. " to " .. xyz(b.Max)
    end)
    local material = asText(function() return UTIL.objectPath(actor.StaticMeshComponent:GetMaterial(0)) end)
    return string.format("up in %s, at (%s) cm, scale (%s), mesh (%s) cm, material %s, hidden %s (the game's %s), drawn"
        .. " lately %s", tostring(wears[k]), at, scale, box, material, hidden[k] and "yes" or "no",
        asText(function() return actor.bHidden end), drawnLately(actor))
end

-- What the game says of post k's mesh component: shown or not, and the draw distances that could cull it.
local function componentFacts(k)
    local c = up[k].StaticMeshComponent
    local function field(name) return asText(function() return c[name] end) end
    return string.format("its mesh component: visible %s, hidden in game %s, max draw distance %s (cached %s), min"
        .. " draw distance %s, bounds scale %s, never distance culled %s, cull distance volume %s", field("bVisible"),
        field("bHiddenInGame"), field("LDMaxDrawDistance"), field("CachedMaxDrawDistance"), field("MinDrawDistance"),
        field("BoundsScale"), field("bNeverDistanceCull"), field("bAllowCullDistanceVolume"))
end

-- The wall piece standing nearest (px, py), and whether the engine drew it lately: the report's control, a piece
-- the player can see.
local function nearestPieceFacts(px, py)
    local best, bestD2 = nil, math.huge
    for i, actor in pairs(pieces.raised()) do
        local wall = layout.walls[i]
        local d2 = (wall.x - px) ^ 2 + (wall.y - py) ^ 2
        if d2 < bestD2 and actor then best, bestD2 = i, d2 end
    end
    if not best then return "no wall piece standing" end
    return string.format("the nearest wall piece, %d, %.0f m away: drawn lately %s", best,
        math.sqrt(bestD2) / CM_PER_M, drawnLately(pieces.raised()[best]))
end

-- Logs the posts' report: how many are up and hidden by distance, and the nearest post as the game has it.
local function report(ctx)
    if reports >= REPORTS_LOGGED then return end
    reports = reports + 1
    local upN, hiddenN = 0, 0
    for k in pairs(up) do
        upN = upN + 1
        if hidden[k] then hiddenN = hiddenN + 1 end
    end
    local k, metres = nearestPost(ctx.px, ctx.py)
    local nearest = "no player position"
    if k then
        local state = up[k] and (actorFacts(k) .. "; " .. componentFacts(k))
            or ("not up (" .. (wanted(layout.posts[k], ctx.opening) and "wanted" or "not wanted") .. ")")
        nearest = string.format("the nearest, post %d, %.0f m away: %s; %s", k, metres, state,
            nearestPieceFacts(ctx.px, ctx.py))
    end
    log(string.format("wall posts: try %s: %d of %d up, %d hidden by distance; %s (report %d; the first %d are"
        .. " logged)", try, upN, #layout.posts, hiddenN, nearest, reports, REPORTS_LOGGED))
end

-- One update's share of the walk: WALK_PER_TICK posts looked at; the report after each full walk that is due.
local function walk(ctx)
    local n = #layout.posts
    for _ = 1, math.min(WALK_PER_TICK, n) do
        walkAt = walkAt % n + 1
        ctx.spawns = ctx.spawns - lookAt(walkAt, ctx)
        if walkAt == n then
            walks = walks + 1
            if UTIL.isDue(walks, REPORT_EVERY_WALKS, FIRST_REPORT_WALK) then report(ctx) end
        end
    end
end

-- Each walls update, after the pieces: WALK_PER_TICK posts looked at (at most SPAWNS_PER_TICK raised), and the
-- player's spot told to the looks. Nothing without the pak's post, a cut without posts, or before the spawning library
-- is found (MESH_ACTORS.ready: the glows may not have looked for it yet).
function WALL_POSTS.update(passes, pawn)
    if not (layout.posts and #layout.posts > 0) or not postAssets() then return end
    if not MESH_ACTORS.ready() then
        UTIL.once("wall posts wait", "wall posts: waiting for GameplayStatics and the StaticMeshActor class")
        return
    end
    local openingNow = {}
    for _, s in ipairs(pieces.opening()) do
        if s.index then openingNow[s.index] = true end
    end
    local okL, loc = pcall(function() return pawn:K2_GetActorLocation() end)
    local ctx = { passes = passes or {}, pawn = pawn, opening = openingNow, spawns = SPAWNS_PER_TICK,
                  px = okL and loc and loc.X or nil, py = okL and loc and loc.Y or nil,
                  pz = okL and loc and loc.Z or nil }
    walk(ctx)
    tellSpot()
end

-- A new world (or the pawn changed): posts the game no longer has are forgotten without a call; the looks are let go,
-- never called again, and made anew when next needed.
function WALL_POSTS.reset()
    local live = MESH_ACTORS.liveAddresses()
    for k in pairs(up) do
        if not live[upAt[k]] then
            up[k], upAt[k], wears[k], hidden[k] = nil, nil, nil, nil
        end
    end
    looks, spotTold, walks = {}, nil, 0
    for k in pairs(up) do wears[k] = nil end      -- (their looks are let go: each is put in a new one when looked at)
end

-- Every post taken down (a change of cut: the post numbers mean other posts; the perf probe's "none").
function WALL_POSTS.takeAllDown()
    for k in pairs(up) do takeDown(k) end
    walkAt = 0
end

-- The test key (Ctrl+Shift+F4): the next of TRIES, every post taken down to go up again in it (within about 15 s for
-- the 75 areas' posts), and a report FIRST_REPORT_WALK walks later, once they are up. Returns the try's name.
function WALL_POSTS.nextTry()
    local at = 1
    for i, name in ipairs(TRIES) do
        if name == try then at = i end
    end
    try = TRIES[at % #TRIES + 1]
    WALL_POSTS.takeAllDown()
    walks, reports = 0, math.min(reports, REPORTS_LOGGED - 1)    -- (each press gets its report)
    return try
end

-- The perf probe's test states (walls.lua's W.perfMode): "none" takes every post down, "hidden" hides them, any other
-- shows them again.
function WALL_POSTS.perfMode(mode)
    if mode == "none" then
        WALL_POSTS.takeAllDown()
        return
    end
    for k, actor in pairs(up) do
        if actor:IsValid() then pcall(function() actor:SetActorHiddenInGame(mode == "hidden") end) end
        hidden[k] = mode == "hidden" or nil
    end
end

-- How many posts are up now (the harness's and the log's count).
function WALL_POSTS.count()
    local n = 0
    for _ in pairs(up) do n = n + 1 end
    return n
end

-- Hands over what this part reads (see the top of the file).
function WALL_POSTS.install(env)
    W, layout, pieces, WALL_SKINS, sizes = env.W, env.locks.layout, env.pieces, env.skins, env.sizes
end

return WALL_POSTS
