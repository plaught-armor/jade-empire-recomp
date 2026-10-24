// Aimed target pick in combat, a deliberate change rather than a bit-exact
// replacement. When the player's target is gone, the player target update
// 0x434430 picks the nearest candidate within 20 m, wherever it stands. The
// port weights each candidate's distance by its angle off the player's aim,
// the stick's direction while it is held, else the camera's view: straight
// ahead counts as is, side on 1 + AIM_K / 2 times as far, behind 1 + AIM_K
// times. JE_AIM=0 keeps the nearest pick. JE_NATIVE has no effect here.
// WHY: docs/recompiler.md §10
package native

import "core:math"
import "../x86"

guest_obj_pos: x86.Func

aim_on := true

AIM_K :: 2 // a candidate behind the player counts 1 + AIM_K times its distance
#assert(AIM_K > 0)

// 0x434430 calls 0x4123d0 for each candidate that passed its filters and
// keeps the one with the least squared distance from the player (edi there)
// below 400. The call returns here.
AIM_PICK_RET :: 0x004345f9
// Where the weighted position is handed back: the settings page, past the
// control panel's descriptions. 12 bytes.
AIM_POS :: 0x00a00300

// The player's last stick direction in combat, world xy, from the movement
// hook (turn.odin); 0 when the stick is centred.
@(private = "file")
aim_x, aim_y: f32

aim_stick :: proc(x, y: f32) {
	aim_x, aim_y = x, y
}

// Scene object position, thiscall, returns ^f32 x, y, z.
Obj_Pos_004123d0 :: proc() {
	c := &x86.cpu
	ret, player := ld(c.esp), c.edi
	guest_obj_pos()
	if !aim_on || ret != AIM_PICK_RET {return}
	pos, at := player + CREATURE_POS, c.eax
	dx, dy, dz := lf(at) - lf(pos), lf(at + 0x4) - lf(pos + 0x4), lf(at + 0x8) - lf(pos + 0x8)
	ux, uy := aim_dir(pos)
	h := math.sqrt(dx * dx + dy * dy)
	cos: f32 = 1
	if h > 0 && (ux != 0 || uy != 0) {cos = (dx * ux + dy * uy) / h}
	// Scaled into 1 / (1 + AIM_K) .. 1 of its distance, so the weighted pick
	// stays under the game's 400 wherever the plain distance does.
	s := (1 + AIM_K * (1 - cos) / 2) / (1 + AIM_K)
	sf(AIM_POS, lf(pos) + dx * s)
	sf(AIM_POS + 0x4, lf(pos + 0x4) + dy * s)
	sf(AIM_POS + 0x8, lf(pos + 0x8) + dz * s)
	c.eax = AIM_POS
}

// Unit xy of the player's aim: the stick, else camera to player; 0, 0 if
// neither has a direction.
@(private = "file")
aim_dir :: proc(pos: u32) -> (f32, f32) {
	x, y := aim_x, aim_y
	if x == 0 && y == 0 {
		cam := ld(ld(ld(APP) + APP_MODULE) + MODULE_CAMERA) + CAMERA_POS
		x, y = lf(pos) - lf(cam), lf(pos + 0x4) - lf(cam + 0x4)
	}
	n := math.sqrt(x * x + y * y)
	if n == 0 {return 0, 0}
	return x / n, y / n
}
