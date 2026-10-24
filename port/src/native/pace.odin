// Combat pace, a deliberate change rather than a bit-exact replacement. The
// heroes' attacks and their recoveries (the m…tran anims after a swing) play
// faster, through the speed argument of the anim start 0x43fec0; damage lands
// on animation events, so it follows. A blow that lands slows the game clock
// for a moment (hit stop, win32 clock_slow): a little for a light blow the
// player lands or takes, more for a power attack.
// JE_PACE=0 keeps the original speeds, JE_HIT_STOP=0 the original impacts.
// JE_NATIVE has no effect here.
// WHY: docs/recompiler.md §10
package native

import "core:time"
import "../win32"
import "../x86"

pace_level: i32 = 1 // index into PACES
hit_stop_on := true

Pace :: struct {
	attack, recover: f32, // speed scales of the player's swings and recoveries
}
PACES := [3]Pace{{1, 1}, {1.1, 1.4}, {1.2, 1.8}}

HIT_STOP_LIGHT :: 45 * time.Millisecond
HIT_STOP_POWER :: 80 * time.Millisecond
HIT_STOP_TAKEN :: 35 * time.Millisecond
ANIM_FLAGS_IDLE :: 0x40 // ready stances, restarted every frame while idle

// A hero's swing, live from its start until the hero's next anim other than
// an idle: a hit reaction meanwhile of the foe the hero targets is its blow.
// The heroes are the player and player 2's hero (coop_foes.odin).
@(private = "file")
Swing :: struct {
	live, power: bool,
}
@(private = "file")
swings: [2]Swing

// From the anim start hook: cre starts the anim name with flags; speed is the
// address of the f32 speed argument; p is the player.
pace_anim :: proc(cre, p, name, flags, speed: u32) {
	m, d := x86.mem[name], x86.mem[name + 1]
	attack := m == 'm' && d >= '0' && d <= '9'
	hit := flags == ANIM_FLAGS_ACTION && is_hit(name)
	heroes := [2]u32{p, coop_p2_hero()}
	for h, i in heroes {
		if cre != h {continue}
		if attack {
			k := PACES[clamp(pace_level, 0, len(PACES) - 1)]
			switch flags {
			case ANIM_FLAGS_ACTION:
				sf(speed, lf(speed) * k.attack)
			case ANIM_FLAGS_RECOVER:
				sf(speed, lf(speed) * k.recover)
			}
		}
		if flags != ANIM_FLAGS_IDLE {swings[i] = {attack && flags == ANIM_FLAGS_ACTION, d == '3'}}
		if hit_stop_on && hit {win32.clock_slow(HIT_STOP_TAKEN)}
		return
	}
	if !hit_stop_on || !hit {return}
	for h, i in heroes {
		if h == 0 || !swings[i].live || ld(h + CREATURE_TARGET) != ld(cre + CREATURE_ID) {continue}
		win32.clock_slow(swings[i].power ? HIT_STOP_POWER : HIT_STOP_LIGHT)
		return
	}
}
