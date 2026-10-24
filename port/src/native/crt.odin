// ftol2 (0x6b32a0): the MSVC CRT's float to int64 conversion, truncating
// st(0) without touching the control word. Integer and x87 work only; the
// stack scratch it writes lies below the caller's esp. WHY: docs/recompiler.md §8
package native

import "../x86"

guest_ftol2: x86.Func

// i = st(0) rounded by the control word; edx:eax = i, corrected by one toward
// zero when the rounding went away from it. The correction reads the sign of
// st(0) as an f32 (edx's first load) and the f32 bits of st(0) - i: adding
// 0x7fffffff to them carries exactly when the difference points toward zero.
// i = 0 with a zero high dword skips the correction. Pops st(0); fld and fild
// leave st(0) - i (or st(0)) and i in the two freed registers, as the guest
// leaves them. ecx holds the corrected difference bits, unchanged on the zero
// path.
ftol2_006b32a0 :: proc() {
	if mode == .Check {
		check(0x006b32a0, ftol2_native, guest_ftol2, {})
		return
	}
	if mode == .Off {
		guest_ftol2()
		return
	}
	ftol2_native()
}

@(private = "file")
ftol2_native :: proc() {
	ftol2_body()
	x86.cpu.esp += 4
}

// ftol2 without its return: for native callers, whose call is inlined.
@(private)
ftol2_body :: #force_inline proc "contextless" () {
	c := &x86.cpu
	t := c.fpu.top
	v := st_phys(t)
	i := fist64(v)
	fi := f64(i)
	lo, hi := u32(u64(i)), u32(u64(i) >> 32)
	set_st_phys(t + 7, fi)
	c.fpu.tag |= rot8(0x81, t)
	c.fpu.top = (t + 1) & 7
	if lo == 0 && hi & 0x7fffffff == 0 {
		c.eax, c.edx = 0, hi
		return
	}
	d := round_pc(c.fpu.cw & x86.PC_MASK == 0, v - fi)
	set_st_phys(t, d)
	bits := transmute(u32)f32(d)
	if i32(transmute(u32)f32(v)) < 0 {
		bits ~= 0x80000000
		ecx := bits + 0x7fffffff
		cf := u32(ecx < bits)
		eax := lo + cf
		c.ecx, c.eax, c.edx = ecx, eax, hi + u32(eax < lo)
		return
	}
	ecx := bits + 0x7fffffff
	bw := u32(ecx < bits)
	c.ecx, c.eax, c.edx = ecx, lo - bw, hi - u32(lo < bw)
}

guest_ceil: x86.Func

CEIL_CW :: 0x00769f74 // u16: the control word ceil runs under, rounding up
CEIL_ONE :: 0x006e3568 // f64 the SNaN path adds, quieting it
CEIL_QNAN :: 0x006beed9 // _handle_qnan1: cdecl(op, x, old cw) -> st(0)
CEIL_EXCEPT :: 0x006bef2b // _except1: cdecl(flags, op, x, r, old cw) -> st(0)
CEIL_RET_QNAN :: 0x006ba946
CEIL_RET_EXCEPT :: 0x006ba9bc

// ceil (0x6ba8f0): cdecl(x: f64) -> st(0). Through _ctrlfp (0x6bf14c) the
// guest sets the control word to CEIL_CW, rounds x with frndint, restores
// the old word and returns r = round(x). fucompp of r against x leaves the
// status bits; the two registers it popped hold x and r, and the push of the
// result takes the first back, so r is left in st(0) and in the empty
// register below it. eax = the sign-extended CEIL_CW (_ctrlfp's return),
// ecx = hi(x)'s top half over the old word (the guest's last pop). An
// infinity restores the word and returns x, edx = 0 (_fpclass's). A NaN, and
// an inexact result with the precision exception unmasked, go to the CRT's
// error helpers with the guest's frame and registers, still under CEIL_CW.
ceil_006ba8f0 :: proc() {
	c := &x86.cpu
	if mode != .On {
		if mode == .Check {
			check(0x006ba8f0, ceil_006ba8f0, guest_ceil, {})
			return
		}
		guest_ceil()
		return
	}
	e := c.esp
	lo, hi := ld(e + 4), ld(e + 8)
	old, cw := c.fpu.cw, u16(ld(CEIL_CW))
	x := transmute(f64)(u64(hi) << 32 | u64(lo))
	c.fpu.cw = cw
	t := c.fpu.top
	if hi & F64_EXP_HI == F64_EXP_HI {
		ceil_special(e, x, hi, u32(old))
		return
	}
	r := round_pc(cw & x86.PC_MASK == 0, round_cw(x))
	sw := fcom_bits(r, x)
	if sw != C3 && old & 0x20 == 0 {
		ceil_frame(e, u32(old))
		st(e - 12, lo32(r))
		st(e - 8, hi32(r))
		set_st_phys(t + 7, x)
		set_st_phys(t + 6, r)
		c.fpu.tag |= rot8(0xc0, t)
		c.fpu.sw = c.fpu.sw &~ (C0 | C2 | C3) | sw
		c.eax = ld(e + 0xa) & 0xffff0000 | u32(fstsw())
		ceil_except(e, 0x10, x, r, hi)
		return
	}
	c.fpu.cw = old
	set_st_phys(t + 7, r)
	set_st_phys(t + 6, r)
	c.fpu.tag = (c.fpu.tag | rot8(0x40, t)) &~ rot8(0x80, t)
	c.fpu.top = (t + 7) & 7
	c.fpu.sw = c.fpu.sw &~ (C0 | C2 | C3) | sw
	c.eax = u32(i32(i16(cw)))
	c.ecx = hi & 0xffff0000 | u32(old)
	c.esp = e + 4
}

@(private = "file")
lo32 :: #force_inline proc "contextless" (v: f64) -> u32 {return u32(transmute(u64)v)}

@(private = "file")
hi32 :: #force_inline proc "contextless" (v: f64) -> u32 {return u32(transmute(u64)v >> 32)}

// An exponent of all ones, classified as _fpclass (0x6bf01e) does: 1 and 2
// the infinities, 3 a quiet NaN, 4 a signaling one.
@(private = "file")
ceil_special :: proc(e: u32, x: f64, hi, old: u32) {
	c := &x86.cpu
	t := c.fpu.top
	lo := lo32(x)
	set_st_phys(t + 7, x)
	c.edx = 0
	if lo == 0 && hi & 0x7fffffff == 0x7ff00000 {
		c.eax = u32(i32(i16(c.fpu.cw)))
		c.fpu.cw = u16(old)
		c.fpu.tag &~= rot8(0x80, t)
		c.fpu.top = (t + 7) & 7
		c.ecx = hi & 0xffff0000 | old
		c.esp = e + 4
		return
	}
	ceil_frame(e, old)
	c.fpu.tag |= rot8(0x80, t)
	if hi & 0x7ff80000 == 0x7ff80000 {
		st(e - 32, lo)
		st(e - 28, hi)
		st(e - 36, 0xc)
		st(e - 40, CEIL_RET_QNAN)
		c.eax, c.ecx = 3, hi
		c.esp = e - 40
		call_guest(CEIL_QNAN)
		c.esp += 0x10
		ceil_leave()
		return
	}
	q := round_pc(c.fpu.cw & x86.PC_MASK == 0, x + lf64(CEIL_ONE))
	c.eax = 4
	ceil_except(e, 8, x, q, hi)
}

// The pushes every error path makes: ebp, ecx twice, ebx, esi, then the old
// word sign-extended as _ctrlfp returned it.
@(private = "file")
ceil_frame :: #force_inline proc "contextless" (e, old: u32) {
	c := &x86.cpu
	st(e - 4, c.ebp)
	st(e - 8, c.ecx)
	st(e - 12, c.ecx)
	st(e - 16, c.ebx)
	st(e - 20, c.esi)
	st(e - 24, u32(i32(i16(old))))
	c.ebp = e - 4
	c.ebx = u32(i32(i16(old)))
	c.esi = 0xffff
}

// _except1(flags, 0xc, x, r, old) and the guest's epilogue.
@(private = "file")
ceil_except :: proc(e, flags: u32, x, r: f64, hi: u32) {
	c := &x86.cpu
	st(e - 32, lo32(r))
	st(e - 28, hi32(r))
	st(e - 40, lo32(x))
	st(e - 36, hi32(x))
	st(e - 44, 0xc)
	st(e - 48, flags)
	st(e - 52, CEIL_RET_EXCEPT)
	c.ecx = hi
	c.esp = e - 52
	call_guest(CEIL_EXCEPT)
	c.esp += 0x1c
	ceil_leave()
}

// pop esi; pop ebx; leave; ret.
@(private = "file")
ceil_leave :: #force_inline proc "contextless" () {
	c := &x86.cpu
	c.esi = ld(c.esp)
	c.ebx = ld(c.esp + 4)
	c.esp = c.ebp
	c.ebp = ld(c.esp)
	c.esp += 8
}
