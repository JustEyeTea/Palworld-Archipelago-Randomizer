-- The shop's cards: each tech card of level 2 and up is a shop slot, labelled with what it sends in the multiworld,
-- its icon and whether it can still be bought. main.lua's update relabels the cards each update, when needed.
-- Tests: mod/test/tests/shop.lua; groups "shop cards", "cards are labelled again only when needed", "tooltips"
--   (tools/lua_harness.sh, in CI).
-- The shape of the shop: the update looks at the cards every 300 ms and relabels a card only when it changed (and every
-- card on a full pass, every 3 s), and the hooks (shop.lua) only change what the game's functions answer. No widget
-- is labelled, made or added inside a Blueprint hook: that crashed the game. The one exception is
-- the tooltip hook (shop.lua's tooltipSetup), which sets the tooltip's opacity and its caution note's visibility as
-- the game sets the tooltip up: deferred, the tooltip would show for a frame. Those two property sets make no widget,
-- and they have run inside the hook in every release.
local SHOP_CARDS = {}
local DATA = require("ap_data")
local PERF = require("perf")
local STATE = require("ap_state")
local TECHS = require("tech_icons")
local UTIL = require("util")
local WALLS = require("walls")
local WORLD = require("world")
local ICONS, STRUCTURES = TECHS.icons, TECHS.structures
local ap = STATE.ap
local keepAlive, log, once, safe = UTIL.keepAlive, UTIL.log, UTIL.once, UTIL.safe

-- What main.lua hands over (SHOP_CARDS.install).
--   dir     the mod's folder, where the icons are (icons\<kind>.png)
local env

-- Takes what main.lua hands over.
function SHOP_CARDS.install(handedOver)
    env = handedOver
end

-- State: forgotten never (each is kept alive in the game instance; one no longer valid is loaded again).
local textures = {}           -- icon kind -> its texture, or false when loading it failed
-- A failed load is remembered as false for the session, so it is not loaded again for every card on every update.
local function modIcon(kind, worldContext)
    local t = textures[kind]
    if t == false then return nil end
    if t and t:IsValid() then return t end
    local lib = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    if not lib or not lib:IsValid() then
        once("nolib", "KismetRenderingLibrary not found")
        return nil
    end
    local path = env.dir .. "\\icons\\" .. kind .. ".png"
    t = lib:ImportFileAsTexture2D(worldContext, path)
    if not (t and t:IsValid()) then
        textures[kind] = false
        log("could not load icon " .. path)
        return nil
    end
    textures[kind] = t
    keepAlive(t)
    return t
end

local techTextures = {}       -- tech id -> its icon's texture, or false when loading it failed (state, as textures)
-- A technology's own icon (an asset in the game), for slots that hold one of your techs.
function SHOP_CARDS.techIcon(tech)
    local t = techTextures[tech]
    if t == false then return nil end                 -- (failed before: see modIcon)
    if t and t:IsValid() then return t end
    local path = ICONS[tech]
    if not path then return nil end
    t = StaticFindObject(path)
    if not t or not t:IsValid() then
        pcall(LoadAsset, path)
        t = StaticFindObject(path)
    end
    if not (t and t:IsValid()) then
        techTextures[tech] = false
        log("could not load " .. path)
        return nil
    end
    techTextures[tech] = t
    keepAlive(t)
    return t
end

-- The icon a card shows for another item: by its most important flag (a trap's bit is not shown on a card).
local function iconKind(flags)
    if flags & STATE.ITEM_FLAGS.progression ~= 0 then return "progression" end
    if flags & STATE.ITEM_FLAGS.useful ~= 0 then return "useful" end
    return "filler"
end

-- The tech a slot holds when it holds one of your own techs (such cards show that tech as itself).
function SHOP_CARDS.ownTech(tech)
    local scouted = ap.scouted[DATA.shop[tech].loc]
    local it = scouted and scouted.own and DATA.items[scouted.id]
    return it and it.kind == "tech" and it.tech or nil
end

-- What a slot sends, as the card names it.
function SHOP_CARDS.rewardText(tech)
    local scouted = ap.scouted[DATA.shop[tech].loc]
    if not scouted then return "Archipelago item" end
    local mine = SHOP_CARDS.ownTech(tech)
    if mine then return DATA.shop[mine].name end
    if scouted.own then return "Your " .. scouted.item end
    return scouted.player .. "'s " .. scouted.item .. " (" .. scouted.game .. ")"
end

-- Whether a tech's card is a shop slot now: one of DATA.shop, once the shop is open (ap.shopOpen), and not in a world
-- known not to be the seed's (there the cards and the shop's hooks give the game's own answers).
function SHOP_CARDS.isShopSlot(tech)
    return ap.shopOpen and DATA.shop[tech] ~= nil and WORLD.seedWorld() ~= false
end
-- Whether a shop slot's check has been sent, or found checked.
function SHOP_CARDS.bought(tech) return ap.checked[DATA.shop[tech].loc] == true end

-- The game's own card categories, read off the level-1 cards (never relabelled) so they follow the game's language.
local categories = { structure = "Structures", item = "Items" }    -- state, forgotten never (the game's language)
-- Reads a level-1 card's category text into categories. Returns whether it found one.
local function readCategory(card, tech)
    local text = safe(function() return card.BP_PalTextBlock_Category:GetText():ToString() end)
    if type(text) == "string" and text ~= "" then
        categories[STRUCTURES[tech] and "structure" or "item"] = text
        return true
    end
    return false
end

-- A card the mod labelled is labelled again only when something says it needs it: setting every card's texts, icon
-- and click state on every update costs about 11 UE4SS calls a card (an estimated 1-3 ms an update with the menu's
-- 30-80 cards, unmeasured). So a card is skipped when its tech and what it should show are as last applied AND the
-- card itself still shows it: its name texts, its category, its icon and its click state are read back (cheap reads),
-- which catches the game setting a pooled card up again, or a text block re-applying its own text-table row on a
-- rebuild (a PalTextBlockBase does that). Anything that can't be read back counts as changed. Every 10th pass (3 s)
-- relabels every card anyway, as a safety net for anything those reads miss.
-- State: the cards. Forgotten: a card's entry once the card is no longer found (refreshCards), all of them when no
-- card is; readBack never (each is logged once a session).
local labelled = {}           -- card address -> { tech, sig, name, category, tex address, clickable } as last applied
local readBack = {}           -- which read-backs worked (each logged once)
-- Logs, once for each kind of read-back, whether reading it back from a card works.
local function logReadBackOnce(what, ok)
    if readBack[what] == nil then
        readBack[what] = ok
        local result = ok and " works" or " does not work (those cards are relabelled every update)"
        log("cards: reading back the " .. what .. result)
    end
end
-- Whether a card still shows what was last applied to it (seen), as its widgets read back.
local function stillShows(card, seen)
    local okt, text = pcall(function() return card.RichText_TechnologyName_Lock:GetText():ToString() end)
    logReadBackOnce("name", okt)
    if not okt or text ~= seen.name then return false end
    local oku, unlock = pcall(function() return card.RichText_TechnologyName_Unlock:GetText():ToString() end)
    logReadBackOnce("unlocked name", oku)
    if not oku or unlock ~= seen.name then return false end
    local okg, cat = pcall(function() return card.BP_PalTextBlock_Category:GetText():ToString() end)
    logReadBackOnce("category", okg)
    if not okg or cat ~= seen.category then return false end
    if seen.tex then
        local res = UTIL.addr(safe(function() return card.Image_Icon.Brush.ResourceObject end))
        logReadBackOnce("icon", res ~= nil)
        if res ~= seen.tex then return false end
    end
    local okc, on = pcall(function() return card.WBP_PalInvisibleButton:IsInteractionEnabled() end)
    logReadBackOnce("click state", okc)
    return okc and on == seen.clickable
end

-- A level-1 card's category is read until the game has filled it in (it can still be empty as the card is built),
-- then again only on a full pass or when the card shows another tech.
local function readStarterCategory(card, tech, key, full)
    if DATA.starters[tech] and (full or not labelled[key] or labelled[key].tech ~= tech) then
        labelled[key] = readCategory(card, tech) and { tech = tech } or nil
    end
end

-- A card's picture, the first of these that loads: your own tech's icon; the crate's art; an Area Pass's (Lock Size:
-- areas) own ticket (art/area-passes/ap-area-pass-<area>.png); a Region Pass's own region's ticket
-- (art/ap-pass-<region>.png), which an Area Pass falls back to; else the small-pass ticket (an area's, though its file
-- is ap-pass-region.png); else the mod's icon for the item's kind. Returns it and its source.
local AREA_PASS_ART = "area-passes\\ap-area-pass-"   -- an area's ticket: this, its slug (WALLS.slugOf), .png
local function cardPicture(mine, it, kind, card)
    local ART = require("art")
    local tex = mine and SHOP_CARDS.techIcon(mine)
    if tex then return tex, "the tech's own icon" end
    tex = it and it.name == "Palworld Crate" and ART.texture("ap-crate-palworld")
    if tex then return tex, "the crate's art" end
    if kind == "area-pass" then
        tex = it.name:find("^Area Pass") and ART.texture(AREA_PASS_ART .. WALLS.slugOf(it.lock))
        if tex then return tex, "its area's own pass ticket" end
        tex = ART.texture("ap-pass-" .. WALLS.slugOf(WALLS.regionOf(it.lock)))
        if tex then return tex, "its region's pass ticket" end
        tex = it.name:find("^Area Pass") and ART.texture("ap-pass-region")
        if tex then return tex, "the small-pass ticket" end
    end
    tex = modIcon(kind, card)
    return tex, tex and ("the mod's " .. kind .. " icon") or ("none (the mod's " .. kind .. " icon did not load)")
end

-- What a shop slot's card should show: { name, category, clickable, texture }.
local function cardLabel(tech, card)
    local sent, mine = SHOP_CARDS.bought(tech), SHOP_CARDS.ownTech(tech)
    local scouted = ap.scouted[DATA.shop[tech].loc]
    local own = scouted and scouted.own
    local category = mine and categories[STRUCTURES[mine] and "structure" or "item"]
        or (sent and (own and "Received" or "Sent") or "Archipelago")
    local name = ((sent and not own) and "Sent: " or "") .. SHOP_CARDS.rewardText(tech)
    local clickable = not sent or mine ~= nil
    local it = own and DATA.items[scouted.id]
    local kind = (it and it.kind == "pass") and "area-pass" or (scouted and iconKind(scouted.flags) or "filler")
    local tex, source = cardPicture(mine, it, kind, card)
    UTIL.took("cards: a card's picture", source)
    return { name = name, category = category, clickable = clickable, texture = tex }
end

-- One write to a card's widgets. The first write that fails in the session is logged, naming the widget; the card is
-- labelled again on a later pass, as its read-back no longer matches.
local function writeCard(widget, write)
    local ok, err = pcall(write)
    if not ok then
        once("cardwrite", "cards: could not set the " .. widget .. " (" .. tostring(err) .. ")")
    end
end

-- Sets a card's click state, name texts, category and icon to `label`.
local function applyLabel(card, label)
    -- A bought card does nothing when clicked (the game is told it cannot be researched). One showing your own tech
    -- stays interactive so its tooltip still works; the others are switched off outright.
    writeCard("click state", function() card.WBP_PalInvisibleButton:SetIsInteractionEnabled(label.clickable) end)
    local text = FText(label.name)
    writeCard("name text", function() card.RichText_TechnologyName_Lock:SetText(text) end)
    writeCard("unlocked name text", function() card.RichText_TechnologyName_Unlock:SetText(text) end)
    writeCard("category", function() card.BP_PalTextBlock_Category:SetText(FText(label.category)) end)
    if label.texture then
        writeCard("icon", function() card.Image_Icon:SetBrushFromTexture(label.texture, false) end)
    end
end

-- Labels one tech card as its shop slot (key: the card's address), unless it still shows that label; `full` labels it
-- anyway. The header: one of your techs looks like ordinary research (its own category, before and after buying);
-- your other items say "Received" once bought, other players' items "Sent".
function SHOP_CARDS.relabel(card, key, full)
    local tech = card.BindedTechnologyName:ToString()
    readStarterCategory(card, tech, key, full)
    if not SHOP_CARDS.isShopSlot(tech) then return end
    local label = cardLabel(tech, card)
    local tex = label.texture
    local texAddr = tex and UTIL.addr(tex) or nil
    local sig = label.name .. "\0" .. label.category .. "\0" .. tostring(label.clickable) .. "\0" .. tostring(texAddr)
    local seen = labelled[key]
    if not full and seen and seen.tech == tech and seen.sig == sig and stillShows(card, seen) then
        PERF.count("cardsSkipped")
        return
    end
    PERF.count("cards")
    applyLabel(card, label)
    labelled[key] = { tech = tech, sig = sig, name = label.name, category = label.category, tex = texAddr,
                      clickable = label.clickable }
end

-- State: forgotten never (cardPasses counts the session's passes); lastCards is replaced every update.
local cardPasses = 0          -- card passes so far: every FULL_RELABEL_EVERY-th relabels every card
local FULL_RELABEL_EVERY = UTIL.updates(3)   -- card passes, one per update: every card relabelled about every 3 s
local lastCards = nil         -- this update's cards (the Ctrl+0 old-load replay relabels them again)
-- Labels every tech card the menu has (relabel), each one in full on a full pass, and forgets cards no longer found.
function SHOP_CARDS.refreshCards(full)
    local cards = FindAllOf("WBP_MainMenu_Technology_Content_C")
    lastCards = cards
    if not cards then
        labelled = {}
        return
    end
    cardPasses = cardPasses + 1
    full = full or UTIL.isDue(cardPasses, FULL_RELABEL_EVERY)
    local current = {}
    for _, card in ipairs(cards) do
        local key = card:IsValid() and UTIL.addr(card)
        if key then
            current[#current + 1] = key
            local ok, err = pcall(SHOP_CARDS.relabel, card, key, full)
            if not ok then
                once("relabel", "relabel error: " .. tostring(err))
            end
        elseif key == nil then
            -- Its entry could not be told from another card's, so it is left alone.
            once("cardaddress", "cards: a card whose address can't be read is left alone")
        end
    end
    local kept = {}           -- cards gone are forgotten
    for _, key in ipairs(current) do
        kept[key] = labelled[key]
    end
    labelled = kept
end

-- Asks the tech tree to refresh its buttons, then labels every card in full (after a purchase or a new tech list).
function SHOP_CARDS.refreshTree()
    local tree = FindFirstOf("WBP_MainMenu_Technology_00_C")
    if tree and tree:IsValid() then
        safe(function() tree:UpdateAllTechnologyButton() end)
    end
    SHOP_CARDS.refreshCards(true)
end

-- The cards the last pass found (the perf probe's Ctrl+0 replay relabels them again).
function SHOP_CARDS.lastCards()
    return lastCards
end

return SHOP_CARDS
