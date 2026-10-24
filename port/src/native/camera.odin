// Free camera out of combat, a deliberate change rather than a bit-exact
// replacement. The game's exploration camera (vtable 0x6e37d0) is a spring
// that pulls back behind the player's facing every frame, and the right stick
// only turns the player. The port takes the right stick out of combat and
// keeps a yaw and a pitch of its own: each frame the game's camera runs on its
// own pose, the pose is saved, and the camera is shown turned by the port's
// angles round the point it looks at, pulled in by the game's own collision.
// While the player moves and the stick rests, the yaw eases back behind.
// With turn-to-run (turn.odin) the shown camera also holds its heading while
// the game's spring swings round behind a turning player, so the stick, read
// against the shown camera, does not chase itself; it eases back behind only
// as fast as the player runs away from it.
// JE_CAMERA=0 keeps the original camera. JE_NATIVE has no effect here.
// WHY: docs/recompiler.md §10
package native

import "core:math"
import "../win32"
import "../x86"

guest_cam_update: x86.Func

cam_on := true

CAM_YAW_RATE :: math.PI // radians per second at full stick
CAM_PITCH_RATE :: 0.5 * math.PI
CAM_PITCH_MIN :: -0.35 // radians of elevation above the look point
CAM_PITCH_MAX :: 1.2
CAM_RECENTRE_WAIT :: 0.75 // seconds of rest before the yaw eases back
CAM_RECENTRE_RATE :: 1.5 // per second, exponential
CAM_MOVING :: 0.5 // units per second the player has to move

// CBehaviorCamera (0x420f60 is its update, vtable slot 2).
BEH_TARGET :: 0x38 // object followed
BEH_CAMERA :: 0x3c // the camera's interface at camera + 4
BEH_TARGET_POS :: 0x48 // f32 x, y, z
BEH_CLIPPED :: 0xe8 // u32 flags 0x420730 leaves; restored round the port's call
BEH_CLIP_HOLD :: 0xec
CAMERA_IFACE :: 4
CAMERA_QUAT :: 0x88 // f32 w, x, y, z; the camera looks down its -z, +y up
CAM_CLIP :: 0x00420730 // thiscall(out*, want*), ret 8: want pulled in by collision

// The right stick this frame, from the virtual pad (flick.odin), -1 to 1, y up.
cam_rx, cam_ry: f32
@(private = "file")
cam_pad_frame: u32

@(private = "file")
Cam :: struct {
	beh:       u32,
	frame:     u32, // frame of the last update
	yaw:       f32, // radians added round the vertical
	pitch:     f32, // radians added to the elevation
	rest:      f32, // seconds the stick has rested
	last:      [3]f32, // target position last update
	gyaw:      f32, // the game's yaw round its target last update
	shown:     bool, // the pose below is on the camera
	guest_pos: [3]f32, // the game's own pose
	guest_q:   [4]f32,
	show_pos:  [3]u32, // the pose shown, as stored
	show_q:    [4]u32,
}
@(private = "file")
cam: Cam

// The exploration camera ran last frame or this one.
cam_active :: proc() -> bool {
	return cam_on && cam.beh != 0 && x86.frame_now - cam.frame <= 1
}

// The exploration camera's behaviour if it runs the camera at c, or 0 (a
// conversation's or a cutscene's camera has the view, or combat's).
cam_behaviour :: proc(c: u32) -> u32 {
	if cam.beh == 0 || x86.frame_now - cam.frame > 1 || ld(cam.beh + BEH_CAMERA) != c + CAMERA_IFACE {return 0}
	return cam.beh
}

// From each build of the virtual pad: out of combat, the right stick is the
// camera's and the game sees it centred. A frame can build the pad more than
// once; the largest reading of the frame is kept.
cam_pad :: proc(this: u32) {
	if x86.frame_now != cam_pad_frame {
		cam_pad_frame, cam_rx, cam_ry = x86.frame_now, 0, 0
	}
	if !cam_active() {return}
	p := world_player()
	if p == 0 || ld(p + CREATURE_COMBAT) != 0 {return}
	rx, ry := f32(i16(ld(this + XB_RX))) / 32767, f32(i16(ld(this + XB_RY))) / 32767
	if abs(rx) > abs(cam_rx) {cam_rx = rx}
	if abs(ry) > abs(cam_ry) {cam_ry = ry}
	st(this + XB_RX, 0) // RX and RY
}

// The camera c's pose as the game left it: while the port shows its own
// pose, the game's from under it. The shown pose was pulled in by the
// game's collision with the collision's flags put back, so only the game's
// pose agrees with them.
cam_game_pose :: proc(c: u32) -> (pos: [3]f32, q: [4]f32) {
	if cam.shown && ld(cam.beh + BEH_CAMERA) == c + CAMERA_IFACE && pose_is(c, cam.show_pos, cam.show_q) {
		return cam.guest_pos, cam.guest_q
	}
	for i in 0 ..< 3 {pos[i] = lf(c + CAMERA_POS + u32(i) * 4)}
	for i in 0 ..< 4 {q[i] = lf(c + CAMERA_QUAT + u32(i) * 4)}
	return
}

// CBehaviorCamera update, thiscall(dt), ret 4.
Cam_Update_00420f60 :: proc() {
	this := x86.cpu.ecx
	ci := ld(this + BEH_CAMERA)
	if ci == 0 {
		guest_cam_update()
		return
	}
	c := ci - CAMERA_IFACE
	if this != cam.beh {
		cam = {beh = this}
	} else if cam.shown && pose_is(c, cam.show_pos, cam.show_q) {
		for i in 0 ..< 3 {sf(c + CAMERA_POS + u32(i) * 4, cam.guest_pos[i])}
		for i in 0 ..< 4 {sf(c + CAMERA_QUAT + u32(i) * 4, cam.guest_q[i])}
	}
	cam.shown = false
	// The update ran this frame or the last; otherwise the camera is new or another
	// (a conversation, a cutscene) had the view, and the game's pose is a cut.
	steady := x86.frame_now - cam.frame <= 1
	x86.cpu.ecx = this
	guest_cam_update()
	cam.frame = x86.frame_now
	if !cam_on || ld(this + BEH_TARGET) == 0 {return}
	for i in 0 ..< 3 {cam.guest_pos[i] = lf(c + CAMERA_POS + u32(i) * 4)}
	for i in 0 ..< 4 {cam.guest_q[i] = lf(c + CAMERA_QUAT + u32(i) * 4)}
	cam_steer(this, steady)
	if cam.yaw == 0 && cam.pitch == 0 {return}
	cam_show(this, c)
}

// Moves the port's angles by the stick, or eases the yaw back.
@(private = "file")
cam_steer :: proc(this: u32, steady: bool) {
	dt := lf(ld(APP) + APP_DT)
	t := [3]f32{lf(this + BEH_TARGET_POS), lf(this + BEH_TARGET_POS + 4), lf(this + BEH_TARGET_POS + 8)}
	d := t - cam.last
	moving := dt > 0 && math.sqrt(d.x * d.x + d.y * d.y) > CAM_MOVING * dt
	cam.last = t
	// The pad's deadzone (win32.pad_stick) is already off the stick.
	rx, ry := cam_rx, cam_ry
	// The game's camera swung by dg round the target: the shown camera keeps
	// its heading. The swing is not checked for size: where collision pulls
	// the camera in close to the target its yaw turns by a radian or more in
	// one update, and only a cut may pass.
	g := t - cam.guest_pos
	gyaw := math.atan2(g.y, g.x)
	dg := wrap_pi(gyaw - cam.gyaw)
	cam.gyaw = gyaw
	p := world_player()
	hold := turn_on && p != 0 && ld(p + CREATURE_COMBAT) == 0
	if hold && steady {
		cam.yaw = wrap_pi(cam.yaw - dg)
	}
	if rx != 0 || ry != 0 {
		cam.rest = 0
		step := -rx * CAM_YAW_RATE * dt
		cam.yaw = math.mod(cam.yaw + step + 3 * math.PI, 2 * math.PI) - math.PI
		cam.pitch -= ry * CAM_PITCH_RATE * dt
	} else {
		cam.rest += dt
		if moving && cam.rest >= CAM_RECENTRE_WAIT {
			rate: f32 = CAM_RECENTRE_RATE
			if hold {
				// How far the player runs away from the shown camera.
				f := [2]f32{lf(p + CREATURE_FACING), lf(p + CREATURE_FACING + 4)}
				a := gyaw + cam.yaw
				rate *= max(0, f.x * math.cos(a) + f.y * math.sin(a))
			}
			cam.yaw *= math.exp(-rate * dt)
			if abs(cam.yaw) < 0.001 {cam.yaw = 0}
		}
	}
}

// Shows the game's pose turned by the port's angles round its look point.
@(private = "file")
cam_show :: proc(this, c: u32) {
	g, q := cam.guest_pos, cam.guest_q
	t := [3]f32{lf(this + BEH_TARGET_POS), lf(this + BEH_TARGET_POS + 4), lf(this + BEH_TARGET_POS + 8)}
	// The look point: where the view ray passes the target's vertical.
	f := quat_rot(q, {0, 0, -1})
	fh := f.x * f.x + f.y * f.y
	if fh < 1e-6 {return}
	s := ((t.x - g.x) * f.x + (t.y - g.y) * f.y) / fh
	if s <= 0 {return}
	p := g + f * s
	v := g - p
	h := math.sqrt(v.x * v.x + v.y * v.y)
	if h < 1e-4 {return}
	e0 := math.atan2(v.z, h)
	cam.pitch = clamp(e0 + cam.pitch, CAM_PITCH_MIN, CAM_PITCH_MAX) - e0
	// Raise about the horizontal axis across the view, then turn about z.
	k := [3]f32{v.y / h, -v.x / h, 0}
	sp, cp := math.sin(cam.pitch / 2), math.cos(cam.pitch / 2)
	sy, cy := math.sin(cam.yaw / 2), math.cos(cam.yaw / 2)
	r := quat_mul({cy, 0, 0, sy}, {cp, k.x * sp, k.y * sp, 0})
	want := p + quat_rot(r, v)
	q = quat_mul(r, q)
	// The game's collision, run from its own state as at the end of update.
	clipped, hold := ld(this + BEH_CLIPPED), ld(this + BEH_CLIP_HOLD)
	x86.cpu.esp -= 0x18
	buf := x86.cpu.esp
	for i in 0 ..< 3 {sf(buf + u32(i) * 4, want[i])}
	x86.cpu.ecx = this
	out := win32.guest_call(CAM_CLIP, buf + 0xc, buf)
	pos := [3]f32{lf(out), lf(out + 4), lf(out + 8)}
	x86.cpu.esp += 0x18
	st(this + BEH_CLIPPED, clipped)
	st(this + BEH_CLIP_HOLD, hold)
	for i in 0 ..< 3 {
		sf(c + CAMERA_POS + u32(i) * 4, pos[i])
		cam.show_pos[i] = ld(c + CAMERA_POS + u32(i) * 4)
	}
	for i in 0 ..< 4 {
		sf(c + CAMERA_QUAT + u32(i) * 4, q[i])
		cam.show_q[i] = ld(c + CAMERA_QUAT + u32(i) * 4)
	}
	cam.shown = true
}

// The yaw of the view on the camera at c, from its quaternion. Unlike the
// angle from the camera's position to the player, it holds steady when
// collision pulls the camera in close, where a small sideways offset of the
// position swung the angle. false when the view looks almost straight down.
cam_view_yaw :: proc(c: u32) -> (f32, bool) {
	q: [4]f32
	for i in 0 ..< 4 {q[i] = lf(c + CAMERA_QUAT + u32(i) * 4)}
	return quat_view_yaw(q)
}

// The yaw of the view of a camera turned by q.
quat_view_yaw :: proc(q: [4]f32) -> (f32, bool) {
	f := quat_rot(q, {0, 0, -1})
	if f.x * f.x + f.y * f.y < 0.01 {return 0, false}
	return math.atan2(f.y, f.x), true
}

// The camera still holds the pose the port showed.
@(private = "file")
pose_is :: proc(c: u32, pos: [3]u32, q: [4]u32) -> bool {
	for i in 0 ..< 3 {if ld(c + CAMERA_POS + u32(i) * 4) != pos[i] {return false}}
	for i in 0 ..< 4 {if ld(c + CAMERA_QUAT + u32(i) * 4) != q[i] {return false}}
	return true
}

// Hamilton product of quaternions stored w, x, y, z.
quat_mul :: proc(a, b: [4]f32) -> [4]f32 {
	return {
		a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
		a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
		a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
		a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0],
	}
}

// v turned by the unit quaternion q (w, x, y, z).
quat_rot :: proc(q: [4]f32, v: [3]f32) -> [3]f32 {
	u := [3]f32{q[1], q[2], q[3]}
	a := [3]f32{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x}
	b := [3]f32{u.y * a.z - u.z * a.y, u.z * a.x - u.x * a.z, u.x * a.y - u.y * a.x}
	return v + 2 * (q[0] * a + b)
}
