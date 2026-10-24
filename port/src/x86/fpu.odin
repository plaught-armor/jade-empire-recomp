// x87 on f64. Registers hold f64, not 80-bit values; rounding control applies
// only to integer stores and frndint. Precision control 00 (single, as D3D9
// CreateDevice sets without FPU_PRESERVE) rounds every result written through
// set_st to f32: code compares an x87 result against a constant and then
// reuses its f32 store, so a dot product of 0.99999998 in double that is 1.0
// in single takes the wrong branch (slerp of equal quaternions, 0 * inf = NaN).
// Single keeps the extended exponent range: only the significand narrows.
// Double and extended both run as f64. Loads, fxch and frstor are exact.
// WHY: docs/recompiler.md §4
package x86

import "core:math"

C0 :: 0x100
C1 :: 0x200
C2 :: 0x400
C3 :: 0x4000

// Register indexes are masked to 0..7, so the [8]f64 accesses below skip
// Odin's bounds check: it is an out-of-line call per access, about 4% of the
// frame in combat. WHY: docs/recompiler.md §2
st :: #force_inline proc "contextless" (i: u32) -> f64 {
	#no_bounds_check return cpu.fpu.st[(cpu.fpu.top + i) & 7]
}

PC_MASK :: 0x300

// Arithmetic result into st(i), rounded to the precision-control width.
set_st :: #force_inline proc "contextless" (i: u32, v: f64) {
	#no_bounds_check cpu.fpu.st[(cpu.fpu.top + i) & 7] = round_pc(cpu.fpu.cw & PC_MASK == 0, v)
}

// Physical register j & 7, for the generator's cached x87 runs.
st_phys :: #force_inline proc "contextless" (j: u32) -> f64 {
	#no_bounds_check return cpu.fpu.st[j & 7]
}

set_st_phys :: #force_inline proc "contextless" (j: u32, v: f64) {
	#no_bounds_check cpu.fpu.st[j & 7] = v
}

// An arithmetic result under precision control: single when the PC field is 00.
round_pc :: #force_inline proc "contextless" (single: bool, v: f64) -> f64 {
	return single ? round_single(v) : v
}

// Tag-word bits for registers relative to top t (bit j = physical register
// (t + j) & 7); the generator's cached x87 runs write tags back with it.
rot8 :: #force_inline proc "contextless" (m: u8, t: u32) -> u8 {
	return u8((u32(m) << (t & 7) | u32(m) >> (8 - (t & 7))) & 0xff)
}

SINGLE_DROP :: 52 - 23 // f64 significand bits below an f32 significand

// v with its significand rounded to 24 bits, nearest-even, keeping the f64
// exponent: single precision control narrows the significand, not the range.
round_single :: #force_inline proc "contextless" (v: f64) -> f64 {
	b := transmute(u64)v
	if (b >> 52) & 0x7ff == 0x7ff {return v} // inf and NaN pass through
	half := u64(1) << (SINGLE_DROP - 1)
	b += half - 1 + ((b >> SINGLE_DROP) & 1)
	return transmute(f64)(b &~ (u64(1) << SINGLE_DROP - 1))
}

// Exact register write: moves and restores, never rounded.
set_st_raw :: #force_inline proc "contextless" (i: u32, v: f64) {
	#no_bounds_check cpu.fpu.st[(cpu.fpu.top + i) & 7] = v
}

fpush :: #force_inline proc "contextless" (v: f64) {
	f := &cpu.fpu
	f.top = (f.top - 1) & 7
	#no_bounds_check f.st[f.top] = v
	f.tag &~= 1 << f.top
}

fpop :: #force_inline proc "contextless" () {
	f := &cpu.fpu
	f.tag |= 1 << f.top
	f.top = (f.top + 1) & 7
}

fxch :: #force_inline proc "contextless" (i: u32) {
	a := st(0)
	set_st_raw(0, st(i))
	set_st_raw(i, a)
}

fninit :: proc "contextless" () {
	cpu.fpu = Fpu{cw = 0x37f, tag = 0xff}
}

fldcw :: #force_inline proc "contextless" (v: u16) {
	cpu.fpu.cw = v
}

fstsw :: #force_inline proc "contextless" () -> u16 {
	return (cpu.fpu.sw & ~u16(0x3800)) | u16(cpu.fpu.top << 11)
}

// fcom/fucom: C3 C2 C0 = 000 greater, 001 less, 100 equal, 111 unordered.
fcom :: #force_inline proc "contextless" (a, b: f64) {
	f := &cpu.fpu
	f.sw &~= C0 | C2 | C3
	if a > b {
	} else if a < b {
		f.sw |= C0
	} else if a == b {
		f.sw |= C3
	} else {
		f.sw |= C0 | C2 | C3
	}
}

// fcomi/fucomi: ZF PF CF in place of C3 C2 C0.
fcomi :: proc "contextless" (a, b: f64) {
	c := &cpu
	c.of = false; c.sf = false; c.af = false
	c.zf = !(a > b || a < b)
	c.cf = !(a >= b)
	c.pf = math.is_nan(a) || math.is_nan(b)
}

fxam :: proc "contextless" () {
	f := &cpu.fpu
	f.sw &~= C0 | C1 | C2 | C3
	v := st(0)
	if math.sign_bit(v) {f.sw |= C1}
	if f.tag & (1 << f.top) != 0 {
		f.sw |= C0 | C3 // empty
		return
	}
	switch math.classify(v) {
	case .NaN, .Neg_Inf, .Inf:
		f.sw |= C0
		if !math.is_nan(v) {f.sw |= C2}
	case .Zero, .Neg_Zero:
		f.sw |= C3
	case .Subnormal:
		f.sw |= C2 | C3
	case .Normal:
		f.sw |= C2
	}
}

// fprem/fprem1 as one complete reduction: C2 clear, quotient bits in C0 C3 C1.
fprem :: proc "contextless" () {
	f := &cpu.fpu
	a, b := st(0), st(1)
	q := math.trunc(a / b)
	set_st(0, a - q * b)
	qi := u64(abs(q))
	f.sw &~= C0 | C1 | C2 | C3
	if qi & 1 != 0 {f.sw |= C1}
	if qi & 2 != 0 {f.sw |= C3}
	if qi & 4 != 0 {f.sw |= C0}
}

// v rounded to an integer under the control word's rounding field. Adding and
// subtracting 2^52 rounds to nearest even (the host's SSE default), which
// mode 0 is; the other modes step that result by one. A magnitude of 2^52 or
// more is already an integer, and NaN passes through. A zero result keeps v's
// sign, as frndint's does. Inline so the generator copies it and the fist
// stores below into each package: a call across packages is never inlined.
round_cw :: #force_inline proc "contextless" (v: f64) -> f64 {
	TWO52 :: f64(1 << 52)
	SIGN :: u64(1) << 63
	if !(abs(v) < TWO52) {return v}
	s := v < 0 ? -TWO52 : TWO52
	r := (v + s) - s
	switch (cpu.fpu.cw >> 10) & 3 {
	case 1: if r > v {r -= 1}
	case 2: if r < v {r += 1}
	case 3: if abs(r) > abs(v) {r -= v < 0 ? -1 : 1}
	}
	return transmute(f64)(transmute(u64)r | transmute(u64)v & SIGN)
}

// Out-of-range and NaN stores give the integer indefinite value.
fist16 :: #force_inline proc "contextless" (v: f64) -> i16 {
	r := round_cw(v)
	return r >= -32768 && r <= 32767 ? i16(r) : min(i16)
}

fist32 :: #force_inline proc "contextless" (v: f64) -> i32 {
	r := round_cw(v)
	return r >= -2147483648 && r <= 2147483647 ? i32(r) : min(i32)
}

fist64 :: #force_inline proc "contextless" (v: f64) -> i64 {
	r := round_cw(v)
	return r >= -9223372036854775808 && r < 9223372036854775808 ? i64(r) : min(i64)
}

// The conversions truncate; the bounds are on v, before truncation.
fist32_trunc :: #force_inline proc "contextless" (v: f64) -> i32 {
	return v > -2147483649 && v < 2147483648 ? i32(v) : min(i32)
}

fist64_trunc :: #force_inline proc "contextless" (v: f64) -> i64 {
	return v > -9223372036854777856 && v < 9223372036854775808 ? i64(v) : min(i64)
}

// 80-bit extended <-> f64.
ld80 :: proc "contextless" (a: u32) -> f64 {
	m := rd64(a)
	se := rd16(a + 8)
	e := i32(se & 0x7fff)
	neg := se & 0x8000 != 0
	v: f64
	if e == 0 && m == 0 {
		v = 0
	} else if e == 0x7fff {
		v = m << 1 == 0 ? math.inf_f64(1) : math.nan_f64()
	} else {
		v = math.ldexp(f64(m), int(e - 16383 - 63))
	}
	return neg ? -v : v
}

st80 :: proc "contextless" (a: u32, v: f64) {
	b := transmute(u64)v
	neg := b >> 63 != 0
	e := i32((b >> 52) & 0x7ff)
	frac := b & ((1 << 52) - 1)
	m: u64
	ex: u16
	switch {
	case e == 0 && frac == 0:
		m = 0; ex = 0
	case e == 0x7ff:
		m = (1 << 63) | (frac << 11); ex = 0x7fff
	case e == 0:
		// Subnormal f64 is a normal extended value.
		fr, xp := math.frexp(abs(v))
		m = u64(math.ldexp(fr, 64)); ex = u16(i32(xp) - 1 + 16383)
	case:
		m = (1 << 63) | (frac << 11); ex = u16(e - 1023 + 16383)
	}
	wr64(a, m)
	wr16(a + 8, ex | (neg ? 0x8000 : 0))
}

// 108-byte protected-mode fnsave image: 28-byte environment + 8 x 10 bytes.
fnsave :: proc "contextless" (a: u32) {
	f := &cpu.fpu
	wr32(a, u32(f.cw) | 0xffff0000)
	wr32(a + 4, u32(fstsw()) | 0xffff0000)
	tw: u32 = 0
	for i in u32(0) ..< 8 {
		if f.tag & (1 << i) != 0 {tw |= 3 << (i * 2)}
	}
	wr32(a + 8, tw | 0xffff0000)
	for i in u32(3) ..< 7 {wr32(a + i * 4, 0)}
	for i in u32(0) ..< 8 {st80(a + 28 + i * 10, st(i))}
	fninit()
}

frstor :: proc "contextless" (a: u32) {
	f := &cpu.fpu
	f.cw = rd16(a)
	sw := rd16(a + 4)
	f.top = u32(sw >> 11) & 7
	f.sw = sw & ~u16(0x3800)
	tw := rd32(a + 8)
	f.tag = 0
	for i in u32(0) ..< 8 {
		if (tw >> (i * 2)) & 3 == 3 {f.tag |= 1 << i}
	}
	for i in u32(0) ..< 8 {set_st_raw(i, ld80(a + 28 + i * 10))}
}
