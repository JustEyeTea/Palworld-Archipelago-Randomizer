"""The level model: the tuning numbers (in player levels), the levels each cut of the map gives (towers' bosses, the
techs behind them, the first level each Pal can be had at), and the climb, which answers how far a player can level and
what they can catch and fight. PalworldWorld takes the climb from LevelModel.
Tests: test_logic.py (TestLevels), test_areas.py (TestAreasBossAboveTheClimb), test_options.py
(TestPlayerTextMatchesTheCode, for the player text's copies of these numbers)."""
import math
from typing import Callable, FrozenSet, Optional

from BaseClasses import CollectionState

from .data import (BREEDING_TECH, CATCHABLE, CAUGHT_KINDS, DIRECT, LAYOUTS, MAX_LEVEL, SPHERE_NEEDS, SPHERE_TECHS,
                   TECH_BY_ID, Layout, Tech)

# Tuning, in player levels unless said. The options' descriptions (options.py) and the game page
# (docs/en_Palworld.md) repeat TOWER_LEVELS, TOWER_MARGIN, PALDECK_MARGIN and RELIC_LEVEL, and the game page also
# LEVELS_BELOW_PIECE and TECH_POINTS_PER_LEVEL; test_options.py's TestPlayerTextMatchesTheCode checks every copy.
FREE_LEVEL = 15              # levels anyone reaches in the starting zone
LEVELS_PAST_PIECE = 8        # a piece lets a player level about this far past its typical Pal level
LEVELS_BELOW_PIECE = 8       # and only a player at most this far below that level can start levelling there
WORLD_TREE_BOSS_MARGIN = 4   # the World Tree boss asks for this much past its piece's Pal level (half a climb)
SPHERE_STEP = 10             # each sphere tier catches Pals about this many levels higher
TOWER_MARGIN = 8             # levels a player passes the last tower they need (the Towers goal's check level)
PALDECK_MARGIN = 5           # the same for the Pal that completes a Paldeck goal
RELIC_LEVEL = 30             # the Relic Hunt goal's check level when left on auto
TECH_POINTS_PER_LEVEL = 6    # the game's tech points for each level (1.0.5 tables)
ANCIENT_POINTS_PER_TOWER = 5  # Ancient tech points a tower boss gives
NO_LEVEL = MAX_LEVEL + 1     # "never": above every real level, so it fails any "<= cap" test
# The level each tower's boss fight asks for (Zoe, Lily, Axel, Marcus, Victor, Saya, Bjorn, Auri; from web research,
# not the game's tables), which is also the order a Towers goal takes them in.
TOWER_LEVELS = {"Starting Zone Tower": 10, "Forest Tower": 20, "Volcano Tower": 30, "Desert Tower": 40,
                "Snow Tower": 50, "Sakurajima Tower": 55, "Feybreak Tower": 60, "Sky Islands Tower": 68}


def piece_level(layout: Layout, piece: str) -> int:
    """A piece's typical Pal level. A piece with no Pals of its own takes the level of the piece named after its lock
    (the lock's main piece), and 0 when that has none either."""
    return int(layout.piece_levels.get(piece) or layout.piece_levels.get(layout.pieces.get(piece, piece)) or 0)


class Levels:
    """The levels a layout (the Lock Size option) gives: towers' bosses, techs behind them, and the first level each Pal
    can be had at."""
    def __init__(self, layout: Layout):
        self.layout = layout
        self.tower = {name: TOWER_LEVELS[name] for name in layout.towers}
        self.pal_levels = {e: self.pal_level(e) for e in CATCHABLE}
        self.caught_pal_levels = {e: self.pal_level(e, breed=False) for e in CATCHABLE}  # bred-only Pals: NO_LEVEL

    def world_tree_boss_level(self, piece: str) -> int:
        """The level the World Tree's boss, in this piece, asks for (as the logic has it)."""
        return piece_level(self.layout, piece) + WORLD_TREE_BOSS_MARGIN

    def tech(self, tech: Tech) -> int:
        """The level from which a tech can be had: its own, or its tower's if it needs one."""
        return max(tech.level, self.tower[tech.tower] if tech.tower else 0)

    def pal_level(self, entry: str, live: Optional[FrozenSet[str]] = None, breed: bool = True) -> int:
        """The lowest level at which a Pal can be had: where it is caught, or for a bred-only Pal (with `breed`), its
        parents' level and the Breeding Farm's. With `live`, only sources in those pieces count."""
        sources = self.layout.sources
        caught = lambda source: source.kind in CAUGHT_KINDS and (live is None or source.piece in live)
        best = NO_LEVEL
        for source in sources[entry]:
            if caught(source):
                best = min(best, int(source.level))
            elif breed and source.kind == "breed" and all(p in DIRECT for p in source.parents):
                parents = max(min((int(s.level) for s in sources[p] if caught(s)), default=NO_LEVEL)
                              for p in source.parents)
                best = min(best, max(parents, self.tech(TECH_BY_ID[BREEDING_TECH])))
        return best


LEVELS_BY_LAYOUT = {name: Levels(layout) for name, layout in LAYOUTS.items()}


class LevelModel:
    """PalworldWorld's level model (one of its base classes): it reads the seed's plan that generate_early sets."""

    # --- the level model: how far the player can level, and what they can catch and fight ----------------------------
    # tests: test_logic.py (TestLevels); climb_top: none of its own
    # The climb asks, for each piece, whether the player can catch its Pals at the level reached so far. That question
    # (can_catch_at, then sphere_tier, has_tech and shop_ok) takes `level_so_far` and must pass it on: without it,
    # shop_ok asks level_ok, which calls max_level again, and the logic recurses without end in any seed where a sphere
    # or furnace tech stays normal research.
    def climb(self, live: FrozenSet[str], can_level_in: Callable[[str, int], bool]) -> int:
        """The level climb that max_level and climb_top share: from FREE_LEVEL, the pieces in `live` in order of their
        Pals' level. A piece no more than LEVELS_BELOW_PIECE above the level so far, and that can_level_in(piece, level
        so far) allows, takes the player to LEVELS_PAST_PIECE past its Pals' level; the first piece too far above
        ends the climb."""
        level_so_far = FREE_LEVEL
        levels = self.layout.piece_levels
        for piece in sorted((piece for piece in levels if piece in live), key=levels.get):
            if levels[piece] - LEVELS_BELOW_PIECE > level_so_far:
                break
            if can_level_in(piece, level_so_far):
                level_so_far = max(level_so_far, int(levels[piece]) + LEVELS_PAST_PIECE)
        return level_so_far

    def climb_top(self, live: FrozenSet[str]) -> int:
        """The highest level these pieces let a player reach: the climb with everything in hand."""
        return min(MAX_LEVEL, self.climb(live, lambda piece, level_so_far: True))

    def max_level(self, state: CollectionState) -> int:
        """How far the player can level: the climb, through each piece that is open and whose Pals they can catch."""
        levels = self.layout.piece_levels
        return self.climb(self.live, lambda piece, level_so_far: self.piece_open(state, piece)
                          and self.can_catch_at(state, levels[piece], level_so_far))

    def level_ok(self, state: CollectionState, level: int) -> bool:
        """Whether the player can reach this level: anyone reaches FREE_LEVEL, the rest is the climb (max_level)."""
        return level <= FREE_LEVEL or level <= self.max_level(state)

    def sphere_tier(self, state: CollectionState, level_so_far: Optional[int] = None) -> int:
        """Spheres the player can make, in order: each sphere's tech and what its recipe needs (SPHERE_NEEDS; the Pal
        Sphere has no row there, so it needs its tech alone). level_so_far: see the note above climb."""
        tier = 0
        for tech in SPHERE_TECHS:
            needs = SPHERE_NEEDS.get(tech.id, ()) if self.gear else ()
            if not all(self.has_tech(state, t, level_so_far) for t in (tech.id,) + needs):
                break
            tier += 1
        return tier

    def can_catch_at(self, state: CollectionState, level: int, level_so_far: Optional[int] = None) -> bool:
        """Spheres good enough for Pals of this level. level_so_far: the player's level inside the climb (see the note
        above climb); None elsewhere."""
        need = min(len(SPHERE_TECHS), max(1, math.ceil(level / SPHERE_STEP))) if self.gear else 1
        return self.sphere_tier(state, level_so_far) >= need

    def can_fight_at(self, state: CollectionState, level: int) -> bool:
        """A boss of this level: the level, and a team of Pals caught at about it."""
        return self.level_ok(state, level) and self.can_catch_at(state, level)
