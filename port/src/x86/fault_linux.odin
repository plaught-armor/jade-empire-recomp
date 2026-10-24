// Host fault report: SIGSEGV, SIGBUS, SIGFPE and SIGILL print the faulting
// address (as a guest address when inside guest memory), the host pc, a host
// backtrace (recompiled procs are named r_<guest addr>) and the guest
// registers, then return with the default action restored so the fault
// repeats and the process still dumps core.
// WHY: docs/recompiler.md §2
package x86

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:sys/posix"

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	backtrace :: proc(buf: [^]rawptr, size: c.int) -> c.int ---
	backtrace_symbols_fd :: proc(buf: [^]rawptr, size: c.int, fd: c.int) ---
}

FAULT_FRAMES :: 48
// Linux x86-64 ucontext_t: uc_flags, uc_link, uc_stack (24 bytes), then
// mcontext gregs[23]; REG_RIP is gregs[16].
UCONTEXT_RIP :: 40 + 16 * 8

// SIGSTKSZ is too small: the kernel's signal frame (xsave area) plus fmt
// overflow it and the second fault kills the process silently.
FAULT_STACK :: 1 << 20

fault_stack: [FAULT_STACK]u8

fault_init :: proc() {
	ss := posix.stack_t {
		ss_sp   = &fault_stack[0],
		ss_size = len(fault_stack),
	}
	if posix.sigaltstack(&ss, nil) != .OK {fatal("sigaltstack: %v", posix.strerror(posix.errno()))}
	sa := posix.sigaction_t {
		sa_sigaction = fault_handler,
		sa_flags     = {.SIGINFO, .ONSTACK, .RESETHAND},
	}
	posix.sigemptyset(&sa.sa_mask)
	for sig in ([4]posix.Signal{.SIGSEGV, .SIGBUS, .SIGFPE, .SIGILL}) {
		if posix.sigaction(sig, &sa, nil) != .OK {fatal("sigaction %v: %v", sig, posix.strerror(posix.errno()))}
	}
}

fault_handler :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, uctx: rawptr) {
	context = runtime.default_context()
	addr := uintptr(info.si_addr)
	base := uintptr(rawptr(mem))
	rip := (^uintptr)(uintptr(uctx) + UCONTEXT_RIP)^
	fmt.eprintf("x86: host %v at %x, host pc %x", sig, addr, rip)
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
}

// The host call stack to stderr, symbolized.
host_backtrace :: proc() {
	frames: [FAULT_FRAMES]rawptr
	n := backtrace(&frames[0], FAULT_FRAMES)
	backtrace_symbols_fd(&frames[0], n, 2)
}
