// Right-stick target switching in locked combat, a deliberate change rather
// than a bit-exact replacement. While the player is in combat with a target,
// a flick of the right stick left or right presses the virtual pad's left or
// right trigger, the game's previous and next target, for one frame; the
// stick then has to come back near centre before it flicks again. The right
// stick moves nothing else while locked. JE_FLICK=0 keeps the original right
// stick. JE_NATIVE has no effect here.
// WHY: docs/recompiler.md §10
package native

import "../x86"

guest_xb_input: x86.Func

flick_on := true

// CXbInput (one per controller port, 0x33a8 bytes apart), the virtual Xbox
// pad it builds each call.
XB_LT :: 0xe // u8 analog trigger: previous target
XB_RT :: 0xf // u8: next target
XB_RX :: 0x14 // i16
XB_RY :: 0x16 // i16

FLICK_CENTRE :: 0x2ccc // both axes within this rearm the flick
FLICK_FIRE :: 0x5333 // x past this, and past |y|, flicks

APP_STATE :: 0x38 // u32: 0 or 5 while the world runs
MODULE_PARTY :: 0x0 // creature**
MODULE_PARTY_N :: 0x4
OBJECT_INVALID :: 0x0075b394 // u32 holding the invalid object id
CREATURE_TARGET :: 0x58c // u32 object id
CREATURE_TARGET_MODE :: 0x590 // u16, 1 when locked on
GAME_RUNNING :: 0x0075ecdc // u32, nonzero in a module

// Flick state per CXbInput. A frame can build the same pad more than once,
// so a flick is held for every call in the frame it fired.
FLICK_PADS :: 8
Flick_Pad :: struct {
	this:  u32,
	armed: bool,
	frame: u32, // frame of the last call
	dir:   i32, // -1, 1: flicked this frame
}
@(private = "file")
flick_pads: [FLICK_PADS]Flick_Pad

// thiscall(a1, a2), ret 8: rebuilds the virtual pad at this.
Xb_Input_006678e0 :: proc() {
	this, gui := x86.cpu.ecx, ld(x86.cpu.esp + 8) != 0
	guest_xb_input()
	if gui {gui_dpad(this)} else {move_pad_read(this)}
	flick(this)
	cam_pad(this)
}

// Fires and holds the flicks of the pad at this, and centres its right stick
// while locked.
@(private = "file")
flick :: proc(this: u32) {
	if !flick_on {return}
	f := flick_pad(this)
	if f == nil {return}
	if !locked() {
		f.armed, f.dir = false, 0
		return
	}
	rx, ry := i32(i16(ld(this + XB_RX))), i32(i16(ld(this + XB_RY)))
	if f.frame != x86.frame_now {
		f.frame, f.dir = x86.frame_now, 0
		if abs(rx) <= FLICK_CENTRE && abs(ry) <= FLICK_CENTRE {
			f.armed = true
		} else if f.armed && abs(rx) >= FLICK_FIRE && abs(rx) > abs(ry) {
			f.armed, f.dir = false, rx < 0 ? -1 : 1
		}
	}
	st(this + XB_RX, 0) // RX and RY
	if f.dir != 0 && ld(this + XB_LT) & 0xffff == 0 {
		st8(this + (f.dir < 0 ? XB_LT : XB_RT), 0xff)
	}
}

// The state for one CXbInput, taking a free slot on first use; nil when all
// are taken.
@(private = "file")
flick_pad :: proc(this: u32) -> ^Flick_Pad {
	for &f in flick_pads {
		if f.this == this {return &f}
	}
	for &f in flick_pads {
		if f.this == 0 {
			f.this = this
			return &f
		}
	}
	return nil
}

// The party's one creature is in combat locked on a target.
@(private = "file")
locked :: proc() -> bool {
	c := world_player()
	return c != 0 && ld(c + CREATURE_COMBAT) != 0 && ld(c + CREATURE_TARGET_MODE) & 0xffff == 1 &&
		ld(c + CREATURE_TARGET) != ld(OBJECT_INVALID)
}

// The party's one creature while the world runs, else 0.
world_player :: proc() -> u32 {
	app := ld(APP)
	if app == 0 || ld(GAME_RUNNING) == 0 {return 0}
	if s := ld(app + APP_STATE); s != 0 && s != 5 {return 0}
	m := ld(app + APP_MODULE)
	if m == 0 || ld(m + MODULE_PARTY_N) != 1 || ld(m + MODULE_PARTY) == 0 {return 0}
	return ld(ld(m + MODULE_PARTY))
}
