// Skeleton_GatherWorldPose (0x629dc0) as a native span from its entry to its
// epilogue (0x62ab50): a bone tree's world positions and rotations, appended
// to two arrays in depth-first order. WHY: docs/recompiler.md §8
package native

import "../x86"

POSE_NODES_MAX :: 128
POSE_DEPTH_MAX :: 64
POSE_CHILDREN_MAX :: 64 // per node
POSE_FRAME :: 0x150 // stack bytes per guest call: frame, saved registers, arguments
POSE_HELPER :: 0x20 // stack bytes below a frame its helper calls use
// The exact path's depth. The guest's whole stack (win32 STACK_LO to
// STACK_HI), POSE_FRAME per six levels, ends before it, so a tree this deep
// is one only the recompiled body can replay: it runs off the stack.
POSE_PATH_MAX :: 1 << 19
POSE_CHECK_MAX :: (SPAN_OUT_MAX - 2) / 7 // elements compared in each array
POSE_POS_RESERVE :: 0x0059a1d0 // thiscall(ecx array, capacity), ret 4
POSE_ROT_RESERVE :: 0x005a2000
// The reserve calls' return addresses: the root's inline pushes, then the
// push helpers (0x59ad30, 0x608240) the deeper levels call.
POSE_RET_POS :: 0x00629f10
POSE_RET_ROT :: 0x00629fde
POSE_RET_POS_PUSH :: 0x0059ad50
POSE_RET_ROT_PUSH :: 0x00608260
// Compared at the exit: esp. The epilogue pops ebx, ebp, esi and edi, and the
// callers read no eax, ecx or edx.
POSE_LIVE :: 0x10

// cdecl(node, positions, rotations, parent position, parent rotation). The
// arrays are {data, count, capacity} with 12-byte f32 positions and 16-byte
// (w x y z) rotations, and the guest indexes both by the positions' count. A
// node is the position v at +8, the rotation r at +0x14 and u32[+0x30]
// children at [+0x2c]. Each node in turn, its parent's position p and rotation
// q (the arguments for the root): p + rotate(q, v) (v when q's w is exactly
// +-1) and q composed with r, pushed, then its children. A push at count ==
// capacity first reserves twice the capacity (8 from 0) through operator new.
// The guest unrolls five levels of the walk and calls itself below them, so
// the sums of q composed with r associate by depth mod 6 (pose_comp), and at
// a call's root rotate's z reaches the sum unnarrowed. Under the f32 rule
// (native.odin), with no growth, no overlap and the tree in bounds, the f32
// path computes the whole tree before it writes; otherwise the exact path
// replays the guest node by node (pose_exact). Writes only the pushed
// elements, the arrays' headers and the saved registers the epilogue pops:
// the rest of the frame is dead at the return.
Skeleton_GatherWorldPose_00629dc0_0062ab50 :: proc() -> bool #no_bounds_check {
	c := &x86.cpu
	e := c.esp
	poses, rots := ld(e + 8), ld(e + 0xc)
	if mode == .Check {
		n, ok := pose_count(ld(e + 4))
		if !ok {
			return false
		}
		// Grown first, so neither run grows: each would free the storage the
		// other then reads.
		pose_grow(e - 0x138, poses, n, POSE_POS_RESERVE, POSE_RET_POS)
		pose_grow(e - 0x138, rots, n, POSE_ROT_RESERVE, POSE_RET_ROT)
		n = min(n, POSE_CHECK_MAX)
		return span_check(0x0062ab50, Skeleton_GatherWorldPose_00629dc0_0062ab50,
			{{ld(poses) + ld(poses + 4) * 12, n * 3}, {ld(rots) + ld(rots + 4) * 16, n * 4}, {poses + 4, 1}, {rots + 4, 1}}, POSE_LIVE)
	}
	csr := csr_get()
	w: Pose_Walk = ---
	if !pose_walk(&w, e) || !f32_state(csr) {
		return pose_exact(e)
	}
	out: Pose_Out = ---
	f32_begin(csr)
	rotated := pose_compute(&w, &out, ld(e + 0x10), ld(e + 0x14))
	if !f32_end(csr) {
		return pose_exact(e)
	}
	bad := false
	for i in 0 ..< w.n {
		for x in out.pos[i] {bad |= transmute(u32)x & F32_EXP == F32_EXP}
		for x in out.rot[i] {bad |= transmute(u32)x & F32_EXP == F32_EXP}
	}
	if bad {
		return pose_exact(e)
	}
	base := ld(poses + 4)
	pd, rd := ld(poses), ld(rots)
	for i in 0 ..< w.n {
		sv(pd + (base + i) * 12, out.pos[i])
		sv(rd + (base + i) * 16, out.rot[i])
	}
	st(poses + 4, base + w.n)
	st(rots + 4, base + w.n)
	// The registers the guest's blocks use end empty: the composition's two,
	// the deeper levels' vector add three, rotate seven.
	m := u8(0xc0)
	if w.n > 1 {m |= 0xe0}
	if rotated {m |= 0xfe}
	c.fpu.tag |= rot8(m, c.fpu.top)
	pose_exit(e)
	return true
}

// The epilogue's saved registers and esp.
@(private = "file")
pose_exit :: proc "contextless" (e: u32) {
	c := &x86.cpu
	st(e - 0x12c, c.ebx)
	st(e - 0x130, c.ebp)
	st(e - 0x134, c.esi)
	st(e - 0x138, c.edi)
	c.esp = e - 0x138
}

// The tree in depth-first order: each node's address, its parent's index (-1
// for the root) and its depth.
@(private = "file")
Pose_Walk :: struct {
	n:      u32,
	node:   [POSE_NODES_MAX]u32,
	parent: [POSE_NODES_MAX]i32,
	depth:  [POSE_NODES_MAX]u8,
}

@(private = "file")
Pose_Out :: struct {
	pos: [POSE_NODES_MAX][3]f32,
	rot: [POSE_NODES_MAX][4]f32,
}

// Fills w from the arguments at esp e; false when the native cannot run.
@(private = "file")
pose_walk :: proc "contextless" (w: ^Pose_Walk, e: u32) -> bool #no_bounds_check {
	poses, rots := ld(e + 8), ld(e + 0xc)
	if ld(poses + 4) != ld(rots + 4) {
		return false
	}
	path: [POSE_DEPTH_MAX + 1]struct {
		at:   i32,
		next: i32,
	} = ---
	w.n = 1
	w.node[0], w.parent[0], w.depth[0] = ld(e + 4), -1, 0
	path[0] = {0, 0}
	sp := 1
	for _ in 0 ..< 2 * POSE_NODES_MAX {
		if sp == 0 {
			break
		}
		top := &path[sp - 1]
		nd := w.node[top.at]
		k := i32(ld(nd + 0x30))
		if k > POSE_CHILDREN_MAX {
			return false
		}
		if top.next >= k {
			sp -= 1
			continue
		}
		if w.n == POSE_NODES_MAX || sp > POSE_DEPTH_MAX {
			return false
		}
		i := w.n
		w.node[i], w.parent[i], w.depth[i] = ld(ld(nd + 0x2c) + u32(top.next) * 4), top.at, u8(sp)
		w.n += 1
		top.next += 1
		path[sp] = {i32(i), 0}
		sp += 1
	}
	return sp == 0 && pose_room(w, e)
}

// Both arrays hold the pushes without growing, and what the guest writes (the
// pushed elements, its stack) overlaps nothing it reads (the nodes, their
// child lists, the parent pose, the array headers) or each other.
@(private = "file")
pose_room :: proc "contextless" (w: ^Pose_Walk, e: u32) -> bool #no_bounds_check {
	poses, rots := ld(e + 8), ld(e + 0xc)
	base, n := u64(ld(poses + 4)), u64(w.n)
	if base + n > u64(ld(poses + 8)) || base + n > u64(ld(rots + 8)) {
		return false
	}
	deepest := u64(0)
	for i in 0 ..< w.n {deepest = max(deepest, u64(w.depth[i]))}
	stack_lo := u64(e) - (deepest / 6 + 1) * POSE_FRAME - POSE_HELPER
	writes := [3][2]u64 {
		{u64(ld(poses)) + base * 12, u64(ld(poses)) + (base + n) * 12},
		{u64(ld(rots)) + base * 16, u64(ld(rots)) + (base + n) * 16},
		{stack_lo, u64(e)},
	}
	for a in 0 ..< 3 {
		for b in a + 1 ..< 3 {
			if pose_overlap(writes[a], writes[b]) {return false}
		}
	}
	reads := [4][2]u64 {
		{u64(ld(e + 0x10)), u64(ld(e + 0x10)) + 12},
		{u64(ld(e + 0x14)), u64(ld(e + 0x14)) + 16},
		{u64(poses), u64(poses) + 12},
		{u64(rots), u64(rots) + 12},
	}
	for r in reads {
		for x in writes {
			if pose_overlap(r, x) {return false}
		}
	}
	for i in 0 ..< w.n {
		nd := u64(w.node[i])
		kids := u64(ld(w.node[i] + 0x2c))
		k := u64(max(i32(ld(w.node[i] + 0x30)), 0))
		for x in writes {
			if pose_overlap({nd + 8, nd + 0x34}, x) || pose_overlap({kids, kids + k * 4}, x) {return false}
		}
	}
	return true
}

@(private = "file")
pose_overlap :: #force_inline proc "contextless" (a, b: [2]u64) -> bool {return a[0] < b[1] && b[0] < a[1]}

// q composed with r, the products in registers, the sums of x and y
// associated by depth mod 6.
@(private)
pose_comp :: #force_inline proc "contextless" (s: bool, r, q: [4]$T, d: u8) -> [4]T #no_bounds_check {
	p: [4][4]T
	for i in 0 ..< 4 {
		for j in 0 ..< 4 {p[i][j] = xmul(s, r[i], q[j])}
	}
	w := xsub(s, xsub(s, xsub(s, p[0][0], p[1][1]), p[2][2]), p[3][3])
	x, y: T
	switch d % 6 {
	case 2:
		x = xadd(s, xadd(s, p[0][1], p[1][0]), p[3][2])
	case 4, 5:
		x = xadd(s, xadd(s, p[0][1], p[3][2]), p[1][0])
	case:
		x = xadd(s, xadd(s, p[1][0], p[3][2]), p[0][1])
	}
	x = xsub(s, x, p[2][3])
	switch d % 6 {
	case 1, 2, 5:
		y = xadd(s, xadd(s, xsub(s, p[2][0], p[3][1]), p[1][3]), p[0][2])
	case:
		y = xadd(s, xadd(s, xsub(s, p[2][0], p[3][1]), p[0][2]), p[1][3])
	}
	z := xadd(s, xsub(s, xadd(s, p[2][1], p[3][0]), p[1][2]), p[0][3])
	return {w, x, y, z}
}

// Out of line so no floating-point operation moves across the MXCSR accesses
// around it. Products and sums in the guest's order. True when a rotation
// was not a copy.
@(private = "file")
pose_compute :: #force_no_inline proc "contextless" (w: ^Pose_Walk, out: ^Pose_Out, pp, pq: u32) -> (rotated: bool) #no_bounds_check {
	for i in 0 ..< w.n {
		nd, d := w.node[i], w.depth[i]
		p: [3]f32
		q: [4]f32
		if j := w.parent[i]; j < 0 {
			p, q = lv(pp), lq(pq)
		} else {
			p, q = out.pos[j], out.rot[j]
		}
		v := lv(nd + 8)
		if !unit_w(transmute(u32)q[0]) {
			v, _ = skin_rot(true, q, v, false)
			rotated = true
		}
		out.pos[i] = {p[0] + v[0], p[1] + v[1], p[2] + v[2]}
		out.rot[i] = pose_comp(true, lq(nd + 0x14), q, d)
	}
	return
}

@(private = "file")
Pose_Path :: struct {
	node, index, next: u32, // the node, its position index, its next child
}

@(private = "file")
pose_path: [POSE_PATH_MAX]Pose_Path

// The tree's node count; false when it is deeper than POSE_PATH_MAX.
@(private = "file")
pose_count :: proc "contextless" (root: u32) -> (n: u32, ok: bool) #no_bounds_check {
	pose_path[0] = {node = root}
	sp := 1
	n = 1
	for sp > 0 {
		top := &pose_path[sp - 1]
		if i32(top.next) >= i32(ld(top.node + 0x30)) {
			sp -= 1
			continue
		}
		if sp == POSE_PATH_MAX {
			return n, false
		}
		pose_path[sp] = {node = ld(ld(top.node + 0x2c) + top.next * 4)}
		top.next += 1
		sp += 1
		n += 1
	}
	return n, true
}

// The exact path: the recompiled body's f64 operations, rounded under single
// precision control as round_pc rounds, narrowed where the guest stores or
// spills, node by node in its order. Each node reads its parent's elements
// through the data pointers and index the guest uses, pushes as it pushes,
// reserving through call_guest with esp in its frame, and leaves the tag
// bits its blocks leave, so any precision control, value or growth gives its
// bits. False only for a tree deeper than POSE_PATH_MAX, before any write.
@(private = "file")
pose_exact :: proc(e: u32) -> bool #no_bounds_check {
	root := ld(e + 4)
	if _, ok := pose_count(root); !ok {
		return false
	}
	poses, rots := ld(e + 8), ld(e + 0xc)
	s := x86.cpu.fpu.cw & x86.PC_MASK == 0
	pose_path[0] = {node = root, index = pose_node(e, s, root, 0, ld(e + 0x10), ld(e + 0x14))}
	sp := u32(1)
	for sp > 0 {
		top := &pose_path[sp - 1]
		if i32(top.next) >= i32(ld(top.node + 0x30)) {
			sp -= 1
			continue
		}
		assert(sp < POSE_PATH_MAX)
		i := top.index
		pp, pq := ld(poses) + i * 12, ld(rots) + i * 16
		nd := ld(ld(top.node + 0x2c) + top.next * 4)
		top.next += 1
		pose_path[sp] = {node = nd, index = pose_node(e, s, nd, sp, pp, pq)}
		sp += 1
	}
	pose_exit(e)
	return true
}

// One node at depth d, its parent's position and rotation at pp and pq;
// returns its index.
@(private = "file")
pose_node :: proc(e: u32, s: bool, nd, d, pp, pq: u32) -> u32 #no_bounds_check {
	c := &x86.cpu
	poses, rots := ld(e + 8), ld(e + 0xc)
	i := ld(poses + 4)
	top := d % 6 == 0 // the root of a guest call: inline pushes
	frame := e - 0x138 - d / 6 * POSE_FRAME
	t := c.fpu.top
	v := [3]f64{lx(nd + 8), lx(nd + 0xc), lx(nd + 0x10)}
	m := u8(top ? 0xc0 : 0xe0)
	if !unit_w(ld(pq)) {
		v, _ = skin_rot(s, [4]f64{lx(pq), lx(pq + 4), lx(pq + 8), lx(pq + 0xc)}, v, false)
		v = {xspill(v[0]), xspill(v[1]), top ? v[2] : xspill(v[2])}
		m = 0xfe
	}
	p := [3]f64{lx(pp), lx(pp + 4), lx(pp + 8)}
	pos: [3]f32
	for k in 0 ..< 3 {pos[k] = f32(top ? round_pc(s, v[k] + p[k]) : round_pc(s, p[k] + v[k]))}
	c.fpu.tag |= rot8(m, t)
	pose_push(poses, top ? frame : frame - 0xc, pos, POSE_POS_RESERVE, top ? POSE_RET_POS : POSE_RET_POS_PUSH)
	r := [4]f64{lx(nd + 0x14), lx(nd + 0x18), lx(nd + 0x1c), lx(nd + 0x20)}
	q := [4]f64{lx(pq), lx(pq + 4), lx(pq + 8), lx(pq + 0xc)}
	o := pose_comp(s, r, q, u8(d % 6))
	c.fpu.tag |= rot8(0xc0, t)
	pose_push(rots, top ? frame : frame - 0xc, [4]f32{f32(o[0]), f32(o[1]), f32(o[2]), f32(o[3])}, POSE_ROT_RESERVE, top ? POSE_RET_ROT : POSE_RET_ROT_PUSH)
	return i
}

// The guest's push: at count == capacity a reserve call with esp at sp.
@(private = "file")
pose_push :: proc(arr, sp: u32, v: [$N]f32, reserve, ret: u32) {
	if cap := ld(arr + 8); ld(arr + 4) == cap {
		pose_reserve(sp, arr, cap != 0 ? cap * 2 : 8, reserve, ret)
	}
	sv(ld(arr) + ld(arr + 4) * u32(N) * 4, v)
	st(arr + 4, ld(arr + 4) + 1)
}

// The capacity n pushes leave, reserved at once.
@(private = "file")
pose_grow :: proc(sp, arr, n, reserve, ret: u32) {
	k, cap := ld(arr + 4), ld(arr + 8)
	grown := cap
	for _ in 0 ..< n {
		if k == grown {grown = grown != 0 ? grown * 2 : 8}
		k += 1
	}
	if grown != cap {
		pose_reserve(sp, arr, grown, reserve, ret)
	}
}

// thiscall reserve(ecx arr, capacity) with esp at sp, as the guest pushes it.
@(private = "file")
pose_reserve :: proc(sp, arr, capacity, reserve, ret: u32) {
	c := &x86.cpu
	esp := c.esp
	st(sp - 4, capacity)
	st(sp - 8, ret)
	c.ecx, c.esp = arr, sp - 8
	call_guest(reserve)
	c.esp = esp
}
