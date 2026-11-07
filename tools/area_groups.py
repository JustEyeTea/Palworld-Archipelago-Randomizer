"""Areas (one Area Pass each; the first is where a game starts) as groups of the game's own named map regions
(DT_WorldMapAreaData rows, placed in the world as BP_PalRegionTrigger volumes). Decided with JustEyeTee, 2 Nov 2026,
from a draft drawn over the game's world map. Caves, dungeons and towers inside a region belong to it and are not
listed; regions with no Pals (oil rigs, the King Whale islet) still place their land in an area.
"""
import os

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

# Every named surface region on its own: the area_size option's 'regions' (the user, 2026-11-05: a cramped start, more
# and smaller unlocks). Names are the game's English region names (DT_WorldMap_Common_Text; its 'Verdant Sream' spelt
# right). Two rows with no name of their own go with a neighbour: Boss_KingWhale (the King Whale islet, no Pals) with
# Crescent Moon Shore, Darkisland07 with Stone Pillar Cave. The start is the one region the first tower stands in.
REGIONS = {
    'Windswept Island': ['Grass_001'],
    'Sunlit Isle': ['SmallIsland01'],
    'Flying Fish Coast': ['Grass_6'],
    'Fortress Ruins': ['Grass_5'],
    'Autumn Rocks': ['Grass_4'],
    'Golden Hills': ['Grass_3'],
    'Bamboo Groves': ['Grass_002'],
    'Small Settlement': ['Grass_Village_001'],
    'Sea Breeze Archipelago': ['PvPIsland_001'],
    'Isle of Silence': ['PvPIsland_002'],
    'Isle of Murmurs': ['PvPIsland_003'],
    'Deep Bamboo Thicket': ['Grass_9'],
    'Marsh Island': ['PvPIsland_005'],
    'Eastern Wild Island': ['PvPIsland_004'],
    'Isle of Decayed Treasures': ['SmallIsland06'],
    'Scars of War': ['Grass_8'],
    'Rayne Syndicate Oil Rig': ['Oilrig_001'],
    'Crescent Moon Shore': ['Forest_001', 'Boss_KingWhale'],
    'Ancient Ritual Site': ['Forest_Ruin'],
    "Gobfin's Turf": ['Grass_7'],
    'Rayne Syndicate Test Drilling Rig': ['Oilrig_002'],
    'No. 1 Wildlife Sanctuary': ['Preserve_001'],
    'Foot of the Volcano': ['Volcano_2'],
    'Dry Sandy Beach': ['Volcano_4'],
    "Fisherman's Point": ['Volcano_Village_001'],
    'Isle of Eternal Summer': ['SmallIsland07'],
    'Frostbitten Isle': ['SmallIsland04'],
    'Mount Obsidian': ['Volcano_001'],
    'Ruined Fortress City': ['Volcano_3'],
    'No. 2 Wildlife Sanctuary': ['Preserve_002'],
    'Phantom Isle': ['SmallIsland05'],
    'Verdant Stream': ['Forest_002'],
    'Twilight Dunes': ['Desert_Small'],
    'Frostbound Mountains': ['Frost_Small'],
    'Desiccated Dunes': ['Desert_001'],
    'Duneshelter': ['Desert_Village_001'],
    'Scouring Islet': ['New_SmallIsland03'],
    'Flamepulse Islet': ['New_SmallIsland02'],
    'Oasis Isle': ['SmallIsland02'],
    'No. 3 Wildlife Sanctuary': ['Preserve_003'],
    'Islet of Circular Ruins': ['New_SmallIsland01'],
    'Astral Mountains': ['Frost_001'],
    'Foot of the Astral Mountains': ['Frost_2'],
    'Abandoned Ruins': ['Frost_3'],
    'Isle of the Glacial Core': ['SmallIsland03'],
    'Sakurajima - Southern Sandbar': ['Sakurajima_WhiteSand'],
    'Sakurajima - Northern Rock Field': ['Sakurajima_RockSand'],
    'Sakurajima - Mushroom Wetlands': ['Sakurajim_Mushroom'],
    'Dancing Sakura Shrine': ['Sakurajima_Sakura'],
    'Suncrest Islet': ['New_SmallIsland07'],
    'Scorched Ashland': ['Darkisland_FT01'],
    'Loess Plains': ['Darkisland_FT03'],
    'Hidden Passage to the Oculus Gate': ['Darkisland_FT04'],
    'The Oculus Gate, Tower in Sight': ['Darkisland_FT05'],
    'Scorched Hill': ['Darkisland_FT07'],
    'Deserted Ash Plateau': ['Darkisland_FT08'],
    'Withered Seaside': ['Darkisland_FT09'],
    'Frozen Coral Hill': ['Darkisland_FT10'],
    'Feybreak Shipwreck': ['Darkisland03'],
    'Crystalized Ancient Tree': ['Darkisland05'],
    'Stone Pillar Cave': ['Darkisland08', 'Darkisland07'],
    'Emberstone Plateau': ['Darkisland11'],
    'Feybreak Tower': ['Darkisland_Boss'],
    'Bicornis Islet': ['New_SmallIsland04'],
    'Glacial Memento Islet': ['New_SmallIsland05'],
    'Sandstone Gate Islet': ['New_SmallIsland06'],
    'Rayne Syndicate Platform Oil Rig': ['Oilrig_003'],
    'The Azure Tapestry': ['Skyisland01'],
    'Waterlily Gorge': ['Skyisland02'],
    'Dragonmark Peak': ['Skyisland03'],
    'Farcry Marsh': ['Skyisland04'],
    'Azure Woodland': ['Skyisland05'],
    'Crystalline Archipelago': ['Skyisland06'],
    'Enchanted Firmament': ['Skyisland07'],
    'Foot of the World Tree': ['FootOfWorldTree'],
}
REGIONS_START = 'Windswept Island'

# Which set the tools build (AREA_SIZE=regions in the environment for the per-region set; tools/build_areas.sh runs both).
if os.environ.get('AREA_SIZE', 'areas') == 'regions':
    GROUPS, START = REGIONS, REGIONS_START

# Regions that are part of another (caves, dungeons, towers, church ruins): their land goes with the region around them.
SUBREGION = r'FixedDungeon|UnderGroundCave|UndergroundCave|^Tower_|_Crunch|^Arena$'
