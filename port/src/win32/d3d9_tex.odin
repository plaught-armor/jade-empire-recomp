// Textures, cube textures and surfaces on GL immutable-storage textures.
package win32

import gl "vendor:OpenGL"
import "../x86"

GL_COMPRESSED_RGBA_S3TC_DXT1 :: 0x83f1
GL_COMPRESSED_RGBA_S3TC_DXT3 :: 0x83f2
GL_COMPRESSED_RGBA_S3TC_DXT5 :: 0x83f3

// bits: per texel; block: bytes per 4x4 block (compressed formats).
Fmt_Info :: struct {
	bits, block:            u32,
	internal, format, type: u32,
	swz:                    [4]i32,
}

SWZ_ID :: [4]i32{gl.RED, gl.GREEN, gl.BLUE, gl.ALPHA}
SWZ_X :: [4]i32{gl.RED, gl.GREEN, gl.BLUE, gl.ONE}

fmt_info :: proc(f: u32) -> (Fmt_Info, bool) {
	switch f {
	case D3DFMT_A8R8G8B8: return {32, 0, gl.RGBA8, gl.BGRA, gl.UNSIGNED_INT_8_8_8_8_REV, SWZ_ID}, true
	case D3DFMT_X8R8G8B8: return {32, 0, gl.RGBA8, gl.BGRA, gl.UNSIGNED_INT_8_8_8_8_REV, SWZ_X}, true
	case D3DFMT_A8B8G8R8: return {32, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, SWZ_ID}, true
	case D3DFMT_R5G6B5: return {16, 0, gl.RGB565, gl.RGB, gl.UNSIGNED_SHORT_5_6_5, SWZ_X}, true
	case D3DFMT_A1R5G5B5: return {16, 0, gl.RGB5_A1, gl.BGRA, gl.UNSIGNED_SHORT_1_5_5_5_REV, SWZ_ID}, true
	case D3DFMT_X1R5G5B5: return {16, 0, gl.RGB5_A1, gl.BGRA, gl.UNSIGNED_SHORT_1_5_5_5_REV, SWZ_X}, true
	case D3DFMT_A4R4G4B4: return {16, 0, gl.RGBA4, gl.BGRA, gl.UNSIGNED_SHORT_4_4_4_4_REV, SWZ_ID}, true
	case D3DFMT_A8: return {8, 0, gl.R8, gl.RED, gl.UNSIGNED_BYTE, {gl.ZERO, gl.ZERO, gl.ZERO, gl.RED}}, true
	case D3DFMT_L8: return {8, 0, gl.R8, gl.RED, gl.UNSIGNED_BYTE, {gl.RED, gl.RED, gl.RED, gl.ONE}}, true
	case D3DFMT_A8L8: return {16, 0, gl.RG8, gl.RG, gl.UNSIGNED_BYTE, {gl.RED, gl.RED, gl.RED, gl.GREEN}}, true
	case D3DFMT_V8U8: return {16, 0, gl.RG8_SNORM, gl.RG, gl.BYTE, {gl.RED, gl.GREEN, gl.ONE, gl.ONE}}, true
	case D3DFMT_R16F: return {16, 0, gl.R16F, gl.RED, gl.HALF_FLOAT, {gl.RED, gl.ONE, gl.ONE, gl.ONE}}, true
	case D3DFMT_G16R16F: return {32, 0, gl.RG16F, gl.RG, gl.HALF_FLOAT, {gl.RED, gl.GREEN, gl.ONE, gl.ONE}}, true
	case D3DFMT_A16B16G16R16F: return {64, 0, gl.RGBA16F, gl.RGBA, gl.HALF_FLOAT, SWZ_ID}, true
	case D3DFMT_R32F: return {32, 0, gl.R32F, gl.RED, gl.FLOAT, {gl.RED, gl.ONE, gl.ONE, gl.ONE}}, true
	case D3DFMT_A32B32G32R32F: return {128, 0, gl.RGBA32F, gl.RGBA, gl.FLOAT, SWZ_ID}, true
	case D3DFMT_DXT1: return {0, 8, GL_COMPRESSED_RGBA_S3TC_DXT1, 0, 0, SWZ_ID}, true
	case D3DFMT_DXT2, D3DFMT_DXT3: return {0, 16, GL_COMPRESSED_RGBA_S3TC_DXT3, 0, 0, SWZ_ID}, true
	case D3DFMT_DXT4, D3DFMT_DXT5: return {0, 16, GL_COMPRESSED_RGBA_S3TC_DXT5, 0, 0, SWZ_ID}, true
	case D3DFMT_D24S8, D3DFMT_D24X8: return {32, 0, gl.DEPTH24_STENCIL8, gl.DEPTH_STENCIL, gl.UNSIGNED_INT_24_8, SWZ_ID}, true
	case D3DFMT_D16: return {16, 0, gl.DEPTH_COMPONENT16, gl.DEPTH_COMPONENT, gl.UNSIGNED_SHORT, SWZ_ID}, true
	}
	return {}, false
}

fmt_must :: proc(f: u32) -> Fmt_Info {
	fi, ok := fmt_info(f)
	if !ok {
		x86.fatal("d3d9: unsupported format %d", f)
	}
	return fi
}

level_dim :: #force_inline proc(v, l: u32) -> u32 {return max(1, v >> l)}

level_pitch :: proc(fi: Fmt_Info, w: u32) -> u32 {
	return fi.block != 0 ? max(1, (w + 3) / 4) * fi.block : w * fi.bits / 8
}

level_rows :: proc(fi: Fmt_Info, h: u32) -> u32 {
	return fi.block != 0 ? max(1, (h + 3) / 4) : h
}

level_bytes :: proc(fi: Fmt_Info, w, h, l: u32) -> u32 {
	return level_pitch(fi, level_dim(w, l)) * level_rows(fi, level_dim(h, l))
}

full_levels :: proc(w, h: u32) -> u32 {
	n: u32 = 1
	for v := max(w, h); v > 1; v >>= 1 {
		n += 1
	}
	return n
}

faces :: #force_inline proc(r: ^Res) -> u32 {return r.kind == .Cube ? 6 : 1}

// Byte offset of (face, level) inside the shadow; the second result is the
// whole shadow size.
shadow_off :: proc(r: ^Res, face, level: u32) -> (off, total: u32) {
	fi := fmt_must(r.format)
	chain: u32 = 0
	for l in 0 ..< r.levels {
		if l == level {off = chain}
		chain += level_bytes(fi, r.w, r.h, l)
	}
	return face * chain + off, faces(r) * chain
}

// Render-target scale: render targets and depth surfaces get GL storage at
// rt_scale times their D3D size; the guest only ever sees D3D sizes.
// WHY: docs/rendering.md §1
rt_scale: u32 = 1

usage_scale :: proc(usage: u32) -> u32 {
	return usage & (D3DUSAGE_RENDERTARGET | D3DUSAGE_DEPTHSTENCIL) != 0 ? rt_scale : 1
}

res_scale :: #force_inline proc(r: ^Res) -> u32 {return max(r.scale, 1)}

tex_gl_create :: proc(target: u32, fi: Fmt_Info, w, h, levels: u32) -> (t: u32) {
	gl.CreateTextures(target, 1, &t)
	gl.TextureStorage2D(t, i32(levels), fi.internal, i32(w), i32(h))
	swz := fi.swz
	gl.TextureParameteriv(t, gl.TEXTURE_SWIZZLE_RGBA, &swz[0])
	gl.TextureParameteri(t, gl.TEXTURE_MAX_LEVEL, i32(levels - 1))
	return
}

// r: a texture, cube or standalone surface (the shadow owner).
lock_level :: proc(r: ^Res, face, level, out, rect, flags: u32) -> u32 {
	if level >= r.levels || face >= faces(r) {
		return D3DERR_INVALIDCALL
	}
	fi := fmt_must(r.format)
	off, total := shadow_off(r, face, level)
	if r.shadow == 0 {
		r.shadow = heap_alloc(total, true)
	}
	if r.kind == .Surface && r.usage & (D3DUSAGE_RENDERTARGET | D3DUSAGE_DEPTHSTENCIL) != 0 {
		ms_read(r.obj)
		if flags & D3DLOCK_READONLY == 0 {ms_write(r.obj)}
		surf_read(r, fi, total, x86.ptr(r.shadow))
	}
	pitch := level_pitch(fi, level_dim(r.w, level))
	p := r.shadow + off
	if rect != 0 {
		left, top := x86.rd32(rect), x86.rd32(rect + 4)
		p += fi.block != 0 ? top / 4 * pitch + left / 4 * fi.block : top * pitch + left * fi.bits / 8
	}
	x86.wr32(out, pitch)
	x86.wr32(out + 4, p)
	r.lock_flags = flags
	r.locked = true
	return D3D_OK
}

unlock_level :: proc(r: ^Res, face, level: u32) -> u32 {
	if !r.locked {
		return D3DERR_INVALIDCALL
	}
	r.locked = false
	if r.lock_flags & D3DLOCK_READONLY != 0 || r.host_fed {
		return D3D_OK
	}
	if font_hd_unlock(r) {
		return D3D_OK
	}
	fi := fmt_must(r.format)
	off, _ := shadow_off(r, face, level)
	tex_upload(r, fi, face, level, x86.ptr(r.shadow + off))
	if level == 0 && r.usage & D3DUSAGE_AUTOGENMIPMAP != 0 {
		gl.GenerateTextureMipmap(r.gl)
	}
	return D3D_OK
}

// Level 0 of standalone surface r at its D3D size into dst (n bytes). A
// scaled surface is first reduced to D3D size on the GPU.
surf_read :: proc(r: ^Res, fi: Fmt_Info, n: u32, dst: rawptr) {
	src := r.gl
	if k := res_scale(r); k > 1 {
		src = tex_gl_create(gl.TEXTURE_2D, fi, r.w, r.h, 1)
		sr := [4]i32{0, 0, i32(r.w * k), i32(r.h * k)}
		gl_blit({r.gl, 0, -1}, {src, 0, -1}, sr, {0, 0, i32(r.w), i32(r.h)}, r.format, true)
	}
	gl.GetTextureImage(src, 0, fi.format, fi.type, i32(n), dst)
	if src != r.gl {gl.DeleteTextures(1, &src)}
}

// Replaces (face, level) of r's GL texture with the level image at src.
tex_upload :: proc(r: ^Res, fi: Fmt_Info, face, level: u32, src: rawptr) {
	w, h := i32(level_dim(r.w, level)), i32(level_dim(r.h, level))
	n := i32(level_bytes(fi, r.w, r.h, level))
	if k := res_scale(r); k > 1 { // D3D-size image, scaled up into the storage
		assert(fi.block == 0, "compressed render target")
		tmp := tex_gl_create(gl.TEXTURE_2D, fi, u32(w), u32(h), 1)
		gl.TextureSubImage2D(tmp, 0, 0, 0, w, h, fi.format, fi.type, src)
		dr := [4]i32{0, 0, i32(level_dim(r.w * k, level)), i32(level_dim(r.h * k, level))}
		gl_blit({tmp, 0, -1}, {r.gl, i32(level), r.kind == .Cube ? i32(face) : -1}, {0, 0, w, h}, dr, r.format, true)
		gl.DeleteTextures(1, &tmp)
		return
	}
	switch {
	case r.kind == .Cube && fi.block != 0:
		gl.CompressedTextureSubImage3D(r.gl, i32(level), 0, 0, i32(face), w, h, 1, fi.internal, n, src)
	case r.kind == .Cube:
		gl.TextureSubImage3D(r.gl, i32(level), 0, 0, i32(face), w, h, 1, fi.format, fi.type, src)
	case fi.block != 0:
		gl.CompressedTextureSubImage2D(r.gl, i32(level), 0, 0, w, h, fi.internal, n, src)
	case:
		gl.TextureSubImage2D(r.gl, i32(level), 0, 0, w, h, fi.format, fi.type, src)
	}
}

TEX_OWN := [?]Com_Method {
	{"SetLOD", Tex_SetLOD}, {"GetLOD", Tex_GetLOD}, {"GetLevelCount", Tex_GetLevelCount},
	{"SetAutoGenFilterType", Tex_SetAutoGenFilterType}, {"GetAutoGenFilterType", Tex_GetAutoGenFilterType},
	{"GenerateMipSubLevels", Tex_GenerateMipSubLevels},
	{"GetLevelDesc", Tex_GetLevelDesc}, {"GetSurfaceLevel", Tex_GetSurfaceLevel},
	{"LockRect", Tex_LockRect}, {"UnlockRect", Tex_UnlockRect}, {"AddDirtyRect", Tex_AddDirtyRect},
}

CUBE_OWN := [?]Com_Method {
	{"SetLOD", Tex_SetLOD}, {"GetLOD", Tex_GetLOD}, {"GetLevelCount", Tex_GetLevelCount},
	{"SetAutoGenFilterType", Tex_SetAutoGenFilterType}, {"GetAutoGenFilterType", Tex_GetAutoGenFilterType},
	{"GenerateMipSubLevels", Tex_GenerateMipSubLevels},
	{"GetLevelDesc", Tex_GetLevelDesc}, {"GetCubeMapSurface", Cube_GetCubeMapSurface},
	{"LockRect", Cube_LockRect}, {"UnlockRect", Cube_UnlockRect}, {"AddDirtyRect", Cube_AddDirtyRect},
}

SURF_OWN := [?]Com_Method {
	{"GetContainer", Surf_GetContainer}, {"GetDesc", Surf_GetDesc},
	{"LockRect", Surf_LockRect}, {"UnlockRect", Surf_UnlockRect},
	{"GetDC", nil}, {"ReleaseDC", nil},
}

tex_create :: proc(kind: Res_Kind, w, h, levels, usage, format, pool, out: u32) -> u32 {
	fi, ok := fmt_info(format)
	if !ok {
		x86.wr32(out, 0)
		return D3DERR_INVALIDCALL
	}
	n := levels == 0 || usage & D3DUSAGE_AUTOGENMIPMAP != 0 ? full_levels(w, h) : levels
	vt := kind == .Cube ? res_vtable("IDirect3DCubeTexture9", CUBE_OWN[:]) : res_vtable("IDirect3DTexture9", TEX_OWN[:])
	_, r := res_new(kind, vt)
	r.format, r.usage, r.pool, r.w, r.h, r.levels = format, usage, pool, w, h, n
	r.scale = usage_scale(usage)
	r.gl = tex_gl_create(kind == .Cube ? gl.TEXTURE_CUBE_MAP : gl.TEXTURE_2D, fi, w * r.scale, h * r.scale, n)
	r.surfs = make([dynamic]u32, faces(r) * n)
	x86.wr32(out, r.obj)
	return D3D_OK
}

// (this, Width, Height, Levels, Usage, Format, Pool, ppTexture, pSharedHandle)
Dev_CreateTexture :: proc() {
	ra := x86.rd32(x86.cpu.esp)
	hr := tex_create(.Texture, arg(1), arg(2), arg(3), arg(4), arg(5), arg(6), arg(7))
	font_hd_texture(ra, hr, arg(7))
	ret(9, hr)
}

// (this, EdgeLength, Levels, Usage, Format, Pool, ppCubeTexture, pSharedHandle)
Dev_CreateCubeTexture :: proc() {
	ret(8, tex_create(.Cube, arg(1), arg(1), arg(2), arg(3), arg(4), arg(5), arg(6)))
}

// D3DX creation: D3DX_DEFAULT / 0 sizes become 256 and D3DFMT_UNKNOWN
// becomes A8R8G8B8 (D3DXCheckTextureRequirements); GL storage takes any
// size, so no power-of-two rounding.
d3dx_size :: proc(v: u32) -> u32 {return v == 0 || v == D3DX_DEFAULT ? 256 : v}
d3dx_format :: proc(f: u32) -> u32 {return f == D3DFMT_UNKNOWN ? D3DFMT_A8R8G8B8 : f}
d3dx_levels :: proc(l: u32) -> u32 {return l == D3DX_DEFAULT ? 0 : l}

// (pDevice, Width, Height, MipLevels, Usage, Format, Pool, ppTexture)
D3DXCreateTexture :: proc() {
	ret(8, tex_create(.Texture, d3dx_size(arg(1)), d3dx_size(arg(2)), d3dx_levels(arg(3)), arg(4), d3dx_format(arg(5)), arg(6), arg(7)))
}

// (pDevice, Size, MipLevels, Usage, Format, Pool, ppCubeTexture)
D3DXCreateCubeTexture :: proc() {
	sz := d3dx_size(arg(1))
	ret(7, tex_create(.Cube, sz, sz, d3dx_levels(arg(2)), arg(3), d3dx_format(arg(4)), arg(5), arg(6)))
}

Tex_SetLOD :: proc() {
	r := res_of(arg(0))
	old := r.lod
	r.lod = min(arg(1), r.levels - 1)
	gl.TextureParameteri(r.gl, gl.TEXTURE_BASE_LEVEL, i32(r.lod))
	ret(2, old)
}

Tex_GetLOD :: proc() {ret(1, res_of(arg(0)).lod)}

Tex_GetLevelCount :: proc() {
	r := res_of(arg(0))
	ret(1, r.usage & D3DUSAGE_AUTOGENMIPMAP != 0 ? 1 : r.levels)
}

Tex_SetAutoGenFilterType :: proc() {ret(2, D3D_OK)}
Tex_GetAutoGenFilterType :: proc() {ret(1, 2)} // D3DTEXF_LINEAR

Tex_GenerateMipSubLevels :: proc() {
	gl.GenerateTextureMipmap(res_of(arg(0)).gl)
	ret(1, 0)
}

Tex_GetLevelDesc :: proc() {
	r := res_of(arg(0))
	l := arg(1)
	if l >= r.levels {
		ret(3, D3DERR_INVALIDCALL)
		return
	}
	put_surface_desc(arg(2), r, level_dim(r.w, l), level_dim(r.h, l))
	ret(3, D3D_OK)
}

// Surface object for (face, level) of texture id, created on first request.
tex_surface :: proc(id, face, level: u32) -> u32 {
	k := face * res[id].levels + level
	if s := res[id].surfs[k]; s != 0 {
		x86.wr32(s + 4, x86.rd32(s + 4) + 1)
		return s
	}
	vt := res_vtable("IDirect3DSurface9", SURF_OWN[:])
	_, sr := res_new(.Surface, vt)
	t := &res[id]
	sr.format, sr.usage, sr.pool, sr.gl, sr.scale = t.format, t.usage, t.pool, t.gl, t.scale
	sr.w, sr.h, sr.levels = level_dim(t.w, level), level_dim(t.h, level), 1
	sr.parent, sr.face, sr.level = id + 1, face, level
	t.surfs[k] = sr.obj
	return sr.obj
}

Tex_GetSurfaceLevel :: proc() {
	r := res_of(arg(0))
	l := arg(1)
	if l >= r.levels {
		ret(3, D3DERR_INVALIDCALL)
		return
	}
	x86.wr32(arg(2), tex_surface(com_id(arg(0)), 0, l))
	ret(3, D3D_OK)
}

Tex_LockRect :: proc() {
	r := res_of(arg(0))
	hr := lock_level(r, 0, arg(1), arg(2), arg(3), arg(4))
	if hr == D3D_OK {font_hd_lock(r, x86.rd32(x86.cpu.esp))}
	ret(5, hr)
}
Tex_UnlockRect :: proc() {ret(2, unlock_level(res_of(arg(0)), 0, arg(1)))}
Tex_AddDirtyRect :: proc() {ret(2, D3D_OK)}

Cube_GetCubeMapSurface :: proc() {
	r := res_of(arg(0))
	f, l := arg(1), arg(2)
	if l >= r.levels || f >= 6 {
		ret(4, D3DERR_INVALIDCALL)
		return
	}
	x86.wr32(arg(3), tex_surface(com_id(arg(0)), f, l))
	ret(4, D3D_OK)
}

Cube_LockRect :: proc() {ret(6, lock_level(res_of(arg(0)), arg(1), arg(2), arg(3), arg(4), arg(5)))}
Cube_UnlockRect :: proc() {ret(3, unlock_level(res_of(arg(0)), arg(1), arg(2)))}
Cube_AddDirtyRect :: proc() {ret(3, D3D_OK)}

// The shadow owner of a surface and the surface's place in it.
surf_owner :: proc(s: ^Res) -> (^Res, u32, u32) {
	if s.parent == 0 {
		return s, 0, 0
	}
	return &res[s.parent - 1], s.face, s.level
}

// Standalone surface object, or 0 for an unsupported format.
surface_new :: proc(w, h, format, usage, pool: u32) -> u32 {
	fi, ok := fmt_info(format)
	if !ok || w == 0 || h == 0 {
		return 0
	}
	_, r := res_new(.Surface, res_vtable("IDirect3DSurface9", SURF_OWN[:]))
	r.format, r.usage, r.pool, r.w, r.h, r.levels = format, usage, pool, w, h, 1
	r.scale = usage_scale(usage)
	r.gl = tex_gl_create(gl.TEXTURE_2D, fi, w * r.scale, h * r.scale, 1)
	return r.obj
}

surface_create :: proc(w, h, format, usage, pool, out: u32) -> u32 {
	s := surface_new(w, h, format, usage, pool)
	x86.wr32(out, s)
	return s != 0 ? D3D_OK : D3DERR_INVALIDCALL
}

// (this, Width, Height, Format, MultiSample, MultisampleQuality, Lockable, ppSurface, pSharedHandle)
Dev_CreateRenderTarget :: proc() {
	ret(9, surface_create(arg(1), arg(2), arg(3), D3DUSAGE_RENDERTARGET, D3DPOOL_DEFAULT, arg(7)))
}

// (this, Width, Height, Format, MultiSample, MultisampleQuality, Discard, ppSurface, pSharedHandle)
Dev_CreateDepthStencilSurface :: proc() {
	ret(9, surface_create(arg(1), arg(2), arg(3), D3DUSAGE_DEPTHSTENCIL, D3DPOOL_DEFAULT, arg(7)))
}

// (this, Width, Height, Format, Pool, ppSurface, pSharedHandle)
Dev_CreateOffscreenPlainSurface :: proc() {
	ret(7, surface_create(arg(1), arg(2), arg(3), 0, arg(4), arg(5)))
}

Surf_GetContainer :: proc() {
	s := res_of(arg(0))
	c := s.parent != 0 ? res[s.parent - 1].obj : device_obj
	x86.wr32(c + 4, x86.rd32(c + 4) + 1)
	x86.wr32(arg(2), c)
	ret(3, D3D_OK)
}

Surf_GetDesc :: proc() {
	s := res_of(arg(0))
	put_surface_desc(arg(1), s, s.w, s.h)
	ret(2, D3D_OK)
}

Surf_LockRect :: proc() {
	o, f, l := surf_owner(res_of(arg(0)))
	ret(4, lock_level(o, f, l, arg(1), arg(2), arg(3)))
}

Surf_UnlockRect :: proc() {
	o, f, l := surf_owner(res_of(arg(0)))
	ret(1, unlock_level(o, f, l))
}

D3DX_DEFAULT :: 0xffffffff

// D3DXFilterTexture(pBaseTexture, pPalette, SrcLevel, MipFilter): rebuilds
// levels below SrcLevel from it. GL's mip generation stands in for every
// D3DX_FILTER_* (box-like 2x2 averaging); DXT formats go through a CPU
// decode / 2x2 box / re-encode chain (d3dx_dxt.odin). The guest shadow, if any, is read
// back so later locks see the new levels.
D3DXFilterTexture :: proc() {
	r, pal, src := res_of(arg(0)), arg(1), arg(2)
	if pal != 0 {x86.fatal("D3DXFilterTexture: palette")}
	if src == D3DX_DEFAULT {src = 0}
	if r.kind != .Texture && r.kind != .Cube {x86.fatal("D3DXFilterTexture: resource kind %v", r.kind)}
	if src >= r.levels {
		ret(4, D3DERR_INVALIDCALL)
		return
	}
	fi := fmt_must(r.format)
	if fi.block != 0 {
		for f in 0 ..< faces(r) {tex_filter_dxt(r, fi, f, src)}
	} else if src + 1 < r.levels {
		gl.TextureParameteri(r.gl, gl.TEXTURE_BASE_LEVEL, i32(src))
		gl.GenerateTextureMipmap(r.gl)
		gl.TextureParameteri(r.gl, gl.TEXTURE_BASE_LEVEL, i32(r.lod))
		if r.shadow != 0 {tex_shadow_readback(r, fi, src + 1)}
	}
	ret(4, D3D_OK)
}

// Copies levels first.. of every face from GL into the shadow.
tex_shadow_readback :: proc(r: ^Res, fi: Fmt_Info, first: u32) {
	assert(res_scale(r) == 1, "shadow of a scaled render target")
	for f in 0 ..< faces(r) {
		for l in first ..< r.levels {
			off, _ := shadow_off(r, f, l)
			w, h := i32(level_dim(r.w, l)), i32(level_dim(r.h, l))
			n := i32(level_bytes(fi, r.w, r.h, l))
			gl.GetTextureSubImage(r.gl, i32(l), 0, 0, i32(f), w, h, 1, fi.format, fi.type, n, x86.ptr(r.shadow + off))
		}
	}
}

// DXT mip chain of one face below level src: the source level is read back
// from GL (it may be newer than the shadow), each lower level is the 2x2 box
// of the previous decoded level, re-encoded, uploaded and mirrored into the
// shadow.
tex_filter_dxt :: proc(r: ^Res, fi: Fmt_Info, face, src: u32) {
	k := dxt_kind(r.format)
	w, h := level_dim(r.w, src), level_dim(r.h, src)
	blocks := make([]u8, level_bytes(fi, r.w, r.h, src))
	defer delete(blocks)
	gl.GetCompressedTextureSubImage(r.gl, i32(src), 0, 0, i32(face), i32(w), i32(h), 1, i32(len(blocks)), raw_data(blocks))
	cur := make([]Rgba, w * h)
	defer delete(cur)
	nxt := make([]Rgba, w * h)
	defer delete(nxt)
	dxt_decode_level(k, blocks, w, h, cur)
	for l in src + 1 ..< r.levels {
		rgba_halve(cur, w, h, nxt)
		w, h = max(1, w / 2), max(1, h / 2)
		cur, nxt = nxt, cur
		out := blocks[:level_bytes(fi, r.w, r.h, l)]
		dxt_encode_level(k, cur[:w * h], w, h, out)
		tex_upload(r, fi, face, l, raw_data(out))
		if r.shadow != 0 {
			off, _ := shadow_off(r, face, l)
			copy(([^]u8)(x86.ptr(r.shadow + off))[:len(out)], out)
		}
	}
}

// Formats D3DXLoadSurfaceFromSurface converts on the GPU: GL blits between
// normalized color storage convert per channel. Swizzled storage (L8, A8,
// A8L8) would come out with the wrong channels, so it is excluded.
blit_color_format :: proc(f: u32) -> bool {
	switch f {
	case D3DFMT_A8R8G8B8, D3DFMT_X8R8G8B8, D3DFMT_A8B8G8R8, D3DFMT_R5G6B5, D3DFMT_A1R5G5B5, D3DFMT_X1R5G5B5, D3DFMT_A4R4G4B4:
		return true
	}
	return false
}

// D3DXLoadSurfaceFromSurface(pDestSurface, pDestPalette, pDestRect,
// pSrcSurface, pSrcPalette, pSrcRect, Filter, ColorKey). One GPU blit with
// per-resource render scale. Filter NONE/POINT (1, 2) is nearest, everything
// else (LINEAR, TRIANGLE, BOX, D3DX_DEFAULT) linear. An X-format source has
// undefined alpha in GL storage; D3DX reads it as opaque, so the destination
// alpha of the rect is then cleared to 1. The destination shadow (always
// present for a D3DPOOL_SYSTEMMEM surface) is refreshed from GL so a later
// lock sees the copy.
// WHY: docs/rendering.md §1
D3DXLoadSurfaceFromSurface :: proc() {
	dobj, sobj, filter, key := arg(0), arg(3), arg(6), arg(7)
	if arg(1) != 0 || arg(4) != 0 {x86.fatal("D3DXLoadSurfaceFromSurface: palette")}
	if key != 0 {x86.fatal("D3DXLoadSurfaceFromSurface: color key %08x", key)}
	dst, src := res_of(dobj), res_of(sobj)
	if !blit_color_format(src.format) || !blit_color_format(dst.format) {
		x86.fatal("D3DXLoadSurfaceFromSurface: format %d -> %d", src.format, dst.format)
	}
	own, df, dl := surf_owner(dst)
	sown, _, sl := surf_owner(src)
	if own.locked || sown.locked {x86.fatal("D3DXLoadSurfaceFromSurface: locked surface")}
	sr := [4]i32{0, 0, i32(level_dim(src.w, sl)), i32(level_dim(src.h, sl))}
	dr := [4]i32{0, 0, i32(level_dim(dst.w, dl)), i32(level_dim(dst.h, dl))}
	if arg(5) != 0 {blob_in(arg(5), &sr, 16)}
	if arg(2) != 0 {blob_in(arg(2), &dr, 16)}
	sr *= i32(res_scale(src))
	dr *= i32(res_scale(dst))
	ms_read(sobj)
	ms_write(dobj)
	di := res_img(dobj)
	gl_blit(res_img(sobj), di, sr, dr, src.format, filter & 0xff > 2)
	if fmt_must(src.format).swz == SWZ_X && fmt_must(dst.format).swz == SWZ_ID {
		img_attach(blit_fbo[1], gl.COLOR_ATTACHMENT0, di)
		raster_lost()
		gl.Enable(gl.SCISSOR_TEST)
		gl.Scissor(dr[0], dr[1], dr[2] - dr[0], dr[3] - dr[1])
		gl.ColorMaski(0, false, false, false, true)
		one := [4]f32{0, 0, 0, 1}
		gl.ClearNamedFramebufferfv(blit_fbo[1], gl.COLOR, 0, &one[0])
		gl.ColorMaski(0, true, true, true, true) // draws set masks from render state again
		gl.NamedFramebufferTexture(blit_fbo[1], gl.COLOR_ATTACHMENT0, 0, 0)
	}
	// A system-memory surface lives in its shadow: allocate it now so the
	// next lock reads the copy, not zeros.
	if own.shadow != 0 || own.pool == D3DPOOL_SYSTEMMEM {
		fi := fmt_must(own.format)
		off, total := shadow_off(own, df, dl)
		if own.shadow == 0 {own.shadow = heap_alloc(total, true)}
		w, h := i32(level_dim(own.w, dl)), i32(level_dim(own.h, dl))
		n := i32(level_bytes(fi, own.w, own.h, dl))
		assert(res_scale(own) == 1, "shadow of a scaled render target")
		gl.GetTextureSubImage(own.gl, i32(dl), 0, 0, i32(df), w, h, 1, fi.format, fi.type, n, x86.ptr(own.shadow + off))
	}
	ret(8, D3D_OK)
}
