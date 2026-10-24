"""The engine's pathfinding grid of an area (CGrid, pathfind.cpp) and routes on it.

An area keeps its grid at area + AREA_GRID, built at load from the area's
HEXGRID resource by the constructor at 0x475db0. Cells are pointy-top hexes:
column j runs along world y (spacing 1.5 * cell), row r along world x
(spacing 2 * half_w), odd columns shifted half a row in +x. Cell index is
j * h + r. A cell's byte is its source byte + 1, kept below 0xfc; source
bytes 0xfc and up are stored as they are. The engine's A* (0x477b90) never
enters 0xfe or 0xff (nor a cell set in the bitmap at CGrid + 0x18), steps
onto other cells at their byte as cost (0xfd costs 1 and is entered but not
expanded through). Centre per 0x475f80, corners per 0x476040.

The grid is one layer: under a walkway over lower ground, or where a ledge
is narrower than a cell, it holds thin bands of 0xfe that collision lets a
body walk through. Routes here may cross such a band at a high cost (see
soft); 0xff and blocks learned by walking into them stay hard. Placeables
stamp patches into the live grid as they open and close (0x476f00, called
from CArtPlaceable::SetHexGridPatch at 0x4aa790), so a grid read after a
cutscene can be cut where it was open before.
WHY: docs/modding.md §6
"""
import heapq
import math
import struct
from collections import namedtuple

AREA_GRID = 0x1DC      # area object -> embedded CGrid
HEADER_SIZE = 48       # CGrid fields read: 12 x 4 bytes
HARD = 0xFE            # cell byte at or above which the engine's A* never enters a cell
BLOCKED = 0xFF         # byte block_disc writes: a block soft never lets a route cross
DEAD_END = 0xFD        # engine enters this cell but does not expand through it
WALL_COST = 4.0        # extra cost of a cell next to a blocking one, keeps routes off walls
BAND = 3               # most 0xfe cells across a band, along a hex axis, that soft lets a route cross
SOFT_COST = 12.0       # cost of stepping onto a soft cell: routes cross a band only to save a detour
THROUGH_COST = 1000.0  # cost of a blocked cell to route(through=True): crossed only where no way round
LOS_STEP = 0.25        # metres between line-of-sight samples
BODY = 0.4             # metres each side of a straight segment that must be open

Grid = namedtuple("Grid", "w h cell half_w ox oy cells")


def parse(header, cells):
    """A Grid from the 48 header bytes and the w*h cell bytes."""
    assert len(header) == HEADER_SIZE, len(header)
    _, _, w, h, n, _, _ = struct.unpack("<2f5I", header[:28])
    cell, _, half_w, ox, oy = struct.unpack("<5f", header[28:48])
    assert 0 < w and 0 < h and w * h == n, (w, h, n)
    assert len(cells) == n, (len(cells), n)
    assert cell > 0 and half_w > 0, (cell, half_w)
    return Grid(w, h, cell, half_w, ox, oy, bytes(cells))


def header_cells(header):
    """(guest address of the cell bytes, their count) from the header."""
    _, _, _, _, n, ptr, _ = struct.unpack("<2f5I", header[:28])
    return ptr, n


def center(g, i):
    """World (x, y) of the centre of cell i."""
    j, r = divmod(i, g.h)
    return g.ox + (2 * r + (j & 1)) * g.half_w, g.oy + j * 1.5 * g.cell


def cell_at(g, x, y):
    """Index of the cell whose centre is nearest (x, y), or None off the grid."""
    j0 = round((y - g.oy) / (1.5 * g.cell))
    best, best_d = None, math.inf
    for j in (j0 - 1, j0, j0 + 1):
        if not 0 <= j < g.w:
            continue
        r0 = round((x - g.ox) / (2 * g.half_w) - 0.5 * (j & 1))
        for r in (r0 - 1, r0, r0 + 1):
            if not 0 <= r < g.h:
                continue
            cx, cy = center(g, j * g.h + r)
            d = (cx - x) ** 2 + (cy - y) ** 2
            if d < best_d:
                best, best_d = j * g.h + r, d
    return best


def open_cell(g, i):
    return i is not None and g.cells[i] < HARD


def step(g, i, d):
    """The neighbour of cell i in direction d (0..5), or None off the grid.
    Directions d and d ^ 1 are opposite, so 0, 2 and 4 name the three axes."""
    j, r = divmod(i, g.h)
    shift = j & 1  # odd columns sit half a row further in +x
    dj, dr = ((0, -1), (0, 1), (-1, shift - 1), (1, shift), (-1, shift), (1, shift - 1))[d]
    if 0 <= j + dj < g.w and 0 <= r + dr < g.h:
        return (j + dj) * g.h + r + dr
    return None


def soft(g, i):
    """Whether cell i is a 0xfe cell in a band at most BAND cells across:
    along some hex axis, open cells on both sides with only 0xfe cells
    between. Such bands are where the one-layer grid disagrees with
    collision (see the module docstring)."""
    if g.cells[i] != HARD:
        return False
    for axis in (0, 2, 4):
        a, b = _steps_to_open(g, i, axis), _steps_to_open(g, i, axis ^ 1)
        if a + b - 1 <= BAND:
            return True
    return False


def _steps_to_open(g, i, d):
    """Steps from cell i in direction d to the first open cell, passing only
    0xfe cells; past BAND (more than any soft band allows) when none is."""
    k = i
    for n in range(1, BAND + 1):
        k = step(g, k, d)
        if k is None or g.cells[k] > HARD:
            return BAND + 1
        if g.cells[k] < HARD:
            return n
    return BAND + 1


def nearest_open(g, i, rings):
    """The open cell fewest hex steps from cell i, at most rings steps away,
    or None. Breadth-first over neighbours, so ties go to the first found."""
    assert i is not None and rings >= 0, (i, rings)
    seen, ring = {i}, [i]
    for _ in range(rings + 1):
        for k in ring:
            if open_cell(g, k):
                return k
        ring = [n for k in ring for n in neighbours(g, k) if n not in seen]
        seen.update(ring)
    return None


def block_disc(g, x, y, radius):
    """A copy of g with every cell whose centre lies within radius metres of
    (x, y) blocked: an obstacle the grid does not hold (a body, a prop placed
    after load) found by walking into it."""
    assert radius > 0, radius
    cells = bytearray(g.cells)
    i = cell_at(g, x, y)
    if i is None:
        return g
    rings = int(radius / g.half_w) + 1
    seen, ring = {i}, [i]
    for _ in range(rings + 1):
        for k in ring:
            if math.dist(center(g, k), (x, y)) <= radius:
                cells[k] = BLOCKED
        ring = [n for k in ring for n in neighbours(g, k) if n not in seen]
        seen.update(ring)
    return g._replace(cells=bytes(cells))


def soft_on_leg(g, a, b):
    """The first soft cell the straight segment a -> b passes over, or None."""
    n = max(1, int(math.dist(a, b) / LOS_STEP))
    for k in range(n + 1):
        t = k / n
        i = cell_at(g, a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
        if i is not None and soft(g, i):
            return i
    return None


def harden_band(g, i, cap):
    """A copy of g with the 0xfe cells connected to cell i (at most cap of
    them) blocked: a band walking showed to be a real wall. A long wall is a
    long band, and blocking one disc of it only moves the route to the next
    soft crossing along it. Returns (grid, cells blocked)."""
    assert g.cells[i] == HARD, g.cells[i]
    cells = bytearray(g.cells)
    seen, todo = {i}, [i]
    for _ in range(cap):
        if not todo:
            break
        k = todo.pop()
        cells[k] = BLOCKED
        for n in neighbours(g, k):
            if n not in seen and g.cells[n] == HARD:
                seen.add(n)
                todo.append(n)
    return g._replace(cells=bytes(cells)), len(seen) - len(todo)


def neighbours(g, i):
    """Indices of the up to six cells sharing an edge with cell i."""
    j, r = divmod(i, g.h)
    shift = j & 1  # odd columns sit half a row further in +x
    steps = ((0, -1), (0, 1), (-1, shift - 1), (-1, shift), (1, shift - 1), (1, shift))
    return [(j + dj) * g.h + r + dr for dj, dr in steps
            if 0 <= j + dj < g.w and 0 <= r + dr < g.h]


def step_cost(g, i):
    """Cost of stepping onto cell i (open or soft). The engine charges the
    byte itself; here 1 plus a tenth of it, so a 0xfc cell weighs ~26 steps
    rather than 252 and routes still prefer clear ground."""
    if g.cells[i] == HARD:
        return SOFT_COST
    near_wall = any(not open_cell(g, n) for n in neighbours(g, i))
    byte = 1 if g.cells[i] == DEAD_END else g.cells[i]
    return 1.0 + (WALL_COST if near_wall else 0.0) + (byte - 1) * 0.1


def route(g, start, goal, through=False):
    """Cell indices from start to goal (both open), or None if none connects.
    A* over hex edges onto open and soft cells; each cell is expanded at
    most once. through: also step onto blocked cells, at THROUGH_COST each,
    to find where a wall cuts the cheapest way (see first_blocked)."""
    assert open_cell(g, start) and open_cell(g, goal), (start, goal)
    gx, gy = center(g, goal)
    unit = 2 * g.half_w
    came, cost = {start: None}, {start: 0.0}
    todo, done = [(0.0, start)], set()
    for _ in range(6 * g.w * g.h + 1):  # each expansion pushes at most six cells
        if not todo:
            return None
        _, i = heapq.heappop(todo)
        if i == goal:
            path = []
            for _ in range(g.w * g.h):
                if i is None:
                    return path[::-1]
                path.append(i)
                i = came[i]
            raise AssertionError("route back-chain longer than the grid")
        if i in done:
            continue
        done.add(i)
        if g.cells[i] == DEAD_END and i != start:
            continue
        for n in neighbours(g, i):
            passable = open_cell(g, n) or soft(g, n)
            if n in done or not (passable or through):
                continue
            c = cost[i] + (step_cost(g, n) if passable else THROUGH_COST)
            if c < cost.get(n, math.inf):
                cost[n], came[n] = c, i
                nx, ny = center(g, n)
                heapq.heappush(todo, (c + math.hypot(nx - gx, ny - gy) / unit, n))
    return None


def first_blocked(g, path):
    """The first cell on path neither open nor soft, or None."""
    assert path is not None, "route through blocked cells found no way"
    return next((i for i in path if not (open_cell(g, i) or soft(g, i))), None)


def clear(g, a, b):
    """Whether a body of radius BODY walking the straight segment a -> b stays
    on open cells: the segment and its two sides, sampled every LOS_STEP."""
    d = math.dist(a, b)
    if d == 0:
        return open_cell(g, cell_at(g, *a))
    nx, ny = (a[1] - b[1]) / d * BODY, (b[0] - a[0]) / d * BODY
    n = max(1, int(d / LOS_STEP))
    for k in range(n + 1):
        t = k / n
        x, y = a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t
        for s in (0, 1, -1):
            if not open_cell(g, cell_at(g, x + s * nx, y + s * ny)):
                return False
    return True


def waypoints(g, path):
    """World points along path with every corner a straight segment can cut
    removed (string pulling); the first and last cells' centres included."""
    pts = [center(g, i) for i in path]
    if len(pts) <= 2:
        return pts
    out, k = [pts[0]], 0
    for _ in range(len(pts)):  # k grows by at least one per pass
        if k == len(pts) - 1:
            return out
        far = k + 1
        for m in range(len(pts) - 1, k + 1, -1):
            if clear(g, pts[k], pts[m]):
                far = m
                break
        out.append(pts[far])
        k = far
    raise AssertionError("string pulling did not reach the last point")
