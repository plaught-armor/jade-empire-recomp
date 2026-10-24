// Host MSAA, at the sample count the game's present params ask for (its
// Anti-aliasing row): the back buffer and the auto depth surface each get a
// multisampled twin the game never sees; draws and clears go to the twins
// while every bound attachment has a live one, and anything else that touches
// the surfaces (a blit, a lock, Present) resolves first.
// WHY: docs/rendering.md §8
package win32

import "core:fmt"
import gl "vendor:OpenGL"

Ms_Surf :: struct {
	obj:   u32, // backbuf or autodepth; 0 = no twin
	tex:   u32, // TEXTURE_2D_MULTISAMPLE at the surface's GL size
	live:  bool, // the twin holds the surface's content
	dirty: bool, // the twin holds content the single-sample texture lacks
}

msaa: [2]Ms_Surf // color, depth
ms_bound: bool // fbo has the twins attached
ms_samples: i32 // sample count of the twins; 0 = none

// Gives the back buffer and auto depth surface twins of samples samples
// (D3DMULTISAMPLE_TYPE; under 2 = none); after frame_reset.
ms_reset :: proc(samples: u32) {
	ms_samples = 0
	if samples < 2 {return}
	mc, md: i32
	gl.GetIntegerv(gl.MAX_COLOR_TEXTURE_SAMPLES, &mc)
	gl.GetIntegerv(gl.MAX_DEPTH_TEXTURE_SAMPLES, &md)
	n := min(i32(min(samples, 16)), mc, md)
	if n < 2 {return}
	ms_samples = n
	objs := [2]u32{backbuf, autodepth}
	for obj, i in objs {
		if obj == 0 {continue}
		r := res_of(obj)
		k := res_scale(r)
		m := &msaa[i]
		m^ = {obj = obj}
		gl.CreateTextures(gl.TEXTURE_2D_MULTISAMPLE, 1, &m.tex)
		gl.TextureStorage2DMultisample(m.tex, n, fmt_must(r.format).internal, i32(r.w * k), i32(r.h * k), true)
	}
	fmt.eprintf("d3d9: msaa %dx\n", n)
}

// Drops the twin of obj when the surface dies.
ms_unbind :: proc(obj: u32) {
	for &m in msaa {
		if m.obj != obj || obj == 0 {continue}
		gl.DeleteTextures(1, &m.tex)
		m = {}
	}
}

ms_of :: proc(obj: u32) -> ^Ms_Surf {
	for &m in msaa {
		if m.obj == obj && obj != 0 {return &m}
	}
	return nil
}

ms_resolve :: proc(m: ^Ms_Surf) {
	if !m.live || !m.dirty {return}
	r := res_of(m.obj)
	k := i32(res_scale(r))
	full := [4]i32{0, 0, i32(r.w) * k, i32(r.h) * k}
	gl_blit({m.tex, 0, -1}, res_img(m.obj), full, full, r.format, false)
	m.dirty = false
}

// Before obj's single-sample texture is read.
ms_read :: proc(obj: u32) {
	if m := ms_of(obj); m != nil {ms_resolve(m)}
}

// Before obj's single-sample texture is written outside the fbo: the surface
// stays single-sample until a full clear (ms_clear_arm).
ms_write :: proc(obj: u32) {
	m := ms_of(obj)
	if m == nil || !m.live {return}
	ms_resolve(m)
	m.live = false
	fb_dirty = true
}

ms_is_bound :: proc(m: ^Ms_Surf) -> bool {
	if m.obj == bind.depth {return true}
	for v in bind.rt {
		if v == m.obj {return true}
	}
	return false
}

// A clear of flags over the whole surface makes a bound twin live again: what
// it held before no longer matters. Before fb_bind.
ms_clear_arm :: proc(flags: u32) {
	for &m in msaa {
		if m.obj == 0 || m.live || !ms_is_bound(&m) {continue}
		r := res_of(m.obj)
		v := ds.viewport
		if v.x != 0 || v.y != 0 || v.w < r.w || v.h < r.h {continue}
		s := ds.scissor
		if ds.rs[174] != 0 && (s[0] > 0 || s[1] > 0 || s[2] < i32(r.w) || s[3] < i32(r.h)) {continue}
		zs := flags & (D3DCLEAR_ZBUFFER | D3DCLEAR_STENCIL)
		whole := is_depth_format(r.format) ? zs == D3DCLEAR_ZBUFFER | D3DCLEAR_STENCIL || (zs == D3DCLEAR_ZBUFFER && r.format != D3DFMT_D24S8) : flags & D3DCLEAR_TARGET != 0
		if !whole {continue}
		m.live, m.dirty = true, false
		fb_dirty = true
	}
}

// Whether the fbo uses the twins: only when every bound attachment has a live
// one (GL framebuffers cannot mix sample counts). Otherwise each bound live
// twin is resolved and dropped.
ms_pick :: proc() -> bool {
	any, all := false, true
	objs := [RT_MAX + 1]u32{bind.rt[0], bind.rt[1], bind.rt[2], bind.rt[3], bind.depth}
	for obj in objs {
		if obj == 0 {continue}
		any = true
		m := ms_of(obj)
		if m == nil || !m.live {all = false}
	}
	if any && all {return true}
	for &m in msaa {
		if m.live && ms_is_bound(&m) {
			ms_resolve(&m)
			m.live = false
		}
	}
	return false
}

// Attaches surface obj, or its twin when use, to fbo at a.
ms_attach :: proc(a, obj: u32, use: bool) {
	if use && obj != 0 {
		gl.NamedFramebufferTexture(fbo, a, ms_of(obj).tex, 0)
		return
	}
	attach(fbo, a, obj)
}

// After fb_bind: a draw or clear follows, so bound twins get new content.
ms_mark :: proc() {
	if !ms_bound {return}
	for &m in msaa {
		if m.live && ms_is_bound(&m) {m.dirty = true}
	}
}
