"""Areas (one Area Pass each; the first is where a game starts) as groups of the game's own named map regions
(DT_WorldMapAreaData rows, placed in the world as BP_PalRegionTrigger volumes). Decided with JustEyeTee, 2 Nov 2026,
from a draft drawn over the game's world map. Caves, dungeons and towers inside a region belong to it and are not
listed; regions with no Pals (oil rigs, the King Whale islet) still place their land in an area.
"""
START = 'Windswept Island'
GROUPS = {
    'Windswept Island': ['Grass_001', 'SmallIsland01', 'Grass_6'],
    'Bamboo Groves': ['Grass_5', 'Grass_4', 'Grass_3', 'Grass_002', 'Grass_Village_001'],
    'Sea Breeze Archipelago': ['PvPIsland_001'],
    'Isles of Silence': ['PvPIsland_002', 'PvPIsland_003', 'Grass_9'],
    'Marsh Island': ['PvPIsland_005', 'PvPIsland_004', 'SmallIsland06', 'Grass_8', 'Oilrig_001'],
    'Crescent Moon Shore': ['Forest_001', 'Forest_Ruin', 'Grass_7', 'Oilrig_002', 'Preserve_001', 'Boss_KingWhale'],
    'Volcano Foothills': ['Volcano_2', 'Volcano_4', 'Volcano_Village_001', 'SmallIsland07', 'SmallIsland04'],
    'Mount Obsidian': ['Volcano_001', 'Volcano_3', 'Preserve_002', 'SmallIsland05'],
    'Verdant Stream': ['Forest_002', 'Desert_Small', 'Frost_Small'],
    'Desiccated Dunes': ['Desert_001', 'Desert_Village_001', 'New_SmallIsland03', 'New_SmallIsland02', 'SmallIsland02',
                         'Preserve_003', 'New_SmallIsland01'],
    'Astral Mountains': ['Frost_001', 'Frost_2', 'Frost_3', 'SmallIsland03'],
    'Sakurajima': ['Sakurajima_WhiteSand', 'Sakurajima_RockSand', 'Sakurajim_Mushroom', 'Sakurajima_Sakura',
                   'New_SmallIsland07'],
    'Feybreak': ['Darkisland_FT01', 'Darkisland_FT03', 'Darkisland_FT04', 'Darkisland_FT05', 'Darkisland_FT07',
                 'Darkisland_FT08', 'Darkisland_FT09', 'Darkisland_FT10', 'Darkisland03', 'Darkisland05', 'Darkisland07',
                 'Darkisland08', 'Darkisland11', 'Darkisland_Boss', 'New_SmallIsland04', 'New_SmallIsland05',
                 'New_SmallIsland06', 'Oilrig_003'],
    'Sky Islands': ['Skyisland01', 'Skyisland02', 'Skyisland03', 'Skyisland04', 'Skyisland05', 'Skyisland06',
                    'Skyisland07'],
    'World Tree': ['FootOfWorldTree'],
}
# Regions that are part of another (caves, dungeons, towers, church ruins): their land goes with the region around them.
SUBREGION = r'FixedDungeon|UnderGroundCave|UndergroundCave|^Tower_|_Crunch|^Arena$'
