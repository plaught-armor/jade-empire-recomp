package x86

import "core:mem/virtual"
import "core:sys/linux"

mem_init :: proc() {
	p, err := linux.mmap(MEM_BASE, MEM_SIZE, {}, {.PRIVATE, .ANONYMOUS, .NORESERVE, .FIXED_NOREPLACE})
	if err != .NONE || uintptr(p) != MEM_BASE {
		fatal("cannot reserve guest memory at %x: %v", MEM_BASE, err)
	}
	mem = guest()
	if virtual.commit(mem[NULL_GUARD:], MEM_SIZE - NULL_GUARD) != nil {
		fatal("cannot commit guest memory")
	}
}
