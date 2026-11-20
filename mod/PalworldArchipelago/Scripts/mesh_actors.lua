-- Plain engine StaticMeshActors showing one of the art pak's meshes in a material, spawned from Lua: movable, no
-- collision, no shadow. Also the addresses of those the game still has, to tell a world's actors are gone without
-- calling them. Shared by the glows (glow_pieces.lua) and the walls' corner posts (wall_posts.lua); each keeps its own
-- list of what it spawned and when to let it go.
-- Tests: through mod/test/tests/glow.lua and mod/test/tests/wall_posts.lua (tools/lua_harness.sh, in CI).
local MESH_ACTORS = {}
local UTIL = require("util")

MESH_ACTORS.SPAWN_ALWAYS = 1         -- ESpawnActorCollisionHandlingMethod::AlwaysSpawn: it goes up wherever it stands
local MOVABLE = 2                    -- EComponentMobility::Movable: a spawned StaticMeshActor starts Static
local NO_COLLISION = 0               -- ECollisionEnabled::NoCollision
local STATIC_MESH_ACTOR = "StaticMeshActor"       -- the class by the short name FindAllOf takes

-- The game's spawning library and the StaticMeshActor class. Forgotten: never; each is checked with IsValid before use.
local statics, actorClass = nil, nil

-- Whether GameplayStatics and the StaticMeshActor class are found (looked up again while either is missing).
function MESH_ACTORS.ready()
    if not UTIL.isValid(statics) then
        statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    end
    if not UTIL.isValid(actorClass) then
        actorClass = StaticFindObject("/Script/Engine.StaticMeshActor")
    end
    return UTIL.isValid(statics) and UTIL.isValid(actorClass)
end

-- Dresses an actor between its spawn and its finish: movable (it can turn and grow), the mesh and the material, no
-- collision and no shadow.
local function dressNew(actor, mesh, material)
    local component = actor.StaticMeshComponent
    component:SetMobility(MOVABLE)
    component:SetStaticMesh(mesh)
    component:SetMaterial(0, material)
    component:SetCollisionEnabled(NO_COLLISION)
    component:SetCastShadow(false)
    actor:SetActorEnableCollision(false)
end

-- A StaticMeshActor showing `mesh` in `material`, spawned at the transform t ({ Rotation, Translation, Scale3D }),
-- dressed and finished; or nil and why not. One that could not be dressed is destroyed again. Call ready() first.
function MESH_ACTORS.spawn(pawn, mesh, material, t)
    local actor = statics:BeginDeferredActorSpawnFromClass(pawn, actorClass, t, MESH_ACTORS.SPAWN_ALWAYS, nil)
    if not UTIL.isValid(actor) then return nil, "the spawn gave no actor" end
    local ok, err = pcall(dressNew, actor, mesh, material)
    statics:FinishSpawningActor(actor, t)
    if ok then return actor end
    pcall(function() actor:K2_DestroyActor() end)
    return nil, "it could not be dressed: " .. tostring(err)
end

-- The addresses of the StaticMeshActors the game still has (FindAllOf lists live objects only).
function MESH_ACTORS.liveAddresses()
    local live = {}
    for _, actor in ipairs(FindAllOf(STATIC_MESH_ACTOR) or {}) do
        local addr = UTIL.addr(actor)
        if addr then
            live[addr] = true
        end
    end
    return live
end

-- The game's clock in seconds (GetTimeSeconds), or nil.
function MESH_ACTORS.gameSeconds(pawn)
    local ok, now = pcall(function() return statics:GetTimeSeconds(pawn) end)
    if ok and type(now) == "number" then return now end
    return nil
end

return MESH_ACTORS
