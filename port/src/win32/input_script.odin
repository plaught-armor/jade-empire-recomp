// Scripted input for unattended test runs (JE_INPUT_SCRIPT). The script is a
// comma-separated list of `frame:Action`, frame counting presented frames
// from boot, or `+frame:Action` counting frames of lockstep play from its
// start (lockstep.odin), for runs whose menus before it differ:
//   Key           SDL scancode name ("Down", "Return", "Escape", "A"): a tap.
//   Key~N         the key held for N frames.
//   Move@x/y      move the pointer to guest client pixel (x, y).
//   Click@x/y     move there, then a left-button tap.
//   Pad.name      a gamepad button ("a", "start", "dpup") or axis ("leftx",
//                 "righttrigger") tap, the axis at full deflection; ~N holds.
//                 "Pad.-leftx" deflects an axis fully negative.
//                 Any Pad action attaches a virtual SDL gamepad at startup.
// Taps push the down event at that presented frame and the up event
// INPUT_TAP_FRAMES later. Every event is a real SDL event at host window
// coordinates, so it travels the same pump path (window messages, DirectInput,
// guest coordinate mapping) as physical input.
package win32

import "core:c"
import "core:fmt"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"
import "../x86"

INPUT_TAP_FRAMES :: 4
INPUT_SCRIPT_MAX :: 1024

Input_Kind :: enum u8 {Key, Move, Button, Pad_Button, Pad_Axis}

Input_Tap :: struct {
	frame: u32,
	kind:  Input_Kind,
	down:  bool,
	key:   sdl.Scancode,
	pad:   c.int, // Pad_*: SDL gamepad button or axis
	btn:   u8, // Button: SDL mouse button, 1 left, 2 middle, 3 right
	value: i16, // Pad_Axis while down: deflection
	p2:    bool, // Pad_*: on the second virtual gamepad
	x, y:  f32, // Move: guest client pixels
	play:  bool, // frame counts frames of lockstep play
}

input_taps: [dynamic]Input_Tap // pending, in script order
input_pad_wanted: bool
input_pad: ^sdl.Joystick        // the virtual gamepad, once attached
input_pad2_wanted: bool
input_pad2: ^sdl.Joystick       // the second, player 2's

input_parse_point :: proc(item, s: string) -> (x, y: f32) {
	slash := strings.index_byte(s, '/')
	if slash < 0 {x86.fatal("JE_INPUT_SCRIPT: %q needs x/y", item)}
	px, okx := strconv.parse_uint(s[:slash], 10)
	py, oky := strconv.parse_uint(s[slash + 1:], 10)
	if !okx || !oky {x86.fatal("JE_INPUT_SCRIPT: bad point in %q", item)}
	return f32(px), f32(py)
}

input_script_load :: proc(script: string) {
	s := script
	for item in strings.split_iterator(&s, ",") {
		if len(input_taps) + 3 > INPUT_SCRIPT_MAX {x86.fatal("JE_INPUT_SCRIPT: over %d events", INPUT_SCRIPT_MAX)}
		colon := strings.index_byte(item, ':')
		if colon < 0 {x86.fatal("JE_INPUT_SCRIPT: %q is not frame:Action", item)}
		play := strings.has_prefix(item, "+")
		frame, ok := strconv.parse_uint(item[play ? 1 : 0:colon], 10)
		if !ok {x86.fatal("JE_INPUT_SCRIPT: bad frame in %q", item)}
		f, act := u32(frame), item[colon + 1:]
		first := len(input_taps)
		defer for &t in input_taps[first:] {t.play = play}
		switch {
		case strings.has_prefix(act, "Move@"):
			x, y := input_parse_point(item, act[5:])
			append(&input_taps, Input_Tap{frame = f, kind = .Move, x = x, y = y})
		case strings.has_prefix(act, "Click@"):
			x, y := input_parse_point(item, act[6:])
			append(&input_taps, Input_Tap{frame = f, kind = .Move, x = x, y = y})
			append(&input_taps, Input_Tap{frame = f, kind = .Button, down = true, btn = 1})
			append(&input_taps, Input_Tap{frame = f + INPUT_TAP_FRAMES, kind = .Button, btn = 1})
		case:
			name, held := act, u32(INPUT_TAP_FRAMES)
			if t := strings.index_byte(act, '~'); t >= 0 {
				n, okn := strconv.parse_uint(act[t + 1:], 10)
				if !okn || n == 0 {x86.fatal("JE_INPUT_SCRIPT: bad hold in %q", item)}
				name, held = act[:t], u32(n)
			}
			if strings.has_prefix(name, "Pad.") {
				input_pad_parse(item, name[4:], f, held)
				continue
			}
			key := sdl.GetScancodeFromName(strings.clone_to_cstring(name, context.temp_allocator))
			if key == .UNKNOWN {x86.fatal("JE_INPUT_SCRIPT: unknown key %q", name)}
			append(&input_taps, Input_Tap{frame = f, kind = .Key, down = true, key = key})
			append(&input_taps, Input_Tap{frame = f + held, kind = .Key, key = key})
		}
	}
}

input_pad_parse :: proc(item, name: string, f, held: u32) {
	t := Input_Tap{frame = f, down = true, value = 32767}
	name := name
	if strings.has_prefix(name, "-") {name, t.value = name[1:], -32768}
	cn := strings.clone_to_cstring(name, context.temp_allocator)
	if b := sdl.GetGamepadButtonFromString(cn); b != .INVALID {
		t.kind, t.pad = .Pad_Button, c.int(b)
	} else if a := sdl.GetGamepadAxisFromString(cn); a != .INVALID {
		t.kind, t.pad = .Pad_Axis, c.int(a)
	} else {
		x86.fatal("JE_INPUT_SCRIPT: unknown gamepad control %q in %q", name, item)
	}
	append(&input_taps, t)
	t.frame, t.down = f + held, false
	append(&input_taps, t)
	input_pad_wanted = true
}

// Logs a change of motor speeds; the game re-sends the same speeds every frame.
input_pad_rumble :: proc "c" (_: rawptr, lo, hi: u16) -> bool {
	@(static) last: [2]u16
	if last == {lo, hi} {return true}
	last = {lo, hi}
	context = {}
	fmt.eprintf("pad: virtual rumble %d %d\n", lo, hi)
	return true
}

// Attaches the virtual gamepad when the script uses one, and the second one
// (player 2 of couch co-op) when the control channel is open; needs SDL
// initialized. Their buttons and axes are numbered as SDL's gamepad enums.
input_pad_attach :: proc() {
	if input_pad_wanted {input_pad = input_pad_new("JE_INPUT_SCRIPT gamepad")}
	if input_pad2_wanted {input_pad2 = input_pad_new("JE_INPUT_SCRIPT gamepad 2")}
}

input_pad_new :: proc(name: cstring) -> ^sdl.Joystick {
	desc := sdl.VirtualJoystickDesc {
		version     = size_of(sdl.VirtualJoystickDesc),
		type        = u16(sdl.JoystickType.GAMEPAD),
		naxes       = u16(sdl.GamepadAxis.RIGHT_TRIGGER) + 1,
		nbuttons    = u16(sdl.GamepadButton.DPAD_RIGHT) + 1,
		button_mask = 1 << (u32(sdl.GamepadButton.DPAD_RIGHT) + 1) - 1,
		axis_mask   = 1 << (u32(sdl.GamepadAxis.RIGHT_TRIGGER) + 1) - 1,
		name        = name,
		Rumble      = input_pad_rumble,
	}
	id := sdl.AttachVirtualJoystick(desc)
	if id == 0 {x86.fatal("JE_INPUT_SCRIPT: attach virtual gamepad: %s", sdl.GetError())}
	j := sdl.OpenJoystick(id)
	if j == nil {x86.fatal("JE_INPUT_SCRIPT: open virtual gamepad: %s", sdl.GetError())}
	return j
}

input_pad_set :: proc(t: Input_Tap) {
	ok: bool
	j := t.p2 ? input_pad2 : input_pad
	if j == nil {return} // player 2's, unplugged (ctl pad2 off)
	if t.kind == .Pad_Button {
		ok = sdl.SetJoystickVirtualButton(j, t.pad, t.down)
	} else {
		ok = sdl.SetJoystickVirtualAxis(j, t.pad, t.down ? t.value : (t.pad >= c.int(sdl.GamepadAxis.LEFT_TRIGGER) ? -32768 : 0))
	}
	if !ok {x86.fatal("JE_INPUT_SCRIPT: set virtual gamepad control %d: %s", t.pad, sdl.GetError())}
}

// Guest client pixel to host window coordinates (inverse of to_guest).
input_to_host :: proc(x, y: f32) -> (f32, f32) {
	sw, sh: c.int
	_ = sdl.GetWindowSize(window, &sw, &sh)
	rx, ry, rw, rh := view_rect(f32(sw), f32(sh))
	return rx + x * rw / f32(max(wnd_w, 1)), ry + y * rh / f32(max(wnd_h, 1))
}

input_event :: proc(t: Input_Tap) -> (ev: sdl.Event) {
	ts := sdl.GetTicksNS()
	switch t.kind {
	case .Key:
		ev.key = {
			type      = t.down ? .KEY_DOWN : .KEY_UP,
			timestamp = ts,
			scancode  = t.key,
			key       = sdl.GetKeyFromScancode(t.key, {}, false),
			down      = t.down,
		}
	case .Move:
		hx, hy := input_to_host(t.x, t.y)
		ev.motion = {type = .MOUSE_MOTION, timestamp = ts, x = hx, y = hy, xrel = hx - mouse_hx, yrel = hy - mouse_hy}
	case .Pad_Button, .Pad_Axis:
		x86.fatal("input_event: gamepad controls are set directly")
	case .Button:
		ev.button = {
			type      = t.down ? .MOUSE_BUTTON_DOWN : .MOUSE_BUTTON_UP,
			timestamp = ts,
			button    = t.btn,
			down      = t.down,
			clicks    = 1,
			x         = mouse_hx,
			y         = mouse_hy,
		}
	}
	return
}

// Pushes every event due at frame, in script order. A Move updates the
// tracked pointer at once so a button in the same frame lands on it.
input_script_step :: proc(frame: u32) {
	for _ in 0 ..< len(input_taps) {
		due := -1
		for t, i in input_taps {
			if t.play ? lockstep && i64(t.frame) <= vframe : t.frame <= frame {due = i; break}
		}
		if due < 0 {return}
		t := input_taps[due]
		ordered_remove(&input_taps, due)
		if t.kind == .Pad_Button || t.kind == .Pad_Axis {
			input_pad_set(t)
			continue
		}
		ev := input_event(t)
		if t.kind == .Move {mouse_hx, mouse_hy = ev.motion.x, ev.motion.y}
		if !sdl.PushEvent(&ev) {x86.fatal("JE_INPUT_SCRIPT: push event: %s", sdl.GetError())}
	}
}
