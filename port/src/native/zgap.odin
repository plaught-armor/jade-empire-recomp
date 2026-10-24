// Object_BoxZGap (0x5aa990): an object's box placed in another object's frame,
// and the gap between that box and the frame's z = 0 plane. Calls guest code
// only in its tail, after the f32 work. WHY: docs/recompiler.md §8
package native

import "../x86"

guest_box_zgap: x86.Func

ZGAP_NEG :: 0x006e190c // f32 -1, Quat_Conj (0x5c1070)'s factor on w
ZGAP_RET_GET :: 0x005aaccb // return addresses of the three tail calls
ZGAP_RET_GET2 :: 0x005aacda
ZGAP_RET_SET :: 0x005aace6

// __thiscall(this = ecx, other), ret 4; quaternions are (w x y z). With
// c = Quat_Conj(other.quat at +0x88) (w times -1), p = this.quat (+0x84) times
// c, m = Quat_ToMatrix3(p) and the box [+0x1d0, +0x1dc] put through
// Aabb_Transform3x3(m), the offset d = this.pos (+0x78) - other.pos (+0x7c) is
// rotated by c (copied when c.w is exactly +-1) into r, and the box moved by r.
// Its z range [lo, hi] gives [this + 0x18]: 0 when it holds 0 strictly inside,
// else min(|lo|, |hi|). eax keeps r.x's high half and the last fnstsw (hi
// against 0 on the 0 path, |lo| against |hi| with one register pushed on the
// other); ecx = [this + 0x20c], edx = r.z's bits. Then, with [this + 0x20c]
// non-null, the guest's tail: a = its vcall +0x14; when a is non-null, the
// same vcall again and b = [result + 0x14], b's vcall +0x268(other), each with
// the registers and return address the guest gives it. The stack scratch lies
// below the caller's esp; p and m are written to the guest's slots for them,
// which the two helpers read; the argument slot ends as the guest leaves it.
// box_zgap runs under the f32 rule (native.odin) with finite inputs, else,
// or when the rule fails, as the recompiled body's operations, so any
// precision control, register state and value give its bits. Under JE_NATIVE=check
// the tail calls run twice, once for each body.
Object_BoxZGap_005aa990 :: proc() {
	c := &x86.cpu
	e := c.esp
	this, o := c.ecx, ld(e + 4)
	lent := coop_cam_lend(o)
	defer if lent {coop_cam_unlend()}
	if mode != .On {
		if mode == .Check {
			check(0x005aa990, Object_BoxZGap_005aa990, guest_box_zgap, {{this + 0x18, 1}, {e + 4, 1}})
			return
		}
		guest_box_zgap()
		return
	}
	s := e - 0x74 // esp after the prologue's pushes
	csr := csr_get()
	r: Zgap_Out
	ok := false
	if f32_state(csr) && finite(this + 0x78, 7) && finite(this + 0x1d0, 6) && finite(o + 0x7c, 7) {
		f32_begin(csr)
		r = box_zgap(true, this, o, s, f32)
		ok = f32_end(csr)
	}
	if !ok {
		r = box_zgap(c.fpu.cw & x86.PC_MASK == 0, this, o, s, f64)
	}
	f := &c.fpu
	t := f.top
	f.sw = f.sw &~ (C0 | C2 | C3) | r.cmp
	f.tag |= rot8(0xff, t) // Quat_ToMatrix3 empties all eight
	f.top = r.straddle ? t : (t + 7) & 7
	c.eax = transmute(u32)r.rx & 0xffff0000 | u32(fstsw())
	f.top = t
	sf(this + 0x18, r.gap)
	c.edx = transmute(u32)r.rz
	ebx, esi, edi := c.ebx, c.esi, c.edi
	c.ecx = ld(this + 0x20c)
	if c.ecx != 0 {
		c.ebx, c.esi, c.edi = o + 0x88, this, o
		c.edx = ld(c.ecx)
		st(s - 4, ZGAP_RET_GET)
		c.esp = s - 4
		call_guest(ld(c.edx + 0x14))
		if c.eax != 0 {
			c.ecx = ld(this + 0x20c)
			c.eax = ld(c.ecx)
			st(s - 4, ZGAP_RET_GET2)
			c.esp = s - 4
			call_guest(ld(c.eax + 0x14))
			c.ecx = ld(c.eax + 0x14)
			c.edx = ld(c.ecx)
			st(s - 4, o)
			st(s - 8, ZGAP_RET_SET)
			c.esp = s - 8
			call_guest(ld(c.edx + 0x268))
		}
	}
	c.ebx, c.esi, c.edi = ebx, esi, edi
	c.esp = e + 8
}

@(private = "file")
Zgap_Out :: struct {
	gap, rx, rz: f32,
	cmp:         u16, // the last compare's status bits
	straddle:    bool, // the box's z range holds 0 strictly inside
}

// The guest's body in its order, as the f32 rule's f32 operations or the
// recompiled body's f64 ones under precision control s, with the frame slots
// the helpers read: c = Quat_Conj(other.quat) at s + 0x18, p at s + 0x40, m
// at s + 0x50, the box at s + 0x28 (lo) and s + 0x34 (hi). The rotation's z y
// product goes through the argument slot, as later |hi| does. The frame lies
// below the caller's esp, so it overlaps no input and the f64 rerun after a
// failed f32 rule reads what the guest reads; the gap, the one store above
// it, is the caller's to make.
@(private = "file")
box_zgap :: #force_no_inline proc "contextless" (s: bool, this, o, f: u32, $T: typeid) -> (out: Zgap_Out) #no_bounds_check {
	conj :: #force_inline proc "contextless" (s: bool, o: u32, $T: typeid) -> [4]T {
		return {xspill(xmul(s, xl(o + 0x88, T), xl(ZGAP_NEG, T))), xl(o + 0x8c, T), xl(o + 0x90, T), xl(o + 0x94, T)}
	}
	cq := conj(s, o, T)
	cw, cx, cy, cz := cq[0], cq[1], cq[2], cq[3]
	q0, q1, q2, q3 := xl(this + 0x84, T), xl(this + 0x88, T), xl(this + 0x8c, T), xl(this + 0x90, T)
	sf(f + 0x40, f32(xsub(s, xsub(s, xsub(s, xmul(s, q0, cw), xmul(s, cx, q1)), xmul(s, cy, q2)), xmul(s, cz, q3))))
	sf(f + 0x44, f32(xsub(s, xadd(s, xadd(s, xmul(s, cy, q3), xmul(s, cx, q0)), xmul(s, q1, cw)), xmul(s, cz, q2))))
	sf(f + 0x48, f32(xadd(s, xadd(s, xsub(s, xmul(s, q2, cw), xmul(s, cx, q3)), xmul(s, cz, q1)), xmul(s, cy, q0))))
	sf(f + 0x4c, f32(xadd(s, xsub(s, xadd(s, xmul(s, cx, q2), xmul(s, q3, cw)), xmul(s, cy, q1)), xmul(s, cz, q0))))
	quat_matrix(s, f + 0x40, f + 0x50, T)
	aabb_transform(s, f + 0x50, this + 0x1d0, this + 0x1dc, f + 0x28, f + 0x34, T)
	d: [3]T
	for i in u32(0) ..< 3 {d[i] = xspill(xsub(s, xl(this + 0x78 + i * 4, T), xl(o + 0x7c + i * 4, T)))}
	r := [3]f32{f32(d[0]), f32(d[1]), f32(d[2])}
	c2 := conj(s, o, T)
	if w := transmute(u32)f32(c2[0]); w != 0x3f800000 && w != 0xbf800000 {
		v, tmp := skin_rot(s, c2, d, true)
		sf(f + 0x78, tmp.t6c)
		r = {f32(v[0]), f32(v[1]), f32(v[2])}
	}
	lo := xadd(s, T(r[2]), xl(f + 0x30, T))
	hi := xadd(s, T(r[2]), xl(f + 0x3c, T))
	lo, hi = xspill(lo), xspill(hi)
	zero := xl(PLANE_ZERO, T)
	out.rx, out.rz = r[0], r[2]
	out.straddle = lo < zero && hi > zero || lo > zero && hi < zero
	if out.straddle {
		out.cmp = fcom_bits(hi, zero)
		return
	}
	alo, ahi := abs(lo), abs(hi)
	sf(f + 0x78, f32(ahi))
	out.cmp = fcom_bits(alo, ahi)
	out.gap = f32(out.cmp == C0 ? alo : ahi)
	return
}
