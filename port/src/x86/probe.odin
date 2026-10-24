// Function probes for live debugging (JE_CTL `probe`): every call to a probed
// guest function logs one line on return with its return address, ecx, the
// first PROBE_ARGS stack arguments (as at entry), eax and st(0). An argument that
// points at a C string, or at a pointer to one (CExoString), also shows it.
// A dump spec (JE_CTL `probe dump`) adds the words at ecx or an argument plus an
// offset, read at entry, as hex with their float reading.
// WHY: docs/recompiler.md §7
package x86

import "base:runtime"
import "core:fmt"

PROBE_MAX :: 8
PROBE_ARGS :: 4
PROBE_HITS_MAX :: 256 // lines a probe logs before it goes quiet
PROBE_STR_MAX :: 40   // bytes of a guessed string shown
PROBE_DUMP_WORDS :: 16 // most dwords a dump spec shows
PROBE_DUMP_ECX :: -1   // Probe_Dump.arg naming ecx rather than a stack argument

Probe :: struct {
	addr, hits: u32,
	arg0:       Maybe(u32), // when set, only calls whose first stack argument equals it log
}

// Which words every probe line also shows: n dwords at off past ecx
// (arg == PROBE_DUMP_ECX) or past stack argument arg. n 0 is off.
Probe_Dump :: struct {
	arg:    int,
	off, n: u32,
}

probes: [PROBE_MAX]Probe
probe_n: int
probe_dump: Probe_Dump

probe_dump_set :: proc(arg: int, off, n: u32) {
	assert(arg >= PROBE_DUMP_ECX && arg < PROBE_ARGS && n <= PROBE_DUMP_WORDS)
	probe_dump = {arg, off, n}
}

// Adds a probe on the function at addr, optionally filtered on its first stack
// argument; false when the table is full.
probe_add :: proc(addr: u32, arg0: Maybe(u32) = nil) -> bool {
	if probe_n == PROBE_MAX {return false}
	probes[probe_n] = {addr, 0, arg0}
	probe_n += 1
	return true
}

probe_clear :: proc() {
	probe_n = 0
}

// Runs f under the probe for addr. False, with f not run, when addr has no probe.
probe_call :: proc(addr: u32, f: Func) -> bool {
	p: ^Probe
	for i in 0 ..< probe_n {
		if probes[i].addr == addr {p = &probes[i]; break}
	}
	if p == nil {return false}
	sp, ecx := cpu.esp, cpu.ecx
	ra := rd32(sp)
	args: [PROBE_ARGS]u32
	for i in 0 ..< PROBE_ARGS {args[i] = rd32(sp + 4 + u32(i) * 4)}
	d := probe_dump
	base := ecx if d.arg == PROBE_DUMP_ECX else args[max(d.arg, 0)]
	words: [PROBE_DUMP_WORDS]u32
	if !probe_readable(base + d.off, d.n * 4) {d.n = 0}
	for i in 0 ..< d.n {words[i] = rd32(base + d.off + i * 4)}
	f()
	if want, ok := p.arg0.?; ok && args[0] != want {return true}
	if p.hits == PROBE_HITS_MAX {return true}
	p.hits += 1
	fmt.eprintf("probe: %08x ra=%08x ecx=%08x", addr, ra, ecx)
	for v in args {
		fmt.eprintf(" %08x", v)
		if s, ok := probe_str(v); ok {fmt.eprintf("%q", s)}
	}
	fmt.eprintf(" = %08x st0=%v", cpu.eax, st(0))
	if d.n > 0 {fmt.eprintf(" [%08x+%x]", base, d.off)}
	for w in words[:d.n] {fmt.eprintf(" %08x(%.4g)", w, transmute(f32)w)}
	fmt.eprintf("\n")
	return true
}

// The C string at p, or at the pointer stored at p, when it is printable.
probe_str :: proc(p: u32) -> (string, bool) {
	if s, ok := probe_cstr(p); ok {return s, true}
	if !probe_readable(p, 4) {return "", false}
	return probe_cstr(rd32(p))
}

probe_cstr :: proc(p: u32) -> (string, bool) {
	if !probe_readable(p, PROBE_STR_MAX) {return "", false}
	n := 0
	for n < PROBE_STR_MAX && mem[p + u32(n)] != 0 {
		b := mem[p + u32(n)]
		if b < 0x20 || b > 0x7e {return "", false}
		n += 1
	}
	if n < 2 {return "", false}
	return string(mem[p:p + u32(n)]), true
}

probe_readable :: proc(p, n: u32) -> bool {
	return p >= NULL_GUARD && u64(p) + u64(n) <= MEM_SIZE
}

// Write watch (JE_CTL `watch`): every guest store whose address falls in
// [watch_lo, watch_lo + watch_len) logs the address, the value and a host
// backtrace, where recompiled procs show as r_<guest addr>. watch_len 0 is off,
// which costs each store one compare. Built in only with -define:JE_WATCH=true.
// Stores that straddle the range start are not seen. WATCH_HITS_MAX lines, then
// it goes quiet.
WATCH :: #config(JE_WATCH, false)
WATCH_HITS_MAX :: 24

watch_lo, watch_len, watch_hits: u32

watch_set :: proc(lo, n: u32) {
	watch_lo, watch_len, watch_hits = lo, n, 0
}

@(cold)
watch_hit :: proc "contextless" (a: u32, v: u64) {
	if watch_hits == WATCH_HITS_MAX {return}
	watch_hits += 1
	context = runtime.default_context()
	fmt.eprintf("watch: %08x <- %x (ecx=%08x esi=%08x)\n", a, v, cpu.ecx, cpu.esi)
	host_backtrace()
}
