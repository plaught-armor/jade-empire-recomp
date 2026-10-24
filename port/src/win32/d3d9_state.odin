// IDirect3DDevice9 pipeline state: plain host copies of everything the game
// sets, with D3D9's documented defaults. The GL backend reads this at draw
// time; Get* methods hand it back unchanged.
package win32

import "../x86"

RS_MAX :: 256
TSS_STAGES :: 8
TSS_MAX :: 33
SAMPLERS :: 21 // 0..15 pixel, 16 = D3DDMAPSAMPLER (256), 17..20 = vertex (257..260)
SS_MAX :: 14
LIGHTS_MAX :: 64
VS_F_MAX :: 256
PS_F_MAX :: 32
INT_MAX :: 16
BOOL_MAX :: 16
TS_MAX :: 512 // D3DTS_WORLDMATRIX(n) = 256 + n

Viewport :: struct {
	x, y, w, h: u32,
	min_z, max_z: f32,
}

Light :: struct {
	raw:     [26]u32, // D3DLIGHT9, 104 bytes
	set:     bool,
	enabled: bool,
}

Dev_State :: struct {
	rs:          [RS_MAX]u32,
	tss:         [TSS_STAGES][TSS_MAX]u32,
	ss:          [SAMPLERS][SS_MAX]u32,
	xf:          [TS_MAX]Mat,
	viewport:    Viewport,
	scissor:     [4]i32,
	material:    [17]u32, // D3DMATERIAL9, 68 bytes
	lights:      [LIGHTS_MAX]Light,
	clip:        [6][4]f32,
	clip_status: [6]u32,
	vs:          Vs_Consts, // shader constants; draws pack the registers a shader reads (upload_consts)
	ps:          Ps_Consts,
	fvf:         u32,
	sw_vp:       u32,
	npatch:      f32,
	gamma:       [768]u16,
}

ds: Dev_State

f2u :: #force_inline proc "contextless" (v: f32) -> u32 {return transmute(u32)v}

// D3DRENDERSTATETYPE defaults (d3d9types.h; values per the D3D9 docs).
RS_DEFAULTS := [?][2]u32 {
	{7, 1}, {8, 3}, {9, 2}, {14, 1}, {16, 1}, {19, 2}, {20, 1}, {22, 3}, {23, 4}, {25, 8},
	{37, 0x3f800000}, {38, 0x3f800000}, {53, 1}, {54, 1}, {55, 1}, {56, 8},
	{58, 0xffffffff}, {59, 0xffffffff}, {60, 0xffffffff}, {136, 1}, {137, 1},
	{141, 1}, {142, 1}, {145, 1}, {146, 2}, {154, 0x3f800000}, {155, 0x3f800000},
	{158, 0x3f800000}, {161, 1}, {162, 0xffffffff}, {166, 0x43800000}, {168, 0xf},
	{171, 1}, {172, 3}, {173, 1}, {178, 0x3f800000}, {179, 0x3f800000}, {182, 0x3f800000},
	{186, 1}, {187, 1}, {188, 1}, {189, 8}, {190, 0xf}, {191, 0xf}, {192, 0xf},
	{193, 0xffffffff}, {207, 2}, {208, 1}, {209, 1},
}

// Defaults for a back buffer of w x h; called on CreateDevice and Reset.
state_reset :: proc(w, h: u32) {
	ds = {}
	consts_dirty = {true, true}
	for d in RS_DEFAULTS {
		ds.rs[d[0]] = d[1]
	}
	for s in 0 ..< u32(TSS_STAGES) {
		t := &ds.tss[s]
		t[1] = s == 0 ? 4 : 1 // COLOROP: MODULATE / DISABLE
		t[2], t[3] = 2, 1     // COLORARG1 TEXTURE, COLORARG2 CURRENT
		t[4] = s == 0 ? 2 : 1 // ALPHAOP: SELECTARG1 / DISABLE
		t[5], t[6] = 2, 1
		t[11] = s             // TEXCOORDINDEX
		t[26], t[27], t[28] = 1, 1, 1
	}
	for &s in ds.ss {
		s[1], s[2], s[3] = 1, 1, 1 // ADDRESSU/V/W WRAP
		s[5], s[6] = 1, 1          // MAG/MINFILTER POINT
		s[10] = 1                  // MAXANISOTROPY
	}
	for &m in ds.xf {
		m = MAT_IDENTITY
	}
	ds.viewport = {0, 0, w, h, 0, 1}
	ds.scissor = {0, 0, i32(w), i32(h)}
	for i in 0 ..< 256 {
		v := u16(i) * 257
		ds.gamma[i], ds.gamma[256 + i], ds.gamma[512 + i] = v, v, v
	}
}

blob_in :: proc(p: u32, dst: rawptr, n: u32) {
	copy(([^]u8)(dst)[:n], x86.mem[p:p + n])
}

blob_out :: proc(p: u32, src: rawptr, n: u32) {
	copy(x86.mem[p:p + n], ([^]u8)(src)[:n])
}

// Status-only methods.
Dev_Ok1 :: proc() {ret(1, D3D_OK)}
Dev_Ok2 :: proc() {ret(2, D3D_OK)}
Dev_Ok3 :: proc() {ret(3, D3D_OK)}
Dev_Ok4 :: proc() {ret(4, D3D_OK)}

Dev_GetAvailableTextureMem :: proc() {ret(1, 512 << 20)}

Dev_GetDirect3D :: proc() {
	x86.wr32(arg(1), d3d_obj)
	x86.wr32(d3d_obj + 4, x86.rd32(d3d_obj + 4) + 1)
	ret(2, D3D_OK)
}

Dev_GetDeviceCaps :: proc() {
	put_caps(arg(1))
	ret(2, D3D_OK)
}

Dev_GetDisplayMode :: proc() {
	w, h := desktop_size()
	put_mode(arg(2), u32(w), u32(h))
	ret(3, D3D_OK)
}

// D3DDEVICE_CREATION_PARAMETERS {Adapter, DeviceType, hFocusWindow, BehaviorFlags}.
Dev_GetCreationParameters :: proc() {
	p := arg(1)
	x86.wr32(p, 0); x86.wr32(p + 4, 1); x86.wr32(p + 8, dev_focus); x86.wr32(p + 12, dev_behavior)
	ret(2, D3D_OK)
}

Dev_SetCursorPosition :: proc() {ret(4, 0)}
Dev_ShowCursor :: proc() {ret(2, 0)}

Dev_SetGammaRamp :: proc() {
	blob_in(arg(3), &ds.gamma, size_of(ds.gamma))
	ret(4, 0)
}

Dev_GetGammaRamp :: proc() {
	blob_out(arg(2), &ds.gamma, size_of(ds.gamma))
	ret(3, 0)
}

// D3DTRANSFORMSTATETYPE: VIEW 2, PROJECTION 3, TEXTURE0..7 16..23, WORLD 256+.
xf_slot :: proc(t: u32) -> (^Mat, bool) {
	if t >= TS_MAX {
		return nil, false
	}
	return &ds.xf[t], true
}

Dev_SetTransform :: proc() {
	m, ok := xf_slot(arg(1))
	if !ok {
		ret(3, D3DERR_INVALIDCALL)
		return
	}
	m^ = rd_mat(arg(2))
	if m == &ds.xf[XF_PROJECTION] {ssao_projection(m)}
	ret(3, D3D_OK)
}

Dev_GetTransform :: proc() {
	m, ok := xf_slot(arg(1))
	if !ok {
		ret(3, D3DERR_INVALIDCALL)
		return
	}
	wr_mat(arg(2), m^)
	ret(3, D3D_OK)
}

// D3D multiplies on the left: M' = pMatrix * M.
Dev_MultiplyTransform :: proc() {
	m, ok := xf_slot(arg(1))
	if !ok {
		ret(3, D3DERR_INVALIDCALL)
		return
	}
	m^ = mat_mul(rd_mat(arg(2)), m^)
	ret(3, D3D_OK)
}

Dev_SetViewport :: proc() {
	blob_in(arg(1), &ds.viewport, size_of(Viewport))
	ssao_viewport()
	ret(2, D3D_OK)
}

Dev_GetViewport :: proc() {
	blob_out(arg(1), &ds.viewport, size_of(Viewport))
	ret(2, D3D_OK)
}

Dev_SetMaterial :: proc() {
	blob_in(arg(1), &ds.material, size_of(ds.material))
	ret(2, D3D_OK)
}

Dev_GetMaterial :: proc() {
	blob_out(arg(1), &ds.material, size_of(ds.material))
	ret(2, D3D_OK)
}

Dev_SetLight :: proc() {
	i := arg(1)
	if i >= LIGHTS_MAX {
		x86.fatal("SetLight index %d >= %d", i, LIGHTS_MAX)
	}
	blob_in(arg(2), &ds.lights[i].raw, size_of(ds.lights[i].raw))
	ds.lights[i].set = true
	ret(3, D3D_OK)
}

Dev_GetLight :: proc() {
	i := arg(1)
	if i >= LIGHTS_MAX || !ds.lights[i].set {
		ret(3, D3DERR_INVALIDCALL)
		return
	}
	blob_out(arg(2), &ds.lights[i].raw, size_of(ds.lights[i].raw))
	ret(3, D3D_OK)
}

// Enabling a light never set gives it the default directional white light.
Dev_LightEnable :: proc() {
	i := arg(1)
	if i >= LIGHTS_MAX {
		x86.fatal("LightEnable index %d >= %d", i, LIGHTS_MAX)
	}
	l := &ds.lights[i]
	if !l.set {
		l.raw = {}
		l.raw[0] = 3                                       // D3DLIGHT_DIRECTIONAL
		l.raw[1], l.raw[2], l.raw[3] = f2u(1), f2u(1), f2u(1) // Diffuse rgb
		l.raw[18] = f2u(1)                                   // Direction z
		l.set = true
	}
	l.enabled = arg(2) != 0
	ret(3, D3D_OK)
}

Dev_GetLightEnable :: proc() {
	i := arg(1)
	if i >= LIGHTS_MAX || !ds.lights[i].set {
		ret(3, D3DERR_INVALIDCALL)
		return
	}
	x86.wr32(arg(2), ds.lights[i].enabled ? 1 : 0)
	ret(3, D3D_OK)
}

Dev_SetClipPlane :: proc() {
	i := arg(1)
	if i >= 6 {
		ret(3, D3DERR_INVALIDCALL)
		return
	}
	blob_in(arg(2), &ds.clip[i], 16)
	ret(3, D3D_OK)
}

Dev_GetClipPlane :: proc() {
	i := arg(1)
	if i >= 6 {
		ret(3, D3DERR_INVALIDCALL)
		return
	}
	blob_out(arg(2), &ds.clip[i], 16)
	ret(3, D3D_OK)
}

Dev_SetRenderState :: proc() {
	s := arg(1)
	if s < RS_MAX {
		ds.rs[s] = arg(2)
	}
	ret(3, D3D_OK)
}

Dev_GetRenderState :: proc() {
	s := arg(1)
	x86.wr32(arg(2), s < RS_MAX ? ds.rs[s] : 0)
	ret(3, D3D_OK)
}

Dev_SetClipStatus :: proc() {
	blob_in(arg(1), &ds.clip_status, 8)
	ret(2, D3D_OK)
}

Dev_GetClipStatus :: proc() {
	blob_out(arg(1), &ds.clip_status, 8)
	ret(2, D3D_OK)
}

Dev_GetTextureStageState :: proc() {
	st, t := arg(1), arg(2)
	x86.wr32(arg(3), st < TSS_STAGES && t < TSS_MAX ? ds.tss[st][t] : 0)
	ret(4, D3D_OK)
}

Dev_SetTextureStageState :: proc() {
	st, t := arg(1), arg(2)
	if st < TSS_STAGES && t < TSS_MAX {
		ds.tss[st][t] = arg(3)
	}
	ret(4, D3D_OK)
}

// Sampler numbers: 0..15, D3DDMAPSAMPLER 256, D3DVERTEXTEXTURESAMPLER0..3 257..260.
sampler_slot :: proc(s: u32) -> (u32, bool) {
	switch {
	case s < 16: return s, true
	case s >= 256 && s <= 260: return s - 240, true
	}
	return 0, false
}

Dev_GetSamplerState :: proc() {
	s, ok := sampler_slot(arg(1))
	t := arg(2)
	x86.wr32(arg(3), ok && t < SS_MAX ? ds.ss[s][t] : 0)
	ret(4, ok ? D3D_OK : D3DERR_INVALIDCALL)
}

Dev_SetSamplerState :: proc() {
	s, ok := sampler_slot(arg(1))
	t := arg(2)
	if ok && t < SS_MAX {
		ds.ss[s][t] = arg(3)
	}
	ret(4, ok ? D3D_OK : D3DERR_INVALIDCALL)
}

Dev_ValidateDevice :: proc() {
	x86.wr32(arg(1), 1)
	ret(2, D3D_OK)
}

// RECT {left, top, right, bottom}.
Dev_SetScissorRect :: proc() {
	blob_in(arg(1), &ds.scissor, 16)
	ret(2, D3D_OK)
}

Dev_GetScissorRect :: proc() {
	blob_out(arg(1), &ds.scissor, 16)
	ret(2, D3D_OK)
}

Dev_SetSoftwareVertexProcessing :: proc() {
	ds.sw_vp = arg(1)
	ret(2, D3D_OK)
}

Dev_GetSoftwareVertexProcessing :: proc() {ret(1, ds.sw_vp)}

Dev_SetNPatchMode :: proc() {
	ds.npatch = transmute(f32)arg(1)
	ret(2, D3D_OK)
}

Dev_GetNPatchMode :: proc() {
	x86.fpush(f64(ds.npatch))
	ret(1, 0)
}

Dev_SetFVF :: proc() {
	ds.fvf = arg(1)
	bind.decl, bind.decl_obj = ds.fvf == 0 ? 0 : fvf_decl(ds.fvf) + 1, 0
	ret(2, D3D_OK)
}

Dev_GetFVF :: proc() {
	x86.wr32(arg(1), ds.fvf)
	ret(2, D3D_OK)
}

Const_Kind :: enum u8 {F, I, B}

// Float constant registers written so far per bank (vertex, pixel): the
// highest + 1. Every register at or past it is still 0.
const_hw: [2]u32

// Shader constants: (this, StartRegister, pData, Count). F and I registers
// are 4-vectors; a B register is one BOOL, kept in the first lane of its
// 16-byte slot. u: the bank (0 vertex, 1 pixel); slots: the register file
// inside ds.vs or ds.ps. Shaders read only F registers (DEFI and DEFB are
// unsupported); I and B are kept for Get.
// WHY: docs/rendering.md §7
const_io :: proc(u: int, slots: rawptr, regs: u32, kind: Const_Kind, set: bool) {
	bools := kind == .B
	start, p, n := arg(1), arg(2), arg(3)
	if start > regs || n > regs - start {
		ret(4, D3DERR_INVALIDCALL)
		return
	}
	at := uintptr(slots) + uintptr(start * 16)
	for r in 0 ..< (bools ? n : 1) {
		g, h := bools ? p + r * 4 : p, rawptr(at + uintptr(r * 16))
		k := bools ? 4 : n * 16
		if set {blob_in(g, h, k)} else {blob_out(g, h, k)}
	}
	if set && kind == .F {
		consts_dirty[u] = true
		const_hw[u] = max(const_hw[u], start + n)
	}
	ret(4, D3D_OK)
}

Dev_SetVertexShaderConstantF :: proc() {const_io(0, &ds.vs.f, VS_F_MAX, .F, true)}
Dev_GetVertexShaderConstantF :: proc() {const_io(0, &ds.vs.f, VS_F_MAX, .F, false)}
Dev_SetVertexShaderConstantI :: proc() {const_io(0, &ds.vs.i, INT_MAX, .I, true)}
Dev_GetVertexShaderConstantI :: proc() {const_io(0, &ds.vs.i, INT_MAX, .I, false)}
Dev_SetVertexShaderConstantB :: proc() {const_io(0, &ds.vs.b, BOOL_MAX, .B, true)}
Dev_GetVertexShaderConstantB :: proc() {const_io(0, &ds.vs.b, BOOL_MAX, .B, false)}
Dev_SetPixelShaderConstantF :: proc() {const_io(1, &ds.ps.f, PS_F_MAX, .F, true)}
Dev_GetPixelShaderConstantF :: proc() {const_io(1, &ds.ps.f, PS_F_MAX, .F, false)}
Dev_SetPixelShaderConstantI :: proc() {const_io(1, &ds.ps.i, INT_MAX, .I, true)}
Dev_GetPixelShaderConstantI :: proc() {const_io(1, &ds.ps.i, INT_MAX, .I, false)}
Dev_SetPixelShaderConstantB :: proc() {const_io(1, &ds.ps.b, BOOL_MAX, .B, true)}
Dev_GetPixelShaderConstantB :: proc() {const_io(1, &ds.ps.b, BOOL_MAX, .B, false)}
