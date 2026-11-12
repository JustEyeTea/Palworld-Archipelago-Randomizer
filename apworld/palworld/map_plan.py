"""The map this seed uses: plan_map, the generate_early step that picks the locks with passes and checks, the pieces in
play and whether the sea and sky mounts count, and the route searches it rests on (locks_in_scope, corridor, reach).
PalworldWorld takes these from MapPlan.
Tests: test_progression.py (TestTwoTowers, TestBeyondGoalPasses, TestBeyondGoalOpen, TestAreasTwoTowers,
TestWorldTreeKeepsEverything, TestNoGearLogicLeavesTheSeaOut, TestNoGearLogicPassesKeepsEveryPass), test_areas.py."""
import heapq
import logging
from collections import defaultdict
from typing import Callable, Dict, FrozenSet, List

from .data import CATCHABLE, SEA
from .levels import NO_LEVEL, TOWER_MARGIN, piece_level

UNVISITED = (NO_LEVEL + 1, 0)  # corridor's cost of a piece it has not reached yet: worse than any real route


class MapPlan:
    """PalworldWorld's map plan (one of its base classes): it reads and sets the seed's plan (see PalworldWorld)."""

    def plan_map(self) -> None:
        """The goal's towers, the locks in this seed, the pieces in play (live), whether the sea and sky
        mounts are needed, the techs the logic counts on, and each Pal's level; then the cap is held to what the map
        lets a player reach."""
        o = self.options
        self.goal_towers = self.goal_towers_in_order()
        self.scope = self.locks_in_scope()
        if self.goal_rules().pals and self.scope != self.every_lock():
            # Counts every piece of the scope and bred Pals, before live and Gear Logic narrow them, so it can pass
            # where check_counts' count (capture_levels) still refuses the seed.
            in_scope = sum(1 for e in CATCHABLE
                           if self.levels.pal_level(e, self.pieces_of(self.scope)) <= self.asked_cap)
            if in_scope < o.paldeck_count.value:      # the goal's Pals come first: keep every lock instead
                logging.warning(f"Palworld ({self.player_name}): Regions Beyond the Goal would leave {in_scope} "
                                f"Pals to register; every region is kept")
                self.scope = self.every_lock()
        self.live = (self.pieces_of(self.scope) if o.area_locks and o.beyond_goal == o.beyond_goal.option_locked
                     else frozenset(self.layout.pieces))
        # Mounts count only where the map needs them: the open sea always with Gear Logic; without it only when the
        # goal can't be reached by land, and otherwise the pieces only the sea reaches are left out of the seed (no
        # checks there; a player may still swim over). The Sky Islands need a flying mount whenever the seed has them.
        land = self.reach_by_land(self.live)
        self.sea_needed = self.gear or any(p not in land for p in self.goal_pieces())
        if not self.sea_needed:
            self.leave_out_sea_only_pieces(land)
        self.sky_needed = any(lock in self.layout.sky for p, lock in self.layout.pieces.items() if p in self.live)
        self.prog_techs = self.progression_techs()
        # A Pal is a capture check only where this seed has checks: not in locks beyond the goal, open or not.
        checked = self.live & self.pieces_of(self.scope)
        self.capture_levels = ({e: self.levels.pal_level(e, checked, breed=self.gear) for e in CATCHABLE}
                               if checked != frozenset(self.layout.pieces) or not self.gear
                               else self.levels.pal_levels)
        # No check above what the map in this seed lets a player reach.
        self.cap = min(self.asked_cap, self.climb_top(self.live))
        if o.check_level.value and self.cap < o.check_level.value:      # on auto, lowering it is routine
            logging.warning(f"Palworld ({self.player_name}): the Check Level Cap is {o.check_level.value}, but the "
                            f"regions in this seed let a player level only to {self.cap}; checks stop there")

    def leave_out_sea_only_pieces(self, land: FrozenSet[str]) -> None:
        """Takes the pieces only the open sea reaches out of play. With Area Locks and Regions Beyond the Goal locked or
        open, a lock left with no piece in play (the Sky Islands and the World Tree, say) also goes beyond the goal: its
        pass would open nothing the logic knows, so it leaves the pool, and the mod seals or opens its walls like any
        other lock beyond the goal. With passes, every pass stays, as that option promises."""
        o = self.options
        self.live = frozenset(p for p in self.live if p in land)
        if o.area_locks and o.beyond_goal != o.beyond_goal.option_passes:
            locks_in_play = {self.layout.pieces[p] for p in self.live}
            self.scope = frozenset(lock for lock in self.scope if lock in locks_in_play)

    # --- the map this seed uses (Regions Beyond the Goal) ------------------------------------------------------------
    # tests: test_progression.py (TestTwoTowers, TestBeyondGoalPasses, TestBeyondGoalOpen), test_areas.py; corridor
    # and reach_by_land: none of their own
    def every_lock(self) -> FrozenSet[str]:
        """Every lock of this layout, the open sea and the start too."""
        return frozenset(self.layout.pieces.values())

    def pieces_of(self, locks) -> FrozenSet[str]:
        """The pieces that make up these locks."""
        return frozenset(p for p, lock in self.layout.pieces.items() if lock in locks)

    def start_pieces(self) -> List[str]:
        """The pieces of the lock a game starts in, sorted."""
        return sorted(p for p, lock in self.layout.pieces.items() if lock == self.layout.start)

    def goal_pieces(self) -> List[str]:
        """The pieces the goal needs the player to reach: its towers', and the World Tree's for that goal."""
        pieces = [self.layout.towers[t] for t in self.goal_towers]
        if self.goal_rules().world_tree:
            pieces.append(self.layout.world_tree)
        return pieces

    def locks_in_scope(self) -> FrozenSet[str]:
        """The locks this seed has passes and checks in: the start, the open sea, every lock with Pals at or below the
        Check Level Cap (or the goal's towers' level, if higher), and the locks on the cheapest way to the goal's
        towers (and the World Tree). Locks the start can't reach through these are left out too. Without Area Locks,
        or with Regions Beyond the Goal on passes, all."""
        o, layout = self.options, self.layout
        if not o.area_locks or o.beyond_goal == o.beyond_goal.option_passes:
            return self.every_lock()
        low: Dict[str, int] = {}
        for piece, lock in layout.pieces.items():
            low[lock] = min(low.get(lock, NO_LEVEL), piece_level(layout, piece))
        # Up to the cap, but never short of what the goal's towers need to level for (a low cap set by hand only
        # takes checks away, not the locks a player levels in).
        need = max([self.asked_cap] + [self.levels.tower[t] + TOWER_MARGIN for t in self.goal_towers])
        scope = {lock for lock, level in low.items() if level <= need} | {layout.start, SEA}
        for target in self.goal_pieces():
            scope |= {layout.pieces[p] for p in self.corridor(target, scope, low)}
        reached = self.reach(scope)
        return frozenset(lock for lock in scope if any(layout.pieces[p] == lock for p in reached))

    def neighbours(self) -> Dict[str, List[str]]:
        """Each piece's neighbours across a border, sorted (so the route searches are the same in every run)."""
        out = defaultdict(set)
        for a, b in self.layout.borders:
            out[a].add(b)
            out[b].add(a)
        return {p: sorted(n) for p, n in out.items()}

    def corridor(self, target: str, scope, low: Dict[str, int]) -> List[str]:
        """The pieces outside `scope` on the way from the start to `target`: the route whose highest such lock is
        lowest, then the one through the fewest pieces."""
        layout, nbrs = self.layout, self.neighbours()
        start = self.start_pieces()
        best = {p: (0, 0) for p in start}
        prev: Dict[str, str] = {}
        heap = [(0, 0, p) for p in start]
        while heap:
            worst, steps, piece = heapq.heappop(heap)
            if (worst, steps) > best[piece]:
                continue
            if piece == target:
                break
            for nxt in nbrs.get(piece, ()):
                lock = layout.pieces[nxt]
                key = (max(worst, 0 if lock in scope else low[lock]), steps + 1)
                if key < best.get(nxt, UNVISITED):
                    best[nxt], prev[nxt] = key, piece
                    heapq.heappush(heap, (key[0], key[1], nxt))
        path, piece = [], target
        while piece in prev:
            path.append(piece)
            piece = prev[piece]
        return [p for p in path if layout.pieces[p] not in scope]

    def flood(self, may_enter: Callable[[str], bool]) -> FrozenSet[str]:
        """The pieces the start reaches across borders, entering only the pieces may_enter allows."""
        nbrs = self.neighbours()
        todo = self.start_pieces()
        seen = set(todo)
        while todo:
            for nxt in nbrs.get(todo.pop(), ()):
                if nxt not in seen and may_enter(nxt):
                    seen.add(nxt)
                    todo.append(nxt)
        return frozenset(seen)

    def reach(self, scope) -> FrozenSet[str]:
        """The pieces the start reaches through the borders of these locks (mounts aside: the logic sees to those)."""
        return self.flood(lambda piece: self.layout.pieces[piece] in scope)

    def reach_by_land(self, live: FrozenSet[str]) -> FrozenSet[str]:
        """The pieces in play (live) the start reaches without the open sea (and without going up to the sky)."""
        def by_land(piece: str) -> bool:
            lock = self.layout.pieces[piece]
            return piece in live and lock != SEA and lock not in self.layout.sky
        return self.flood(by_land)
