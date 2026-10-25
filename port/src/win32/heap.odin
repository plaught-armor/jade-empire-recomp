// Guest heap: power-of-two size classes over a bump region, 16-byte header
// before each block (u32 requested size, u32 class). All Win32 heaps share it.
package win32

import "../x86"

HEAP_LO :: 0x10000000
HEAP_HI :: 0x80000000
HDR :: 16
MIN_CLASS :: 4 // 16 bytes
MAX_CLASS :: 30

heap_top: u32 = HEAP_LO
free_lists: [MAX_CLASS + 1][dynamic]u32

// Play's own part of the heap, from heap_play (lockstep.odin) on: blocks
// come from HEAP_PLAY up, and blocks below it that are freed stay unused,
// so where play's blocks lie follows from play alone, not from what each
// peer's menus allocated before. The game orders some of its work by
// address. WHY: docs/hle.md §11
HEAP_PLAY :: 0x40000000
heap_floor: u32 = HEAP_LO

// Render's own part of the heap in play: blocks allocated while heap_render
// is set (native code sets it around the texture cache, which each peer's
// menus left unlike) come from HEAP_RENDER up, so they move no play block.
HEAP_RENDER :: 0x70000000
heap_render := 0
render_top: u32 = HEAP_RENDER
render_free: [MAX_CLASS + 1][dynamic]u32

heap_play :: proc() {
	if heap_top > HEAP_PLAY {x86.fatal("heap: %08x in use before play, past %08x", heap_top, HEAP_PLAY)}
	heap_top, heap_floor = HEAP_PLAY, HEAP_PLAY
	for &l in free_lists {clear(&l)}
}

size_class :: proc(n: u32) -> u32 {
	k: u32 = MIN_CLASS
	for k < MAX_CLASS && (u32(1) << k) < n + HDR {
		k += 1
	}
	return k
}

// Guest pointer to n bytes (zeroed when zero is set), or 0 when out of space.
heap_alloc :: proc(n: u32, zero: bool) -> u32 {
	if n > (1 << MAX_CLASS) - HDR {
		return 0
	}
	k := size_class(n)
	lists, top, hi := &free_lists, &heap_top, u32(HEAP_HI)
	if heap_floor == HEAP_PLAY {
		hi = HEAP_RENDER
		if heap_render > 0 {lists, top, hi = &render_free, &render_top, HEAP_HI}
	}
	blk: u32
	if len(lists[k]) > 0 {
		blk = pop(&lists[k])
	} else {
		sz := u32(1) << k
		if top^ + sz > hi || top^ + sz < top^ {
			return 0
		}
		blk = top^
		top^ += sz
	}
	x86.wr32(blk, n)
	x86.wr32(blk + 4, k)
	x86.wr32(blk + 8, 0x48454150) // "HEAP" marker, checked on free
	p := blk + HDR
	if zero {
		x86.mem_zero(p, n)
	}
	return p
}

heap_check :: proc(p: u32) -> u32 {
	blk := p - HDR
	in_render := p >= HEAP_RENDER + HDR && p < render_top
	if p < HEAP_LO + HDR || (p >= heap_top && !in_render) || x86.rd32(blk + 8) != 0x48454150 {
		x86.fatal("heap: bad pointer %08x", p)
	}
	return blk
}

heap_free :: proc(p: u32) {
	if p == 0 {
		return
	}
	blk := heap_check(p)
	x86.wr32(blk + 8, 0x45455246) // "FREE"
	if blk < heap_floor {return}
	append(blk >= HEAP_RENDER && heap_floor == HEAP_PLAY ? &render_free[x86.rd32(blk + 4)] : &free_lists[x86.rd32(blk + 4)], blk)
}

heap_size :: proc(p: u32) -> u32 {
	return x86.rd32(heap_check(p))
}

heap_realloc :: proc(p: u32, n: u32, zero: bool) -> u32 {
	if p == 0 {
		return heap_alloc(n, zero)
	}
	blk := heap_check(p)
	old := x86.rd32(blk)
	if n + HDR <= u32(1) << x86.rd32(blk + 4) {
		if zero && n > old {
			x86.mem_zero(p + old, n - old)
		}
		x86.wr32(blk, n)
		return p
	}
	// A grown block stays in its part of the heap.
	render := heap_render
	heap_render = blk >= HEAP_RENDER && heap_floor == HEAP_PLAY ? 1 : 0
	q := heap_alloc(n, zero)
	heap_render = render
	if q == 0 {
		return 0
	}
	copy(x86.mem[q:q + old], x86.mem[p:p + old])
	heap_free(p)
	return q
}

// Guest copy of a host string, NUL-terminated.
heap_str :: proc(s: string) -> u32 {
	p := heap_alloc(u32(len(s)) + 1, false)
	copy(x86.mem[p:p + u32(len(s))], s)
	x86.wr8(p + u32(len(s)), 0)
	return p
}
