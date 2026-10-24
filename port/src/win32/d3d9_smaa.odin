// SMAA 1x (JE_SMAA): Jimenez et al.'s morphological antialiasing over the back
// buffer, once a frame: at the frame's first copy out of the back buffer (the
// glow capture, before the UI is drawn), else at Present. The shader is the
// reference SMAA.hlsl and its precomputed area and search textures (MIT, in
// smaa/). Sharpening and vibrance (d3d9_cas.odin) run after it in the same
// chain. WHY: docs/rendering.md §9
package win32

import "core:strings"
import gl "vendor:OpenGL"

smaa_on := true // JE_SMAA; 0 = off

SMAA_SRC :: #load("smaa/SMAA.hlsl", string)
SMAA_AREA :: #load("smaa/area.bin") // 160 x 560 RG8
SMAA_SEARCH :: #load("smaa/search.bin") // 64 x 16 R8

SMAA_HEAD :: `#version 460 core
#define SMAA_GLSL_4
#define SMAA_PRESET_HIGH
#define SMAA_RT_METRICS rt
layout(location = 0) uniform vec4 rt;
`

// Every pass is one triangle over the target. The device runs with
// ClipControl(UPPER_LEFT), so clip y = +1 is texture row 0.
SMAA_VS_HEAD :: `#define SMAA_INCLUDE_PS 0
`
SMAA_VS_POS :: `
out gl_PerVertex { vec4 gl_Position; };
layout(location = 0) out vec2 uv;
vec2 fullscreen() {
	vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0);
	gl_Position = vec4(p, 0.0, 1.0);
	return vec2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
}
`
SMAA_PS_HEAD :: `#define SMAA_INCLUDE_VS 0
`

SMAA_EDGE_VS :: `layout(location = 1) out vec4 off[3];
void main() { uv = fullscreen(); SMAAEdgeDetectionVS(uv, off); }
`
SMAA_EDGE_PS :: `layout(binding = 0) uniform sampler2D color_tex;
layout(location = 0) in vec2 uv;
layout(location = 1) in vec4 off[3];
layout(location = 0) out vec4 o;
void main() { o = vec4(SMAAColorEdgeDetectionPS(uv, off, color_tex), 0.0, 0.0); }
`
SMAA_BLEND_VS :: `layout(location = 1) out vec4 off[3];
layout(location = 4) out vec2 pix;
void main() { uv = fullscreen(); SMAABlendingWeightCalculationVS(uv, pix, off); }
`
SMAA_BLEND_PS :: `layout(binding = 0) uniform sampler2D edges_tex;
layout(binding = 1) uniform sampler2D area_tex;
layout(binding = 2) uniform sampler2D search_tex;
layout(location = 0) in vec2 uv;
layout(location = 1) in vec4 off[3];
layout(location = 4) in vec2 pix;
layout(location = 0) out vec4 o;
void main() { o = SMAABlendingWeightCalculationPS(uv, pix, off, edges_tex, area_tex, search_tex, vec4(0.0)); }
`
SMAA_MIX_VS :: `layout(location = 1) out vec4 off;
void main() { uv = fullscreen(); SMAANeighborhoodBlendingVS(uv, off); }
`
SMAA_MIX_PS :: `layout(binding = 0) uniform sampler2D color_tex;
layout(binding = 1) uniform sampler2D blend_tex;
layout(location = 0) in vec2 uv;
layout(location = 1) in vec4 off;
layout(location = 0) out vec4 o;
void main() { o = SMAANeighborhoodBlendingPS(uv, off, color_tex, blend_tex); }
`

Smaa :: struct {
	ready:              bool,
	done:               bool, // ran this frame
	vs, ps:             [4]u32, // edge detection, blend weights, neighborhood blending, CAS
	pipe, vao, fbo:     u32,
	lin, pt:            u32, // samplers
	area, search:       u32,
	edges, blend, out:  u32, // at the back buffer's GL size
	w, h:               i32,
}

smaa: Smaa

smaa_init :: proc() {
	vs := [3]string{SMAA_EDGE_VS, SMAA_BLEND_VS, SMAA_MIX_VS}
	ps := [3]string{SMAA_EDGE_PS, SMAA_BLEND_PS, SMAA_MIX_PS}
	for i in 0 ..< 3 {
		smaa.vs[i] = glsl_compile(strings.concatenate({SMAA_HEAD, SMAA_VS_HEAD, SMAA_SRC, SMAA_VS_POS, vs[i]}, context.temp_allocator), false)
		smaa.ps[i] = glsl_compile(strings.concatenate({SMAA_HEAD, SMAA_PS_HEAD, SMAA_SRC, ps[i]}, context.temp_allocator), true)
	}
	smaa.vs[3] = glsl_compile(CAS_VS, false)
	smaa.ps[3] = glsl_compile(CAS_PS, true)
	gl.CreateProgramPipelines(1, &smaa.pipe)
	gl.CreateVertexArrays(1, &smaa.vao)
	gl.CreateFramebuffers(1, &smaa.fbo)
	gl.CreateSamplers(1, &smaa.lin)
	gl.CreateSamplers(1, &smaa.pt)
	for s in ([2]u32{smaa.lin, smaa.pt}) {
		f := i32(s == smaa.lin ? gl.LINEAR : gl.NEAREST)
		gl.SamplerParameteri(s, gl.TEXTURE_MIN_FILTER, f)
		gl.SamplerParameteri(s, gl.TEXTURE_MAG_FILTER, f)
		gl.SamplerParameteri(s, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
		gl.SamplerParameteri(s, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	}
	gl.CreateTextures(gl.TEXTURE_2D, 1, &smaa.area)
	gl.TextureStorage2D(smaa.area, 1, gl.RG8, 160, 560)
	gl.TextureSubImage2D(smaa.area, 0, 0, 0, 160, 560, gl.RG, gl.UNSIGNED_BYTE, raw_data(SMAA_AREA))
	gl.CreateTextures(gl.TEXTURE_2D, 1, &smaa.search)
	gl.TextureStorage2D(smaa.search, 1, gl.R8, 64, 16)
	gl.TextureSubImage2D(smaa.search, 0, 0, 0, 64, 16, gl.RED, gl.UNSIGNED_BYTE, raw_data(SMAA_SEARCH))
	smaa.ready = true
}

// (Re)allocates the work textures for a w x h back buffer.
smaa_resize :: proc(w, h: i32) {
	if w == smaa.w && h == smaa.h {return}
	if smaa.edges != 0 {
		gl.DeleteTextures(1, &smaa.edges)
		gl.DeleteTextures(1, &smaa.blend)
		gl.DeleteTextures(1, &smaa.out)
	}
	gl.CreateTextures(gl.TEXTURE_2D, 1, &smaa.edges)
	gl.TextureStorage2D(smaa.edges, 1, gl.RG8, w, h)
	gl.CreateTextures(gl.TEXTURE_2D, 1, &smaa.blend)
	gl.TextureStorage2D(smaa.blend, 1, gl.RGBA8, w, h)
	gl.CreateTextures(gl.TEXTURE_2D, 1, &smaa.out)
	gl.TextureStorage2D(smaa.out, 1, gl.RGBA8, w, h)
	progs := [6]u32{smaa.vs[0], smaa.vs[1], smaa.vs[2], smaa.ps[0], smaa.ps[1], smaa.ps[2]} // not CAS's
	for p in progs {
		if gl.GetUniformLocation(p, "rt") < 0 {continue} // compiled out
		gl.ProgramUniform4f(p, 0, 1 / f32(w), 1 / f32(h), f32(w), f32(h))
	}
	smaa.w, smaa.h = w, h
}

// One pass: program i into target tex (a multisampled twin works too), with
// up to three (texture, sampler) inputs on units 0..2. Edge detection
// discards pixels without edges, so the first two targets start cleared; the
// last pass writes every pixel.
smaa_pass :: proc(i: int, target: u32, inputs: [][2]u32) {
	gl.NamedFramebufferTexture(smaa.fbo, gl.COLOR_ATTACHMENT0, target, 0)
	if i < 2 {
		zero := [4]f32{}
		gl.ClearNamedFramebufferfv(smaa.fbo, gl.COLOR, 0, &zero[0])
	}
	for t, u in inputs {
		gl.BindTextureUnit(u32(u), t[0])
		gl.BindSampler(u32(u), t[1])
	}
	gl.UseProgramStages(smaa.pipe, gl.VERTEX_SHADER_BIT, smaa.vs[i])
	gl.UseProgramStages(smaa.pipe, gl.FRAGMENT_SHADER_BIT, smaa.ps[i])
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
}

// Runs SSAO (only for scene, before the UI), SMAA, then CAS, each when on,
// over the back buffer if they have not run this frame. None runs over a
// movie: the frames are film, already upscaled, and CAS oversharpens them. The last pass writes to the multisampled twin when that is
// live (every sample of a pixel gets the pixel's result), else to a work
// texture copied back into the surface. Draws restore every
// state touched here from render state (apply_raster), except the pipeline,
// the VAO and the samplers, restored below.
smaa_frame :: proc(scene: bool) {
	cas := cas_on()
	ao := scene && ssao_level != 0
	if (!smaa_on && !cas && !ao) || smaa.done || backbuf == 0 || len(binks) > 0 {return}
	smaa.done = true
	if !smaa.ready {smaa_init()}
	b := res_of(backbuf)
	k := res_scale(b)
	w, h := i32(b.w * k), i32(b.h * k)
	smaa_resize(w, h)
	m := ms_of(backbuf)
	twin := m != nil && m.live
	raster_lost()
	gl.Disable(gl.SCISSOR_TEST)
	gl.Disable(gl.BLEND)
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.STENCIL_TEST)
	gl.Disable(gl.CULL_FACE)
	gl.PolygonMode(gl.FRONT_AND_BACK, gl.FILL)
	gl.ColorMaski(0, true, true, true, true)
	gl.Viewport(0, 0, w, h)
	gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, smaa.fbo)
	gl.BindVertexArray(smaa.vao)
	gl.BindProgramPipeline(smaa.pipe)
	if ao {
		ssao_frame(twin ? m.tex : b.gl, w, h)
		if twin {m.dirty = true}
	}
	ms_read(backbuf)
	src, last := b.gl, twin ? m.tex : smaa.out
	if smaa_on {
		smaa_pass(0, smaa.edges, {{b.gl, smaa.lin}})
		smaa_pass(1, smaa.blend, {{smaa.edges, smaa.lin}, {smaa.area, smaa.lin}, {smaa.search, smaa.pt}})
		// Before CAS the result goes to smaa.out; blend is free for CAS then.
		src = cas ? smaa.out : last
		smaa_pass(2, src, {{b.gl, smaa.lin}, {smaa.blend, smaa.lin}})
	}
	if cas {
		if !twin {last = src == smaa.out ? smaa.blend : smaa.out}
		k := cas_k()
		gl.ProgramUniform2f(smaa.ps[3], 0, k[0], k[1])
		smaa_pass(3, last, {{src, smaa.pt}})
	}
	gl.NamedFramebufferTexture(smaa.fbo, gl.COLOR_ATTACHMENT0, 0, 0)
	if twin {
		m.dirty = true
	} else if smaa_on || cas {
		full := [4]i32{0, 0, w, h}
		gl_blit({last, 0, -1}, res_img(backbuf), full, full, b.format, false)
	}
	for u in u32(0) ..< 3 {gl.BindSampler(u, dg.samplers[u])}
	gl.BindVertexArray(dg.vao)
	gl.BindProgramPipeline(dg.pipe)
}
