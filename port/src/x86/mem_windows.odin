package x86

import win "core:sys/windows"

// The commit is charged to the page file up front, as Windows has no
// overcommit; pages are still only backed when touched.
mem_init :: proc() {
	p := win.VirtualAlloc(rawptr(MEM_BASE), MEM_SIZE, win.MEM_RESERVE, win.PAGE_NOACCESS)
	if uintptr(p) != MEM_BASE {
		fatal("cannot reserve guest memory at %x: error %d", MEM_BASE, win.GetLastError())
	}
	mem = guest()
	if win.VirtualAlloc(&mem[NULL_GUARD], MEM_SIZE - NULL_GUARD, win.MEM_COMMIT, win.PAGE_READWRITE) == nil {
		fatal("cannot commit guest memory: error %d", win.GetLastError())
	}
}
