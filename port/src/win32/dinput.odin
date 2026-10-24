// DirectInput 8: system keyboard and mouse devices fed from the SDL event
// pump, and one game controller (pad.odin).
package win32

import sdl "vendor:sdl3"
import "../x86"

DINPUT := [?]Hle_Entry {
	{"dinput8.dll!DirectInput8Create", DirectInput8Create},
}

DI_METHODS := [?]Com_Method {
	{"QueryInterface", com_query}, {"AddRef", com_addref}, {"Release", com_release},
	{"CreateDevice", DI_CreateDevice}, {"EnumDevices", DI_EnumDevices},
	{"GetDeviceStatus", nil}, {"RunControlPanel", nil}, {"Initialize", nil},
	{"FindDevice", nil}, {"EnumDevicesBySemantics", nil}, {"ConfigureDevices", nil},
}

DEV_METHODS := [?]Com_Method {
	{"QueryInterface", com_query}, {"AddRef", com_addref}, {"Release", com_release},
	{"GetCapabilities", nil}, {"EnumObjects", Dev_EnumObjects}, {"GetProperty", Dev_GetProperty},
	{"SetProperty", Dev_SetProperty}, {"Acquire", Dev_Acquire}, {"Unacquire", Dev_Unacquire},
	{"GetDeviceState", Dev_GetDeviceState}, {"GetDeviceData", Dev_GetDeviceData},
	{"SetDataFormat", Dev_SetDataFormat}, {"SetEventNotification", nil},
	{"SetCooperativeLevel", Dev_SetCooperativeLevel}, {"GetObjectInfo", Dev_GetObjectInfo},
	{"GetDeviceInfo", nil}, {"RunControlPanel", nil}, {"Initialize", nil},
	{"CreateEffect", nil}, {"EnumEffects", nil}, {"GetEffectInfo", nil},
	{"GetForceFeedbackState", nil}, {"SendForceFeedbackCommand", nil},
	{"EnumCreatedEffectObjects", nil}, {"Escape", nil}, {"Poll", Dev_Poll},
	{"SendDeviceData", nil}, {"EnumEffectsInFile", nil}, {"WriteEffectToFile", nil},
	{"BuildActionMap", nil}, {"SetActionMap", nil}, {"GetImageInfo", nil},
}

GUID_SysMouse := [16]u8{0x60, 0x2b, 0x1d, 0x6f, 0xa0, 0xd5, 0xcf, 0x11, 0xbf, 0xc7, 0x44, 0x45, 0x53, 0x54, 0x00, 0x00}
GUID_SysKeyboard := [16]u8{0x61, 0x2b, 0x1d, 0x6f, 0xa0, 0xd5, 0xcf, 0x11, 0xbf, 0xc7, 0x44, 0x45, 0x53, 0x54, 0x00, 0x00}

DI_OK :: 0
DI_NOEFFECT :: 1
DI_BUFFEROVERFLOW :: 1
DIERR_NOTACQUIRED :: 0x8007000c
DIERR_INVALIDPARAM :: 0x80070057
DIERR_DEVICENOTREG :: 0x80040154
DIPROP_BUFFERSIZE :: 1
DIPROP_GRANULARITY :: 3
DIERR_UNSUPPORTED :: 0x80004001
DIMOFS_Z :: 8
DIGDD_PEEK :: 1

Di_Kind :: enum u32 {Keyboard, Mouse, Joystick}

Di_Event :: struct {
	ofs, data, time, seq: u32,
}

DI_EVENTS_MAX :: 1024

Di_Device :: struct {
	acquired:  bool,
	buf_size:  u32, // DIPROP_BUFFERSIZE; 0 = unbuffered
	data_size: u32, // DIDATAFORMAT.dwDataSize of the selected format
	events:    [dynamic]Di_Event,
	overflow:  bool,
	dx, dy, dz: i32, // mouse motion since the last GetDeviceState
}

di_devs: [Di_Kind]Di_Device
di_keys: [256]u8    // DIK-indexed, 0x80 = down
di_buttons: [8]u8   // mouse buttons, 0x80 = down
di_seq: u32

DirectInput8Create :: proc() {
	out := arg(3)
	vt := com_vtable("dinput8.dll", "IDirectInput8A", DI_METHODS[:])
	x86.wr32(out, com_new(vt, 0))
	ret(5, DI_OK)
}

DI_CreateDevice :: proc() {
	g, out := arg(1), arg(2)
	kind: Di_Kind
	switch {
	case guid_eq(g, GUID_SysKeyboard): kind = .Keyboard
	case guid_eq(g, GUID_SysMouse): kind = .Mouse
	case guid_eq(g, GUID_PadInstance) || guid_eq(g, GUID_PadProduct): kind = .Joystick
	case:
		x86.wr32(out, 0)
		ret(4, DIERR_DEVICENOTREG)
		return
	}
	vt := com_vtable("dinput8.dll", "IDirectInputDevice8A", DEV_METHODS[:])
	x86.wr32(out, com_new(vt, u32(kind)))
	ret(4, DI_OK)
}

// EnumDevices(this, class, cb, ref, flags). Keyboard and mouse are opened by
// GUID and not listed; the controller is listed by pad_enum.
DI_EnumDevices :: proc() {
	pad_enum(arg(1), arg(2), arg(3), arg(4))
	ret(5, DI_OK)
}

dev :: proc() -> ^Di_Device {
	return &di_devs[Di_Kind(com_id(arg(0)))]
}

Dev_SetProperty :: proc() {
	prop, hdr := arg(1), arg(2)
	switch prop {
	case DIPROP_BUFFERSIZE:
		dev().buf_size = min(x86.rd32(hdr + 16), DI_EVENTS_MAX)
	case DIPROP_RANGE:
		if Di_Kind(com_id(arg(0))) != .Joystick {
			ret(3, DIERR_UNSUPPORTED)
			return
		}
		ret(3, pad_set_range(hdr))
		return
	}
	ret(3, DI_OK)
}

// DIPROPDWORD: header {dwSize, dwHeaderSize, dwObj, dwHow}, dwData at +16.
// The wheel moves in WHEEL_DELTA (120) steps; other axes in units of 1.
Dev_GetProperty :: proc() {
	prop, hdr := arg(1), arg(2)
	switch prop {
	case DIPROP_BUFFERSIZE:
		x86.wr32(hdr + 16, dev().buf_size)
	case DIPROP_GRANULARITY:
		x86.wr32(hdr + 16, x86.rd32(hdr + 8) == DIMOFS_Z ? 120 : 1)
	case:
		ret(3, DIERR_UNSUPPORTED)
		return
	}
	ret(3, DI_OK)
}

Dev_SetDataFormat :: proc() {
	dev().data_size = x86.rd32(arg(1) + 12)
	ret(2, DI_OK)
}

Dev_SetCooperativeLevel :: proc() {ret(3, DI_OK)}

Dev_Acquire :: proc() {
	d := dev()
	was := d.acquired
	d.acquired = true
	ret(1, was ? DI_NOEFFECT : DI_OK)
}

Dev_Unacquire :: proc() {
	d := dev()
	was := d.acquired
	d.acquired = false
	clear(&d.events)
	ret(1, was ? DI_OK : DI_NOEFFECT)
}

Dev_Poll :: proc() {
	pump()
	ret(1, dev().acquired ? DI_NOEFFECT : DIERR_NOTACQUIRED)
}

// Immediate state: the 256-byte key array, DIMOUSESTATE(2) with motion
// accumulated since the previous call, or DIJOYSTATE.
Dev_GetDeviceState :: proc() {
	n, p := arg(1), arg(2)
	d := dev()
	if !d.acquired {
		ret(3, DIERR_NOTACQUIRED)
		return
	}
	pump()
	x86.mem_zero(p, n)
	switch Di_Kind(com_id(arg(0))) {
	case .Keyboard:
		copy(x86.mem[p:p + min(n, 256)], di_keys[:min(n, 256)])
	case .Mouse:
		if n < 16 {
			ret(3, DIERR_INVALIDPARAM)
			return
		}
		x86.wr32(p, u32(d.dx)); x86.wr32(p + 4, u32(d.dy)); x86.wr32(p + 8, u32(d.dz))
		d.dx, d.dy, d.dz = 0, 0, 0
		nb := min(n - 12, 8)
		copy(x86.mem[p + 12:p + 12 + nb], di_buttons[:nb])
	case .Joystick:
		if n != DIJOYSTATE_SIZE || d.data_size != DIJOYSTATE_SIZE {
			x86.fatal("joystick GetDeviceState(%d) with data format size %d; only c_dfDIJoystick is implemented", n, d.data_size)
		}
		pad_state(p)
	}
	ret(3, DI_OK)
}

// Buffered DIDEVICEOBJECTDATA records {ofs, data, time, seq, appdata} at
// stride cbObjectData; rgdod == 0 with a count discards events.
Dev_GetDeviceData :: proc() {
	stride, out, inout, flags := arg(1), arg(2), arg(3), arg(4)
	d := dev()
	if !d.acquired {
		ret(5, DIERR_NOTACQUIRED)
		return
	}
	pump()
	n := min(x86.rd32(inout), u32(len(d.events)))
	if out != 0 {
		for k in 0 ..< n {
			e := d.events[k]
			r := out + k * stride
			x86.mem_zero(r, stride)
			x86.wr32(r, e.ofs); x86.wr32(r + 4, e.data); x86.wr32(r + 8, e.time); x86.wr32(r + 12, e.seq)
		}
	}
	if flags & DIGDD_PEEK == 0 {
		remove_range(&d.events, 0, int(n))
	}
	x86.wr32(inout, n)
	over := d.overflow
	d.overflow = false
	ret(5, over ? DI_BUFFEROVERFLOW : DI_OK)
}

di_push :: proc(d: ^Di_Device, ofs, data: u32) {
	if !d.acquired || d.buf_size == 0 {
		return
	}
	if u32(len(d.events)) >= d.buf_size {
		d.overflow = true
		return
	}
	di_seq += 1
	append(&d.events, Di_Event{ofs, data, host_ms(), di_seq})
}

// Event sinks called by the user32 pump.
di_key :: proc(dik: u8, down: bool) {
	if dik == 0 {
		return
	}
	di_keys[dik] = down ? 0x80 : 0
	di_push(&di_devs[.Keyboard], u32(dik), down ? 0x80 : 0)
}

di_motion :: proc(dx, dy: i32) {
	m := &di_devs[.Mouse]
	m.dx += dx
	m.dy += dy
	if dx != 0 {di_push(m, 0, u32(dx))}
	if dy != 0 {di_push(m, 4, u32(dy))}
}

di_wheel :: proc(dz: i32) {
	m := &di_devs[.Mouse]
	m.dz += dz
	di_push(m, 8, u32(dz))
}

// b: 0 left, 1 right, 2 middle, 3.. extra (DIMOFS_BUTTON0 = 12).
di_button :: proc(b: u32, down: bool) {
	if b >= len(di_buttons) {
		return
	}
	di_buttons[b] = down ? 0x80 : 0
	di_push(&di_devs[.Mouse], 12 + b, down ? 0x80 : 0)
}
