// Aabb_Outcode (0x5c1e70): the Cohen-Sutherland outcode of a point against a
// box. Compares only, so the f32 rule does not apply: an f32 compare and the
// guest's compare of the same values widened to f64 agree. WHY: docs/recompiler.md §8
package native

import "../x86"

guest_aabb_outcode: x86.Func

// cdecl(p: ^[3]f32, min: ^[3]f32, max: ^[3]f32, out: ^u8). Per axis x y z,
// p < min sets 0x20 0x08 0x02, else p > max sets 0x10 0x04 0x01; unordered
// sets neither. eax keeps the last fnstsw, its low byte replaced by the
// outcode when the z < min branch ran. The register fld pushed is left as the
// guest leaves it: empty, holding p.z.
Aabb_Outcode_005c1e70 :: proc() {
	c := &x86.cpu
	if mode == .Check {
		check(0x005c1e70, aabb_native, guest_aabb_outcode, {{ld(c.esp + 0x10), 1}})
		return
	}
	if mode == .Off {
		guest_aabb_outcode()
		return
	}
	aabb_native()
}

// Bits for p < min and p > max, per axis.
@(private)
OUTCODE_BITS := [3][2]u8{{0x20, 0x10}, {0x08, 0x04}, {0x02, 0x01}}

@(private = "file")
aabb_native :: proc() #no_bounds_check {
	c := &x86.cpu
	p := ld(c.esp + 0x4)
	lo := ld(c.esp + 0x8)
	hi := ld(c.esp + 0xc)
	out := ld(c.esp + 0x10)
	code, cmp, below := outcode(p, lo, hi)
	st8(out, code)
	sw := c.fpu.sw &~ (C0 | C2 | C3) | cmp
	c.fpu.sw = sw
	set_st_phys(c.fpu.top + 7, f64(lf(p + 8)))
	c.fpu.tag |= rot8(0x80, c.fpu.top)
	fsw := u32(sw & ~u16(0x3800) | u16(c.fpu.top << 11))
	al := below ? u32(code) : fsw & 0xff
	c.eax = c.eax & 0xffff0000 | fsw & 0xff00 | al
	c.ecx = p
	c.edx = out
	c.esp += 4
}

// The outcode of point p against box lo-hi, the status bits of the last
// compare, and whether that compare was the z < min one and held.
@(private)
outcode :: #force_inline proc "contextless" (p, lo, hi: u32) -> (code: u8, cmp: u16, below: bool) #no_bounds_check {
	for axis in u32(0) ..< 3 {
		v := lf(p + axis * 4)
		cmp = fcom_bits(v, lf(lo + axis * 4))
		below = cmp == C0
		if below {
			code |= OUTCODE_BITS[axis][0]
		} else {
			cmp = fcom_bits(v, lf(hi + axis * 4))
			if cmp == 0 {code |= OUTCODE_BITS[axis][1]}
		}
	}
	return
}

// Aabb_Transform3x3 (0x5c3eb0): the box lo-hi under a 3x3 matrix, as a new
// min and max corner. WHY: docs/recompiler.md §8
guest_aabb_transform: x86.Func

// cdecl(m: ^[9]f32, lo: ^[3]f32, hi: ^[3]f32, out_lo: ^[3]f32, out_hi: ^[3]f32).
// out[r] sums over k the terms m[r + 3k] p[k]: out_hi takes hi's component
// where m[r + 3k] is not below 0.0 (the PLANE_ZERO compare) and lo's
// otherwise, out_lo the reverse. Each sum is (t0 + t1) + t2, except out_hi.x,
// (t1 + t2) + t0. The last compare (m[8]) leaves its status bits and eax =
// 12 when it was not below 0.0, else 0; ecx and edx writes are dead. The two
// registers the sums used end empty and are not written (cpu_matches), nor is
// the frame below esp. With finite inputs apart from the outputs the f32
// rule (native.odin) runs first; else, or when it fails, every operation is
// the recompiled body's (aabb_transform), so any precision control, overlap
// and value give its bits.
Aabb_Transform3x3_005c3eb0 :: proc() {
	c := &x86.cpu
	e := c.esp
	olo, ohi := ld(e + 0x10), ld(e + 0x14)
	if mode != .On {
		if mode == .Check {
			check(0x005c3eb0, Aabb_Transform3x3_005c3eb0, guest_aabb_transform, {{olo, 3}, {ohi, 3}})
			return
		}
		guest_aabb_transform()
		return
	}
	m, lo, hi := ld(e + 0x4), ld(e + 0x8), ld(e + 0xc)
	csr := csr_get()
	cmp: u16
	ok := false
	if f32_state(csr) && finite(m, 9) && finite(lo, 3) && finite(hi, 3) &&
	   apart(m, 36, olo, 12) && apart(m, 36, ohi, 12) && apart(lo, 12, olo, 12) &&
	   apart(lo, 12, ohi, 12) && apart(hi, 12, olo, 12) && apart(hi, 12, ohi, 12) {
		f32_begin(csr)
		cmp = aabb_transform(true, m, lo, hi, olo, ohi, f32)
		ok = f32_end(csr)
	}
	if !ok {
		cmp = aabb_transform(c.fpu.cw & x86.PC_MASK == 0, m, lo, hi, olo, ohi, f64)
	}
	c.fpu.sw = c.fpu.sw &~ (C0 | C2 | C3) | cmp
	c.fpu.tag |= rot8(0xc0, c.fpu.top)
	c.eax = cmp & C0 == 0 ? 12 : 0
	c.esp = e + 4
}

// The guest's transform in its order, as the f32 rule's f32 operations or
// the recompiled body's f64 ones under precision control s: lo and hi copied
// first, then per row the three compares, out_hi, and out_lo, each reading m
// where the guest does, so an output overlapping m or an input gives its
// bits. Returns the status bits of the last compare.
@(private)
aabb_transform :: #force_no_inline proc "contextless" (s: bool, m, lo, hi, olo, ohi: u32, $T: typeid) -> (cmp: u16) #no_bounds_check {
	p := [2][3]T{{xl(lo, T), xl(lo + 4, T), xl(lo + 8, T)}, {xl(hi, T), xl(hi + 4, T), xl(hi + 8, T)}}
	zero := xl(PLANE_ZERO, T)
	for r in u32(0) ..< 3 {
		up: [3]int
		for k in u32(0) ..< 3 {
			cmp = fcom_bits(xl(m + (r + 3 * k) * 4, T), zero)
			up[k] = cmp & C0 == 0 ? 1 : 0
		}
		th: [3]T
		for k in u32(0) ..< 3 {th[k] = xmul(s, p[up[k]][k], xl(m + (r + 3 * k) * 4, T))}
		h := r == 0 ? xadd(s, xadd(s, th[1], th[2]), th[0]) : xadd(s, xadd(s, th[0], th[1]), th[2])
		sf(ohi + r * 4, f32(h))
		tl: [3]T
		for k in u32(0) ..< 3 {tl[k] = xmul(s, p[1 - up[k]][k], xl(m + (r + 3 * k) * 4, T))}
		sf(olo + r * 4, f32(xadd(s, xadd(s, tl[0], tl[1]), tl[2])))
	}
	return
}
