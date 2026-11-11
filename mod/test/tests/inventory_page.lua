-- The in-game main menu: the Inventory page's mailbox and crate buttons, and the Esc menu's button beside it.
-- Tests menu_world.lua, menu.lua, clicks.lua.

group("the Inventory page's mailbox button", function()
    -- The in-game main menu (WBP_InGameMainMenu_C, kdump): CurrentContentWidget is the shown tab's widget. The Inventory
    -- tab's is a new WBP_InventoryEquipment_ForDisplay_C per visit, whose WBP_InventoryEquipment is the page. The page's
    -- name bar is CanvasPanelChara > Overlay_0 > HorizontalBox_0 > [SizeBox_NameEdit > WBP_CommonButton_NameEdit (Edit
    -- Name, a WBP_CommonButton_C) | Text_CharacterName]. The bar is no variable of the page: only GetParent reaches it.
    local COMMON_CLICK = "/Game/Pal/Blueprint/UI/UserInterface/Common/WBP_CommonButton.WBP_CommonButton_C:BndEvt__WBP_CommonButton_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_3_CommonButtonBaseClicked__DelegateSignature"
    local function commonClick(w) if hooks[COMMON_CLICK] then hooks[COMMON_CLICK]({ get = function() return w end }) end end
    local function named(name, class, extra)
        local w = Widget(extra)
        w.GetClass = function() return classed(class) end
        w.GetFName = function() return FNameOf(name) end
        return w
    end
    local function inventoryPage()
        local kids = {}
        local root = named("CanvasPanel_0", "CanvasPanel")
        local chara = named("CanvasPanelChara", "CanvasPanel", { GetParent = function() return root end })
        local bar = named("Overlay_0", "Overlay", { GetParent = function() return chara end })
        function bar:GetChildrenCount() return #kids end
        function bar:GetChildAt(i) return kids[i + 1] end
        function bar:AddChild(w)
            kids[#kids + 1] = w
            w.GetParent = function() return bar end
            return { SetHorizontalAlignment = function(_, a) w.halign = a end, SetVerticalAlignment = function(_, a) w.valign = a end,
                     SetPadding = function(_, p) w.padding = p end }
        end
        function chara:GetChildrenCount() return 1 end
        function chara:GetChildAt() return bar end
        function root:GetChildrenCount() return 1 end
        function root:GetChildAt() return chara end
        local row = named("HorizontalBox_0", "HorizontalBox", { GetParent = function() return bar end })
        local editBox = named("SizeBox_NameEdit", "SizeBox", { GetParent = function() return row end })
        local edit = named("WBP_CommonButton_NameEdit", "WBP_CommonButton_C", { GetParent = function() return editBox end,
                                                                                 WBP_PalInvisibleButton = Focusable() })
        local page = named("WBP_InventoryEquipment", "WBP_InventoryEquipment_C",
                           { SizeBox_NameEdit = editBox, WBP_CommonButton_NameEdit = edit,
                             Text_CharacterName = named("Text_CharacterName", "BP_PalTextBlock_C", { GetParent = function() return row end }),
                             WidgetTree = { RootWidget = root } })
        return page, kids, edit
    end
    local function inventoryTab(page, extra)
        local w = named("WBP_InventoryEquipment_ForDisplay_C_1", "WBP_InventoryEquipment_ForDisplay_C", extra)
        w.WBP_InventoryEquipment = page
        return w
    end
    local function MainMenu(tab, tabType)
        return named("WBP_InGameMainMenu_C_1", "WBP_InGameMainMenu_C", {
            CurrentContentWidget = tab, CurrentTabType = tabType,
            GetFullName = function() return "WBP_InGameMainMenu_C /Engine/Transient.GameEngine_0:PalGameInstance_0.WBP_InGameMainMenu_C_1" end,
            -- What its X button does; its Destruct then lets go of the tab (kdump: CurrentContentWidget = None).
            Close = function(self) self.closed = true; self.CurrentContentWidget = nil end,
            IsVisible = function(self) return not self.closed end, IsInViewport = function(self) return not self.closed end })
    end
    local function linesWith(text) local n = 0; for _, l in ipairs(printed) do if l:find(text, 1, true) then n = n + 1 end end; return n end
    local function closeChest() run(1); hudWindows["chest" .. #shown].gone = true; run(2) end   -- followed first, then closed
    escOpen = false
    require("mailbox").add("Wood", 5)                          -- something to count on the button
    run(1)
    -- Menus closed: one object scan per update, for the main menu only (open-questions: the FPS drop and FindAllOf).
    local escScans, mainScans = lookups.WBP_MenuESC_C or 0, lookups.WBP_InGameMainMenu_C or 0
    run(10)
    expect((lookups.WBP_MenuESC_C or 0) == escScans and (lookups.WBP_InGameMainMenu_C or 0) == mainScans + 10,
           "with the menus closed, only the main menu is looked for: " .. (lookups.WBP_MenuESC_C or 0) - escScans .. " Esc scans")
    -- Each tab widget the main menu shows is logged once, with the tab, so a missing button has a reason in the log.
    mainMenu = MainMenu(named("WBP_MainMenu_Pal_C_1", "WBP_MainMenu_Pal_C"), 2)
    mainMenuOpen = true
    run(3)
    expect(linesWith("main menu content is WBP_MainMenu_Pal_C (tab 2)") == 1, "another tab: its widget class is logged once")
    mainMenu = MainMenu(inventoryTab(nil), 8)                  -- the Inventory tab's wrapper, but no page in it
    run(3)
    expect(linesWith("main menu content is WBP_InventoryEquipment_ForDisplay_C (tab 8)") == 1
           and linesWith("the main menu's WBP_InventoryEquipment_ForDisplay_C has no valid WBP_InventoryEquipment; no mailbox button there") == 1,
           "an Inventory tab without its page: said once")
    -- A main menu whose Close fails: the HUD closes the button's owner instead.
    local fbPage, fbKids = inventoryPage()
    mainMenu = MainMenu(inventoryTab(fbPage), 8)
    mainMenu.Close = function() error("no Close") end
    run(1)
    local fbBtn = fbKids[1] and fbKids[1].child
    local ownerClosed = nil
    hud.CloseOwnerStackableUI = function(_, w) ownerClosed = w; mainMenu.closed = true end
    local shownBefore = #shown
    commonClick(fbBtn)
    run(1)
    expect(fbBtn and ownerClosed == fbBtn and logged("main menu closed for the mailbox from the inventory %(CloseOwnerStackableUI%)"),
           "if the main menu's Close fails, the HUD closes the button's owner")
    run(2)
    expect(#shown == shownBefore + 1 and shown[#shown].kind == 7, "and the mailbox opens: " .. #shown - shownBefore)
    expect(logged("in%-game main menu after closing from the inventory: gone"), "then looks whether the main menu went")
    closeChest()
    mainMenuOpen = false
    group("a card still remembered as hovered is forgotten once the main menu is closed", function()
        local slot = "Product_Cooking_Grade_01"                     -- owned through its item, not bought
        mainMenuOpen = true
        shared.info["Setup by Technology Name"](shared.info, FNameOf(slot))       -- no un-hover follows
        run(1)
        local whileOpen = shared.isResearched(slot)
        mainMenuOpen, escOpen = false, false                        -- closed under the pointer
        run(1)
        mainMenuOpen = nil
        expect(whileOpen == false and shared.isResearched(slot) == nil,
               "the game's answer again, for crafting and building: " .. tostring(whileOpen) .. ", "
               .. tostring(shared.isResearched(slot)))
    end)
    -- The main menu on its Inventory tab.
    local page, barKids, editName = inventoryPage()
    mainMenu = MainMenu(inventoryTab(page), 8)
    mainMenuOpen = true
    run(1)
    local invBox = barKids[1]
    local invBtn = invBox and invBox.child
    local emblemBox = barKids[2]                               -- the mailbox emblem, left of the button
    expect(emblemBox and emblemBox.child and emblemBox.child.texture and emblemBox.child.texture.path == "ap-mailbox-emblem-64"
           and emblemBox.width == 24 and emblemBox.halign == 3 and emblemBox.padding and emblemBox.padding.Right == 236,
           "with the mailbox emblem just left of it, 24 high")
    expect(#barKids == 3 and invBox.width == 230 and invBox.height == 28 and invBtn and invBtn.Text_Main
           and invBtn.Text_Main.text == "Archipelago Mailbox (1)",
           "the name bar gets the game's button, 230x28, with the count: " .. tostring(invBtn and invBtn.Text_Main and invBtn.Text_Main.text))
    expect(invBox and invBox.halign == 3 and invBox.valign == 0, "at the bar's right end, as tall as the Edit Name row")
    expect(linesWith("the inventory page is WBP_InventoryEquipment_C (via the main menu's CurrentContentWidget, tab 8)") == 1,
           "says it found the page through the main menu, with the tab")
    expect(logged("Mailbox button added to the inventory page %(WBP_CommonButton_C%) | %?:SizeBox/0 < Overlay_0:Overlay < CanvasPanelChara:CanvasPanel < CanvasPanel_0:CanvasPanel"),
           "logged where it went, once")
    expect(hooks[COMMON_CLICK], "its click is hooked")
    run(4)
    expect(#barKids == 3, "added once (the mailbox button, its emblem, the crate button)")
    expect(barKids[3] and barKids[3].vis == 1 and barKids[3].padding and barKids[3].padding.Right == 268,
           "the crate button waits, collapsed, left of the emblem until there is a crate")
    -- Focus probes: which of the bar's buttons a player reached, and with what input.
    inputSubsystems = { named("CommonInputSubsystem_0", "CommonInputSubsystem", { GetCurrentInputType = function() return 1 end }) }
    editName.WBP_PalInvisibleButton.focused = true
    run(1)
    editName.WBP_PalInvisibleButton.focused = false
    if invBtn then invBtn.WBP_PalInvisibleButton.focused = true end
    run(2)
    expect(linesWith("the game's Edit Name button has focus (input 1 gamepad)") == 1
           and linesWith("the inventory mailbox button has focus (input 1 gamepad)") == 1, "focus is logged once each, with the input type")
    -- The click hook sees every WBP_CommonButton_C: the game's own Edit Name does nothing here.
    shownBefore = #shown
    commonClick(editName)
    run(3)
    expect(not mainMenu.closed and #shown == shownBefore, "the game's own buttons are left alone")
    -- The tab picked again: a new wrapper and page. The old page stays valid until collected but is not the menu's.
    local page2, barKids2 = inventoryPage()
    mainMenu.CurrentContentWidget = inventoryTab(page2)
    run(1)
    local invBtn2 = barKids2[1] and barKids2[1].child
    expect(#barKids2 == 3 and #barKids == 3 and invBtn2 and invBtn2.Text_Main.text == "Archipelago Mailbox (1)"
           and linesWith("Mailbox button added to the inventory page") == 1, "a new page gets its button, quietly; the old one none again")
    -- Palworld Crates: with a crate waiting, the page's Open button shows it, and a click opens it on the next update.
    do
        local CR, MB = require("crates"), require("mailbox")
        local saved, mailSaved = CR.list, {}
        for _, e in ipairs(MB.queue) do mailSaved[#mailSaved + 1] = { id = e.id, n = e.n } end
        CR.list = { "sphere" }
        run(1)
        local crateBox = barKids2[3]
        local crateBtn = crateBox and crateBox.child
        expect(crateBox and crateBox.vis == 0 and crateBtn and crateBtn.Text_Main and crateBtn.Text_Main.text == "Open: Sphere Crate",
               "the Inventory page shows Open with the next crate: " .. tostring(crateBtn and crateBtn.Text_Main and crateBtn.Text_Main.text))
        if crateBtn then commonClick(crateBtn) end
        expect(#CR.list == 1, "nothing opens inside the click's hook")
        run(1)
        expect(#CR.list == 0 and logged("crate: opened a Sphere Crate at level %d+: %d+ x ") and table.concat(announced, "|"):find("Opened a Sphere Crate: ", 1, true),
               "the next update opens it into the mailbox and says what was inside")
        run(1)
        expect(crateBox and crateBox.vis == 1, "with no crate left the button folds away")
        CR.list, MB.queue = saved, mailSaved               -- as it was, for the tests below
    end
    commonClick(invBtn)                                        -- the old page's button: no longer ours
    run(1)
    expect(not mainMenu.closed, "a button on a page the menu let go of does nothing")
    commonClick(invBtn2)
    expect(not mainMenu.closed, "nothing is closed inside the click's hook")
    run(1)
    expect(mainMenu.closed and logged("main menu closed for the mailbox from the inventory %(Close%)"),
           "the button closes the main menu on the next update, as its X button does")
    run(2)
    expect(#shown == shownBefore + 1 and shown[#shown].kind == 7, "then the mailbox opens: " .. #shown - shownBefore)
    closeChest()
    -- The Options tab: the Esc menu's button as before, nothing for the inventory.
    local escRoot2 = escMenu.WidgetTree
    for i = #escChildren, 4, -1 do escChildren[i] = nil end
    escMenu = Widget({ GetClass = function() return classed("WBP_MenuESC_C") end, WidgetTree = escRoot2,
                       Close = function(self) self.tabOnly = true end, CloseAction = function(self) self.closed = true; mainMenu:Close() end })   -- OnCloseEscMenu
    mainMenu = MainMenu(escMenu, 7)
    escOpen = true
    run(1)
    local mailBtn = escChildren[4]
    expect(mailBtn and mailBtn.Text_Main.text == "Archipelago Mailbox (1)" and linesWith("Mailbox button added to the inventory page") == 1,
           "the Esc menu still gets its button; the Options tab no inventory one")
    shownBefore = #shown
    hooks[GAME_PATH.escClick]({ get = function() return mailBtn end })
    run(1)
    expect(escMenu.closed and not escMenu.tabOnly and mainMenu.closed, "the Esc button still closes the menu by CloseAction")
    run(2)
    expect(#shown == shownBefore + 1, "and opens the mailbox")
    closeChest()
    escOpen = false
    -- A client whose page has no such name bar: nothing added, said once, with a look at the page.
    local bare = named("WBP_InventoryEquipment", "WBP_InventoryEquipment_C",
                       { WidgetTree = { RootWidget = panel("CanvasPanel", { panel("CanvasPanel", {}) }) } })
    mainMenu = MainMenu(inventoryTab(bare), 8)
    run(3)
    expect(linesWith("the inventory page has no name bar (no SizeBox_NameEdit; no Text_CharacterName)") == 1
           and linesWith("menu survey: inventory page | 0:?:CanvasPanel, 1:?:CanvasPanel") == 1, "no bar: said once, with the page's widgets")
    expect(not logged("inventory page error") and not logged("could not add the inventory"), "and no error")
    -- The world ends with the page up (a kick, a disconnect): its button's address must not stay ours. The click hook on
    -- WBP_CommonButton_C stays and fires at the title too (the connect window's OK is one), at a reused address.
    local lastPage, lastKids = inventoryPage()
    mainMenu = MainMenu(inventoryTab(lastPage), 8)
    run(1)
    local lastBtn = lastKids[1] and lastKids[1].child
    playerController.K2_GetPawn = function() return nil end
    run(1)
    local closeLines = linesWith("main menu closed for the mailbox")
    shownBefore = #shown
    commonClick(lastBtn)
    run(3)
    expect(lastBtn and not mainMenu.closed and linesWith("main menu closed for the mailbox") == closeLines and #shown == shownBefore,
           "out of a world, a click at an old button's address does nothing")
    do   -- an error every update that names a new address each time is logged once
        playerController.K2_GetPawn = function() return pawn end
        local raised, was = 0, mainMenu
        mainMenu = MainMenu(inventoryTab((inventoryPage())), 8)
        mainMenu.IsValid = function()
            raised = raised + 1
            error(string.format("boom at 0x%x", 4096 + raised))
        end
        mainMenuOpen = true
        run(5)
        mainMenu = was
        local lines = 0
        for _, l in ipairs(printed) do
            if l:find("menu: main menu error", 1, true) and l:find("boom at", 1, true) then lines = lines + 1 end
        end
        expect(raised >= 5 and lines == 1, "one line, not one an update: " .. lines .. " for " .. raised .. " errors")
    end
    mainMenuOpen, inputSubsystems = false, nil
    escOpen = false
    playerController.K2_GetPawn, playerController.GetAddress = nil, nil

end)
