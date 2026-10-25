// user32 HLE over SDL3: one top-level window, a posted-message queue fed from
// SDL events, and guest window procedures called for dispatch.
package win32

import "core:c"
import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"
import "../x86"

USER32 := [?]Hle_Entry {
	{"user32.dll!RegisterClassA", RegisterClassA},
	{"user32.dll!CreateWindowExA", CreateWindowExA},
	{"user32.dll!DefWindowProcA", DefWindowProcA},
	{"user32.dll!ShowWindow", ShowWindow},
	{"user32.dll!MoveWindow", MoveWindow},
	{"user32.dll!SetWindowPos", SetWindowPos},
	{"user32.dll!GetWindowRect", GetWindowRect},
	{"user32.dll!GetWindowInfo", GetWindowInfo},
	{"user32.dll!SetWindowLongA", SetWindowLongA},
	{"user32.dll!AdjustWindowRect", ret1_3},
	{"user32.dll!GetSystemMetrics", GetSystemMetrics},
	{"user32.dll!SystemParametersInfoA", ret1_4},
	{"user32.dll!ChangeDisplaySettingsA", ret0_2},
	{"user32.dll!EnumDisplaySettingsA", EnumDisplaySettingsA},
	{"user32.dll!FindWindowA", ret0_2},
	{"user32.dll!MessageBoxA", MessageBoxA},
	{"user32.dll!LoadIconA", LoadIconA},
	{"user32.dll!LoadCursorA", LoadIconA},
	{"user32.dll!GetCursor", GetCursor},
	{"user32.dll!SetCursor", SetCursor},
	{"user32.dll!ShowCursor", ShowCursor},
	{"user32.dll!GetCursorPos", GetCursorPos},
	{"user32.dll!SetCursorPos", SetCursorPos},
	{"user32.dll!ClipCursor", ret1_1},
	{"user32.dll!SetCapture", SetCapture},
	{"user32.dll!ReleaseCapture", ret1_0},
	{"user32.dll!GetAsyncKeyState", GetAsyncKeyState},
	{"user32.dll!IntersectRect", IntersectRect},
	{"user32.dll!GetDC", GetDC},
	{"user32.dll!ReleaseDC", ret1_2},
	{"user32.dll!BeginPaint", BeginPaint},
	{"user32.dll!EndPaint", ret1_2},
	{"user32.dll!PostQuitMessage", PostQuitMessage},
	{"user32.dll!PeekMessageA", PeekMessageA},
	{"user32.dll!GetMessageA", GetMessageA},
	{"user32.dll!TranslateMessage", ret0_1},
	{"user32.dll!DispatchMessageA", DispatchMessageA},
}

ret1_0 :: proc() {ret(0, 1)}
ret1_4 :: proc() {ret(4, 1)}

WM_DESTROY :: 0x0002
WM_SIZE :: 0x0005
WM_ACTIVATE :: 0x0006
WM_SETFOCUS :: 0x0007
WM_KILLFOCUS :: 0x0008
WM_PAINT :: 0x000f
WM_CLOSE :: 0x0010
WM_QUIT :: 0x0012
WM_ACTIVATEAPP :: 0x001c
WM_CREATE :: 0x0001
WM_NCCREATE :: 0x0081
WM_KEYDOWN :: 0x0100
WM_KEYUP :: 0x0101
WM_CHAR :: 0x0102
WM_SYSKEYDOWN :: 0x0104
WM_SYSKEYUP :: 0x0105
WM_MOUSEMOVE :: 0x0200
WM_LBUTTONDOWN :: 0x0201
WM_MOUSEWHEEL :: 0x020a

HWND_MAIN :: 0x00010010
HDC_MAIN :: 0x00020020
CURSOR_ARROW :: 0x00030030

Msg :: struct {
	hwnd, msg, wparam, lparam: u32,
}

Wnd_Class :: struct {
	name: string,
	proc_: u32,
}

classes: [dynamic]Wnd_Class
window: ^sdl.Window
wnd_proc: u32
wnd_style, wnd_exstyle: u32
wnd_x, wnd_y, wnd_w, wnd_h: i32 // guest client rectangle
wnd_scale: i32 = 1             // host window = guest client size x wnd_scale
start_fullscreen: bool       // setting FULLSCREEN: borderless fullscreen from the start; Alt+Enter toggles
queue: [dynamic]Msg
quit_posted: bool
quit_code: u32
cursor_shown: i32 = 0
cursor_cur: u32 = CURSOR_ARROW
// What the window title says after the game's name, such as the online
// game's address (title_set); title_shown, what it last said.
title_extra, title_shown: string

user32_init :: proc() {
	if !sdl.Init({.VIDEO, .EVENTS, .GAMEPAD}) {
		x86.fatal("SDL_Init: %s", sdl.GetError())
	}
	input_pad_attach()
}

RegisterClassA :: proc() {
	wc := arg(0)
	name := x86.cstr(x86.rd32(wc + 36))
	append(&classes, Wnd_Class{strings.clone(name), x86.rd32(wc + 4)})
	ret(1, 0xc000 + u32(len(classes)))
}

// The guest's single window: CreateWindowExA makes the SDL window, sized to
// the requested outer rectangle (no decorations are modelled).
CreateWindowExA :: proc() {
	exstyle, cls, title, style := arg(0), arg(1), arg(2), arg(3)
	x, y, w, h, param := i32(arg(4)), i32(arg(5)), i32(arg(6)), i32(arg(7)), arg(11)
	if window != nil {
		x86.fatal("CreateWindowExA: second window")
	}
	name := cls < 0x10000 ? "" : x86.cstr(cls)
	for k in classes {
		if (cls < 0x10000 && cls == 0xc000 + u32(len(classes))) || strings.equal_fold(k.name, name) {
			wnd_proc = k.proc_
		}
	}
	if wnd_proc == 0 {
		x86.fatal("CreateWindowExA: unknown class %s", name)
	}
	if u32(w) == 0x80000000 {w = 640}
	if u32(h) == 0x80000000 {h = 480}
	wnd_style, wnd_exstyle = style, exstyle
	wnd_x, wnd_y, wnd_w, wnd_h = 0, 0, max(w, 64), max(h, 64)
	_ = x; _ = y
	t := strings.clone_to_cstring(title != 0 ? x86.cstr(title) : "Jade Empire", context.temp_allocator)
	// Fullscreen waits for fullscreen_start: created fullscreen and hidden,
	// then sized and shown, Windows kept the window at its windowed size
	// while SDL went on reporting the display's, so Present drew a crop.
	flags: sdl.WindowFlags = {.OPENGL, .HIDDEN, .RESIZABLE}
	window = sdl.CreateWindow(t, c.int(wnd_w), c.int(wnd_h), flags)
	if window == nil {
		x86.fatal("SDL_CreateWindow: %s", sdl.GetError())
	}
	_ = sdl.StartTextInput(window)
	// CREATESTRUCTA for WM_NCCREATE/WM_CREATE, built in a scratch heap block.
	cs := heap_alloc(48, true)
	x86.wr32(cs, param)
	x86.wr32(cs + 16, u32(h)); x86.wr32(cs + 20, u32(w))
	x86.wr32(cs + 32, style); x86.wr32(cs + 36, title); x86.wr32(cs + 40, cls); x86.wr32(cs + 44, exstyle)
	guest_call(wnd_proc, HWND_MAIN, WM_NCCREATE, 0, cs)
	r := guest_call(wnd_proc, HWND_MAIN, WM_CREATE, 0, cs)
	heap_free(cs)
	if r == 0xffffffff {
		sdl.DestroyWindow(window)
		window = nil
		ret(12, 0)
		return
	}
	ret(12, HWND_MAIN)
}

DefWindowProcA :: proc() {
	h, m := arg(0), arg(1)
	r: u32 = 0
	switch m {
	case WM_CLOSE:
		guest_call(wnd_proc, h, WM_DESTROY, 0, 0)
	case WM_NCCREATE:
		r = 1
	}
	ret(4, r)
}

ShowWindow :: proc() {
	if window != nil {
		if arg(1) == 0 {sdl.HideWindow(window)} else {sdl.ShowWindow(window)}
		fullscreen_start()
	}
	ret(2, 1)
}

resize :: proc(w, h: i32) {
	if w > 0 && h > 0 {
		wnd_w, wnd_h = w, h
		// Fullscreen keeps the window at the display's size; the windowed
		// size it returns to was set before fullscreen_start.
		if !fullscreen() {sdl.SetWindowSize(window, c.int(w * wnd_scale), c.int(h * wnd_scale))}
	}
}

// Setting FULLSCREEN, once the device has given the window its windowed
// size and the window is shown.
fullscreen_start :: proc() {
	if !start_fullscreen || gl_ctx == nil || sdl.GetWindowFlags(window) & {.HIDDEN} != {} {return}
	start_fullscreen = false
	fullscreen_set(true)
	_ = sdl.SyncWindow(window) // false only when it timed out
}

// The letterboxed image: the largest centred rectangle of the guest
// client's aspect inside a w x h host area, in the same units.
view_rect :: proc(w, h: f32) -> (x, y, vw, vh: f32) {
	ga := f32(wnd_w) / f32(max(wnd_h, 1))
	vw, vh = w, h
	if w > h * ga {vw = h * ga} else {vh = w / ga}
	return (w - vw) / 2, (h - vh) / 2, max(vw, 1), max(vh, 1)
}

// Host window point to guest client coordinates; the host window may have
// any size (wnd_scale, the user resizing it, or fullscreen).
to_guest :: proc(x, y: f32) -> (f32, f32) {
	sw, sh: c.int
	_ = sdl.GetWindowSize(window, &sw, &sh)
	rx, ry, rw, rh := view_rect(f32(sw), f32(sh))
	return (x - rx) * f32(wnd_w) / rw, (y - ry) * f32(wnd_h) / rh
}

// Host window motion to guest client pixels.
to_guest_delta :: proc(dx, dy: f32) -> (f32, f32) {
	sw, sh: c.int
	_ = sdl.GetWindowSize(window, &sw, &sh)
	_, _, rw, rh := view_rect(f32(sw), f32(sh))
	return dx * f32(wnd_w) / rw, dy * f32(wnd_h) / rh
}

MoveWindow :: proc() {
	resize(i32(arg(3)), i32(arg(4)))
	ret(6, 1)
}

SWP_NOSIZE :: 0x1

SetWindowPos :: proc() {
	if arg(6) & SWP_NOSIZE == 0 {
		resize(i32(arg(4)), i32(arg(5)))
	}
	ret(7, 1)
}

put_rect :: proc(p: u32, l, t, r, b: i32) {
	x86.wr32(p, u32(l)); x86.wr32(p + 4, u32(t)); x86.wr32(p + 8, u32(r)); x86.wr32(p + 12, u32(b))
}

GetWindowRect :: proc() {
	put_rect(arg(1), wnd_x, wnd_y, wnd_x + wnd_w, wnd_y + wnd_h)
	ret(2, 1)
}

// Added to the client rect's x by GetWindowInfo: the GUI's left edge while the
// game reads the cursor (native widegui.odin).
client_dx: i32

GetWindowInfo :: proc() {
	p := arg(1)
	x86.mem_zero(p + 4, 56)
	put_rect(p + 4, wnd_x, wnd_y, wnd_x + wnd_w, wnd_y + wnd_h)
	put_rect(p + 20, wnd_x + client_dx, wnd_y, wnd_x + client_dx + wnd_w, wnd_y + wnd_h)
	x86.wr32(p + 36, wnd_style)
	x86.wr32(p + 40, wnd_exstyle)
	x86.wr32(p + 44, 1) // WS_ACTIVECAPTION
	ret(2, 1)
}

GWL_EXSTYLE :: 0xffffffec
GWL_STYLE :: 0xfffffff0
GWL_WNDPROC :: 0xfffffffc

SetWindowLongA :: proc() {
	idx, v := arg(1), arg(2)
	old: u32
	switch idx {
	case GWL_STYLE: old = wnd_style; wnd_style = v
	case GWL_EXSTYLE: old = wnd_exstyle; wnd_exstyle = v
	case GWL_WNDPROC: old = wnd_proc; wnd_proc = v
	case: x86.fatal("SetWindowLongA index %d", i32(idx))
	}
	ret(3, old)
}

desktop_size :: proc() -> (i32, i32) {
	m := sdl.GetDesktopDisplayMode(sdl.GetPrimaryDisplay())
	if m == nil {
		return 1920, 1080
	}
	return i32(m.w), i32(m.h)
}

GetSystemMetrics :: proc() {
	w, h := desktop_size()
	switch arg(0) {
	case 0: ret(1, u32(w)) // SM_CXSCREEN
	case 1: ret(1, u32(h)) // SM_CYSCREEN
	case: ret(1, 0)
	}
}

// Fullscreen modes offered to the game: common 4:3 and 16:9 sizes up to the
// desktop, all 32-bit at 60 Hz.
MODES := [?][2]u32{{640, 480}, {800, 600}, {1024, 768}, {1280, 720}, {1280, 1024}, {1600, 900}, {1920, 1080}, {2560, 1440}, {3840, 2160}}

EnumDisplaySettingsA :: proc() {
	n, dm := arg(1), arg(2)
	w, h := desktop_size()
	mw, mh: u32
	if n == 0xffffffff || n == 0xfffffffe {
		mw, mh = u32(w), u32(h)
	} else {
		k: u32 = 0
		found := false
		for m in MODES {
			if m[0] <= u32(w) && m[1] <= u32(h) {
				if k == n {mw, mh = m[0], m[1]; found = true; break}
				k += 1
			}
		}
		if !found {
			ret(3, 0)
			return
		}
	}
	x86.wr16(dm + 36, 156)
	x86.wr32(dm + 40, 0x5c0000) // DM_BITSPERPEL | DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY
	x86.wr32(dm + 104, 32)
	x86.wr32(dm + 108, mw)
	x86.wr32(dm + 112, mh)
	x86.wr32(dm + 120, 60)
	ret(3, 1)
}

MessageBoxA :: proc() {
	cap := arg(2) != 0 ? x86.cstr(arg(2)) : ""
	fmt.eprintf("win32: MessageBox [%s] %s\n", cap, arg(1) != 0 ? x86.cstr(arg(1)) : "")
	ret(4, 1) // IDOK
}

LoadIconA :: proc() {ret(2, CURSOR_ARROW)}
GetCursor :: proc() {ret(0, cursor_cur)}

SetCursor :: proc() {
	old := cursor_cur
	cursor_cur = arg(0)
	ret(1, old)
}

// Display counter as in Win32: the cursor shows while it is >= 0.
ShowCursor :: proc() {
	cursor_shown += arg(0) != 0 ? 1 : -1
	if cursor_shown >= 0 {_ = sdl.ShowCursor()} else {_ = sdl.HideCursor()}
	ret(1, u32(cursor_shown))
}

// Last host pointer position seen in the event stream. Read instead of
// SDL_GetMouseState so scripted (pushed) events move the cursor too.
mouse_hx, mouse_hy: f32
mouse_rem: [2]f32 // sub-pixel remainder of guest-scaled relative motion
// Host point of the last SetCursorPos warp while its motion echo is due.
// Windows moves the cursor without a DirectInput delta; SDL reports the warp
// as motion, which would cancel the game's mouse-look recentering.
warp_due: bool
warp_at: [2]f32

GetCursorPos :: proc() {
	if lockstep {
		at := kbm_cursor_get()
		x86.wr32(arg(0), u32(i32(at.x) + wnd_x))
		x86.wr32(arg(0) + 4, u32(i32(at.y) + wnd_y))
		ret(1, 1)
		return
	}
	x, y := to_guest(mouse_hx, mouse_hy)
	x86.wr32(arg(0), u32(i32(x) + wnd_x))
	x86.wr32(arg(0) + 4, u32(i32(y) + wnd_y))
	ret(1, 1)
}

// Under lockstep the guest's cursor moves on every peer, the pointer only
// where it is player 1's.
SetCursorPos :: proc() {
	if lockstep {kbm_cursor_set(i32(arg(0)) - wnd_x, i32(arg(1)) - wnd_y)}
	if window != nil && (!lockstep || kbm_drives_p1()) {
		// Same guest-to-host mapping as to_guest inverts (letterboxed view),
		// so a later GetCursorPos returns the point set here.
		mouse_hx, mouse_hy = input_to_host(f32(i32(arg(0)) - wnd_x), f32(i32(arg(1)) - wnd_y))
		warp_due, warp_at = true, {mouse_hx, mouse_hy}
		sdl.WarpMouseInWindow(window, mouse_hx, mouse_hy)
	}
	ret(2, 1)
}

SetCapture :: proc() {ret(1, 0)}

GetAsyncKeyState :: proc() {
	ret(1, vk_down(arg(0)) ? 0x8000 : 0)
}

IntersectRect :: proc() {
	d, a, b := arg(0), arg(1), arg(2)
	l := max(i32(x86.rd32(a)), i32(x86.rd32(b)))
	t := max(i32(x86.rd32(a + 4)), i32(x86.rd32(b + 4)))
	r := min(i32(x86.rd32(a + 8)), i32(x86.rd32(b + 8)))
	bt := min(i32(x86.rd32(a + 12)), i32(x86.rd32(b + 12)))
	if l >= r || t >= bt {
		put_rect(d, 0, 0, 0, 0)
		ret(3, 0)
		return
	}
	put_rect(d, l, t, r, bt)
	ret(3, 1)
}

GetDC :: proc() {ret(1, HDC_MAIN)}

BeginPaint :: proc() {
	p := arg(1)
	x86.mem_zero(p, 64)
	x86.wr32(p, HDC_MAIN)
	put_rect(p + 8, 0, 0, wnd_w, wnd_h)
	ret(2, HDC_MAIN)
}

PostQuitMessage :: proc() {
	quit_posted = true
	quit_code = arg(0)
	ret(1, 0)
}

// ---------------------------------------------------------------- messages

post :: proc(msg, wparam, lparam: u32) {
	append(&queue, Msg{HWND_MAIN, msg, wparam, lparam})
}

// Client coordinates of a host point; a point on a letterbox bar is
// clamped to the nearest client edge.
mouse_lparam :: proc(hx, hy: f32) -> u32 {
	x, y := to_guest(hx, hy)
	x, y = clamp(x, 0, f32(wnd_w - 1)), clamp(y, 0, f32(wnd_h - 1))
	return u32(u16(i16(x))) | u32(u16(i16(y))) << 16
}

mouse_buttons: u32 // MK_* state for wparam

// A motion event's DirectInput delta in guest pixels, so a game-drawn
// cursor tracks the host pointer; the pointer's host point kept.
mouse_motion :: proc(m: sdl.MouseMotionEvent) -> (dx, dy: i32) {
	echo := warp_due && abs(m.x - warp_at.x) < 1 && abs(m.y - warp_at.y) < 1
	warp_due &&= !echo
	gx, gy := to_guest_delta(m.xrel, m.yrel)
	mouse_rem += echo ? {} : [2]f32{gx, gy}
	dx, dy = i32(mouse_rem.x), i32(mouse_rem.y)
	mouse_rem -= {f32(dx), f32(dy)}
	mouse_hx, mouse_hy = m.x, m.y
	return
}

// SDL 1 left, 2 middle, 3 right, 4.. extra; DirectInput 0 left, 1 right, 2 middle.
di_button_of :: proc(b: u8) -> u32 {
	return b == 2 ? 2 : (b == 3 ? 1 : u32(b) - 1)
}

// Translates pending SDL events into posted messages. Under lockstep only
// closing the window and the host's own keys come through; the keyboard and
// mouse go to the frame's input record (kbm.odin), which every peer replays
// alike, and focus is dropped: one peer's would steer its game away from
// the others'.
pump :: proc() {
	upnp_poll()
	if window != nil && title_extra != title_shown {
		t := title_extra != "" ? fmt.ctprintf("Jade Empire - %s", title_extra) : "Jade Empire"
		if !sdl.SetWindowTitle(window, t) {fmt.eprintfln("win32: window title: %s", sdl.GetError())}
		title_shown = title_extra
	}
	ev: sdl.Event
	for sdl.PollEvent(&ev) {
		if lockstep {
			#partial switch ev.type {
			case .QUIT, .WINDOW_CLOSE_REQUESTED:
				post(WM_CLOSE, 0, 0)
			case .KEY_DOWN, .KEY_UP:
				if !host_key(ev.key) {kbm_key(ev.key)}
			case .TEXT_INPUT:
				for r in string(ev.text.text) {kbm_char(r)}
			case .MOUSE_MOTION:
				kbm_move(mouse_motion(ev.motion))
			case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
				mouse_hx, mouse_hy = ev.button.x, ev.button.y
				kbm_button(di_button_of(ev.button.button), ev.button.down)
			case .MOUSE_WHEEL:
				kbm_wheel(i32(ev.wheel.y * 120))
			case .GAMEPAD_ADDED:
				pad_open(ev.gdevice.which)
			case .GAMEPAD_REMOVED:
				pad_removed(ev.gdevice.which)
			}
			continue
		}
		#partial switch ev.type {
		case .QUIT, .WINDOW_CLOSE_REQUESTED:
			post(WM_CLOSE, 0, 0)
		case .WINDOW_FOCUS_GAINED:
			post(WM_ACTIVATEAPP, 1, 0); post(WM_ACTIVATE, 1, 0); post(WM_SETFOCUS, 0, 0)
		case .WINDOW_FOCUS_LOST:
			post(WM_ACTIVATE, 0, 0); post(WM_ACTIVATEAPP, 0, 0); post(WM_KILLFOCUS, 0, 0)
		case .KEY_DOWN, .KEY_UP:
			key_event(ev.key)
		case .TEXT_INPUT:
			if join_edit.state == .Open {
				join_edit_text(string(ev.text.text))
				continue
			}
			for r in string(ev.text.text) {
				if r < 0x100 {post(WM_CHAR, u32(r), 1)}
			}
		case .MOUSE_MOTION:
			di_motion(mouse_motion(ev.motion))
			post(WM_MOUSEMOVE, mouse_buttons, mouse_lparam(ev.motion.x, ev.motion.y))
		case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
			b := ev.button
			mouse_hx, mouse_hy = b.x, b.y
			di_button(di_button_of(b.button), b.down)
			// WM_[LRM]BUTTON(DOWN|UP): down codes 0x201/0x204/0x207, up = down + 1.
			base: u32
			mk: u32
			switch b.button {
			case 1: base, mk = 0x201, 0x1
			case 3: base, mk = 0x204, 0x2
			case 2: base, mk = 0x207, 0x10
			case: continue
			}
			if b.down {mouse_buttons |= mk} else {mouse_buttons &~= mk}
			post(b.down ? base : base + 1, mouse_buttons, mouse_lparam(b.x, b.y))
		case .GAMEPAD_ADDED:
			pad_open(ev.gdevice.which)
		case .GAMEPAD_REMOVED:
			pad_removed(ev.gdevice.which)
		case .MOUSE_WHEEL:
			d := i32(ev.wheel.y * 120)
			di_wheel(d)
			post(WM_MOUSEWHEEL, mouse_buttons | u32(u16(i16(d))) << 16, 0)
		}
	}
}

// Sets what the window title says after the game's name; the next pump
// shows it. s is kept.
title_set :: proc(s: string) {
	title_extra = strings.clone(s)
}

fullscreen :: proc() -> bool {
	return window != nil && sdl.GetWindowFlags(window) & {.FULLSCREEN} != {}
}

// Borderless fullscreen on or off; before the window exists, how it starts.
fullscreen_set :: proc(on: bool) {
	if window == nil {
		start_fullscreen = on
		return
	}
	if !sdl.SetWindowFullscreen(window, on) {
		fmt.eprintf("win32: fullscreen toggle: %s\n", sdl.GetError())
	}
}

// Host keys, not passed to the game: Alt+Enter toggles borderless
// fullscreen, F12 writes a play-log mark.
host_key :: proc(k: sdl.KeyboardEvent) -> bool {
	alt := k.mod & {.LALT, .RALT} != {}
	switch {
	case k.scancode == .RETURN && alt:
		if k.down && !k.repeat {fullscreen_set(!fullscreen())}
	case k.scancode == .F12:
		if k.down && !k.repeat {play_mark_pending = true}
	case:
		return false
	}
	return true
}

key_event :: proc(k: sdl.KeyboardEvent) {
	if host_key(k) {
		return
	}
	if join_edit.state == .Open {
		join_edit_key(k)
		return
	}
	vk := scancode_vk(k.scancode)
	if vk == 0 {
		return
	}
	if !k.repeat {
		di_key(scancode_dik(k.scancode), k.down)
	}
	alt := k.mod & {.LALT, .RALT} != {}
	sc := u32(scancode_dik(k.scancode))
	lp := 1 | (sc & 0xff) << 16
	if alt {lp |= 1 << 29}
	if !k.down {lp |= 3 << 30}
	m: u32 = k.down ? WM_KEYDOWN : WM_KEYUP
	if alt || vk == 0x12 {m += 4} // WM_SYS*
	post(m, vk, lp)
}

put_msg :: proc(p: u32, m: Msg) {
	x86.wr32(p, m.hwnd)
	x86.wr32(p + 4, m.msg)
	x86.wr32(p + 8, m.wparam)
	x86.wr32(p + 12, m.lparam)
	x86.wr32(p + 16, host_ms())
	x86.wr32(p + 20, 0)
	x86.wr32(p + 24, 0)
}

// Next message for PeekMessage/GetMessage; WM_QUIT once queued messages drain.
next_msg :: proc(remove: bool) -> (Msg, bool) {
	pump()
	if len(queue) > 0 {
		m := queue[0]
		if remove {ordered_remove(&queue, 0)}
		return m, true
	}
	if quit_posted {
		if remove {quit_posted = false}
		return Msg{0, WM_QUIT, quit_code, 0}, true
	}
	return {}, false
}

PM_REMOVE :: 1

PeekMessageA :: proc() {
	m, ok := next_msg(arg(4) & PM_REMOVE != 0)
	if !ok {
		ret(5, 0)
		return
	}
	put_msg(arg(0), m)
	ret(5, 1)
}

GetMessageA :: proc() {
	for {
		m, ok := next_msg(true)
		if ok {
			put_msg(arg(0), m)
			ret(4, m.msg == WM_QUIT ? 0 : 1)
			return
		}
		_ = sdl.WaitEventTimeout(nil, 10)
	}
}

DispatchMessageA :: proc() {
	p := arg(0)
	if x86.rd32(p) == 0 {
		ret(1, 0)
		return
	}
	ret(1, guest_call(wnd_proc, x86.rd32(p), x86.rd32(p + 4), x86.rd32(p + 8), x86.rd32(p + 12)))
}
