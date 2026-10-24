// Player 2's HUD online. Pass B (coop_camera.odin) runs CGuiManager's draw a
// second time, from player 2's camera; there the game's player is player 2's
// hero, so the panels show player 2's health, chi and focus and styles. The
// panels holding a player's bars and style cross keep what they last showed
// (a bar flashes when its value drops, the cross when the style changes), so
// pass B draws a twin of each, made the way the game makes the panel and
// swapped into the manager's list for the pass, and the game's panels keep
// player 1's.
// The game's player is a CPlayerCreature, player 2's hero a plain CCreature
// with none of its tail (the control, the style quick slots, the henchmen),
// which the panels read. So in pass B the game's player is a stand-in: a
// CPlayerCreature-sized copy of player 2's creature made each pass, the tail
// player 1's, with player 1's vtable and player 2's styles in the quick
// slots. What the panels write to it is dropped.
// WHY: docs/recompiler.md §10
package native

import "core:fmt"
import "../win32"
import "../x86"

guest_get_player: x86.Func

OPERATOR_NEW :: 0x006b27aa // cdecl operator new (size)
PANEL_PARENT :: 0x28 // the panel's parent, its ctor's argument
PANEL_VT_DELETE :: 0 // thiscall (1): destroys and frees it (0x57dfd0, base 0x51e490)
GUI_PANEL_HELD :: 0x0075b550 // ^panel, cleared when that panel is deleted
PANEL_FLAGS :: 0x48 // u32; bit 0x200 while shown
GUI_PANELS :: 0x30 // CGuiManager: count, then the panel array at +8
CREATURE_SIZE :: 0x7e8 // CCreature, as 0x45ed90 makes one
PLAYER_SIZE :: 0x12f0 // CPlayerCreature, as 0x45edeb makes one
STYLE_SLOTS :: 0x810 // CPlayerCreature: 10 quick slots, style id or -1
STYLE_SLOT_N :: 10
// CPanelFloatStyle style change, thiscall(style id, 1): the cross picks the
// style's slot and the label shows its name for a while. SetCurrentStyle
// 0x4bd720 calls it on the game's panel for the player only.
STYLE_CHANGED :: 0x00543030

// The panels a player has his own of: vtable, size, ctor thiscall (parent).
@(private = "file")
Hud_Kind :: struct {
	vtable, size, ctor: u32,
}
@(private = "file")
HUD_KINDS :: [?]Hud_Kind {
	{0x006ffe10, 0x1940, 0x0057da90}, // lti_fltingcombat: health, chi, focus
	{0x006fa7d0, 0x18f0, 0x005425c0}, // lti_floatstyle: the style cross
}

// Per kind, the game's panel a twin was made for, and the twin.
@(private = "file")
Twin :: struct {
	game, twin: u32,
}
@(private = "file")
twins: [len(HUD_KINDS)]Twin
// The manager's list slot each twin stands in for the pass, -1 for none.
@(private = "file")
twin_slot: [len(HUD_KINDS)]i32
// The stand-in for the game's player while pass B's GUI draws, else 0.
// The style the style twin was last told player 2 uses, -1 for none.
@(private = "file")
twin_style: u32 = 0xffff_ffff
@(private = "file")
hud_player: u32
// The stand-in's memory, made once.
@(private = "file")
stand_in: u32

// Puts player 2's panels in the manager mgr's list for pass B's GUI draw;
// coop_hud_end takes them out. Calls guest code.
coop_hud_begin :: proc(mgr: u32) {
	for &s in twin_slot {s = -1}
	hud_player = 0
	cre := hero_id != 0 ? win32.object_by_id(hero_id) : 0
	if cre == 0 {return}
	p := game_player()
	if p == 0 {return}
	if stand_in == 0 {stand_in = guest_new(PLAYER_SIZE)}
	if stand_in == 0 {return}
	copy(x86.mem[stand_in:stand_in + CREATURE_SIZE], x86.mem[cre:cre + CREATURE_SIZE])
	copy(x86.mem[stand_in + CREATURE_SIZE:stand_in + PLAYER_SIZE], x86.mem[p + CREATURE_SIZE:p + PLAYER_SIZE])
	st(stand_in, ld(p))
	// Player 2's styles in the quick slots.
	for s, k in p2_style_slots(cre) {st(stand_in + STYLE_SLOTS + 4 * u32(k), s)}
	hud_player = stand_in
	n, list := ld(mgr + GUI_PANELS), ld(mgr + GUI_PANELS + 8)
	for i in u32(0) ..< n {
		g := ld(list + 4 * i)
		if g == 0 {continue}
		for k, j in HUD_KINDS {
			if ld(g) != k.vtable {continue}
			t := &twins[j]
			// A new panel of the game's (a load makes them again): a new twin.
			if t.game != g {
				free_twin(t.twin)
				t^ = {g, make_twin(k, g)}
				if k.vtable == HUD_KINDS[1].vtable {twin_style = 0xffff_ffff}
			}
			if t.twin == 0 {continue}
			st(t.twin + PANEL_FLAGS, ld(g + PANEL_FLAGS))
			st(list + 4 * i, t.twin)
			twin_slot[j] = i32(i)
			if k.vtable == HUD_KINDS[1].vtable {style_changed(t.twin, cre)}
		}
	}
}

// Tells the style twin of the style player 2's hero cre uses when it changed.
// Calls guest code.
@(private = "file")
style_changed :: proc(twin, cre: u32) {
	i := ld(cre + CREATURE_STYLE)
	if i >= ld(cre + CREATURE_STYLE_N) {return}
	s := ld(ld(ld(cre + CREATURE_STYLES) + 4 * i))
	if s == twin_style {return}
	twin_style = s
	saved := x86.cpu
	defer x86.cpu = saved
	x86.cpu.ecx = twin
	win32.guest_call(STYLE_CHANGED, s, 1)
}

coop_hud_end :: proc(mgr: u32) {
	list := ld(mgr + GUI_PANELS + 8)
	for s, j in twin_slot {
		if s >= 0 {st(list + 4 * u32(s), twins[j].game)}
	}
	for &s in twin_slot {s = -1}
	hud_player = 0
}

// A panel of kind k under game's parent, made as the game makes it. Calls guest code.
@(private = "file")
make_twin :: proc(k: Hud_Kind, game: u32) -> u32 {
	saved := x86.cpu
	defer x86.cpu = saved
	p := guest_new(k.size)
	if p == 0 {return 0}
	x86.cpu.ecx = p
	win32.guest_call(k.ctor, ld(game + PANEL_PARENT))
	fmt.eprintfln("coop: player 2 panel %08x for %08x", p, game)
	return p
}

// Deletes a twin, as the game deletes a panel. Its parent is the old game
// panel's, which the load that made the new one may have freed; the twin is
// not among the parent's children, so the delete is told it has no parent
// (it would look for the twin there to take it out). Calls guest code.
@(private = "file")
free_twin :: proc(twin: u32) {
	if twin == 0 {return}
	saved := x86.cpu
	defer x86.cpu = saved
	st(twin + PANEL_PARENT, 0)
	// Cleared by the delete only for a panel with a parent.
	if ld(GUI_PANEL_HELD) == twin {st(GUI_PANEL_HELD, 0)}
	x86.cpu.ecx = twin
	win32.guest_call(ld(ld(twin) + PANEL_VT_DELETE), 1)
	fmt.eprintfln("coop: player 2 panel %08x deleted", twin)
}

@(private = "file")
game_player :: proc() -> u32 {
	saved := x86.cpu
	defer x86.cpu = saved
	x86.cpu.ecx = ld(ld(APP) + APP_MODULE)
	win32.guest_call(GET_PLAYER)
	return x86.cpu.eax
}

@(private = "file")
guest_new :: proc(size: u32) -> u32 {
	saved := x86.cpu
	defer x86.cpu = saved
	return win32.guest_call_c(OPERATOR_NEW, size)
}

// The game's player, thiscall on the module: the stand-in for player 2's
// hero while pass B's GUI draws. There its callers are the style cross, the
// bars, the area map (which so centres on player 2) and the henchman panel
// (hidden while player 2 is in); all of them should show player 2.
Get_Player_00424700 :: proc() {
	guest_get_player()
	if hud_player != 0 && x86.cpu.eax != 0 {x86.cpu.eax = hud_player}
}
