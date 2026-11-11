-- Lock Size: areas, areas beyond the goal, the walls' area colours and the HUD pieces (the hint pop-up, the
-- debuff icons, the goal banner). Tests walls.lua, hint_popup.lua, debuffs.lua.

group("Lock Size: areas", function()
    -- Slot data options.lock_size 1: every named area of the game on its own, opened by an Area Pass.
    -- walls.lua still calls this cut "regions" (the older word).
    local RD = dofile(MOD .. "/Scripts/area_walls_regions.lua")
    local liveWalls = require("walls")
    slotData["options.lock_size"] = "1"
    h.reconnect("Tester")
    h.replayItems()
    run(80)
    expect(logged("area locks: 75 areas %(" .. #RD.walls .. " border pieces%)") and liveWalls.layout == "regions"
           and liveWalls.passName("Golden Hills") == "Area Pass: Golden Hills", "a 75-areas seed: the areas' walls and passes")
    local up = wallCount()
    expect(up > 1000 and up <= #RD.walls, "the 75 areas' walls go up (the 15 regions' came down): " .. up)
    pushItem({ name = "Area Pass: Golden Hills", index = 9000 })
    run(60)
    expect(wallCount() < up, "an Area Pass takes its area's walls down: " .. up .. " -> " .. wallCount())
    expect(liveWalls.parentOf("Golden Hills") == "Bamboo Groves" and liveWalls.parentOf("Gobfin's Turf") == "Crescent Moon Shore",
           "an area wears its region's colour, ticket and stamp (area_parents_regions.lua)")
    local perHex = {}
    for i in ipairs(RD.walls) do
        local name = liveWalls.pieceSkin(i, {}, "paws")
        local hex, own = name:match("^paws:(%x+):(%d+)$")
        if hex then perHex[hex] = perHex[hex] or {}; perHex[hex][own] = true end
    end
    local sisters = 0
    for _, owns in pairs(perHex) do local n = 0; for _ in pairs(owns) do n = n + 1 end; if n >= 2 then sisters = sisters + 1 end end
    expect(sisters >= 5, "75 Areas, paws: sister Areas wear their Region's colour, each its own variant (paws:<colour>:<area>): "
           .. sisters .. " regions with several")
    slotData["options.lock_size"], slotData["options.area_size"] = nil, "1"   -- a seed made before the rename
    h.reconnect("Tester")
    run(80)
    expect(liveWalls.layout == "regions", "a seed from before the rename (options.area_size 1) still gets the 75 areas")
    slotData["options.area_size"] = nil                          -- a 15-regions seed again (and seeds made before the option)
    h.reconnect("Tester")
    run(80)
    expect(liveWalls.layout == "areas" and logged("area locks: 15 regions"), "back to a 15-regions seed: the regions' walls")
end)

group("areas beyond the goal", function()
    -- Slot data beyond_goal_areas and options.beyond_goal: sealed for good, or open from the start.
    slotData.beyond_goal_areas, slotData["options.beyond_goal"] = shared.hintArea, "0"
    h.reconnect("Tester")
    run(80)
    expect(logged("areas beyond the goal: 1, sealed for good"), "a locked area beyond the goal is logged")
    local up = wallCount()
    local noticesBefore = #announced
    pawnAt = shared.hintAt
    runPast(WAIT.wallNotice)
    local toldBeyond, offered = false, false
    for i = noticesBefore + 1, #announced do
        if announced[i]:find(shared.hintArea .. " is beyond this seed's goal: its walls stay up.", 1, true) then toldBeyond = true end
        if announced[i]:find("needs Region Pass: " .. shared.hintArea, 1, true) then offered = true end
    end
    expect(toldBeyond and not offered, "its wall says it is beyond the goal, and offers no hint for a pass that isn't there")
    slotData["options.beyond_goal"] = "2"
    h.reconnect("Tester")
    run(80)
    expect(logged("areas beyond the goal: 1, open from the start") and wallCount() < up,
           "open: its walls come down without a pass: " .. up .. " -> " .. wallCount())
    slotData.beyond_goal_areas, slotData["options.beyond_goal"] = nil, nil
end)

group("area-coloured walls and the hint pop-up", function()
    local WD = shared.WD
    -- Area-coloured walls, sealed walls beyond the goal, the hint pop-up.
    local liveWalls = require("walls")
    local openedBeyond = shared.hintArea                -- the open-beyond test above opened it
    local layout, canvas, hudKids = fakeHud("CanvasPanel_179")
    local savedFAO = FindAllOf
    FindAllOf = function(class) if class == "WBP_PalHUDLayout_C" then return { layout } end return savedFAO(class) end
    local function actorOf(w)
        for a in pairs(wallsUp) do if a.t.Translation.X == w[1] and a.t.Translation.Y == w[2] then return a end end
    end
    local function pieceBetween(x, y)
        for _, w in ipairs(WD.walls) do
            local a1, a2 = WD.areas[w[5] + 1], WD.areas[w[6] + 1]
            if (a1 == x and a2 == y) or (a1 == y and a2 == x) then
                local a = actorOf(w)
                if a then return a end
            end
        end
    end
    local function popupAfter(n)
        for _ = 1, 450 do
            if #hudKids > n then return hudKids[n + 1] end
            run(1)
        end
    end
    local skinAt = logMark()
    liveWalls.setSkin(nil); run(3)
    -- An area beside the start still locked (the open-beyond test above opened the hint test's area), and a spot on
    -- the start's side of one of its walls.
    local area, at, piece
    for _, w in ipairs(WD.walls) do
        local x, y = WD.areas[w[5] + 1], WD.areas[w[6] + 1]
        local other = (x == WD.start and y) or (y == WD.start and x)
        if other and liveWalls.AREA_COLOURS[other] and w[3] > 5000 and actorOf(w) then
            local yaw = math.rad(w[4])
            for _, side in ipairs({ 1, -1 }) do
                local px, py = w[1] - side * math.sin(yaw) * 1500, w[2] + side * math.cos(yaw) * 1500
                if liveWalls.areaAt(px, py) == WD.start then area, at, piece = other, { X = px, Y = py, Z = 0 }, actorOf(w) end
            end
            if area then break end
        end
    end
    local popupArea, popupAt = area, at   -- (another wall: the one above was opened)
    local want = popupArea and liveWalls.linearOf(liveWalls.AREA_COLOURS[popupArea])
    expect(piece and piece.Cube.mat.textures.MainTexture01.path == "ap-wall-pattern-pawholes" and h.sameColour(piece.Cube.mat.vectors.Color, want)
           and loggedSince(skinAt, "wall skin area: colours "), "by default a wall wears the paw holes in the colour of the area it keeps you out of")
    -- The hint pop-up at that wall: centred, a little transparent, gone after 6 s.
    pawnAt = popupAt
    local box = popupAfter(#hudKids)
    local over = box and box.child
    expect(box and box.width == 380 and box.height == 84 and box.opacity == 0.8 and box.vis == 4
           and box.canvasSlot.anchors.Minimum.X == 0.5 and box.canvasSlot.anchors.Minimum.Y == 0.5
           and box.canvasSlot.alignment.X == 0.5 and box.canvasSlot.position.Y == 0,
           "walking up to a wall shows the hint pop-up in the middle of the screen at 0.8 opacity")
    expect(over and over.children[1].child.texture.path == "ap-hint-plate-short" and over.children[2].text == popupArea .. " is sealed"
           and over.children[3].text == "Not enough points for a hint: 3 of 121" and over.children[4] and over.children[4].width == 9,
           "on the not-enough-points plate, with its two lines and the bar: "
           .. tostring(over and over.children[3] and over.children[3].text))
    runCycles(3)
    expect(box and box.removed, "and goes away after 6 s")
    -- Beyond the goal: the sealed walls (slate grey; the sealed pattern when its file is found) and the pop-up says so.
    slotData.beyond_goal_areas, slotData["options.beyond_goal"] = popupArea, "0"
    h.reconnect("Tester")
    run(80)
    local m = piece.Cube.mat
    expect(m and (m.textures.MainTexture01.path == "ap-wall-pattern-sealed" or m.textures.MainTexture01.path == "ap-wall-pattern-a")
           and h.sameColour(m.vectors.Color, require("walls").linearOf("9AA3B5")),
           "a wall to an area beyond the goal wears the sealed grey, #9AA3B5")
    local sealedBox = popupAfter(#hudKids)
    expect(sealedBox and sealedBox.child.children[2].text == popupArea .. " is beyond the goal"
           and sealedBox.child.children[3].text == "Its walls stay up for good." and not sealedBox.child.children[4],
           "its pop-up says it is beyond the goal, with no points bar")
    slotData.beyond_goal_areas, slotData["options.beyond_goal"] = nil, nil
    h.reconnect("Tester")
    run(80)
    expect(h.sameColour(piece.Cube.mat.vectors.Color, want), "and back to its area's colour when it is not")
    -- A pass that opens one side of a piece still up turns it to the other side's colour.
    local a1, a2, between
    for _, w in ipairs(WD.walls) do
        local x, y = WD.areas[w[5] + 1], WD.areas[w[6] + 1]
        if liveWalls.AREA_COLOURS[x] and liveWalls.AREA_COLOURS[y] and not shared.open[x] and not shared.open[y] and x ~= openedBeyond
           and y ~= openedBeyond and actorOf(w) then
            a1, a2, between = x, y, actorOf(w)
            break
        end
    end
    local colourOf = function(area) return liveWalls.linearOf(liveWalls.AREA_COLOURS[area]) end
    local colourBefore = between and between.Cube.mat.vectors.Color
    pushItem({ name = "Region Pass: " .. tostring(a1), index = 9300 })
    run(80)
    expect(between and (h.sameColour(colourBefore, colourOf(a1)) or h.sameColour(colourBefore, colourOf(a2))) and h.sameColour(between.Cube.mat.vectors.Color, colourOf(a2))
           and not between.gone, "a piece between " .. tostring(a1) .. " and " .. tostring(a2) .. " turns to "
           .. tostring(a2) .. "'s colour when " .. tostring(a1) .. " opens")
    FindAllOf = savedFAO
end)

group("debuff icons, the hint plate and the goal banner", function()
    -- Debuff icons with their timers at the top of the HUD.
    local layout, canvas, hudKids = fakeHud("CanvasPanel_179")
    local savedFAO = FindAllOf
    FindAllOf = function(class) if class == "WBP_PalHUDLayout_C" then return { layout } end return savedFAO(class) end
    local DB = require("debuffs")
    expect(DB.clock(200, 0) == "1:00" and DB.clock(100, 0) == "0:30" and DB.clock(5, 10) == "0:00", "the timer reads m:ss")
    require("traps").test("Slow Trap")                     -- the test tools route: it goes on the next update
    local row
    for _ = 1, 40 do
        for _, k in ipairs(hudKids) do if not k.removed then row = k end end
        if row then break end
        run(1)
    end
    local over = row and row.child
    local timer = over and over.children[#over.children].child          -- the timer is the last piece of a tile
    expect(row and row.canvasSlot.anchors.Minimum.X == 0.5 and row.canvasSlot.anchors.Minimum.Y == 0
           and row.canvasSlot.position.Y == 112 and row.vis == 4,
           "a Slow Trap puts its icon at the top centre of the HUD, never taking a click")
    -- (The harness's ImportFileAsTexture2D makes any file; in game a missing ap-debuff-slow.png gives a plain SLOW tile.)
    local icon = over and over.children[1].child
    expect(icon and icon.texture and icon.texture.path == "ap-debuff-slow" and icon.ownerW == nil and over.children[1].width == 44,
           "the Art lane's ap-debuff-slow icon, 44 px")
    local first = timer and timer.text
    expect(first == "1:00" or first == "0:59", "with its time left under it: " .. tostring(first))
    run(10)
    expect(timer.text ~= first and #hudKids == 1, "the timer counts down without rebuilding the row: " .. tostring(timer.text))
    local ended = false
    for _ = 1, 220 do
        run(1)
        if logged("Slow Trap ended") and row.removed then ended = true; break end
    end
    expect(ended and #DB.active() == 0,
           "and the icon goes when the Slow Trap ends")
    -- 2026-11-08 crash: Return to title during the goal banner; the update then called the old world's widget. With the
    -- HUD gone (FindAllOf lists it no more) the banner is forgotten without a call to it.
    local POP = require("hint_popup")
    expect(POP.banner("10 Pals registered", 1) and logged("goal banner: shown %(10 Pals registered%)"), "the goal banner is shown on the HUD")
    local bannerBox
    for _, k in ipairs(hudKids) do if not k.removed then bannerBox = k end end
    local touched = false
    if bannerBox then
        bannerBox.IsValid = function() touched = true; error("a dead widget called") end
        bannerBox.RemoveFromParent = function() touched = true; error("a dead widget called") end
    end
    local liveFAO = FindAllOf
    FindAllOf = function(class) if class == "WBP_PalHUDLayout_C" then return {} end return savedFAO(class) end
    local okT = pcall(POP.tick, 2)
    FindAllOf = liveFAO
    local okT2 = pcall(POP.tick, 3)
    expect(bannerBox and okT and okT2 and not touched, "the world gone (Return to title), the banner is forgotten without touching it")
    -- A faint just after a wall hint: the pawn reads nil for a moment in the same world, with the same HUD.
    local now
    local realTick = POP.tick
    POP.tick = function(t) now = t; return realTick(t) end   -- (the core's update count, as it hands it over)
    run(1)
    POP.show({ title = "Bamboo Groves is sealed", line = "It needs Region Pass: Bamboo Groves" }, now)
    local plate = hudKids[#hudKids]
    game.pawnGone = true
    run(2)
    game.pawnGone = false
    run(3 * POP.SHOW_TICKS)
    POP.tick = realTick
    expect(plate and plate.removed,
           "a hint plate on screen when the pawn reads nil for a moment (same world, same HUD) still comes down")
    -- A wall hint while the goal banner is up: the banner keeps its 15 s; the hint goes to chat only.
    run(1)
    POP.banner("10 Pals registered", now)
    local banner = hudKids[#hudKids]
    local hintShown = POP.show({ title = "Bamboo Groves is sealed", line = "It needs Region Pass: Bamboo Groves" }, now + 1)
    expect(banner and not banner.removed and hintShown == false and hudKids[#hudKids] == banner,
           "a wall hint does not take the goal banner down early")
    run(POP.SHOW_TICKS * 3)                                   -- (the banner's time runs out)
    -- After Return to title and another world load the last world's HUD layout is still listed, first, and reads
    -- visible: the plate, the banner and the debuff icons go on the live one.
    local oldKids = {}
    local oldCanvas = Widget({ GetClass = function() return classed("CanvasPanel") end })
    function oldCanvas:AddChildToCanvas(w)
        oldKids[#oldKids + 1] = w
        return canvas:AddChildToCanvas(w)                     -- (a slot like the live canvas's)
    end
    local oldSafe = Widget({ GetClass = function() return classed("SafeZone") end,
                             GetChildAt = function() return oldCanvas end })
    local oldLayout = Widget({ IsVisible = function() return true end, WidgetTree = { RootWidget = oldSafe },
                               GetOwningPlayer = function() return { IsValid = function() return false end } end })
    FindAllOf = function(class)
        if class == "WBP_PalHUDLayout_C" then return { oldLayout, layout } end
        return savedFAO(class)
    end
    local kidsBefore = #hudKids
    local onPlate = POP.show({ title = "Bamboo Groves is sealed", line = "It needs Region Pass: Bamboo Groves" },
                             now + 100)
    POP.hide()
    local DBF = require("debuffs")
    DBF.set("test", "ap-debuff-slow", "SLOW", now + 200)
    DBF.tick(now + 100)
    DBF.clear("test")
    DBF.tick(now + 101)
    expect(onPlate and #hudKids >= kidsBefore + 2 and #oldKids == 0,
           "the hint plate and the debuff icons go on the live HUD, not the last world's: " .. #oldKids
           .. " on the old one")
    FindAllOf = savedFAO
end)
