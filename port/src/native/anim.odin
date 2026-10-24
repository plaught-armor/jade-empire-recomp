// AnimTrack_FindKey (0x5ffa00): the key interval of an animation track that
// holds a time, by binary search over its u16 key frames. Integer work plus a
// few x87 operations replayed under precision control, so no f32 rule is
// needed. WHY: docs/recompiler.md §8
package native

import "../x86"

guest_anim_find_key: x86.Func

ANIM_BIAS :: 0x006e2360 // f32 1e-5, subtracted from the time
ANIM_FPS :: 0x006e2f50 // f32 256, key frames per second
ANIM_SPF :: 0x0070c0cc // f32 1/256
ANIM_EPS :: 0x006e4664 // f32 1e-10, the shortest interval interpolated

// thiscall(track, time: f32, anim, idx: ^u32, frac: ^f32), ret 0x10. The key
// frames are u16s at [anim + 0x4c] + 2 * u16[track + 8], u16[track + 6] of
// them; k = ftol2((time - 1e-5) * 256), low 16 bits. k at or before key 0, or
// no keys: idx 0, frac 1. k after the last key: idx n, frac 1. Else idx is
// the first key at or after k with its predecessor before it, and frac is
// (k - key[idx - 1]) / (key[idx] - key[idx - 1]), or 0 when the interval is
// under 1e-10 seconds. ecx and edx are left as ftol2 and each exit leave them;
// the x87 registers pushed are left empty holding their last values.
AnimTrack_FindKey_005ffa00 :: proc() {
	c := &x86.cpu
	if mode == .Check {
		check(0x005ffa00, anim_find_key_native, guest_anim_find_key, {{ld(c.esp + 0xc), 1}, {ld(c.esp + 0x10), 1}})
		return
	}
	if mode == .Off {
		guest_anim_find_key()
		return
	}
	anim_find_key_native()
}

@(private = "file")
anim_find_key_native :: proc() {
	c := &x86.cpu
	e := c.esp
	track := c.ecx
	anim := ld(e + 0x8)
	idxp, fracp := ld(e + 0xc), ld(e + 0x10)
	c.esp = e + 0x14
	single := c.fpu.cw & x86.PC_MASK == 0
	t := c.fpu.top
	x := round_pc(single, f64(lf(e + 0x4)) - f64(lf(ANIM_BIAS)))
	keys := ld(anim + 0x4c) + ld16(track + 0x8) * 2
	x = round_pc(single, x * f64(lf(ANIM_FPS)))
	set_st_phys(t + 7, x)
	c.fpu.tag &~= rot8(0x80, t)
	c.fpu.top = (t + 7) & 7
	c.ecx = anim
	ftol2_body()
	k := c.eax & 0xffff
	n := ld16(track + 0x6)
	if n == 0 || ld16(keys) >= k {
		st(idxp, 0)
		st(fracp, 0x3f800000)
		c.eax = idxp
		return
	}
	if ld16(keys + n * 2 - 2) < k {
		st(idxp, n)
		st(fracp, 0x3f800000)
		c.eax, c.edx = n, fracp
		return
	}
	lo, hi := i32(1), i32(n) - 1
	for hi > lo {
		m := (hi + lo) >> 1
		if ld16(keys + u32(m) * 2) < k {
			lo = m + 1
		} else if ld16(keys + u32(m) * 2 - 2) < k {
			lo = m
			break
		} else {
			hi = m
		}
	}
	idx := u32(lo)
	st(idxp, idx)
	k0 := ld16(keys + idx * 2 - 2)
	k1 := ld16(keys + idx * 2)
	span := round_pc(single, f64(i32(k1 - k0)) * f64(lf(ANIM_SPF)))
	c.fpu.sw = c.fpu.sw &~ (C0 | C2 | C3) | fcom_bits(span, f64(lf(ANIM_EPS)))
	set_st_phys(t + 7, span)
	c.fpu.tag &~= rot8(0x80, t)
	c.fpu.top = (t + 7) & 7
	c.eax = idxp & 0xffff0000 | u32(fstsw())
	if c.fpu.sw & C0 != 0 {
		st(fracp, 0)
		c.edx = fracp
		c.fpu.tag |= rot8(0x80, t)
		c.fpu.top = t
		return
	}
	off := k - k0
	frames := round_pc(single, span * f64(lf(ANIM_FPS)))
	frac := round_pc(single, f64(i32(off)) / frames)
	set_st_phys(t + 6, frames)
	set_st_phys(t + 7, frac)
	st(fracp, transmute(u32)f32(frac))
	c.fpu.tag |= rot8(0xc0, t)
	c.fpu.top = t
	c.eax, c.edx = off, k0
}
