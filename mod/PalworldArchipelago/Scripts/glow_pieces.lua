-- Glow pieces: what the check glow (glow_checks.lua) and the item-arrival burst (glow_burst.lua) are made of. The
-- PalworldArchipelagoArt pak's glow meshes and textures and its M_APGlow material (logicmod/make_glow_assets.py), the
-- looks made from that material, and plain engine StaticMeshActors wearing them (movable, no collision, no shadow).
-- Also the switch in config.txt (glow=0 turns both glows off) and forgetting every piece at a world change. The
-- glows are visual only: nothing here changes the game.
-- Tests: mod/test/tests/glow.lua; groups "the item-arrival burst", "the check glow" (tools/lua_harness.sh, in CI).
local GLOW_PIECES = {}
local CONFIG = require("config")
local PLAYER = require("player")
local UTIL = require("util")
local WALL_SKINS = require("wall_skins")    -- (modAsset: how a pak asset is loaded; MID_FLAGS)
local WALLS = require("walls")              -- (SPAWN_ALWAYS)
local log = UTIL.log
local once = UTIL.onceIn("glow")

local ART_FOLDER = "/Game/Mods/PalworldArchipelagoArt/"
-- The pak's glow meshes and textures, each by the part it is for (logicmod/art/glow/glow-spec.txt describes them).
local PARTS = { "ring", "beam", "sprite", "shock", "column", "twinkle" }
local MESH_PREFIX, TEXTURE_PREFIX = "SM_APGlow", "T_APGlow"     -- SM_APGlowRing, T_APGlowRing ...
local MATERIAL = "M_APGlow"
-- M_APGlow's parameters, by the field of a look that sets each (GLOW_PIECES.look). A copy of the list in
-- logicmod/make_glow_assets.py's docstring, which makes them: a name changed there is changed here.
local SCALARS = {
    brightness = "Brightness",          -- emissive strength
    edgePower = "EdgePower",            -- the soft edge: x |N.V| to this power (0: none)
    spin = "Spin",                      -- turns a second about the piece's own Z, by the game's clock
    startTime = "StartTime",            -- game seconds the fade and the growth count from
    life = "Life",                      -- seconds the fade lasts (0: never fades)
    fadeDelay = "FadeDelay",            -- seconds after StartTime the fade begins
    fadePower = "FadePower",            -- the fade's curve: (1 - its share done) to this power
    growXY = "GrowXY", growZ = "GrowZ", -- the size across and up at StartTime, as a share of the full size
    growTime = "GrowTime",              -- seconds to grow to full size, eased out (0: no growth)
    nearFadeStart = "NearFadeStart",    -- cm from the camera where the piece starts to show...
    nearFadeEnd = "NearFadeEnd",        -- ...and where it is fully there (the pillar hides up close)
}
local MOVABLE = 2                   -- EComponentMobility::Movable: a spawned StaticMeshActor starts Static
local NO_COLLISION = 0              -- ECollisionEnabled::NoCollision
local STANDING = { X = 0, Y = 0, Z = 0, W = 1 }   -- a spawn's turn as a quaternion: none
local DEGREES = 180 / math.pi
local STATIC_MESH_ACTOR = "StaticMeshActor"       -- the pieces' class by the short name FindAllOf takes

-- State: what the pieces are made of. Forgotten: assets and looks at a world change (forgetWorld; looked up or made
-- again when next needed); pakMissing never (the pak is mounted at start-up or not at all); keptPlaces never (each
-- kept object takes the place of the one before it, so the list does not grow).
local assets = nil            -- { meshes = { part -> mesh }, textures = { part -> texture }, material = M_APGlow }
local pakMissing = false      -- the pak's glow assets were looked for and are not all there: the glows are off
local looks = {}              -- look name -> its dynamic material instance of M_APGlow, in this world
local keptPlaces = {}         -- what is kept ("asset SM_APGlowRing", "look ring") -> its place (UTIL.keepInPlace)
-- State: the pieces standing. Forgotten: at a world change (forgetWorld), and each when it is removed.
local alive = {}              -- a piece's address -> the piece { actor, addr }
local madeFor = nil           -- the player controller's address the pieces were spawned under
-- The game's libraries and the actor class. Forgotten: never; each is checked with IsValid before use.
local statics, actorClass, materialLibrary = nil, nil, nil

-- Keeps obj alive in the place kept for `key`, in place of what was kept there before.
local function keepAs(key, obj)
    keptPlaces[key] = UTIL.keepInPlace(keptPlaces[key], obj)
end

-- Whether config.txt lets the glows show (glow=0 turns them off; on by default). Said once when off.
function GLOW_PIECES.on()
    if CONFIG.cfg.glow == "0" then
        once("off", "glow: off (glow=0 in config.txt)")
        return false
    end
    return true
end

-- The game's spawning and material libraries and the StaticMeshActor class; false while any is missing.
local function librariesReady()
    if not UTIL.isValid(statics) then
        statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    end
    if not UTIL.isValid(actorClass) then
        actorClass = StaticFindObject("/Script/Engine.StaticMeshActor")
    end
    if not UTIL.isValid(materialLibrary) then
        materialLibrary = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
    end
    local ready = UTIL.isValid(statics) and UTIL.isValid(actorClass) and UTIL.isValid(materialLibrary)
    if not ready then
        once("libraries", "glow: waiting: GameplayStatics, StaticMeshActor or KismetMaterialLibrary not found yet")
    end
    return ready
end

-- One of the pak's assets, kept alive, or nil (its name added to `missing`).
local function packAsset(name, missing)
    local found = WALL_SKINS.modAsset(ART_FOLDER .. name, name, {})
    if not found then
        missing[#missing + 1] = name
        return nil
    end
    keepAs("asset " .. name, found)
    return found
end

-- The pak's glow assets, or nil and the names of those missing.
local function findAssets()
    local missing = {}
    local found = { meshes = {}, textures = {}, material = packAsset(MATERIAL, missing) }
    for _, part in ipairs(PARTS) do
        local suffix = part:sub(1, 1):upper() .. part:sub(2)
        found.meshes[part] = packAsset(MESH_PREFIX .. suffix, missing)
        found.textures[part] = packAsset(TEXTURE_PREFIX .. suffix, missing)
    end
    if #missing > 0 then return nil, missing end
    return found
end

-- Whether the glows can show now: config.txt allows them, the game's libraries are there and the pak's glow assets
-- were found (looked for once; without them both glows are off for the session, said in one line).
function GLOW_PIECES.ready()
    if pakMissing or not GLOW_PIECES.on() then return false end
    if assets then return librariesReady() end
    if not librariesReady() then return false end
    local missing
    assets, missing = findAssets()
    if not assets then
        pakMissing = true
        log("glow: off for this session: the PalworldArchipelagoArt pak has no " .. table.concat(missing, ", ")
            .. " (logicmod/make_glow_assets.py makes them)")
        return false
    end
    once("assets", "glow: the pak's glow meshes, textures and " .. MATERIAL .. " found")
    return true
end

-- Sets a look's parameters on its material: each field of `params` (SCALARS, plus colour = the part whose texture is
-- a colour picture, Tex; mask = the part whose texture is a light mask, Mask; tint = a linear colour, Tint).
local function setParameters(material, params)
    for field, value in pairs(params) do
        if field == "colour" then
            material:SetTextureParameterValue(FName("Tex"), assets.textures[value])
        elseif field == "mask" then
            material:SetTextureParameterValue(FName("Mask"), assets.textures[value])
        elseif field == "tint" then
            material:SetVectorParameterValue(FName("Tint"), value)
        elseif SCALARS[field] then
            material:SetScalarParameterValue(FName(SCALARS[field]), value)
        else
            error("glow: a look has a field M_APGlow has no parameter for: " .. tostring(field))
        end
    end
end

-- The look kept as `name` in this world: a dynamic instance of M_APGlow (owned by the game instance and kept alive,
-- as the walls' materials are), made on first use; `params` are set on it each time. Nil when it can't be made.
function GLOW_PIECES.look(name, params)
    local material = looks[name]
    if not UTIL.isValid(material) then
        local gameInstance = UTIL.gameInstance()
        if not gameInstance then return nil end
        material = materialLibrary:CreateDynamicMaterialInstance(gameInstance, assets.material, FName("None"),
            WALL_SKINS.MID_FLAGS)
        if not UTIL.isValid(material) then
            UTIL.onceErr("glow look", name, "glow: could not make the look " .. name)
            return nil
        end
        keepAs("look " .. name, material)
        looks[name] = material
    end
    setParameters(material, params)
    return material
end

-- Dresses a piece between its spawn and its finish: movable (it turns and grows), the part's mesh and the look, no
-- collision and no shadow. Untested in game: a plain StaticMeshActor spawned from Lua and dressed this way.
local function dressNew(actor, part, material)
    local mesh = actor.StaticMeshComponent
    mesh:SetMobility(MOVABLE)
    mesh:SetStaticMesh(assets.meshes[part])
    mesh:SetMaterial(0, material)
    mesh:SetCollisionEnabled(NO_COLLISION)
    mesh:SetCastShadow(false)
    actor:SetActorEnableCollision(false)
end

-- A StaticMeshActor spawned, dressed (dressNew) and finished, or nil and why not. One that could not be dressed is
-- destroyed again.
local function spawnDressed(pawn, part, material, t)
    local actor = statics:BeginDeferredActorSpawnFromClass(pawn, actorClass, t, WALLS.SPAWN_ALWAYS, nil)
    if not UTIL.isValid(actor) then return nil, "the spawn gave no actor" end
    local ok, err = pcall(dressNew, actor, part, material)
    statics:FinishSpawningActor(actor, t)
    if ok then return actor end
    pcall(function() actor:K2_DestroyActor() end)
    return nil, "it could not be dressed: " .. tostring(err)
end

-- A new piece: a StaticMeshActor showing `part`'s mesh in `material`, at `at` (a location), scaled by `scale`
-- (X, Y, Z), not turned. Returns the piece { actor, addr }, or nil (logged once for each kind of failure).
function GLOW_PIECES.spawn(pawn, part, material, at, scale)
    local t = { Rotation = STANDING, Translation = at, Scale3D = scale }
    local ok, actor, why = pcall(spawnDressed, pawn, part, material, t)
    if not (ok and actor) then
        why = ok and why or tostring(actor)
        UTIL.onceErr("glow spawn", why, "glow: a " .. part .. " piece did not go up: " .. why)
        return nil
    end
    local frame = PLAYER.frame()
    madeFor = madeFor or (frame and frame.controllerKey)
    local piece = { actor = actor, addr = UTIL.addr(actor) }
    alive[piece.addr] = piece
    return piece
end

-- Whether a piece still stands: it was not removed or forgotten, and the game says it is valid. Asked before every
-- call on a piece.
function GLOW_PIECES.isLive(piece)
    return piece ~= nil and alive[piece.addr] == piece and UTIL.isValid(piece.actor)
end

-- Scales a live piece (SetActorScale3D: no out-parameters, unlike K2_SetActorLocation).
function GLOW_PIECES.setScale(piece, scale)
    if not GLOW_PIECES.isLive(piece) then return end
    pcall(function() piece.actor:SetActorScale3D(scale) end)
end

-- Turns a live piece to a rotation { Pitch, Yaw, Roll } in degrees.
function GLOW_PIECES.turn(piece, rotation)
    if not GLOW_PIECES.isLive(piece) then return end
    pcall(function() piece.actor:K2_SetActorRotation(rotation, false) end)
end

-- Moves a live piece to `at`, turned to `rotation`, in one call (K2_TeleportTo: no out-parameters).
function GLOW_PIECES.place(piece, at, rotation)
    if not GLOW_PIECES.isLive(piece) then return end
    pcall(function() piece.actor:K2_TeleportTo(at, rotation) end)
end

-- The rotation that turns a piece's +X (a flat quad's face) from `from` towards `to`, both locations.
function GLOW_PIECES.facing(from, to)
    local dx, dy, dz = to.X - from.X, to.Y - from.Y, to.Z - from.Z
    local across = math.sqrt(dx * dx + dy * dy)
    return { Pitch = math.atan(dz, across) * DEGREES, Yaw = math.atan(dy, dx) * DEGREES, Roll = 0 }
end

-- Takes a piece down and forgets it.
function GLOW_PIECES.remove(piece)
    if not piece then return end
    if GLOW_PIECES.isLive(piece) then
        pcall(function() piece.actor:K2_DestroyActor() end)
    end
    alive[piece.addr] = nil
end

-- Where the camera is now, or nil: the player's camera manager (the frame's controller). Untested in game.
function GLOW_PIECES.camera()
    local frame = PLAYER.frame()
    local ok, at = pcall(function() return frame.pc.PlayerCameraManager:GetCameraLocation() end)
    if ok and at and at.X then return at end
    return nil
end

-- The game's clock in seconds (GetTimeSeconds, the clock M_APGlow's Time node runs on), or nil.
function GLOW_PIECES.gameSeconds(pawn)
    local ok, now = pcall(function() return statics:GetTimeSeconds(pawn) end)
    if ok and type(now) == "number" then return now end
    return nil
end

-- An actor's bounds: { centre, half = half its size along each axis }, both in cm, or nil when they can't be read.
-- Untested in game: GetActorBounds' two FVector out-parameters filled into Lua tables.
function GLOW_PIECES.bounds(actor)
    local centre, half = {}, {}
    local ok = pcall(function() actor:GetActorBounds(false, centre, half, false) end)
    if ok and centre.X and half.X then return { centre = centre, half = half } end
    return nil
end

-- The addresses of the StaticMeshActors the game still has (FindAllOf lists live objects only).
local function liveAddresses()
    local live = {}
    for _, actor in ipairs(FindAllOf(STATIC_MESH_ACTOR) or {}) do
        local addr = UTIL.addr(actor)
        if addr then
            live[addr] = true
        end
    end
    return live
end

-- A world change (the pawn changed): the pieces still standing under the same controller (a faint: the same world)
-- are taken down; under another controller or none (another world, the title) they went with their world and are
-- only forgotten, never called. The looks and assets are let go too, and found or made again when next needed.
function GLOW_PIECES.forgetWorld()
    local frame = PLAYER.frame()
    local sameController = frame ~= nil and frame.controllerKey ~= nil and frame.controllerKey == madeFor
    if sameController and next(alive) then
        local live = liveAddresses()
        for addr, piece in pairs(alive) do
            if live[addr] then
                pcall(function() piece.actor:K2_DestroyActor() end)
            end
        end
    end
    alive, madeFor, looks, assets = {}, nil, {}, nil
end

-- Whether the pieces kept were made under this update's controller. Under another, they are of a world that is gone:
-- they are forgotten without a call (forgetWorld), and false is returned.
function GLOW_PIECES.sameWorld()
    local frame = PLAYER.frame()
    if madeFor == nil or (frame and frame.controllerKey == madeFor) then return true end
    GLOW_PIECES.forgetWorld()
    return false
end

-- How many pieces stand now (the harness's and the log's count).
function GLOW_PIECES.count()
    local n = 0
    for _ in pairs(alive) do
        n = n + 1
    end
    return n
end

return GLOW_PIECES
