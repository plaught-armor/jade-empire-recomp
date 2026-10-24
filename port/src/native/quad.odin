// Emitter_Update (0x63a860), its per-particle loop (0x63aba0 to 0x63aee5) as a
// native span: each particle's camera-facing quad, four vertices into the
// vertex buffer. WHY: docs/recompiler.md §8
package native

import "../x86"

QUAD_HALF :: 0x006e1914 // f32 0.5
QUAD_BYTE :: 0x006e8c04 // f32 255
QUAD_INTERP :: 0x00630fb0 // Emitter_InterpColorSize
QUAD_BASIS :: 0x00631670 // Emitter_ParticleBasis
QUAD_ONE :: 0x006e1910 // f32 1
QUAD_NO_CELL :: 0x006e1848 // f32, the fade of a particle with no atlas cell
QUAD_CELL_NEXT :: 0x00630ed0 // Emitter cell steps, thiscall (cell) -> cell or -1
QUAD_CELL_PREV :: 0x00630f40
QUAD_RET_INTERP :: 0x0063abdf // return addresses of the two calls
QUAD_RET_BASIS :: 0x0063ac06
QUAD_VERTEX :: 0x18 // bytes: position, color, u, v
QUAD_FRAME_LO :: 0x18 // the frame slots the loop and its two calls write
QUAD_FRAME_HI :: 0xa4
QUAD_INDEX_MAX :: 0x1000000 // a cell index and its successor convert to f32 exactly
QUAD_BATCH :: 64 // particles whose calls run before their vertices
QUAD_PARTICLE :: 0x70 // bytes of a particle the loop and its calls read
// Compared at the exit: eax ecx edx ebx esp ebp esi. edi is reloaded there.
QUAD_LIVE :: 0x7f

// Entered with esp at the frame base s, ebp the emitter, edi the next vertex
// and eax the particle index i (i32[s + 0x30]); ebx is the pass (i32[s + 0x44]
// after the first particle), and only pass 0 takes the batch below. Particle i is [[ebp + 0x1c0] + 4i]; the loop runs while i is
// below i32[ebp + 0x1c4]. Per particle p, as the guest: Emitter_InterpColorSize
// into the color (s + 0x74), alpha (s + 0x84) and sizes (s + 0x80, s + 0x94),
// Emitter_ParticleBasis into right R (s + 0x24) and up U (s + 0x18), both
// through call_guest with the guest's arguments. Then R *= size a * 0.5, U *=
// size b * 0.5, the atlas cell q, r = i32[p + 0x50] divmod i32[s + 0x4c], and
// the color ARGB with alpha (f32[s + 0x60] * f32[s + 0x14]) * alpha, each
// channel times 255 truncated. With P = [p + 8], du = [s + 0x5c] and dv =
// [s + 0x64], the vertices are (P - R) - U at (r du, 1 - (q + 1) dv),
// (R + P) - U at ((r + 1) du, the same), (U + P) + R (z (U + R) + P) at
// ((r + 1) du, 1 - q dv) and (P - R) + U at (r du, the same). The calls of up
// to QUAD_BATCH particles run first, their outputs kept, then the vertices of
// all of them under one f32 rule (native.odin) check: the MXCSR accesses
// around it cost more than a particle's arithmetic. The batch's vertices
// overlap neither the frame nor its particles, so the calls cannot see them.
// Every frame slot the guest writes is left with its value. Other passes, and
// the particles from the first one the batch cannot take, run in quad_exact;
// the calls have no effect but their outputs, so running them again for a
// batch the f32 rule rejected is harmless.
Emitter_Quads_0063aba0_0063aee5 :: proc() -> bool #no_bounds_check {
	c := &x86.cpu
	s := c.esp
	if mode == .Check {
		n := u32(max(i32(ld(c.ebp + 0x1c4)) - i32(c.eax), 1))
		frame := u32(QUAD_FRAME_HI - QUAD_FRAME_LO) / 4
		return span_check(0x0063aee5, Emitter_Quads_0063aba0_0063aee5,
			{{s + QUAD_FRAME_LO, frame}, {c.edi, min(n * QUAD_VERTEX, SPAN_OUT_MAX - frame)}}, QUAD_LIVE)
	}
	em, i, vb, pass := c.ebp, c.eax, c.edi, c.ebx
	first := true
	b: [QUAD_BATCH]Quad_In = ---
	for pass == 0 && ld(s + 0x44) == 0 && i32(i) < i32(ld(em + 0x1c4)) {
		n, stop := quad_gather(&b, s, em, i, vb)
		if n == 0 {
			break
		}
		csr := csr_get()
		f32_begin(csr)
		ok := quad_vertices(&b, n, s, vb)
		if !f32_end(csr) || !ok {
			break
		}
		l := &b[n - 1]
		sv(s + 0x18, l.U)
		sv(s + 0x24, l.R)
		st(s + 0x3c, u32(l.r + 1))
		st(s + 0x40, u32(l.r))
		st(s + 0x48, u32(l.q))
		st(s + 0x8c, l.argb)
		st(s + 0x90, ld(s + 0x7c))
		st(s + 0x98, ld(s + 0x78))
		st(s + 0xa0, ld(s + 0x74))
		full := lf(QUAD_BYTE)
		for v, k in ([4]f32{l.col[0], l.col[1], l.col[2], l.alpha}) {
			c.xmm[k] = {}
			c.xmm[k].f[0] = v * full
		}
		c.ecx, c.edx, c.esi = u32(l.r + 1), u32(l.q + 1), l.p
		i += n
		vb += n * 4 * QUAD_VERTEX
		st(s + 0x30, i)
		first = false
		if stop {
			break
		}
	}
	for first || i32(i) < i32(ld(em + 0x1c4)) {
		quad_exact(s, em, i, vb, first ? pass : ld(s + 0x44))
		first = false
		i += 1
		vb += 4 * QUAD_VERTEX
		st(s + 0x30, i)
	}
	c.eax, c.ebx, c.edi, c.esp = i, ld(s + 0x44), vb, s
	return true
}

// One iteration of the recompiled loop for pass ebx, every read and write in
// the guest's order on guest memory. Pass 0 fades by f32[s + 0x14] and takes
// the cell [p + 0x50]; pass 2 and 4 step it back once and twice and fade by
// (1 - t), pass 3 steps it forward twice and the rest once, fading by t, with
// t = ([p + 0x6c] - [p + 0x58]) / [s + 0x34]. A cell below 0 is (0, 0) with
// the fade f32[QUAD_NO_CELL]. Leaves ecx r + 1, edx q + 1, esi p and the
// SSE products in xmm0 to xmm3; the guest empties st0 to st2.
@(private = "file")
quad_exact :: proc(s, em, i, vb, pass: u32) #no_bounds_check {
	c := &x86.cpu
	p := ld(ld(em + 0x1c0) + i * 4)
	quad_calls(s, em, p, i, vb, pass)
	x := c.fpu.cw & x86.PC_MASK == 0
	a := xmul(x, lx(s + 0x80), lx(QUAD_HALF))
	h := xmul(x, lx(s + 0x94), lx(QUAD_HALF))
	for k in u32(0) ..< 3 {sx(s + 0x24 + k * 4, xmul(x, lx(s + 0x24 + k * 4), a))}
	for k in u32(0) ..< 3 {sx(s + 0x18 + k * 4, xmul(x, lx(s + 0x18 + k * 4), h))}
	c.fpu.tag |= rot8(0xe0, c.fpu.top)
	fade: f64
	cell := ld(p + 0x50)
	if pass == 0 {
		fade = lx(s + 0x14)
	} else {
		back := pass == 2 || pass == 4
		step := back ? u32(QUAD_CELL_PREV) : u32(QUAD_CELL_NEXT)
		switch pass {
		case 3: cell = quad_cell(s, em, step, cell, 0x0063acb3)
		case 4: cell = quad_cell(s, em, step, cell, 0x0063aca5)
		}
		cell = quad_cell(s, em, step, cell, back ? 0x0063acd2 : 0x0063acbb)
		x = c.fpu.cw & x86.PC_MASK == 0
		t := round_pc(x, xsub(x, lx(p + 0x6c), lx(p + 0x58)) / lx(s + 0x34))
		if back {t = xsub(x, lx(QUAD_ONE), t)}
		fade = xmul(x, t, lx(s + 0x14))
	}
	q, r := u32(0), u32(0)
	if pass != 0 && i32(cell) < 0 {
		fade = lx(QUAD_NO_CELL)
	} else {
		cols := ld(s + 0x4c)
		q = u32(i64(i32(cell)) / i64(i32(cols)))
		r = cell - u32(i64(i32(q)) * i64(i32(cols)))
	}
	st(s + 0x48, q)
	st(s + 0x40, r)
	cb, cg, cr := ld(s + 0x7c), ld(s + 0x78), ld(s + 0x74)
	st(s + 0x90, cb)
	alpha := xmul(x, xmul(x, lx(s + 0x60), fade), lx(s + 0x84))
	st(s + 0x98, cg)
	st(s + 0xa0, cr)
	sx(s + 0x3c, alpha)
	full := lf(QUAD_BYTE)
	ch: [4]u32
	for a, k in ([4]u32{s + 0xa0, s + 0x98, s + 0x90, s + 0x3c}) {
		c.xmm[k] = {}
		c.xmm[k].f[0] = lf(a) * full
		ch[k] = x86.cvtt_i32(f64(c.xmm[k].f[0]))
	}
	argb := (ch[0] << 16 | ch[1] << 8) | (ch[2] | ch[3] << 24)
	st(s + 0x8c, argb)
	for j in u32(0) ..< 4 {st(vb + 0xc + j * QUAD_VERTEX, argb)}
	r1: u32
	for k in u32(0) ..< 3 {
		d := xsub(x, lx(p + 8 + k * 4), lx(s + 0x24 + k * 4))
		if k == 0 {
			st(s + 0x3c, ld(s + 0x48) + 1)
			r1 = ld(s + 0x40) + 1
		}
		sx(vb + k * 4, xsub(x, d, lx(s + 0x18 + k * 4)))
	}
	u0 := xmul(x, f64(i32(ld(s + 0x40))), lx(s + 0x5c))
	sx(vb + 0x10, u0)
	v1 := f64(i32(ld(s + 0x3c)))
	st(s + 0x3c, r1)
	v1 = xsub(x, lx(QUAD_ONE), xmul(x, v1, lx(s + 0x64)))
	sx(vb + 0x14, v1)
	for k in u32(0) ..< 3 {
		sx(vb + 0x18 + k * 4, xsub(x, xadd(x, lx(s + 0x24 + k * 4), lx(p + 8 + k * 4)), lx(s + 0x18 + k * 4)))
	}
	u1 := xmul(x, f64(i32(ld(s + 0x3c))), lx(s + 0x5c))
	sx(vb + 0x28, u1)
	sx(vb + 0x2c, v1)
	for k in u32(0) ..< 2 {
		sx(vb + 0x30 + k * 4, xadd(x, xadd(x, lx(s + 0x18 + k * 4), lx(p + 8 + k * 4)), lx(s + 0x24 + k * 4)))
	}
	sx(vb + 0x38, xadd(x, xadd(x, lx(s + 0x20), lx(s + 0x2c)), lx(p + 0x10)))
	sx(vb + 0x40, u1)
	v0 := xsub(x, lx(QUAD_ONE), xmul(x, f64(i32(ld(s + 0x48))), lx(s + 0x64)))
	sx(vb + 0x44, v0)
	for k in u32(0) ..< 3 {
		sx(vb + 0x48 + k * 4, xadd(x, xsub(x, lx(p + 8 + k * 4), lx(s + 0x24 + k * 4)), lx(s + 0x18 + k * 4)))
	}
	sx(vb + 0x58, u0)
	sx(vb + 0x5c, v0)
	c.ecx, c.edx, c.esi = r1, ld(s + 0x48) + 1, p
}

// A cell step call, the cell pushed as its argument; returns eax.
@(private = "file")
quad_cell :: proc(s, em, fn, cell, ret: u32) -> u32 {
	c := &x86.cpu
	st(s - 4, cell)
	st(s - 8, ret)
	c.ecx, c.esp = em, s - 8
	call_guest(fn)
	c.esp = s
	return c.eax
}

// A particle's inputs to its vertices; R, U, alpha and argb hold the scaled
// basis, the faded alpha and the packed color after quad_vertices.
@(private = "file")
Quad_In :: struct {
	p:              u32,
	q, r:           i32,
	size_a, size_b: f32,
	alpha:          f32,
	col:            [3]f32,
	R, U, P:        [3]f32,
	argb:           u32,
}

// Runs the calls of up to QUAD_BATCH particles from i, keeping their outputs
// in b; stop when the particle after them cannot run natively.
@(private = "file")
quad_gather :: proc(b: ^[QUAD_BATCH]Quad_In, s, em, i, vb: u32) -> (n: u32, stop: bool) #no_bounds_check {
	vlo := u64(vb)
	vhi := vlo + QUAD_BATCH * 4 * QUAD_VERTEX
	if vlo < u64(s) + 0xc0 && u64(s) - 0x40 < vhi {
		return 0, true
	}
	cols := i32(ld(s + 0x4c))
	if cols == 0 || cols == -1 {
		return 0, true
	}
	for n < QUAD_BATCH && i32(i + n) < i32(ld(em + 0x1c4)) {
		p := ld(ld(em + 0x1c0) + (i + n) * 4)
		if vlo < u64(p) + QUAD_PARTICLE && u64(p) < vhi {
			return n, true
		}
		quad_calls(s, em, p, i + n, vb + n * 4 * QUAD_VERTEX, 0)
		if !f32_state(csr_get()) {
			return n, true
		}
		cell := i32(ld(p + 0x50))
		q, r := cell / cols, cell % cols
		if abs(q) >= QUAD_INDEX_MAX - 1 || abs(r) >= QUAD_INDEX_MAX - 1 {
			return n, true
		}
		b[n] = {
			p      = p,
			q      = q,
			r      = r,
			size_a = lf(s + 0x80),
			size_b = lf(s + 0x94),
			alpha  = lf(s + 0x84),
			col    = lv(s + 0x74),
			R      = lv(s + 0x24),
			U      = lv(s + 0x18),
			P      = lv(p + 8),
		}
		n += 1
	}
	return n, false
}

// The two calls at the top of an iteration, pushed as the guest pushes them.
@(private = "file")
quad_calls :: proc(s, em, p, i, vb, pass: u32) {
	c := &x86.cpu
	c.ebx, c.edi = pass, vb
	args := [8]u32{p, i, ld(s + 0x50), s + 0x74, s + 0x84, s + 0x80, s + 0x94, ld(s + 0x88)}
	for a, k in args {st(s - 0x20 + u32(k) * 4, a)}
	st(s - 0x24, QUAD_RET_INTERP)
	c.eax, c.ecx, c.edx, c.esi, c.esp = i, em, s + 0x74, p, s - 0x24
	call_guest(QUAD_INTERP)
	basis := [6]u32{s + 0x24, s + 0x18, p, s + 0xa4, s + 0x68, s + 0xb0}
	for a, k in basis {st(s - 0x18 + u32(k) * 4, a)}
	st(s - 0x1c, QUAD_RET_BASIS)
	c.eax, c.ecx, c.edx, c.esp = s + 0x24, em, s + 0x18, s - 0x1c
	call_guest(QUAD_BASIS)
	c.esp = s
}

// cvttss2si: the integer indefinite outside the i32 range.
@(private = "file")
quad_trunc :: #force_inline proc "contextless" (x: f32) -> u32 {
	if !(x > -2147483648.0 && x < 2147483648.0) {
		return 0x80000000
	}
	return u32(i32(x))
}

// Writes the batch's vertices from vb, and each particle's scaled basis and
// color back to b; false when one is not finite. Out of line so no
// floating-point operation moves across the MXCSR accesses around it.
// Products and sums in the guest's order.
@(private = "file")
quad_vertices :: #force_no_inline proc "contextless" (b: ^[QUAD_BATCH]Quad_In, n, s, vb: u32) -> bool #no_bounds_check {
	half, full, one := lf(QUAD_HALF), lf(QUAD_BYTE), lf(QUAD_ONE)
	fade := lf(s + 0x60) * lf(s + 0x14)
	du, dv := lf(s + 0x5c), lf(s + 0x64)
	bad := false
	for k in 0 ..< min(n, QUAD_BATCH) {
		e := &b[k]
		a, h := e.size_a * half, e.size_b * half
		R, U, P := e.R * a, e.U * h, e.P
		e.alpha = fade * e.alpha
		e.argb = quad_trunc(e.col[0] * full) << 16 | quad_trunc(e.col[1] * full) << 8 | quad_trunc(e.col[2] * full) | quad_trunc(e.alpha * full) << 24
		e.R, e.U = R, U
		u0, u1 := f32(e.r) * du, f32(e.r + 1) * du
		v0, v1 := one - f32(e.q) * dv, one - f32(e.q + 1) * dv
		pos := [4][3]f32{(P - R) - U, (R + P) - U, (U + P) + R, (P - R) + U}
		pos[2][2] = (U[2] + R[2]) + P[2]
		uv := [4][2]f32{{u0, v1}, {u1, v1}, {u1, v0}, {u0, v0}}
		at := vb + k * 4 * QUAD_VERTEX
		for j in u32(0) ..< 4 {
			sv(at + j * QUAD_VERTEX, pos[j])
			st(at + j * QUAD_VERTEX + 0xc, e.argb)
			sv(at + j * QUAD_VERTEX + 0x10, uv[j])
			for x in pos[j] {bad |= transmute(u32)x & F32_EXP == F32_EXP}
			for x in uv[j] {bad |= transmute(u32)x & F32_EXP == F32_EXP}
		}
	}
	return !bad
}
