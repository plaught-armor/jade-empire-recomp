// Foes while player 2 is in: two heroes against the encounters made for one,
// so every foe of the player gets COOP_HEALTH times its health and fights a
// tier smarter (ai.odin foe_tier). The health comes back when player 2 leaves.
// In player 1's fight player 2's hero is in combat stance and targets a live
// foe, the nearest by player 2's aim as the player's pick weighs it
// (target.odin), kept until it falls or leaves reach or another stands well
// nearer by the aim: the game gives stance and target to the player alone, and
// a creature's combat AI, which runs what player 2's buttons push, updates
// only on its target.
// WHY: docs/recompiler.md §10
package native

import "core:fmt"
import "core:math"
import "../win32"
import "../x86"

COOP_HEALTH :: 2.0
COOP_TIER :: 1 // tiers added to a foe's, under the setting's cap

CREATURE_GET_HEALTH_BASE :: 0x004c63b0 // thiscall: the override, else the template's
FACTIONS :: 0x0076c928 // ^faction manager; its table at +4
FACTION_IS_ENEMY :: 0x00455f40 // thiscall table (faction a, faction b) -> u8, as GetIsEnemy 0x483420 calls it
OBJ_PART_FACTION :: 0x8 // in the object's vtable +0x7c part

COOP_FIGHT_REACH :: 12.0 // m, the farthest foe player 2's hero targets
COOP_SWITCH :: 0.5 // share of the target's weighted squared distance another foe must be under to take over

TARGET_OWNER :: 0x28 // in the target at CREATURE_TARGET: the creature
CREATURE_SET_COMBAT :: 0x114 // vtable: (on), the combat stance flag
TARGET_SET :: 0x0046ff70 // thiscall on CREATURE_TARGET (id, 0), ret 8

guest_target_upkeep: x86.Func

// The nearest live foe to player 2's hero by its aim of those the AI updated
// in a frame, and how near the hero's target was.
@(private = "file")
Near_Foe :: struct {
	frame: u32,
	id:    u32,
	d2:    f32, // weighted squared distance, m²
	cur:   f32, // the same of the hero's target, -1 when not seen in reach
}
@(private = "file")
near_now, near_last: Near_Foe
// Player 2's hero as of its last control update: where it stands, its aim
// (unit xy: the second pad's stick against player 2's camera, else its
// facing) and its target then.
@(private = "file")
hero_at, hero_aim: [2]f32
@(private = "file")
hero_target: u32

// A foe given more health: its base override before, to put back.
@(private = "file")
Scaled :: struct {
	flag, value: u32,
}
@(private = "file")
scaled: map[u32]Scaled
SCALED_MAX :: 256 // past it, foes no longer in the world are dropped

// Whether player 2's hero is in play: foes then scale.
coop_p2_in :: proc() -> bool {
	return coop_on && hero_id != 0 && win32.pad2_input().on
}

// Player 2's hero while in play, else 0.
coop_p2_hero :: proc() -> u32 {
	return coop_p2_in() ? win32.object_by_id(hero_id) : 0
}

// From the AI update of creature cre: scales a foe of the player once while
// player 2 is in. Calls guest code.
coop_foe_seen :: proc(cre: u32) {
	id := ld(cre + CREATURE_ID)
	if !coop_p2_in() || id == hero_id {return}
	if id in scaled {
		near_seen(cre)
		return
	}
	p := world_player()
	if p == 0 || cre == p || !is_enemy(cre, p) {return}
	if len(scaled) >= SCALED_MAX {
		gone: [SCALED_MAX]u32
		n := 0
		for k in scaled {
			if n < SCALED_MAX && win32.object_by_id(k) == 0 {gone[n] = k; n += 1}
		}
		for k in gone[:n] {delete_key(&scaled, k)}
	}
	scaled[id] = {ld(cre + CREATURE_HEALTH_BASE), ld(cre + CREATURE_HEALTH_BASE + 4)}
	base := thiscall(CREATURE_GET_HEALTH_BASE, cre)
	st(cre + CREATURE_HEALTH_BASE, 1)
	st(cre + CREATURE_HEALTH_BASE + 4, u32(f32(base) * COOP_HEALTH + 0.5))
	sf(cre + CREATURE_HEALTH_MAX, lf(cre + CREATURE_HEALTH_MAX) * COOP_HEALTH)
	sf(cre + CREATURE_HEALTH, lf(cre + CREATURE_HEALTH) * COOP_HEALTH)
	fmt.eprintfln("coop: foe %08x health %d to %d", id, base, ld(cre + CREATURE_HEALTH_BASE + 4))
}

@(private = "file")
near_seen :: proc(cre: u32) {
	if near_now.frame != x86.frame_now {
		near_last = near_now
		near_now = {frame = x86.frame_now, d2 = COOP_FIGHT_REACH * COOP_FIGHT_REACH, cur = -1}
	}
	if lf(cre + CREATURE_HEALTH) <= 0 {return}
	dx, dy := lf(cre + CREATURE_POS) - hero_at.x, lf(cre + CREATURE_POS + 4) - hero_at.y
	d2 := dx * dx + dy * dy
	if d2 > COOP_FIGHT_REACH * COOP_FIGHT_REACH {return}
	cos: f32 = 1
	if d2 > 0 {cos = (dx * hero_aim.x + dy * hero_aim.y) / math.sqrt(d2)}
	k := (1 + AIM_K * (1 - cos) / 2) / (1 + AIM_K)
	w, id := d2 * k * k, ld(cre + CREATURE_ID)
	if id == hero_target {near_now.cur = w}
	if w < near_now.d2 {near_now.id, near_now.d2 = id, w}
}

// Before player 2's control update: while the player p is in combat stance,
// player 2's hero is too and targets by the last whole frame of AI updates:
// its target while that is in reach, else the nearest foe by its aim; else
// neither. Calls guest code.
coop_fight :: proc(p, hero: u32) {
	hero_at = {lf(hero + CREATURE_POS), lf(hero + CREATURE_POS + 4)}
	if coop_pad == {} {
		hero_aim = {lf(hero + CREATURE_FACING), lf(hero + CREATURE_FACING + 4)}
	} else {
		a := coop_cam_yaw() + math.atan2(-f32(coop_pad.x), f32(coop_pad.y))
		hero_aim = {math.cos(a), math.sin(a)}
	}
	invalid := ld(OBJECT_INVALID)
	want := invalid
	if ld(p + CREATURE_COMBAT) != 0 {
		f := near_now.frame == x86.frame_now ? near_last : near_now
		if f.id != 0 && x86.frame_now - f.frame <= 1 && win32.object_by_id(f.id) != 0 {
			want = f.id
			cur := target(hero)
			if cur != invalid && f.cur >= 0 && f.d2 > f.cur * COOP_SWITCH {want = cur}
		}
	}
	hero_target = want
	on := u32(want != invalid)
	if ld(hero + CREATURE_COMBAT) != on {vcall(hero, CREATURE_SET_COMBAT, on)}
	if target(hero) != want {thiscall(TARGET_SET, hero + CREATURE_TARGET, want, 0)}
}

// A creature's target upkeep in combat stance, thiscall on CREATURE_TARGET:
// a creature not the player keeps its target only while the target fights it
// back, else picks its own. Player 2's hero keeps the one coop_fight gave it.
Target_Upkeep_004709c0 :: proc() {
	if coop_driven(ld(x86.cpu.ecx + TARGET_OWNER)) {
		x86.cpu.eax = 0
		x86.cpu.esp += 4
		return
	}
	guest_target_upkeep()
}

// The foe player 2's hero targets in a fight, 0 for none.
coop_fight_foe :: proc(hero: u32) -> u32 {
	if ld(hero + CREATURE_COMBAT) == 0 {return 0}
	id := target(hero)
	return id == ld(OBJECT_INVALID) ? 0 : win32.object_by_id(id)
}

// A creature's target id as 0x46f240 reads it: the invalid id unless set.
@(private = "file")
target :: proc(cre: u32) -> u32 {
	return ld16(cre + CREATURE_TARGET_MODE) == 1 ? ld(cre + CREATURE_TARGET) : ld(OBJECT_INVALID)
}

// Puts the foes' health back, once player 2 is out. Calls guest code.
coop_foes_restore :: proc() {
	if len(scaled) == 0 || coop_p2_in() {return}
	for id, s in scaled {
		cre := win32.object_by_id(id)
		if cre == 0 {continue}
		st(cre + CREATURE_HEALTH_BASE, s.flag)
		st(cre + CREATURE_HEALTH_BASE + 4, s.value)
		sf(cre + CREATURE_HEALTH_MAX, lf(cre + CREATURE_HEALTH_MAX) / COOP_HEALTH)
		if h := lf(cre + CREATURE_HEALTH); h > 0 {sf(cre + CREATURE_HEALTH, max(h / COOP_HEALTH, 1))}
	}
	clear(&scaled)
	fmt.eprintfln("coop: foes' health back")
}

// Whether a and b are enemies, as GetIsEnemy tells. Calls guest code.
@(private = "file")
is_enemy :: proc(a, b: u32) -> bool {
	faction :: proc(o: u32) -> u32 {
		part := vcall(o, OBJ_VT_CONVERSATION)
		return part != 0 ? ld(part + OBJ_PART_FACTION) : 0
	}
	fa, fb := faction(a), faction(b)
	saved := x86.cpu
	defer x86.cpu = saved
	x86.cpu.ecx = ld(FACTIONS) + 4
	return win32.guest_call(FACTION_IS_ENEMY, fb, fa) & 0xff != 0
}

@(private = "file")
thiscall :: proc(fn, this: u32, args: ..u32) -> u32 {
	saved := x86.cpu
	defer x86.cpu = saved
	x86.cpu.ecx = this
	return win32.guest_call(fn, ..args)
}

// thiscall(obj) through its vtable slot.
@(private = "file")
vcall :: proc(obj, slot: u32, args: ..u32) -> u32 {
	return thiscall(ld(ld(obj) + slot), obj, ..args)
}
