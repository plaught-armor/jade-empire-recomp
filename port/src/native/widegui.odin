// The GUI at a resolution wider than 4:3, a deliberate change rather than a
// bit-exact replacement. The game lays its GUI out on a 640x480 virtual
// screen and scales x by GUI_SX = width / 640 and y by GUI_SY = height / 480
// (0x597c60), so at 16:9 every panel, font and border is stretched sideways.
// Every GUI draw goes through a clip-rect stack (GUI_CLIP, top index
// GUI_CLIP_TOP): a pushed rect is its parent's origin plus its own virtual
// rect times the scales (0x5da590), and a panel is drawn into its rect's
// viewport. The stack's root is the full viewport, set each GUI frame by
// 0x5da240. With wide_gui_on the port sets GUI_SX to GUI_SY there and makes
// the root a centered 4:3 rect, so the GUI keeps its shape and sits in the
// middle of the screen; the 3D view keeps the full width. The mouse is read
// relative to the window's client rect (0x51cea0, through GetWindowInfo), so
// that rect is moved by the same offset while the read runs. A movie drawn to
// the full screen (0x67f0e0) is drawn at its own aspect, centered.
// WHY: docs/rendering.md §13
package native

import "../win32"
import "../x86"

guest_gui_root: x86.Func
guest_gui_mouse: x86.Func
guest_movie_draw: x86.Func

wide_gui_on := true

GUI_W :: 0x0075b3b0 // i32 back buffer width
GUI_H :: 0x0075b3b4 // i32 back buffer height
GUI_SX :: 0x0075b3b8 // f32 width / 640
GUI_SY :: 0x0075b3bc // f32 height / 480
GUI_INV_640 :: 0x006ec7f0 // f32 1 / 640, the game's GUI_SX factor
GUI_CLIP :: 0x0079df68 // the clip-rect stack, 10 bytes each: i16 x, y, w, h, flags
GUI_VIRTUAL_W :: 640
MOVIE_OPEN :: 0x44 // u32 of the movie player, nonzero with a movie open
MOVIE_BINK :: 0x48 // the movie's Bink struct: u32 width, height at +0, +4

// The root rect's left edge this GUI frame, 0 when the GUI fills the width.
@(private = "file")
gui_ox: i32

// cdecl(): sets the clip stack's root to the viewport and GUI_SX.
Gui_Root_005da240 :: proc() {
	guest_gui_root()
	w := i32(ld(GUI_W))
	h := i32(ld(GUI_H))
	sy := lf(GUI_SY)
	gui_ox = 0
	win32.gui_bar_w = 0
	if !wide_gui_on || w * 3 <= h * 4 {
		st(GUI_SX, transmute(u32)(f32(f64(w) * f64(lf(GUI_INV_640)))))
		return
	}
	st(GUI_SX, transmute(u32)sy)
	gw := i32(f32(GUI_VIRTUAL_W) * sy + 0.5)
	gui_ox = (w - gw) / 2
	win32.gui_bar_w = gui_ox
	x86.wr16(GUI_CLIP, u16(i16(x86.rd16(GUI_CLIP)) + i16(gui_ox)))
	x86.wr16(GUI_CLIP + 4, u16(gw))
}

// thiscall(events): reads the cursor into the GUI's virtual coordinates.
Gui_Mouse_0051cea0 :: proc() {
	win32.client_dx = gui_ox
	guest_gui_mouse()
	win32.client_dx = 0
}

// thiscall(flags, x, y, w, h), ret 0x14: draws the open movie's frame to the
// rect; w or h <= 0 is the back buffer's.
Movie_Draw_0067f0e0 :: proc() {
	c := &x86.cpu
	this, a := c.ecx, c.esp
	if wide_gui_on && ld(this + MOVIE_OPEN) != 0 {
		sw, sh := i32(ld(GUI_W)), i32(ld(GUI_H))
		x, y, w, h := i32(ld(a + 0x8)), i32(ld(a + 0xc)), i32(ld(a + 0x10)), i32(ld(a + 0x14))
		if w <= 0 {w = sw}
		if h <= 0 {h = sh}
		bink := ld(this + MOVIE_BINK)
		bw, bh := i32(ld(bink)), i32(ld(bink + 4))
		if x <= 0 && y <= 0 && w == sw && h == sh && bw > 0 && bh > 0 && sw * bh > sh * bw {
			mw := (sh * bw * 2 + bh) / (bh * 2)
			st(a + 0x8, u32((sw - mw) / 2))
			st(a + 0x10, u32(mw))
		}
		c.ecx = this
	}
	guest_movie_draw()
}
