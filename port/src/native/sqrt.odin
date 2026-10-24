// Math_SqrtNewton (0x5c0320): sqrt(x) for a double, from a bit-trick
// estimate of 1/sqrt(x) refined by four Newton steps. WHY: docs/recompiler.md §8
package native

import "../x86"

guest_sqrt_newton: x86.Func

SQRT_HALF :: 0x006e2900 // f64 0.5
SQRT_THREE_HALVES :: 0x00708b60 // f64 1.5
SQRT_MAGIC :: 0xbfcd4600 // the estimate's high dword is (SQRT_MAGIC - hi(x)) >> 1
F64_EXP_HI :: 0x7ff00000
SQRT_F32_MIN :: 1.0 / (1 << 100) // the fast path's x range: every step stays a normal single
SQRT_F32_MAX :: f64(1 << 100)

// cdecl(x: f64) -> st(0). y0 is x with its high dword replaced by the
// estimate's, which the guest writes over x's argument slot (and leaves in
// eax; ecx = hi(x)). h = x / 2, then four times t = 1.5 - (h y) y, y = y t
// (t y the last time); the result is x y. Every operation is the recompiled
// body's: f64, rounded under single precision control as round_pc rounds, in
// its operand order, so any precision control, register state and value give
// its bits. The three registers the steps used are left empty holding the
// third t, y4 and y3.
Math_SqrtNewton_005c0320 :: proc() {
	c := &x86.cpu
	e := c.esp
	if mode != .On {
		if mode == .Check {
			check(0x005c0320, Math_SqrtNewton_005c0320, guest_sqrt_newton, {{e + 0x4, 2}})
			return
		}
		guest_sqrt_newton()
		return
	}
	f := &c.fpu
	s := f.cw & x86.PC_MASK == 0
	tp := f.top
	x := lf64(e + 0x4)
	hi := ld(e + 0x8)
	yhi := (SQRT_MAGIC - hi) >> 1
	st(e + 0x8, yhi)
	tt, y4, y3, r := sqrt_newton(s, x, lf64(e + 0x4))
	set_st_phys(tp + 4, tt)
	set_st_phys(tp + 5, y4)
	set_st_phys(tp + 6, y3)
	set_st_phys(tp + 7, r)
	f.tag = f.tag &~ rot8(0xf0, tp) | rot8(0x70, tp)
	f.top = (tp + 7) & 7
	c.eax, c.ecx = yhi, hi
	c.esp = e + 4
}

// The steps from x and y0, as the recompiled body rounds them: the third t,
// y4, y3 and x y4. Under single precision every operand after the first step
// is a single, so f32 arithmetic gives the same bits (a double result rounded
// to single equals the single result for +, - and *); only y0 and x are full
// doubles, and their products are formed in f64 and narrowed.
@(private)
sqrt_newton :: #force_inline proc "contextless" (s: bool, x, y0: f64) -> (t, y4, y3, r: f64) {
	k := lf64(SQRT_THREE_HALVES)
	if s && x >= SQRT_F32_MIN && x <= SQRT_F32_MAX && f64(f32(k)) == k {
		k := f32(k)
		h := f32(lf64(SQRT_HALF) * x)
		t := k - f32(f64(f32(f64(h) * y0)) * y0)
		y := f32(y0 * f64(t))
		for _ in 0 ..< 2 {
			t = k - h * y * y
			y = y * t
		}
		y4 := (k - h * y * y) * y
		return f64(t), f64(y4), f64(y), f64(f32(x * f64(y4)))
	}
	h := round_pc(s, lf64(SQRT_HALF) * x)
	y := y0
	for _ in 0 ..< 3 {
		t = round_pc(s, k - round_pc(s, round_pc(s, h * y) * y))
		y = round_pc(s, y * t)
	}
	y4 = round_pc(s, round_pc(s, k - round_pc(s, round_pc(s, h * y) * y)) * y)
	return t, y4, y, round_pc(s, x * y4)
}
