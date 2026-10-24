// Integer helpers called from generated code: flags register, rotates,
// string instructions, cpuid.
package x86

import "base:intrinsics"

parity :: #force_inline proc "contextless" (v: u8) -> bool {
	x := v ~ (v >> 4)
	x ~= x >> 2
	x ~= x >> 1
	return x & 1 == 0
}

get_eflags :: proc "contextless" () -> u32 {
	c := &cpu
	f: u32 = 0x202 // reserved bit 1, IF
	if c.cf {f |= 0x1}
	if c.pf {f |= 0x4}
	if c.af {f |= 0x10}
	if c.zf {f |= 0x40}
	if c.sf {f |= 0x80}
	if c.df {f |= 0x400}
	if c.of {f |= 0x800}
	return f
}

set_eflags :: proc "contextless" (f: u32) {
	c := &cpu
	c.cf = f & 0x1 != 0
	c.pf = f & 0x4 != 0
	c.af = f & 0x10 != 0
	c.zf = f & 0x40 != 0
	c.sf = f & 0x80 != 0
	c.df = f & 0x400 != 0
	c.of = f & 0x800 != 0
}

sahf :: proc "contextless" () {
	c := &cpu
	ah := (c.eax >> 8) & 0xff
	c.cf = ah & 0x1 != 0
	c.pf = ah & 0x4 != 0
	c.af = ah & 0x10 != 0
	c.zf = ah & 0x40 != 0
	c.sf = ah & 0x80 != 0
}

lahf :: proc "contextless" () {
	c := &cpu
	c.eax = (c.eax & 0xffff00ff) | ((get_eflags() & 0xd7) << 8)
}

pushad :: proc "contextless" () {
	c := &cpu
	sp := c.esp
	push32(c.eax); push32(c.ecx); push32(c.edx); push32(c.ebx)
	push32(sp); push32(c.ebp); push32(c.esi); push32(c.edi)
}

popad :: proc "contextless" () {
	c := &cpu
	c.edi = pop32(); c.esi = pop32(); c.ebp = pop32(); _ = pop32()
	c.ebx = pop32(); c.edx = pop32(); c.ecx = pop32(); c.eax = pop32()
}

// Reports a Pentium-class CPU without MMX/SSE, so the CRT keeps to x87.
// WHY: docs/recompiler.md §5
cpuid :: proc "contextless" () {
	c := &cpu
	switch c.eax {
	case 0:
		c.eax = 1
		c.ebx = 0x756e6547 // "GenuineIntel"
		c.edx = 0x49656e69
		c.ecx = 0x6c65746e
	case 1:
		c.eax = 0x543
		c.ebx = 0
		c.ecx = 0
		c.edx = 0x1 // FPU only
	case:
		c.eax = 0; c.ebx = 0; c.ecx = 0; c.edx = 0
	}
}

rol8 :: #force_inline proc "contextless" (a: u8, n: u32) -> u8 {k := n & 7; return (a << k) | (a >> ((8 - k) & 7))}
ror8 :: #force_inline proc "contextless" (a: u8, n: u32) -> u8 {k := n & 7; return (a >> k) | (a << ((8 - k) & 7))}
rol16 :: #force_inline proc "contextless" (a: u16, n: u32) -> u16 {k := n & 15; return (a << k) | (a >> ((16 - k) & 15))}
ror16 :: #force_inline proc "contextless" (a: u16, n: u32) -> u16 {k := n & 15; return (a >> k) | (a << ((16 - k) & 15))}
rol32 :: #force_inline proc "contextless" (a: u32, n: u32) -> u32 {k := n & 31; return (a << k) | (a >> ((32 - k) & 31))}
ror32 :: #force_inline proc "contextless" (a: u32, n: u32) -> u32 {k := n & 31; return (a >> k) | (a << ((32 - k) & 31))}

// Rotate through carry, one bit per step; counts are mod 9/17/33.
rcl8 :: proc "contextless" (a: u8, n: u32) -> u8 {return u8(rc_left(u32(a), n % 9, 8))}
rcr8 :: proc "contextless" (a: u8, n: u32) -> u8 {return u8(rc_right(u32(a), n % 9, 8))}
rcl16 :: proc "contextless" (a: u16, n: u32) -> u16 {return u16(rc_left(u32(a), n % 17, 16))}
rcr16 :: proc "contextless" (a: u16, n: u32) -> u16 {return u16(rc_right(u32(a), n % 17, 16))}
rcl32 :: proc "contextless" (a: u32, n: u32) -> u32 {return rc_left(a, n, 32)}
rcr32 :: proc "contextless" (a: u32, n: u32) -> u32 {return rc_right(a, n, 32)}

rc_left :: proc "contextless" (a: u32, n: u32, bits: u32) -> u32 {
	v := a
	top := u32(1) << (bits - 1)
	for _ in 0 ..< n {
		out := v & top != 0
		v = (v << 1) | (cpu.cf ? 1 : 0)
		cpu.cf = out
	}
	if bits < 32 {v &= (u32(1) << bits) - 1}
	cpu.of = (v & top != 0) != cpu.cf
	return v
}

rc_right :: proc "contextless" (a: u32, n: u32, bits: u32) -> u32 {
	v := a
	top := u32(1) << (bits - 1)
	for _ in 0 ..< n {
		out := v & 1 != 0
		v = (v >> 1) | (cpu.cf ? top : 0)
		cpu.cf = out
	}
	cpu.of = ((v ~ (v << 1)) & top) != 0
	return v
}

Rep :: enum {
	None,
	Rep,   // repeat while ecx != 0
	Repe,  // and while ZF
	Repne, // and while !ZF
}

step :: #force_inline proc "contextless" (size: u32) -> u32 {
	return cpu.df ? 0 - size : size
}

rd_n :: #force_inline proc "contextless" (a: u32, size: u32) -> u32 {
	switch size {
	case 1: return u32(rd8(a))
	case 2: return u32(rd16(a))
	}
	return rd32(a)
}

wr_n :: #force_inline proc "contextless" (a: u32, size: u32, v: u32) {
	switch size {
	case 1: wr8(a, u8(v))
	case 2: wr16(a, u16(v))
	case: wr32(a, v)
	}
}

// A rep string run of n bytes from a moves forward through guest memory
// without wrapping: the bulk paths below apply. WHY: docs/recompiler.md §2
rep_bulk :: #force_inline proc "contextless" (a: u32, n: u64) -> bool {
	return !cpu.df && !WATCH && u64(a) + n <= MEM_SIZE
}

movs :: proc "contextless" (size: u32, mode: Rep) {
	c := &cpu
	d := step(size)
	if mode == .None {
		wr_n(c.edi, size, rd_n(c.esi, size))
		c.esi += d; c.edi += d
		return
	}
	si, di, n := c.esi, c.edi, c.ecx
	bytes := u64(n) * u64(size)
	// Element by element, a destination just above the source repeats the
	// source's first elements; memmove would not.
	if rep_bulk(si, bytes) && rep_bulk(di, bytes) && (di <= si || u64(di) >= u64(si) + bytes) {
		intrinsics.mem_copy(&guest()[di], &guest()[si], int(bytes))
		c.esi, c.edi, c.ecx = si + u32(bytes), di + u32(bytes), 0
		return
	}
	for _ in 0 ..< n {
		wr_n(di, size, rd_n(si, size))
		si += d; di += d
	}
	c.esi, c.edi, c.ecx = si, di, 0
}

stos :: proc "contextless" (size: u32, mode: Rep) {
	c := &cpu
	d := step(size)
	if mode == .None {
		wr_n(c.edi, size, c.eax)
		c.edi += d
		return
	}
	di, n, v := c.edi, c.ecx, c.eax
	bytes := u64(n) * u64(size)
	if rep_bulk(di, bytes) {
		p := &guest()[di]
		switch size {
		case 1: for i in 0 ..< uintptr(n) {(^u8)(uintptr(p) + i)^ = u8(v)}
		case 2: for i in 0 ..< uintptr(n) {intrinsics.unaligned_store((^u16)(uintptr(p) + 2 * i), u16(v))}
		case: for i in 0 ..< uintptr(n) {intrinsics.unaligned_store((^u32)(uintptr(p) + 4 * i), v)}
		}
		c.edi, c.ecx = di + u32(bytes), 0
		return
	}
	for _ in 0 ..< n {
		wr_n(di, size, v)
		di += d
	}
	c.edi, c.ecx = di, 0
}

lods :: proc "contextless" (size: u32, mode: Rep) {
	c := &cpu
	d := step(size)
	n := mode == .None ? 1 : c.ecx
	for _ in 0 ..< n {
		v := rd_n(c.esi, size)
		switch size {
		case 1: c.eax = (c.eax & 0xffffff00) | v
		case 2: c.eax = (c.eax & 0xffff0000) | v
		case: c.eax = v
		}
		c.esi += d
	}
	if mode != .None {c.ecx = 0}
}

// Flags of a - b at the given width.
cmp_flags :: proc "contextless" (a, b, size: u32) {
	c := &cpu
	bits := size * 8
	mask: u32 = bits == 32 ? 0xffffffff : (u32(1) << bits) - 1
	sign := u32(1) << (bits - 1)
	r := (a - b) & mask
	c.cf = a < b
	c.zf = r == 0
	c.sf = r & sign != 0
	c.of = ((a ~ b) & (a ~ r) & sign) != 0
	c.af = ((a ~ b ~ r) & 0x10) != 0
	c.pf = parity(u8(r))
}

cmps :: proc "contextless" (size: u32, mode: Rep) {
	c := &cpu
	d := step(size)
	if mode == .None {
		cmp_flags(rd_n(c.esi, size), rd_n(c.edi, size), size)
		c.esi += d; c.edi += d
		return
	}
	for c.ecx != 0 {
		cmp_flags(rd_n(c.esi, size), rd_n(c.edi, size), size)
		c.esi += d; c.edi += d; c.ecx -= 1
		if (mode == .Repe) != c.zf {break}
	}
}

scas :: proc "contextless" (size: u32, mode: Rep) {
	c := &cpu
	d := step(size)
	mask: u32 = size == 4 ? 0xffffffff : (u32(1) << (size * 8)) - 1
	if mode == .None {
		cmp_flags(c.eax & mask, rd_n(c.edi, size), size)
		c.edi += d
		return
	}
	for c.ecx != 0 {
		cmp_flags(c.eax & mask, rd_n(c.edi, size), size)
		c.edi += d; c.ecx -= 1
		if (mode == .Repe) != c.zf {break}
	}
}
