// Script searches while player 2 is in: GetNearestObject,
// GetNearestObjectToLocation and GetFirstObjectInShape/GetNextObjectInShape
// never find player 2's hero, so the shipped scripts that take the nth
// nearest creature or act on every creature in a shape (zmf_a_resurrect,
// j02_eud_convictj, j03_een_gasburst ...) see the world they were written
// for. Triggers never see it enter or leave, so no OnEnter script, area
// transition or trap fires for it. The engine's own searches (sounds, the
// AI) still see it.
// WHY: docs/recompiler.md §10
package native

import "../x86"

// The area's nth nearest object (thiscall area (^out id, ^pos, type, flags,
// nth), ret 0x14); nth counts from 0, and the nws function adds 1 when the
// target itself is of the type.
guest_nearest: x86.Func
NEAREST_FROM_SCRIPT :: 0x0048602c // return address in nws_GetNearestObject_etc 0x485e50
NEAREST_NTH :: 0x14 // stack offset of nth
NEAREST_MAX :: 256 // past it, searched as is

// The area's first and next object in a shape (thiscall area (shape, ^box),
// ret 8), as nws_GetFirstObjectInShape_etc 0x4863b0 walks them, and
// nws_GetFirstInObject_etc 0x484e20 over a trigger's box.
guest_shape_first: x86.Func
guest_shape_next: x86.Func
SHAPE_FROM_SCRIPT :: [?]u32 {
	0x00486837, // the first, for GetFirstObjectInShape
	0x00486845, // the next, for GetNextObjectInShape
	0x00486bbc, // the next, past one the shape left out
	0x00484ee2, // the first, for GetFirstInObject
	0x00484ef0, // the next, for GetNextInObject
	0x00484f96, // the next, past one outside the trigger
}

// nws_GetNearestObject_etc's search: past player 2's hero when it ranks
// among the nearest nth + 1, the nth of the rest.
Nearest_004ad720 :: proc() {
	esp := x86.cpu.esp
	out, nth := ld(esp + 4), ld(esp + NEAREST_NTH)
	if hero_id == 0 || ld(esp) != NEAREST_FROM_SCRIPT || nth > NEAREST_MAX {guest_nearest(); return}
	saved := x86.cpu
	for k in u32(0) ..= nth {
		x86.cpu = saved
		st(esp + NEAREST_NTH, k)
		guest_nearest()
		if ld(out) == hero_id {
			x86.cpu = saved
			st(esp + NEAREST_NTH, nth + 1)
			guest_nearest()
			st(esp + NEAREST_NTH, nth)
			return
		}
	}
	// Not among them: the last search was the nth already.
	st(esp + NEAREST_NTH, nth)
}

Shape_First_004ad810 :: proc() {shape_step(guest_shape_first)}
Shape_Next_004ad850 :: proc() {shape_step(guest_shape_next)}

// nws_GetFirstObjectInShape_etc's walk: player 2's hero is stepped over.
@(private = "file")
shape_step :: proc(step: x86.Func) {
	esp := x86.cpu.esp
	from := ld(esp)
	saved := x86.cpu
	step()
	if hero_id == 0 {return}
	script := false
	for a in SHAPE_FROM_SCRIPT {script ||= from == a}
	if !script {return}
	for x86.cpu.eax != 0 && ld(x86.cpu.eax + CREATURE_ID) == hero_id {
		x86.cpu = saved
		guest_shape_next()
	}
}

// A trigger's events (thiscall trigger (kind, ?, event by value {tag, data})).
// Kind 1 carries a script event: data u16 +0 its type, objects +0x28 count
// and +0x30 array, the first the creature entering or leaving.
guest_trigger_event: x86.Func
TRIGGER_EVENT_SCRIPT :: 1
TRIGGER_EVENT_NONE :: 0xffffffff // a kind the handler only frees
TRIGGER_ENTER :: 0xc
TRIGGER_EXIT :: 0xd
EVENT_OBJECTS_N :: 0x28
EVENT_OBJECTS :: 0x30

// CTrigger_EventHandler: player 2's hero entering or leaving is dropped.
Trigger_Event_004fd870 :: proc() {
	esp := x86.cpu.esp
	if hero_id != 0 && ld(esp + 4) == TRIGGER_EVENT_SCRIPT && ld(esp + 0xc) == 0 {
		d := ld(esp + 0x10)
		t := ld(d) & 0xffff
		if (t == TRIGGER_ENTER || t == TRIGGER_EXIT) && ld(d + EVENT_OBJECTS_N) > 0 && ld(ld(d + EVENT_OBJECTS)) == hero_id {
			st(esp + 4, TRIGGER_EVENT_NONE)
		}
	}
	guest_trigger_event()
}
