// Local copies of x86's x87 helpers, so they inline here: under
// -use-separate-modules a #force_inline proc from another module stays an
// out-of-line call. Each matches its x86/fpu.odin original exactly.
// WHY: docs/recompiler.md §8
package native

import "../x86"

@(private)
st_phys :: #force_inline proc "contextless" (j: u32) -> f64 {
	#no_bounds_check return x86.cpu.fpu.st[j & 7]
}

@(private)
set_st_phys :: #force_inline proc "contextless" (j: u32, v: f64) {
	#no_bounds_check x86.cpu.fpu.st[j & 7] = v
}

// Tag-word bits m for registers relative to top t.
@(private)
rot8 :: #force_inline proc "contextless" (m: u8, t: u32) -> u8 {
	return u8((u32(m) << (t & 7) | u32(m) >> (8 - (t & 7))) & 0xff)
}

@(private)
round_pc :: #force_inline proc "contextless" (single: bool, v: f64) -> f64 {
	return single ? round_single(v) : v
}

@(private)
round_single :: #force_inline proc "contextless" (v: f64) -> f64 {
	b := transmute(u64)v
	if (b >> 52) & 0x7ff == 0x7ff {return v}
	half := u64(1) << (x86.SINGLE_DROP - 1)
	b += half - 1 + ((b >> x86.SINGLE_DROP) & 1)
	return transmute(f64)(b &~ (u64(1) << x86.SINGLE_DROP - 1))
}

// fld dword, as the recompiled body widens it.
@(private)
lx :: #force_inline proc "contextless" (a: u32) -> f64 {return f64(lf(a))}

// fstp dword, as the recompiled body narrows it.
@(private)
sx :: #force_inline proc "contextless" (a: u32, v: f64) {sf(a, f32(v))}

// frndint under the control word's rounding mode.
@(private)
round_cw :: #force_inline proc "contextless" (v: f64) -> f64 {
	TWO52 :: f64(1 << 52)
	SIGN :: u64(1) << 63
	if !(abs(v) < TWO52) {return v}
	s := v < 0 ? -TWO52 : TWO52
	r := (v + s) - s
	switch (x86.cpu.fpu.cw >> 10) & 3 {
	case 1: if r > v {r -= 1}
	case 2: if r < v {r += 1}
	case 3: if abs(r) > abs(v) {r -= v < 0 ? -1 : 1}
	}
	return transmute(f64)(transmute(u64)r | transmute(u64)v & SIGN)
}

// fistp qword; out of range and NaN give the integer indefinite.
@(private)
fist64 :: #force_inline proc "contextless" (v: f64) -> i64 {
	r := round_cw(v)
	return r >= -9223372036854775808 && r < 9223372036854775808 ? i64(r) : min(i64)
}

// fnstsw: sw with top in bits 11-13.
@(private)
fstsw :: #force_inline proc "contextless" () -> u16 {
	f := &x86.cpu.fpu
	return (f.sw & ~u16(0x3800)) | u16(f.top << 11)
}

// One x87 operation of a formula both paths of a span share: the f32 rule's
// f32 operation, or the recompiled body's f64 one rounded under single
// precision control s.
@(private)
xadd :: #force_inline proc "contextless" (s: bool, a, b: $T) -> T {
	when T == f32 {return a + b} else {return round_pc(s, a + b)}
}

@(private)
xsub :: #force_inline proc "contextless" (s: bool, a, b: $T) -> T {
	when T == f32 {return a - b} else {return round_pc(s, a - b)}
}

@(private)
xmul :: #force_inline proc "contextless" (s: bool, a, b: $T) -> T {
	when T == f32 {return a * b} else {return round_pc(s, a * b)}
}

// An fstp dword and the fld dword that reloads it.
@(private)
xspill :: #force_inline proc "contextless" (v: $T) -> T {
	when T == f32 {return v} else {return f64(f32(v))}
}

// fadd st, st: the value doubled.
@(private)
xdbl :: #force_inline proc "contextless" (s: bool, v: $T) -> T {return xadd(s, v, v)}

// An fld dword: the f32 itself, or widened.
@(private)
xl :: #force_inline proc "contextless" (a: u32, $T: typeid) -> T {
	when T == f32 {return lf(a)} else {return lx(a)}
}
