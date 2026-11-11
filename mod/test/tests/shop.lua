-- The Technology menu's shop: what each card shows, when cards are labelled again, the tooltips, and which slots
-- can be bought. Tests shop.lua and shop_cards.lua.

group("shop cards", function()
    expect(cards[1].shown.name == "Friend's Map Width (ChecksFinder)" and cards[1].shown.icon == "progression",
           "another player's item: " .. tostring(cards[1].shown.name) .. ", icon " .. tostring(cards[1].shown.icon))
    expect(cards[2].shown.category == "Estructuras", "your own tech carries the game's own category: "
           .. tostring(cards[2].shown.category))
    expect(cards[3].shown.category == "Archipelago" and cards[1].shown.category == "Archipelago",
           "other unbought slots say Archipelago")
    expect(cards[4].shown.category == "Estructuras" and cards[4].shown.name == nil, "level-1 cards untouched")
    expect(cards[2].shown.name == "Campfire" and tostring(cards[2].shown.icon):find("CampFire"),
           "your own tech shows as itself: " .. tostring(cards[2].shown.name) .. ", icon "
           .. tostring(cards[2].shown.icon))
    expect(cards[3].shown.name == "Your Wood Bundle" and cards[3].shown.icon == "filler",
           "your own filler: " .. tostring(cards[3].shown.name))
    expect(#kept >= 3, "textures kept alive: " .. #kept)
    local passCard = Card("Special_PalSphere_Grade_01")
    shared.passCard = passCard       -- your Region Pass's card: the buying tests read it again
    cards[#cards + 1] = passCard
    run(1)
    expect(passCard.shown.icon == "ap-pass-feybreak", "your Region Pass shows its own region's ticket: "
           .. tostring(passCard.shown.icon))

    do   -- a card whose address can't be read is skipped (its entry could not be told from another's)
        local nameless = Card("Product_Cooking_Grade_01")
        nameless.GetAddress = function() error("the card was freed") end
        cards[#cards + 1] = nameless
        run(1)
        table.remove(cards)
        expect(nameless.shown.name == nil, "a card with no readable address is left alone")
    end
    do   -- a card whose name text cannot be set says so, once
        local card = cards[3]
        local setText = card.RichText_TechnologyName_Lock.SetText
        card.RichText_TechnologyName_Lock.SetText = function() error("no text block here") end
        require("shop_cards").refreshCards(true)
        require("shop_cards").refreshCards(true)
        card.RichText_TechnologyName_Lock.SetText = setText
        expect(logged("cards: could not set the name text %(.*no text block here%)"),
               "a card's widget write that fails is logged, naming the widget")
    end
end)

group("cards are labelled again only when needed", function()
    local sets = cardSets
    run(9)
    expect(cardSets - sets <= 4, "a quiet menu: no card relabelled on every update (one full pass in 10): "
           .. (cardSets - sets) .. " name texts set in 9 updates")
    cards[1].shown.name = "Repair Bench"                         -- the game set the pooled card up again
    cards[3].Image_Icon:SetBrushFromTexture(Texture("T_icon_vanilla"))
    run(1)
    expect(cards[1].shown.name == "Friend's Map Width (ChecksFinder)" and cards[3].shown.icon == "filler",
           "a card the game set up again is labelled again on the next update: " .. tostring(cards[1].shown.name)
           .. ", " .. tostring(cards[3].shown.icon))
    run(1)
    cards[3].shown.category = "Items" -- a rebuild re-applied the category's own text-table row
    run(1)
    expect(cards[3].shown.category == "Archipelago", "a category the game reset is labelled again on the next update: "
           .. tostring(cards[3].shown.category))
    -- A level-1 card whose category the game has not filled in yet is read again on the next update, not 3 s later.
    local late = Card("Workbench")
    table.insert(cards, 1, late)
    run(1)
    late.shown.category = "Bauwerke"
    run(1)
    expect(cards[3].shown.category == "Bauwerke", "a level-1 category filled in late is read on the next update: "
           .. tostring(cards[3].shown.category))
    table.remove(cards, 1)
    run(10)                                                      -- a full pass reads the other level-1 card again
    expect(cards[2].shown.category == "Estructuras", "and back to the other level-1 card's category: "
           .. tostring(cards[2].shown.category))
end)

group("tooltips", function()
    local INFO = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/InventoryEquipment/"
        .. "WBP_InventoryEquipment_ItemInfo.WBP_InventoryEquipment_ItemInfo_C"
    local setupHook = hooks[INFO .. ":Setup by Technology Name"]
    local info = { IsValid = function() return true end, opacity = nil, shownFor = {},
                   WBP_InventoryEquipment_ItemInfo_Caution = { SetVisibility = function(self, v) self.vis = v end } }
    function info:SetRenderOpacity(o) self.opacity = o end
    shared.info = info               -- the tooltip widget: later groups show a tech's tooltip on it
    -- The game's own setup, followed by the hook (UE4SS runs it after the function).
    info["Setup by Technology Name"] = function(self, name)
        self.shownFor[#self.shownFor + 1] = name:ToString()
        setupHook(h.param(self), h.param(name))
    end
    info["Setup by Technology Name"](info, FNameOf("PalBox"))
    expect(info.shownFor[2] == "Product_Cooking_Grade_01" and info.opacity == 1.0,
           "a slot holding your tech shows that tech's tooltip: " .. table.concat(info.shownFor, ", "))
    expect(info.WBP_InventoryEquipment_ItemInfo_Caution.vis == 1, "its prerequisite note is hidden")
    info.shownFor = {}
    info["Setup by Technology Name"](info, FNameOf("RepairBench"))
    expect(#info.shownFor == 1 and info.opacity == 0.0, "another player's item has no tooltip")
    info["Setup by Technology Name"](info, FNameOf("Workbench"))
    expect(info.opacity == 1.0, "level-1 tooltips untouched")
end)

group("which slots can be bought", function()
    local unlockable = postHooks["/Script/Pal.PalTechnologyData:IsUnlockableRecipeTechnology"]
    -- As UE4SS calls it: the game's own result (a plain boolean) first, then the parameter.
    local function canBuy(tech) return unlockable(h.param(td), false, h.param(FNameOf(tech))) end
    shared.canBuy = canBuy           -- whether the game lets the player click the slot of this tech
    expect(canBuy("Special_PalSphere_Grade_01") == true, "a slot whose tech you own can still be bought")
    expect(canBuy("RepairBench") == nil, "a slot whose tech you lack: the game decides")
    expect(canBuy("Workbench") == nil, "level-1 techs: the game decides")
    local researched = postHooks["/Script/Pal.PalTechnologyData:IsUnlockRecipeTechnology"]
    local function isResearched(tech) return researched(h.param(td), true, h.param(FNameOf(tech))) end
    shared.isResearched = isResearched   -- the mod's answer to the game's 'is this researched?'
    expect(isResearched("Special_PalSphere_Grade_01") == nil,
           "owned slot, pointer elsewhere: the game's answer (crafting unaffected)")
    shared.info["Setup by Technology Name"](shared.info, FNameOf("Special_PalSphere_Grade_01"))
    expect(isResearched("Special_PalSphere_Grade_01") == false,
           "owned slot under the pointer: 'not researched yet', so it can be clicked")
    expect(isResearched("Product_Cooking_Grade_01") == nil, "another owned tech meanwhile: the game's answer")
    expect(logged("could not hook .*OnUnhoveredAnyTechnology_Internal yet")
           and logged("hooked .*OnUnhoveredAnyTechnology_Internal %(try"),
           "a Blueprint hook that failed to register is tried again and registered")
    local UNHOVERED = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Technology/"
        .. "WBP_MainMenu_Technology_00.WBP_MainMenu_Technology_00_C:OnUnhoveredAnyTechnology_Internal"
    hooks[UNHOVERED]()
    expect(isResearched("Special_PalSphere_Grade_01") == nil, "pointer gone: the game's answer again")
    td.TechnologyPoint = 0
    expect(canBuy("Special_PalSphere_Grade_01") == false, "not without the points")
    td.TechnologyPoint = 12
    -- A slot with a prerequisite, owned through its item, while the prerequisite is not.
    expect(canBuy("AutoMealPouch_Tier2") == nil, "Average Feed Bag (needs Small Feed Bag) not owned: the game decides")
    game.playerLevel = 20
    pushItem({ name = "Tech: Average Feed Bag" })
    runCycles(1)
    expect(canBuy("AutoMealPouch_Tier2") == false, "owned, but not without its prerequisite Small Feed Bag")
    pushItem({ name = "Tech: Small Feed Bag" })
    runCycles(1)
    expect(canBuy("AutoMealPouch_Tier2") == true, "and buyable once Small Feed Bag arrives")
    game.playerLevel = 4
    runCycles(1)
    expect(canBuy("AutoMealPouch_Tier2") == false, "not below the slot's level")
end)
