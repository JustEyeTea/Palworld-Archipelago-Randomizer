"""Draws the Palworld world from the game tables (the dumps from the server probe's dumptable/dumpactors commands):
field spawners coloured by Pal level, fast-travel points, towers, alpha bosses and effigies, with a 100 km grid, to
choose area boundaries. It also holds the frame lock_model.py draws its piece map in.
    <AP venv python> tools/plot_world.py <tables dir> <out.png>
Tests: none; the picture is private and checked by eye.
"""
import sys

from PIL import Image, ImageDraw, ImageFont

from table_dumps import read_table, spawner_levels, wild_spawner_pals, world_xyz

# The part of the world drawn, in world cm (X runs up the picture, south to north; Y to the right, west to east): the
# main map and the World Tree's island beside it, with a margin.
PLOT_X_MIN, PLOT_X_MAX = -1100e3, 700e3
PLOT_Y_MIN, PLOT_Y_MAX = -800e3, 650e3
PLOT_SCALE = 0.0011                          # picture pixels per world cm: about 1600 x 2000 px
BACKGROUND = (18, 22, 30)                    # a dark blue-grey
GRID_STEP_KM = 100                           # one grid line every 100 km
GRID_COLOUR, GRID_TEXT = (45, 50, 60), (110, 110, 120)
LOWEST_LEVEL, HIGHEST_LEVEL = 1, 80          # the colour scale's ends: blue at 1, green at 40, red at 80
SPAWNER_PLACEMENTS = ("Field", "FieldBoss")  # DT_PalSpawnerPlacement rows drawn: the open world's spawners
FAST_TRAVEL_COLOUR, FAST_TRAVEL_TEXT = (255, 255, 0), (220, 220, 120)
TOWER_COLOUR, TOWER_TEXT = (255, 0, 255), (255, 120, 255)
EFFIGY_COLOUR = (255, 255, 255)


def picture_size():
    """The plot's (width, height) in pixels."""
    return int((PLOT_Y_MAX - PLOT_Y_MIN) * PLOT_SCALE) + 1, int((PLOT_X_MAX - PLOT_X_MIN) * PLOT_SCALE) + 1


def to_picture(x, y):
    """A world spot's pixel in the plot: world X up the picture, world Y to the right."""
    return (y - PLOT_Y_MIN) * PLOT_SCALE, (PLOT_X_MAX - x) * PLOT_SCALE


def level_colour(level):
    """The colour of a Pal level: blue at LOWEST_LEVEL, green halfway, red at HIGHEST_LEVEL."""
    t = max(0, min(1, (level - LOWEST_LEVEL) / (HIGHEST_LEVEL - LOWEST_LEVEL)))
    return int(255 * t), int(255 * (1 - abs(t - 0.5) * 2)), int(255 * (1 - t))


def draw_grid(drawing, font):
    """Grid lines every GRID_STEP_KM, each labelled with its world X or Y in km."""
    for km in range(int(PLOT_X_MIN / 1e3), int(PLOT_X_MAX / 1e3) + 1, GRID_STEP_KM):
        drawing.line([to_picture(km * 1e3, PLOT_Y_MIN), to_picture(km * 1e3, PLOT_Y_MAX)], fill=GRID_COLOUR)
        drawing.text(to_picture(km * 1e3, PLOT_Y_MIN), f"x{km}k", fill=GRID_TEXT, font=font)
    for km in range(int(PLOT_Y_MIN / 1e3), int(PLOT_Y_MAX / 1e3) + 1, GRID_STEP_KM):
        drawing.line([to_picture(PLOT_X_MIN, km * 1e3), to_picture(PLOT_X_MAX, km * 1e3)], fill=GRID_COLOUR)
        drawing.text(to_picture(PLOT_X_MAX, km * 1e3), f"y{km}k", fill=GRID_TEXT, font=font)


def draw_spawners(drawing, tables):
    """Each open-world spawner as a dot in the colour of its Pals' typical level."""
    pals = wild_spawner_pals(read_table(tables, "DT_PalWildSpawner.tsv"))
    for row in read_table(tables, "DT_PalSpawnerPlacement.tsv"):
        if row["PlacementType"] not in SPAWNER_PLACEMENTS or row["SpawnerName"] not in pals:
            continue
        levels = spawner_levels(pals[row["SpawnerName"]])
        x, y, _ = world_xyz(row["Location"])
        px, py = to_picture(x, y)
        drawing.ellipse([px - 2, py - 2, px + 2, py + 2], fill=level_colour(sum(levels) / len(levels)))


def draw_landmarks(drawing, tables, font):
    """Effigies (dots), alphas (squares in their level's colour), fast-travel points and towers, labelled."""
    for row in read_table(tables, "actors_PalLevelObjectRelic.tsv"):
        drawing.point(to_picture(float(row["x"]), float(row["y"])), fill=EFFIGY_COLOUR)
    for row in read_table(tables, "DT_BossSpawnerLoactionData.tsv"):
        x, y, _ = world_xyz(row["Location"])
        px, py = to_picture(x, y)
        drawing.rectangle([px - 3, py - 3, px + 3, py + 3], outline=level_colour(int(row["Level"])))
    for row in read_table(tables, "actors_PalLevelObjectUnlockableFastTravelPoint.tsv"):
        px, py = to_picture(float(row["x"]), float(row["y"]))
        drawing.polygon([(px, py - 6), (px - 5, py + 4), (px + 5, py + 4)], outline=FAST_TRAVEL_COLOUR)
        short_id = row["FastTravelPointID"].replace("FTPoint", "F").replace("WatchTower_", "W")
        drawing.text((px + 6, py - 6), short_id, fill=FAST_TRAVEL_TEXT, font=font)
    for row in read_table(tables, "actors_PalBossTower.tsv"):
        px, py = to_picture(float(row["x"]), float(row["y"]))
        drawing.rectangle([px - 8, py - 8, px + 8, py + 8], outline=TOWER_COLOUR, width=3)
        drawing.text((px + 10, py), "T" + row["BossType"], fill=TOWER_TEXT, font=font)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    tables, out = sys.argv[1:3]
    width, height = picture_size()
    picture = Image.new("RGB", (width, height), BACKGROUND)
    drawing = ImageDraw.Draw(picture)
    font = ImageFont.load_default()
    draw_grid(drawing, font)
    draw_spawners(drawing, tables)
    draw_landmarks(drawing, tables, font)
    picture.save(out)
    print(width, height)


if __name__ == "__main__":
    main()
