// r_00604fa0's relaxation loop (0x6052e0 to 0x60554b) as a native span: the
// remaining passes over two distance-constraint lists on the particle
// positions. WHY: docs/recompiler.md §8
package native

import "../x86"

ROPE_HALF :: 0x0070c078 // f32 0.5
ROPE_PARTICLES_MAX :: 256
ROPE_LINKS_MAX :: 1024 // per list
ROPE_PASSES_MAX :: 64
// Compared at the exit: ebx esp edi. The return stores no eax, ecx or edx, and
// the epilogue pops esi and ebp.
ROPE_LIVE :: 0x98

// Entered with esp at the frame base s, ebx the rope's definition and edi the
// rope. The particles are 12-byte f32 positions at [edi + 0x80]; the lists are
// 12-byte links (i0, i1, length L): u32[ebx + 0x14c] at [ebx + 0x148] (pins,
// moving i1 only) and u32[ebx + 0x134] at [ebx + 0x130] (moving both). A pass,
// with d = p[i0] - p[i1] for a pin and p[i1] - p[i0] for a link and
// k = L^2 / (((dz dz + dy dy) + dx dx) + L^2) - 0.5: each pin p[i1] -= 2 d k,
// then each link p[i0] -= d k, p[i1] += d k, in list order. Passes run while
// the counter i32[s + 0x18], incremented after each, is below f32[s + 0x20];
// the first runs regardless (the guest tested it before the loop). Leaves the
// last compare's status bits and the tags the guest empties. Writes no frame
// slot: the frame is dead at the exit. The f32 rule (native.odin) relaxes a
// copy, committed only when it holds; otherwise, or when the lists reach past
// ROPE_PARTICLES_MAX, overlap what the loop reads or need more than
// ROPE_PASSES_MAX passes, rope_exact replays the recompiled body in guest
// memory order.
Rope_Relax_006052e0_0060554b :: proc() -> bool #no_bounds_check {
	c := &x86.cpu
	s := c.esp
	pa := ld(c.edi + 0x80)
	if mode == .Check {
		n := min(rope_extent(c.ebx), ROPE_PARTICLES_MAX)
		return span_check(0x0060554b, Rope_Relax_006052e0_0060554b, {{pa, n * 3}}, ROPE_LIVE)
	}
	csr := csr_get()
	k := i32(ld(s + 0x18))
	n := rope_extent(c.ebx)
	if f32_state(csr) && n <= ROPE_PARTICLES_MAX && rope_apart(c.ebx, c.edi, s, pa, n) {
		limit := f64(lf(s + 0x20))
		passes := i32(1)
		for passes < ROPE_PASSES_MAX && f64(k + passes) < limit {
			passes += 1
		}
		if !(f64(k + passes) < limit) && rope_fast(c.ebx, pa, n, passes, csr) {
			c.fpu.sw = c.fpu.sw &~ (C0 | C2 | C3) | fcom_bits(f64(k + passes), limit)
			return true
		}
	}
	rope_exact(c.fpu.cw & x86.PC_MASK == 0, c.ebx, c.edi, s, k)
	return true
}

// The f32 rule's passes on a copy; false, with nothing written, when they left
// the normal f32 range.
@(private = "file")
rope_fast :: proc "contextless" (def, pa, n: u32, passes: i32, csr: u32) -> bool #no_bounds_check {
	p: [ROPE_PARTICLES_MAX][3]f32
	for i in u32(0) ..< n {p[i] = {lf(pa + i * 12), lf(pa + i * 12 + 4), lf(pa + i * 12 + 8)}}
	f32_begin(csr)
	rope_relax(&p, def, passes)
	if !f32_end(csr) {
		return false
	}
	bad := false
	for i in u32(0) ..< n {
		for e in p[i] {bad |= transmute(u32)e & F32_EXP == F32_EXP}
	}
	if bad {
		return false
	}
	for i in u32(0) ..< n {
		for e, j in p[i] {sf(pa + i * 12 + u32(j) * 4, e)}
	}
	return true
}

// The recompiled loop: every pass, each read and write in the guest's order
// on guest memory, the counter k compared after each pass with the limit as
// the guest reloads it. A pin pass empties the tags of st0 to st4, a link pass
// st0 to st2, the compare st0.
@(private = "file")
rope_exact :: #force_no_inline proc "contextless" (s: bool, def, rope, f: u32, k: i32) {
	c := &x86.cpu
	k := k
	empty := u8(0x80)
	for {
		for j := u32(0); i32(j) < i32(ld(def + 0x14c)); j += 1 {
			empty |= 0xf8
			e := ld(def + 0x148) + j * 12
			pa := ld(rope + 0x80)
			a, b := pa + ld(e) * 12, pa + ld(e + 4) * 12
			d: [3]f64
			for i in u32(0) ..< 3 {d[i] = xspill(round_pc(s, lx(a + i * 4) - lx(b + i * 4)))}
			dx2, dy2 := xdbl(s, d[0]), xdbl(s, d[1])
			dz2 := xspill(xdbl(s, d[2]))
			kk := xspill(rope_k_exact(s, d, lx(e + 8)))
			v := [3]f64{xspill(xmul(s, dx2, kk)), xspill(xmul(s, dy2, kk)), xspill(xmul(s, dz2, kk))}
			q := ld(rope + 0x80) + ld(e + 4) * 12
			for i in u32(0) ..< 3 {sx(q + i * 4, xsub(s, lx(q + i * 4), v[i]))}
		}
		for j := u32(0); i32(j) < i32(ld(def + 0x134)); j += 1 {
			empty |= 0xe0
			e := ld(def + 0x130) + j * 12
			pa := ld(rope + 0x80)
			a, b := pa + ld(e) * 12, pa + ld(e + 4) * 12
			d: [3]f64
			for i in u32(0) ..< 3 {d[i] = xspill(round_pc(s, lx(b + i * 4) - lx(a + i * 4)))}
			kk := rope_k_exact(s, d, lx(e + 8))
			r := [3]f64{xspill(xmul(s, d[0], kk)), xspill(xmul(s, d[1], kk)), xspill(xmul(s, d[2], kk))}
			q := ld(rope + 0x80) + ld(e) * 12
			for i in u32(0) ..< 3 {sx(q + i * 4, xsub(s, lx(q + i * 4), r[i]))}
			q = ld(rope + 0x80) + ld(e + 4) * 12
			for i in u32(0) ..< 3 {sx(q + i * 4, xadd(s, r[i], lx(q + i * 4)))}
		}
		k += 1
		cmp := fcom_bits(f64(k), lx(f + 0x20))
		if cmp != C0 {
			c.fpu.sw = c.fpu.sw &~ (C0 | C2 | C3) | cmp
			c.fpu.tag |= rot8(empty, c.fpu.top)
			return
		}
	}
}

// rope_k as the recompiled body rounds it.
@(private = "file")
rope_k_exact :: #force_inline proc "contextless" (s: bool, d: [3]f64, l: f64) -> f64 {
	ll := xmul(s, l, l)
	sum := xadd(s, xadd(s, xmul(s, d[2], d[2]), xmul(s, d[1], d[1])), xmul(s, d[0], d[0]))
	return xsub(s, round_pc(s, ll / xadd(s, sum, ll)), lx(ROPE_HALF))
}

// The particle count the links reach: one past the highest index, or
// ROPE_PARTICLES_MAX + 1 when a list is longer than ROPE_LINKS_MAX.
@(private = "file")
rope_extent :: proc "contextless" (def: u32) -> u32 {
	n := u32(0)
	for l in ([2]u32{0x148, 0x130}) {
		m := max(i32(ld(def + l + 4)), 0)
		if m > ROPE_LINKS_MAX {
			return ROPE_PARTICLES_MAX + 1
		}
		a := ld(def + l)
		for j in u32(0) ..< u32(m) {
			n = max(n, ld(a + j * 12) + 1, ld(a + j * 12 + 4) + 1)
		}
	}
	return min(n, ROPE_PARTICLES_MAX + 1)
}

// The positions overlap none of what the loop reads: the lists, their counts
// and pointers, the rope's particle pointer and the frame.
@(private = "file")
rope_apart :: proc "contextless" (def, rope, s, pa, n: u32) -> bool {
	lo, hi := u64(pa), u64(pa) + u64(n) * 12
	npin, nlink := u64(max(i32(ld(def + 0x14c)), 0)), u64(max(i32(ld(def + 0x134)), 0))
	spans := [5][2]u64 {
		{u64(def + 0x130), u64(def + 0x150)},
		{u64(rope + 0x80), u64(rope + 0x84)},
		{u64(s), u64(s) + 0x70},
		{u64(ld(def + 0x148)), u64(ld(def + 0x148)) + npin * 12},
		{u64(ld(def + 0x130)), u64(ld(def + 0x130)) + nlink * 12},
	}
	for r in spans {
		if lo < r[1] && r[0] < hi {return false}
	}
	return true
}

@(private = "file")
rope_k :: #force_inline proc "contextless" (d: [3]f32, l, half: f32) -> f32 {
	ll := l * l
	return ll / (((d[2] * d[2] + d[1] * d[1]) + d[0] * d[0]) + ll) - half
}

// Out of line so no floating-point operation moves across the MXCSR accesses
// around it. Products and sums in the guest's order.
@(private = "file")
rope_relax :: #force_no_inline proc "contextless" (p: ^[ROPE_PARTICLES_MAX][3]f32, def: u32, passes: i32) #no_bounds_check {
	half := lf(ROPE_HALF)
	pins, npin := ld(def + 0x148), i32(ld(def + 0x14c))
	links, nlink := ld(def + 0x130), i32(ld(def + 0x134))
	for _ in 0 ..< passes {
		for j in 0 ..< max(npin, 0) {
			e := pins + u32(j) * 12
			i0, i1 := ld(e), ld(e + 4)
			d := p[i0] - p[i1]
			k := rope_k(d, lf(e + 8), half)
			p[i1] -= (d + d) * k
		}
		for j in 0 ..< max(nlink, 0) {
			e := links + u32(j) * 12
			i0, i1 := ld(e), ld(e + 4)
			d := p[i1] - p[i0]
			k := rope_k(d, lf(e + 8), half)
			r := d * k
			p[i0] -= r
			p[i1] = r + p[i1]
		}
	}
}
