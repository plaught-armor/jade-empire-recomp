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
	blk: u32
	if len(free_lists[k]) > 0 {
		blk = pop(&free_lists[k])
	} else {
		sz := u32(1) << k
		if heap_top + sz > HEAP_HI || heap_top + sz < heap_top {
			return 0
		}
		blk = heap_top
		heap_top += sz
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
	if p < HEAP_LO + HDR || p >= heap_top || x86.rd32(blk + 8) != 0x48454150 {
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
	append(&free_lists[x86.rd32(blk + 4)], blk)
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
	q := heap_alloc(n, zero)
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
