// D-pad menu navigation, a deliberate change rather than a bit-exact
// replacement. The game's GUI binding table (stores near 0x40d83c) maps the left
// stick to menu movement but leaves the four d-pad inputs unbound, so the
// d-pad does nothing in menus. On the GUI's reads of the pad (CXbInput
// 0x6678e0 with a2 nonzero, from GetGUIInput 0x667420) a held d-pad direction
// reads as the left stick at full deflection on that axis, so menus move
// with the game's own stick repeat. Gameplay reads (a2 0) see the pad as
// built, so the d-pad keeps its in-game bindings.
// WHY: docs/recompiler.md §10
package native

// The virtual Xbox pad CXbInput builds at this, and the copy of the previous
// call's pad it keeps at this + XB_PREV.
XB_BUTTONS :: 0x4 // u16: d-pad up 1, down 2, left 4, right 8
XB_LX :: 0x10 // i16, then LY (up positive) at 0x12
XB_PREV :: 0x1c

DPAD_FULL :: 32767

// Folds the d-pad of the pad and of its previous copy into their left sticks.
gui_dpad :: proc(this: u32) {
	for p in ([2]u32{this, this + XB_PREV}) {
		b := ld16(p + XB_BUTTONS)
		if b & 0xf == 0 {continue}
		lx, ly := i16(ld16(p + XB_LX)), i16(ld16(p + XB_LX + 2))
		if b & 1 != 0 {ly = DPAD_FULL}
		if b & 2 != 0 {ly = -DPAD_FULL}
		if b & 4 != 0 {lx = -DPAD_FULL}
		if b & 8 != 0 {lx = DPAD_FULL}
		st(p + XB_LX, u32(u16(lx)) | u32(u16(ly)) << 16)
	}
}
