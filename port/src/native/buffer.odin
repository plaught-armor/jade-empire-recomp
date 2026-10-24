// Input buffer for the player's combat presses, a deliberate change rather
// than a bit-exact replacement. The game's press handler drops a press that
// comes while the current move is still busy (creature flags 1, 2 or 0x32),
// so a click made a little before the combo window opens is lost and the
// chain stops. The port remembers the player's last dropped press and offers
// it again on each combat input tick for BUFFER_SEC; the first tick the game
// takes it, it plays as if pressed then. A release already seen for those
// buttons is sent after the accepted retry, so nothing stays held.
// JE_BUFFER=0 keeps the original input. JE_NATIVE has no effect here.
// WHY: docs/recompiler.md §10
package native

import "core:time"
import "../win32"
import "../x86"

guest_combat_press: x86.Func
guest_combat_release: x86.Func
guest_combat_tick: x86.Func

buffer_on := true

BUFFER_SEC :: 0.35

// CCombatInput (reset 0x448f40): the per-frame input block of a creature.
INPUT_OWNER :: 0x94 // owner*, whose +0xc is the combat controller
OWNER_CONTROLLER :: 0xc
// The combat controller.
CONTROLLER_HELD :: 0x0 // u32 buttons held; the press handler clears a dropped press

COMBAT_PRESS :: 0x0044cb00 // thiscall(buttons, creature), ret 8; creature 0 = player
COMBAT_RELEASE :: 0x0044c3c0 // thiscall(buttons, creature), ret 8

// The one buffered press, live while ctrl is nonzero.
@(private = "file")
Buffered :: struct {
	ctrl:     u32,
	buttons:  u32,
	at:       time.Duration,
	released: bool,
}
@(private = "file")
buf: Buffered
@(private = "file")
retrying: bool

// Press handler: picks and queues the move for buttons, or drops the press.
Combat_Press_0044cb00 :: proc() {
	c := &x86.cpu
	this, buttons, creature := c.ecx, ld(c.esp + 0x4), ld(c.esp + 0x8)
	guest_combat_press()
	if !buffer_on || creature != 0 || buttons == 0 || retrying {return}
	if ld(this + CONTROLLER_HELD) & buttons != 0 {
		buf = {}
		return
	}
	if !player_fighting() {return}
	buf = {this, buttons, win32.host_now(), false}
}

// Release handler: a release of the buffered buttons is held back until the
// retried press is taken or expires.
Combat_Release_0044c3c0 :: proc() {
	c := &x86.cpu
	this, buttons, creature := c.ecx, ld(c.esp + 0x4), ld(c.esp + 0x8)
	guest_combat_release()
	if buf.ctrl == this && creature == 0 && buttons & buf.buttons != 0 {buf.released = true}
}

// Per-frame combat input tick, thiscall on the input block: after it runs,
// the buffered press is offered again.
Combat_Tick_0044a8d0 :: proc() {
	this := x86.cpu.ecx
	guest_combat_tick()
	if buf.ctrl == 0 {return}
	owner := ld(this + INPUT_OWNER)
	if owner == 0 || ld(owner + OWNER_CONTROLLER) != buf.ctrl {return}
	if !buffer_on || !player_fighting() || time.duration_seconds(win32.host_now() - buf.at) > BUFFER_SEC {
		buf = {}
		return
	}
	b := buf
	retrying = true
	thiscall_guest(COMBAT_PRESS, b.ctrl, b.buttons, 0)
	retrying = false
	if ld(b.ctrl + CONTROLLER_HELD) & b.buttons == 0 {return}
	buf = {}
	if b.released {thiscall_guest(COMBAT_RELEASE, b.ctrl, b.buttons, 0)}
}

// The player is in the world and in combat stance.
@(private = "file")
player_fighting :: proc() -> bool {
	p := world_player()
	return p != 0 && ld(p + CREATURE_COMBAT) != 0
}

@(private = "file")
thiscall_guest :: proc(fn, this: u32, args: ..u32) {
	x86.cpu.ecx = this
	win32.guest_call(fn, ..args)
}
