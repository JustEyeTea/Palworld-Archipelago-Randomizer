-- The shop's cards: each tech card of level 2 and up is a shop slot, labelled with what it sends in the multiworld,
-- its icon and whether it can still be bought. main.lua's update relabels the cards each update, when needed.
-- Tests: mod/test/harness.lua (run by tools/lua_harness.sh): groups "shop cards", "cards are labelled again only when
-- needed" and "tooltips".
-- The shop: cards relabelled every 300 ms (kit 9's shape: timer relabel plus two post-hooks, never widget work inside
-- Blueprint hooks, which crashed kits 5 and 6).
local SHOP_CARDS = {}
local D = require("ap_data")
local P = require("perf")
local STATE = require("ap_state")
local TECHS = require("tech_icons")
local UTIL = require("util")
local WALLS = require("walls")
local ICONS, STRUCTURES = TECHS.icons, TECHS.structures
local ap = STATE.ap
local keep, log, once, safe = UTIL.keep, UTIL.log, UTIL.once, UTIL.safe

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
local function icon(kind, ctx)
    local t = textures[kind]
    if t == false then return nil end
    if t and t:IsValid() then return t end
    local lib = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    if not lib or not lib:IsValid() then once("nolib", "KismetRenderingLibrary not found"); return nil end
    local path = env.dir .. "\\icons\\" .. kind .. ".png"
    t = lib:ImportFileAsTexture2D(ctx, path)
    if not (t and t:IsValid()) then
        textures[kind] = false
        log("could not load icon " .. path)
        return nil
    end
    textures[kind] = t
    keep(t)
    return t
end

-- A technology's own icon (an asset in the game), for slots that hold one of your techs.
local techTextures = {}       -- tech id -> its icon's texture, or false when loading it failed (state, as textures)
function SHOP_CARDS.techIcon(tech)
    local t = techTextures[tech]
    if t == false then return nil end                 -- (failed before: see icon)
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
    keep(t)
    return t
end

local function iconKind(flags)
    if flags & 1 ~= 0 then return "progression" end
    if flags & 2 ~= 0 then return "useful" end
    return "filler"
end

-- The tech a slot holds when it holds one of your own techs (such cards show that tech as itself).
function SHOP_CARDS.ownTech(tech)
    local r = ap.scouted[D.shop[tech].loc]
    local it = r and r.own and D.items[r.id]
    return it and it.kind == "tech" and it.tech or nil
end

-- What a slot sends, as the card names it.
function SHOP_CARDS.rewardText(tech)
    local r = ap.scouted[D.shop[tech].loc]
    if not r then return "Archipelago item" end
    local mine = SHOP_CARDS.ownTech(tech)
    if mine then return D.shop[mine].name end
    if r.own then return "Your " .. r.item end
    return r.player .. "'s " .. r.item .. " (" .. r.game .. ")"
end

function SHOP_CARDS.shopCard(tech) return ap.shopOpen and D.shop[tech] ~= nil end
function SHOP_CARDS.bought(tech) return ap.checked[D.shop[tech].loc] == true end

-- The game's own card categories, read off the level-1 cards (never relabelled) so they follow the game's language.
local categories = { structure = "Structures", item = "Items" }    -- state, forgotten never (the game's language)
local function readCategory(card, tech)
    local text = safe(function() return card.BP_PalTextBlock_Category:GetText():ToString() end)
    if type(text) == "string" and text ~= "" then categories[STRUCTURES[tech] and "structure" or "item"] = text; return true end
    return false
end

-- A card the mod labelled is labelled again only when something says it needs it. 6dd356e set every card's texts,
-- icon and click state on every update (about 11 UE4SS calls a card, an estimated 1-3 ms an update with the menu's
-- 30-80 cards, unmeasured). Now a card is skipped when its tech and what it should show are as last applied AND the
-- card itself still shows it: its name texts, its category, its icon and its click state are read back (cheap reads),
-- which catches the game setting a pooled card up again, or a text block re-applying its own text-table row on a
-- rebuild (issues-log: PalTextBlockBase). Anything that can't be read back counts as changed. Every 10th pass (3 s)
-- relabels every card anyway, as a safety net for anything those reads miss.
-- State: the cards. Forgotten: a card's entry once the card is no longer found (refreshCards), all of them when no
-- card is; readBack never (each is logged once a session).
local labelled = {}           -- card address -> { tech, sig, name, category, tex address, clickable } as last applied
local readBack = {}           -- which read-backs worked (logged once each, for the playtest)
local function noteRead(what, ok)
    if readBack[what] == nil then
        readBack[what] = ok
        log("cards: reading back the " .. what .. (ok and " works" or " does not work (those cards are relabelled every update)"))
    end
end
local function stillShows(card, seen)
    local okt, text = pcall(function() return card.RichText_TechnologyName_Lock:GetText():ToString() end)
    noteRead("name", okt)
    if not okt or text ~= seen.name then return false end
    local oku, unlock = pcall(function() return card.RichText_TechnologyName_Unlock:GetText():ToString() end)
    noteRead("unlocked name", oku)
    if not oku or unlock ~= seen.name then return false end
    local okg, cat = pcall(function() return card.BP_PalTextBlock_Category:GetText():ToString() end)
    noteRead("category", okg)
    if not okg or cat ~= seen.category then return false end
    if seen.tex then
        local oki, res = pcall(function() return tostring(card.Image_Icon.Brush.ResourceObject:GetAddress()) end)
        noteRead("icon", oki)
        if not oki or res ~= seen.tex then return false end
    end
    local okc, on = pcall(function() return card.WBP_PalInvisibleButton:IsInteractionEnabled() end)
    noteRead("click state", okc)
    return okc and on == seen.clickable
end

-- Card header: one of your techs looks like ordinary research (its own category, before and after buying); your
-- other items say "Received" once bought, other players' items "Sent".
function SHOP_CARDS.relabel(card, key, full)
    local tech = card.BindedTechnologyName:ToString()
    -- A level-1 card's category is read until the game has filled it in (it can still be empty as the card is built),
    -- then again only on a full pass or when the card shows another tech.
    if D.starters[tech] and (full or not labelled[key] or labelled[key].tech ~= tech) then
        labelled[key] = readCategory(card, tech) and { tech = tech } or nil
    end
    if not SHOP_CARDS.shopCard(tech) then return end
    local sent, mine = SHOP_CARDS.bought(tech), SHOP_CARDS.ownTech(tech)
    local r = ap.scouted[D.shop[tech].loc]
    local own = r and r.own
    local category = mine and categories[STRUCTURES[mine] and "structure" or "item"]
        or (sent and (own and "Received" or "Sent") or "Archipelago")
    local name = ((sent and not own) and "Sent: " or "") .. SHOP_CARDS.rewardText(tech)
    local clickable = not sent or mine ~= nil
    local it = own and D.items[r.id]
    local kind = (it and it.kind == "pass") and "area-pass" or (r and iconKind(r.flags) or "filler")
    -- A Region Pass shows its own region's ticket (art/ap-pass-<region>.png); an Area Pass (Lock Size: areas) its
    -- region's, else the small-pass ticket (ap-pass-region.png, named before the rename); else the shared one.
    local ART = require("art")
    local tex = mine and SHOP_CARDS.techIcon(mine)
        or (it and it.name == "Palworld Crate" and ART.texture("ap-crate-palworld"))
        or (kind == "area-pass" and (ART.texture("ap-pass-" .. WALLS.slugOf(WALLS.parentOf(it.area)))
                                     or (it.name:find("^Area Pass") and ART.texture("ap-pass-region"))))
        or icon(kind, card)
    local texAddr = tex and safe(function() return tostring(tex:GetAddress()) end) or nil
    local sig = name .. "\0" .. category .. "\0" .. tostring(clickable) .. "\0" .. tostring(texAddr)
    local seen = labelled[key]
    if not full and seen and seen.tech == tech and seen.sig == sig and stillShows(card, seen) then
        P.count("cardsSkipped")
        return
    end
    P.count("cards")
    -- A bought card does nothing when clicked (the game is told it cannot be researched). One showing your own tech
    -- stays interactive so its tooltip still works; the others are switched off outright.
    safe(function() card.WBP_PalInvisibleButton:SetIsInteractionEnabled(clickable) end)
    local text = FText(name)
    safe(function() card.RichText_TechnologyName_Lock:SetText(text) end)
    safe(function() card.RichText_TechnologyName_Unlock:SetText(text) end)
    safe(function() card.BP_PalTextBlock_Category:SetText(FText(category)) end)
    if tex then safe(function() card.Image_Icon:SetBrushFromTexture(tex, false) end) end
    labelled[key] = { tech = tech, sig = sig, name = name, category = category, tex = texAddr, clickable = clickable }
end

-- State: forgotten never (cardPasses counts the session's passes); lastCards is replaced every update.
local cardPasses = 0          -- card passes so far: every 10th relabels every card
local lastCards = nil         -- this update's cards (the Ctrl+0 old-load replay relabels them again)
function SHOP_CARDS.refreshCards(full)
    local cards = FindAllOf("WBP_MainMenu_Technology_Content_C")
    lastCards = cards
    if not cards then labelled = {}; return end
    cardPasses = cardPasses + 1
    full = full or cardPasses % 10 == 0
    local current = {}
    for _, card in ipairs(cards) do
        if card:IsValid() then
            local key = safe(function() return tostring(card:GetAddress()) end) or card
            current[#current + 1] = key
            local ok, err = pcall(SHOP_CARDS.relabel, card, key, full)
            if not ok then once("relabel", "relabel error: " .. tostring(err)) end
        end
    end
    local kept = {}           -- cards gone are forgotten
    for _, key in ipairs(current) do kept[key] = labelled[key] end
    labelled = kept
end

function SHOP_CARDS.refreshTree()
    local tree = FindFirstOf("WBP_MainMenu_Technology_00_C")
    if tree and tree:IsValid() then safe(function() tree:UpdateAllTechnologyButton() end) end
    SHOP_CARDS.refreshCards(true)
end

-- The cards the last pass found (the perf probe's Ctrl+0 replay relabels them again).
function SHOP_CARDS.lastCards()
    return lastCards
end

return SHOP_CARDS
