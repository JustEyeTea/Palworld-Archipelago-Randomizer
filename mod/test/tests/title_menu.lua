-- The title menu's Archipelago menu: the banner, the typed fields, the saved servers, Connect, Back and Esc, and
-- what happens when its rows can't be made. Tests menu.lua, menu_title.lua, menu_title_banner.lua,
-- menu_title_rows.lua, menu_title_connect.lua, menu_survey.lua, text_window.lua.

group("the title menu's Archipelago menu", function()
    local MB = require("mailbox")
    -- The banner opens one Archipelago menu, the game's own title buttons swapped for ours in the same list. The
    -- fields are typed in the menu itself: Server, Port, Slot and Password are the game's own text box in the menu;
    -- the saved servers show under Server while it has the keyboard; the banner brightens under the pointer. Without
    -- a text box class, rows that open the text window (tested at the end).
    local WINDOW_OK = GAME_PATH.windowOk                       -- the text window's OK
    game.titleOpen = true
    -- A title menu whose buttons could not be made must not get a new banner every update (once it got 1,042).
    local realCreate = wbl.Create
    wbl.Create = function() return nil end
    run(3)
    expect(#titleCanvasKids == 0 and #menuChildren == 2 and not logged("title banner added"), "no rows, no banner")
    wbl.Create = realCreate
    run(1)
    -- On the list's canvas: the title banner (a 600 wide box) and the saved servers' panel (an Overlay).
    local bannerBox, drop
    for _, k in ipairs(titleCanvasKids) do
        if k.kind == "Overlay" then
            drop = drop or k
        elseif k.width == 600 then
            bannerBox = bannerBox or k
        end
    end
    expect(#titleCanvasKids == 2 and bannerBox and bannerBox.width == 600 and bannerBox.height == 150
           and bannerBox.child and bannerBox.child.kind == "Overlay"
           and #bannerBox.child.children == 4 and bannerBox.child.children[1].texture.path == "ap-title-banner",
           "the banner (600x150: picture, status dot, text, its button) goes on the canvas the buttons sit on")
    local openBtn = bannerBox and bannerBox.child.children[4]
    expect(openBtn and openBtn.Test_Content and openBtn.slot.h == 0 and openBtn.slot.v == 0 and openBtn.opacity == 0.02,
           "a title button over the whole banner, all but invisible")
    local pic = bannerBox and bannerBox.child.children[1]
    expect(pic and pic.slot.h == 0 and pic.slot.v == 0,
           "its picture fills it (v0.13.5 playtest: it kept the brush's 32x32)")
    local bs = bannerBox and bannerBox.canvasSlot
    expect(bs and bs.position.X == 0 and bs.position.Y == -588 and buttonBox.prepassed,
           "its bottom 8 above the list's top (the list measured first): " .. tostring(bs and bs.position.Y))
    expect(bs and bs.anchors.Minimum.X == 0.5 and bs.anchors.Maximum.Y == 1 and bs.alignment.X == 0.5
           and bs.alignment.Y == 1,
           "centred over the list, with the list's anchors")
    expect(bs and bs.size.X == 600 and bs.auto == false, "600 wide, at the size set (not sized to its content)")
    expect(logged("menu: title banner added on CanvasPanelMenu at 0,%-588"), "and says where")
    -- The list: Start Game (the game's), Server, six picks, Port, Slot, Password, Connect, Back, then Quit Game.
    -- (the panel's soft ends in pads of their own, above Server and below Back)
    local R = { padtop = 2, server = 3, port = 4, slot = 5, password = 6, go = 7, back = 8, padbottom = 9 }
    -- The saved servers: their panel on the canvas, its rows in its VerticalBox.
    local function pickBox(i) return drop.children[2].children[i] end
    local function pick(i) return pickBox(i).child end
    local function rowBox(i) return menuChildren[i] end
    -- (a row of ours: its size box, a dark Border, then the row: label and text box, or the button)
    local function inner(b)
        local c = b and b.child
        if c and c.kind == "Border" then
            c = c.child
        end
        return c
    end
    local function btn(i) return inner(menuChildren[i]) end
    local function edit(i) return inner(menuChildren[i]).children[2] end
    local function typed(i) return edit(i).Text:ToString() end
    local function typeInto(i, s) edit(i).Text = { ToString = function() return s end } end
    local allCollapsed = true
    for i = 2, 9 do
        if not (rowBox(i) and rowBox(i).vis == 1) then
            allCollapsed = false
        end
    end
    expect(#menuChildren == 10 and menuChildren[10] == quitWrap and quitWrap.padding and quitWrap.padding.Bottom == 7,
           "the menu's rows in the title's own list, Quit Game moved back to the end with its padding")
    expect(edit(R.server).kind == "PalEditableTextBox" and edit(R.server).colour and edit(R.password).password
           and inner(rowBox(R.server)).children[1].text == "Server:"
           and inner(rowBox(R.port)).children[1].text == "Port:"
           and inner(rowBox(R.server)).children[1].fontSize == 20,
           "Server, Port, Slot and Password: a label and the game's own text box, its text colour set (its style " ..
           "never copied)")
    expect(logged("fields typed in PalEditableTextBox"), "and the log says so")
    local allBacked = true
    for _, i in ipairs({ R.server, R.port, R.slot, R.password, R.go, R.back }) do
        local b = rowBox(i)
        if not (b and b.child and b.child.kind == "Border" and b.child.brush and b.child.brush.A > 0.5
                and b.height == 41
                and b.padding and b.padding.Bottom == 0) then allBacked = false end
    end
    expect(allBacked, "the menu's rows on a dark backing, 41 high with no gap, so they read as one panel (dev.33: " ..
                      "hard to read)")
    -- A row's backing: its picture's name, and its brush.
    local function piece(i)
        local b = rowBox(i).child
        return b.texture and b.texture.path, b.Background
    end
    local topPicture, topBrush = piece(R.padtop)
    local serverPicture, serverBrush = piece(R.server)
    local portPicture = piece(R.port)
    local goPicture = piece(R.go)
    local backPicture, backBrush = piece(R.back)
    local bottomPicture, bottomBrush = piece(R.padbottom)
    expect(topPicture == "ap-menu-panel-top" and topBrush.DrawAs == 1 and topBrush.Margin.Top == 0.25
           and topBrush.Margin.Bottom == 0 and topBrush.Margin.Left == 28 / 64 and rowBox(R.padtop).height == 24,
           "the panel's top edge (dev.34): a feathered piece drawn as a box, its soft end in a 24-high pad above "
           .. "Server")
    expect(serverPicture == "ap-menu-panel-mid" and serverBrush.Margin.Top == 0 and portPicture == "ap-menu-panel-mid"
           and goPicture == "ap-menu-panel-mid" and backPicture == "ap-menu-panel-mid" and backBrush.Margin.Bottom == 0
           and rowBox(R.server).child.pad.Left == 22,
           "the panel's middle: every text row from Server to Back on its solid part (dev.35: \"move the whole text " ..
           "area "
           .. "further down\")")
    expect(bottomPicture == "ap-menu-panel-bottom" and bottomBrush.Margin.Bottom == 0.25
           and bottomBrush.ImageSize.X == 64
           and rowBox(R.padbottom).height == 16,
           "the panel's bottom edge: a feathered piece drawn as a box, its soft end in a 16-high pad below Back")
    expect(logged("not a live title menu %(a template%), left alone: " ..
                  ".*/Game/Pal/Blueprint/UI/UserInterface/Title/WBP_Title"),
           "the title screen asset's template (dev.25 log: rows tried on it every update) is left alone")
    expect(not styleAssigned,
           "no text box's WidgetStyle is assigned from Lua (dev.21: the game crashed at the title), not even in a "
           .. "pcall")
    expect(allCollapsed and gameButtonWrap.vis ~= 1 and quitWrap.vis ~= 1,
           "the rows wait collapsed; the game's buttons show")
    expect(bannerTexts[#bannerTexts]:find("Connected | localhost:38281 | Slot: Tester", 1, true),
           "the banner shows the connection")
    local moves = bs and bs.moves
    run(3)
    expect(#menuChildren == 10 and #titleCanvasKids == 2, "added once")
    expect(drop and drop.kind == "Overlay" and drop.vis == 1 and #drop.children[2].children == 6
           and drop.canvasSlot.zorder == 20,
           "the saved servers wait in a panel of their own on the canvas, folded away (dev.25 test: in the list "
           .. "they pushed the rows down)")
    local st = edit(R.server).WidgetStyle
    expect(st.BackgroundColor.SpecifiedColor.A >= 0.95 and st.BackgroundColor.SpecifiedColor.R < 0.02
           and st.BackgroundColor.ColorUseRule == 0
           and st.FocusedForegroundColor.SpecifiedColor.R > 0.8 and logged("text boxes coloured"),
           "the boxes: a dark backing and light text, focused or not (dev.25 test: white boxes, pale text), written " ..
           "field by field")
    expect(bs and bs.moves == moves, "and the banner left where it is while the list keeps its size")
    expect(logged("Archipelago menu added to the title menu %(VerticalBox VerticalBox_Menu%); the banner opens it"),
           "found the box the Start Game button sits in")
    expect(logged("menu layout: WBP_Title_MenuButton_StartLocalGame | %?:SizeBox/0 < VerticalBox_Menu:VerticalBox"),
           "and logged the layout once")
    expect(hooks[GAME_PATH.titleClick] and hooks[WINDOW_OK], "their clicks and the text window's OK are hooked")
    -- The menu's ExecuteInGameThread runs at the next game tick, as in the game (the rest of the harness runs it at
    -- once).
    local queued, realGT = {}, ExecuteInGameThread
    ExecuteInGameThread = function(f)
        local source = debug.getinfo(2, "S").source             -- (the menu's files, and clicks.lua for its rows)
        if source:find("menu", 1, true) or source:find("clicks.lua", 1, true) then
            queued[#queued + 1] = f
        else
            f()
        end
    end
    local function tick()
        local q = queued
        queued = {}
        for _, f in ipairs(q) do
            f()
        end
    end
    local HOVER, UNHOVER = GAME_PATH.titleClick:gsub("Event_0_", "Event_1_"),
        GAME_PATH.titleClick:gsub("Event_0_", "Event_2_")
    expect(hooks[HOVER] and hooks[UNHOVER], "the title button's hover and unhover are hooked (kdump: events 1 and 2)")
    -- The banner must show it can be clicked: it waits a little dim and lights up under the pointer, from the
    -- button's own hover events (polling the pointer every 60 ms crashed the game on the title).
    expect(pic.colour and pic.colour.R < 1, "the banner waits a little dim")
    hooks[HOVER]({ get = function() return openBtn end })
    expect(pic.colour.R < 1, "nothing changes inside the hover's hook")
    tick()
    expect(pic.colour.R == 1 and bannerBox.scale and bannerBox.scale.X > 1
           and tostring(pic.texture.path):find("ap%-title%-banner%-hover"),
           "and lights up under the pointer: brighter, a little bigger, the hover picture (dev.22 test: it barely " ..
           "stood out)")
    hooks[UNHOVER]({ get = function() return openBtn end })
    tick()
    expect(pic.colour.R < 1 and bannerBox.scale.X == 1 and pic.texture.path == "ap-title-banner",
           "and goes back when it leaves")
    local function click(b)   -- (the click, then the next tick)
        hooks[GAME_PATH.titleClick]({ get = function() return b end })
        tick()
    end
    local function okWith(text)
        pushed[#pushed].OutString = text
        hooks[WINDOW_OK]()
        for id, w in pairs(hudWindows) do   -- the game closes the window
            w.gone = true
        end
        run(1)
    end
    local pushedBefore = #pushed
    hooks[GAME_PATH.titleClick]({ get = function() return openBtn end })
    expect(gameButtonWrap.vis ~= 1 and pic.texture.path ~= "ap-title-banner-pressed",
           "nothing changes inside the click's hook")
    tick()
    expect(gameButtonWrap.vis == 1 and rowBox(R.server).vis == 0 and pic.texture.path == "ap-title-banner-pressed",
           "at the next tick the menu is open (the user, dev.24 test: at once, not at the next update), the banner " ..
           "pressed")
    run(2)
    expect(pic.texture.path == "ap-title-banner", "and its own picture again by the next update")
    expect(gameButtonWrap.vis == 1 and quitWrap.vis == 1 and rowBox(R.server).vis == 0 and rowBox(R.port).vis == 0
           and rowBox(R.go).vis == 0 and rowBox(R.back).vis == 0 and drop.vis == 1
           and logged("Archipelago menu opened"),
           "the banner opens the menu: the game's buttons fold away, the rows show (the saved servers not yet)")
    expect(typed(R.server) == "localhost" and typed(R.port) == "38281" and typed(R.slot) == "Tester"
           and typed(R.password) == ""
           and btn(R.go).Test_Content.text == "Disconnect (connected as Tester)"
           and btn(R.back).Test_Content.text == "Back",
           "the boxes hold the connection's server, port, slot and password: " .. typed(R.server))
    expect(io.open(MOD .. "/config.txt"):read("*a"):find("servers=localhost", 1, true)
           and logged("servers: remembered localhost"),
           "a server connected to is remembered (archipelago.gg is always offered)")
    edit(R.server).focus = true
    run(1)
    expect(drop.vis == 0 and pickBox(1).vis == 0 and pickBox(2).vis == 0 and pickBox(3).vis == 1,
           "while the Server box has the keyboard, the saved servers show: two rows, the third folded away")
    expect(pickBox(1).width == 420 and pick(1).Test_Content.text:find("archipelago.gg", 1, true)
           and pick(2).Test_Content.text:find("localhost   (chosen)", 1, true),
           "the saved servers are archipelago.gg and localhost (chosen), 420 wide: " .. pick(2).Test_Content.text)
    expect(drop.canvasSlot.position and drop.canvasSlot.position.Y == -588 + 8 + 24 + 41
           and drop.canvasSlot.alignment.Y == 0,
           "their panel sits just under the Server box")
    -- The saved servers must not stick around: they stay only while the pointer is on one of them (pressing it takes
    -- the keyboard from the box before the click lands), and go at the next update otherwise.
    edit(R.server).focus = false
    hooks[HOVER]({ get = function() return pick(2) end })
    tick()
    run(1)
    expect(drop.vis == 0, "the Server box left with the pointer on a saved server: they stay")
    hooks[UNHOVER]({ get = function() return pick(2) end })
    tick()
    run(1)
    expect(drop.vis == 1, "the pointer gone too: they go at the next update")
    edit(R.server).focus = true
    run(1)
    edit(R.server).focus = false -- the click on a saved server takes the keyboard away
    hooks[HOVER]({ get = function() return pick(1) end })
    tick()
    click(pick(1))
    run(1)
    expect(typed(R.server) == "archipelago.gg"
           and btn(R.go).Test_Content.text == "Connect to archipelago.gg:38281 as Tester",
           "a saved server picked fills the Server box; the last row offers to connect there")
    run(1)
    expect(drop.vis == 1,
           "then the saved servers fold away at the next update (dev.25 and dev.27 tests: they lingered)")
    typeInto(R.port, "40000")
    typeInto(R.slot, "Other")
    typeInto(R.password, "secret")
    run(1)
    expect(btn(R.go).Test_Content.text == "Connect to archipelago.gg:40000 as Other" and #pushed == pushedBefore,
           "typed in the menu: no text window")
    edit(R.server).focus = true
    typeInto(R.server, "72.60.29.30:38281")
    run(1)
    expect(typed(R.server) == "72.60.29.30:38281"
           and btn(R.go).Test_Content.text == "Connect to 72.60.29.30:38281 as Other",
           "host:port typed in the Server box counts at once, and is left as typed while the box has the keyboard")
    edit(R.server).focus = false
    run(1)
    expect(typed(R.server) == "72.60.29.30" and typed(R.port) == "38281", "left, the port moves to its own box")
    typeInto(R.server, "archipelago.gg")
    typeInto(R.port, "40000")
    run(1)
    local connectsBefore = #connects
    click(btn(R.go))
    run(1)
    local c = connects[#connects]
    expect(#connects == connectsBefore + 1 and c.server == "archipelago.gg:40000" and c.slot == "Other"
           and c.password == "secret",
           "Connect connects with them, replacing the connection there was")
    local cfgText = io.open(MOD .. "/config.txt"):read("*a")
    expect(cfgText:find("server=archipelago.gg:40000", 1, true) and cfgText:find("slot=Other", 1, true)
           and cfgText:find("servers=localhost", 1, true),
           "saved to config.txt, the saved servers kept")
    slotData.seed = "67890"
    push("status", "connected", "Other")
    run(1)
    expect(logged("progress of the last one forgotten"), "a different seed starts afresh")
    run(1)
    expect(gameButtonWrap.vis == 0 and rowBox(R.server).vis == 1 and logged("Archipelago menu closed"),
           "connected: back to the title's own buttons")
    expect(not io.open(MOD .. "/config.txt"):read("*a"):find("archipelago.gg,", 1, true),
           "archipelago.gg is not saved: it is always there")
    -- A slot the server refuses: what is in memory is still Other's, and is saved as Other's, not under the refused
    -- name.
    MB.add("Wood", 10)
    runCycles(1)
    click(openBtn)
    run(1)
    typeInto(R.slot, "Typo")
    typeInto(R.password, "")
    run(1)
    click(btn(R.go))
    run(1)
    push("status", "refused", "InvalidSlot")
    run(1)
    expect(gameButtonWrap.vis == 1, "refused: the menu stays open to fix it")
    inWorld(true)
    local took = MB.takeAll()
    inWorld(false)
    expect(took == 10 and h.saveText("67890", "Other"):find("mail=\n", 1, true)
           and not io.open(h.saveFile("67890", "Typo")),
           "a refused slot: the take is saved in the connected slot's file")
    typeInto(R.slot, "Other")
    run(1)
    click(btn(R.go))
    run(1)
    push("status", "connected", "Other")
    run(2)
    -- Back closes without connecting; reopened, the menu starts from the connection, and its last row disconnects.
    click(openBtn)
    run(1)
    typeInto(R.server, "72.60.29.30")
    run(1)
    local cb = #connects
    local backAt = logMark()
    click(btn(R.back))
    run(1)
    expect(gameButtonWrap.vis == 0 and #connects == cb and loggedSince(backAt, "Archipelago menu closed"),
           "Back: the game's buttons again, nothing connected")
    -- Esc backs out of the Archipelago menu: it does what Back does.
    click(openBtn)
    run(1)
    typeInto(R.server, "10.0.0.9")
    run(1)
    local escBind = keyBinds["key:ESCAPE"]
    if escBind then
        escBind()
    end
    tick()   -- (the key's work, at the next game tick)
    run(1)
    expect(escBind and gameButtonWrap.vis == 0 and rowBox(R.server).vis == 1 and #connects == cb
           and logged("Esc closes the Archipelago menu"),
           "Esc closes the menu as Back does: the game's buttons again, nothing connected")
    if escBind then
        escBind()
    end
    tick()
    run(1)
    expect(gameButtonWrap.vis == 0 and #connects == cb, "Esc with the menu closed: nothing happens")
    click(openBtn)
    run(1)
    expect(typed(R.server) == "archipelago.gg" and btn(R.go).Test_Content.text == "Disconnect (connected as Other)",
           "reopened, it starts from the connection: " .. typed(R.server))
    click(btn(R.go))
    run(1)
    expect(disconnects == 1 and btn(R.go).Test_Content.text:find("^Connect to archipelago%.gg:40000 as Other"),
           "its last row disconnects")
    click(btn(R.go))
    run(1)
    push("status", "connected", "Other")
    run(2)
    local goBtn = btn(R.go)
    -- After Options and the Survival Guide our rows can be gone from the title menu and the remake can fail; using
    -- the old rows then crashed the game 4.6 s later, so the old rows are never touched again.
    do
        local deadTouched = false
        for i = 2, 9 do
            local b = rowBox(i)
            if b then
                b.gone = true
                b.SetVisibility = function() deadTouched = true end
            end
            if b and b.child then
                b.child.gone = true
            end
            local c = inner(b)                                           -- (through the Border)
            if c then
                c.gone = true
            end
        end
        local create = wbl.Create
        wbl.Create = function() return nil end
        run(3)
        expect(not deadTouched and logged("our rows are gone from a title menu still there")
               and logged("could not add the Archipelago menu's rows: .*%(try %d%)")
               and logged("the old banner taken away"),
               "our rows gone and the remake failing: logged, and the old rows never touched again")
        wbl.Create = create
        local rowsBefore = #menuChildren
        run(2)
        expect(#menuChildren > rowsBefore and logged("Archipelago menu added to the title menu"),
               "then made again once it can be")
    end
    do   -- one test of "in a world": a pawn the lookup answers with, even one not valid, counts
        local notValid = Widget({ IsValid = function() return false end })
        game.titleOpen = false                                       -- (no title menu up: it is only looked for)
        playerController.K2_GetPawn = function() return notValid end
        newController()
        run(1)
        local looks = lookups.WBP_TitleMenu_C or 0
        run(10)
        local inTen = (lookups.WBP_TitleMenu_C or 0) - looks
        inWorld(false)
        noController()
        game.titleOpen = true
        run(2)
        expect(inTen <= 1,
               "in a world, the title menu is looked for every 10th update, as the world buttons see it: " .. inTen)
    end
    -- A title menu while the player's pawn is in a world (should the in-world test be wrong in the game): found within
    -- 10 updates, logged, and looked for every update again.
    inWorld(true)
    controllerAgain()
    run(10)
    expect(logged("a title menu was found with the player's pawn in a world"), "a title menu seen in a world is logged")
    inWorld(false)
    noController()
    game.titleOpen = false
    run(1)
    -- In a world the title menu is gone; a game title button made later at a freed address of ours is not ours.
    local disconnectsBefore, pushedBefore = disconnects, #pushed
    hooks[GAME_PATH.titleClick]({ get = function() return Widget({ addr = goBtn.addr }) end })
    hooks[GAME_PATH.titleClick]({ get = function() return Widget({ addr = openBtn.addr }) end })
    run(1)
    expect(disconnects == disconnectsBefore and #pushed == pushedBefore,
           "our old title buttons' addresses are forgotten")
    -- Without a text box class (neither the game's nor UMG's): rows that open the text window, one per field (its
    -- heading is set where the window has one).
    game.palEditOk, game.umgEditOk = false, false
    for i = #menuChildren, 1, -1 do
        menuChildren[i] = nil
    end
    menuChildren[1], menuChildren[2] = gameButtonWrap, quitWrap
    gameButtonWrap.vis, quitWrap.vis = 0, 0
    game.titleOpen = true
    run(2)
    expect(#menuChildren == 9
           and logged("typed fields not made %(no text box class%); the text window instead %(try %d%)")
           and logged("fields in the text window"), "no text box: the rows with the text window")
    click(titleCanvasKids[#titleCanvasKids].child.children[4])
    run(1)
    click(menuChildren[4].child)   -- Port (after Server and Type a server address)
    run(1)
    expect(#pushed == pushedBefore + 1 and pushed[#pushed].DefaultInputName == "40000",
           "Port opens the text window, filled in")
    okWith("40001")
    expect(menuChildren[4].child.Test_Content.text == "Port: 40001", "and sets the port")
    game.titleOpen = false
    run(1)
    game.palEditOk, game.umgEditOk = nil, nil
    ExecuteInGameThread = realGT
    do   -- a title menu whose rows kept failing, gone and back at the same address: tried again at once
        local function added() return countLoggedText("Archipelago menu added to the title menu") end
        local create = wbl.Create
        wbl.Create = function() return nil end
        game.titleOpen = true
        run(13)                                                 -- builds failing every update, then every 10th
        game.titleOpen = false
        run(1)                                                  -- the menu goes
        wbl.Create = create
        for i = #menuChildren, 1, -1 do
            menuChildren[i] = nil
        end
        menuChildren[1], menuChildren[2] = gameButtonWrap, quitWrap
        gameButtonWrap.vis, quitWrap.vis = 0, 0
        game.titleOpen = true                                        -- back, at the address it had
        local addedBefore = added()
        run(1)
        expect(added() == addedBefore + 1, "its rows are made on the first update it is back, not after a backoff")
        game.titleOpen = false
        run(1)
    end
    do   -- a button whose label the mod can't set (the game's widget changed) says so, once
        local WIDGETS = require("widgets")
        WIDGETS.setLabel(Widget({}), "Archipelago Mailbox")
        WIDGETS.setLabel(Widget({}), "Archipelago Mailbox")
        local lines = countLoggedText("a button has neither Text_Main nor Test_Content")
        expect(lines == 1, "a label that can't be set is logged once: " .. lines)
    end
    do   -- the fallback chains say once which branch they took
        expect(logged("menu: the button list: the panel above WBP_Title_MenuButton_StartLocalGame")
               and logged("widgets: a button's label: Test_Content") and logged("widgets: a button's label: Text_Main")
               and logged("menu: a text box's text: its Text field")
               and logged("util: WBP_APMailbox_C: not there, even after loading its package"),
               "the button list, a label, a text box's text and a class each say where they came from")
    end
    do   -- a server written with its scheme (wss://, as the connector takes it) keeps it in the menu
        local CONFIG = require("config")
        local serverWas, slotWas = CONFIG.cfg.server, CONFIG.cfg.slot
        CONFIG.cfg.server, CONFIG.cfg.slot = "wss://myhost.example:38281", "Other"
        push("status", "connected", "Other")
        for i = #menuChildren, 1, -1 do
            menuChildren[i] = nil
        end
        menuChildren[1], menuChildren[2] = gameButtonWrap, quitWrap
        gameButtonWrap.vis, quitWrap.vis = 0, 0
        game.titleOpen = true
        run(2)
        click(titleCanvasKids[#titleCanvasKids].child.children[4])
        run(2)
        local goText = btn(R.go) and btn(R.go).Test_Content.text
        local serverText = typed(R.server)
        click(btn(R.back))
        run(1)
        game.titleOpen = false
        run(1)
        CONFIG.rememberServer("wss://myhost.example:38281")
        local saved = CONFIG.cfg.servers or ""
        CONFIG.cfg.server, CONFIG.cfg.slot = serverWas, slotWas
        expect(serverText == "wss://myhost.example" and goText == "Disconnect (connected as Other)",
               "the menu shows the scheme and knows the connection is that server: " .. tostring(serverText)
               .. " / " .. tostring(goText))
        expect(saved:find("myhost.example", 1, true) and not saved:find("wss", 1, true),
               "and the server is remembered by its host: " .. saved)
    end
    do   -- the Server box emptied: the last row says a server is missing, not "Connect to  as Other"
        for i = #menuChildren, 1, -1 do
            menuChildren[i] = nil
        end
        menuChildren[1], menuChildren[2] = gameButtonWrap, quitWrap
        gameButtonWrap.vis, quitWrap.vis = 0, 0
        game.titleOpen = true
        run(2)
        click(titleCanvasKids[#titleCanvasKids].child.children[4])
        run(2)
        typeInto(R.server, "")
        run(1)
        local goText = btn(R.go) and btn(R.go).Test_Content.text
        click(btn(R.back))
        run(1)
        game.titleOpen = false
        run(1)
        expect(goText == "Connect (type a server first)", "an empty Server box: " .. tostring(goText))
    end
    do   -- Esc while the text window asks for a field (the window layout): it is the window's, the menu stays open
        game.palEditOk, game.umgEditOk = false, false
        for i = #menuChildren, 1, -1 do
            menuChildren[i] = nil
        end
        menuChildren[1], menuChildren[2] = gameButtonWrap, quitWrap
        gameButtonWrap.vis, quitWrap.vis = 0, 0
        game.titleOpen = true
        run(2)
        click(titleCanvasKids[#titleCanvasKids].child.children[4])
        run(2)
        click(menuChildren[4].child)                         -- Port: the text window opens
        run(1)
        local escBind = keyBinds["key:ESCAPE"]
        if escBind then
            escBind()
        end
        tick()
        run(1)
        local stillOpen = gameButtonWrap.vis == 1
        okWith("40002")
        local back
        for _, box in ipairs(menuChildren) do
            local b = inner(box)
            if b and b.Test_Content and b.Test_Content.text == "Back" then
                back = b
            end
        end
        if back then
            click(back)
        end
        run(1)
        game.titleOpen = false
        run(1)
        game.palEditOk, game.umgEditOk = nil, nil
        expect(escBind and stillOpen and back and gameButtonWrap.vis == 0,
               "Esc while the text window is up leaves the Archipelago menu open (a click there does nothing either)")
    end
    do   -- the banner can't be placed on the canvas: it is taken off again and goes in the button list instead
        local realAdd = titleCanvas.AddChildToCanvas
        local onCanvas = nil
        function titleCanvas:AddChildToCanvas(w)
            local slot = realAdd(self, w)
            slot.SetAnchors = function() error("this slot takes no anchors") end
            w.RemoveFromParent = function(widget) widget.removed = true end
            onCanvas = w
            return slot
        end
        for i = #menuChildren, 1, -1 do
            menuChildren[i] = nil
        end
        menuChildren[1], menuChildren[2] = gameButtonWrap, quitWrap
        gameButtonWrap.vis, quitWrap.vis = 0, 0
        local placedAt = logMark()
        game.titleOpen = true
        run(2)
        titleCanvas.AddChildToCanvas = realAdd
        local inList = false
        for _, box in ipairs(menuChildren) do
            if box == onCanvas then
                inList = true
            end
        end
        game.titleOpen = false
        run(1)
        expect(onCanvas and onCanvas.removed and inList and not loggedSince(placedAt, "title banner error"),
               "a banner that can't be placed is taken off the canvas and put in the button list, not left there")
    end
end)
