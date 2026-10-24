// Turn-to-run movement for the player out of combat, a deliberate change
// rather than a bit-exact replacement. The game maps the stick relative to the
// player's facing and keeps the facing, so any stick angle off forward plays a
// strafe or backpedal while the trailing camera swings round. The port takes
// the stick relative to the camera instead: the move's desired facing, which
// the game turns the player to (0x45e070), steps toward the stick direction at
// TURN_RATE, and the move runs forward along the current facing. Combat
// movement is left alone. JE_TURN=0 keeps the original movement. JE_NATIVE has
// no effect here.
// WHY: docs/recompiler.md §10
package native

import "core:math"
import "../x86"

guest_move_dir: x86.Func
guest_move_anim: x86.Func

turn_on := true

TURN_RATE :: 3 * math.PI // radians per second
// The run slows with the cosine of the turn still to go, to this fraction at
// a quarter turn or more, so a reversal pivots near the spot.
TURN_CRAWL :: 0.15

// CMoveDataCreature (ctor 0x45bfd0), built per frame by CPlayerControl.
MOVE_WANT_FACING :: 0x78 // f32 x, y, z: the facing the move turns toward
MOVE_CREATURE :: 0x90
MOVE_STICK :: 0x94 // f32 x, y: the stick, x across, y ahead

CREATURE_POS :: 0x44 // f32 x, y, z
CREATURE_FACING :: 0x50 // f32 x, y, z unit vector
CREATURE_COMBAT :: 0x588 // u32, nonzero in combat stance

APP :: 0x0076c924
APP_DT :: 0x20 // f32 seconds this frame
APP_MODULE :: 0xa0
MODULE_CAMERA :: 0x124
CAMERA_POS :: 0x7c // f32 x, y, z

GET_PLAYER :: 0x00424700 // thiscall on [[APP]+APP_MODULE]
GET_PLAYER_RET :: 0x0045c9b0 // a return address inside 0x45c980, which calls it the same way

// The stick is read against the shown camera's view yaw (cam_view_yaw). The free
// camera (camera.odin) holds its heading while the player turns, as player
// 2's camera does (coop_camera.odin). Without it
// the game's camera swings round behind the facing, so a steady stick is read
// against the yaw latched when it left center until it is let go; read against
// the live camera the turn would chase itself. A stick that turns brings view
// toward the live camera by as much as it turned, so steering with the stick
// follows the screen. One for the player, one for the henchman player 2
// drives (coop.odin).
@(private = "file")
Driver :: struct {
	view:       f32,
	view_held:  bool,
	stick_last: f32, // the stick's angle on the pad at the last move
}
@(private = "file")
drivers: [2]Driver

// The left stick of the last gameplay read of the virtual pad (LX, LY up
// positive). The game's move direction is no good for the stick's angle: on
// some camera angles (0x464762) it negates the direction to backpedal, so a
// stick a little past screen right would read as straight back.
move_pad: [2]i16

// Keeps the left stick of a gameplay read of the virtual pad at this.
move_pad_read :: proc(this: u32) {
	v := ld(this + XB_LX)
	move_pad = {i16(v), i16(v >> 16)}
}

// CMoveDataCreature set direction, thiscall(dir*), ret 4: dir is the stick
// turned by the creature's facing; picks the move mode and writes the move
// direction to +0x60.
Move_Dir_0045c720 :: proc() {
	c := &x86.cpu
	this, dir := c.ecx, ld(c.esp + 0x4)
	creature := ld(this + MOVE_CREATURE)
	if creature == 0 {
		guest_move_dir()
		return
	}
	dx, dy := lf(dir), lf(dir + 0x4)
	n := math.sqrt(dx * dx + dy * dy)
	mine, combat := creature == player(), ld(creature + CREATURE_COMBAT) != 0
	p2 := !mine && coop_id != 0 && ld(creature + CREATURE_ID) == coop_id
	d := &drivers[p2 ? 1 : 0]
	if n == 0 && (mine || p2) {d.view_held = false}
	c.ecx = this
	if mine {aim_stick(combat ? dx : 0, combat ? dy : 0)}
	if !turn_on || combat || n == 0 || !mine && !p2 {
		c.ecx = this
		guest_move_dir()
		if mine {stick_log(this, creature, n, combat)}
		return
	}
	pos, face := creature + CREATURE_POS, creature + CREATURE_FACING
	fx, fy := lf(face), lf(face + 0x4)
	now := math.atan2(fy, fx)
	cam := ld(ld(ld(APP) + APP_MODULE) + MODULE_CAMERA)
	live, ok := cam_view_yaw(cam)
	if !ok {live = math.atan2(lf(pos + 0x4) - lf(cam + CAMERA_POS + 0x4), lf(pos) - lf(cam + CAMERA_POS))}
	// The stick's angle counterclockwise from forward; keys move without it.
	stick := math.atan2(dy, dx) - now
	pad := p2 ? coop_pad : move_pad
	if pad != {} {stick = math.atan2(-f32(pad.x), f32(pad.y))}
	if cam_active() || p2 || !d.view_held {
		d.view, d.view_held = live, true
	} else {
		moved := abs(wrap_pi(stick - d.stick_last))
		d.view += clamp(wrap_pi(live - d.view), -moved, moved)
	}
	d.stick_last = stick
	// The game's own turn toward the desired facing stalls on wide angles, so
	// the desired facing is only this frame's step of the turn.
	turn := wrap_pi(d.view + stick - now)
	step := TURN_RATE * lf(ld(APP) + APP_DT)
	want := now + clamp(turn, -step, step)
	st(this + MOVE_WANT_FACING, transmute(u32)math.cos(want))
	st(this + MOVE_WANT_FACING + 0x4, transmute(u32)math.sin(want))
	st(this + MOVE_WANT_FACING + 0x8, 0)
	ahead := n * max(math.cos(turn), TURN_CRAWL)
	st(dir, transmute(u32)(fx * ahead))
	st(dir + 0x4, transmute(u32)(fy * ahead))
	c.ecx = this
	guest_move_dir()
	// The move update (0x45e300) turns the model from the desired facing by
	// the stick's angle off ahead, as the original stick is relative to the
	// facing. Here the desired facing already follows the stick, so the model
	// turned twice as far as the facing, then snapped back once the stick came
	// within 0.1 of the x axis and the game skipped the turn. Straight ahead
	// is what the stick is to the turned player.
	sx, sy := lf(this + MOVE_STICK), lf(this + MOVE_STICK + 0x4)
	st(this + MOVE_STICK, 0)
	st(this + MOVE_STICK + 0x4, transmute(u32)math.sqrt(sx * sx + sy * sy))
	if mine {stick_log(this, creature, n, false)}
}

// CMoveDataCreature move animation, thiscall(dt, facing*, velocity*), ret 0xc:
// turns the creature and picks its walk, jog or run, or out of combat with
// the stick near an axis a strafe (cwalkl, cwalkfl ...) by the velocity's
// angle off the model's heading (0x45c190, 45 degree sectors). Move_Dir leaves
// the stick straight ahead, on an axis, so a wall that slides the velocity
// more than 22.5 degrees off the facing would play a strafe. The stick is
// shown as diagonal for the call, which out of combat always picks the
// forward animation.
Move_Anim_0045c980 :: proc() {
	c := &x86.cpu
	this := c.ecx
	creature := ld(this + MOVE_CREATURE)
	if !turn_on || creature == 0 || ld(creature + CREATURE_COMBAT) != 0 || (coop_id == 0 || ld(creature + CREATURE_ID) != coop_id) && creature != player() {
		c.ecx = this
		guest_move_anim()
		return
	}
	sx, sy := ld(this + MOVE_STICK), ld(this + MOVE_STICK + 0x4)
	st(this + MOVE_STICK, transmute(u32)f32(1))
	st(this + MOVE_STICK + 0x4, transmute(u32)f32(1))
	c.ecx = this
	guest_move_anim()
	st(this + MOVE_STICK, sx)
	st(this + MOVE_STICK + 0x4, sy)
}

// a in -pi .. pi.
wrap_pi :: proc(a: f32) -> f32 {
	return math.mod(math.mod(a + math.PI, 2 * math.PI) + 2 * math.PI, 2 * math.PI) - math.PI
}

// The player creature, looked up as 0x45c980 does. Clobbers eax, ecx, edx.
@(private = "file")
player :: proc() -> u32 {
	c := &x86.cpu
	c.ecx = ld(ld(APP) + APP_MODULE)
	c.esp -= 4
	st(c.esp, GET_PLAYER_RET)
	call_guest(GET_PLAYER)
	return c.eax
}
