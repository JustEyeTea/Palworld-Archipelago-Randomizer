-- Ctrl+F7 (test builds): saves the game's whole world map (T_WorldMap, 8192 px, drawn at 4096 px) as WorldMap.png in
-- the mod folder, to lay area borders over. The texture is drawn into a render target with a canvas, then exported.
-- Map calibration (DT_WorldMapUIData, MainMap): the image spans world X -1,099,400..349,400 and Y -724,400..724,400.
if not RegisterKeyBind or not Key or not ModifierKey then return function() end end

local function log(msg) print("[PalworldAP] [map] " .. msg .. "\n") end
local TEXTURE = "/Game/Pal/Texture/UI/Map/T_WorldMap.T_WorldMap"
local SIZE = 4096

local function describe(v)
    if type(v) == "table" then
        local parts = {}
        for k, x in pairs(v) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(x) end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end

local function export(dir)
    local ctx = FindFirstOf("PalPlayerController")
    if not ctx or not ctx:IsValid() then log("load a world first"); return end
    pcall(LoadAsset, (TEXTURE:gsub("%.[^.]+$", "")))
    local tex = StaticFindObject(TEXTURE)
    if not tex or not tex:IsValid() then log("map texture not found: " .. TEXTURE); return end
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local rt = krl:CreateRenderTarget2D(ctx, SIZE, SIZE, 2, { R = 0, G = 0, B = 0, A = 1 }, false)   -- RTF_RGBA8
    if not rt or not rt:IsValid() then log("could not create a render target"); return end
    log("render target ok")
    -- UE4SS hands out-parameters back either in the tables passed for them or as extra return values: try both.
    local canvasOut, sizeOut, contextOut = {}, {}, {}
    local r1, r2, r3 = krl:BeginDrawCanvasToRenderTarget(ctx, rt, canvasOut, sizeOut, contextOut)
    log("begin draw returned " .. describe(r1) .. " " .. describe(r2) .. " " .. describe(r3)
        .. "; tables " .. describe(canvasOut) .. " " .. describe(sizeOut) .. " " .. describe(contextOut))
    -- Seen in game: the canvas (and the size) come back in the first table, the draw context in the second.
    local canvas = nil
    for _, c in ipairs({ canvasOut.Canvas, r1 }) do
        if type(c) == "userdata" and select(2, pcall(function() return c:IsValid() end)) == true then canvas = c; break end
    end
    if not canvas then log("no canvas came back; this way of exporting does not work"); return end
    local ok, err = pcall(function()
        canvas:K2_DrawTexture(tex, { X = 0, Y = 0 }, { X = SIZE, Y = SIZE }, { X = 0, Y = 0 }, { X = 1, Y = 1 },
            { R = 1, G = 1, B = 1, A = 1 }, 0, 0, { X = 0.5, Y = 0.5 })
    end)
    log("draw: " .. (ok and "ok" or tostring(err)))
    local context = sizeOut.RenderTarget and sizeOut or contextOut
    ok, err = pcall(function() krl:EndDrawCanvasToRenderTarget(ctx, context) end)
    log("end draw: " .. (ok and "ok" or tostring(err)))
    ok, err = pcall(function() krl:ExportRenderTarget(ctx, rt, dir, "WorldMap.png") end)
    log("export to " .. dir .. "\\WorldMap.png: " .. (ok and "ok" or tostring(err)))
end

return function(dir)
    RegisterKeyBind(Key.F7, { ModifierKey.CONTROL }, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(export, dir)
            if not ok then log("error: " .. tostring(err)) end
        end)
    end)
    log("Ctrl+F7 saves the world map to " .. dir .. "\\WorldMap.png")
end
