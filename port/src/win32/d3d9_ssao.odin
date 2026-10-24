// Ambient occlusion (JE_SSAO): volumetric obscurance (Loos and Sloan)
// from the scene depth, once a frame before the UI, at the head of the SMAA
// chain (smaa_frame). The view position of a pixel comes from its depth and
// the last perspective projection the game set; the occlusion of a disk of
// SSAO_RADIUS around it is blurred with a depth-aware 5x5 filter and
// multiplied into the back buffer. WHY: docs/rendering.md §15
package win32

import gl "vendor:OpenGL"

ssao_level: u32 // JE_SSAO; 0 = off, 1..3 = low, medium, high

SSAO_RADIUS :: 0.6 // world units sampled around a pixel
SSAO_INTENSITY := [4]f32{0, 0.6, 1.0, 1.5}

// Shared by both passes: the view distance of texel p of the depth, from
// proj = _11, _22, _33, _43 and _34 of a D3D (row vector) perspective, with
// window z = z_ndc (ClipControl ZERO_TO_ONE), and vp, the viewport that
// projection draws into, in texels (x, y, w, h; row 0 at the top). View
// space here is x right, y up (texture row 0 is NDC y = +1), z toward the
// eye; the sky (z = 1) is pushed far away so it neither occludes nor counts
// as a neighbour. Texels outside vp are left alone.
SSAO_HEAD :: `#version 460 core
layout(binding = 0) uniform sampler2D depth_tex;
layout(location = 0) uniform vec4 proj;
layout(location = 1) uniform vec4 prm; // _34, radius, intensity, 0
layout(location = 2) uniform vec4 vp;
layout(location = 0) out vec4 o;
ivec2 size = textureSize(depth_tex, 0);
float dist_at(ivec2 p) {
	float z = texelFetch(depth_tex, clamp(p, ivec2(0), size - 1), 0).r;
	return z >= 1.0 ? 1e6 : abs(proj.w / (prm.x * z - proj.z));
}
bool outside(ivec2 p) {
	return any(lessThan(vec2(p), vp.xy)) || any(greaterThanEqual(vec2(p), vp.xy + vp.zw));
}
`

SSAO_VS :: `#version 460 core
out gl_PerVertex { vec4 gl_Position; };
void main() {
	gl_Position = vec4(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0, 0.0, 1.0);
}
`

// Volumetric obscurance (Loos and Sloan 2010): the share of a sphere of
// prm.y around the pixel that lies behind the depth surface, from the columns
// along the view axis through taps on a disk. A flat surface fills half the
// sphere and is not darkened, a crease more, a convex surface less. No normal
// is used: one rebuilt from depth is flat per triangle, and on low-poly
// characters close to the camera it stepped the occlusion per triangle. A tap
// nearer than two radii in front is a separate object and counts as flat.
// Taps lie on a golden angle spiral turned per pixel by interleaved gradient
// noise. The occlusion fades out between SSAO_FADE_NEAR and SSAO_FADE_FAR
// and as the disk shrinks from 3 pixels to 1, where it stops.
// WHY: docs/rendering.md §15
SSAO_AO_PS :: `
const float SSAO_FADE_NEAR = 40.0, SSAO_FADE_FAR = 80.0;
void main() {
	ivec2 p = ivec2(gl_FragCoord.xy);
	if (outside(p)) { o = vec4(1.0); return; }
	float d = dist_at(p);
	float rpx = prm.y * proj.x * vp.z * 0.5 / d;
	if (d > 1e5 || rpx < 1.0) { o = vec4(1.0); return; }
	float k = min(rpx, vp.w * 0.25) / rpx;
	float a = 6.2831853 * fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
	float filled = 0.0, total = 0.0;
	for (int i = 0; i < 12; i++) {
		float t = sqrt((float(i) + 0.5) / 12.0) * k;
		float ang = a + float(i) * 2.3999632;
		float h = prm.y * sqrt(1.0 - t * t);
		float ds = dist_at(p + ivec2(round(vec2(cos(ang), sin(ang)) * t * rpx)));
		filled += d - ds > 2.0 * prm.y ? h : clamp(d + h - ds, 0.0, 2.0 * h);
		total += 2.0 * h;
	}
	float occ = max(2.0 * filled / total - 1.0, 0.0);
	occ *= smoothstep(1.0, 3.0, rpx) * (1.0 - smoothstep(SSAO_FADE_NEAR, SSAO_FADE_FAR, d));
	o = vec4(max(1.0 - prm.z * occ, 0.0));
}
`

// A 5x5 mean of the occlusion over the neighbours within 5% of the pixel's
// distance; the output is multiplied into the target (blend ZERO, SRC_COLOR).
SSAO_BLUR_PS :: `
layout(binding = 1) uniform sampler2D ao_tex;
void main() {
	ivec2 p = ivec2(gl_FragCoord.xy);
	float d = dist_at(p);
	if (d > 1e5 || outside(p)) { o = vec4(1.0); return; }
	float sum = 0.0, wsum = 0.0;
	for (int y = -2; y <= 2; y++) {
		for (int x = -2; x <= 2; x++) {
			ivec2 q = clamp(p + ivec2(x, y), ivec2(0), size - 1);
			float w = max(1.0 - abs(dist_at(q) - d) / (0.05 * d), 0.0) + 1e-4;
			sum += texelFetch(ao_tex, q, 0).r * w;
			wsum += w;
		}
	}
	o = vec4(vec3(sum / wsum), 1.0);
}
`

Ssao :: struct {
	ready:    bool,
	vs:       u32,
	ao, blur: u32, // fragment programs
	tex:      u32, // R8 occlusion at the back buffer's GL size
	w, h:     i32,
	proj:     [4]f32, // _11, _22, _33, _43 of the last perspective projection
	proj_34:  f32, // its _34; 0 before any
	vp:       Viewport, // the viewport it draws into
}

ssao: Ssao

// From SetTransform(PROJECTION): keeps the last perspective one, the scene's
// (the game also sets an identity projection between scene draws), and the
// back buffer's viewport; ssao_viewport keeps a viewport set after it.
ssao_projection :: proc(m: ^Mat) {
	if m[2][3] == 0 || m[3][3] != 0 || m[0][0] == 0 || m[1][1] == 0 {return}
	ssao.proj = {f32(m[0][0]), f32(m[1][1]), f32(m[2][2]), f32(m[3][2])}
	ssao.proj_34 = f32(m[2][3])
	if bind.rt[0] == backbuf {ssao.vp = ds.viewport}
}

// From SetViewport: the scene's viewport, when the projection is the scene's
// and the target the back buffer (character creation draws the scene into a
// panel, not the whole screen).
ssao_viewport :: proc() {
	m := &ds.xf[XF_PROJECTION]
	if m[2][3] != 0 && m[3][3] == 0 && bind.rt[0] == backbuf {ssao.vp = ds.viewport}
}

ssao_init :: proc() {
	ssao.vs = glsl_compile(SSAO_VS, false)
	ssao.ao = glsl_compile(SSAO_HEAD + SSAO_AO_PS, true)
	ssao.blur = glsl_compile(SSAO_HEAD + SSAO_BLUR_PS, true)
	ssao.ready = true
}

// Multiplies the occlusion into target (the back buffer's GL texture or its
// live multisampled twin). In smaa_frame's state: its pipeline, VAO and
// framebuffer bound, blending off, viewport w x h.
ssao_frame :: proc(target: u32, w, h: i32) {
	if ssao_level == 0 || ssao.proj_34 == 0 || autodepth == 0 {return}
	if !ssao.ready {ssao_init()}
	if ssao.w != w || ssao.h != h {
		if ssao.tex != 0 {gl.DeleteTextures(1, &ssao.tex)}
		gl.CreateTextures(gl.TEXTURE_2D, 1, &ssao.tex)
		gl.TextureStorage2D(ssao.tex, 1, gl.R8, w, h)
		ssao.w, ssao.h = w, h
	}
	d := res_of(autodepth)
	if i32(d.w * res_scale(d)) != w || i32(d.h * res_scale(d)) != h {return}
	ms_read(autodepth)
	p := ssao.proj
	prm := [4]f32{ssao.proj_34, SSAO_RADIUS, SSAO_INTENSITY[min(ssao_level, 3)], 0}
	s := f32(res_scale(d))
	v := [4]f32{f32(ssao.vp.x) * s, f32(ssao.vp.y) * s, f32(ssao.vp.w) * s, f32(ssao.vp.h) * s}
	if v[2] <= 0 || v[3] <= 0 {return}
	for prog in ([2]u32{ssao.ao, ssao.blur}) {
		gl.ProgramUniform4f(prog, 0, p[0], p[1], p[2], p[3])
		gl.ProgramUniform4f(prog, 1, prm[0], prm[1], prm[2], prm[3])
		gl.ProgramUniform4f(prog, 2, v[0], v[1], v[2], v[3])
	}
	gl.BindTextureUnit(0, d.gl)
	gl.BindSampler(0, smaa.pt)
	gl.BindTextureUnit(1, ssao.tex)
	gl.BindSampler(1, smaa.pt)
	gl.UseProgramStages(smaa.pipe, gl.VERTEX_SHADER_BIT, ssao.vs)
	gl.NamedFramebufferTexture(smaa.fbo, gl.COLOR_ATTACHMENT0, ssao.tex, 0)
	gl.UseProgramStages(smaa.pipe, gl.FRAGMENT_SHADER_BIT, ssao.ao)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
	gl.NamedFramebufferTexture(smaa.fbo, gl.COLOR_ATTACHMENT0, target, 0)
	gl.UseProgramStages(smaa.pipe, gl.FRAGMENT_SHADER_BIT, ssao.blur)
	gl.Enable(gl.BLEND)
	gl.BlendEquation(gl.FUNC_ADD)
	gl.BlendFuncSeparate(gl.ZERO, gl.SRC_COLOR, gl.ZERO, gl.ONE)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
	gl.Disable(gl.BLEND)
}
