// Game controller: one SDL3 gamepad presented to the game as the DirectInput
// device of an Xbox 360 controller ("Controller (XBOX 360 For Windows)"),
// with rumble through XInputSetState.
// WHY: docs/hle.md §5
package win32

import "core:fmt"
import "core:math"
import sdl "vendor:sdl3"
import "../x86"

// The game's controller layout table (0x703668) matches this product name
// and then sets its 360-pad flag, which routes rumble through XInput.
PAD_NAME :: "Controller (XBOX 360 For Windows)"

GUID_PadInstance := [16]u8{0x4a, 0x45, 0x50, 0x41, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01}
GUID_PadProduct := [16]u8{0x5e, 0x04, 0x8e, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x50, 0x49, 0x44, 0x56, 0x49, 0x44}

DI8DEVCLASS_ALL :: 0
DI8DEVCLASS_GAMECTRL :: 4
DIEDFL_FORCEFEEDBACK :: 0x100
DIDFT_AXIS :: 3
DIDFT_ABSAXIS :: 2
DIPROP_RANGE :: 4
DIPH_BYOFFSET :: 1
DIPH_BYID :: 2
DIJOYSTATE_SIZE :: 0x50
DIDEVICEINSTANCE_SIZE :: 0x244
DIDEVICEOBJECTINSTANCE_SIZE :: 0x13c
DEVTYPE_360 :: 0x00010215 // DIDEVTYPE_HID | DI8DEVTYPEGAMEPAD_STANDARD << 8 | DI8DEVTYPE_GAMEPAD
PAD_TRIGGER_DOWN :: 8000   // SDL trigger value (0..32767) at which a trigger counts as a button
PAD_TRIGGER_UP :: 4000     // and below which a pressed one counts as released
PAD_STICK_DZ_DEFAULT :: 12 // radial stick deadzone, percent of full deflection
PAD_STICK_OUTER :: 0.95    // deflection that reads as full, for pads that never reach the rim
PAD_AXIAL_DZ :: 6535       // the game's own per-axis deadzone, patched out of CXbInput
PAD_RUMBLE_MS :: 0xffff    // XInput vibration lasts until changed; SDL caps a rumble at this

// The device's objects, as the 360 driver lays them out in DIJOYSTATE:
// axes lX, lY, lZ, lRx, lRy (lZ is the combined triggers: LT up, RT down),
// one POV, and buttons. Axes come first, so an axis's index is its
// pad_range slot. Buttons 10 and 11 are LT and RT past PAD_TRIGGER_DOWN,
// which the game's 360 layout reads; the real driver has no such buttons.
// Names are what the game shows for bindings.
JOY_AXES :: 5
Joy_Object :: struct {
	ofs:  u32,    // DIJOYSTATE offset
	type: u32,    // DIDFT_* | instance << 8
	guid: u8,     // first byte of GUID_{X,Y,Z,Rx,Ry}Axis / GUID_POV / GUID_Button
	name: string,
}
DIDFT_PSHBUTTON :: 0x4
DIDFT_BUTTON :: 0xc
DIDFT_POV :: 0x10
DIERR_OBJECTNOTFOUND :: 0x80070002
// GUID_XAxis {A36D02E0-C9F3-11CF-BFC7-444553540000}; the other object type
// GUIDs differ only in the first byte.
GUID_OBJ_TAIL := [15]u8{0x02, 0x6d, 0xa3, 0xf3, 0xc9, 0xcf, 0x11, 0xbf, 0xc7, 0x44, 0x45, 0x53, 0x54, 0x00, 0x00}
JOY_OBJECTS := [?]Joy_Object {
	{0x00, DIDFT_ABSAXIS | 0 << 8, 0xe0, "Left Stick X"},
	{0x04, DIDFT_ABSAXIS | 1 << 8, 0xe1, "Left Stick Y"},
	{0x08, DIDFT_ABSAXIS | 2 << 8, 0xe2, "Triggers"},
	{0x0c, DIDFT_ABSAXIS | 3 << 8, 0xf4, "Right Stick X"},
	{0x10, DIDFT_ABSAXIS | 4 << 8, 0xf5, "Right Stick Y"},
	{0x20, DIDFT_POV | 0 << 8, 0xf2, "D-Pad"},
	{0x30, DIDFT_PSHBUTTON | 0 << 8, 0xf0, "A"},
	{0x31, DIDFT_PSHBUTTON | 1 << 8, 0xf0, "B"},
	{0x32, DIDFT_PSHBUTTON | 2 << 8, 0xf0, "X"},
	{0x33, DIDFT_PSHBUTTON | 3 << 8, 0xf0, "Y"},
	{0x34, DIDFT_PSHBUTTON | 4 << 8, 0xf0, "LB"},
	{0x35, DIDFT_PSHBUTTON | 5 << 8, 0xf0, "RB"},
	{0x36, DIDFT_PSHBUTTON | 6 << 8, 0xf0, "Back"},
	{0x37, DIDFT_PSHBUTTON | 7 << 8, 0xf0, "Start"},
	{0x38, DIDFT_PSHBUTTON | 8 << 8, 0xf0, "Left Stick"},
	{0x39, DIDFT_PSHBUTTON | 9 << 8, 0xf0, "Right Stick"},
	{0x3a, DIDFT_PSHBUTTON | 10 << 8, 0xf0, "LT"},
	{0x3b, DIDFT_PSHBUTTON | 11 << 8, 0xf0, "RT"},
}

// The 360 buttons, by the names the game shows. pad_names gives a
// PlayStation or Nintendo pad its own names; any other keeps the 360's.
// WHY: docs/hle.md §5
Pad_Btn :: enum {A, B, X, Y, LB, RB, LT, RT, LS, RS, Back, Start}
PAD_NAMES_360 := [Pad_Btn]string {
	.A = "A", .B = "B", .X = "X", .Y = "Y", .LB = "LB", .RB = "RB", .LT = "LT", .RT = "RT",
	.LS = "Left Stick", .RS = "Right Stick", .Back = "Back", .Start = "Start",
}
PAD_FACE := [Pad_Btn]sdl.GamepadButton {
	.A = .SOUTH, .B = .EAST, .X = .WEST, .Y = .NORTH,
	.LB = .INVALID, .RB = .INVALID, .LT = .INVALID, .RT = .INVALID, .LS = .INVALID, .RS = .INVALID, .Back = .INVALID, .Start = .INVALID,
}
PAD_LABEL_NAMES := [sdl.GamepadButtonLabel]string {
	.UNKNOWN = "", .A = "A", .B = "B", .X = "X", .Y = "Y",
	.CROSS = "Cross", .CIRCLE = "Circle", .SQUARE = "Square", .TRIANGLE = "Triangle",
}
// JOY_OBJECTS[JOY_BUTTON0 + i] is the 360 button JOY_BUTTON_NAMES[i].
JOY_BUTTON0 :: 6
JOY_BUTTON_NAMES := [12]Pad_Btn{.A, .B, .X, .Y, .LB, .RB, .Back, .Start, .LS, .RS, .LT, .RT}

// Names of the open pad's buttons; own is false when they are the 360's.
// Under lockstep always the 360's: the names reach the game's strings, which
// must be the same on every peer.
pad_names :: proc() -> (names: [Pad_Btn]string, own: bool) {
	names = PAD_NAMES_360
	if pad == nil || lockstep {return}
	for s, b in PAD_FACE {
		if s == .INVALID {continue}
		if l := PAD_LABEL_NAMES[sdl.GetGamepadButtonLabel(pad, s)]; l != "" {names[b] = l}
	}
	#partial switch t := sdl.GetGamepadType(pad); t {
	case .PS3, .PS4, .PS5:
		names[.LB], names[.RB], names[.LT], names[.RT], names[.LS], names[.RS] = "L1", "R1", "L2", "R2", "L3", "R3"
		names[.Back] = t == .PS3 ? "Select" : t == .PS4 ? "Share" : "Create"
		names[.Start] = t == .PS3 ? "Start" : "Options"
	case .NINTENDO_SWITCH_PRO, .NINTENDO_SWITCH_JOYCON_LEFT, .NINTENDO_SWITCH_JOYCON_RIGHT, .NINTENDO_SWITCH_JOYCON_PAIR:
		names[.LB], names[.RB], names[.LT], names[.RT], names[.Back], names[.Start] = "L", "R", "ZL", "ZR", "-", "+"
	}
	for s, b in names {
		if s != PAD_NAMES_360[b] {own = true}
	}
	return
}

// rgbButtons index -> SDL button, in the 360 driver's order.
PAD_BUTTONS := [10]sdl.GamepadButton {
	.SOUTH, .EAST, .WEST, .NORTH, .LEFT_SHOULDER, .RIGHT_SHOULDER, .BACK, .START, .LEFT_STICK, .RIGHT_STICK,
}

pad: ^sdl.Gamepad
pad2: ^sdl.Gamepad // player 2 of couch co-op (native/coop.odin); the game never reads it
pad_rumble_warned: bool
pad_range := [JOY_AXES][2]i32{0 ..< JOY_AXES = {0, 65535}} // DIPROP_RANGE per axis; DirectInput default
pad_trigger_held: [2]bool // LT, RT as buttons, for the release threshold
stick_radial := true // setting STICK_DZ -1 restores the game's per-axis deadzone
stick_dz: f32 = PAD_STICK_DZ_DEFAULT / 100.0 // setting STICK_DZ, percent
// The left stick of the last pad_state, as SDL reads it and after pad_stick,
// for JE_STICK_LOG (native/stick_log.odin).
pad_left_raw, pad_left: [2]i32

// One pad as SDL reads it: what the game's input is made from, and what
// lockstep peers send each other (lockstep.odin).
Pad_Axis :: enum {LX, LY, RX, RY, LT, RT}
Pad_Input :: struct {
	axes:    [Pad_Axis]i16, // sticks down positive, triggers 0..32767
	buttons: u16, // bit i for PAD_BUTTONS[i], then PAD_DPAD's
	on:      bool, // a pad is connected
}
PAD_DPAD := [4]sdl.GamepadButton{.DPAD_UP, .DPAD_DOWN, .DPAD_LEFT, .DPAD_RIGHT}
PAD_AXES := [Pad_Axis]sdl.GamepadAxis {
	.LX = .LEFTX, .LY = .LEFTY, .RX = .RIGHTX, .RY = .RIGHTY, .LT = .LEFT_TRIGGER, .RT = .RIGHT_TRIGGER,
}

// Under lockstep, the frame's input for player 1's pad and player 2's.
pad_in: [2]Pad_Input

pad_sample :: proc(g: ^sdl.Gamepad) -> (in_: Pad_Input) {
	if g == nil {return}
	in_.on = true
	for a, k in PAD_AXES {in_.axes[k] = sdl.GetGamepadAxis(g, a)}
	for b, i in PAD_BUTTONS {
		if sdl.GetGamepadButton(g, b) {in_.buttons |= 1 << u32(i)}
	}
	for b, i in PAD_DPAD {
		if sdl.GetGamepadButton(g, b) {in_.buttons |= 1 << u32(len(PAD_BUTTONS) + i)}
	}
	return
}

// Player 1's input: the first pad, or the frame's record under lockstep.
// While the join address editor has the pad, and after until its buttons
// are let go, the game sees it released (join_edit.odin).
pad1_input :: proc() -> Pad_Input {
	if lockstep {return pad_in[0]}
	in_ := pad_sample(pad)
	if !join_edit_holds(in_) {return in_}
	return {on = in_.on}
}

// Player 2's input: the second pad, or the frame's record under lockstep.
pad2_input :: proc() -> Pad_Input {
	return lockstep ? pad_in[1] : pad_sample(pad2)
}

// Opens connected gamepads into the free slots, pad then pad2. Called at
// enumeration, before the event pump has reported any device. The scripted
// virtual pads, when attached, win over physical ones: otherwise a connected
// controller takes the single DirectInput slot and scripted stick input goes
// nowhere.
pad_open_first :: proc() {
	if input_pad != nil {
		pad_open(sdl.GetJoystickID(input_pad))
		if input_pad2 != nil {pad_open(sdl.GetJoystickID(input_pad2))}
		return
	}
	n: i32
	ids := sdl.GetGamepads(&n)
	defer sdl.free(ids)
	for i in 0 ..< n {pad_open(ids[i])}
}

// Opens gamepad id into the first free slot. A scripted virtual pad owns its
// slot: no other device takes it.
pad_open :: proc(id: sdl.JoystickID) {
	for p in ([2]^sdl.Gamepad{pad, pad2}) {
		if p != nil && sdl.GetGamepadID(p) == id {return}
	}
	slot, own := &pad, input_pad
	if pad != nil {slot, own = &pad2, input_pad2}
	if slot^ != nil || own != nil && sdl.GetJoystickID(own) != id {
		return
	}
	slot^ = sdl.OpenGamepad(id)
	if slot^ == nil {
		fmt.eprintf("pad: open %d failed: %s\n", id, sdl.GetError())
		return
	}
	if slot == &pad {pad_rumble_warned = false}
	fmt.eprintf("pad: connected %d \"%s\"%s\n", id, sdl.GetGamepadName(slot^), slot == &pad2 ? " as player 2" : "")
}

pad_removed :: proc(id: sdl.JoystickID) {
	for slot in ([2]^^sdl.Gamepad{&pad, &pad2}) {
		if slot^ == nil || sdl.GetGamepadID(slot^) != id {continue}
		fmt.eprintf("pad: disconnected %d%s\n", id, slot == &pad2 ? " (player 2)" : "")
		sdl.CloseGamepad(slot^)
		slot^ = nil
		if slot == &pad {pad_trigger_held = {}}
		pad_open_first()
		return
	}
}

// Lists the gamepad for the game-controller class, except to a
// force-feedback enumeration: the game then takes its XInput rumble path
// instead of creating DirectInput effects. The device is listed whether or
// not a pad is connected: the game enumerates once, at start, so a pad
// plugged in later must find the device already there. Until then it reads
// as centred and released.
pad_enum :: proc(class, cb, ref, flags: u32) {
	if class != DI8DEVCLASS_ALL && class != DI8DEVCLASS_GAMECTRL || flags & DIEDFL_FORCEFEEDBACK != 0 {
		return
	}
	pad_open_first()
	inst := heap_alloc(DIDEVICEINSTANCE_SIZE, true)
	defer heap_free(inst)
	x86.wr32(inst, DIDEVICEINSTANCE_SIZE)
	copy(x86.mem[inst + 4:inst + 0x14], GUID_PadInstance[:])
	copy(x86.mem[inst + 0x14:inst + 0x24], GUID_PadProduct[:])
	x86.wr32(inst + 0x24, DEVTYPE_360)
	put_str(inst + 0x28, 260, PAD_NAME)
	put_str(inst + 0x12c, 260, PAD_NAME)
	x86.wr16(inst + 0x240, 1) // HID usage page Generic Desktop, usage Game Pad
	x86.wr16(inst + 0x242, 5)
	guest_call(cb, inst, ref)
}

// Writes DIDEVICEOBJECTINSTANCEA {dwSize, guidType at 4, dwOfs at 0x14,
// dwType at 0x18, dwFlags at 0x1c, tszName[260] at 0x20} for object k.
pad_object_info :: proc(o: u32, k: int) {
	j := JOY_OBJECTS[k]
	x86.mem_zero(o, DIDEVICEOBJECTINSTANCE_SIZE)
	x86.wr32(o, DIDEVICEOBJECTINSTANCE_SIZE)
	x86.wr8(o + 4, j.guid)
	copy(x86.mem[o + 5:o + 0x14], GUID_OBJ_TAIL[:])
	x86.wr32(o + 0x14, j.ofs)
	x86.wr32(o + 0x18, j.type)
	name := j.name
	if k >= JOY_BUTTON0 {
		names, _ := pad_names()
		name = names[JOY_BUTTON_NAMES[k - JOY_BUTTON0]]
	}
	put_str(o + 0x20, 260, name)
}

// Object index for a DIPH_BYOFFSET or DIPH_BYID key, or -1.
pad_object_find :: proc(obj, how: u32) -> int {
	for j, k in JOY_OBJECTS {
		if how == DIPH_BYOFFSET && j.ofs == obj || how == DIPH_BYID && j.type & 0xffff1f == obj & 0xffff1f {
			return k
		}
	}
	return -1
}

// EnumObjects(this, cb, ref, flags): the objects whose type is in flags
// (DIDFT_ALL = 0 lists every object), until the callback returns 0.
Dev_EnumObjects :: proc() {
	cb, ref, flags := arg(1), arg(2), arg(3)
	o := heap_alloc(DIDEVICEOBJECTINSTANCE_SIZE, true)
	defer heap_free(o)
	for j, k in JOY_OBJECTS {
		if flags & 0xff != 0 && j.type & flags & 0xff == 0 {
			continue
		}
		pad_object_info(o, k)
		if guest_call(cb, o, ref) == 0 {
			break
		}
	}
	ret(4, DI_OK)
}

// GetObjectInfo(this, pdidoi, dwObj, dwHow). The game asks for every
// c_dfDIJoystick offset BYOFFSET and shows "-" for those not found.
Dev_GetObjectInfo :: proc() {
	o, obj, how := arg(1), arg(2), arg(3)
	k := pad_object_find(obj, how)
	if k < 0 {
		ret(4, DIERR_OBJECTNOTFOUND)
		return
	}
	pad_object_info(o, k)
	ret(4, DI_OK)
}

// DIPROPRANGE {header, lMin at +16, lMax at +20} for DIPH_DEVICE (every
// axis), or one axis BYOFFSET or BYID.
pad_set_range :: proc(hdr: u32) -> u32 {
	obj, how := x86.rd32(hdr + 8), x86.rd32(hdr + 12)
	lo, hi := i32(x86.rd32(hdr + 16)), i32(x86.rd32(hdr + 20))
	if lo >= hi {
		return DIERR_INVALIDPARAM
	}
	if how == 0 {
		for &r in pad_range {r = {lo, hi}}
		return DI_OK
	}
	k := pad_object_find(obj, how)
	if k < 0 || k >= JOY_AXES {
		return DIERR_OBJECTNOTFOUND
	}
	pad_range[k] = {lo, hi}
	return DI_OK
}

// Maps v in -32768..32767 onto the axis range.
pad_scale :: proc(axis: int, v: i32) -> u32 {
	r := pad_range[axis]
	return u32(r[0] + i32(i64(v + 32768) * i64(r[1] - r[0]) / 65535))
}

// DIJOYSTATE: lX..lRz at 0, sliders at 0x18, POV[4] at 0x20, buttons at
// 0x30. A disconnected pad reads as centred and released.
pad_state :: proc(p: u32) {
	x86.mem_zero(p, DIJOYSTATE_SIZE)
	for k in 0 ..< u32(4) {x86.wr32(p + 0x20 + k * 4, 0xffffffff)}
	in_ := pad1_input()
	if !in_.on {
		pad_trigger_held = {}
		for k in 0 ..< JOY_AXES {x86.wr32(p + u32(k) * 4, pad_scale(k, 0))}
		return
	}
	ax := in_.axes
	lt, rt := i32(ax[.LT]), i32(ax[.RT])
	pad_left_raw = {i32(ax[.LX]), i32(ax[.LY])}
	lx, ly := pad_stick(pad_left_raw.x, pad_left_raw.y)
	pad_left = {lx, ly}
	rx, ry := pad_stick(i32(ax[.RX]), i32(ax[.RY]))
	x86.wr32(p + 0x0, pad_scale(0, lx))
	x86.wr32(p + 0x4, pad_scale(1, ly))
	x86.wr32(p + 0x8, pad_scale(2, clamp(lt - rt, -32768, 32767)))
	x86.wr32(p + 0xc, pad_scale(3, rx))
	x86.wr32(p + 0x10, pad_scale(4, ry))
	x86.wr32(p + 0x20, pad_pov(in_))
	for _, i in PAD_BUTTONS {
		if in_.buttons & (1 << u32(i)) != 0 {x86.wr8(p + 0x30 + u32(i), 0x80)}
	}
	for v, i in ([2]i32{lt, rt}) {
		held := &pad_trigger_held[i]
		held^ = v >= (held^ ? PAD_TRIGGER_UP : PAD_TRIGGER_DOWN)
		if held^ {x86.wr8(p + 0x3a + u32(i), 0x80)}
	}
}

// Player 2's pad: the sticks after pad_stick (SDL's axes, down
// positive) and the buttons held, the triggers past PAD_TRIGGER_DOWN with the
// same release threshold as pad_state's. ok is false with no second pad.
pad2_read :: proc() -> (left, right: [2]i32, held: bit_set[Pad_Btn], ok: bool) {
	@(static) trigger_held: [2]bool
	in_ := pad2_input()
	if !in_.on {
		trigger_held = {}
		return
	}
	ax := in_.axes
	left.x, left.y = pad_stick(i32(ax[.LX]), i32(ax[.LY]))
	right.x, right.y = pad_stick(i32(ax[.RX]), i32(ax[.RY]))
	for _, i in PAD_BUTTONS {
		if in_.buttons & (1 << u32(i)) != 0 {held += {JOY_BUTTON_NAMES[i]}}
	}
	for v, i in ([2]i32{i32(ax[.LT]), i32(ax[.RT])}) {
		h := &trigger_held[i]
		h^ = v >= (h^ ? PAD_TRIGGER_UP : PAD_TRIGGER_DOWN)
		if h^ {held += {i == 0 ? .LT : .RT}}
	}
	return left, right, held, true
}

// One stick, x and y in -32768..32767. Radial: deflection under stick_dz
// reads as centred, and the rest, up to PAD_STICK_OUTER, is stretched over
// the full range along the stick's own angle, so small deflections neither
// jump nor snap to an axis. Otherwise each axis within PAD_AXIAL_DZ of
// centre reads 0, as the unpatched game does.
pad_stick :: proc(x, y: i32) -> (i32, i32) {
	if !stick_radial {
		return abs(x) <= PAD_AXIAL_DZ ? 0 : x, abs(y) <= PAD_AXIAL_DZ ? 0 : y
	}
	fx, fy := f32(x) / 32767, f32(y) / 32767
	m := math.sqrt(fx * fx + fy * fy)
	if m <= stick_dz {
		return 0, 0
	}
	k := min((m - stick_dz) / (PAD_STICK_OUTER - stick_dz), 1) * 32767 / m
	return i32(fx * k), i32(fy * k)
}

// D-pad as POV hundredths of a degree clockwise from up; centred 0xffffffff.
pad_pov :: proc(in_: Pad_Input) -> u32 {
	POV := [16]u32 {
		0xffffffff, 0, 18000, 0xffffffff, // bits: up 1, down 2, left 4, right 8
		27000, 31500, 22500, 27000,
		9000, 4500, 13500, 9000,
		0xffffffff, 0, 18000, 0xffffffff,
	}
	return POV[in_.buttons >> len(PAD_BUTTONS) & 0xf]
}

// XInputSetState(user, XINPUT_VIBRATION{wLeftMotorSpeed, wRightMotorSpeed}):
// left is the low-frequency motor. Only user 0 exists.
XInputSetState :: proc() {
	user, vib := arg(0), arg(1)
	if user != 0 || pad == nil && !lockstep {
		ret(2, 1167) // ERROR_DEVICE_NOT_CONNECTED
		return
	}
	lo, hi := x86.rd16(vib), x86.rd16(vib + 2)
	if pad == nil {ret(2, 0); return} // lockstep: the game sees the same pad on every peer
	if !sdl.RumbleGamepad(pad, lo, hi, PAD_RUMBLE_MS) && !pad_rumble_warned {
		// Not every pad has motors; XInput reports success regardless.
		fmt.eprintf("pad: rumble unsupported: %s\n", sdl.GetError())
		pad_rumble_warned = true
	}
	ret(2, 0)
}
