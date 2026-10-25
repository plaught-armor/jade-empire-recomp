// Load-screen fade. The loading screen is never shown: while it is up,
// Present keeps the last ordinary frame on screen and fades it to black, and
// the first frames after it fade back in. The save message, a box over the
// game in the same GUI panel, is shown as is.
// WHY: docs/rendering.md §3
package win32

import "core:fmt"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"
import "../x86"

APP_PTR :: 0x76c924 // the application object
APP_GUI :: 0xb4 // its GUI manager
GUI_PANELS :: 0x8c // the GUI manager's table of open panels, by id
LOAD_PANEL :: 0x41 // the loading screen, and the save message
PANEL_W :: 0x0c // panel width and height, in GUI units
PANEL_H :: 0x10
GUI_W :: 640 // the GUI screen, in GUI units
GUI_H :: 480
FADE_OUT_S :: f32(0.25)
FADE_IN_S :: f32(0.35)
FADE_IN_DT_MAX :: f32(1.0 / 30) // a long first frame still shows the fade-in

Fade :: struct {
	level:     f32, // 1 = frame fully visible, 0 = black
	last_ns:   u64, // time of the previous Present; 0 before the first
	tex, fbo:  u32, // the last ordinary frame, at window size
	w, h:      i32,
	pipe, vao: u32,
	fs, copy:  u32, // the black overlay; the copy of a texture into a rectangle
	lin:       u32, // linear sampler for the copy
}

fade := Fade{level = 1}

FADE_VS :: `#version 460 core
out gl_PerVertex { vec4 gl_Position; };
void main() {
	vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0);
	gl_Position = vec4(p, 0.0, 1.0);
}
`

FADE_FS :: `#version 460 core
layout(location = 0) uniform float alpha;
out vec4 color;
void main() { color = vec4(0.0, 0.0, 0.0, alpha); }
`

// Present copies by drawing, not glBlitFramebuffer: AMD's Windows driver
// showed a scaled blit's source unscaled (a 1.5x crop of the title screen).
// rect: the destination's x, y and 1/w, 1/h in pixels; extent: the source
// texels used, from the texture's (0,0); flip: the source is top row first.
FADE_COPY_FS :: `#version 460 core
layout(location = 0) uniform vec4 rect;
layout(location = 1) uniform vec2 extent;
layout(location = 2) uniform bool flip;
layout(binding = 17) uniform sampler2D src;
out vec4 color;
void main() {
	vec2 uv = (gl_FragCoord.xy - rect.xy) * rect.zw;
	if (flip) uv.y = 1.0 - uv.y;
	color = vec4(texture(src, uv * extent / vec2(textureSize(src, 0))).rgb, 1.0);
}
`
FADE_UNIT :: 17 // texture unit of the copy's source, past SOFT_UNIT

// GUI panel id open now, or 0. The GUI manager's panel table holds a pointer
// for each open panel and 0 for a closed one (lookup 0x55d9f0).
gui_panel :: proc(id: u32) -> u32 {
	app := x86.rd32(APP_PTR)
	if app == 0 {return 0}
	gui := x86.rd32(app + APP_GUI)
	if gui == 0 {return 0}
	panels := x86.rd32(gui + GUI_PANELS)
	if panels == 0 {return 0}
	return x86.rd32(panels + 4 * id)
}

Load_Panel :: enum {
	None,
	Load_Screen, // panel 0x41 at full screen size
	Save_Box, // panel 0x41 as the 320x135 save message
}

// What panel 0x41 shows now. The main menu's attract movie plays over an
// open loading screen, so an open movie is never a load.
load_panel :: proc() -> Load_Panel {
	if len(binks) > 0 {return .None}
	p := gui_panel(LOAD_PANEL)
	if p == 0 {return .None}
	full := x86.rd32(p + PANEL_W) >= GUI_W && x86.rd32(p + PANEL_H) >= GUI_H
	return full ? .Load_Screen : .Save_Box
}

fade_init :: proc() {
	gl.CreateFramebuffers(1, &fade.fbo)
	gl.CreateVertexArrays(1, &fade.vao)
	gl.CreateProgramPipelines(1, &fade.pipe)
	fade.fs = glsl_compile(FADE_FS, true)
	fade.copy = glsl_compile(FADE_COPY_FS, true)
	gl.CreateSamplers(1, &fade.lin)
	gl.SamplerParameteri(fade.lin, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.SamplerParameteri(fade.lin, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.SamplerParameteri(fade.lin, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.SamplerParameteri(fade.lin, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.UseProgramStages(fade.pipe, gl.VERTEX_SHADER_BIT, glsl_compile(FADE_VS, false))
	gl.UseProgramStages(fade.pipe, gl.FRAGMENT_SHADER_BIT, fade.fs)
}

// (Re)allocates the held frame when the window size changes; the new one is black.
fade_resize :: proc(w, h: i32) {
	if w == fade.w && h == fade.h {return}
	fmt.eprintf("d3d9: window %dx%d pixels%s\n", w, h, fullscreen() ? ", fullscreen" : "")
	if fade.tex != 0 {gl.DeleteTextures(1, &fade.tex)}
	gl.CreateTextures(gl.TEXTURE_2D, 1, &fade.tex)
	gl.TextureStorage2D(fade.tex, 1, gl.RGBA8, max(w, 1), max(h, 1))
	gl.NamedFramebufferTexture(fade.fbo, gl.COLOR_ATTACHMENT0, fade.tex, 0)
	black := [4]f32{0, 0, 0, 1}
	gl.ClearNamedFramebufferfv(fade.fbo, gl.COLOR, 0, &black[0])
	fade.w, fade.h = w, h
}

// Steps the fade level by the time since the previous Present; the save box
// holds it where it is.
fade_step :: proc() -> (panel: Load_Panel) {
	now := sdl.GetTicksNS()
	dt := fade.last_ns == 0 ? 0 : f32(now - fade.last_ns) * 1e-9
	fade.last_ns = now
	panel = load_panel()
	switch panel {
	case .Save_Box:
	case .Load_Screen:
		fade.level = max(fade.level - dt / FADE_OUT_S, 0)
	case .None:
		fade.level = min(fade.level + min(dt, FADE_IN_DT_MAX) / FADE_IN_S, 1)
	}
	return
}

// Shows the frame: an ordinary back buffer (texture src, its bw x bh texels
// from (0,0)) replaces the held frame, a loading-screen or save-box one is
// dropped; the held frame goes to the window under a black overlay of alpha
// 1 - level. Draws restore every state touched here from render state
// (apply_raster), except the pipeline and VAO.
fade_present :: proc(src: u32, bw, bh, ww, wh: i32) {
	panel := fade_step()
	fade_resize(ww, wh)
	raster_lost()
	gl.Disable(gl.SCISSOR_TEST)
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.STENCIL_TEST)
	gl.Disable(gl.CULL_FACE)
	gl.Disable(gl.BLEND)
	gl.PolygonMode(gl.FRONT_AND_BACK, gl.FILL)
	gl.ColorMaski(0, true, true, true, true)
	gl.BindVertexArray(fade.vao)
	gl.BindProgramPipeline(fade.pipe)
	gl.UseProgramStages(fade.pipe, gl.FRAGMENT_SHADER_BIT, fade.copy)
	gl.BindSampler(FADE_UNIT, fade.lin)
	if panel == .None {
		// Letterboxed; the bars stay as fade_resize cleared them.
		fx, fy, fw, fh := view_rect(f32(ww), f32(wh))
		fade_copy(src, bw, bh, fade.fbo, {i32(fx), i32(fy), i32(fw), i32(fh)}, true)
	}
	fade_copy(fade.tex, ww, wh, 0, {0, 0, ww, wh}, false)
	gl.UseProgramStages(fade.pipe, gl.FRAGMENT_SHADER_BIT, fade.fs)
	if fade.level < 1 {
		gl.Enable(gl.BLEND)
		gl.BlendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ZERO, gl.ONE)
		gl.BlendEquationSeparate(gl.FUNC_ADD, gl.FUNC_ADD)
		gl.ProgramUniform1f(fade.fs, 0, 1 - fade.level)
		gl.DrawArrays(gl.TRIANGLES, 0, 3)
	}
	gl.BindVertexArray(dg.vao)
	gl.BindProgramPipeline(dg.pipe)
}

// Draws texels (0,0)-(sw,sh) of texture src over rectangle r (x, y, w, h) of
// framebuffer dst, top row first when flip.
@(private = "file")
fade_copy :: proc(src: u32, sw, sh: i32, dst: u32, r: [4]i32, flip: bool) {
	gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, dst)
	gl.Viewport(r.x, r.y, r.z, r.w)
	gl.ProgramUniform4f(fade.copy, 0, f32(r.x), f32(r.y), 1 / f32(max(r.z, 1)), 1 / f32(max(r.w, 1)))
	gl.ProgramUniform2f(fade.copy, 1, f32(sw), f32(sh))
	gl.ProgramUniform1i(fade.copy, 2, i32(flip))
	gl.BindTextureUnit(FADE_UNIT, src)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
}
