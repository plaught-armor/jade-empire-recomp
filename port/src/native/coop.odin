// Co-op, a deliberate change rather than a bit-exact replacement. The second
// pad (online, the remote peer's) drives player 2's hero (coop_hero.odin):
// each frame the player's control update 0x463570 runs again on a copy of the
// player's control with the hero's id and the second pad's stick. The hero's
// combat AI (ai.odin) picks nothing and runs what the second pad's buttons
// push. Player 2 has a camera of its own (coop_camera.odin). JE_COOP=1 turns it on; off is the game as shipped. JE_NATIVE
// has no effect here.
// WHY: docs/recompiler.md §10
package native

import "core:math"
import "../win32"
import "../x86"

guest_player_control: x86.Func
guest_control_frame: x86.Func

coop_on := false

// While player 2's control update runs: the id of the henchman it drives, and the
// second pad's left stick as the virtual pad holds one (LX, LY up positive).
coop_id: u32
coop_pad: [2]i16
// The second pad's buttons as of player 2's last control update.
coop_held: bit_set[win32.Pad_Btn]

// CPlayerControl (vtable 0x6e86e8), the player's at CREATURE_CONTROL.
CREATURE_CONTROL :: 0x7ec
CONTROL_SIZE :: 0xa0
CONTROL_STICK :: 0x10 // f32 ahead (-1 full ahead), f32 across
CONTROL_CREATURE :: 0x80 // u32 object id of the creature driven

// The player's henchman slots: HENCH_N of HENCH_SIZE at HENCH_SLOTS, the
// selected one's index at HENCH_SEL (0xff for none).
HENCH_SLOTS :: 0xa28
HENCH_SIZE :: 0x8c
HENCH_ID :: 0x40 // u32 object id in a slot
HENCH_SEL :: 0x1144

// Globals the control update keeps for the player's jump and target turn.
JUMP_LATCH :: 0x0076c650
TARGET_TURN :: 0x0075b390

COOP_CONTROL :: 0x00a00400 // guest copy of the player's control for P2

// The selected henchman's object id, or 0.
henchman_id :: proc(p: u32) -> u32 {
	i := u32(x86.mem[p + HENCH_SEL])
	if i == 0xff {return 0}
	id := ld(p + HENCH_SLOTS + HENCH_SIZE * i + HENCH_ID)
	return id == ld(OBJECT_INVALID) ? 0 : id
}

// Whether player 2 drives cre: its combat AI then stays out.
coop_driven :: proc(cre: u32) -> bool {
	if !coop_on || !win32.pad2_input().on {return false}
	p := world_player()
	return p != 0 && hero_id != 0 && ld(cre + CREATURE_ID) == hero_id
}

// The direction DoEvade takes for player 2's dodge: the second pad's stick
// against player 2's camera, given as a stick against the player's facing, as the
// game turns it by the player's facing (dodge.odin). Straight ahead of cre,
// the henchman, with the stick centred.
coop_evade_dir :: proc(cre: u32) -> (x, y: f32) {
	p := world_player()
	if p == 0 {return 0, 0}
	pa := math.atan2(lf(p + CREATURE_FACING + 4), lf(p + CREATURE_FACING))
	w: f32
	if coop_pad == {} {
		w = math.atan2(lf(cre + CREATURE_FACING + 4), lf(cre + CREATURE_FACING))
	} else {
		w = coop_cam_yaw() + math.atan2(-f32(coop_pad.x), f32(coop_pad.y))
	}
	rel := w - pa // counterclockwise from the player's facing
	return -math.sin(rel), math.cos(rel)
}

// CPlayerControl frame, thiscall(dt), ret 4 (control vtable slot 8), which
// CAppBase_Update 0x40ca50 calls every frame: it runs the control update
// 0x463570 only in play, not in conversations or cutscenes. Whether player 2
// is in, and so whether the henchman or player 2's hero is in the world, is
// settled here, every frame.
Control_Frame_00464aa0 :: proc() {
	this := x86.cpu.ecx
	guest_control_frame()
	ret := x86.cpu.eax
	defer x86.cpu.eax = ret
	p := world_player()
	if p == 0 || ld(p + CREATURE_CONTROL) != this {return}
	on := coop_on && win32.pad2_input().on
	coop_hench(p, on)
	if !on {coop_foes_restore()}
	// A hero the game kept is player 2's, in or not. Out of cutscenes and
	// conversations too; coop_hero brings the hero back in play.
	coop_hero_find(p)
	if !on || coop_scene(p) {coop_hero_away()}
}

// CPlayerControl update, thiscall(dt), ret 4: moves the creature the control
// drives by its stick against the camera; player 2's against its own.
Player_Control_00463570 :: proc() {
	c := &x86.cpu
	this, dt := c.ecx, ld(c.esp + 0x4)
	guest_player_control()
	ret := c.eax
	defer c.eax = ret
	if !coop_on || !win32.pad2_input().on {return}
	p := world_player()
	if p == 0 || ld(p + CREATURE_CONTROL) != this || coop_scene(p) {return}
	hero := coop_hero(p)
	if hero == 0 || coop_hero_dead(p, hero, transmute(f32)dt) {return}
	id := ld(hero + CREATURE_ID)
	copy(x86.mem[COOP_CONTROL:][:CONTROL_SIZE], x86.mem[this:][:CONTROL_SIZE])
	st(COOP_CONTROL + CONTROL_CREATURE, id)
	left, right, held, ok := win32.pad2_read()
	if !ok {return}
	coop_fight(p, hero)
	coop_cam_update(p, hero, transmute(f32)dt, right)
	was := coop_cam_put()
	defer coop_cam_restore(was)
	coop_style(p, hero, transmute(f32)dt)
	coop_held = held
	coop_pad = {i16(left.x), i16(-left.y)}
	coop_id = id
	defer coop_id = 0
	sf(COOP_CONTROL + CONTROL_STICK, f32(left.y) / 32767)
	sf(COOP_CONTROL + CONTROL_STICK + 4, f32(left.x) / 32767)
	jump, turn := ld(JUMP_LATCH), ld(TARGET_TURN)
	esp := c.esp
	x86.push32(dt)
	x86.push32(0)
	c.ecx = COOP_CONTROL
	guest_player_control()
	if c.esp != esp {x86.fatal("coop: control update left esp %08x, expected %08x", c.esp, esp)}
	st(JUMP_LATCH, jump)
	st(TARGET_TURN, turn)
}
