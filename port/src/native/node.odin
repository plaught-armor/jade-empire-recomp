// Node_GetWorldPosOri (0x59e170), the hottest guest function: a node's world
// position and orientation, composed up its parent chain and then through its
// owner. WHY: docs/recompiler.md §8
package native

import "base:runtime"
import "../x86"

guest_node_world: x86.Func

// Parent links followed before the chain is taken to be a cycle.
NODE_CHAIN_MAX :: 1 << 16

// The two quaternion w values (±1) whose rotation the guest skips.
W_SKIP_A :: 0x006e1910
W_SKIP_B :: 0x006e190c

// x87 status bits fcom sets.
C0 :: x86.C0
C2 :: x86.C2
C3 :: x86.C3

// __thiscall(node = ecx, pos: ^[3]f32, ori: ^[4]f32 (w x y z)), ret 8.
// Follows the f32 rule (native.odin) where it holds; elsewhere every
// operation is the recompiled body's (node_world under f64), so any precision
// control, register state and value give its bits. The guest's stack
// temporaries below esp are not written; its two argument slots end holding
// the owner's rotation x and y, as the guest leaves them. pos and ori must
// not alias the node data, which the exact path rereads after the f32 one.
// WHY: docs/recompiler.md §8
Node_GetWorldPosOri_0059e170 :: proc() {
	c := &x86.cpu
	e := c.esp
	if mode != .On {
		if mode == .Check {
			check(0x0059e170, Node_GetWorldPosOri_0059e170, guest_node_world,
				{{ld(e + 4), 3}, {ld(e + 8), 4}, {e + 4, 2}})
			return
		}
		guest_node_world()
		return
	}
	node := c.ecx
	pos := ld(e + 4)
	ori := ld(e + 8)
	owner := ld(node + 0x38)
	if owner == 0 {
		for i in u32(0) ..< 3 {st(pos + i * 4, ld(node + 0x8 + i * 4))}
		for i in u32(0) ..< 4 {st(ori + i * 4, ld(node + 0x14 + i * 4))}
		c.eax = ld(node + 0x20)
		c.ecx = node + 0x14
		c.edx = ld(node + 0x1c)
		c.esp += 12
		return
	}
	csr := csr_get()
	sw: u16
	ok := false
	if f32_state(csr) {
		f32_begin(csr)
		sw = node_world(true, node, owner, pos, ori, c.fpu.sw, f32)
		ok = f32_end(csr) && finite(pos, 3) && finite(ori, 4)
	}
	if !ok {
		sw = node_world(c.fpu.cw & x86.PC_MASK == 0, node, owner, pos, ori, c.fpu.sw, f64)
	}
	// The last fnstsw, taken with one register pushed, into eax's low half.
	// Seven registers below top held the products; they end empty.
	top1 := (c.fpu.top - 1) & 7
	c.fpu.sw = sw
	c.fpu.tag |= rot8(0xfe, c.fpu.top)
	c.eax = ld(owner + 0x80) & 0xffff0000 | u32(sw & ~u16(0x3800) | u16(top1 << 11))
	c.ecx = ld(owner + 0x7c)
	c.edx = pos
	st(e + 4, ld(owner + 0x88))
	st(e + 8, ld(owner + 0x8c))
	c.esp += 12
}

// The chain in the guest's order, as the f32 rule's f32 operations (out of
// line so none moves across the MXCSR accesses around it) or the recompiled
// body's f64 ones under precision control s. Returns the status word after
// the last compare.
@(private = "file")
node_world :: #force_no_inline proc "contextless" (s: bool, node, owner, pos, ori: u32, sw_in: u16, $T: typeid) -> u16 {
	st(pos, 0); st(pos + 4, 0); st(pos + 8, 0)
	st(ori, 0x3f800000); st(ori + 4, 0); st(ori + 8, 0); st(ori + 12, 0)
	sw := sw_in
	n := node
	for _ in 0 ..< NODE_CHAIN_MAX {
		if ld(ld(n + 0x4)) & 0x1001 != 0x1001 {
			sw = node_step(s, n + 0x14, n + 0x24, n + 0x8, pos, ori, sw, T)
		}
		n = ld(n + 0x34)
		if n == 0 {break}
	}
	if n != 0 {
		chain_fatal(node)
	}
	return node_step(s, owner + 0x84, owner + 0x238, owner + 0x78, pos, ori, sw, T)
}

@(private = "file")
chain_fatal :: proc "contextless" (node: u32) -> ! {
	context = runtime.default_context()
	x86.fatal("node %08x: parent chain longer than %d", node, NODE_CHAIN_MAX)
}

// One link: pos = q (pos * scale) q* + p, ori = q ori. q is w x y z at qa,
// the scale at sa, p at pa. Operations in the guest's order, the scaled
// position and four products through their f32 stack temporaries. Returns
// the status word after the w compares.
@(private = "file")
node_step :: #force_inline proc "contextless" (s: bool, qa, sa, pa, pos, ori: u32, sw_in: u16, $T: typeid) -> u16 {
	w, X, Y, Z := xl(qa, T), xl(qa + 4, T), xl(qa + 8, T), xl(qa + 12, T)
	sc := xl(sa, T)
	px, py, pz := xl(pa, T), xl(pa + 4, T), xl(pa + 8, T)
	sx := xspill(xmul(s, sc, xl(pos, T)))
	sy := xspill(xmul(s, sc, xl(pos + 4, T)))
	sz := xspill(xmul(s, sc, xl(pos + 8, T)))
	sw := sw_in &~ (C0 | C2 | C3) | fcom_bits(w, xl(W_SKIP_A, T))
	if sw & (C2 | C3) != C3 {
		sw = sw &~ (C0 | C2 | C3) | fcom_bits(w, xl(W_SKIP_B, T))
	}
	if sw & (C2 | C3) == C3 {
		sf(pos, f32(xadd(s, px, sx)))
		sf(pos + 4, f32(xadd(s, py, sy)))
		sf(pos + 8, f32(xadd(s, pz, sz)))
	} else {
		a := xmul(s, Z, X)
		b := xmul(s, Y, w)
		cc := xmul(s, Z, Z)
		m24 := xspill(xmul(s, Y, Y))
		e := xmul(s, Y, X)
		f := xmul(s, Z, w)
		g := xsub(s, xmul(s, xadd(s, b, a), sz), xmul(s, xadd(s, m24, cc), sx))
		j := xadd(s, g, xmul(s, xsub(s, e, f), sy))
		sf(pos, f32(xadd(s, xadd(s, xdbl(s, j), px), sx)))
		m20 := xspill(xmul(s, X, X))
		m1c := xspill(xmul(s, Z, Y))
		m18 := xspill(xmul(s, X, w))
		k := xsub(s, xmul(s, xadd(s, f, e), sx), xmul(s, xadd(s, m20, cc), sy))
		k = xadd(s, k, xmul(s, xsub(s, m1c, m18), sz))
		sf(pos + 4, f32(xadd(s, xadd(s, xdbl(s, k), py), sy)))
		q := xadd(s, xmul(s, xadd(s, m18, m1c), sy), xmul(s, xsub(s, a, b), sx))
		q = xsub(s, q, xmul(s, xadd(s, m20, m24), sz))
		sf(pos + 8, f32(xadd(s, xadd(s, xdbl(s, q), pz), sz)))
	}
	o0, o1, o2, o3 := xl(ori, T), xl(ori + 4, T), xl(ori + 8, T), xl(ori + 12, T)
	sf(ori, f32(xsub(s, xsub(s, xsub(s, xmul(s, o0, w), xmul(s, o1, X)), xmul(s, o2, Y)), xmul(s, o3, Z))))
	sf(ori + 4, f32(xsub(s, xadd(s, xadd(s, xmul(s, Y, o3), xmul(s, o0, X)), xmul(s, o1, w)), xmul(s, o2, Z))))
	sf(ori + 8, f32(xadd(s, xadd(s, xsub(s, xmul(s, o2, w), xmul(s, o3, X)), xmul(s, o1, Z)), xmul(s, o0, Y))))
	sf(ori + 12, f32(xadd(s, xsub(s, xadd(s, xmul(s, o2, X), xmul(s, o3, w)), xmul(s, o1, Y)), xmul(s, o0, Z))))
	return sw
}

// fcom/fucom: C3 C2 C0 = 000 greater, 001 less, 100 equal, 111 unordered.
@(private)
fcom_bits :: #force_inline proc "contextless" (a, b: $T) -> u16 {
	if a > b {return 0}
	if a < b {return C0}
	if a == b {return C3}
	return C0 | C2 | C3
}
