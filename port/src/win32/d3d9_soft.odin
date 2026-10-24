// Soft particles (JE_SOFT): a blended particle quad fades out where it nears
// the scene behind it, so smoke, fire and sparks no longer cut a hard line
// through floors and walls. The scene depth is copied once per change into a
// texture the fixed-function pixel program reads; the fade is the view-space
// gap between the quad and that depth over SOFT_RANGE, both depths made
// linear by the projection transform. WHY: docs/rendering.md §10
package win32

import gl "vendor:OpenGL"

soft_on := true // JE_SOFT; 0 = off

SOFT_RANGE :: 0.4 // world units over which a particle fades in
SOFT_UNIT :: 16 // texture unit of the depth copy, past the 16 D3D samplers

// Fade kinds, the FF program key's soft field.
SOFT_NONE :: 0
SOFT_ALPHA :: 1 // source blend SRCALPHA: scale alpha
SOFT_COLOR :: 2 // ONE, ONE: scale color

Soft :: struct {
	tex, fbo: u32,
	w, h:     u32, // GL size of the copy
	format:   u32, // D3DFORMAT of the copy
	src:      u32, // depth surface the copy holds
	stale:    bool, // the depth surface changed since the copy
	kind:     u8, // fade of the draw being prepared
	param:    [4]f32, // MISC soft: A, B of z_ndc = A + B / w, 1 / SOFT_RANGE
}

soft: Soft

// The depth surface was written: the next soft draw copies it again.
soft_touch :: #force_inline proc() {soft.stale = true}

// Decides the fade of the draw being prepared, and copies the depth when it
// needs one. After fb_bind, before apply_raster.
soft_prepare :: proc(decl_id: u32, pretransformed: bool) {
	rs := &ds.rs
	soft.kind = SOFT_NONE
	if rs[7] != 0 && rs[14] != 0 {
		soft.stale = true
		return
	}
	if !soft_on || bind.ps != 0 || pretransformed || rs[27] == 0 || rs[7] == 0 || bind.depth == 0 ||
	   bind.depth != autodepth {return}
	kind := u8(SOFT_NONE)
	if rs[19] == 5 {
		kind = SOFT_ALPHA
	} else if rs[19] == 2 && rs[20] == 2 {
		kind = SOFT_COLOR
	} else {
		return
	}
	// Particles: color and texture, no normal.
	color, tex := false, false
	for e in decls[decl_id].elems {
		#partial switch e.usage {
		case .COLOR: color = true
		case .TEXCOORD: tex = true
		case .NORMAL, .BLENDWEIGHT: return
		}
	}
	if !color || !tex {return}
	// D3D perspective, row vectors: z_clip = z * _33 + _43, w_clip = z.
	p := &ds.xf[XF_PROJECTION]
	if p[2][3] != 1 || p[3][3] != 0 || p[3][2] == 0 {return}
	soft_copy()
	soft.kind = kind
	soft.param = {p[2][2], p[3][2], 1 / SOFT_RANGE, 0}
}

// Copies the bound depth surface (its MSAA twin when bound) into soft.tex.
@(private = "file")
soft_copy :: proc() {
	r := res_of(bind.depth)
	k := res_scale(r)
	w, h := r.w * k, r.h * k
	if soft.tex == 0 || soft.w != w || soft.h != h || soft.format != r.format {
		if soft.tex != 0 {gl.DeleteTextures(1, &soft.tex)}
		if soft.fbo == 0 {gl.CreateFramebuffers(1, &soft.fbo)}
		ifmt: i32
		gl.GetTextureLevelParameteriv(r.gl, 0, gl.TEXTURE_INTERNAL_FORMAT, &ifmt)
		gl.CreateTextures(gl.TEXTURE_2D, 1, &soft.tex)
		gl.TextureStorage2D(soft.tex, 1, u32(ifmt), i32(w), i32(h))
		gl.TextureParameteri(soft.tex, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
		gl.TextureParameteri(soft.tex, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
		gl.NamedFramebufferTexture(soft.fbo, depth_attachment_of(r.format), soft.tex, 0)
		gl.BindTextureUnit(SOFT_UNIT, soft.tex)
		soft.w, soft.h, soft.format, soft.stale = w, h, r.format, true
	}
	if !soft.stale && soft.src == bind.depth {return}
	gl.Disable(gl.SCISSOR_TEST)
	dg.raster.scissor_on = false
	gl.BlitNamedFramebuffer(fbo, soft.fbo, 0, 0, i32(w), i32(h), 0, 0, i32(w), i32(h), gl.DEPTH_BUFFER_BIT, gl.NEAREST)
	soft.src, soft.stale = bind.depth, false
}

// Fragment tail of a soft FF program: fades col by the depth gap.
GLSL_SOFT :: `	{
		float zs = (texelFetch(soft_depth, ivec2(gl_FragCoord.xy), 0).r - vp_z.x) * vp_z.y;
		float k = clamp((soft.y / (zs - soft.x) - 1.0 / gl_FragCoord.w) * soft.z, 0.0, 1.0);
`
