// Process start: map the exe, build the thread environment block and stack,
// then enter the guest at its entry point.
package win32

import "core:time"
import "../x86"

TEB :: 0x00030000
STACK_LO :: 0x01000000
STACK_HI :: 0x02000000

// Runs the guest from its entry point; returns only if the entry point does.
boot :: proc(exe: string) {
	start_tick = time.tick_now()
	hle_init()
	user32_init()
	img := load_pe(exe)
	// TEB: SEH chain end, stack bounds, self pointer.
	x86.wr32(TEB + 0x00, 0xffffffff)
	x86.wr32(TEB + 0x04, STACK_HI)
	x86.wr32(TEB + 0x08, STACK_LO)
	x86.wr32(TEB + 0x18, TEB)
	x86.wr32(TEB + 0x20, 0x1000)
	x86.wr32(TEB + 0x24, 0x1000)
	x86.cpu.fs_base = TEB
	x86.fninit()
	x86.cpu.esp = STACK_HI - 0x100
	x86.push32(0) // return address of the entry point
	x86.call(img.entry)
}
