// The game's analog deadzone, a deliberate change rather than a bit-exact
// replacement. Each stick axis, read as a float in -1..1, passes through
// (|v| - dz) / (1 - dz) with dz 0.6, so the stick does nothing until 60% of its
// travel. The port's pad already applies a radial deadzone and rescales
// (win32 pad_stick), so the game's is set to 0 for the call and the value
// passes through unchanged. JE_STICK=0 keeps the original deadzone. JE_NATIVE
// has no effect here.
// WHY: docs/hle.md §5
package native

import "../x86"

guest_axis_dz: x86.Func

stick_on := true

// Per controller port, 0x33a8 bytes apart: f32 deadzone of axis actions 0x10
// to 0x13.
AXIS_DZ :: 0x3810
AXIS_FIRST :: 0x10
AXIS_N :: 4
PORT_SIZE :: 0x33a8

// thiscall(port, action, value: f32) -> st(0), ret 0xc: value past the
// deadzone of the action's axis, rescaled to -1..1.
Axis_Deadzone_006661d0 :: proc() {
	c := &x86.cpu
	a := ld(c.esp + 0x8) - AXIS_FIRST
	if !stick_on || a >= AXIS_N {
		guest_axis_dz()
		return
	}
	dz := c.ecx + ld(c.esp + 0x4) * PORT_SIZE + AXIS_DZ + a * 4
	old := ld(dz)
	st(dz, 0)
	guest_axis_dz()
	st(dz, old)
}
