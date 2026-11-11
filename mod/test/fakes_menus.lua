-- The stand-ins for the game's widgets, menus and HUD, and the hidden chest the mailbox uses: what menu.lua, the
-- mailbox and the HUD pieces build on. Loaded after fakes.lua, whose lookups (FindAllOf, StaticFindObject) return
-- these objects; switches in game (escOpen, mainMenuOpen, titleOpen) say which are up.
-- A builder (Panel, MainMenu, inventoryPage, fakeHud ...) makes a fresh object for a test that needs its own.

-- Widgets ---------------------------------------------------------------------------------------------------------

-- Any UMG widget: valid until a test marks it gone, with an address of its own, and the fields given.
function Widget(extra)
    local w = { IsValid = function(self) return not self.gone end, addr = math.random(1, 1e9) }
    function w:GetAddress() return self.addr end
    for k, v in pairs(extra or {}) do
        w[k] = v
    end
    return w
end
-- A widget's class, as GetClass returns it: an object with the class's name.
function classed(name)
    return { GetFName = function() return FNameOf(name) end }
end
-- Makes a widget's visibility readable (0, Visible, until set).
function visible(w)
    w.GetVisibility = function(self) return self.vis or 0 end
    w.SetVisibility = function(self, v) self.vis = v end
    return w
end
-- A widget that can take focus (UWidget:HasAnyUserFocus and HasFocusedDescendants, both in LuaTypes).
function Focusable()
    return Widget({ HasAnyUserFocus = function(self) return self.focused == true end,
                    HasFocusedDescendants = function() return false end })
end
-- A panel of the class given, holding the widgets in `kids` (read as a widget tree's children).
function Panel(class, kids)
    return Widget({ GetClass = function() return classed(class) end,
                    GetChildrenCount = function() return #kids end,
                    GetChildAt = function(_, i) return kids[i + 1] end })
end
-- A widget with a name (GetFName) and a class, and the fields given.
function NamedWidget(name, class, extra)
    local w = Widget(extra)
    w.GetClass = function() return classed(class) end
    w.GetFName = function() return FNameOf(name) end
    return w
end

-- The title menu ----------------------------------------------------------------------------------------------------

-- Its buttons sit in a vertical box (the title menu has no VerticalBox_0, as on the client).
menuChildren = {}                                            -- the box's children, in order
buttonBox = Widget({ GetClass = function() return classed("VerticalBox") end,
                     GetFName = function() return FNameOf("VerticalBox_Menu") end })
function buttonBox:AddChild(box)
    menuChildren[#menuChildren + 1] = box
    return { SetPadding = function(_, p) box.padding = p end, SetHorizontalAlignment = function() end }
end
function buttonBox:RemoveChild(box)
    for i, c in ipairs(menuChildren) do
        if c == box then
            table.remove(menuChildren, i)
            return true
        end
    end
    return false
end
function buttonBox:GetChildrenCount() return #menuChildren end
function buttonBox:GetChildAt(i) return menuChildren[i + 1] end
-- The list sits on a canvas, CanvasPanelMenu (as on the client): anchored bottom-centre, its bottom 80 above the
-- anchor, 600x500 with our buttons in it.
titleCanvasKids = {}                                         -- what the mod puts on that canvas
titleCanvas = Widget({ GetClass = function() return classed("CanvasPanel") end,
                       GetFName = function() return FNameOf("CanvasPanelMenu") end })
function titleCanvas:AddChildToCanvas(w)
    local slot = { SetAnchors = function(s, a) s.anchors = a end, SetAlignment = function(s, a) s.alignment = a end,
                   SetAutoSize = function(s, v) s.auto = v end, SetSize = function(s, v) s.size = v end,
                   SetZOrder = function(s, z) s.zorder = z end }
    function slot:SetPosition(p)
        self.position = p
        self.moves = (self.moves or 0) + 1
    end
    w.canvasSlot = slot
    titleCanvasKids[#titleCanvasKids + 1] = w
    return slot
end
buttonBox.GetParent = function() return titleCanvas end
buttonBox.desired = { X = 600, Y = 500 }
buttonBox.GetDesiredSize = function(self) return self.desired end
buttonBox.ForceLayoutPrepass = function(self) self.prepassed = true end
buttonBox.Slot = { GetAnchors = function() return { Minimum = { X = 0.5, Y = 1 }, Maximum = { X = 0.5, Y = 1 } } end,
                   GetAlignment = function() return { X = 0.5, Y = 1 } end,
                   GetPosition = function() return { X = 0, Y = -80 } end }
-- Start Game (and the rest of the game's buttons), then Quit Game, last until our buttons go in.
gameButtonWrap = visible(Widget({ GetClass = function() return classed("SizeBox") end,
                                  GetParent = function() return buttonBox end }))
gameTitleButton = Widget({ GetParent = function() return gameButtonWrap end })
quitWrap = visible(Widget({ GetClass = function() return classed("SizeBox") end,
                            GetParent = function() return buttonBox end,
                            Slot = { Padding = { Left = 0, Top = 0, Right = 0, Bottom = 7 },
                                     HorizontalAlignment = 2 } }))
menuChildren[1], menuChildren[2] = gameButtonWrap, quitWrap
titleMenu = Widget({ WBP_Title_MenuButton_StartLocalGame = gameTitleButton,
                     WBP_Title_MenuButton_ExitGame = Widget({ GetParent = function() return quitWrap end }),
                     VerticalBox_0 = Widget({ AddChild = function() error("buttons belong with the game's") end }) })
-- The title screen asset's own WBP_TitleMenu (a template): not live, never to be touched.
titleTemplate = Widget({ WBP_Title_MenuButton_StartLocalGame = gameTitleButton })
function titleTemplate:GetFullName()
    return "WBP_TitleMenu_C /Game/Pal/Blueprint/UI/UserInterface/Title/WBP_Title.WBP_Title_C:WidgetTree.WBP_TitleMenu"
end

-- The widget factory (WidgetBlueprintLibrary:Create) -----------------------------------------------------------------

-- The game's small labelled button (WBP_CommonButton, kdump): label Text_Main, focus on its inner
-- WBP_PalInvisibleButton (GetFocusTarget).
local function CommonButton()
    return Widget({ GetClass = function() return classed("WBP_CommonButton_C") end,
                    Text_Main = { IsValid = function() return true end, BindTextDatatableHandle = {},
                                  SetText = function(self, t) self.text = t.text end },
                    WBP_PalInvisibleButton = Focusable() })
end
-- The map's plain icon (WBP_WorldMap_IconBase_OnlyIcon).
local function MapIcon()
    local icon = Widget({ ChangeTexture = function(self, tex) self.tex = tex end,
                          SetVisibility = function(self, v) self.visibility = v end })
    function icon:GetParent() return self.parent end
    function icon:RemoveFromParent()
        self.parent = nil
        self.removed = true
    end
    return icon
end
-- The Esc menu's small button (WBP_MenuESC_Button_S).
local function EscButton()
    return Widget({ GetClass = function() return classed("WBP_MenuESC_Button_S_C") end,
                    Text_Main = { IsValid = function() return true end, BindTextDatatableHandle = {},
                                  SetText = function(self, t) self.text = t.text end } })
end
-- The title menu's button (WBP_Title_MenuButton), the class the mod asks for when it is none of the above.
local function TitleButton()
    return Widget({ Test_Content = { SetText = function(self, t) self.text = t.text end },
                    SetVisibility = function(self, v) self.visibility = v end,
                    SetRenderOpacity = function(self, o) self.opacity = o end,
                    IsHovered = function(self) return self.hovered == true end,
                    HasAnyUserFocus = function() return false end,
                    HasFocusedDescendants = function(self) return self.focused == true end })
end
wbl = { IsValid = function() return true end }
function wbl.Create(_, _, cls)
    local path = cls and tostring(cls.path) or ""
    if path:find("/Common/WBP_CommonButton.", 1, true) then return CommonButton() end
    if path:find("WBP_WorldMap_IconBase_OnlyIcon", 1, true) then return MapIcon() end
    if path:find("WBP_MenuESC_Button_S", 1, true) then return EscButton() end
    return TitleButton()
end

-- UMG widgets the mod makes (StaticConstructObject) ----------------------------------------------------------------

bannerTexts = {}                                             -- every text a made TextBlock was given, in order
styleAssigned = false                                        -- whether the mod assigned a text box's WidgetStyle
-- A text box: what is in it reads back from its Text (a test types by setting Text); focus is the test's to set.
-- Assigning its WidgetStyle from another box crashed the game: here that is an error, as strict.
function EditBox(kind)
    local e = Widget({ GetClass = function() return classed(kind) end, kind = kind, Text = TextOf(""),
                       SetText = function(self, t) self.Text = TextOf(t.text) end,
                       SetIsPassword = function(self, on) self.password = on end,
                       SetForegroundColor = function(self, c) self.colour = c end,
                       HasKeyboardFocus = function(self) return self.focus == true end,
                       SetVisibility = function(self, v) self.vis = v end,
                       GetVisibility = function(self) return self.vis or 0 end })
    -- its own style, whose colours the mod writes field by field (FSlateColor: SpecifiedColor and ColorUseRule)
    local function slate() return { SpecifiedColor = { R = 1, G = 1, B = 1, A = 1 }, ColorUseRule = 1 } end
    rawset(e, "WidgetStyle", { BackgroundColor = slate(), ForegroundColor = slate(), FocusedForegroundColor = slate() })
    return setmetatable(e, { __newindex = function(self, k, v)
        if k == "WidgetStyle" then
            styleAssigned = true
            error("WidgetStyle assigned from Lua: this crashed the game (dev.21)")
        end
        rawset(self, k, v)
    end })
end
-- Gives a made widget children: AddChild (a child gets its slot in .slot) and RemoveChild.
local function holdsChildren(box)
    function box:AddChild(c)
        self.child = c
        self.children[#self.children + 1] = c
        c.GetParent = function() return self end
        local slot = { SetPadding = function(s, pad) s.padding = pad end,
                       SetHorizontalAlignment = function(s, a) s.h = a end,
                       SetVerticalAlignment = function(s, a) s.v = a end }
        c.slot = slot
        return slot
    end
    function box:RemoveChild(c)
        for i, x in ipairs(self.children) do
            if x == c then
                table.remove(self.children, i)
            end
        end
        if self.child == c then
            self.child = nil
        end
        return true
    end
end
-- One stand-in for every other widget the mod makes (SizeBox, Overlay, Image, TextBlock, Border): it records what is
-- done to it.
local function MadeWidget(kind)
    local box = Widget({ GetClass = function() return classed(kind) end, kind = kind, children = {},
                         Font = { Size = 24 },
                         Background = { Margin = {}, ImageSize = {} },   -- (a Border's brush, written field by field)
                         SetWidthOverride = function(self, w) self.width = w end,
                         SetHeightOverride = function(self, h) self.height = h end,
                         SetBrushFromTexture = function(self, t) self.texture = t end,
                         SetFont = function(self, f) self.fontSize = f.Size end,
                         SetColorAndOpacity = function(self, c) self.colour = c end,
                         SetRenderOpacity = function(self, o) self.opacity = o end,
                         SetVisibility = function(self, v) self.vis = v end,
                         GetVisibility = function(self) return self.vis or 0 end,
                         SetRenderTransformPivot = function(self, v) self.pivot = v end,
                         SetRenderScale = function(self, v) self.scale = v end,
                         SetBrushColor = function(self, c) self.brush = c end,
                         SetPadding = function(self, p) self.pad = p end,
                         RemoveFromParent = function(self) self.removedFromParent = true end })
    function box:SetText(t)
        self.text = t.text
        bannerTexts[#bannerTexts + 1] = t.text
    end
    holdsChildren(box)
    return box
end
StaticConstructObject = function(cls)
    local kind = type(cls) == "table" and cls.umg or "SizeBox"
    if kind == "PalEditableTextBox" or kind == "EditableTextBox" then return EditBox(kind) end
    return MadeWidget(kind)
end

-- The HUD service: the text window, and the chest window the mailbox opens ------------------------------------------

hudWindows = {}                                              -- the HUD's windows by id
pushed = {}                                                  -- the parameters of every text window pushed
chestWindowsShown = {}                                       -- every chest window shown: { kind =, param = }
chestRow = nil                                               -- the last chest window's heading row
hud = {}
-- The text window. Its Text_Head as the game's: its Text field reads back as a value with no ToString; GetText()
-- gives the FText.
function hud.Push(_, cls, param)
    local id = "w" .. (#pushed + 1)
    pushed[#pushed + 1] = param
    local head = { SetText = function(self, t) self.text = t.text end, Text = 0,
                   BindTextDatatableHandle = { RowName = FName("WorldName") } }
    function head:GetText()
        local s = self.text or ""
        return { ToString = function() return s end }
    end
    hudWindows[id] = Widget({ Text_Head = head,
                              PalEditableTextBox_0 = { SetIsPassword = function(self, on) self.password = on end } })
    return id
end
function hud.GetWidget(_, id) return hudWindows[id] end
function hud.CreateDispatchParameterForK2Node() return {} end
-- The chest window (kind 7), headed "Advanced Chest"; its heading sits in a SizeBox in a row.
function hud.ShowCommonUI(_, kind, param)
    local id = "chest" .. (#chestWindowsShown + 1)
    chestWindowsShown[#chestWindowsShown + 1] = { kind = kind, param = param }
    local row = Widget({ GetClass = function() return classed("HorizontalBox") end,
                         GetFName = function() return FNameOf("HorizontalBox_Title") end, children = {} })
    local headBox = Widget({ GetClass = function() return classed("SizeBox") end,
                             GetFName = function() return FNameOf("SizeBox_Title") end,
                             GetParent = function() return row end })
    function row:AddChild(c)
        self.children[#self.children + 1] = c
        return { SetVerticalAlignment = function() end, SetPadding = function() end }
    end
    chestRow = row
    local head = { IsValid = function() return true end, text = "Advanced Chest", BindTextDatatableHandle = {},
                   GetParent = function() return headBox end }
    function head:SetText(t) self.text = t.text end
    function head:GetText()
        local t = self.text
        return { ToString = function() return t end }
    end
    hudWindows[id] = Widget({ WBP_IngameMenu_Chest = { Text_TargetContainerName = head } })
    return id
end
function hud.Close(_, id)
    if hudWindows[id] then
        hudWindows[id].gone = true
    end
end
util.GetHUDService = function() return hud end

-- The Esc menu, and the HUD's mission list beside it ---------------------------------------------------------------

-- The Esc menu (WBP_MenuESC_C, from kdump): Canvas_Buttons holds vertical boxes of WBP_MenuESC_Button_C. Its
-- WidgetTree has RootWidget but no GetAllWidgets (C++ only in the game; calling it errors).
escChildren = {}                                             -- the button box's children: the game's three, then ours
local function escMenuButton()
    local b = Widget({ GetClass = function() return classed("WBP_MenuESC_Button_C") end })
    return Widget({ GetClass = function() return classed("SizeBox") end, GetChildAt = function() return b end })
end
for i = 1, 3 do
    escChildren[i] = escMenuButton()
end
local escBox = Widget({ GetClass = function() return classed("VerticalBox") end,
                        GetFName = function() return FNameOf("VerticalBox_Esc") end,
                        GetChildrenCount = function() return #escChildren end,
                        GetChildAt = function(_, i) return escChildren[i + 1] end })
function escBox:AddChild(box)
    escChildren[#escChildren + 1] = box
    return { SetPadding = function(_, p) box.padding = p end, SetHorizontalAlignment = function() end }
end
-- Its Close shuts only its tab of the main menu; CloseAction closes the main menu.
escMenu = Widget({ GetClass = function() return classed("WBP_MenuESC_C") end,
                   WidgetTree = { RootWidget = Panel("CanvasPanel", { Panel("CanvasPanel", {}),
                                                                      Panel("CanvasPanel", { escBox }) }) },
                   Close = function(self) self.tabOnly = true end,
                   CloseAction = function(self) self.closed = true end })
-- The HUD's mission list (its name holds "gamemenu") has a box of buttons too; the mod must leave it alone.
taskChildren = {}
for i = 1, 3 do
    taskChildren[i] = Widget({ GetClass = function() return classed("WBP_IngameMenu_Task_Simple_Button_C") end })
end
local taskBox = Widget({ GetClass = function() return classed("HorizontalBox") end,
                         GetChildrenCount = function() return #taskChildren end,
                         GetChildAt = function(_, i) return taskChildren[i + 1] end })
function taskBox:AddChild(box)
    taskChildren[#taskChildren + 1] = box
    return { SetPadding = function() end, SetHorizontalAlignment = function() end }
end
taskList = Widget({ GetClass = function() return classed("WBP_IngameMenu_Task_SimpleList_C") end,
                    WidgetTree = { RootWidget = Panel("CanvasPanel", { taskBox }) } })

-- The in-game main menu ---------------------------------------------------------------------------------------------

-- The main menu (WBP_InGameMainMenu_C): the Esc menu is its Options tab, its CurrentContentWidget. Its class default
-- object is found too.
defaultMainMenu = Widget({ GetClass = function() return classed("WBP_InGameMainMenu_C") end })
function defaultMainMenu:GetFullName()
    return "WBP_InGameMainMenu_C /Game/Pal/Blueprint/UI/InGameMainMenu/WBP_InGameMainMenu.Default__WBP_InGameMainMenu_C"
end
escMain = Widget({ GetClass = function() return classed("WBP_InGameMainMenu_C") end, CurrentTabType = 7,
                   IsVisible = function() return not escMenu.closed end,
                   IsInViewport = function() return not escMenu.closed end })
function escMain:GetFullName()
    return "WBP_InGameMainMenu_C /Engine/Transient.GameEngine_0:PalGameInstance_0.WBP_InGameMainMenu_C_0"
end
setmetatable(escMain, { __index = function(_, k) if k == "CurrentContentWidget" then return escMenu end end })
mainMenu = nil                                               -- the main menu a test shows (game.mainMenuOpen)
-- A main menu showing `tab` (its CurrentContentWidget) on the tab numbered `tabType`. Its Close is what its X button
-- does; its Destruct then lets go of the tab (kdump: CurrentContentWidget = None).
function MainMenu(tab, tabType)
    local menu = NamedWidget("WBP_InGameMainMenu_C_1", "WBP_InGameMainMenu_C",
                             { CurrentContentWidget = tab, CurrentTabType = tabType })
    function menu:GetFullName()
        return "WBP_InGameMainMenu_C /Engine/Transient.GameEngine_0:PalGameInstance_0.WBP_InGameMainMenu_C_1"
    end
    function menu:Close()
        self.closed = true
        self.CurrentContentWidget = nil
    end
    function menu:IsVisible() return not self.closed end
    function menu:IsInViewport() return not self.closed end
    return menu
end
-- The Inventory tab's page (WBP_InventoryEquipment, kdump). Its name bar is CanvasPanelChara > Overlay_0 >
-- HorizontalBox_0 > [SizeBox_NameEdit > WBP_CommonButton_NameEdit (Edit Name, a WBP_CommonButton_C) |
-- Text_CharacterName]. The bar is no variable of the page: only GetParent reaches it.
-- Returns the page, the list the bar's added children go in, and the Edit Name button.
function inventoryPage()
    local kids = {}
    local root = NamedWidget("CanvasPanel_0", "CanvasPanel")
    local chara = NamedWidget("CanvasPanelChara", "CanvasPanel", { GetParent = function() return root end })
    local bar = NamedWidget("Overlay_0", "Overlay", { GetParent = function() return chara end })
    function bar:GetChildrenCount() return #kids end
    function bar:GetChildAt(i) return kids[i + 1] end
    function bar:AddChild(w)
        kids[#kids + 1] = w
        w.GetParent = function() return bar end
        return { SetHorizontalAlignment = function(_, a) w.halign = a end,
                 SetVerticalAlignment = function(_, a) w.valign = a end,
                 SetPadding = function(_, p) w.padding = p end }
    end
    function chara:GetChildrenCount() return 1 end
    function chara:GetChildAt() return bar end
    function root:GetChildrenCount() return 1 end
    function root:GetChildAt() return chara end
    local row = NamedWidget("HorizontalBox_0", "HorizontalBox", { GetParent = function() return bar end })
    local editBox = NamedWidget("SizeBox_NameEdit", "SizeBox", { GetParent = function() return row end })
    local edit = NamedWidget("WBP_CommonButton_NameEdit", "WBP_CommonButton_C",
                             { GetParent = function() return editBox end, WBP_PalInvisibleButton = Focusable() })
    local name = NamedWidget("Text_CharacterName", "BP_PalTextBlock_C", { GetParent = function() return row end })
    local page = NamedWidget("WBP_InventoryEquipment", "WBP_InventoryEquipment_C",
                             { SizeBox_NameEdit = editBox, WBP_CommonButton_NameEdit = edit, Text_CharacterName = name,
                               WidgetTree = { RootWidget = root } })
    return page, kids, edit
end
-- The Inventory tab's widget: a new WBP_InventoryEquipment_ForDisplay_C per visit, holding the page.
function inventoryTab(page, extra)
    local w = NamedWidget("WBP_InventoryEquipment_ForDisplay_C_1", "WBP_InventoryEquipment_ForDisplay_C", extra)
    w.WBP_InventoryEquipment = page
    return w
end

-- The HUD layout (WBP_PalHUDLayout_C), and canvases ----------------------------------------------------------------

-- A canvas panel: what the mod adds to it is listed in `kids`, in order; each added widget gets its slot in
-- canvasSlot and is marked removed when taken off.
function fakeCanvas(name)
    local kids = {}
    local canvas = Widget({ GetClass = function() return classed("CanvasPanel") end,
                            GetFName = function() return FNameOf(name) end,
                            GetChildrenCount = function() return #kids end,
                            GetChildAt = function(_, i) return kids[i + 1] end })
    function canvas:AddChildToCanvas(w)
        kids[#kids + 1] = w
        w.RemoveFromParent = function(self) self.removed = true end
        local slot = { SetAnchors = function(sl, v) sl.anchors = v end,
                       SetAlignment = function(sl, v) sl.alignment = v end,
                       SetPosition = function(sl, v) sl.position = v end, SetAutoSize = function() end,
                       SetZOrder = function(sl, z) sl.z = z end }
        w.canvasSlot = slot
        return slot
    end
    return canvas, kids
end
-- A HUD layout as on the client: SafeZone_0 holding a canvas named `canvasName`. Returns the layout, the canvas and
-- the list of what the mod puts on the canvas. A test lists the layout by wrapping FindAllOf for WBP_PalHUDLayout_C.
function fakeHud(canvasName)
    local canvas, kids = fakeCanvas(canvasName)
    local safe = Widget({ GetClass = function() return classed("SafeZone") end,
                          GetFName = function() return FNameOf("SafeZone_0") end,
                          GetChildrenCount = function() return 1 end, GetChildAt = function() return canvas end })
    local layout = Widget({ IsVisible = function() return true end, WidgetTree = { RootWidget = safe } })
    return layout, canvas, kids
end

-- The hidden chest (the mailbox without its LogicMod) -----------------------------------------------------------------

-- Chests are made on first use, 300 slots, with the chest template put back after; the players' chests keep 54.
chests = nil                                                 -- the chest map objects made, once the mailbox makes one
chestTemplates = nil                                         -- the chest Blueprint's parameter component(s)
chestSpawnAsked = nil                                        -- the map object id the last spawn asked for
uiUtil = nil                                                 -- PalUIUtility (item names), once installChest
moves = {}                                                   -- every move from the chest to the bag: { to, index, n }
-- An item id that names no item (a slot's own: a test writes into it).
local function noItem() return { A = 0, B = 0, C = 0, D = 0 } end
-- A slot's or a container's permission: what may be put in it.
local function Permission()
    return { PermissionTypeA = TArray({}), PermissionTypeB = TArray({}), PermissionItemStaticIds = TArray({}) }
end
-- One slot of the chest, empty.
local function Slot(index)
    local slot = { ItemId = { StaticId = FNameOf("None"), DynamicId = { LocalIdInCreatedWorld = noItem() } },
                   StackCount = 0, Permission = Permission() }
    function slot:GetSlotId() return { ContainerId = { ID = { A = 9, B = 9, C = 9, D = 9 } }, SlotIndex = index } end
    function slot:OnRep_Permission() end
    function slot:IsValid() return true end
    function slot:IsEmpty() return self.StackCount == 0 or self.ItemId.StaticId:ToString() == "None" end
    function slot:GetItemId() return self.ItemId end
    function slot:GetStackCount() return self.StackCount end
    function slot:OnRep_ItemId() end
    function slot:OnRep_StackCount() end
    return slot
end
-- The chest's container: its slots, as many as the template says.
local function Container()
    local slots = {}
    for i = 1, chestTemplates[1].SlotNum do
        slots[i] = Slot(i - 1)
    end
    local c = { Num = function() return #slots end, Get = function(_, i) return slots[i + 1] end, slots = slots,
                Permission = Permission(), OnRep_Permission = function() end }
    function c.GetLastNotEmptyIndex()
        for i = #slots, 1, -1 do
            if not slots[i]:IsEmpty() then return i - 1 end
        end
        return -1
    end
    return c
end
-- The map object manager: a spawn makes the chest at once.
mapObjects = {}
function mapObjects.RequestSpawnMapObjectByPlayer_Server(_, id, at)
    chestSpawnAsked = id:ToString()
    local model = { DeteriorationDamage = 0.15, DamagableType = 0 }
    chests[#chests + 1] = { IsValid = function() return true end, at = at, c = Container(), model = model,
                            GetTransform = function(self) return { Translation = self.at } end,
                            GetItemContainerModule = function(self)
                                return { GetContainer = function() return self.c end }
                            end,
                            GetModelInstanceId = function() return "m" end, GetActor = function() return nil end,
                            RequestLockPrivate_ServerInternal = function(self) self.locked = true end }
    return true
end
function mapObjects.FindModel() return chests[1].model end
-- The game's move from a chest slot to the bag (the Item part of the player's network transmitter).
local function moveToBag(_, _, to, froms)
    for _, f in ipairs(froms) do
        moves[#moves + 1] = { to = to.ID.A, index = f.SlotId.SlotIndex, n = f.Num }
        if game.movesWork then
            local slot = chests[1].c.slots[f.SlotId.SlotIndex + 1]
            local id = slot.ItemId.StaticId:ToString()
            bagHas[id] = (bagHas[id] or 0) + f.Num
            slot.StackCount = slot.StackCount - f.Num
            if slot.StackCount <= 0 then                -- an emptied slot holds no item at all
                slot.ItemId = { StaticId = FNameOf("None"), DynamicId = { LocalIdInCreatedWorld = noItem() } }
                slot.StackCount = 0
            end
        end
    end
end
-- Puts the chest's stand-ins in place: the mailbox group does this where the game first needs them, as the tests
-- before it ran without them.
function installChest()
    chests = {}
    chestTemplates = { { SlotNum = 54 } }
    chestTemplates[1].GetFullName = function()
        return "PalMapObjectItemChestParameterComponent /Game/Pal/Blueprint/MapObject/BuildObject/"
            .. "BP_BuildObject_ItemChest_04.BP_BuildObject_ItemChest_04_C:ItemChestParameter_GEN_VARIABLE"
    end
    util.GetMapObjectManager = function() return mapObjects end
    util.GetLocalPlayerID = function() return 1 end
    util.GetItemIDManager = function()
        return { GetStaticItemData = function() return { GetMaxStackCount = function() return 9999 end } end }
    end
    util.GetNetworkTransmitter = function()
        return { Item = { IsValid = function() return true end, RequestMoveToContainer_ToServer = moveToBag } }
    end
    uiUtil = {}
    function uiUtil.GetItemName(_, _, id, out)
        local names = { Wood = "Wood", Stone = "Stone" }
        out.outName = { ToString = function() return names[id:ToString()] end }
    end
    ps.PlayerUId = { A = 1, B = 2, C = 3, D = 4 }
end

-- The game's functions a test calls as the game would, through the hook the mod registered on each ------------------

GAME_PATH = {}
GAME_PATH.title = "/Game/Pal/Blueprint/UI/UserInterface/Title/"
GAME_PATH.titleClick = GAME_PATH.title .. "WBP_Title_MenuButton.WBP_Title_MenuButton_C:BndEvt__WBP_Title_MenuButton_"
    .. "WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_0_CommonButtonBaseClicked__DelegateSignature"
GAME_PATH.escClick = "/Game/Pal/Blueprint/UI/UserInterface/ESCMenu/WBP_MenuESC_Button_S.WBP_MenuESC_Button_S_C:"
    .. "BndEvt__WBP_MenuESC_Button_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_0_CommonButtonBaseClicked__"
    .. "DelegateSignature"
GAME_PATH.windowOk = GAME_PATH.title .. "WBP_Title_WorldSettings_NameWindow.WBP_Title_WorldSettings_NameWindow_C:"
    .. "BndEvt__WBP_Title_WorldSettings_NameWindow_WBP_CommonButton_K2Node_ComponentBoundEvent_5_OnClicked__"
    .. "DelegateSignature"
GAME_PATH.commonClick = "/Game/Pal/Blueprint/UI/UserInterface/Common/WBP_CommonButton.WBP_CommonButton_C:BndEvt__"
    .. "WBP_CommonButton_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_3_CommonButtonBaseClicked__DelegateSignature"
