// Player 2's style switching. The game's d-pad style switch is the style
// cross panel's (CPanelFloatStyle, vtable 0x6fa7d0): d-pad left, right, up,
// down pick quick slot 0, 1, 2, 3 (vt+0x58, +0x54, +0x5c, +0x60), and
// SelectSlot (vt+0x74, 0x542440) switches the game's player to the slot's
// style. That is all on the game's player, so player 2's d-pad does here
// what SelectSlot does, on player 2's hero, with the slots its HUD shows.
// WHY: docs/recompiler.md §10
package native

import "core:fmt"
import "../win32"
import "../x86"

// thiscall(style id, 0, 1), ret 0xc: switch to the style (vt+0x128 of a
// creature, 0x4bd4f0).
CREATURE_VT_SWITCH_STYLE :: 0x128
// thiscall(style id, 1), ret 8: whether the creature may switch to it now.
CREATURE_VT_CAN_STYLE :: 0x138
// States under which SelectSlot leaves the style alone.
STYLE_STATE_BUSY :: [?]u32{0x1d, 0x36, 0x54}
STYLE_WAIT :: 0.5 // s between switches, SelectSlot's [panel+0x1838]

// The quick slot each d-pad direction picks, in PAD_DPAD's order (up, down,
// left, right).
@(private = "file")
DPAD_SLOT := [4]u32{2, 3, 0, 1}

@(private = "file")
style_wait: f32
@(private = "file")
dpad_was: u16

// Player 2's quick slots: the styles of creature cre in order, those with
// the sign bit set skipped (HasStyle 0x4bd2c0), the rest -1.
p2_style_slots :: proc(cre: u32) -> (slots: [STYLE_SLOT_N]u32) {
	k := u32(0)
	es := ld(cre + CREATURE_STYLES)
	for i in 0 ..< ld(cre + CREATURE_STYLE_N) {
		s := ld(ld(es + 4 * i))
		if s & 0x8000_0000 != 0 || k == STYLE_SLOT_N {continue}
		slots[k] = s
		k += 1
	}
	for ; k < STYLE_SLOT_N; k += 1 {slots[k] = 0xffff_ffff}
	return
}

// Runs player 2's d-pad on player 2's hero, in player 1's fight: a newly
// pressed direction switches to its slot's style. dt in seconds. Calls guest code.
coop_style :: proc(p, hero: u32, dt: f32) {
	style_wait = max(style_wait - dt, 0)
	dpad := win32.pad2_input().buttons >> len(win32.PAD_BUTTONS) & 0xf
	pressed := dpad & ~dpad_was
	dpad_was = dpad
	if pressed == 0 || style_wait > 0 {return}
	if ld(p + CREATURE_COMBAT) == 0 && ld(hero + CREATURE_COMBAT) == 0 {return}
	i := 0
	for pressed & (1 << u32(i)) == 0 {i += 1}
	s := p2_style_slots(hero)[DPAD_SLOT[i]]
	if s == 0xffff_ffff {return}
	saved := x86.cpu
	defer x86.cpu = saved
	for b in STYLE_STATE_BUSY {
		if has_state(hero, b) {return}
	}
	x86.cpu.ecx = hero
	if win32.guest_call(ld(ld(hero) + CREATURE_VT_CAN_STYLE), s, 1) == 0 {return}
	style_wait = STYLE_WAIT
	x86.cpu.ecx = hero
	win32.guest_call(ld(ld(hero) + CREATURE_VT_SWITCH_STYLE), s, 0, 1)
	fmt.eprintfln("coop: player 2 style %x", s)
}
