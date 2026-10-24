// Guest memory: one 4 GiB reservation, so every u32 guest address is a valid
// offset. The low 64 KiB stay inaccessible to fault on null-pointer use.
package x86

import "base:intrinsics"

MEM_SIZE :: 1 << 32
NULL_GUARD :: 0x10000
// Host address of guest address 0. Fixed, so the accessors below fold it into
// each access instead of loading a base pointer that any store may overwrite.
// WHY: docs/recompiler.md §2
MEM_BASE :: uintptr(0x100_0000_0000)

mem: [^]u8 // MEM_BASE, for code that slices guest memory

guest :: #force_inline proc "contextless" () -> [^]u8 {
	return ([^]u8)(rawptr(MEM_BASE))
}

// mem_init (mem_linux.odin, mem_windows.odin) reserves the 4 GiB at MEM_BASE
// and commits all of it above NULL_GUARD.

ptr :: #force_inline proc "contextless" (a: u32) -> rawptr {
	return &guest()[a]
}

rd8 :: #force_inline proc "contextless" (a: u32) -> u8 {return guest()[a]}
rd16 :: #force_inline proc "contextless" (a: u32) -> u16 {return intrinsics.unaligned_load((^u16)(&guest()[a]))}
rd32 :: #force_inline proc "contextless" (a: u32) -> u32 {return intrinsics.unaligned_load((^u32)(&guest()[a]))}
rd64 :: #force_inline proc "contextless" (a: u32) -> u64 {return intrinsics.unaligned_load((^u64)(&guest()[a]))}

// Stores check the write watch (probe.odin) only in a JE_WATCH build: the
// check's possible call makes the compiler reload registers after every store.
wr8 :: #force_inline proc "contextless" (a: u32, v: u8) {
	when WATCH {if a - watch_lo < watch_len {watch_hit(a, u64(v))}}
	guest()[a] = v
}
wr16 :: #force_inline proc "contextless" (a: u32, v: u16) {
	when WATCH {if a - watch_lo < watch_len {watch_hit(a, u64(v))}}
	intrinsics.unaligned_store((^u16)(&guest()[a]), v)
}
wr32 :: #force_inline proc "contextless" (a: u32, v: u32) {
	when WATCH {if a - watch_lo < watch_len {watch_hit(a, u64(v))}}
	intrinsics.unaligned_store((^u32)(&guest()[a]), v)
}
wr64 :: #force_inline proc "contextless" (a: u32, v: u64) {
	when WATCH {if a - watch_lo < watch_len {watch_hit(a, v)}}
	intrinsics.unaligned_store((^u64)(&guest()[a]), v)
}

push32 :: #force_inline proc "contextless" (v: u32) {
	cpu.esp -= 4
	wr32(cpu.esp, v)
}

pop32 :: #force_inline proc "contextless" () -> u32 {
	v := rd32(cpu.esp)
	cpu.esp += 4
	return v
}

mem_zero :: proc "contextless" (a: u32, n: u32) {
	for i in 0 ..< n {
		mem[a + i] = 0
	}
}

CSTR_MAX :: 1 << 16

// NUL-terminated guest string, without copying. Longer than CSTR_MAX is fatal.
cstr :: proc(a: u32) -> string {
	n: u32 = 0
	for mem[a + n] != 0 {
		n += 1
		if n == CSTR_MAX {
			fatal("unterminated guest string at %08x", a)
		}
	}
	return string(mem[a:a + n])
}
