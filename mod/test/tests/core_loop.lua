-- The core update's bookkeeping: frames, reconnecting, buying a slot, a player still loading, the save file and
-- the tech list compared only when needed. Tests main.lua, shop.lua, save.lua, tech_lock.lua.

group("updates queued in one engine frame (after a stall) run once", function()
    local walks, fao = 0, FindAllOf
    FindAllOf = function(class, ...)
        if class == "PalPlayerController" then walks = walks + 1 end
        return fao(class, ...)
    end
    for _ = 1, 5 do loop() end                              -- five hand-offs, the frame the last update ran in
    local sameFrame = walks
    frameCount = frameCount + 1
    loop()
    FindAllOf = fao
    expect(sameFrame == 0 and walks == 1, "none in the same frame, one in the next: " .. sameFrame .. ", " .. walks)
end)

group("reconnect does not repeat one-off items", function()
    local MB = require("mailbox")
    h.reconnect("Tester")
    pushItem({ name = "Wood Bundle", from = "Friend", index = 2 })
    pushItem({ name = "Tech Points +2", from = "Friend", index = 3 })
    runCycles(2)
    expect(#given == 0 and select(2, MB.count()) == 50 and td.TechnologyPoint == 12, "no second Wood Bundle or points")
end)

group("buying a slot", function()
    local research = hooks["/Script/Pal.PalNetworkPlayerComponent:RequestUnlockTechnology_ToServer"]
    local req = { v = FNameOf("RepairBench") }
    req.get = function(self) return self.v end
    req.set = function(self, v) self.v = v end
    shared.research, shared.req = research, req   -- the research hook and a request to call it with
    research(nil, req)
    expect(req.v:ToString() == "AP_ShopSlot", "request rewritten")
    expect(not checks[D.shop.RepairBench.loc], "the purchase waits for the next update (on the game thread; no ExecuteWithDelay)")
    run(1)
    expect(checks[D.shop.RepairBench.loc], "shop check sent")
    expect(td.TechnologyPoint == 12 - D.shop.RepairBench.cost, "points charged: " .. td.TechnologyPoint)
    local pointsBefore = td.TechnologyPoint
    req.v = FNameOf("RepairBench"); research(nil, req)
    expect(td.TechnologyPoint == pointsBefore, "a bought slot is not charged twice")
    expect(shared.canBuy("RepairBench") == false, "a bought slot cannot be bought again")
    req.v = FNameOf("PalBox"); research(nil, req)
    run(1)
    expect(cards[1].shown.clickable == false and cards[1].shown.category == "Sent", "bought card (another player's item) switched off")
    expect(cards[2].shown.category == "Estructuras", "bought, your tech still shows its own category")
    expect(cards[2].shown.clickable == true and cards[2].shown.name == "Campfire",
           "bought card showing your tech stays interactive for its tooltip: " .. tostring(cards[2].shown.name))
    req.v = FNameOf("Workbench"); research(nil, req)
    expect(req.v:ToString() == "Workbench", "level-1 research left alone")
end)

group("an update UE4SS runs inside a Blueprint hook skips its turn", function()
    local CONTENT = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Technology/WBP_MainMenu_Technology_Content."
        .. "WBP_MainMenu_Technology_Content_C:IsUnlocked"
    local walks, fao = 0, FindAllOf
    FindAllOf = function(class, ...)
        if class == "PalPlayerController" then walks = walks + 1 end
        return fao(class, ...)
    end
    local card = { BindedTechnologyName = FNameOf("RepairBench") }
    frameCount = frameCount + 1                             -- (a new frame: only the hook can stop it)
    hooks[CONTENT]({ get = function() loop(); return card end }, { set = function() end })
    FindAllOf = fao
    expect(walks == 0 and logged("update skipped: it came inside a hook"),
           "the card's IsUnlocked hook: no update ran inside it: " .. walks .. " controller walk(s)")
end)

group("a bought slot's check is sent again on every connection, and kept in the save file", function()
    local loc = D.shop.RepairBench.loc
    checks[loc] = nil                                -- as if it went into a socket that was already dead
    h.reconnect("Tester")
    run(1)
    expect(checks[loc], "after reconnecting, the purchase's check is sent again")
    runCycles(2)                                          -- (the save is written once the items are in again)
    local text = h.saveText()
    expect(text:find("bought=[%d,]*" .. loc),
           "the save file keeps the bought slot: " .. (text:match("bought=[^\n]*") or "none"))
end)

group("still loading into the world", function()
    td.valid = false
    local forEach = unlocked.ForEach
    unlocked.ForEach = function() error("Tried calling a member function but the UObject instance is nullptr") end
    runCycles(2)
    td.valid, unlocked.ForEach = true, forEach
    expect(not logged("update error"), "no errors while the player's tech data is not there yet")
end)

group("buying a slot: what the cards and the save file say afterwards", function()
    shared.req.v = FNameOf("Special_PalSphere_Grade_01"); shared.research(nil, shared.req)
    run(1)
    expect(shared.passCard.shown.category == "Received" and shared.passCard.shown.name == "Your Region Pass: Feybreak",
           "bought, your other items say Received: " .. tostring(shared.passCard.shown.category) .. " / " .. tostring(shared.passCard.shown.name))
    expect(cards[1].shown.name:find("^Sent: "), "other players' items keep the Sent: prefix")

    expect(h.saveText():match("given=" .. (nextItemIndex - 1)), "save file records items applied")   -- (every item so far)
end)

group("a save file that can't be written is logged, and the player told once", function()
    local MB = require("mailbox")
    local openWas = io.open
    io.open = function(path, mode)
        if (mode or ""):find("w", 1, true) and path:find("save%-[^\\/]*%.txt") then return nil, "Permission denied" end
        return openWas(path, mode)
    end
    MB.add("Stone", 1)                                        -- something new to save (as the test below does)
    runCycles(2)
    runCycles(2)                                                   -- (tried again: the text was never written)
    io.open = openWas
    local timesTold = 0
    for _, a in ipairs(announced) do if a:find("Can't write the mod's save file", 1, true) then timesTold = timesTold + 1 end end
    expect(logged("could not write .*save%-12345%-Tester%.txt%.tmp: Permission denied") and timesTold == 1,
           "the failure is logged with the reason, and the player is told once: " .. timesTold)
    table.remove(MB.queue)
end)

group("the save file is written only when it changes", function()
    local MB = require("mailbox")
    runCycles(2)                                                      -- (the purchase above is saved first: bought=)
    local writes = saveWrites
    runCycles(2)
    expect(saveWrites == writes, "nothing changed: not written again: " .. (saveWrites - writes) .. " write(s)")
    MB.add("Stone", 1)                                           -- mail alone changes (no item index moves)
    runCycles(1)
    expect(saveWrites == writes + 1 and h.saveText():find("Stone:1", 1, true),
           "mail that arrives is still saved")
    table.remove(MB.queue)
    runCycles(1)
end)

group("the tech list is compared only when it may have changed", function()
    local reads, forEachTechs = 0, unlocked.ForEach
    unlocked.ForEach = function(self, fn) reads = reads + 1; return forEachTechs(self, fn) end
    runCycles(2)
    expect(reads <= 1, "nothing changed: the list is not read on every poll: " .. reads .. " read(s) in 2 polls")
    unlocked.list[#unlocked.list + 1] = FNameOf("PalBox")      -- the game unlocks a shop tech by itself
    runCycles(1)
    local relocked = true
    for _, n in ipairs(unlocked.list) do if n:ToString() == "PalBox" then relocked = false end end
    expect(relocked, "a tech the game added is still locked again at the next poll")
    runCycles(1)
    local techDataWas = tdAddress
    reads = 0
    newTechData()                                                -- another world's TechnologyData, its list as long
    runCycles(1)
    local afterSwitch = reads
    runCycles(1)
    expect(afterSwitch == 1 and reads <= 2, "another TechnologyData with a list as long: compared at the next poll ("
           .. afterSwitch .. "), then skipped again (" .. reads .. ")")
    tdAddress = techDataWas
    unlocked.ForEach = forEachTechs
end)

group("an error every update is logged once", function()
    local MB = require("mailbox")
    local mailUpdate, boom = MB.update, 0
    MB.update = function() boom = boom + 1; error(string.format("boom at 0x%x (try %d)", 4096 + boom, boom)) end
    run(5)
    MB.update = mailUpdate
    local boomLines = countLogged("mailbox error: .*boom at")
    expect(boom == 5 and boomLines == 1, "an error naming a different address each time: one line, not " .. boom .. ": " .. boomLines)
end)
