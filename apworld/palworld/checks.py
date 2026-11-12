"""Which checks and items this seed has: plan_checks and check_counts, the generate_early steps that pick the techs
left as normal research and the shop slots that hold only filler, and stop a seed with too few checks; and the
answers every later step reads (wanted, loc_level, pool_names). PalworldWorld takes these from CheckPlan.
Tests: test_progression.py (TestNoGearLogic, TestPointsBudget, TestTwoTowers), test_options.py (TestTooFewChecks,
TestTooFewFillerForTheFillerOnlySlots, TestRelicHuntRoom), test_logic.py (TestSharedAlpha, TestLevelChecksEvery5)."""
import logging
from typing import FrozenSet, List

from Options import OptionError

from .data import (DECOR_TECHS, FLYING_MOUNTS, LAB_TECH, LOCATIONS, PREREQ_TECHS, PROGRESSIVE_SPHERE, SEA_MOUNTS,
                   SHARED_ALPHAS, SHOP_TECHS, SPHERE_TECHS, STARTER_LEVEL, TECH_BY_ID, Tech, shop_location, tech_item)
from .levels import ANCIENT_POINTS_PER_TOWER, TECH_POINTS_PER_LEVEL, piece_level


class CheckPlan:
    """PalworldWorld's check plan (one of its base classes): it reads and sets the seed's plan (see PalworldWorld)."""

    def plan_checks(self) -> None:
        """Which techs stay normal research, and which shop slots hold only filler: both need the final cap."""
        self.research_techs = self.normal_research()
        self.unaffordable = self.unaffordable_slots()

    def check_counts(self) -> None:
        """Stops a seed the options can't fill: a Paldeck goal above the cap, or more items and filler-only slots than
        checks."""
        o = self.options
        if self.goal_rules().pals:              # the goal must fit under the cap, as the map has lowered it
            reachable = sum(1 for level in self.capture_levels.values() if level <= self.cap)
            if reachable < o.paldeck_count.value:
                raise OptionError(f"Palworld ({self.player_name}): only {reachable} Pals can be registered by level "
                                f"{self.cap}; lower Pals to Register or raise the Check Level Cap.")
        # Every item needs a location, and every unaffordable tech slot a filler item or trap, since Archipelago puts
        # nothing else there: the passes and techs alone can outnumber the checks when most kinds are off.
        relic_hunt = self.goal_rules().relics
        locations = sum(1 for loc in LOCATIONS if self.wanted(loc))
        items = len(self.pool_names())
        filler_only = len(self.unaffordable)
        if locations - items - filler_only < relic_hunt:
            raise OptionError(f"Palworld ({self.player_name}): {locations} checks for {items} items, "
                              f"{filler_only} tech slots that hold only filler (the ones a player can't be sure to "
                              f"afford)" + (" and at least one relic" if relic_hunt else "")
                              + "; turn on more checks (capture, alpha, fast-travel or level checks) or raise the "
                                "Check Level Cap.")
        if o.trap_chance and not any(self.trap_weights()):
            logging.warning(f"Palworld ({self.player_name}): Trap Chance is {o.trap_chance.value}% but every trap "
                            f"weight is 0, so there are no traps")

    def normal_research(self) -> FrozenSet[str]:
        """Techs that stay normal research in this seed (no check, no item): décor with Tech Checks: no décor; techs
        above the Check Level Cap; techs behind a tower outside this seed (its lock beyond the goal, or its piece out
        of play, so the logic never has it beaten); and, without Gear Logic, every card that needs another tech or Lab
        research first (gated)."""
        decor = DECOR_TECHS if self.options.tech_checks == self.options.tech_checks.option_no_decor else frozenset()
        beyond = {t for t, piece in self.layout.towers.items()
                  if self.layout.pieces[piece] not in self.scope or piece not in self.live}
        return decor | {t.id for t in SHOP_TECHS if self.levels.tech(t) > self.cap or t.tower in beyond
                        or (not self.gear and self.gated(t))}

    def loc_level(self, loc) -> int:
        """The level from which a location can be checked, for the check level cap."""
        if loc.kind == "shop":
            return self.levels.tech(TECH_BY_ID[loc.key])
        if loc.kind == "capture":
            return self.capture_levels[loc.key]
        if loc.kind == "alpha":
            return loc.level
        if loc.kind == "fast_travel":
            return piece_level(self.layout, self.layout.location_piece[loc.name])
        if loc.kind == "level":
            return loc.key
        if loc.kind == "tower":
            return self.levels.tower[loc.key]
        raise ValueError(loc.kind)

    def wanted(self, loc) -> bool:
        """Whether this location is a check in this seed: in a lock of the seed, under the cap, and of a
        kind the options turn on."""
        o = self.options
        piece = self.layout.location_piece[loc.name]
        if piece and (self.layout.pieces[piece] not in self.scope or piece not in self.live):
            return False                            # not in this seed
        if self.loc_level(loc) > self.cap:
            return False
        if loc.name in SHARED_ALPHAS:
            return False                            # its defeat records as another alpha's: that one is the check
        if loc.kind == "shop":
            return loc.key not in self.research_techs
        if loc.kind == "capture":
            return bool(o.capture_checks)
        if loc.kind == "alpha":
            return bool(o.alpha_checks)
        if loc.kind == "fast_travel":
            return bool(o.fast_travel_checks)
        if loc.kind == "level":     # the option's choice number is the step: every level, every 5th, every 10th
            return o.level_checks.value != 0 and loc.key % o.level_checks.value == 0
        if loc.kind == "tower":
            return True
        raise ValueError(loc.kind)

    def progression_techs(self) -> FrozenSet[str]:
        """The techs the logic counts on in this seed: every prerequisite, the Lab, breeding, spheres, their furnaces
        and the sea mounts with Gear Logic; without it only the first sphere and the saddles the map needs."""
        if self.gear:
            return frozenset(PREREQ_TECHS)
        out = {SPHERE_TECHS[0].id}
        if self.sea_needed:
            out |= set(SEA_MOUNTS)
        if self.sky_needed:
            out |= set(FLYING_MOUNTS)
        todo = list(out)                        # and whatever those techs' cards need first
        while todo:
            tech = TECH_BY_ID[todo.pop()]
            for need in (tech.prereq, LAB_TECH if tech.research else None):
                if need and TECH_BY_ID[need].level > STARTER_LEVEL and need not in out:
                    out.add(need)
                    todo.append(need)
        return frozenset(out)

    def gated(self, tech: Tech) -> bool:
        """A tech card that needs another (non-starter) tech or Lab research first: without Gear Logic it stays normal
        research, so no check waits on a gear item."""
        return bool(tech.research) or bool(tech.prereq and TECH_BY_ID[tech.prereq].level > STARTER_LEVEL)

    def unaffordable_slots(self) -> FrozenSet[str]:
        """Tech-slot checks a player can't be sure to afford in time; they hold only filler and traps (anyone's), so no
        one's progression or useful item waits on tech points the logic doesn't count. Normal slots are taken in the
        order they open, cheapest first, while their running cost stays within the points levelling gives by then
        (6 a level; fast travel, Technical Manuals and the like are the player's spare). Ancient slots: within the
        Ancient points of the towers beaten before the goal (5 each; the last goal tower's come with the goal), and at
        least one tower's."""
        slots = [t for t in SHOP_TECHS if t.id not in self.research_techs]
        towers = len(self.goal_towers) - (1 if self.goal_rules().last_tower_wins else 0)
        ancient_points = ANCIENT_POINTS_PER_TOWER * max(1, towers)
        keep, normal, ancient = set(), 0, 0
        for t in sorted(slots, key=lambda t: (self.levels.tech(t), t.cost, t.id)):
            if t.ancient:
                if ancient + t.cost <= ancient_points:
                    keep.add(t.id)
                    ancient += t.cost
            elif normal + t.cost <= TECH_POINTS_PER_LEVEL * (self.levels.tech(t) - 1):
                keep.add(t.id)
                normal += t.cost
        return frozenset(shop_location(t) for t in slots if t.id not in keep)

    def passes_in_pool(self) -> List[str]:
        """The pass of each lock in this seed (none without Area Locks)."""
        if not self.options.area_locks:
            return []
        return [p for lock, p in self.layout.passes.items() if lock in self.scope]

    def pool_names(self) -> List[str]:
        """The items every seed's pool holds before relics and filler, in pool order: the passes, then each tech that
        is not normal research (a Progressive Sphere in place of each sphere tech, with Progressive Spheres on)."""
        names = list(self.passes_in_pool())
        for tech in SHOP_TECHS:
            if tech.id in self.research_techs:
                continue
            if self.options.progressive_spheres and tech in SPHERE_TECHS:
                names.append(PROGRESSIVE_SPHERE)
            else:
                names.append(tech_item(tech.id))
        return names

    def beyond_goal_locks(self) -> List[str]:
        """The locks with a pass in the game but not in this seed: walls that stay up (locked) or are down (open)."""
        return sorted(lock for lock in self.layout.passes if lock not in self.scope)
