// r_00635a50, the particle physics of an emitter tick: its per-particle loop
// (0x635c80 to 0x63688d) as a native span for the emitters whose particles
// take the plain path. WHY: docs/recompiler.md §8
package native

import "../x86"

PHYS_ZERO :: 0x006e1848 // f32 0
PHYS_ONE :: 0x006e1910 // f32 1
PHYS_TURN :: 0x006e3694 // f32 2 pi, the angle's wrap
PHYS_TURN_MIN :: 0x0070db10 // f32 -2 pi
PHYS_GRAVITY :: 0x0070db0c // f32 9.81
PHYS_NO_MOVE :: 0x0059f310 // the empty move callback (ret 4)
PHYS_RET_MOVE :: 0x00636787 // the callback's return address
PHYS_PARTICLE :: 0x70 // bytes of a particle the loop reads
PHYS_FRAME_LO :: 8 // the frame from s - 8 (the callback's argument and return address)
PHYS_FRAME :: 0x248 // to the dt argument at s + 0x23c
PHYS_EMITTER :: 0x230
PHYS_DEF :: 0x1e8
PHYS_BATCH :: 64 // particles under one f32 rule check
PHYS_SAVE_MAX :: 1024 // particles a check run restores
PHYS_WORDS :: (PHYS_PARTICLE - 8) / 4 // dwords from p + 8 the loop may write
// Compared at the exit: eax ecx edx esp. The epilogue pops ebx ebp esi edi.
PHYS_LIVE :: 0x17

// Entered at the loop head with esp at the frame base s, edi the emitter em,
// ebp its definition def (also u32[s + 0x7c]) and ebx the particle index i,
// counting down to 0; particle i is [[em + 0x1c0] + 4i]. The emitter takes
// the plain path when its life f32[em + 0xc0] is not negative, it is not of
// kind i32[em + 0x130] = 6 (the trail lerp), it has no attractor (def flag
// bit 0 with a target [em + 0x22c]), the move callback (s + 0x3c, its this
// adjustment s + 0x40) is the empty one and the wind (byte s + 0x12) and
// collision (byte s + 0x13) flags are clear; i32[em + 0x134] = 2 with
// u32[def + 0xf0] = 0 takes the immortal path and is left to the guest too.
// Per particle p, with dt = f32[s + 0x23c]: age a = dt + [p + 0x6c], stored;
// a >= life kills p (left to the guest, which removes it) unless
// u32[def + 0xf0] is set, which zeroes the age instead. The angle b =
// f32[s + 0xbc] + [p + 0x20] is stored, less 2 pi above 2 pi or plus 2 pi
// below -2 pi. The position is copied to s + 0x48, and f32[s + 0x18] =
// 1 - dt, 0 when negative. A landed particle (byte p + 0x68) stops there;
// otherwise, with speed [p + 0x24], direction D = [p + 0x28] and velocity
// V = [p + 0x5c]: P += (D speed + V) dt per component, V.z -= (dt
// f32[em + 0xb8]) 9.81 and speed *= f32[s + 0x18]. Batches of PHYS_BATCH
// particles run under one f32 rule (native.odin) check, rolled back from an
// undo log when it fails and rerun in the recompiled body's rounding. The
// particles must lie apart from the frame, the emitter, its definition and
// its particle array, so the emitter's path holds for the whole loop. The loop
// runs until index 0 or until a particle the plain path cannot take; that one
// is handed to the recompiled loop at its head (a false return, the state the
// loop head has) and the span takes over again at the next head.
Emitter_Physics_00635c80_0063688d :: proc() -> bool #no_bounds_check {
	c := &x86.cpu
	s, em := c.esp, c.edi
	if mode == .Check {
		return phys_check(s, em, i32(c.ebx))
	}
	def := c.ebp
	if c.fpu.tag != 0xff || !phys_plain(s, em, def) {
		return false
	}
	x := c.fpu.cw & x86.PC_MASK == 0
	start := i32(c.ebx)
	i := start
	for i >= 0 {
		n := i32(0)
		csr := csr_get()
		if f32_state(csr) {
			n = phys_fast(s, em, def, i, csr)
		}
		if n == 0 {
			n = phys_run(x, s, em, def, i, PHYS_BATCH, nil, f64)
		}
		if n == 0 {
			break
		}
		i -= n
	}
	if i == start {
		return false
	}
	p := ld(ld(em + 0x1c0) + u32(i + 1) * 4)
	keep := f64(f32(round_pc(x, lx(PHYS_ONE) - lx(s + 0x23c))))
	c.fpu.sw = c.fpu.sw &~ (C0 | C2 | C3) | fcom_bits(lx(PHYS_ZERO), keep)
	c.eax = ld(s + 0x7c) & 0xffff0000 | u32(fstsw())
	c.ecx = em
	if ld8(p + 0x68) != 0 {
		c.ecx = ld(def + 0x1e4) & 1 != 0 ? ld(em + 0x22c) : ld(s + 0x48)
	}
	c.edx, c.esi = ld(s + 0x4c), p
	c.ebx = u32(i)
	st(s + 0x14, u32(i))
	if i >= 0 {
		c.ebp = def
		return false
	}
	c.ebp = p + 8
	return true
}

// The emitter's and the frame's conditions for the plain path.
@(private = "file")
phys_plain :: proc "contextless" (s, em, def: u32) -> bool {
	return(
		ld(s + 0x7c) == def &&
		!(lf(em + 0xc0) < 0) &&
		!(ld(em + 0x134) == 2 && ld(def + 0xf0) == 0) &&
		ld(em + 0x130) != 6 &&
		!(ld(def + 0x1e4) & 1 != 0 && ld(em + 0x22c) != 0) &&
		ld(s + 0x3c) == PHYS_NO_MOVE &&
		ld(s + 0x40) == 0 &&
		ld16(s + 0x12) == 0 \
	)
}

// Particle i's address, 0 when it overlaps what the loop reads.
@(private = "file")
phys_particle :: #force_inline proc "contextless" (s, em, def: u32, i: i32) -> u32 {
	arr := ld(em + 0x1c0)
	p := ld(arr + u32(i) * 4)
	if !apart(p, PHYS_PARTICLE, s - PHYS_FRAME_LO, PHYS_FRAME) || !apart(p, PHYS_PARTICLE, em, PHYS_EMITTER) ||
	   !apart(p, PHYS_PARTICLE, def, PHYS_DEF) || !apart(p, PHYS_PARTICLE, arr, ld(em + 0x1c4) * 4) {
		return 0
	}
	return p
}

// The dwords of a particle the plain path writes, for the undo log.
@(private = "file")
PHYS_UNDO := [7]u32{0x6c, 0x20, 0x08, 0x0c, 0x10, 0x64, 0x24}

// A batch under the f32 rule; 0, with every particle put back, when it fails.
@(private = "file")
phys_fast :: proc(s, em, def: u32, i: i32, csr: u32) -> i32 #no_bounds_check {
	undo: [PHYS_BATCH][len(PHYS_UNDO)]u32 = ---
	bad := false
	f32_begin(csr)
	n := phys_run(true, s, em, def, i, PHYS_BATCH, &undo, f32, &bad)
	if f32_end(csr) && !bad {
		return n
	}
	for k := n - 1; k >= 0; k -= 1 {
		p := ld(ld(em + 0x1c0) + u32(i - k) * 4)
		for o, j in PHYS_UNDO {st(p + o, undo[k][j])}
	}
	return 0
}

// Up to nmax particles from i down, each read and write in the recompiled
// loop's order on guest memory; the count run. With undo, each particle's
// written dwords are saved first. Out of line so no floating-point operation
// moves across the MXCSR accesses around the f32 batch.
@(private = "file")
phys_run :: #force_no_inline proc "contextless" (x: bool, s, em, def: u32, i, nmax: i32, undo: ^[PHYS_BATCH][len(PHYS_UNDO)]u32, $T: typeid, bad: ^bool = nil) -> i32 #no_bounds_check {
	n := i32(0)
	nonfinite := false // a local, so the per-store marks stay in a register
	for n < nmax && i - n >= 0 {
		p := phys_particle(s, em, def, i - n)
		if p == 0 {
			break
		}
		if undo != nil {
			for o, j in PHYS_UNDO {undo[n][j] = ld(p + o)}
		}
		if !phys_step(x, s, em, def, p, &nonfinite, T) {
			break
		}
		n += 1
	}
	if bad != nil {
		bad^ = nonfinite
	}
	return n
}

// One particle; false, with nothing written, when it dies.
@(private = "file")
phys_step :: #force_inline proc "contextless" (x: bool, s, em, def, p: u32, bad: ^bool, $T: typeid) -> bool {
	dt := xl(s + 0x23c, T)
	a := xadd(x, dt, xl(p + 0x6c, T))
	dead := a >= xl(em + 0xc0, T)
	if dead && ld(def + 0xf0) == 0 {
		return false
	}
	st8(s + 0x11, 0)
	phys_put(p + 0x6c, a, bad)
	if dead {
		st(p + 0x6c, 0)
	}
	b := xadd(x, xl(s + 0xbc, T), xl(p + 0x20, T))
	turn := xl(PHYS_TURN, T)
	phys_put(p + 0x20, b, bad)
	if b > turn {
		phys_put(p + 0x20, xsub(x, b, turn), bad)
	} else if b < xl(PHYS_TURN_MIN, T) {
		phys_put(p + 0x20, xadd(x, b, turn), bad)
	}
	for k in u32(0) ..< 3 {st(s + 0x48 + k * 4, ld(p + 8 + k * 4))}
	phys_put(s + 0x18, xsub(x, xl(PHYS_ONE, T), dt), bad)
	if xl(PHYS_ZERO, T) > xl(s + 0x18, T) {
		st(s + 0x18, 0)
	}
	if ld8(p + 0x68) != 0 {
		return true
	}
	st(s - 4, p)
	st(s - 8, PHYS_RET_MOVE)
	for k in u32(0) ..< 3 {
		v := xmul(x, xl(p + 0x28 + k * 4, T), xl(p + 0x24, T))
		v = xmul(x, xadd(x, v, xl(p + 0x5c + k * 4, T)), dt)
		phys_put(p + 8 + k * 4, xadd(x, v, xl(p + 8 + k * 4, T)), bad)
	}
	g := xmul(x, xmul(x, dt, xl(em + 0xb8, T)), xl(PHYS_GRAVITY, T))
	phys_put(p + 0x64, xsub(x, xl(p + 0x64, T), g), bad)
	phys_put(p + 0x24, xmul(x, xl(s + 0x18, T), xl(p + 0x24, T)), bad)
	return true
}

// fstp dword; under the f32 rule a value that is not finite marks the batch.
@(private = "file")
phys_put :: #force_inline proc "contextless" (a: u32, v: $T, bad: ^bool) {
	sx(a, f64(v))
	when T == f32 {
		bad^ |= transmute(u32)v & F32_EXP == F32_EXP
	}
}

// JE_NATIVE=check: the span's writes reach every particle from i down, not
// only the regions span_check puts back, so the particles are saved around it.
@(private = "file")
phys_check :: proc(s, em: u32, i: i32) -> bool #no_bounds_check {
	@(static) save: [PHYS_SAVE_MAX][PHYS_WORDS]u32
	if i < 0 || i >= PHYS_SAVE_MAX {
		return false
	}
	arr := ld(em + 0x1c0)
	for k in 0 ..= i {
		p := ld(arr + u32(k) * 4)
		for j in u32(0) ..< PHYS_WORDS {save[k][j] = ld(p + 8 + j * 4)}
	}
	pi, p0 := ld(arr + u32(i) * 4), ld(arr)
	ok := span_check(0x0063688d, Emitter_Physics_00635c80_0063688d,
		{{s - PHYS_FRAME_LO, 9}, {s + 0x48, 3}, {pi + 8, PHYS_WORDS}, {p0 + 8, PHYS_WORDS}}, PHYS_LIVE)
	for k in 0 ..= i {
		p := ld(arr + u32(k) * 4)
		for j in u32(0) ..< PHYS_WORDS {st(p + 8 + j * 4, save[k][j])}
	}
	return ok
}
