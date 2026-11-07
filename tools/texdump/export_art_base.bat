@echo off
rem Exports the Palworld textures that Palworld Archipelago art is designed against (title screen, logo, menus,
rem map, wall pattern) as PNGs. Reads the game's own pak; changes nothing in the game folder.
rem Usage: export_art_base.bat ["path to Palworld\Pal\Content\Paks"]
setlocal
set "PAKS=C:\Program Files (x86)\Steam\steamapps\common\Palworld\Pal\Content\Paks"
if not "%~1"=="" set "PAKS=%~1"
set "OUT=%USERPROFILE%\Documents\Palworld Archipelago\art-base"
if not exist "%OUT%" mkdir "%OUT%"
cd /d "%~dp0"
texdump.exe "%PAKS%" "%~dp0Palworld-1.0.5.usmap" oo2core_9_win64.dll "%OUT%" ^
  Pal/Content/Pal/Texture/UI/Title/ ^
  Pal/Content/Pal/Texture/UI/Logo_Splash/ ^
  Pal/Content/Pal/Texture/UI/Main_Menu/ ^
  Pal/Content/Pal/Texture/UI/IngameMenu/ ^
  Pal/Content/Pal/Texture/UI/Common/ ^
  Pal/Content/Pal/Texture/UI/Map/ ^
  Pal/Content/Pal/Texture/UI/UnlockMapAreaMask/ ^
  Pal/Content/Pal/Effect/Textures/T_DungeonGate02 > "%OUT%\export-log.txt" 2>&1
type "%OUT%\export-log.txt" | findstr /b /c:"done:"
echo Log: %OUT%\export-log.txt
endlocal
