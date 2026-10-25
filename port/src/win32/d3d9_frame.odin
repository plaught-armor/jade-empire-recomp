// Device bindings (render targets, textures, streams, indices), Clear,
// StretchRect and Present. All rendering goes to one FBO whose attachments
// follow the bound surfaces; Present blits the back buffer to the window,
// flipping it (see d3d9_res.odin on orientation), through the load-screen
// fade (d3d9_fade.odin).
package win32

import "core:fmt"
import "core:os"
import "core:time"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"
import "../x86"

RT_MAX :: 4
STREAMS :: 16

Stream :: struct {
	vb, offset, stride, freq: u32,
}

// Bound objects. Binding takes no reference, as in D3D9's public counts;
// res_unbind clears a slot when its object dies.
Bindings :: struct {
	rt:       [RT_MAX]u32,
	depth:    u32,
	tex:      [SAMPLERS]u32,
	streams:  [STREAMS]Stream,
	indices:  u32,
	vs, ps:   u32, // shader id + 1, 0 = fixed function
	vs_obj, ps_obj: u32,
	decl, decl_obj: u32, // decl id + 1; decl_obj 0 when set through SetFVF
}

bind: Bindings
backbuf, autodepth: u32

// Debug: Present writes each back buffer to <dir>/frame_NNNNN.ppm (an
// absolute path: the game runs in its own directory). Empty = off.
frame_dump_dir: string
FRAME_DUMP_STEP :: 30 // dump every Nth frame; a frame is 2.7 MB at 720p
frame_count: u32
trace_frame: u32 = max(u32) // JE_TRACE_FRAME: HLE-trace only this presented frame
fbo: u32
fb_dirty: bool
blit_fbo: [2]u32

frame_init :: proc() {
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
	gl.CreateFramebuffers(1, &fbo)
	gl.CreateFramebuffers(2, &blit_fbo[0])
	draw_init()
	fade_init()
}

// (Re)creates the back buffer and auto depth surface at w x h and binds them.
frame_reset :: proc(p: Present_Params) {
	if backbuf != 0 {res_destroy(com_id(backbuf))}
	if autodepth != 0 {res_destroy(com_id(autodepth))}
	backbuf = surface_new(p.width, p.height, D3DFMT_A8R8G8B8, D3DUSAGE_RENDERTARGET, D3DPOOL_DEFAULT)
	autodepth = 0
	if p.auto_depth != 0 {
		autodepth = surface_new(p.width, p.height, p.depth_format, D3DUSAGE_DEPTHSTENCIL, D3DPOOL_DEFAULT)
	}
	if backbuf == 0 || (p.auto_depth != 0 && autodepth == 0) {
		x86.fatal("d3d9: cannot create back buffer %dx%d depth format %d", p.width, p.height, p.depth_format)
	}
	bind = {}
	bind.rt[0] = backbuf
	bind.depth = autodepth
	fb_dirty = true
	ms_reset(p.ms_type)
}

res_unbind :: proc(obj: u32) {
	ms_unbind(obj)
	for &v in bind.rt {if v == obj {v = 0; fb_dirty = true}}
	if bind.depth == obj {bind.depth = 0; fb_dirty = true}
	for &v in bind.tex {if v == obj {v = 0}}
	for &s in bind.streams {if s.vb == obj {s.vb = 0}}
	if bind.indices == obj {bind.indices = 0}
	if backbuf == obj {backbuf = 0}
	if autodepth == obj {autodepth = 0}
}

// One level (and cube face; layer < 0 for 2D) of a GL texture.
Gl_Img :: struct {
	tex:          u32,
	level, layer: i32,
}

img_attach :: proc(f, a: u32, im: Gl_Img) {
	if im.layer >= 0 {
		gl.NamedFramebufferTextureLayer(f, a, im.tex, im.level, im.layer)
	} else {
		gl.NamedFramebufferTexture(f, a, im.tex, im.level)
	}
}

res_img :: proc(obj: u32) -> Gl_Img {
	s := res_of(obj)
	o, face, level := surf_owner(s)
	return {s.gl, i32(level), o.kind == .Cube ? i32(face) : -1}
}

// Attaches surface obj (0 detaches) to framebuffer f at attachment point a.
attach :: proc(f, a, obj: u32) {
	if obj == 0 {
		gl.NamedFramebufferTexture(f, a, 0, 0)
		return
	}
	img_attach(f, a, res_img(obj))
}

depth_attachment_of :: proc(format: u32) -> u32 {
	return format == D3DFMT_D16 ? gl.DEPTH_ATTACHMENT : gl.DEPTH_STENCIL_ATTACHMENT
}

depth_attachment :: proc(obj: u32) -> u32 {
	return obj != 0 ? depth_attachment_of(res_of(obj).format) : gl.DEPTH_STENCIL_ATTACHMENT
}

is_depth_format :: proc(f: u32) -> bool {
	return f == D3DFMT_D16 || f == D3DFMT_D24S8 || f == D3DFMT_D24X8
}

// Copies rect sr of src to rect dr of dst (left, top, right, bottom in GL
// texels); format picks color or depth. Depth always filters nearest.
gl_blit :: proc(src, dst: Gl_Img, sr, dr: [4]i32, format: u32, linear: bool) {
	depth := is_depth_format(format)
	a := depth ? depth_attachment_of(format) : gl.COLOR_ATTACHMENT0
	img_attach(blit_fbo[0], a, src)
	img_attach(blit_fbo[1], a, dst)
	mask: u32 = depth ? gl.DEPTH_BUFFER_BIT | gl.STENCIL_BUFFER_BIT : gl.COLOR_BUFFER_BIT
	gl.Disable(gl.SCISSOR_TEST)
	dg.raster.scissor_on = false
	gl.BlitNamedFramebuffer(blit_fbo[0], blit_fbo[1], sr[0], sr[1], sr[2], sr[3], dr[0], dr[1], dr[2], dr[3], mask, linear && !depth ? gl.LINEAR : gl.NEAREST)
	gl.NamedFramebufferTexture(blit_fbo[0], a, 0, 0)
	gl.NamedFramebufferTexture(blit_fbo[1], a, 0, 0)
}

// Scale of the bound framebuffer: GL pixels per D3D pixel.
fb_scale :: proc() -> i32 {
	o := bind.rt[0] != 0 ? bind.rt[0] : bind.depth
	return o != 0 ? i32(res_scale(res_of(o))) : 1
}

fb_bind :: proc() {
	if fb_dirty {
		ms_bound = ms_pick()
		bufs: [RT_MAX]u32
		for i in 0 ..< u32(RT_MAX) {
			ms_attach(gl.COLOR_ATTACHMENT0 + i, bind.rt[i], ms_bound)
			bufs[i] = bind.rt[i] != 0 ? gl.COLOR_ATTACHMENT0 + i : gl.NONE
		}
		gl.NamedFramebufferTexture(fbo, gl.DEPTH_STENCIL_ATTACHMENT, 0, 0)
		ms_attach(depth_attachment(bind.depth), bind.depth, ms_bound)
		gl.NamedFramebufferDrawBuffers(fbo, RT_MAX, &bufs[0])
		st := gl.CheckNamedFramebufferStatus(fbo, gl.DRAW_FRAMEBUFFER)
		if st != gl.FRAMEBUFFER_COMPLETE {
			x86.fatal("d3d9: framebuffer incomplete %x (rt0 %08x depth %08x)", st, bind.rt[0], bind.depth)
		}
		fb_dirty = false
	}
	ms_mark()
	gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, fbo)
}

addref_out :: proc(out, obj: u32) -> u32 {
	x86.wr32(out, obj)
	if obj == 0 {
		return D3DERR_NOTFOUND
	}
	x86.wr32(obj + 4, x86.rd32(obj + 4) + 1)
	return D3D_OK
}

// (this, iSwapChain, iBackBuffer, Type, ppBackBuffer)
Dev_GetBackBuffer :: proc() {
	if arg(1) != 0 || arg(2) != 0 {
		ret(5, D3DERR_INVALIDCALL)
		return
	}
	ret(5, addref_out(arg(4), backbuf))
}

// Setting target 0 resets the viewport and scissor to the whole surface.
Dev_SetRenderTarget :: proc() {
	i, s := arg(1), arg(2)
	if i >= RT_MAX || (i == 0 && s == 0) {
		ret(3, D3DERR_INVALIDCALL)
		return
	}
	bind.rt[i] = s
	fb_dirty = true
	if i == 0 {
		r := res_of(s)
		ds.viewport = {0, 0, r.w, r.h, 0, 1}
		ds.scissor = {0, 0, i32(r.w), i32(r.h)}
	}
	ret(3, D3D_OK)
}

Dev_GetRenderTarget :: proc() {
	i := arg(1)
	if i >= RT_MAX {
		ret(3, D3DERR_INVALIDCALL)
		return
	}
	ret(3, addref_out(arg(2), bind.rt[i]))
}

Dev_SetDepthStencilSurface :: proc() {
	bind.depth = arg(1)
	fb_dirty = true
	ret(2, D3D_OK)
}

Dev_GetDepthStencilSurface :: proc() {ret(2, addref_out(arg(1), bind.depth))}

D3DCLEAR_TARGET :: 1
D3DCLEAR_ZBUFFER :: 2
D3DCLEAR_STENCIL :: 4

argb_vec :: proc(c: u32) -> [4]f32 {
	return {f32((c >> 16) & 0xff) / 255, f32((c >> 8) & 0xff) / 255, f32(c & 0xff) / 255, f32(c >> 24) / 255}
}

// Clears one rect (left, top, right, bottom) clipped to the viewport.
clear_rect :: proc(r: [4]i32, flags: u32, color: [4]f32, z: f32, stencil: i32) {
	v := ds.viewport
	x0, y0 := max(r[0], i32(v.x)), max(r[1], i32(v.y))
	x1, y1 := min(r[2], i32(v.x + v.w)), min(r[3], i32(v.y + v.h))
	if ds.rs[174] != 0 { // SCISSORTESTENABLE
		x0, y0 = max(x0, ds.scissor[0]), max(y0, ds.scissor[1])
		x1, y1 = min(x1, ds.scissor[2]), min(y1, ds.scissor[3])
	}
	if x1 <= x0 || y1 <= y0 {
		return
	}
	k := fb_scale()
	gl.Scissor(x0 * k, y0 * k, (x1 - x0) * k, (y1 - y0) * k)
	if flags & D3DCLEAR_TARGET != 0 {
		c := color
		for i in 0 ..< i32(RT_MAX) {
			if bind.rt[i] != 0 {gl.ClearBufferfv(gl.COLOR, i, &c[0])}
		}
	}
	zs := flags & (D3DCLEAR_ZBUFFER | D3DCLEAR_STENCIL)
	switch {
	case zs == D3DCLEAR_ZBUFFER | D3DCLEAR_STENCIL: gl.ClearBufferfi(gl.DEPTH_STENCIL, 0, z, stencil)
	case zs == D3DCLEAR_ZBUFFER: zz := z; gl.ClearBufferfv(gl.DEPTH, 0, &zz)
	case zs == D3DCLEAR_STENCIL: ss := stencil; gl.ClearBufferiv(gl.STENCIL, 0, &ss)
	}
}

// (this, Count, pRects, Flags, Color, Z, Stencil). Write masks are forced on;
// the draw path sets them again from render state.
// Width of the bars beside a GUI narrower than the back buffer (native
// widegui.odin): a full clear of the back buffer leaves them black, so a menu
// that covers no 3D view is framed in black rather than the scene's clear
// color.
gui_bar_w: i32

Dev_Clear :: proc() {
	n, rects, flags := arg(1), arg(2), arg(3)
	color, z, stencil := argb_vec(arg(4)), transmute(f32)arg(5), i32(arg(6))
	if bind.depth == 0 {
		flags &~= D3DCLEAR_ZBUFFER | D3DCLEAR_STENCIL
	}
	if null_render {
		ret(7, D3D_OK)
		return
	}
	if rects == 0 || n == 0 {ms_clear_arm(flags)}
	if flags & D3DCLEAR_ZBUFFER != 0 {soft_touch()}
	fb_bind()
	raster_lost()
	gl.Enable(gl.SCISSOR_TEST)
	gl.ColorMask(true, true, true, true)
	gl.DepthMask(true)
	gl.StencilMask(0xffffffff)
	if rects == 0 || n == 0 {
		clear_rect({0, 0, max(i32), max(i32)}, flags, color, z, stencil)
		if gui_bar_w > 0 && flags & D3DCLEAR_TARGET != 0 && bind.rt[0] == backbuf {
			w := i32(res_of(backbuf).w)
			clear_rect({0, 0, gui_bar_w, max(i32)}, D3DCLEAR_TARGET, {0, 0, 0, 1}, z, stencil)
			clear_rect({w - gui_bar_w, 0, max(i32), max(i32)}, D3DCLEAR_TARGET, {0, 0, 0, 1}, z, stencil)
		}
	} else {
		for i in 0 ..< n {
			r: [4]i32
			blob_in(rects + i * 16, &r, 16)
			clear_rect(r, flags, color, z, stencil)
		}
	}
	ret(7, D3D_OK)
}

// (this, pSourceSurface, pSourceRect, pDestSurface, pDestRect, Filter)
Dev_StretchRect :: proc() {
	src, dst := res_of(arg(1)), res_of(arg(3))
	sr := [4]i32{0, 0, i32(src.w), i32(src.h)}
	dr := [4]i32{0, 0, i32(dst.w), i32(dst.h)}
	if arg(2) != 0 {blob_in(arg(2), &sr, 16)}
	if arg(4) != 0 {blob_in(arg(4), &dr, 16)}
	if null_render {
		ret(6, D3D_OK)
		return
	}
	sr *= i32(res_scale(src))
	dr *= i32(res_scale(dst))
	if arg(1) == backbuf {smaa_frame(true)}
	ms_read(arg(1))
	ms_write(arg(3))
	gl_blit(res_img(arg(1)), res_img(arg(3)), sr, dr, src.format, arg(5) >= 2)
	ret(6, D3D_OK)
}

// (this, pSourceRect, pDestRect, hDestWindowOverride, pDirtyRegion)
// Writes the back buffer as a binary PPM; row 0 is the image top.
frame_dump :: proc(b: ^Res, path: string) {
	w, h := b.w * res_scale(b), b.h * res_scale(b)
	n := int(w * h)
	px := make([]u8, n * 4, context.temp_allocator)
	gl.GetTextureImage(b.gl, 0, gl.RGBA, gl.UNSIGNED_BYTE, i32(len(px)), raw_data(px))
	head := fmt.tprintf("P6\n%d %d\n255\n", w, h)
	out := make([]u8, len(head) + n * 3, context.temp_allocator)
	copy(out, head)
	for i in 0 ..< n {
		copy(out[len(head) + i * 3:][:3], px[i * 4:][:3])
	}
	if err := os.write_entire_file(path, out); err != nil {
		x86.fatal("frame dump %s: %v", path, err)
	}
}

// Play-log status: a line every PLAY_STATUS_MS with the frame and the
// presented frame rate; F12 (host_key) logs a mark and, with JE_MARK_DIR,
// writes that frame as mark_NN_frame_NNNNN.ppm.
// WHY: docs/recompiler.md §6
PLAY_STATUS_MS :: 10_000
play_mark_dir: string
play_mark_pending: bool
play_mark_n: u32
play_status_ms: u64
play_status_frame: u32

play_log :: proc(b: ^Res) {
	if play_mark_pending {
		play_mark_pending = false
		play_mark_n += 1
		fmt.eprintf("mark %d at frame %d\n", play_mark_n, frame_count)
		if play_mark_dir != "" {
			frame_dump(b, fmt.tprintf("%s/mark_%02d_frame_%05d.ppm", play_mark_dir, play_mark_n, frame_count))
		}
	}
	now := sdl.GetTicks()
	if play_status_ms == 0 {play_status_ms = now}
	if now - play_status_ms >= PLAY_STATUS_MS {
		fps := f64(frame_count - play_status_frame) * 1000 / f64(now - play_status_ms)
		fmt.eprintf("status: frame %d, %.1f fps, frame counts at %d fps\n", frame_count, fps, x86.frame_rate)
		play_status_ms, play_status_frame = now, frame_count
	}
}

// Setting FPS: frame-rate cap Present holds to, in frames per second; 0 = no
// cap beyond vsync. Set only with the game's own 30 fps cap lifted.
// WHY: docs/rendering.md §5
fps_cap: u32
fps_next: time.Tick

// Setting MENU_FPS: the lower cap Present holds to while a menu is up
// (MENU_PANELS); 0 = menus run at fps_cap. WHY: docs/rendering.md §5
MENU_FPS_DEFAULT :: 60
MENU_PANELS :: [?]u32{0x02, 0x2c} // MAINGAME (main menu, load list), LTI_INGAMETABS
menu_fps_cap: u32

menu_up :: proc() -> bool {
	for id in MENU_PANELS {
		if gui_panel(id) != 0 {return true}
	}
	return false
}

// Smoothing of the frame period behind x86.frame_rate, and the longest
// period it takes in: a load or a hitch is skipped, so a count taken during
// one (an object created while an area loads) is still the steady-rate count.
// Frames while a Bink movie is open or a menu is up are skipped too: the
// movie or the menu cap paces them.
// WHY: docs/rendering.md §5
FRAME_RATE_EMA :: 0.1
FRAME_PERIOD_MAX :: 0.1
frame_period: f64 = 1.0 / x86.FRAME_RATE_GAME
frame_last: time.Tick

// Updates x86.frame_rate from the time since the previous Present.
frame_rate_track :: proc(menu: bool) {
	now := time.tick_now()
	if frame_last != {} {
		dt := time.duration_seconds(time.tick_diff(frame_last, now))
		if dt <= FRAME_PERIOD_MAX && len(binks) == 0 && !menu {
			frame_period += (dt - frame_period) * FRAME_RATE_EMA
			x86.frame_rate = max(1, u32(1 / frame_period + 0.5))
		}
	}
	frame_last = now
}

// Sleeps until the next frame slot of fps_cap, or of menu_fps_cap while a
// menu is up when that is lower. A slot more than one period in the past
// restarts the schedule, so a hitch is not caught up with a burst. None while
// lock_fast.
fps_wait :: proc(menu: bool) {
	if lock_fast {return}
	limit := fps_cap
	if menu && menu_fps_cap != 0 && (limit == 0 || menu_fps_cap < limit) {limit = menu_fps_cap}
	if limit == 0 {return}
	period := time.Second / time.Duration(limit)
	fps_next = time.tick_add(fps_next, period)
	ahead := time.tick_diff(time.tick_now(), fps_next)
	if ahead > 0 {
		time.accurate_sleep(ahead)
	} else if -ahead > period {
		fps_next = time.tick_now()
	}
}

Dev_Present :: proc() {
	b := res_of(backbuf)
	smaa_frame(false)
	smaa.done = false
	soft_touch()
	ms_read(backbuf)
	if frame_dump_dir != "" && frame_count % FRAME_DUMP_STEP == 0 {
		frame_dump(b, fmt.tprintf("%s/frame_%05d.ppm", frame_dump_dir, frame_count))
	}
	play_log(b)
	if lockstep {lock_frame()} else if lock_pending {lock_start()}
	if net_lobby && !lockstep {net_lobby_poll()}
	ds_pump()
	frame_count += 1
	x86.frame_now = frame_count
	ctl_step(b, frame_count)
	input_script_step(frame_count)
	if trace_frame != max(u32) {x86.hle_trace = frame_count == trace_frame}
	ww, wh: i32
	_ = sdl.GetWindowSizeInPixels(window, &ww, &wh)
	k := i32(res_scale(b))
	fade_present(b.gl, i32(b.w) * k, i32(b.h) * k, ww, wh)
	_ = sdl.GL_SwapWindow(window)
	menu := menu_up()
	fps_wait(lockstep ? false : menu)
	if !lockstep {frame_rate_track(menu)}
	ret(5, D3D_OK)
}

Dev_SetTexture :: proc() {
	s, ok := sampler_slot(arg(1))
	if !ok {
		ret(3, D3DERR_INVALIDCALL)
		return
	}
	bind.tex[s] = arg(2)
	ret(3, D3D_OK)
}

Dev_GetTexture :: proc() {
	s, ok := sampler_slot(arg(1))
	if !ok {
		ret(3, D3DERR_INVALIDCALL)
		return
	}
	_ = addref_out(arg(2), bind.tex[s])
	ret(3, D3D_OK)
}

// (this, StreamNumber, pStreamData, OffsetInBytes, Stride)
Dev_SetStreamSource :: proc() {
	n := arg(1)
	if n >= STREAMS {
		ret(5, D3DERR_INVALIDCALL)
		return
	}
	s := &bind.streams[n]
	s.vb, s.offset, s.stride = arg(2), arg(3), arg(4)
	ret(5, D3D_OK)
}

Dev_GetStreamSource :: proc() {
	n := arg(1)
	if n >= STREAMS {
		ret(5, D3DERR_INVALIDCALL)
		return
	}
	s := bind.streams[n]
	_ = addref_out(arg(2), s.vb)
	x86.wr32(arg(3), s.offset)
	x86.wr32(arg(4), s.stride)
	ret(5, D3D_OK)
}

Dev_SetStreamSourceFreq :: proc() {
	n := arg(1)
	if n >= STREAMS {
		ret(3, D3DERR_INVALIDCALL)
		return
	}
	bind.streams[n].freq = arg(2)
	ret(3, D3D_OK)
}

Dev_GetStreamSourceFreq :: proc() {
	n := arg(1)
	if n >= STREAMS {
		ret(3, D3DERR_INVALIDCALL)
		return
	}
	x86.wr32(arg(2), max(bind.streams[n].freq, 1))
	ret(3, D3D_OK)
}

Dev_SetIndices :: proc() {
	bind.indices = arg(1)
	ret(2, D3D_OK)
}

Dev_GetIndices :: proc() {
	_ = addref_out(arg(1), bind.indices)
	ret(2, D3D_OK)
}
