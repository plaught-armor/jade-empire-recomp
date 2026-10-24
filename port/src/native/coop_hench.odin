// The player's henchman while player 2 is in: player 2's hero takes her
// place in play, so outside conversations and cutscenes she is out of the
// world (deactivated, as SetObjectActive does), and back in it for them,
// where scripts speak through her. She stays in the party in support mode,
// and the mode's buff, which her update would put on the player, is put on
// him here when he goes into a fight. While she is out she is kept at the
// player's side, so she comes back there. When player 2 leaves she
// comes back with the mode she had.
// WHY: docs/recompiler.md §10
package native

import "core:fmt"
import "../win32"
import "../x86"

HENCH_N :: 13
HENCH_MODE :: 0x2c // u32 HenchmenAIData.2da row
HENCH_SUPPORT :: 1
PLAYER_SET_HENCH_MODE :: 0x004f4e80 // thiscall player (slot, mode)

// The support buff, as 0x4f1200 puts it on the player.
RULES :: 0x0076c928 // ^rules
RULES_2DA :: 0x0065e030 // thiscall rules (index) -> ^2da
HENCH_AI_2DA :: 0x50 // HenchmenAIData.2da
TWODA_INT :: 0x00658500 // thiscall 2da (row, column, ^out i32)
HENCH_AI_STATUS :: 6 // the status column
STATE_SUPPORT :: 0x35
HENCH_EFFECT :: 0x34 // u32 slot SupportEffect type (0x4ebfd0)
HENCH_EFFECT_PARAM :: 0x38 // u32 its SupportEffectParam
MODULE_NEW_EFFECT :: 0x00424c30 // thiscall module (type, param) -> ^effect, 0 for type <= 0
EFFECT_SET_CREATOR :: 0x0050fe80 // thiscall effect (^id)
CREATURE_APPLY_EFFECT :: 0x004c4eb0 // thiscall creature (effect, 0, 0)

// Object vtable slots, as SetObjectActive 0x4946c0 uses them.
OBJ_VT_ACTIVE :: 0x90 // nonzero while active
OBJ_VT_INACTIVE :: 0x94 // zero while inactive
OBJ_VT_ACTIVATE :: 0xac
OBJ_VT_DEACTIVATE :: 0xb0 // (0)

// An object's conversation part (GetIsInConversation 0x483be0) and the id of
// the conversation's owner in it.
OBJ_VT_CONVERSATION :: 0x7c
CONVERSATION_OWNER :: 0x78
MODULE_CUTSCENE :: 0x1ec // nonzero in cutscene mode (GetInCutsceneMode 0x484970)

BESIDE :: 1.0 // metres to the player's side a creature comes back at

// The henchman taken out, by id (0 for none), and the modes of the slots
// changed to support, -1 for unchanged.
@(private = "file")
hench_out: u32
// Whether the player was in a fight last frame, while she was out.
@(private = "file")
hench_fight: bool
@(private = "file")
hench_mode := [HENCH_N]i32{0 ..< HENCH_N = -1}

// Keeps the henchman of the player p out of play or in it; p2 is whether
// player 2 is in. Calls guest code.
coop_hench :: proc(p: u32, p2: bool) {
	if !p2 {
		if hench_out != 0 {
			if o := win32.object_by_id(hench_out); o != 0 && vcall(o, OBJ_VT_INACTIVE) == 0 {vcall(o, OBJ_VT_ACTIVATE)}
			hench_out = 0
		}
		for &m, i in hench_mode {
			if m < 0 {continue}
			set_mode(p, u32(i), u32(m))
			m = -1
		}
		return
	}
	id := henchman_id(p)
	// The selection changed: the old henchman is the game's again.
	if hench_out != id {hench_out = 0}
	if id == 0 {return}
	o := win32.object_by_id(id)
	if o == 0 {return}
	if coop_scene(p) || in_conversation(o) {
		if hench_out == id {
			if vcall(o, OBJ_VT_INACTIVE) == 0 {vcall(o, OBJ_VT_ACTIVATE)}
			hench_out = 0
			fmt.eprintfln("coop: henchman %08x in", id)
		}
		return
	}
	if hench_out != id {
		// Out already, by the game or a script: hers to bring back.
		if vcall(o, OBJ_VT_ACTIVE) == 0 {return}
		i := u32(x86.mem[p + HENCH_SEL])
		mode := ld(p + HENCH_SLOTS + HENCH_SIZE * i + HENCH_MODE)
		if mode != HENCH_SUPPORT {
			if hench_mode[i] < 0 {hench_mode[i] = i32(mode)}
			set_mode(p, i, HENCH_SUPPORT)
		}
		hench_out = id
		fmt.eprintfln("coop: henchman %08x out, mode %d", id, mode)
	}
	// An area change brings her back in.
	if vcall(o, OBJ_VT_ACTIVE) != 0 {vcall(o, OBJ_VT_DEACTIVATE, 0)}
	place_beside(o, p)
	// Her update, which no longer runs, puts the mode's buff on the player
	// when she goes into a fight: she goes into one with him.
	fight := ld(p + CREATURE_COMBAT) != 0
	st(o + CREATURE_COMBAT, u32(fight))
	if fight && !hench_fight {support_buff(p, o)}
	hench_fight = fight
}

// The panel showing the selected henchman's portrait and health
// (lti_curselhench, ctor 0x5499e0, update 0x5498f0), and its parts: the
// portrait, its back, the dead mark (labels), two bars and the status label.
HENCH_PANEL_VT :: 0x006faf10
HENCH_PANEL_PARTS :: [?]u32{0xd4, 0x2c4, 0x4b4, 0x6a4, 0x8d0, 0xafc}
PART_FLAGS :: 0x38 // u8 (0x521e70 sets only this byte of the dword)
PART_SHOWN :: 2 // 0x5499e0 clears it on the dead mark

// The henchman's panel hidden for a GUI draw, and its parts' flags then.
@(private = "file")
hench_panel: u32
@(private = "file")
hench_panel_flags: [len(HENCH_PANEL_PARTS)]u8

// Hides the henchman's panel in the GUI manager mgr's list while she is out,
// for one GUI draw: her portrait would show a henchman who is not there, and
// the heroes have no portrait to show player 2 by. The panel is drawn
// through its parent, so its parts are hidden, not it.
// coop_hench_panel_show shows it again.
coop_hench_panel_hide :: proc(mgr: u32) {
	hench_panel = 0
	if hench_out == 0 {return}
	n, list := ld(mgr + GUI_PANELS), ld(mgr + GUI_PANELS + 8)
	for i in u32(0) ..< n {
		g := ld(list + 4 * i)
		if g == 0 || ld(g) != HENCH_PANEL_VT {continue}
		for part, k in HENCH_PANEL_PARTS {
			f := &x86.mem[g + part + PART_FLAGS]
			hench_panel_flags[k] = f^
			f^ &~= PART_SHOWN
		}
		hench_panel = g
		return
	}
}

coop_hench_panel_show :: proc() {
	if hench_panel == 0 {return}
	for part, k in HENCH_PANEL_PARTS {x86.mem[hench_panel + part + PART_FLAGS] = hench_panel_flags[k]}
	hench_panel = 0
}

// The buff of the player p's support mode, from his henchman o, as
// 0x4f1200 puts it on him (0x4f1783 .. 0x4f17d2); the rest of that routine
// is her side of the mode, which needs her in the world. Calls guest code.
@(private = "file")
support_buff :: proc(p, o: u32) {
	saved := x86.cpu
	defer x86.cpu = saved
	sl := p + HENCH_SLOTS + HENCH_SIZE * u32(x86.mem[p + HENCH_SEL])
	// Only a row whose status column is the support state has a buff.
	x86.cpu.esp -= 4
	out := x86.cpu.esp
	st(out, 0)
	x86.cpu.ecx = ld(ld(RULES))
	x86.cpu.ecx = win32.guest_call(RULES_2DA, HENCH_AI_2DA)
	win32.guest_call(TWODA_INT, ld(sl + HENCH_MODE), HENCH_AI_STATUS, out)
	if ld(out) != STATE_SUPPORT {return}
	x86.cpu.ecx = ld(ld(APP) + APP_MODULE)
	eff := win32.guest_call(MODULE_NEW_EFFECT, ld(sl + HENCH_EFFECT), ld(sl + HENCH_EFFECT_PARAM))
	if eff == 0 {return} // none for this henchman
	x86.cpu.ecx = eff
	win32.guest_call(EFFECT_SET_CREATOR, o + CREATURE_ID)
	x86.mem[eff + 0xa] |= 0x20
	st(eff + 0xfc, 1)
	x86.cpu.ecx = p
	win32.guest_call(CREATURE_APPLY_EFFECT, eff, 0, 0)
}

// Whether the player p is in a cutscene or a conversation, where player 2's
// hero is out and the henchman in. (A minigame needs nothing: it loads its own
// module, and the area with player 2's hero goes with the old one.) Calls guest
// code.
coop_scene :: proc(p: u32) -> bool {
	m := ld(ld(APP) + APP_MODULE)
	return ld(m + MODULE_CUTSCENE) != 0 || in_conversation(p)
}

// Puts creature c at the player p's side, facing as p does: not behind, where
// it would stand between p and the camera.
place_beside :: proc(c, p: u32) {
	fx, fy := lf(p + CREATURE_FACING), lf(p + CREATURE_FACING + 4)
	sf(c + CREATURE_POS, lf(p + CREATURE_POS) + BESIDE * fy)
	sf(c + CREATURE_POS + 4, lf(p + CREATURE_POS + 4) - BESIDE * fx)
	sf(c + CREATURE_POS + 8, lf(p + CREATURE_POS + 8))
	for k in u32(0) ..< 3 {sf(c + CREATURE_FACING + 4 * k, lf(p + CREATURE_FACING + 4 * k))}
}

// Whether creature c is in a conversation, as GetIsInConversation tells.
@(private = "file")
in_conversation :: proc(c: u32) -> bool {
	owner :: proc(c: u32) -> u32 {
		r := vcall(c, OBJ_VT_CONVERSATION)
		return r != 0 ? ld(r + CONVERSATION_OWNER) : 0xffffffff
	}
	id := owner(c)
	if id == ld(c + CREATURE_ID) {return true}
	o := win32.object_by_id(id)
	return o != 0 && owner(o) == id
}

// Sets the combat mode of the player p's henchman slot i, as the party panel
// does.
@(private = "file")
set_mode :: proc(p, i, mode: u32) {
	saved := x86.cpu
	defer x86.cpu = saved
	x86.cpu.ecx = p
	win32.guest_call(PLAYER_SET_HENCH_MODE, i, mode)
}

// thiscall(obj) through its vtable slot.
@(private = "file")
vcall :: proc(obj, slot: u32, args: ..u32) -> u32 {
	saved := x86.cpu
	defer x86.cpu = saved
	x86.cpu.ecx = obj
	return win32.guest_call(ld(ld(obj) + slot), ..args)
}

// The object storage's object by id (thiscall storage (id), ret 4).
guest_object_by_id: x86.Func
SUPPORT_CREATOR_SITE :: [?]u32 {
	0x0050b38f, // the support effect's apply 0x50b1c0
	0x0050b4f6, // its removal 0x50b470
}

// The support effect's apply and removal have its creator, the henchman,
// react; while she is out of the world she has no animation to react with,
// so out of it she is none. The effects it puts on the player keep her as
// their creator, so her mode's end (0x4ef6f0) still takes them off.
Object_By_Id_004611b0 :: proc() {
	from := ld(x86.cpu.esp)
	guest_object_by_id()
	support := false
	for a in SUPPORT_CREATOR_SITE {support ||= from == a}
	if support && x86.cpu.eax != 0 && vcall(x86.cpu.eax, OBJ_VT_ACTIVE) == 0 {x86.cpu.eax = 0}
}
