-- The walls' corner posts (wall_posts.lua), on fresh copies of walls.lua: none without the pak's post, said once; with
-- it, a post at each bend of the pieces standing, in the colour its first piece's wall wears, as tall as the walls and
-- without collision; kept while its pieces dissolve and taken down after; none on the game's red walls; forgotten
-- without a call when its world is gone. And the posts in the three walls files touch pieces that exist, at their ends.

local UTIL = require("util")
local POST_MESH = "SM_APWallPost"
local NEAR_END_CM = 400                -- a post stands within this of an end of each piece it touches (4 m: a joint)

-- The corner posts standing: the StaticMeshActors wearing the pak's post.
local function postActors()
    local list = {}
    for a in pairs(glowActors) do
        if a.mesh and tostring(a.mesh.path):find(POST_MESH, 1, true) then
            list[#list + 1] = a
        end
    end
    return list
end

-- A stand-in pawn at the spot pawnAt (the harness's player position).
local function standIn()
    return { IsValid = function() return true end, K2_GetActorLocation = function() return pawnAt end }
end

-- A fresh walls copy whose posts get a mesh_actors.lua of their own that no glow has readied: in the game the posts'
-- first spawn can come before any glow looks for the spawning library.
local function freshWallsAlone()
    local kept = package.loaded["mesh_actors"]
    package.loaded["mesh_actors"] = nil
    local W = h.freshWalls()
    package.loaded["mesh_actors"] = kept
    return W
end

-- Runs a fresh walls copy n updates with these passes, the game's clock moving step seconds each.
local function runWalls(W, n, passes, step)
    local pawn = standIn()
    for _ = 1, n do
        gameSeconds = gameSeconds + (step or 0)
        W.update(true, passes, pawn)
    end
end

-- Every post of a walls file touches pieces that exist, and stands within NEAR_END_CM of an end of each.
local function postsTouchTheirPieces(file)
    local data = dofile(MOD .. "/Scripts/" .. file)
    local bad = 0
    for _, post in ipairs(data.posts or {}) do
        for _, i in ipairs(post.pieces) do
            local wall = data.walls[i]
            local near = nil
            if wall then
                local yaw = math.rad(wall.yaw)
                local dx, dy = math.cos(yaw) * wall.length / 2, math.sin(yaw) * wall.length / 2
                local function from(x, y) return math.sqrt((x - post.x) ^ 2 + (y - post.y) ^ 2) end
                near = math.min(from(wall.x + dx, wall.y + dy), from(wall.x - dx, wall.y - dy))
            end
            if not near or near > NEAR_END_CM then bad = bad + 1 end
        end
    end
    expect(#(data.posts or {}) > 0 and bad == 0, file .. ": " .. #(data.posts or {}) .. " corner posts, each touching"
           .. " pieces that exist, at their ends (" .. bad .. " not)")
end

-- Without the pak's post: no posts, said once.
local function noPostWithoutThePak()
    game.logicMod, game.cornerPosts = true, false
    local W = h.freshWalls()
    W.setSkin("paws")
    local mark = logMark()
    runWalls(W, 40, {})
    expect(W.postCount() == 0 and #postActors() == 0
           and loggedSince(mark, "wall posts: none this session: the PalworldArchipelagoArt pak has no SM_APWallPost,"
                           .. " M_APWallPost"),
           "a pak without the corner post: no posts, and the log says what is missing")
end

-- With the pak's post: posts up at the walls' joints, dressed and sized; returns the walls copy and its data.
local function postsGoUp()
    game.logicMod, game.cornerPosts = true, true
    local W = freshWallsAlone()
    W.setSkin("paws")
    runWalls(W, 80, {})
    local data = dofile(MOD .. "/Scripts/region_walls.lua")
    local spots, posts = {}, postActors()
    for _, post in ipairs(data.posts) do spots[post.x .. "," .. post.y] = post end
    local misplaced, wrongColour, sample = 0, 0, posts[1]
    for _, a in ipairs(posts) do
        local post = spots[a.at.X .. "," .. a.at.Y]
        local skinName = post and W.pieceSkin(post.pieces[1], {}, "paws")
        local hex = skinName and skinName:match(":(%x%x%x%x%x%x)")
        local back = a.material and a.material.vectors.Back
        if not post then misplaced = misplaced + 1 end
        if not (hex and back and h.sameColour(back, UTIL.linear(hex))) then wrongColour = wrongColour + 1 end
    end
    expect(W.postCount() > #data.posts / 2 and #posts == W.postCount() and misplaced == 0,
           "the corner posts go up at the joints of the pieces standing: " .. W.postCount() .. " of " .. #data.posts)
    expect(wrongColour == 0, "each in its first piece's lock colour (M_APWallPost's Back): " .. wrongColour .. " not")
    expect(sample and sample.scale.Z == 3000 and sample.at.Z == 50000 - 150000 and sample.collision == 0
           and sample.actorCollision == false and tostring(sample.material.parent.path):find("M_APWallPost", 1, true),
           "as tall as the walls (3 km, from their foot), without collision, on M_APWallPost")
    return W, data
end

-- A post whose pieces all open: kept while they dissolve, taken down once they are gone.
local function postGoesWithItsPieces(W, data)
    local passes, target = {}, nil
    for _, post in ipairs(data.posts) do
        local wall = data.walls[post.pieces[1]]
        local lock = data.locks[wall.lockB + 1]
        if wall.lockA == 0 and lock ~= data.start and #post.pieces == 2
           and data.walls[post.pieces[2]].lockA == 0 and data.walls[post.pieces[2]].lockB == wall.lockB then
            target, passes[lock] = post, true
            break
        end
    end
    local function postUp()
        for _, a in ipairs(postActors()) do
            if a.at.X == target.x and a.at.Y == target.y then return true end
        end
        return false
    end
    expect(target and postUp(), "a post between the open sea and one region stands while the region is locked")
    runWalls(W, 10, passes, 0.3)          -- 3 s: the walk passes every post, and the dissolve (4 s) is not done
    local whileOpening = postUp()
    runWalls(W, 60, passes, 0.3)
    expect(whileOpening and not postUp(), "its region's pass: kept while its pieces dissolve, taken down after")
end

group("the walls' corner posts", function()
    for _, file in ipairs({ "region_walls.lua", "area_walls.lua", "level_walls.lua" }) do
        postsTouchTheirPieces(file)
    end
    noPostWithoutThePak()
    local W, data = postsGoUp()
    postGoesWithItsPieces(W, data)
    W.setSkin("red")
    runWalls(W, 30, {})
    expect(W.postCount() == 0 and #postActors() == 0, "the game's red walls: no posts")
    W.setSkin("paws")
    runWalls(W, 60, {})
    local before = W.postCount()
    do  -- a faint (the pawn changes, the world stays): the same posts stand, each put in a look made anew
        local spawned, oldLook = glowSpawned, postActors()[1].material
        W.reset()
        runWalls(W, 20, {})
        expect(W.postCount() == before and glowSpawned == spawned and postActors()[1].material ~= oldLook,
               "a faint: the " .. before .. " posts stand on, none raised again, each in a new look ("
               .. (glowSpawned - spawned) .. " spawned)")
    end
    local called = 0
    for _, a in ipairs(postActors()) do        -- (their world is gone: the game no longer lists them)
        a.gone, glowActors[a] = true, nil
        a.K2_DestroyActor = function() called = called + 1 end
    end
    W.reset()
    expect(before > 0 and W.postCount() == 0 and called == 0,
           "a world gone: its " .. before .. " posts forgotten without a call")
    game.logicMod, game.cornerPosts = false, false
end)
