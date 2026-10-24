// Deterministic sin, cos, tan and exp. Odin's math.sin/cos/exp/pow are LLVM
// intrinsics that call the platform libm (glibc picks an FMA variant at load
// time on CPUs that have it; Windows uses the UCRT), so two co-op peers on
// different CPUs or OSes could round a result differently and desync. These
// are plain f64 code with no FMA, so every build on every x86-64 CPU gives the
// same bits. math.atan2, math.log2, math.sqrt, math.trunc and math.ldexp are
// already pure Odin or exact and stay as they are.
//
// Ported from musl (MIT), which took them from FreeBSD msun / Sun fdlibm:
//   Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.
//   Developed at SunSoft, a Sun Microsystems, Inc. business.
//   Permission to use, copy, modify, and distribute this software is freely
//   granted, provided that this notice is preserved.
// Argument reduction uses only the Cody-Waite medium path; past 2^20·π/2 the
// argument is first taken mod the f64 nearest 2π, which is exact and so
// deterministic, though no longer accurate (the game never gets there).
// WHY: docs/recompiler.md §4
package x86

import "core:math"

@(private = "file")
hi_word :: #force_inline proc "contextless" (x: f64) -> u32 {
	return u32(transmute(u64)x >> 32)
}

// Kernel sin on [-π/4, π/4]; y is the tail of x, iy == 0 when y is 0.
@(private = "file")
k_sin :: proc "contextless" (x, y: f64, iy: int) -> f64 {
	S1 :: -1.66666666666666324348e-01
	S2 :: 8.33333333332248946124e-03
	S3 :: -1.98412698298579493134e-04
	S4 :: 2.75573137070700676789e-06
	S5 :: -2.50507602534068634195e-08
	S6 :: 1.58969099521155010221e-10
	z := x * x
	w := z * z
	r := S2 + z * (S3 + z * S4) + z * w * (S5 + z * S6)
	v := z * x
	if iy == 0 {
		return x + v * (S1 + z * r)
	}
	return x - ((z * (0.5 * y - v * r) - y) - v * S1)
}

// Kernel cos on [-π/4, π/4].
@(private = "file")
k_cos :: proc "contextless" (x, y: f64) -> f64 {
	C1 :: 4.16666666666666019037e-02
	C2 :: -1.38888888888741095749e-03
	C3 :: 2.48015872894767294178e-05
	C4 :: -2.75573143513906633035e-07
	C5 :: 2.08757232129817482790e-09
	C6 :: -1.13596475577881948265e-11
	z := x * x
	w := z * z
	r := z * (C1 + z * (C2 + z * C3)) + w * w * (C4 + z * (C5 + z * C6))
	hz := 0.5 * z
	w = 1.0 - hz
	return w + (((1.0 - w) - hz) + (z * r - x * y))
}

// Kernel tan on [-π/4, π/4]; odd selects -1/tan.
@(private = "file")
k_tan :: proc "contextless" (x_in, y_in: f64, odd: int) -> f64 {
	T := [13]f64 {
		3.33333333333334091986e-01,
		1.33333333333201242699e-01,
		5.39682539762260521377e-02,
		2.18694882948595424599e-02,
		8.86323982359930005737e-03,
		3.59207910759131235356e-03,
		1.45620945432529025516e-03,
		5.88041240820264096874e-04,
		2.46463134818469906812e-04,
		7.81794442939557092300e-05,
		7.14072491382608190305e-05,
		-1.85586374855275456654e-05,
		2.59073051863633712884e-05,
	}
	PIO4 :: 7.85398163397448278999e-01
	PIO4_LO :: 3.06161699786838301793e-17
	x, y := x_in, y_in
	hx := hi_word(x)
	big := hx & 0x7fffffff >= 0x3fe59428 // |x| >= 0.6744
	neg := hx >> 31 != 0
	if big {
		if neg {
			x, y = -x, -y
		}
		x = (PIO4 - x) + (PIO4_LO - y)
		y = 0
	}
	z := x * x
	w := z * z
	r := T[1] + w * (T[3] + w * (T[5] + w * (T[7] + w * (T[9] + w * T[11]))))
	v := z * (T[2] + w * (T[4] + w * (T[6] + w * (T[8] + w * (T[10] + w * T[12])))))
	s := z * x
	r = y + z * (s * (r + v) + y) + s * T[0]
	w = x + r
	if big {
		s = f64(1 - 2 * odd)
		v = s - 2.0 * (x + (r - w * w / (w + s)))
		return -v if neg else v
	}
	if odd == 0 {
		return w
	}
	// -1/(x+r) carried in two parts, as -1/w alone is off by up to 2 ulp.
	w0 := transmute(f64)(transmute(u64)w & 0xffffffff_00000000)
	v = r - (w0 - x)
	a := -1.0 / w
	a0 := transmute(f64)(transmute(u64)a & 0xffffffff_00000000)
	return a0 + a * (1.0 + a0 * w0 + a0 * v)
}

// x mod 2π (the f64 nearest 2π), computed exactly like C fmod: the shifting
// long division of the significands. x is finite with |x| >= 2π.
@(private = "file")
fmod_2pi :: proc "contextless" (x: f64) -> f64 {
	MANT :: u64(1) << 52 - 1
	uy := transmute(u64)f64(2 * math.PI)
	ux := transmute(u64)x
	ex := int(ux >> 52 & 0x7ff)
	ey := int(uy >> 52 & 0x7ff)
	mx := ux & MANT | 1 << 52
	my := uy & MANT | 1 << 52
	for ; ex > ey; ex -= 1 {
		if mx >= my {mx -= my}
		mx <<= 1
	}
	if mx >= my {mx -= my}
	if mx == 0 {return 0 * x}
	for mx >> 52 == 0 {
		mx <<= 1
		ex -= 1
	}
	return transmute(f64)(ux & (1 << 63) | u64(ex) << 52 | mx & MANT)
}

// x = n·π/2 + y0 + y1 with |y0 + y1| <= π/4; returns n mod 4.
@(private = "file")
rem_pio2 :: proc "contextless" (x_in: f64) -> (n: int, y0, y1: f64) {
	TOINT :: 1.5 / 2.220446049250313080847e-16 // 1.5·2^52
	PIO4 :: 7.85398163397448278999e-01
	INVPIO2 :: 6.36619772367581382433e-01
	PIO2_1 :: 1.57079632673412561417e+00
	PIO2_1T :: 6.07710050650619224932e-11
	PIO2_2 :: 6.07710050630396597660e-11
	PIO2_2T :: 2.02226624879595063154e-21
	PIO2_3 :: 2.02226624871116645580e-21
	PIO2_3T :: 8.47842766036889956997e-32
	x := x_in
	if hi_word(x) & 0x7fffffff >= 0x413921fb { 	// |x| >= 2^20·π/2
		x = fmod_2pi(x)
	}
	fn := x * INVPIO2 + TOINT - TOINT
	r := x - fn * PIO2_1
	w := fn * PIO2_1T
	if r - w < -PIO4 {
		fn -= 1
		r = x - fn * PIO2_1
		w = fn * PIO2_1T
	} else if r - w > PIO4 {
		fn += 1
		r = x - fn * PIO2_1
		w = fn * PIO2_1T
	}
	y0 = r - w
	ex := int(hi_word(x) >> 20 & 0x7ff)
	ey := int(hi_word(y0) >> 20 & 0x7ff)
	if ex - ey > 16 {
		t := r
		w = fn * PIO2_2
		r = t - w
		w = fn * PIO2_2T - ((t - r) - w)
		y0 = r - w
		ey = int(hi_word(y0) >> 20 & 0x7ff)
		if ex - ey > 49 {
			t = r
			w = fn * PIO2_3
			r = t - w
			w = fn * PIO2_3T - ((t - r) - w)
			y0 = r - w
		}
	}
	y1 = (r - y0) - w
	n = int(fn) & 3
	return
}

sin_f64 :: proc "contextless" (x: f64) -> f64 {
	ix := hi_word(x) & 0x7fffffff
	if ix <= 0x3fe921fb { 	// |x| ~<= π/4
		if ix < 0x3e500000 {return x} 	// |x| < 2^-26
		return k_sin(x, 0, 0)
	}
	if ix >= 0x7ff00000 {return x - x} 	// inf or NaN
	n, y0, y1 := rem_pio2(x)
	switch n {
	case 0:
		return k_sin(y0, y1, 1)
	case 1:
		return k_cos(y0, y1)
	case 2:
		return -k_sin(y0, y1, 1)
	}
	return -k_cos(y0, y1)
}

cos_f64 :: proc "contextless" (x: f64) -> f64 {
	ix := hi_word(x) & 0x7fffffff
	if ix <= 0x3fe921fb {
		if ix < 0x3e46a09e {return 1} 	// |x| < 2^-27·√2
		return k_cos(x, 0)
	}
	if ix >= 0x7ff00000 {return x - x}
	n, y0, y1 := rem_pio2(x)
	switch n {
	case 0:
		return k_cos(y0, y1)
	case 1:
		return -k_sin(y0, y1, 1)
	case 2:
		return -k_cos(y0, y1)
	}
	return k_sin(y0, y1, 1)
}

tan_f64 :: proc "contextless" (x: f64) -> f64 {
	ix := hi_word(x) & 0x7fffffff
	if ix <= 0x3fe921fb {
		if ix < 0x3e400000 {return x} 	// |x| < 2^-27
		return k_tan(x, 0, 0)
	}
	if ix >= 0x7ff00000 {return x - x}
	n, y0, y1 := rem_pio2(x)
	return k_tan(y0, y1, n & 1)
}

exp_f64 :: proc "contextless" (x_in: f64) -> f64 {
	LN2_HI :: 6.93147180369123816490e-01
	LN2_LO :: 1.90821492927058770002e-10
	INVLN2 :: 1.44269504088896338700e+00
	P1 :: 1.66666666666666019037e-01
	P2 :: -2.77777777770155933842e-03
	P3 :: 6.61375632143793436117e-05
	P4 :: -1.65339022054652515390e-06
	P5 :: 4.13813679705723846039e-08
	x := x_in
	if x != x {return x + x}
	hx := hi_word(x)
	neg := hx >> 31 != 0
	hx &= 0x7fffffff
	if hx >= 0x4086232b { 	// |x| >= 708.39
		if x > 709.782712893383973096 {return math.inf_f64(1)} // overflow
		if x < -745.13321910194110842 {return 0}
	}
	hi, lo: f64
	k: int
	if hx > 0x3fd62e42 { 	// |x| > ln2/2
		if hx >= 0x3ff0a2b2 { 	// |x| >= 1.5·ln2
			k = int(INVLN2 * x + (-0.5 if neg else 0.5))
		} else {
			k = -1 if neg else 1
		}
		hi = x - f64(k) * LN2_HI // exact
		lo = f64(k) * LN2_LO
		x = hi - lo
	} else if hx > 0x3e300000 { 	// |x| > 2^-28
		hi = x
	} else {
		return 1 + x
	}
	xx := x * x
	c := x - xx * (P1 + xx * (P2 + xx * (P3 + xx * (P4 + xx * P5))))
	y := 1 + (x * c / (2 - c) - lo + hi)
	if k == 0 {return y}
	return math.ldexp(y, k)
}

sin_f32 :: proc "contextless" (x: f32) -> f32 {return f32(sin_f64(f64(x)))}
cos_f32 :: proc "contextless" (x: f32) -> f32 {return f32(cos_f64(f64(x)))}
tan_f32 :: proc "contextless" (x: f32) -> f32 {return f32(tan_f64(f64(x)))}
exp_f32 :: proc "contextless" (x: f32) -> f32 {return f32(exp_f64(f64(x)))}

sin :: proc {
	sin_f32,
	sin_f64,
}
cos :: proc {
	cos_f32,
	cos_f64,
}
tan :: proc {
	tan_f32,
	tan_f64,
}
exp :: proc {
	exp_f32,
	exp_f64,
}

// x87 f2xm1: 2^x - 1 for |x| <= 1.
f2xm1 :: proc "contextless" (x: f64) -> f64 {
	return exp_f64(x * math.LN2) - 1
}

// x87 fscale: a·2^trunc(b). The exponent clamps so the int conversion stays
// defined; anything past ±2200 already saturates to 0 or inf.
fscale :: proc "contextless" (a, b: f64) -> f64 {
	if b != b {return a + b}
	return math.ldexp(a, int(clamp(math.trunc(b), -2200, 2200)))
}
