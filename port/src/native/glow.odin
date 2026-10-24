// The game's glow pass, replaced by the port's bloom (win32 d3d9_bloom.odin),
// a deliberate change rather than a bit-exact replacement. The pass keeps
// what each channel of the frame has above a threshold, scaled by a slope,
// blurs it with a table of tap weights and adds it back; the port's bloom
// takes the same threshold and the slope times the weights' sum as its gain,
// so a scene glows as strongly as before, only smoother and wider. JE_BLOOM=0
// keeps the game's pass. JE_NATIVE has no effect here.
// WHY: docs/rendering.md §11
package native

import "core:math"
import "../win32"
import "../x86"

guest_glow: x86.Func

GLOW_THRESHOLD :: 0x0075ebfc // f32 r, g, b, 0 to 1; the pass rounds to 1/255
GLOW_GAIN :: 0x0075ec08 // f32: 1 + the bright pass slope
GLOW_WEIGHTS :: 0x0075ec50 // f32 tap weights, 7 draws of 4
GLOW_WEIGHTS_N :: 28

// cdecl(capture texture).
Glow_005cc100 :: proc() {
	if !win32.bloom_on {
		guest_glow()
		return
	}
	// The lookup rounds (level - threshold) * slope to whole levels, so
	// nothing passes below half a level of output: that much is added to the
	// threshold.
	slope := lf(GLOW_GAIN) - 1
	dead := slope > 0 ? 0.5 / slope : 0
	t: [3]f32
	for i in 0 ..< 3 {t[i] = (math.round(lf(GLOW_THRESHOLD + u32(i) * 4) * 255) + dead) / 255}
	sum: f32
	for i in 0 ..< GLOW_WEIGHTS_N {sum += lf(GLOW_WEIGHTS + u32(i) * 4)}
	win32.bloom_frame(t, slope * sum)
	x86.cpu.esp += 4
}
