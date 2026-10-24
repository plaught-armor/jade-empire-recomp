// SSE/SSE2 subset the recompiler lifts: XMM registers as raw unions, 128-bit
// memory access and the lane shuffles. cpuid reports no SSE, so the CRT's
// SSE2 paths stay unreached; game code uses SSE1 unconditionally.
package x86

import "core:math"

Xmm :: struct #raw_union {
	u: [4]u32,
	f: [4]f32,
	d: [2]f64,
	q: [2]u64,
	w: [8]u16,
}

MXCSR_DEFAULT :: 0x1f80

rd128 :: #force_inline proc "contextless" (a: u32) -> Xmm {
	x: Xmm
	x.q[0] = rd64(a)
	x.q[1] = rd64(a + 8)
	return x
}

wr128 :: #force_inline proc "contextless" (a: u32, x: Xmm) {
	wr64(a, x.q[0])
	wr64(a + 8, x.q[1])
}

// shufps: low two lanes from d, high two from s, each picked by 2 imm bits.
shufps :: proc "contextless" (d, s: Xmm, imm: u32) -> Xmm {
	r: Xmm
	r.u[0] = d.u[imm & 3]
	r.u[1] = d.u[(imm >> 2) & 3]
	r.u[2] = s.u[(imm >> 4) & 3]
	r.u[3] = s.u[(imm >> 6) & 3]
	return r
}

pshufd :: proc "contextless" (s: Xmm, imm: u32) -> Xmm {
	r: Xmm
	for i in 0 ..< u32(4) {
		r.u[i] = s.u[(imm >> (2 * i)) & 3]
	}
	return r
}

// Full-precision reciprocal square root; hardware gives ~12 bits.
rsqrt :: #force_inline proc "contextless" (v: f32) -> f32 {
	return 1 / math.sqrt(v)
}

shl64 :: #force_inline proc "contextless" (v: u64, n: u32) -> u64 {return n > 63 ? 0 : v << n}
shr64 :: #force_inline proc "contextless" (v: u64, n: u32) -> u64 {return n > 63 ? 0 : v >> n}

// cmppd predicate imm (0..7) per f64 lane, all-ones mask when true.
cmppd :: proc "contextless" (a, b: Xmm, pred: u32) -> Xmm {
	r: Xmm
	for i in 0 ..< 2 {
		x, y := a.d[i], b.d[i]
		unord := math.is_nan(x) || math.is_nan(y)
		t: bool
		switch pred & 7 {
		case 0: t = x == y
		case 1: t = x < y
		case 2: t = x <= y
		case 3: t = unord
		case 4: t = !(x == y)
		case 5: t = !(x < y)
		case 6: t = !(x <= y)
		case 7: t = !unord
		}
		r.q[i] = t ? ~u64(0) : 0
	}
	return r
}

// cvttss2si/cvttsd2si: truncation, integer indefinite when out of range.
cvtt_i32 :: #force_inline proc "contextless" (v: f64) -> u32 {
	return u32(fist32_trunc(v))
}
