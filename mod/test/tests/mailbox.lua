-- The mailbox: the Esc menu's button, the hidden chest and its window, the LogicMod window.
-- Tests mailbox.lua, mailbox_chest.lua, mailbox_window.lua, bag.lua.

group("the mailbox", function()
    local MB = require("mailbox")
    local kinds, items = MB.count()
    expect(kinds == 1 and items == 50, "the Wood Bundle waits in the mailbox: " .. items)
    expect(h.saveText():find("mail=Wood:50\n", 1, true), "kept in the save file")
    expect(#announced > 0 and table.concat(announced, "|"):find("Esc menu > Archipelago Mailbox.", 1, true)
           and not table.concat(announced, "|"):find("Inventory", 1, true),
           "the player is told where it is: the Esc menu (the Inventory button is not named until a playtest "
           .. "has seen it)")
    inWorld(true)
    newController()
    -- First a client where no main menu is found by that class: the Esc menu is still looked for by its own, every 4th
    -- update (a fallback that costs a scan; every 4th update is a second late, not never).
    game.escOpen, game.escNoMain = true, true
    run(4)
    expect(escChildren[4] and logged("the Esc menu is up but no WBP_InGameMainMenu_C was found"),
           "no main menu: the Esc menu still gets its button")
    game.escNoMain = false                                          -- the usual client from here
    run(1)
    expect(#taskChildren == 3, "the HUD's mission list gets no button: " .. #taskChildren)
    local mailBtn = escChildren[4]
    expect(mailBtn and mailBtn.Text_Main and mailBtn.Text_Main.text == "Archipelago Mailbox (1)",
           "the Esc menu has a mailbox button in its own small style, with the count: "
           .. tostring(mailBtn and mailBtn.Text_Main and mailBtn.Text_Main.text))
    expect(mailBtn and mailBtn.MenuType == 0 and mailBtn.padding and mailBtn.padding.Top == 10,
           "spaced as the game's, and harmless if bound")
    expect(logged("the Esc menu is WBP_MenuESC_C"), "found the Esc menu by its buttons")
    expect(hooks[GAME_PATH.escClick], "its click is hooked")
    run(4)
    expect(#escChildren == 4, "added once")
    -- The game makes a new Esc menu each time it opens: the old one is forgotten, the new one gets a button, quietly.
    local oldEsc = escMenu
    oldEsc.gone = true
    escChildren[4] = nil
    escMenu = Widget({ GetClass = oldEsc.GetClass, WidgetTree = oldEsc.WidgetTree, Close = oldEsc.Close,
                       CloseAction = oldEsc.CloseAction })
    run(1) -- the button is there on the first update
    expect(escChildren[4], "a new Esc menu gets its button on the first update")
    run(3)
    mailBtn = escChildren[4]
    local addLines = countLoggedText("Mailbox button added")
    expect(mailBtn and mailBtn.Text_Main.text == "Archipelago Mailbox (1)" and addLines == 1,
           "a new Esc menu gets its button; logged once: " .. addLines)
    -- No LogicMod: the hidden chest. It is made on first use, 300 slots, with the chest template put back after.
    installChest()
    h.clickEscButton(mailBtn)
    expect(not escMenu.closed, "nothing is closed inside the click's hook")
    run(1)
    expect(escMenu.closed and not escMenu.tabOnly and logged("Esc menu closed for the mailbox %(CloseAction%)"),
           "the mailbox button closes the whole menu on the next update")
    run(3)
    expect(chestSpawnAsked == "ItemChest_04" and chests[1] and #chests[1].c.slots == 300,
           "a 300-slot chest is made: " .. tostring(chests[1] and #chests[1].c.slots))
    expect(chestTemplates[1].SlotNum == 54, "the chests players build keep their size")
    expect(chests[1].at.X == -1050000 and chests[1].at.Z == -40000, "far outside the map, under the ground")
    expect(logged("chest spawn asked, the game answered true"), "the spawn's answer is logged")
    run(2)
    local slots = chests[1].c.slots
    expect(#chestWindowsShown == 1 and chestWindowsShown[1].kind == 7
           and chestWindowsShown[1].param.MapObjectConcreteModel == chests[1], "the game's chest window opens on it")
    expect(slots[1].ItemId.StaticId:ToString() == "Wood" and slots[1].StackCount == 50, "filled from the mailbox")
    expect(chests[1].model.DeteriorationDamage == 0 and chests[1].model.DamagableType == 2 and chests[1].locked,
           "kept from decay and locked")
    expect(not h.saveText():find("mailview", 1, true),
           "the save holds the list only, with no line for an open view (nothing read it)")
    expect(chests[1].c.Permission.PermissionItemStaticIds.list[1]:ToString() == "AP_MailboxGivesOnly"
           and slots[7].Permission.PermissionItemStaticIds.list[1]:ToString() == "AP_MailboxGivesOnly"
           and logged("deposits refused by permission: container set, 300 slot%(s%)"),
           "the chest accepts nothing (the game's own rule)")
    run(1)
    expect(hudWindows["chest1"].WBP_IngameMenu_Chest.Text_TargetContainerName.text == "Archipelago Mailbox"
           and logged("heading was 'Advanced Chest'"), "the window is headed Archipelago Mailbox")
    local l0 = { ps = lookups.PalPlayerState or 0, pc = lookups.PalPlayerController or 0,
                 ffo = lookups["first:PalPlayerController"] or 0, chest = lookups.WBP_ItemChest_C or 0,
                 title = lookups.WBP_TitleMenu_C or 0 }
    run(10)
    expect((lookups.PalPlayerController or 0) - l0.pc == 10 and (lookups.PalPlayerState or 0) - l0.ps <= 10
           and (lookups["first:PalPlayerController"] or 0) == l0.ffo,
           "with the chest open: one controller and at most one player-state lookup per update: "
           .. ((lookups.PalPlayerController or 0) - l0.pc) .. ", " .. ((lookups.PalPlayerState or 0) - l0.ps))
    expect((lookups.WBP_ItemChest_C or 0) == l0.chest,
           "the chest widget is not looked for while the HUD's id says it is open")
    expect((lookups.WBP_TitleMenu_C or 0) - l0.title <= 1,
           "in a world the title menu is looked for every 10th update only: "
           .. ((lookups.WBP_TitleMenu_C or 0) - l0.title))
    slots[1].StackCount = 20                                   -- the player takes 30 Wood
    run(1)
    local bagWood = bagHas.Wood or 0
    slots[1].StackCount = 25                                   -- and puts 5 back
    slots[2].ItemId.StaticId, slots[2].StackCount = FNameOf("Sword"), 1    -- and a sword (gear: has per-item data)
    slots[2].ItemId.DynamicId.LocalIdInCreatedWorld.A = 7
    run(1)
    expect(slots[1].StackCount == 20 and (bagHas.Wood or 0) == bagWood + 5 and moves[1].to == 5
           and moves[1].index == 0 and moves[1].n == 5,
           "a deposit goes back to the bag by the game's move: " .. slots[1].StackCount)
    expect(slots[2]:IsEmpty() and bagHas.Sword == 1, "gear too")
    slots[2].ItemId = { StaticId = FNameOf("Sword"), DynamicId = { LocalIdInCreatedWorld = { A = 8, B = 0, C = 0,
                                                                                             D = 0 } } }
    slots[2].StackCount = 1                                    -- a second sword, into the same slot
    run(1)
    expect(slots[2]:IsEmpty() and bagHas.Sword == 2, "a second piece of gear in the same slot goes back too")
    expect(table.concat(announced, "|"):find("The mailbox only hands items out: Wood went back to your bag.", 1, true),
           "and the player is told")
    pushItem({ name = "Stone Bundle", from = "Friend" })   -- arrives meanwhile
    run(8)                                                     -- (bundles are applied every 7th update)
    expect(slots[2].ItemId.StaticId:ToString() == "Stone" and slots[2].StackCount == 50,
           "what arrives while it is open shows at once")
    -- Gear put into the first empty slot goes back by the game's move, and an item arrives in the same update: it takes
    -- the slot the move just emptied, as a refill over every slot would.
    slots[3].ItemId = { StaticId = FNameOf("Sword"), DynamicId = { LocalIdInCreatedWorld = { A = 9, B = 0, C = 0,
                                                                                             D = 0 } } }
    slots[3].StackCount = 1
    MB.add("Wood", 5)
    run(1)
    expect(slots[3].ItemId.StaticId:ToString() == "Wood" and slots[3].StackCount == 5 and slots[4]:IsEmpty(),
           "an item arriving takes the slot a returned deposit just left: " .. slots[3].ItemId.StaticId:ToString())
    -- taken out
    slots[3].ItemId, slots[3].StackCount = { StaticId = FNameOf("None"), DynamicId = slots[3].ItemId.DynamicId }, 0
    run(1)
    game.movesWork = false -- a move that does nothing: by hand after a few updates
    slots[2].StackCount = 53
    local givenBefore = #given
    run(5)
    expect(slots[2].StackCount == 50 and given[#given] == "Stone x3" and #given == givenBefore + 1
           and logged("did nothing; deposits are returned by hand"),
           "a deposit the move left is returned by hand, once: " .. slots[2].StackCount)
    MB.open(pawn)                              -- the mailbox key pressed again while it is open
    run(3)
    slots[1].StackCount = 21                                   -- put in just before closing (the move does nothing)
    hudWindows["chest1"].gone = true                           -- the player closes it
    run(1)
    expect(#chestWindowsShown == 1, "closed, it stays closed (the key pressed while it was open did nothing)")
    game.movesWork = true
    kinds, items = MB.count()
    expect(kinds == 2 and items == 70,
           "closed: what is left goes back into the mailbox, with what arrived meanwhile: " .. items)
    expect(given[#given] == "Wood x1" and logged("put in at the last moment went back to the bag"),
           "a last-moment deposit goes to the bag")
    expect(slots[1]:IsEmpty() and slots[2]:IsEmpty(), "the chest is emptied")
    expect(not logged("no chest window heading found"), "the heading is not looked for as the window closes")
    local saved = h.saveText()
    expect(saved:find("mail=Wood:20,Stone:50\n", 1, true), "saved: " .. saved)
    -- Open again: the chest is found, not made again. A plain stack left in it (a world save older than the mod's save,
    -- after a crash) is a copy: it goes before filling.
    slots[5].ItemId.StaticId, slots[5].StackCount = FNameOf("Wood"), 20
    h.clickEscButton(mailBtn)
    run(3)
    expect(#chests == 1 and #chestWindowsShown == 2 and slots[1].ItemId.StaticId:ToString() == "Wood"
           and slots[2].ItemId.StaticId:ToString() == "Stone",
           "found again by its place and filled")
    expect(slots[5]:IsEmpty(), "a leftover copy is cleared, not counted twice")
    run(1)
    hudWindows["chest2"].gone = true
    run(2)
    -- A chest window the mod can't follow (no widget for its id, no chest widget found): never emptied early; the next
    -- open settles it first.
    local showPlain = hud.ShowCommonUI
    hud.ShowCommonUI = function(self, k, p)
        showPlain(self, k, p)
        return "untracked"
    end
    h.clickEscButton(mailBtn)
    run(11)
    expect(logged("followed by unknown") and slots[1].StackCount == 20, "a window it can't follow is left alone")
    slots[1].StackCount = 5                                    -- the player takes 15 Wood
    hud.ShowCommonUI = showPlain
    h.clickEscButton(mailBtn)
    run(3)
    kinds, items = MB.count()
    expect(items == 55 and slots[1].StackCount == 5 and logged("followed by id"), "the next open settles it first: "
           .. items)
    h.closeChestWindow()
    run(2)
    -- The world changes while a view the mod can't follow is open: it is dropped, and the next open fills afresh.
    hud.ShowCommonUI = function(self, k, p)
        showPlain(self, k, p)
        return "untracked"
    end
    h.clickEscButton(mailBtn)
    run(11)
    slots[1].StackCount = 1                                    -- the copy left in the chest
    newController()                                            -- a new world
    run(1)
    hud.ShowCommonUI = showPlain
    expect(logged("the world changed; the open chest view is settled on the next open"),
           "a world change drops the view")
    h.clickEscButton(mailBtn)
    run(3)
    kinds, items = MB.count()
    expect(items == 55 and slots[1].StackCount == 5, "the next open fills from the list, not the copy: "
           .. slots[1].StackCount)
    do   -- what the mailbox found out in one world is logged again in the next
        local permissionLines = countLoggedText("deposits refused by permission")
        expect(permissionLines == 2, "a new world logs its own findings again (the chest's permission): "
               .. permissionLines)
    end
    run(1)
    h.closeChestWindow()
    run(2)
    -- Taken during a view it can't follow, then the world changes before that view is settled: what was taken left the
    -- list at once, so the next fill does not give it again.
    hud.ShowCommonUI = function(self, k, p)
        showPlain(self, k, p)
        return "untracked"
    end
    h.clickEscButton(mailBtn)
    run(11)
    local bagWoodBefore = bagHas.Wood or 0
    slots[1].StackCount = 1                                    -- the player takes 4 Wood
    bagHas.Wood = bagWoodBefore + 4
    run(1)
    newController()                                            -- a new world
    run(1)
    hud.ShowCommonUI = showPlain
    h.clickEscButton(mailBtn)
    run(3)
    local woodListed = 0
    for _, e in ipairs(MB.queue) do
        if e.id == "Wood" then
            woodListed = e.n
        end
    end
    expect(woodListed == 1 and slots[1].StackCount == 1 and bagHas.Wood - bagWoodBefore + woodListed == 5,
           "a take is off the list at once: 5 Wood in all, not 9: " .. woodListed .. " listed")
    run(1)
    h.closeChestWindow()
    run(2)
    -- With the LogicMod: its own window, one row per item; a row takes that item into the bag.
    game.logicMod = true
    local function PalButton()
        return Widget({ Label = { SetText = function(self, t) self.text = t.text end },
                        Btn = { SetKeyboardFocus = function(self) self.focused = true end } })
    end
    local winRows = {}
    local window = Widget({ List = { ClearChildren = function() winRows = {} end,
                                     AddChild = function(_, r) winRows[#winRows + 1] = r end },
                            Title = { SetText = function(self, t) self.text = t.text end },
                            Summary = { SetText = function(self, t) self.text = t.text end },
                            TakeAll = PalButton(), Close = PalButton() })
    local pushPlain = hud.Push
    hud.Push = function(self, cls, param)
        if tostring(cls.path):find("WBP_APMailbox", 1, true) then
            hudWindows["mail"] = window
            return "mail"
        end
        return pushPlain(self, cls, param)
    end
    local wblCreate = wbl.Create
    wbl.Create = function(_, _, cls) if tostring(cls.path):find("WBP_APButton", 1,
                                                                true) then return PalButton() end return wblCreate() end
    hookFailures.AP_Clicked = 1                                  -- its first opening: the button class still loading
    h.clickEscButton(mailBtn)
    run(3)
    local ROW_CLICK = "/Game/Mods/PalworldArchipelagoUI/WBP_APButton.WBP_APButton_C:AP_Clicked"
    expect(logged("mailbox: could not hook AP_Clicked yet") and not hooks[ROW_CLICK],
           "a failed hook of its buttons is logged")
    run(10)
    expect(hooks[ROW_CLICK] and hudWindows["mail"],
           "tried again within 3 s, with the window still open: its buttons work")
    expect(#winRows == 2 and winRows[1].Label.text == "Wood  x1" and winRows[2].Label.text == "Stone  x50",
           "the LogicMod window lists the mailbox: " .. tostring(winRows[1] and winRows[1].Label.text))
    expect(winRows[1].Btn.focused, "a controller starts on the first row")
    expect(hooks[ROW_CLICK], "its buttons are hooked")
    game.bagFull = true
    hooks[ROW_CLICK]({ get = function() return winRows[1] end })
    expect(#winRows == 2 and not table.concat(announced, "|"):find("Your bag is full", 1, true),
           "nothing happens inside the click's hook")
    run(1)
    expect(#winRows == 2 and table.concat(announced, "|"):find("Your bag is full: Wood stays in the mailbox.", 1,
                                                               true), "a full bag keeps the item")
    expect(logged("the bag refused Wood %(result 16%)"), "a refusal is logged")
    game.bagFull = false
    do   -- no inventory data (the player still loading): the item stays, and the bag is not called full
        local function fullTold()
            local n = 0
            for _, a in ipairs(announced) do
                if a:find("Your bag is full", 1, true) then
                    n = n + 1
                end
            end
            return n
        end
        local toldBefore, inventoryWas = fullTold(), ps.GetInventoryData
        ps.GetInventoryData = function() return nil end
        hooks[ROW_CLICK]({ get = function() return winRows[1] end })
        run(1)
        ps.GetInventoryData = inventoryWas
        expect(#winRows == 2 and fullTold() == toldBefore and logged("Wood stays in the mailbox: no bag")
               and logged("the player has no inventory data"),
               "no inventory data: the item stays, the log says why, and the player is not told the bag is full")
    end
    hooks[ROW_CLICK]({ get = function() return winRows[1] end })
    run(1)
    expect(given[#given] == "Wood x1" and #winRows == 1, "a row takes its item into the bag")
    hooks[ROW_CLICK]({ get = function() return window.TakeAll end })
    run(1)
    expect(given[#given] == "Stone x50" and #winRows == 0 and MB.count() == 0, "Take all empties it")
    expect(h.saveText():find("mail=\n", 1, true), "and the save")
    do   -- an item whose id reads like a button's action ("close") is still an item
        MB.add("close", 2)
        game.bagFull = true
        hooks[ROW_CLICK]({ get = function() return window.TakeAll end })   -- nothing fits: the window shows the row
        run(1)
        game.bagFull = false
        local row = winRows[1]
        hooks[ROW_CLICK]({ get = function() return row end })
        run(1)
        expect(row and given[#given] == "close x2" and not hudWindows["mail"].gone,
               "its row takes it into the bag, and the window stays open: " .. tostring(given[#given]))
    end
    hooks[ROW_CLICK]({ get = function() return window.Close end })
    run(1)
    hud.Push, wbl.Create, game.logicMod = pushPlain, wblCreate, false
    do   -- a new seed while the hidden chest is being made: the chest templates get their size back at once
        local chestsWere, spawnWas = chests, mapObjects.RequestSpawnMapObjectByPlayer_Server
        chests = {}
        mapObjects.RequestSpawnMapObjectByPlayer_Server = function() return true end   -- the chest never appears
        MB.add("Wood", 1)
        MB.open()
        run(3)
        local raised = chestTemplates[1].SlotNum
        MB.reset()
        local afterReset, toldBefore = chestTemplates[1].SlotNum, #announced
        run(25)
        local toldFailure = false
        for i = toldBefore + 1, #announced do
            if announced[i]:find("could not be made", 1, true) then
                toldFailure = true
            end
        end
        expect(raised == 300 and afterReset == 54 and not toldFailure and not MB.busy(),
               "the templates are put back with the reset, and nothing more is made or said: " .. tostring(afterReset))
        chests, mapObjects.RequestSpawnMapObjectByPlayer_Server = chestsWere, spawnWas
    end
end)
