// Keyboard and mouse under lockstep. The pump collects the local keyboard
// and mouse into kbm_local; each frame kbm_take hands them to that frame's
// input record. Player 1's (the host's, or the only player's) ride in its
// record as they are, and every peer replays them into the guest at the
// same frame (kbm_apply): window messages, DirectInput, GetAsyncKeyState
// and the cursor. The joining peer's become player 2's pad (kbm_pad), as
// the game has one keyboard and mouse, player 1's.
// WHY: docs/hle.md §11
package win32

import "base:intrinsics"
import "core:fmt"
import sdl "vendor:sdl3"

// A frame's keyboard and mouse. keys, buttons and at are state; mouse,
// wheel and chars are what happened during the frame (kbm_events).
Kbm :: struct {
	keys:    [8]u32, // DIK-indexed bits, down
	buttons: u8,     // DirectInput mouse buttons down: 0 left, 1 right, 2 middle, 3.. extra
	at:      [2]i16, // the cursor in client pixels
	mouse:   [2]i16, // motion in client pixels
	wheel:   i16,    // WHEEL_DELTA units
	chars:   [4]u8,  // typed, Latin-1, 0-ended
}

// The local keyboard and mouse since the last kbm_take.
@(private = "file")
kbm_local: Kbm
@(private = "file")
kbm_motion: [2]i32
@(private = "file")
kbm_wheel_sum: i32
@(private = "file")
kbm_text: [dynamic]u8
// Keys and buttons down when lockstep began, left out until let go: the
// press that started play must not reach it.
@(private = "file")
kbm_held: Kbm

// What the guest has seen: the last applied state, and the cursor (moved
// by the stream or by SetCursorPos).
@(private = "file")
kbm_seen: Kbm
@(private = "file")
kbm_cursor: [2]i16

// At lockstep's start, on every peer.
kbm_begin :: proc() {
	kbm_held = {keys = kbm_local.keys, buttons = kbm_local.buttons}
	kbm_motion, kbm_wheel_sum = {}, 0
	clear(&kbm_text)
	kbm_seen, kbm_cursor = {}, {}
	// The joiner's mouse only looks (kbm_pad): held in the window, it never
	// stops at the screen's edge.
	if window != nil && !kbm_drives_p1() && !sdl.SetWindowRelativeMouseMode(window, true) {
		fmt.eprintfln("win32: relative mouse: %s", sdl.GetError())
	}
}

// True when the local mouse is player 1's, so SetCursorPos moves it.
kbm_drives_p1 :: proc() -> bool {
	return !net_on || net_slot == 0
}

kbm_key :: proc(k: sdl.KeyboardEvent) {
	dik := scancode_dik(k.scancode)
	if dik == 0 || k.repeat {return}
	bit := u32(1) << (dik & 31)
	if k.down {kbm_local.keys[dik >> 5] |= bit} else {kbm_local.keys[dik >> 5] &~= bit}
}

kbm_char :: proc(r: rune) {
	if r > 0 && r < 0x100 {append(&kbm_text, u8(r))}
}

kbm_move :: proc(dx, dy: i32) {
	kbm_motion += {dx, dy}
}

// b: the DirectInput button.
kbm_button :: proc(b: u32, down: bool) {
	if b >= 8 {return}
	if down {kbm_local.buttons |= 1 << b} else {kbm_local.buttons &~= 1 << b}
}

kbm_wheel :: proc(d: i32) {
	kbm_wheel_sum += d
}

// The frame's local keyboard and mouse, with the cursor at host point hx, hy.
kbm_take :: proc(hx, hy: f32) -> (k: Kbm) {
	for &w, i in kbm_held.keys {w &= kbm_local.keys[i]}
	kbm_held.buttons &= kbm_local.buttons
	for w, i in kbm_local.keys {k.keys[i] = w &~ kbm_held.keys[i]}
	k.buttons = kbm_local.buttons &~ kbm_held.buttons
	if window != nil {
		x, y := to_guest(hx, hy)
		k.at = {i16(clamp(x, 0, f32(wnd_w - 1))), i16(clamp(y, 0, f32(wnd_h - 1)))}
	}
	k.mouse = {i16(clamp(kbm_motion.x, -0x7fff, 0x7fff)), i16(clamp(kbm_motion.y, -0x7fff, 0x7fff))}
	k.wheel = i16(clamp(kbm_wheel_sum, -0x7fff, 0x7fff))
	kbm_motion, kbm_wheel_sum = {}, 0
	n := min(len(kbm_text), len(k.chars))
	copy(k.chars[:], kbm_text[:n])
	remove_range(&kbm_text, 0, n)
	return
}

// True when k carries anything of its frame alone.
kbm_events :: proc(k: Kbm) -> bool {
	return k.mouse != {} || k.wheel != 0 || k.chars[0] != 0
}

// in_ with its frame's own keyboard and mouse events taken out: what a
// frame that repeats it holds.
input_held :: proc(in_: Pad_Input) -> Pad_Input {
	out := in_
	out.kbm.mouse, out.kbm.wheel, out.kbm.chars = {}, 0, {}
	return out
}

@(private = "file")
kbm_down :: proc(k: Kbm, dik: u8) -> bool {
	return k.keys[dik >> 5] & (1 << (dik & 31)) != 0
}

@(private = "file")
dik_vk :: proc(dik: u8) -> u32 {
	for m in KEYMAP {
		if m[1] == dik {return u32(m[0])}
	}
	return 0
}

// Player 1's keyboard and mouse of the frame, into the guest.
kbm_apply :: proc(k: Kbm) {
	prev := kbm_seen
	alt := kbm_down(k, 0x38) || kbm_down(k, 0xb8)
	for w in 0 ..< len(k.keys) {
		x := k.keys[w] ~ prev.keys[w]
		for x != 0 {
			b := intrinsics.count_trailing_zeros(x)
			x &= x - 1
			dik := u8(u32(w) * 32 + b)
			down := k.keys[w] & (1 << b) != 0
			di_key(dik, down)
			vk := dik_vk(dik)
			if vk == 0 {continue}
			lp := 1 | u32(dik) << 16
			if alt {lp |= 1 << 29}
			if !down {lp |= 3 << 30}
			m: u32 = down ? WM_KEYDOWN : WM_KEYUP
			if alt || vk == 0x12 {m += 4} // WM_SYS*
			post(m, vk, lp)
		}
	}
	for c in k.chars {
		if c == 0 {break}
		post(WM_CHAR, u32(c), 1)
	}
	if k.mouse != {} {di_motion(i32(k.mouse.x), i32(k.mouse.y))}
	if k.at != prev.at {kbm_cursor = k.at}
	mk := kbm_mk(k.buttons)
	if k.mouse != {} || k.at != prev.at {post(WM_MOUSEMOVE, mk, kbm_lparam())}
	// WM_[LRM]BUTTON(DOWN|UP): down codes 0x201/0x204/0x207, up = down + 1.
	MOUSE_DOWN := [3]u32{0x201, 0x204, 0x207}
	for b in u32(0) ..< 8 {
		if (k.buttons ~ prev.buttons) & (1 << b) == 0 {continue}
		down := k.buttons & (1 << b) != 0
		di_button(b, down)
		if b < 3 {post(down ? MOUSE_DOWN[b] : MOUSE_DOWN[b] + 1, mk, kbm_lparam())}
	}
	if k.wheel != 0 {
		di_wheel(i32(k.wheel))
		post(WM_MOUSEWHEEL, mk | u32(u16(k.wheel)) << 16, 0)
	}
	kbm_seen = input_held({kbm = k}).kbm
}

// MK_* bits of DirectInput buttons b.
@(private = "file")
kbm_mk :: proc(b: u8) -> u32 {
	mk := u32(0)
	if b & 1 != 0 {mk |= 0x1}
	if b & 2 != 0 {mk |= 0x2}
	if b & 4 != 0 {mk |= 0x10}
	return mk
}

@(private = "file")
kbm_lparam :: proc() -> u32 {
	return u32(u16(kbm_cursor.x)) | u32(u16(kbm_cursor.y)) << 16
}

// The guest's cursor in client pixels.
kbm_cursor_get :: proc() -> [2]i16 {
	return kbm_cursor
}

kbm_cursor_set :: proc(x, y: i32) {
	kbm_cursor = {i16(clamp(x, -0x7fff, 0x7fff)), i16(clamp(y, -0x7fff, 0x7fff))}
}

// GetAsyncKeyState of player 1's keyboard and mouse as the guest has seen it.
kbm_vk_down :: proc(vk: u32) -> bool {
	switch vk {
	case 1:
		return kbm_seen.buttons & 1 != 0
	case 2:
		return kbm_seen.buttons & 2 != 0
	case 4:
		return kbm_seen.buttons & 4 != 0
	}
	SIDED_DIK := [6]u8{0x2a, 0x36, 0x1d, 0x9d, 0x38, 0xb8}
	if vk >= 0xa0 && vk <= 0xa5 {return kbm_down(kbm_seen, SIDED_DIK[vk - 0xa0])}
	for m in KEYMAP {
		if m[0] != 0 && u32(m[0]) == vk && kbm_down(kbm_seen, m[1]) {return true}
	}
	return false
}

// The joining peer's keyboard and mouse as player 2's pad, merged into its
// pad in_, after the game's first keyboard layout ([Config1]): WASD or the
// arrows move (left Ctrl walks), the mouse looks; left button Attack (A),
// Space Block (B), right button Strong Attack (X), F Focus (Y), Left Shift
// Chi Heal (LB), E Chi Strike (RB), Q and Tab the targets (LT, RT), T No
// Target (left stick), middle button Free Look (right stick), P Combat
// Pause (Back), Esc Menu (Start), 1 to 4 the style slots (d-pad).
KBM_MOUSE_FULL :: 16 // client pixels a frame for a full right stick
kbm_pad :: proc(k: Kbm, in_: Pad_Input) -> Pad_Input {
	out := in_
	out.on = true
	key :: proc(k: Kbm, a, b: u8) -> f32 {return kbm_down(k, a) || kbm_down(k, b) ? 1 : 0}
	mx := key(k, 0x20, 0xcd) - key(k, 0x1e, 0xcb)
	my := key(k, 0x1f, 0xd0) - key(k, 0x11, 0xc8)
	s := f32(32767)
	if mx != 0 && my != 0 {s *= 0.70710678}
	if kbm_down(k, 0x1d) {s *= 0.5}
	merge :: proc(out: ^Pad_Input, a: Pad_Axis, v: f32) {
		v := i16(clamp(v, -32767, 32767))
		if abs(i32(v)) > abs(i32(out.axes[a])) {out.axes[a] = v}
	}
	merge(&out, .LX, mx * s)
	merge(&out, .LY, my * s)
	merge(&out, .RX, f32(k.mouse.x) * 32767 / KBM_MOUSE_FULL)
	merge(&out, .RY, f32(k.mouse.y) * 32767 / KBM_MOUSE_FULL)
	merge(&out, .LT, key(k, 0x10, 0x10) * 32767)
	merge(&out, .RT, key(k, 0x0f, 0x0f) * 32767)
	// PAD_BUTTONS' order (A, B, X, Y, LB, RB, Back, Start, LS, RS), then
	// PAD_DPAD's (up, down, left, right): the DIK that presses each, or
	// mouse button 0x100 + n.
	BTN := [14]u16{0x100, 0x39, 0x101, 0x21, 0x2a, 0x12, 0x19, 0x01, 0x14, 0x102, 0x04, 0x05, 0x02, 0x03}
	for b, i in BTN {
		down := b >= 0x100 ? k.buttons & (1 << (b - 0x100)) != 0 : kbm_down(k, u8(b))
		if down {out.buttons |= 1 << u16(i)}
	}
	return out
}
