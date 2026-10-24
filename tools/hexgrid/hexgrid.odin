// The engine's pathfinding grid of an area (CGrid, pathfind.cpp) and routes on it.
//
// An area keeps its grid at area + AREA_GRID, built at load from the area's
// HEXGRID resource by the constructor at 0x475db0. Cells are pointy-top hexes:
// column j runs along world y (spacing 1.5 * cell), row r along world x
// (spacing 2 * half_w), odd columns shifted half a row in +x. Cell index is
// j * h + r. A cell's byte is its source byte + 1, kept below 0xfc; source
// bytes 0xfc and up are stored as they are. The engine's A* (0x477b90) never
// enters 0xfe or 0xff (nor a cell set in the bitmap at CGrid + 0x18), steps
// onto other cells at their byte as cost (0xfd costs 1 and is entered but not
// expanded through). Centre per 0x475f80, corners per 0x476040.
//
// The grid is one layer: under a walkway over lower ground, or where a ledge
// is narrower than a cell, it holds thin bands of 0xfe that collision lets a
// body walk through. Routes here may cross such a band at a high cost (see
// soft); 0xff and blocks learned by walking into them stay hard. Placeables
// stamp patches into the live grid as they open and close (0x476f00, called
// from CArtPlaceable::SetHexGridPatch at 0x4aa790), so a grid read after a
// cutscene can be cut where it was open before.
// WHY: docs/modding.md §6
package hexgrid

import pq "core:container/priority_queue"
import "core:fmt"
import "core:math"
import "../common"

AREA_GRID :: 0x1DC // area object -> embedded CGrid
HEADER_SIZE :: 48 // CGrid fields read: 12 x 4 bytes
HARD :: 0xFE // cell byte at or above which the engine's A* never enters a cell
BLOCKED :: 0xFF // byte block_disc writes: a block soft never lets a route cross
DEAD_END :: 0xFD // engine enters this cell but does not expand through it
WALL_COST :: 4.0 // extra cost of a cell next to a blocking one, keeps routes off walls
BAND :: 3 // most 0xfe cells across a band, along a hex axis, that soft lets a route cross
SOFT_COST :: 12.0 // cost of stepping onto a soft cell: routes cross a band only to save a detour
THROUGH_COST :: 1000.0 // cost of a blocked cell to route(through=true): crossed only where no way round
LOS_STEP :: 0.25 // metres between line-of-sight samples
BODY :: 0.4 // metres each side of a straight segment that must be open
NONE :: -1 // no cell: off the grid, or not found

Grid :: struct {
	w, h:                   int,
	cell, half_w, ox, oy: f64,
	cells:                  []u8,
}

Point :: [2]f64

u32_at :: proc(b: []u8, o: int) -> u32 {
	return u32(b[o]) | u32(b[o + 1]) << 8 | u32(b[o + 2]) << 16 | u32(b[o + 3]) << 24
}

f32_at :: proc(b: []u8, o: int) -> f64 {return f64(transmute(f32)u32_at(b, o))}

// A Grid from the 48 header bytes and the w*h cell bytes.
parse :: proc(header, cells: []u8) -> Grid {
	fmt.assertf(len(header) == HEADER_SIZE, "%d", len(header))
	w, h, n := int(u32_at(header, 8)), int(u32_at(header, 12)), int(u32_at(header, 16))
	fmt.assertf(0 < w && 0 < h && w * h == n, "%d %d %d", w, h, n)
	fmt.assertf(len(cells) == n, "%d %d", len(cells), n)
	g := Grid{w, h, f32_at(header, 28), f32_at(header, 36), f32_at(header, 40), f32_at(header, 44), nil}
	fmt.assertf(g.cell > 0 && g.half_w > 0, "%v %v", g.cell, g.half_w)
	g.cells = make([]u8, n)
	copy(g.cells, cells)
	return g
}

// Guest address of the cell bytes, and their count, from the header.
header_cells :: proc(header: []u8) -> (ptr: u32, n: int) {
	return u32_at(header, 20), int(u32_at(header, 16))
}

// World (x, y) of the centre of cell i.
center :: proc(g: Grid, i: int) -> Point {
	j, r := i / g.h, i % g.h
	return {g.ox + f64(2 * r + (j & 1)) * g.half_w, g.oy + f64(j) * 1.5 * g.cell}
}

// Index of the cell whose centre is nearest p, or NONE off the grid.
cell_at :: proc(g: Grid, p: Point) -> int {
	j0 := common.py_round((p.y - g.oy) / (1.5 * g.cell))
	best, best_d := NONE, math.INF_F64
	for j in j0 - 1 ..= j0 + 1 {
		if !(0 <= j && j < g.w) do continue
		r0 := common.py_round((p.x - g.ox) / (2 * g.half_w) - 0.5 * f64(j & 1))
		for r in r0 - 1 ..= r0 + 1 {
			if !(0 <= r && r < g.h) do continue
			c := center(g, j * g.h + r)
			d := (c.x - p.x) * (c.x - p.x) + (c.y - p.y) * (c.y - p.y)
			if d < best_d do best, best_d = j * g.h + r, d
		}
	}
	return best
}

open_cell :: proc(g: Grid, i: int) -> bool {
	return i != NONE && g.cells[i] < HARD
}

// The neighbour of cell i in direction d (0..5), or NONE off the grid.
// Directions d and d ~ 1 are opposite, so 0, 2 and 4 name the three axes.
step :: proc(g: Grid, i, d: int) -> int {
	j, r := i / g.h, i % g.h
	shift := j & 1 // odd columns sit half a row further in +x
	steps := [6][2]int{{0, -1}, {0, 1}, {-1, shift - 1}, {1, shift}, {-1, shift}, {1, shift - 1}}
	dj, dr := steps[d][0], steps[d][1]
	if 0 <= j + dj && j + dj < g.w && 0 <= r + dr && r + dr < g.h do return (j + dj) * g.h + r + dr
	return NONE
}

// Whether cell i is a 0xfe cell in a band at most BAND cells across: along
// some hex axis, open cells on both sides with only 0xfe cells between. Such
// bands are where the one-layer grid disagrees with collision (see the
// package comment).
soft :: proc(g: Grid, i: int) -> bool {
	if g.cells[i] != HARD do return false
	for axis in ([3]int{0, 2, 4}) {
		if steps_to_open(g, i, axis) + steps_to_open(g, i, axis ~ 1) - 1 <= BAND do return true
	}
	return false
}

// Steps from cell i in direction d to the first open cell, passing only 0xfe
// cells; past BAND (more than any soft band allows) when none is.
steps_to_open :: proc(g: Grid, i, d: int) -> int {
	k := i
	for n in 1 ..= BAND {
		k = step(g, k, d)
		if k == NONE || g.cells[k] > HARD do return BAND + 1
		if g.cells[k] < HARD do return n
	}
	return BAND + 1
}

// The next ring of a breadth-first walk: unseen neighbours of ring, in order
// (a cell next to two ring cells appears twice), all then marked seen.
next_ring :: proc(g: Grid, ring: []int, seen: []bool) -> []int {
	out: [dynamic]int
	for k in ring {
		nb, nn := neighbours(g, k)
		for n in nb[:nn] do if !seen[n] do append(&out, n)
	}
	for n in out do seen[n] = true
	return out[:]
}

// The open cell fewest hex steps from cell i, at most rings steps away, or
// NONE. Breadth-first over neighbours, so ties go to the first found.
nearest_open :: proc(g: Grid, i, rings: int) -> int {
	fmt.assertf(i != NONE && rings >= 0, "%d %d", i, rings)
	seen := make([]bool, len(g.cells))
	defer delete(seen)
	seen[i] = true
	ring := []int{i}
	for _ in 0 ..= rings {
		for k in ring do if open_cell(g, k) do return k
		ring = next_ring(g, ring, seen)
	}
	return NONE
}

// A copy of g with every cell whose centre lies within radius metres of p
// blocked: an obstacle the grid does not hold (a body, a prop placed after
// load) found by walking into it.
block_disc :: proc(g: Grid, p: Point, radius: f64) -> Grid {
	fmt.assertf(radius > 0, "%v", radius)
	i := cell_at(g, p)
	if i == NONE do return g
	out := g
	out.cells = make([]u8, len(g.cells))
	copy(out.cells, g.cells)
	rings := int(radius / g.half_w) + 1
	seen := make([]bool, len(g.cells))
	defer delete(seen)
	seen[i] = true
	ring := []int{i}
	for _ in 0 ..= rings {
		for k in ring do if dist(center(g, k), p) <= radius do out.cells[k] = BLOCKED
		ring = next_ring(g, ring, seen)
	}
	return out
}

dist :: proc(a, b: Point) -> f64 {return common.py_hypot(a.x - b.x, a.y - b.y)}

// The first soft cell the straight segment a -> b passes over, or NONE.
soft_on_leg :: proc(g: Grid, a, b: Point) -> int {
	n := max(1, int(dist(a, b) / LOS_STEP))
	for k in 0 ..= n {
		t := f64(k) / f64(n)
		i := cell_at(g, {a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t})
		if i != NONE && soft(g, i) do return i
	}
	return NONE
}

// A copy of g with the 0xfe cells connected to cell i (at most cap of them)
// blocked: a band walking showed to be a real wall. A long wall is a long
// band, and blocking one disc of it only moves the route to the next soft
// crossing along it. Returns the grid and the cells blocked.
harden_band :: proc(g: Grid, i, cap: int) -> (Grid, int) {
	fmt.assertf(g.cells[i] == HARD, "%d", g.cells[i])
	out := g
	out.cells = make([]u8, len(g.cells))
	copy(out.cells, g.cells)
	seen := make([]bool, len(g.cells))
	defer delete(seen)
	seen[i] = true
	nseen := 1
	todo: [dynamic]int
	defer delete(todo)
	append(&todo, i)
	for _ in 0 ..< cap {
		if len(todo) == 0 do break
		k := pop(&todo)
		out.cells[k] = BLOCKED
		nb, nn := neighbours(g, k)
		for n in nb[:nn] {
			if !seen[n] && g.cells[n] == HARD {
				seen[n] = true
				nseen += 1
				append(&todo, n)
			}
		}
	}
	return out, nseen - len(todo)
}

// Indices of the up to six cells sharing an edge with cell i: buf[:n].
neighbours :: proc(g: Grid, i: int) -> (buf: [6]int, n: int) {
	j, r := i / g.h, i % g.h
	shift := j & 1 // odd columns sit half a row further in +x
	steps := [6][2]int{{0, -1}, {0, 1}, {-1, shift - 1}, {-1, shift}, {1, shift - 1}, {1, shift}}
	for s in steps {
		if 0 <= j + s[0] && j + s[0] < g.w && 0 <= r + s[1] && r + s[1] < g.h {
			buf[n] = (j + s[0]) * g.h + r + s[1]
			n += 1
		}
	}
	return
}

// Cost of stepping onto cell i (open or soft). The engine charges the byte
// itself; here 1 plus a tenth of it, so a 0xfc cell weighs ~26 steps rather
// than 252 and routes still prefer clear ground.
step_cost :: proc(g: Grid, i: int) -> f64 {
	if g.cells[i] == HARD do return SOFT_COST
	near_wall := false
	nb, nn := neighbours(g, i)
	for n in nb[:nn] do if !open_cell(g, n) do near_wall = true
	byte := g.cells[i] == DEAD_END ? 1 : int(g.cells[i])
	return 1.0 + (near_wall ? WALL_COST : 0.0) + f64(byte - 1) * 0.1
}

Todo :: struct {
	f: f64,
	i: int,
}

// Cell indices from start to goal (both open), or nil if none connects. A*
// over hex edges onto open and soft cells; each cell is expanded at most
// once. through: also step onto blocked cells, at THROUGH_COST each, to find
// where a wall cuts the cheapest way (see first_blocked).
route :: proc(g: Grid, start, goal: int, through := false) -> []int {
	fmt.assertf(open_cell(g, start) && open_cell(g, goal), "%d %d", start, goal)
	gc := center(g, goal)
	unit := 2 * g.half_w
	n := len(g.cells)
	came, cost, done := make([]int, n), make([]f64, n), make([]bool, n)
	defer delete(came)
	defer delete(cost)
	defer delete(done)
	for k in 0 ..< n do came[k], cost[k] = NONE, math.INF_F64
	cost[start] = 0
	todo: pq.Priority_Queue(Todo)
	pq.init(&todo, proc(a, b: Todo) -> bool {return a.f < b.f || a.f == b.f && a.i < b.i}, pq.default_swap_proc(Todo))
	defer pq.destroy(&todo)
	pq.push(&todo, Todo{0, start})
	for _ in 0 ..= 6 * n { // each expansion pushes at most six cells
		if pq.len(todo) == 0 do return nil
		i := pq.pop(&todo).i
		if i == goal {
			path: [dynamic]int
			for _ in 0 ..< n {
				if i == NONE {
					for a, b := 0, len(path) - 1; a < b; a, b = a + 1, b - 1 do path[a], path[b] = path[b], path[a]
					return path[:]
				}
				append(&path, i)
				i = came[i]
			}
			panic("route back-chain longer than the grid")
		}
		if done[i] do continue
		done[i] = true
		if g.cells[i] == DEAD_END && i != start do continue
		nb, nn := neighbours(g, i)
		for m in nb[:nn] {
			passable := open_cell(g, m) || soft(g, m)
			if done[m] || !(passable || through) do continue
			c := cost[i] + (passable ? step_cost(g, m) : THROUGH_COST)
			if c < cost[m] {
				cost[m], came[m] = c, i
				pq.push(&todo, Todo{c + dist(center(g, m), gc) / unit, m})
			}
		}
	}
	return nil
}

// The first cell on path neither open nor soft, or NONE.
first_blocked :: proc(g: Grid, path: []int) -> int {
	fmt.assertf(path != nil, "route through blocked cells found no way")
	for i in path do if !(open_cell(g, i) || soft(g, i)) do return i
	return NONE
}

// Whether a body of radius BODY walking the straight segment a -> b stays on
// open cells: the segment and its two sides, sampled every LOS_STEP.
clear :: proc(g: Grid, a, b: Point) -> bool {
	d := dist(a, b)
	if d == 0 do return open_cell(g, cell_at(g, a))
	nx, ny := (a.y - b.y) / d * BODY, (b.x - a.x) / d * BODY
	n := max(1, int(d / LOS_STEP))
	for k in 0 ..= n {
		t := f64(k) / f64(n)
		x, y := a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t
		for s in ([3]f64{0, 1, -1}) {
			if !open_cell(g, cell_at(g, {x + s * nx, y + s * ny})) do return false
		}
	}
	return true
}

// World points along path with every corner a straight segment can cut
// removed (string pulling); the first and last cells' centres included.
waypoints :: proc(g: Grid, path: []int) -> []Point {
	pts := make([]Point, len(path))
	for i, k in path do pts[k] = center(g, i)
	if len(pts) <= 2 do return pts
	out: [dynamic]Point
	append(&out, pts[0])
	k := 0
	for _ in 0 ..< len(pts) { // k grows by at least one per pass
		if k == len(pts) - 1 do return out[:]
		far := k + 1
		for m := len(pts) - 1; m > k + 1; m -= 1 {
			if clear(g, pts[k], pts[m]) {
				far = m
				break
			}
		}
		append(&out, pts[far])
		k = far
	}
	panic("string pulling did not reach the last point")
}
