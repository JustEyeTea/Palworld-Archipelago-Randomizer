# texdump

Exports Palworld textures to PNG (CUE4Parse), for designing mod art against the game's own UI. Needs the client's
paks: the dedicated server's pak has texture headers but no pixel data. Never commit the exported PNGs or the usmap.

    dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true \
      -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -o out
    texdump <pakDir> <usmap> <oodle dll> <outDir> <package path or folder/>...

`export_art_base.bat` (next to texdump.exe and the usmap) exports the title screen, logo, menu, map and wall-pattern
textures into Documents\Palworld Archipelago\art-base.
