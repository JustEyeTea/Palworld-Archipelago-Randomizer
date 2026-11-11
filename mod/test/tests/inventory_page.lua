-- The in-game main menu: the Inventory page's mailbox and crate buttons, and the Esc menu's button beside it.
-- Tests menu_world.lua, menu.lua, clicks.lua.

group("the Inventory page's mailbox button", function()
    local MB = require("mailbox")
    -- The main menu, its Inventory tab and the page are fakes_menus.lua's MainMenu, inventoryTab and inventoryPage.
    game.escOpen = false
    MB.add("Wood", 5)                          -- something to count on the button
    run(1)
    -- Menus closed: one object scan per update, for the main menu only (open-questions: the FPS drop and FindAllOf).
    local escScans, mainScans = lookups.WBP_MenuESC_C or 0, lookups.WBP_InGameMainMenu_C or 0
    run(10)
    expect((lookups.WBP_MenuESC_C or 0) == escScans and (lookups.WBP_InGameMainMenu_C or 0) == mainScans + 10,
           "with the menus closed, only the main menu is looked for: " .. (lookups.WBP_MenuESC_C or 0) - escScans
           .. " Esc scans")
    -- Each tab widget the main menu shows is logged once, with the tab, so a missing button has a reason in the log.
    mainMenu = MainMenu(NamedWidget("WBP_MainMenu_Pal_C_1", "WBP_MainMenu_Pal_C"), 2)
    game.mainMenuOpen = true
    run(3)
    expect(countLoggedText("main menu content is WBP_MainMenu_Pal_C (tab 2)") == 1,
           "another tab: its widget class is logged once")
    mainMenu = MainMenu(inventoryTab(nil), 8)                  -- the Inventory tab's wrapper, but no page in it
    run(3)
    expect(countLoggedText("main menu content is WBP_InventoryEquipment_ForDisplay_C (tab 8)") == 1
           and countLoggedText("the main menu's WBP_InventoryEquipment_ForDisplay_C has no valid " ..
                               "WBP_InventoryEquipment; no mailbox button there") == 1,
           "an Inventory tab without its page: said once")
    -- A main menu whose Close fails: the HUD closes the button's owner instead.
    local fbPage, fbKids = inventoryPage()
    mainMenu = MainMenu(inventoryTab(fbPage), 8)
    mainMenu.Close = function() error("no Close") end
    run(1)
    local fbBtn = fbKids[1] and fbKids[1].child
    local ownerClosed = nil
    hud.CloseOwnerStackableUI = function(_, w)
        ownerClosed = w
        mainMenu.closed = true
    end
    local shownBefore = #chestWindowsShown
    h.clickCommonButton(fbBtn)
    run(1)
    expect(fbBtn and ownerClosed == fbBtn
           and logged("main menu closed for the mailbox from the inventory %(CloseOwnerStackableUI%)"),
           "if the main menu's Close fails, the HUD closes the button's owner")
    run(2)
    expect(#chestWindowsShown == shownBefore + 1 and chestWindowsShown[#chestWindowsShown].kind == 7,
           "and the mailbox opens: " .. #chestWindowsShown - shownBefore)
    expect(logged("in%-game main menu after closing from the inventory: gone"), "then looks whether the main menu went")
    h.closeChest()
    game.mainMenuOpen = false
    group("a card still remembered as hovered is forgotten once the main menu is closed", function()
        local slot = "Product_Cooking_Grade_01"                     -- owned through its item, not bought
        game.mainMenuOpen = true
        shared.info["Setup by Technology Name"](shared.info, FNameOf(slot))       -- no un-hover follows
        run(1)
        local whileOpen = shared.isResearched(slot)
        game.mainMenuOpen, game.escOpen = false, false                        -- closed under the pointer
        run(1)
        game.mainMenuOpen = nil
        expect(whileOpen == false and shared.isResearched(slot) == nil,
               "the game's answer again, for crafting and building: " .. tostring(whileOpen) .. ", "
               .. tostring(shared.isResearched(slot)))
    end)
    -- The main menu on its Inventory tab.
    local page, barKids, editName = inventoryPage()
    mainMenu = MainMenu(inventoryTab(page), 8)
    game.mainMenuOpen = true
    run(1)
    local invBox = barKids[1]
    local invBtn = invBox and invBox.child
    local emblemBox = barKids[2]                               -- the mailbox emblem, left of the button
    expect(emblemBox and emblemBox.child and emblemBox.child.texture
           and emblemBox.child.texture.path == "ap-mailbox-emblem-64"
           and emblemBox.width == 24 and emblemBox.halign == 3 and emblemBox.padding and emblemBox.padding.Right == 236,
           "with the mailbox emblem just left of it, 24 high")
    expect(#barKids == 3 and invBox.width == 230 and invBox.height == 28 and invBtn and invBtn.Text_Main
           and invBtn.Text_Main.text == "Archipelago Mailbox (1)",
           "the name bar gets the game's button, 230x28, with the count: " .. tostring(invBtn and invBtn.Text_Main
                                                                                       and invBtn.Text_Main.text))
    expect(invBox and invBox.halign == 3 and invBox.valign == 0, "at the bar's right end, as tall as the Edit Name row")
    expect(countLoggedText("the inventory page is WBP_InventoryEquipment_C "
                           .. "(via the main menu's CurrentContentWidget, tab 8)") == 1,
           "says it found the page through the main menu, with the tab")
    expect(logged("Mailbox button added to the inventory page %(WBP_CommonButton_C%) | %?:SizeBox/0 < " ..
                  "Overlay_0:Overlay < CanvasPanelChara:CanvasPanel < CanvasPanel_0:CanvasPanel"),
           "logged where it went, once")
    expect(hooks[GAME_PATH.commonClick], "its click is hooked")
    run(4)
    expect(#barKids == 3, "added once (the mailbox button, its emblem, the crate button)")
    expect(barKids[3] and barKids[3].vis == 1 and barKids[3].padding and barKids[3].padding.Right == 268,
           "the crate button waits, collapsed, left of the emblem until there is a crate")
    -- Focus probes: which of the bar's buttons a player reached, and with what input.
    game.inputSubsystems = { NamedWidget("CommonInputSubsystem_0", "CommonInputSubsystem",
                                         { GetCurrentInputType = function() return 1 end }) }
    editName.WBP_PalInvisibleButton.focused = true
    run(1)
    editName.WBP_PalInvisibleButton.focused = false
    if invBtn then
        invBtn.WBP_PalInvisibleButton.focused = true
    end
    run(2)
    expect(countLoggedText("the game's Edit Name button has focus (input 1 gamepad)") == 1
           and countLoggedText("the inventory mailbox button has focus (input 1 gamepad)") == 1,
           "focus is logged once each, with the input type")
    -- The click hook sees every WBP_CommonButton_C: the game's own Edit Name does nothing here.
    shownBefore = #chestWindowsShown
    h.clickCommonButton(editName)
    run(3)
    expect(not mainMenu.closed and #chestWindowsShown == shownBefore, "the game's own buttons are left alone")
    -- The tab picked again: a new wrapper and page. The old page stays valid until collected but is not the menu's.
    local page2, barKids2 = inventoryPage()
    mainMenu.CurrentContentWidget = inventoryTab(page2)
    run(1)
    local invBtn2 = barKids2[1] and barKids2[1].child
    expect(#barKids2 == 3 and #barKids == 3 and invBtn2 and invBtn2.Text_Main.text == "Archipelago Mailbox (1)"
           and countLoggedText("Mailbox button added to the inventory page") == 1,
           "a new page gets its button, quietly; the old one none again")
    -- Palworld Crates: with a crate waiting, the page's Open button shows it, and a click opens it on the next update.
    do
        local CR = require("crates")
        local saved, mailSaved = CR.list, {}
        for _, e in ipairs(MB.queue) do
            mailSaved[#mailSaved + 1] = { id = e.id, n = e.n }
        end
        CR.list = { "sphere" }
        run(1)
        local crateBox = barKids2[3]
        local crateBtn = crateBox and crateBox.child
        expect(crateBox and crateBox.vis == 0 and crateBtn and crateBtn.Text_Main
               and crateBtn.Text_Main.text == "Open: Sphere Crate",
               "the Inventory page shows Open with the next crate: " .. tostring(crateBtn and crateBtn.Text_Main
                                                                                 and crateBtn.Text_Main.text))
        if crateBtn then
            h.clickCommonButton(crateBtn)
        end
        expect(#CR.list == 1, "nothing opens inside the click's hook")
        run(1)
        expect(#CR.list == 0 and logged("crate: opened a Sphere Crate at level %d+: %d+ x ")
               and table.concat(announced, "|"):find("Opened a Sphere Crate: ", 1, true),
               "the next update opens it into the mailbox and says what was inside")
        run(1)
        expect(crateBox and crateBox.vis == 1, "with no crate left the button folds away")
        CR.list, MB.queue = saved, mailSaved               -- as it was, for the tests below
    end
    h.clickCommonButton(invBtn)                                        -- the old page's button: no longer ours
    run(1)
    expect(not mainMenu.closed, "a button on a page the menu let go of does nothing")
    h.clickCommonButton(invBtn2)
    expect(not mainMenu.closed, "nothing is closed inside the click's hook")
    run(1)
    expect(mainMenu.closed and logged("main menu closed for the mailbox from the inventory %(Close%)"),
           "the button closes the main menu on the next update, as its X button does")
    run(2)
    expect(#chestWindowsShown == shownBefore + 1 and chestWindowsShown[#chestWindowsShown].kind == 7,
           "then the mailbox opens: " .. #chestWindowsShown - shownBefore)
    h.closeChest()
    -- The Options tab: the Esc menu's button as before, nothing for the inventory.
    local escRoot2 = escMenu.WidgetTree
    for i = #escChildren, 4, -1 do
        escChildren[i] = nil
    end
    escMenu = Widget({ GetClass = function() return classed("WBP_MenuESC_C") end, WidgetTree = escRoot2,
                       Close = function(self) self.tabOnly = true end,
                       CloseAction = function(self)                    -- OnCloseEscMenu
                           self.closed = true
                           mainMenu:Close()
                       end })
    mainMenu = MainMenu(escMenu, 7)
    game.escOpen = true
    run(1)
    local mailBtn = escChildren[4]
    expect(mailBtn and mailBtn.Text_Main.text == "Archipelago Mailbox (1)"
           and countLoggedText("Mailbox button added to the inventory page") == 1,
           "the Esc menu still gets its button; the Options tab no inventory one")
    shownBefore = #chestWindowsShown
    h.clickEscButton(mailBtn)
    run(1)
    expect(escMenu.closed and not escMenu.tabOnly and mainMenu.closed,
           "the Esc button still closes the menu by CloseAction")
    run(2)
    expect(#chestWindowsShown == shownBefore + 1, "and opens the mailbox")
    h.closeChest()
    game.escOpen = false
    -- A client whose page has no such name bar: nothing added, said once, with a look at the page.
    local bare = NamedWidget("WBP_InventoryEquipment", "WBP_InventoryEquipment_C",
                       { WidgetTree = { RootWidget = Panel("CanvasPanel", { Panel("CanvasPanel", {}) }) } })
    mainMenu = MainMenu(inventoryTab(bare), 8)
    run(3)
    expect(countLoggedText("the inventory page has no name bar (no SizeBox_NameEdit; no Text_CharacterName)") == 1
           and countLoggedText("menu survey: inventory page | 0:?:CanvasPanel, 1:?:CanvasPanel") == 1,
           "no bar: said once, with the page's widgets")
    expect(not logged("inventory page error") and not logged("could not add the inventory"), "and no error")
    -- The world ends with the page up (a kick, a disconnect): its button's address must not stay ours. The click hook
    -- on WBP_CommonButton_C stays and fires at the title too (the connect window's OK is one), at a reused address.
    local lastPage, lastKids = inventoryPage()
    mainMenu = MainMenu(inventoryTab(lastPage), 8)
    run(1)
    local lastBtn = lastKids[1] and lastKids[1].child
    playerController.K2_GetPawn = function() return nil end      -- the world ended: the pawn reads nil
    run(1)
    local closeLines = countLoggedText("main menu closed for the mailbox")
    shownBefore = #chestWindowsShown
    h.clickCommonButton(lastBtn)
    run(3)
    expect(lastBtn and not mainMenu.closed and countLoggedText("main menu closed for the mailbox") == closeLines
           and #chestWindowsShown == shownBefore,
           "out of a world, a click at an old button's address does nothing")
    do   -- an error every update that names a new address each time is logged once
        inWorld(true)
        local raised, was = 0, mainMenu
        mainMenu = MainMenu(inventoryTab((inventoryPage())), 8)
        mainMenu.IsValid = function()
            raised = raised + 1
            error(string.format("boom at 0x%x", 4096 + raised))
        end
        game.mainMenuOpen = true
        run(5)
        mainMenu = was
        local lines = countLogged("menu: main menu error.*boom at")
        expect(raised >= 5 and lines == 1, "one line, not one an update: " .. lines .. " for " .. raised .. " errors")
    end
    game.mainMenuOpen, game.inputSubsystems = false, nil
    game.escOpen = false
    inWorld(false)
    noController()
    do   -- a page's mailbox button gone while the page is not: both buttons made again, and the old ones let go
        controllerAgain()
        inWorld(true)
        local CR = require("crates")
        local samePage, sameKids = inventoryPage()
        mainMenu = MainMenu(inventoryTab(samePage), 8)
        game.mainMenuOpen = true
        run(1)
        local oldMail, oldCrate = sameKids[1] and sameKids[1].child, sameKids[3] and sameKids[3].child
        if oldMail then
            oldMail.gone = true
        end
        run(1)
        local remade = #sameKids
        game.mainMenuOpen = false
        run(2)
        local saved = CR.list
        CR.list = { "sphere" }
        local stranger = Widget()                                -- a game button made later at the old one's address
        stranger.addr = oldCrate and oldCrate.addr
        h.clickCommonButton(stranger)
        run(2)
        local left = #CR.list
        CR.list = saved
        expect(oldCrate and remade == 6 and left == 1,
               "a crate button made again on the same page leaves no claim behind: a game button at the old one's "
               .. "address opens nothing: " .. left .. " crate(s) left")
        game.mainMenuOpen = false
        inWorld(false)
        noController()
    end
end)
