// Bloom (JE_BLOOM): replaces the game's glow pass (0x5cc100, native glow.odin)
// with a mip-chain bloom over the back buffer at its GL size. The game's pass
// takes a per-channel bright pass of a 640 x 480 copy through 8-bit lookup
// textures, shrinks it to 80 x 60 and blurs it with 25 weighted taps before
// adding it back; at that size it shows blocks and shimmer. Here the same
// bright pass, max(c - threshold, 0) times the same overall gain, runs in
// float from half size down BLOOM_LEVELS levels with a 13-tap filter, is
// summed back up with a 3 x 3 tent and added to the back buffer.
// WHY: docs/rendering.md §11
package win32

import "core:strings"
import gl "vendor:OpenGL"

bloom_on := true // JE_BLOOM; 0 = the game's glow

BLOOM_LEVELS :: 5

BLOOM_VS :: `#version 460 core
out gl_PerVertex { vec4 gl_Position; };
layout(location = 0) out vec2 uv;
void main() {
	vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0);
	gl_Position = vec4(p, 0.0, 1.0);
	uv = vec2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
}
`

BLOOM_PS_HEAD :: `#version 460 core
layout(binding = 0) uniform sampler2D src;
layout(location = 0) uniform vec4 texel; // xy: one source texel in uv
layout(location = 1) uniform vec4 param;
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 o;
`

// One level down: the 13-tap filter of Jimenez's Call of Duty bloom, each tap
// first through the bright pass when param.w is 1 (param.rgb the threshold).
BLOOM_DOWN_PS :: `vec3 tap(float x, float y) {
	vec3 c = texture(src, uv + texel.xy * vec2(x, y)).rgb;
	return param.w != 0.0 ? max(c - param.rgb, 0.0) : c;
}
void main() {
	vec3 c = tap(0, 0) * 0.125;
	c += (tap(-1, -1) + tap(1, -1) + tap(-1, 1) + tap(1, 1)) * 0.125;
	c += (tap(0, -2) + tap(-2, 0) + tap(2, 0) + tap(0, 2)) * 0.0625;
	c += (tap(-2, -2) + tap(2, -2) + tap(-2, 2) + tap(2, 2)) * 0.03125;
	o = vec4(c, 1.0);
}
`

// One level up, added onto the target: a 3 x 3 tent times param.x.
BLOOM_UP_PS :: `vec3 tap(float x, float y) {return texture(src, uv + texel.xy * vec2(x, y)).rgb;}
void main() {
	vec3 c = tap(0, 0) * 4.0;
	c += (tap(0, -1) + tap(-1, 0) + tap(1, 0) + tap(0, 1)) * 2.0;
	c += tap(-1, -1) + tap(1, -1) + tap(-1, 1) + tap(1, 1);
	o = vec4(c * (param.x / 16.0), 1.0);
}
`

Bloom :: struct {
	ready:          bool,
	vs, down, up:   u32,
	pipe, vao, fbo: u32,
	lin:            u32, // sampler
	mip:            [BLOOM_LEVELS]u32,
	size:           [BLOOM_LEVELS][2]i32,
	w, h:           i32, // back buffer GL size the levels are for
}

bloom: Bloom

@(private = "file")
bloom_init :: proc() {
	bloom.vs = glsl_compile(BLOOM_VS, false)
	bloom.down = glsl_compile(strings.concatenate({BLOOM_PS_HEAD, BLOOM_DOWN_PS}, context.temp_allocator), true)
	bloom.up = glsl_compile(strings.concatenate({BLOOM_PS_HEAD, BLOOM_UP_PS}, context.temp_allocator), true)
	gl.CreateProgramPipelines(1, &bloom.pipe)
	gl.UseProgramStages(bloom.pipe, gl.VERTEX_SHADER_BIT, bloom.vs)
	gl.CreateVertexArrays(1, &bloom.vao)
	gl.CreateFramebuffers(1, &bloom.fbo)
	gl.CreateSamplers(1, &bloom.lin)
	gl.SamplerParameteri(bloom.lin, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.SamplerParameteri(bloom.lin, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.SamplerParameteri(bloom.lin, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.SamplerParameteri(bloom.lin, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	bloom.ready = true
}

// (Re)allocates the levels for a w x h back buffer: half size, then halving.
@(private = "file")
bloom_resize :: proc(w, h: i32) {
	if w == bloom.w && h == bloom.h {return}
	if bloom.mip[0] != 0 {gl.DeleteTextures(BLOOM_LEVELS, &bloom.mip[0])}
	gl.CreateTextures(gl.TEXTURE_2D, BLOOM_LEVELS, &bloom.mip[0])
	lw, lh := w, h
	for i in 0 ..< BLOOM_LEVELS {
		lw, lh = max(lw / 2, 1), max(lh / 2, 1)
		gl.TextureStorage2D(bloom.mip[i], 1, gl.R11F_G11F_B10F, lw, lh)
		bloom.size[i] = {lw, lh}
	}
	bloom.w, bloom.h = w, h
}

// One pass of prog from texture src (sw x sh) into texture dst (dw x dh;
// a multisampled twin works too), added onto it when add.
@(private = "file")
bloom_pass :: proc(prog, src: u32, sw, sh: i32, dst: u32, dw, dh: i32, param: [4]f32, add: bool) {
	gl.NamedFramebufferTexture(bloom.fbo, gl.COLOR_ATTACHMENT0, dst, 0)
	gl.ProgramUniform4f(prog, 0, 1 / f32(sw), 1 / f32(sh), 0, 0)
	gl.ProgramUniform4f(prog, 1, param[0], param[1], param[2], param[3])
	gl.UseProgramStages(bloom.pipe, gl.FRAGMENT_SHADER_BIT, prog)
	gl.BindTextureUnit(0, src)
	if add {gl.Enable(gl.BLEND)} else {gl.Disable(gl.BLEND)}
	gl.Viewport(0, 0, dw, dh)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
}

// Adds the bloom of the back buffer to it: the bright pass keeps what each
// channel has above threshold, and gain scales the sum of the levels. The
// result goes to the multisampled twin when that is live, else to the
// surface. Draws restore every state touched here from render state
// (apply_raster), except the pipeline, the VAO, unit 0 and its sampler,
// restored below.
bloom_frame :: proc(threshold: [3]f32, gain: f32) {
	if backbuf == 0 || null_render {return}
	if !bloom.ready {bloom_init()}
	b := res_of(backbuf)
	k := res_scale(b)
	w, h := i32(b.w * k), i32(b.h * k)
	bloom_resize(w, h)
	ms_read(backbuf)
	m := ms_of(backbuf)
	twin := m != nil && m.live
	raster_lost()
	gl.Disable(gl.SCISSOR_TEST)
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.STENCIL_TEST)
	gl.Disable(gl.CULL_FACE)
	gl.PolygonMode(gl.FRONT_AND_BACK, gl.FILL)
	gl.ColorMaski(0, true, true, true, true)
	gl.BlendFunc(gl.ONE, gl.ONE)
	gl.BlendEquation(gl.FUNC_ADD)
	gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, bloom.fbo)
	gl.BindVertexArray(bloom.vao)
	gl.BindProgramPipeline(bloom.pipe)
	gl.BindSampler(0, bloom.lin)
	t := threshold
	bloom_pass(bloom.down, b.gl, w, h, bloom.mip[0], bloom.size[0].x, bloom.size[0].y, {t[0], t[1], t[2], 1}, false)
	for i in 1 ..< BLOOM_LEVELS {
		s, d := bloom.size[i - 1], bloom.size[i]
		bloom_pass(bloom.down, bloom.mip[i - 1], s.x, s.y, bloom.mip[i], d.x, d.y, {}, false)
	}
	for i := BLOOM_LEVELS - 1; i > 0; i -= 1 {
		s, d := bloom.size[i], bloom.size[i - 1]
		bloom_pass(bloom.up, bloom.mip[i], s.x, s.y, bloom.mip[i - 1], d.x, d.y, {1, 0, 0, 0}, true)
	}
	s := bloom.size[0]
	bloom_pass(bloom.up, bloom.mip[0], s.x, s.y, twin ? m.tex : b.gl, w, h, {gain / BLOOM_LEVELS, 0, 0, 0}, true)
	gl.NamedFramebufferTexture(bloom.fbo, gl.COLOR_ATTACHMENT0, 0, 0)
	if twin {m.dirty = true}
	gl.BindSampler(0, dg.samplers[0])
	gl.BindVertexArray(dg.vao)
	gl.BindProgramPipeline(dg.pipe)
}
