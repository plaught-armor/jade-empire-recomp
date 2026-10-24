// Guest x86 CPU state, call dispatch and fault reporting.
// WHY: docs/recompiler.md §2
package x86

import "core:fmt"
import "core:os"

Fpu :: struct {
	st:  [8]f64, // physical registers; st(i) is st[(top + i) & 7]
	top: u32,
	cw:  u16,    // control word: RC bits 10-11, PC bits 8-9 (00 single, else f64)
	sw:  u16,    // status word without TOP; C0 0x100, C1 0x200, C2 0x400, C3 0x4000
	tag: u8,     // bit i set = physical register i empty
}

// Each register and flag sits apart from the next, with an unused slot
// between them: a recompiled body reloads its registers after every call, and
// LLVM pairs adjacent reloads into one wide load, which the store buffer
// cannot forward from the callee's two narrow stores (a stall of a dozen
// cycles each time). WHY: docs/recompiler.md §2
Cpu :: struct {
	eax:      u32,
	_eax:     u32,
	ecx:      u32,
	_ecx:     u32,
	edx:      u32,
	_edx:     u32,
	ebx:      u32,
	_ebx:     u32,
	esp:      u32,
	_esp:     u32,
	ebp:      u32,
	_ebp:     u32,
	esi:      u32,
	_esi:     u32,
	edi:      u32,
	_edi:     u32,
	cf:       bool,
	_cf:      u8,
	pf:       bool,
	_pf:      u8,
	af:       bool,
	_af:      u8,
	zf:       bool,
	_zf:      u8,
	sf:       bool,
	_sf:      u8,
	of:       bool,
	_of:      u8,
	df:       bool,
	_df:      u8,
	fs_base:  u32,
	fpu:      Fpu,
	xmm:      [8]Xmm,
	mxcsr:    u32,
}

cpu := Cpu {
	mxcsr = MXCSR_DEFAULT,
}

Func :: #type proc()

Func_Entry :: struct {
	addr: u32,
	fn:   Func,
}

// Guest addresses below TEXT_HI that are code; HLE procs live at HLE_BASE.
TEXT_LO :: 0x401000
TEXT_HI :: 0x6e1000
HLE_BASE :: 0xff000000
HLE_MAX :: 1024

// Flat table over .text, indexed by address - TEXT_LO.
dispatch: []Func
hle: [HLE_MAX]Func
hle_names: [HLE_MAX]string
hle_trace: bool // JE_HLE_TRACE: log every HLE call with its first seven arguments

register_funcs :: proc(entries: []Func_Entry) {
	if dispatch == nil {
		dispatch = make([]Func, TEXT_HI - TEXT_LO)
	}
	for e in entries {
		assert(e.addr >= TEXT_LO && e.addr < TEXT_HI)
		dispatch[e.addr - TEXT_LO] = e.fn
	}
}

// Call guest code at addr. The return address is already pushed. Both table
// lookups are range-checked first, so they skip the bounds check: the check
// is an out-of-line runtime call here (each package is its own LLVM module).
call :: proc(addr: u32) {
	if addr >= TEXT_LO && addr < TEXT_HI {
		#no_bounds_check f := dispatch[addr - TEXT_LO]
		if f != nil {
			if probe_n > 0 && probe_call(addr, f) {return}
			f()
			return
		}
		call_fault("call to unregistered code address %08x", addr)
	}
	if addr >= HLE_BASE && addr < HLE_BASE + HLE_MAX * 4 {
		k := (addr - HLE_BASE) / 4
		#no_bounds_check f := hle[k]
		if f == nil {
			import_fault(k)
		}
		hle_ring_push(rd32(cpu.esp), k)
		if hle_trace {
			hle_call_traced(k, f)
			return
		}
		f()
		return
	}
	call_fault("call to non-code address %08x", addr)
}

// call's failures, out of line for the same reason.
@(cold)
call_fault :: proc(msg: string, addr: u32) -> ! {
	fatal(msg, addr)
}

@(cold)
import_fault :: proc(k: u32) -> ! {
	fatal("unimplemented import %s", hle_names[k])
}

// An HLE call under JE_HLE_TRACE. Out of line so call's own frame stays small:
// the formatting needs a large one. WHY: docs/recompiler.md §2
@(cold)
hle_call_traced :: proc(k: u32, f: Func) {
	ra, sp := rd32(cpu.esp), cpu.esp
	fmt.eprintf("hle: %08x %s(%08x %08x %08x %08x %08x %08x %08x)", ra, hle_names[k], rd32(sp + 4), rd32(sp + 8), rd32(sp + 12), rd32(sp + 16), rd32(sp + 20), rd32(sp + 24), rd32(sp + 28))
	f()
	fmt.eprintf(" = %08x pops %d\n", cpu.eax, i32(cpu.esp - sp) - 4)
}

// A generated call to code in another package, or an indirect call: packages
// cannot import each other, so these go through the dispatch table. The
// generator copies this into each package, where it inlines; for a constant
// addr its range check folds, leaving a table load and an indirect call.
// Imports and COM methods (HLE slots) take the same inline path with call's
// ring record, so each call site keeps its own indirect-branch prediction.
// Probes, HLE tracing, unset slots and faults go through call.
// WHY: docs/recompiler.md §2
call_ext :: #force_inline proc(addr: u32) {
	if probe_n == 0 {
		if addr >= TEXT_LO && addr < TEXT_HI {
			#no_bounds_check f := dispatch[addr - TEXT_LO]
			if f != nil {
				f()
				return
			}
		} else if addr >= HLE_BASE && addr < HLE_BASE + HLE_MAX * 4 && !hle_trace {
			k := (addr - HLE_BASE) / 4
			#no_bounds_check f := hle[k]
			if f != nil {
				#no_bounds_check hle_ring[hle_ring_n & (HLE_RING - 1)] = {rd32(cpu.esp), k}
				hle_ring_n += 1
				f()
				return
			}
		}
	}
	call(addr)
}

fatal :: proc(f: string, args: ..any) -> ! {
	fmt.eprintf("x86: ")
	fmt.eprintf(f, ..args)
	fmt.eprintf("\n  eax=%08x ecx=%08x edx=%08x ebx=%08x esp=%08x ebp=%08x esi=%08x edi=%08x\n",
		cpu.eax, cpu.ecx, cpu.edx, cpu.ebx, cpu.esp, cpu.ebp, cpu.esi, cpu.edi)
	// esp is 0 before the guest starts (a fatal from startup code).
	if stack_readable(cpu.esp) {
		fmt.eprintf("  stack:")
		for i in u32(0) ..< 8 {
			fmt.eprintf(" %08x", rd32(cpu.esp + i * 4))
		}
		fmt.eprintln()
	}
	crash_context()
	os.exit(1)
}

bad_insn :: proc(pc: u32) {
	fatal("undecodable instruction at %08x", pc)
}

unsupported :: proc(pc: u32) {
	fatal("instruction at %08x not supported by the recompiler", pc)
}

trap :: proc(pc: u32) {
	fatal("int3 at %08x", pc)
}
