// Wider side dodges, a deliberate change rather than a bit-exact replacement.
// DoEvade 0x4c3070 turns the stick into a world direction by the player's
// facing and picks the flip from its dot with the creature's own facing:
// front over cos 45°, back under -cos 45°; then the roll from its dot with the
// facing's right, past ±cos 45°; anything left over falls back to a front
// flip. For the player the two facings are the same, so the dodge is picked
// by the stick's angle on the pad alone, and a stick pushed left with a little
// up or down crossed 45° and flipped. The generator's patches point all four
// compares at DODGE_BOUNDS, so front and back take DODGE_HALF either side and
// the rolls the rest; the side bounds move with them so no direction falls
// through to the fallback. Foes dodge through the same call (ai.odin) and roll
// more often too.
// WHY: docs/recompiler.md §10
package native

import "core:math"
import "../x86"

// The settings page, past AIM_POS: f64 front and back bounds, then the two roll bounds.
DODGE_BOUNDS :: 0x00a00310
DODGE_HALF :: 30 // degrees either side of the facing that flip forward or back

dodge_init :: proc() {
	c := x86.cos(f64(DODGE_HALF) * math.PI / 180)
	s := x86.sin(f64(DODGE_HALF) * math.PI / 180) // cos of the roll's half width
	for v, i in ([4]f64{c, -c, s, -s}) {
		b := transmute(u64)v
		st(DODGE_BOUNDS + u32(i) * 8, u32(b))
		st(DODGE_BOUNDS + u32(i) * 8 + 4, u32(b >> 32))
	}
}
