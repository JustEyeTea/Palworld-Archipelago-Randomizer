"""Corner posts for the Area Locks walls: where two straight pieces of a border meet at a bend, their 4 m thick boxes
overlap in a wedge and the see-through pattern shows twice there; a post (the Art lane's SM_APWallPost, 5.5 m across)
stands on the joint and hides it. Also where a border ends (where borders meet, or at the map's edge): its pieces run
on into the others there. A post stands while any piece it touches stands. Used by tools/lock_walls.py, which writes
the posts into the walls file beside the pieces.
Tests: none of its own; the Lua harness loads the walls files (tests/walls.lua checks every post's pieces exist)."""
import math
from typing import NamedTuple

POST_MIN_TURN = math.radians(5)   # a joint straighter than this is a clean butt joint: no wedge worth hiding
POST_MERGE = 200                  # game units (2 m): posts this close (border ends meeting at one point) are one post
OCTAGON_SYMMETRY = 45             # degrees: the post looks the same turned by this, so its yaw is kept below it


class Post(NamedTuple):
    """One corner post, as the mod's walls file holds it."""
    x: int                      # game units
    y: int
    yaw: float                  # degrees: halves the bend, so a flat face is square to the player inside it
    pieces: tuple               # the wall pieces it touches, as numbers into the file's walls (from 1, as Lua's)


class BorderLine(NamedTuple):
    """One border's line as lock_walls.py cut it: its spots, and the pieces each stretch between two spots became."""
    spots: list                 # (x, y) world spots
    stretch_pieces: list        # for each stretch spots[k] -> spots[k + 1], its pieces' numbers (from 1), in order


def turn_at(before, here, after):
    """How far a border line turns at `here`, in radians (0: straight on)."""
    heading_in = math.atan2(here[1] - before[1], here[0] - before[0])
    heading_out = math.atan2(after[1] - here[1], after[0] - here[0])
    return abs((heading_out - heading_in + math.pi) % (2 * math.pi) - math.pi)


def post_yaw(before, here, after):
    """The yaw that halves the bend at `here` (degrees, 0 to OCTAGON_SYMMETRY); a line's end gives None for the side
    it lacks and takes the one stretch's heading."""
    headings = [math.atan2(b[1] - a[1], b[0] - a[0]) for a, b in ((before, here), (here, after)) if a and b]
    x, y = sum(math.cos(h) for h in headings), sum(math.sin(h) for h in headings)
    return round(math.degrees(math.atan2(y, x)) % OCTAGON_SYMMETRY, 1)


def line_posts(line):
    """The posts along one border line: at each bend sharper than POST_MIN_TURN (a closed loop's ends are one more
    bend) and at each end of an open line."""
    spots, pieces = line.spots, line.stretch_pieces
    closed = len(spots) > 3 and spots[0] == spots[-1]
    posts = []
    for k, here in enumerate(spots[:-1] if closed else spots):
        before = spots[k - 1] if k > 0 else (spots[-2] if closed else None)
        after = spots[k + 1] if k + 1 < len(spots) else None
        if before and after and turn_at(before, here, after) < POST_MIN_TURN:
            continue
        touching = (pieces[k - 1][-1:] if k > 0 else (pieces[-1][-1:] if closed else [])) + \
                   (pieces[k][:1] if k < len(pieces) else [])
        posts.append(Post(round(here[0]), round(here[1]), post_yaw(before, here, after), tuple(touching)))
    return posts


def merged(posts):
    """Posts closer than POST_MERGE as one (the first's place and yaw, every piece they touch), in a stable order."""
    out, cells = [], {}

    def near(post):
        """The kept post within POST_MERGE of this one, if any (looked up in the grid cells around it)."""
        cx, cy = post.x // POST_MERGE, post.y // POST_MERGE
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for k in cells.get((cx + dx, cy + dy), []):
                    if math.dist((out[k].x, out[k].y), (post.x, post.y)) < POST_MERGE:
                        return k
        return None

    for post in posts:
        k = near(post)
        if k is None:
            cells.setdefault((post.x // POST_MERGE, post.y // POST_MERGE), []).append(len(out))
            out.append(post)
        else:
            out[k] = out[k]._replace(pieces=tuple(sorted(set(out[k].pieces) | set(post.pieces))))
    return out


def corner_posts(lines):
    """Every border line's posts, merged where lines meet."""
    return merged([post for line in lines for post in line_posts(line)])
