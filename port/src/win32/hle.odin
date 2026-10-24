// HLE binding: each imported "dll!name" gets one pseudo-address slot. Slots
// with no implementation stay nil, so a call fails naming the import.
package win32

import "base:intrinsics"
import "../x86"

Hle_Entry :: struct {
	name: string,
	fn:   x86.Func,
}

slots: map[string]u32
next_slot: u32

impl_index: map[string]x86.Func

hle_init :: proc() {
	for t in ([]([]Hle_Entry){KERNEL32[:], FILE[:], INI[:], MISC[:], USER32[:], DINPUT[:], D3DX[:], D3D9[:], DSOUND[:], VORBIS[:], BINK[:]}) {
		for e in t {
			impl_index[e.name] = e.fn
		}
	}
}

// Pseudo-address for an import, and whether it has an implementation.
hle_bind :: proc(name: string) -> (u32, bool) {
	fn, ok := impl_index[name]
	if s, have := slots[name]; have {
		return x86.HLE_BASE + s * 4, ok
	}
	if next_slot >= x86.HLE_MAX {
		x86.fatal("more than %d HLE imports", x86.HLE_MAX)
	}
	s := next_slot
	next_slot += 1
	slots[name] = s
	x86.hle[s] = fn
	x86.hle_names[s] = name
	return x86.HLE_BASE + s * 4, ok
}

// Guest load for hot HLE paths. x86.rd32 is not inlined here: each package is
// its own LLVM module (-use-separate-modules), so the call stays a call.
ld32 :: #force_inline proc "contextless" (a: u32) -> u32 {
	return intrinsics.unaligned_load((^u32)(&x86.mem[a]))
}

// stdcall argument i (0-based); the return address is at esp.
arg :: #force_inline proc "contextless" (i: u32) -> u32 {
	return ld32(x86.cpu.esp + 4 + i * 4)
}

// stdcall return: result in eax, callee pops the return address and n args.
ret :: #force_inline proc "contextless" (n: u32, v: u32) {
	x86.cpu.eax = v
	x86.cpu.esp += 4 + n * 4
}

last_error: u32

// Calls guest code at fn from a host proc, keeping ebx, ebp, esi and edi as
// a Win32 API does across its callbacks: the generator assumes host code
// changes only eax, ecx and edx. WHY: docs/recompiler.md §2
guest_enter :: proc(fn: u32) {
	ebx, ebp, esi, edi := x86.cpu.ebx, x86.cpu.ebp, x86.cpu.esi, x86.cpu.edi
	x86.call(fn)
	x86.cpu.ebx, x86.cpu.ebp, x86.cpu.esi, x86.cpu.edi = ebx, ebp, esi, edi
}

// Calls guest code at fn with stdcall args (args[0] pushed last, so it is
// the first parameter) and returns eax. Pushes below the current esp, which
// in an HLE proc still points at the caller's return address.
guest_call :: proc(fn: u32, args: ..u32) -> u32 {
	esp := x86.cpu.esp
	#reverse for a in args {
		x86.push32(a)
	}
	x86.push32(0) // return address; generated code returns natively
	guest_enter(fn)
	if x86.cpu.esp != esp {
		x86.fatal("guest_call %08x: callee left esp %08x, expected %08x", fn, x86.cpu.esp, esp)
	}
	return x86.cpu.eax
}

// guest_call for a cdecl callee: the caller (here) pops the args.
guest_call_c :: proc(fn: u32, args: ..u32) -> u32 {
	esp := x86.cpu.esp
	#reverse for a in args {
		x86.push32(a)
	}
	x86.push32(0) // return address; generated code returns natively
	guest_enter(fn)
	n := u32(len(args)) * 4
	if x86.cpu.esp != esp - n {
		x86.fatal("guest_call_c %08x: callee left esp %08x, expected %08x", fn, x86.cpu.esp, esp - n)
	}
	x86.cpu.esp = esp
	return x86.cpu.eax
}
