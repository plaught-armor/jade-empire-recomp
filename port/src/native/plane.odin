// Plane_BoxMaxDist (0x5c0480): the signed distance from a plane of the box
// corner farthest along its normal. WHY: docs/recompiler.md §8
package native

import "../x86"

guest_plane_box_dist: x86.Func

// The value each normal component is compared against (0.0).
PLANE_ZERO :: 0x006e1848

// cdecl(hi: ^[3]f32, lo: ^[3]f32, plane: ^[4]f32 (n, d)) -> st(0). Per axis,
// the corner takes hi's component when n is above 0.0, else lo's; the result
// is ((p.y n.y + p.z n.z) + p.x n.x) + d, pushed. ecx = plane, edx = lo, and
// eax keeps the third fnstsw (the z compare, its pop done). The two registers
// the products used end empty. Every operation is the recompiled body's: f64,
// rounded under single precision control as round_pc rounds, in its operand
// order, so any precision control and value give its bits.
Plane_BoxMaxDist_005c0480 :: proc() #no_bounds_check {
	c := &x86.cpu
	e := c.esp
	if mode != .On {
		if mode == .Check {
			check(0x005c0480, Plane_BoxMaxDist_005c0480, guest_plane_box_dist, {})
			return
		}
		guest_plane_box_dist()
		return
	}
	hi, lo, pl := ld(e + 0x4), ld(e + 0x8), ld(e + 0xc)
	f := &c.fpu
	s := f.cw & x86.PC_MASK == 0
	t := f.top
	p: [3]f64
	cmp: u16
	for i in u32(0) ..< 3 {
		cmp = fcom_bits(lx(pl + i * 4), lx(PLANE_ZERO))
		p[i] = lx((cmp & (C0 | C3) == 0 ? hi : lo) + i * 4)
	}
	a := round_pc(s, p[1] * lx(pl + 4))
	a = round_pc(s, a + round_pc(s, p[2] * lx(pl + 8)))
	a = round_pc(s, a + round_pc(s, p[0] * lx(pl)))
	f.sw = f.sw &~ (C0 | C2 | C3) | cmp
	f.top = (t + 6) & 7
	c.eax = c.eax & 0xffff0000 | u32(fstsw())
	set_st_phys(t + 7, round_pc(s, a + lx(pl + 12)))
	f.tag = f.tag &~ rot8(0x80, t) | rot8(0x60, t)
	f.top = (t + 7) & 7
	c.ecx, c.edx = pl, lo
	c.esp = e + 4
}
