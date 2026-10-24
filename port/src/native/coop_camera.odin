// Player 2's camera online. Each peer shows its own player's camera; nothing
// about the two views has to match. What has to match is what play reads
// from a camera: player 2's stick moves the hero against player 2's camera,
// so both peers keep that camera, from lockstep input only, and the hero's
// control update and dodge run with it on the game's camera. The joiner then
// draws its frames with it. It is the player's camera at its offset from the
// look point (held while the game's collision pulls the player's in, and
// while combat's camera, which frames the player's fight, has the view), turned
// to a yaw of its own round player 2's hero and pulled in by the game's
// collision: the second pad's right stick turns it, and while the hero moves
// and the stick rests it eases back behind the hero as fast as the hero runs
// away from it, as the free camera (camera.odin) does. In player 1's fight
// it frames player 2's hero and the nearest live foe: its look point eased
// halfway to the foe, its offset lengthened by half their distance, and the
// stick resting, its yaw eased to look past the hero at the foe. Its pitch is the
// game's: the offset is taken from the game's own pose, not the free
// camera's shown one, which the free camera pulls in by collision with the
// collision's flags put back.
// WHY: docs/recompiler.md §10
package native

import "core:fmt"
import "core:mem"
import "core:math"
import "../win32"
import "../x86"

guest_gui_draw: x86.Func
guest_scene_tick: x86.Func

@(private = "file")
Coop_Cam :: struct {
	frame: u32, // frame of the last update, 0 for none
	yaw:   f32, // radians, the view's heading
	rest:  f32, // seconds the stick has rested
	last:  [3]f32, // the hero's position last update
	off:   [3]f32, // the camera from its look point, turned to yaw 0
	rel:   [4]f32, // the camera's rotation, turned to yaw 0
	lift:  f32, // the look point over the creature
	shift: [2]f32, // the look point off the hero, towards the foe framed
	scale: f32, // the offset's length, times
	pos:   [3]f32, // the pose
	q:     [4]f32,
}
@(private = "file")
pc: Coop_Cam

COOP_CAM_LIFT :: 1.5 // the look point over the creature, until the player's camera tells
COOP_CLIP :: 0x00a00500 // the behaviour block player 2's clip runs on
BEH_CLIP_SIZE :: 0xf0 // what of a CBehaviorCamera 0x420730 reads and writes
COOP_FRAME_SPREAD :: 0.5 // the offset grows by this times the foe's distance
COOP_FRAME_MAX :: 2.0 // the offset's length at most, times
COOP_FRAME_RATE :: 3.0 // 1/s, how fast the framing eases in and out
COOP_FRAME_TURN :: 2.0 // 1/s, how fast the view turns to the foe

// Whether player 2's camera was updated this frame or the last.
coop_cam_live :: proc() -> bool {
	return pc.frame != 0 && x86.frame_now - pc.frame <= 1
}

// Player 2's camera yaw, for the dodge's stick (coop.odin).
coop_cam_yaw :: proc() -> f32 {return pc.yaw}

// Moves player 2's camera on by the right stick r (SDL's axes) for the hero
// of the player p. Calls guest code.
coop_cam_update :: proc(p, hero: u32, dt: f32, r: [2]i32) {
	c := ld(ld(ld(APP) + APP_MODULE) + MODULE_CAMERA)
	pos := [3]f32{lf(hero + CREATURE_POS), lf(hero + CREATURE_POS + 4), lf(hero + CREATURE_POS + 8)}
	face := math.atan2(lf(hero + CREATURE_FACING + 4), lf(hero + CREATURE_FACING))
	steady := coop_cam_live()
	if !steady {pc = {yaw = face, lift = COOP_CAM_LIFT, last = pos, rel = {1, 0, 0, 0}, scale = 1}}
	pc.frame = x86.frame_now
	// The player's camera, its heading taken off.
	beh := cam_behaviour(c)
	g, q := cam_game_pose(c)
	t := [3]f32{lf(p + CREATURE_POS), lf(p + CREATURE_POS + 4), lf(p + CREATURE_POS + 8) + pc.lift}
	if beh != 0 {
		for i in 0 ..< 3 {t[i] = lf(beh + BEH_TARGET_POS + u32(i) * 4)}
		pc.lift = t.z - lf(p + CREATURE_POS + 8)
	}
	if yaw, ok := quat_view_yaw(q); ok && (!steady || beh != 0 && ld(beh + BEH_CLIPPED) == 0) {
		un := [4]f32{math.cos(-yaw / 2), 0, 0, math.sin(-yaw / 2)}
		pc.off = quat_rot(un, g - t)
		pc.rel = quat_mul(un, q)
	}
	// In a fight it frames the hero and the hero's target: its look point
	// halfway to the foe, pulled back by half their distance, and, the stick
	// resting, turned to look past the hero at the foe.
	shift, scale := [2]f32{}, f32(1)
	to: [2]f32
	foe := coop_fight_foe(hero)
	if foe != 0 {
		to = {lf(foe + CREATURE_POS) - pos.x, lf(foe + CREATURE_POS + 4) - pos.y}
		sep := math.sqrt(to.x * to.x + to.y * to.y)
		shift = to / 2
		l := math.sqrt(pc.off.x * pc.off.x + pc.off.y * pc.off.y + pc.off.z * pc.off.z)
		scale = clamp(1 + sep * COOP_FRAME_SPREAD / max(l, 0.1), 1, COOP_FRAME_MAX)
	}
	ease := 1 - math.exp(-COOP_FRAME_RATE * dt)
	pc.shift += (shift - pc.shift) * ease
	pc.scale += (scale - pc.scale) * ease
	// The stick turns it; resting, it eases back behind a hero that moves.
	d := pos - pc.last
	moving := dt > 0 && math.sqrt(d.x * d.x + d.y * d.y) > CAM_MOVING * dt
	pc.last = pos
	rx := f32(r.x) / 32767
	if rx != 0 {
		pc.rest = 0
		pc.yaw = wrap_pi(pc.yaw - rx * CAM_YAW_RATE * dt)
	} else {
		pc.rest += dt
		if pc.rest >= CAM_RECENTRE_WAIT && (foe != 0 || moving) {
			back, rate: f32
			if foe != 0 {
				back = wrap_pi(math.atan2(to.y, to.x) - pc.yaw)
				rate = COOP_FRAME_TURN
			} else {
				back = wrap_pi(face - pc.yaw)
				rate = CAM_RECENTRE_RATE * max(0, math.cos(back))
			}
			pc.yaw = wrap_pi(pc.yaw + back * (1 - math.exp(-rate * dt)))
		}
	}
	// Round the hero's look point, pulled in by the game's collision as the
	// player's camera is.
	turn := [4]f32{math.cos(pc.yaw / 2), 0, 0, math.sin(pc.yaw / 2)}
	look := pos + {pc.shift.x, pc.shift.y, pc.lift}
	want := look + quat_rot(turn, pc.off * pc.scale)
	pc.q = quat_mul(turn, pc.rel)
	pc.pos = want
	// The clip reads the camera and the look point from the behaviour it runs
	// on, and leaves its flags there. Combat's camera is another behaviour, so
	// the clip runs on a block of the port's own.
	mem.zero(&x86.mem[COOP_CLIP], BEH_CLIP_SIZE)
	st(COOP_CLIP + BEH_TARGET, p)
	st(COOP_CLIP + BEH_CAMERA, c + CAMERA_IFACE)
	for i in 0 ..< 3 {sf(COOP_CLIP + BEH_TARGET_POS + u32(i) * 4, look[i])}
	cpu := x86.cpu
	defer x86.cpu = cpu
	x86.cpu.esp -= 0x18
	buf := x86.cpu.esp
	for i in 0 ..< 3 {sf(buf + u32(i) * 4, want[i])}
	x86.cpu.ecx = COOP_CLIP
	out := win32.guest_call(CAM_CLIP, buf + 0xc, buf)
	for i in 0 ..< 3 {pc.pos[i] = lf(out + u32(i) * 4)}
}

// The game's camera pose as stored: position then rotation.
Cam_Pose :: [7]u32

// Puts player 2's camera on the game's camera and returns the pose it had.
coop_cam_put :: proc() -> (was: Cam_Pose) {
	c := ld(ld(ld(APP) + APP_MODULE) + MODULE_CAMERA)
	for i in 0 ..< 7 {was[i] = ld(c + CAMERA_POS + u32(i) * 4)}
	for i in 0 ..< 3 {sf(c + CAMERA_POS + u32(i) * 4, pc.pos[i])}
	for i in 0 ..< 4 {sf(c + CAMERA_QUAT + u32(i) * 4, pc.q[i])}
	return
}

// The joiner hears from player 2's camera, which it shows: the mixer carries
// the game's listener from the game's camera to it (win32.ds_view).
@(private = "file")
coop_cam_ear :: proc() {
	v := &win32.ds_view
	v.on = coop_cam_dual() && win32.net_slot != 0
	if !v.on {return}
	c := ld(ld(ld(APP) + APP_MODULE) + MODULE_CAMERA)
	q: [4]f32
	for i in 0 ..< 3 {v.from[i] = lf(c + CAMERA_POS + u32(i) * 4)}
	for i in 0 ..< 4 {q[i] = lf(c + CAMERA_QUAT + u32(i) * 4)}
	v.to = pc.pos
	r := quat_mul(pc.q, {q[0], -q[1], -q[2], -q[3]})
	for i in 0 ..< 3 {
		e: [3]f32
		e[i] = 1
		col := quat_rot(r, e)
		for j in 0 ..< 3 {v.rot[j, i] = col[j]}
	}
	if r := p2_reverb(); r != v.reverb {
		v.reverb = r
		fmt.eprintfln("coop: player 2 reverb room %d decay %.2f", i32(r[0]), transmute(f32)r[3])
	}
}

// The sound environment the game picks at the player (CExoSound's update,
// 0x66fb6d), picked at player 2's hero: the first of the area's sound shapes
// around the point 1.8 m over its feet that has an environment, and that
// environment's reverb (CArea 0x4ae500, CExoSound 0x669600). Outside any, or
// with environments off, a buffer's default parameters. Calls guest code.
AREA_OF :: 0x004246d0 // thiscall on the module: the current area
AREA_SOUND_ON :: 0x38 // -1 while the area has no sound environments
AREA_RES :: 0x1c // its resource: environments at +0x140, count at +0x144
AREA_ENVS :: 0x140
AREA_ENV_SIZE :: 0x28
AREA_ENV_REVERB :: 0x18 // the environment's reverb index
SHAPE_COUNT :: 0x00668d40 // thiscall area () -> its sound shapes count
SHAPE_AT :: 0x00668cf0 // thiscall area (i) -> shape
SHAPE_HAS :: 0x004fe440 // thiscall shape (^point): inside
SHAPE_ENV :: 0x20
EXO_SOUND :: 0x0076c92c // ^CExoSound
EXO_REVERBS :: 0x440 // ^reverb parameters, 0x30 bytes each; count at +0x444
EXO_REVERBS_ON :: 0x00769d90 // u8
EAR_LIFT :: 1.8

@(private = "file")
p2_reverb :: proc() -> (out: [win32.DS_REVERB_WORDS]u32) {
	out = transmute([win32.DS_REVERB_WORDS]u32)win32.DS_REVERB_PRESETS[0]
	cre := hero_id != 0 ? win32.object_by_id(hero_id) : 0
	exo := ld(EXO_SOUND)
	if cre == 0 || exo == 0 || x86.mem[EXO_REVERBS_ON] == 0 {return}
	cpu := x86.cpu
	defer x86.cpu = cpu
	x86.cpu.ecx = ld(ld(APP) + APP_MODULE)
	area := win32.guest_call(AREA_OF)
	if area == 0 || ld(area + AREA_SOUND_ON) == 0xffff_ffff {return}
	x86.cpu.esp -= 0x10
	pt := x86.cpu.esp
	for i in 0 ..< 3 {sf(pt + u32(i) * 4, lf(cre + CREATURE_POS + u32(i) * 4))}
	sf(pt + 8, lf(pt + 8) + EAR_LIFT)
	env: u32
	x86.cpu.ecx = area
	n := win32.guest_call(SHAPE_COUNT)
	for i in u32(0) ..< n {
		x86.cpu.ecx = area
		shape := win32.guest_call(SHAPE_AT, i)
		if shape == 0 {continue}
		x86.cpu.ecx = shape
		if win32.guest_call(SHAPE_HAS, pt) == 0 {continue}
		env = ld(shape + SHAPE_ENV)
		if env != 0 {break}
	}
	res := ld(area + AREA_RES)
	if res == 0 || env >= ld(res + AREA_ENVS + 4) {return}
	r := ld(ld(res + AREA_ENVS) + env * AREA_ENV_SIZE + AREA_ENV_REVERB)
	if r == 0 || r >= ld(exo + EXO_REVERBS + 4) {return}
	at := ld(exo + EXO_REVERBS) + r * 0x30
	for &w, i in out {w = ld(at + u32(i) * 4)}
	return
}

coop_cam_restore :: proc(was: Cam_Pose) {
	c := ld(ld(ld(APP) + APP_MODULE) + MODULE_CAMERA)
	for i in 0 ..< 7 {st(c + CAMERA_POS + u32(i) * 4, was[i])}
}

// What a peer draws has to leave the game as the other peer's drawing does:
// drawing allocates (the heap's blocks then differ in place), updates fades,
// particles and ropes, and fills caches, all by what the view sees. So while
// player 2 plays, both peers draw the frame's view twice, the same way: pass
// A from the game's camera, pass B from player 2's. A peer shows its own
// player's pass and draws the other with win32.null_render, which leaves the
// game as a drawn pass does. A view is the scene's tick phases 1 and 2, the
// GUI's root, and CGuiManager's draw (MainLoop 0x4a4917 .. 0x4a496c), which
// draws the world's labels and overlays over it; pass B runs after pass A's
// GUI. Each pass takes half the frame's time (DT, which MainLoop sets and the
// draws read), so what the draws move on moves on once a frame.
DT :: 0x0075ecd0 // f32 seconds, the frame's time
DRAW_GUI :: 0x0075b3c4 // MainLoop draws the GUI while this and GUI_SHOWN are set
GUI_SHOWN :: 0x0076f90c // u8
GUI_ROOT :: 0x005da240

// The scene's tick, thiscall(phase), ret 4: MainLoop runs phase 0 before the
// update, phase 1 in it (0x40cc96) and phase 2 after it. Phases 1 and 2 each
// draw part of the view, from the camera's pose then.
Scene_Tick_005df230 :: proc() {
	phase := ld(x86.cpu.esp + 4)
	if phase == 2 {coop_cam_ear()}
	if phase == 0 || phase > 2 || !coop_cam_dual() {
		guest_scene_tick()
		return
	}
	if phase == 1 {
		win32.null_render = win32.net_slot != 0
		guest_scene_tick()
		win32.null_render = false
		return
	}
	dual.dt = ld(DT)
	sf(DT, transmute(f32)dual.dt / 2)
	dual.tick = x86.cpu.ecx
	entry := x86.cpu
	win32.null_render = win32.net_slot != 0
	guest_scene_tick()
	win32.null_render = false
	if ld(DRAW_GUI) != 0 && x86.mem[GUI_SHOWN] != 0 {
		dual.gui = true // CGuiManager's draw runs pass B
		return
	}
	done := x86.cpu
	x86.cpu = entry
	pass_b(false)
	x86.cpu = done
}

Gui_Draw_0051e090 :: proc() {
	coop_hench_panel_hide(x86.cpu.ecx)
	defer coop_hench_panel_show()
	if !dual.gui {
		guest_gui_draw()
		return
	}
	dual.gui = false
	entry := x86.cpu
	frame := [2]u32{ld(entry.esp), ld(entry.esp + 4)}
	win32.null_render = win32.net_slot != 0
	guest_gui_draw()
	win32.null_render = false
	x86.cpu = entry
	pass_b(true)
	x86.cpu = entry
	st(entry.esp, frame[0])
	st(entry.esp + 4, frame[1])
	coop_hud_begin(entry.ecx)
	win32.null_render = win32.net_slot != 1
	guest_gui_draw()
	win32.null_render = false
	coop_hud_end(entry.ecx)
	coop_cam_restore(game_pose)
	game_pose_out = false
	st(DT, dual.dt)
}

// The pass from player 2's camera, the GUI's draw (with gui) left to the
// caller, with player 2's camera left on the game's.
@(private = "file")
pass_b :: proc(gui: bool) {
	game_pose = coop_cam_put()
	game_pose_out = true
	win32.null_render = win32.net_slot != 1
	cpu := x86.cpu
	for phase in u32(1) ..= 2 {
		x86.cpu = cpu
		x86.cpu.ecx = dual.tick
		x86.push32(phase)
		x86.push32(0) // return address; generated code returns natively
		guest_scene_tick()
	}
	if gui {
		win32.guest_call(GUI_ROOT)
		win32.null_render = false
		return
	}
	win32.null_render = false
	coop_cam_restore(game_pose)
	game_pose_out = false
	st(DT, dual.dt)
}

// The frame's two passes: the frame's time, the camera ticked, and whether
// CGuiManager's draw has pass B to run.
@(private = "file")
Dual :: struct {
	dt:   u32,
	tick: u32,
	gui:  bool,
}
@(private = "file")
dual: Dual

// While player 2's camera is on the game's, the pose the game gave it, and
// whether player 2's is on it now.
@(private = "file")
game_pose: Cam_Pose
@(private = "file")
game_pose_out: bool

// What the simulation takes from the camera must be the same whichever pass
// it is read in: an object's depth from it (Object_BoxZGap) sets its level of
// detail, which decides how its animation runs, as in a game without player
// 2. While player 2's camera is on the game's camera c, puts the game's pose
// back on it and returns true; coop_cam_unlend then puts player 2's back.
coop_cam_lend :: proc(c: u32) -> bool {
	if !game_pose_out || c != ld(ld(ld(APP) + APP_MODULE) + MODULE_CAMERA) {return false}
	coop_cam_restore(game_pose)
	game_pose_out = false
	return true
}

coop_cam_unlend :: proc() {
	coop_cam_put()
	game_pose_out = true
}

// Whether the peers draw both players' views.
@(private = "file")
coop_cam_dual :: proc() -> bool {
	return win32.net_on && coop_cam_live()
}
