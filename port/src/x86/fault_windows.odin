// Host fault report on Windows: an unhandled exception prints the exception
// code and address (as a guest address when inside guest memory), the host pc
// and the guest registers, a host backtrace of raw addresses with the exe's
// base (map them with jade.pdb), then lets Windows end the process.
// WHY: docs/recompiler.md §2
package x86

import "base:runtime"
import "core:fmt"
import win "core:sys/windows"

FAULT_FRAMES :: 48

fault_init :: proc() {
	win.SetUnhandledExceptionFilter(fault_filter)
}

fault_filter :: proc "system" (ep: ^win.EXCEPTION_POINTERS) -> win.LONG {
	context = runtime.default_context()
	rec := ep.ExceptionRecord
	// For an access violation the second parameter is the address touched.
	addr := uintptr(rec.ExceptionInformation[1]) if rec.NumberParameters >= 2 else uintptr(rec.ExceptionAddress)
	base := uintptr(rawptr(mem))
	fmt.eprintf("x86: host exception %08x at %x, host pc %x", rec.ExceptionCode, addr, ep.ContextRecord.Rip)
	if mem != nil && addr >= base && addr - base < MEM_SIZE {
		fmt.eprintf(" (guest address %08x)", u32(addr - base))
	}
	// Guest registers are as of the last store to cpu; values held in host
	// registers at the fault are not visible here.
	fmt.eprintf("\n  eax=%08x ecx=%08x edx=%08x ebx=%08x esp=%08x ebp=%08x esi=%08x edi=%08x\n",
		cpu.eax, cpu.ecx, cpu.edx, cpu.ebx, cpu.esp, cpu.ebp, cpu.esi, cpu.edi)
	fmt.eprintln("  host backtrace:")
	host_backtrace()
	// Last: a bad guest esp could fault again here, which then ends the process.
	crash_context()
	return win.EXCEPTION_CONTINUE_SEARCH
}

// The host call stack to stderr, raw addresses with the exe's base.
host_backtrace :: proc() {
	frames: [FAULT_FRAMES]rawptr
	n := win.RtlCaptureStackBackTrace(0, FAULT_FRAMES, &frames[0], nil)
	fmt.eprintfln("    exe base %x", uintptr(win.GetModuleHandleW(nil)))
	for f in frames[:n] {fmt.eprintfln("    %x", uintptr(f))}
}
