// Left-stick and movement log for play sessions, a debug aid with no effect on
// the game. With JE_STICK_LOG set (play.sh sets it), each player move logs, at
// most every STICK_LOG_EVERY frames while anything moves and once when it all
// comes to rest, one line:
//   stick f<frame> raw x,y dz x,y game x,y n <n> pad <deg> | want <deg>
//   face <deg> move <deg> <speed>/s view <deg> [combat]
// raw is SDL's left stick (y down), dz the same after pad_stick's deadzone,
// game the virtual Xbox pad's LX, LY (y up) the game reads, n the length of
// the move direction the game derives from it (0 .. 6). pad is the stick's
// angle on the pad, clockwise from up. want (the facing the move turns
// toward), face (the player's facing) and move (the heading of the player's
// position change since the last move) are in degrees clockwise from the
// camera's view direction, so 0 is into the screen and 90 is screen right;
// speed is in world units per second; view is the view direction's world
// yaw, counterclockwise.
package native

import "core:fmt"
import "core:math"
import "../win32"
import "../x86"

stick_log_on := false

STICK_LOG_EVERY :: 3

@(private = "file")
Stick_Log :: struct {
	frame:   u32, // frame of the last move
	printed: u32, // frame of the last line
	pos:     [3]f32,
	idle:    bool, // the last line showed everything at rest
}
@(private = "file")
slog: Stick_Log

// Logs the player's move: this the CMoveDataCreature after Move_Dir, n the
// length of its input direction.
stick_log :: proc(this, creature: u32, n: f32, combat: bool) {
	if !stick_log_on {return}
	f := x86.frame_now
	if f == slog.frame {return}
	// A gap in the moves (a load, a menu) is no movement.
	fresh := f - slog.frame <= STICK_LOG_EVERY
	slog.frame = f
	pos := [3]f32{lf(creature + CREATURE_POS), lf(creature + CREATURE_POS + 4), lf(creature + CREATURE_POS + 8)}
	d := pos.xy - slog.pos.xy
	slog.pos = pos
	dt := lf(ld(APP) + APP_DT)
	speed := fresh && dt > 0 ? math.sqrt(d.x * d.x + d.y * d.y) / dt : 0
	raw, dz := win32.pad_left_raw, win32.pad_left
	rest := raw == {} && move_pad == {} && n == 0 && speed < 0.01
	if rest && slog.idle {return}
	if !rest && f - slog.printed < STICK_LOG_EVERY {return}
	slog.printed, slog.idle = f, rest
	cam := ld(ld(ld(APP) + APP_MODULE) + MODULE_CAMERA)
	around := math.atan2(pos.y - lf(cam + CAMERA_POS + 4), pos.x - lf(cam + CAMERA_POS))
	view, ok := cam_view_yaw(cam)
	if !ok {view = around}
	// Degrees clockwise from the view direction; world yaw is counterclockwise.
	rel :: proc(a, view: f32) -> f32 {return -wrap_pi(a - view) * 180 / math.PI}
	want := math.atan2(lf(this + MOVE_WANT_FACING + 4), lf(this + MOVE_WANT_FACING))
	face := math.atan2(lf(creature + CREATURE_FACING + 4), lf(creature + CREATURE_FACING))
	pad := math.atan2(f32(dz.x), f32(-dz.y)) * 180 / math.PI
	fmt.eprintf(
		"stick f%d raw %d,%d dz %d,%d game %d,%d n %.2f pad %.0f | want %.0f face %.0f move %.0f %.2f/s view %.1f round %.1f%s\n",
		f, raw.x, raw.y, dz.x, dz.y, move_pad.x, move_pad.y, n, dz == {} ? 0 : pad,
		rel(want, view), rel(face, view), speed > 0.01 ? rel(math.atan2(d.y, d.x), view) : 0, speed, view * 180 / math.PI, around * 180 / math.PI,
		combat ? " combat" : "",
	)
}

