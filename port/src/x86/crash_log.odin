// Crash context for play-session logs: the last HLE calls and the guest
// return addresses on the stack, printed by fatal and by the fault handler.
// WHY: docs/recompiler.md §6
package x86

import "core:fmt"

HLE_RING :: 64          // recent HLE calls kept, a power of two
STACK_SCAN :: 512       // guest stack dwords searched for return addresses
STACK_RETURNS_MAX :: 24 // return addresses printed

Hle_Call :: struct {
	ra, k: u32, // guest return address, hle index
}

hle_ring: [HLE_RING]Hle_Call
hle_ring_n: u32 // calls recorded since start
frame_now: u32  // presented frame, set by the D3D9 layer

hle_ring_push :: proc "contextless" (ra, k: u32) {
	hle_ring[hle_ring_n & (HLE_RING - 1)] = {ra, k}
	hle_ring_n += 1
}

// True when the bytes before ra end in a call: E8 rel32, or FF /2 with a
// 0-, 1- or 4-byte displacement (register, [reg], [reg+d8], [reg+d32] or
// [d32] forms; SIB forms are covered by the same lengths plus one byte).
is_return_address :: proc(ra: u32) -> bool {
	if ra < TEXT_LO + 7 || ra >= TEXT_HI {
		return false
	}
	if mem[ra - 5] == 0xe8 {
		return true
	}
	for n in ([?]u32{2, 3, 4, 6, 7}) {
		if mem[ra - n] == 0xff && (mem[ra - n + 1] >> 3) & 7 == 2 {
			return true
		}
	}
	return false
}

// True when STACK_SCAN dwords from sp lie in readable guest memory.
stack_readable :: proc(sp: u32) -> bool {
	return sp >= 0x10000 && sp < 0xfff00000
}

crash_context :: proc() {
	fmt.eprintf("  frame %d\n", frame_now)
	print_guest_returns()
	fmt.eprintf("  last HLE calls, oldest first:\n")
	n := min(hle_ring_n, HLE_RING)
	for i in hle_ring_n - n ..< hle_ring_n {
		c := hle_ring[i & (HLE_RING - 1)]
		fmt.eprintf("    %08x %s\n", c.ra, hle_names[c.k])
	}
}

// One line of likely guest return addresses on the stack, nearest first.
print_guest_returns :: proc() {
	fmt.eprintf("  guest return addresses from esp:")
	sp := cpu.esp
	if stack_readable(sp) {
		shown := 0
		for i in u32(0) ..< STACK_SCAN {
			ra := rd32(sp + i * 4)
			if is_return_address(ra) {
				fmt.eprintf(" %08x@+%x", ra, i * 4)
				shown += 1
				if shown == STACK_RETURNS_MAX {break}
			}
		}
	} else {
		fmt.eprintf(" (esp outside guest memory)")
	}
	fmt.eprintf("\n")
}
