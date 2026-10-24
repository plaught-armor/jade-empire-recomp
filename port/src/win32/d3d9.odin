// Direct3D 9 entry: IDirect3D9 reports one HAL adapter with shader model 2.0
// caps, the desktop's 32-bit modes and the formats the GL backend can hold.
package win32

import "../x86"

D3D9 := [?]Hle_Entry {
	{"d3d9.dll!Direct3DCreate9", Direct3DCreate9},
}

D3D_METHODS := [?]Com_Method {
	{"QueryInterface", com_query}, {"AddRef", com_addref}, {"Release", com_release},
	{"RegisterSoftwareDevice", nil}, {"GetAdapterCount", D3D_GetAdapterCount},
	{"GetAdapterIdentifier", D3D_GetAdapterIdentifier}, {"GetAdapterModeCount", D3D_GetAdapterModeCount},
	{"EnumAdapterModes", D3D_EnumAdapterModes}, {"GetAdapterDisplayMode", D3D_GetAdapterDisplayMode},
	{"CheckDeviceType", D3D_CheckDeviceType}, {"CheckDeviceFormat", D3D_CheckDeviceFormat},
	{"CheckDeviceMultiSampleType", D3D_CheckDeviceMultiSampleType},
	{"CheckDepthStencilMatch", D3D_CheckDepthStencilMatch},
	{"CheckDeviceFormatConversion", D3D_CheckDeviceFormatConversion},
	{"GetDeviceCaps", D3D_GetDeviceCaps}, {"GetAdapterMonitor", D3D_GetAdapterMonitor},
	{"CreateDevice", D3D_CreateDevice},
}

D3D_OK :: 0
D3DERR_NOTAVAILABLE :: 0x8876086a
D3DERR_INVALIDCALL :: 0x8876086c

// D3DFORMAT values the backend supports.
D3DFMT_A8R8G8B8 :: 21
D3DFMT_X8R8G8B8 :: 22
D3DFMT_R5G6B5 :: 23
D3DFMT_X1R5G5B5 :: 24
D3DFMT_A1R5G5B5 :: 25
D3DFMT_A4R4G4B4 :: 26
D3DFMT_A8 :: 28
D3DFMT_A8B8G8R8 :: 32
D3DFMT_L8 :: 50
D3DFMT_A8L8 :: 51
D3DFMT_V8U8 :: 60
D3DFMT_D24S8 :: 75
D3DFMT_D24X8 :: 77
D3DFMT_D16 :: 80
D3DFMT_INDEX16 :: 101
D3DFMT_INDEX32 :: 102
D3DFMT_R16F :: 111
D3DFMT_G16R16F :: 112
D3DFMT_A16B16G16R16F :: 113
D3DFMT_R32F :: 114
D3DFMT_A32B32G32R32F :: 116
D3DFMT_UNKNOWN :: 0
D3DFMT_DXT1 :: 0x31545844
D3DFMT_DXT2 :: 0x32545844
D3DFMT_DXT3 :: 0x33545844
D3DFMT_DXT4 :: 0x34545844
D3DFMT_DXT5 :: 0x35545844

D3DUSAGE_RENDERTARGET :: 0x1
D3DUSAGE_DEPTHSTENCIL :: 0x2

fmt_supported :: proc(f: u32, usage: u32) -> bool {
	switch f {
	case D3DFMT_D24S8, D3DFMT_D24X8, D3DFMT_D16:
		return usage & D3DUSAGE_RENDERTARGET == 0
	case D3DFMT_A8R8G8B8, D3DFMT_X8R8G8B8, D3DFMT_A8B8G8R8, D3DFMT_R5G6B5, D3DFMT_A16B16G16R16F,
	     D3DFMT_R32F, D3DFMT_R16F, D3DFMT_G16R16F, D3DFMT_A32B32G32R32F:
		return usage & D3DUSAGE_DEPTHSTENCIL == 0
	case D3DFMT_X1R5G5B5, D3DFMT_A1R5G5B5, D3DFMT_A4R4G4B4, D3DFMT_A8, D3DFMT_L8, D3DFMT_A8L8,
	     D3DFMT_V8U8, D3DFMT_DXT1, D3DFMT_DXT2, D3DFMT_DXT3, D3DFMT_DXT4, D3DFMT_DXT5:
		return usage & (D3DUSAGE_RENDERTARGET | D3DUSAGE_DEPTHSTENCIL) == 0
	}
	return false
}

d3d_obj: u32

Direct3DCreate9 :: proc() {
	vt := com_vtable("d3d9.dll", "IDirect3D9", D3D_METHODS[:])
	d3d_obj = com_new(vt, 0)
	ret(1, d3d_obj)
}

D3D_GetAdapterCount :: proc() {ret(1, 1)}

// D3DADAPTER_IDENTIFIER9: Driver[512], Description[512], DeviceName[32],
// DriverVersion u64 @1056, VendorId @1064, DeviceId @1068, SubSysId @1072,
// Revision @1076, DeviceIdentifier GUID @1080, WHQLLevel @1096.
D3D_GetAdapterIdentifier :: proc() {
	p := arg(3)
	x86.mem_zero(p, 1100)
	put_str(p, 512, "nv4_disp.dll")
	put_str(p + 512, 512, "NVIDIA GeForce 7900 GTX")
	put_str(p + 1024, 32, `\\.\DISPLAY1`)
	x86.wr64(p + 1056, 0x0006000e000b1e20) // 6.14.11.7712
	x86.wr32(p + 1064, 0x10de)
	x86.wr32(p + 1068, 0x0290)
	x86.wr32(p + 1080, 0xd7b71e3e)
	x86.wr32(p + 1096, 1)
	ret(4, D3D_OK)
}

// Modes from user32's list that fit the desktop.
d3d_mode :: proc(n: u32) -> (w, h: u32, ok: bool) {
	dw, dh := desktop_size()
	k: u32 = 0
	for m in MODES {
		if m[0] <= u32(dw) && m[1] <= u32(dh) {
			if k == n {
				return m[0], m[1], true
			}
			k += 1
		}
	}
	return 0, 0, false
}

D3D_GetAdapterModeCount :: proc() {
	if arg(2) != D3DFMT_X8R8G8B8 {
		ret(3, 0)
		return
	}
	n: u32 = 0
	for {
		if _, _, ok := d3d_mode(n); !ok {break}
		n += 1
	}
	ret(3, n)
}

// D3DDISPLAYMODE: Width, Height, RefreshRate, Format.
put_mode :: proc(p, w, h: u32) {
	x86.wr32(p, w)
	x86.wr32(p + 4, h)
	x86.wr32(p + 8, 60)
	x86.wr32(p + 12, D3DFMT_X8R8G8B8)
}

D3D_EnumAdapterModes :: proc() {
	w, h, ok := d3d_mode(arg(3))
	if arg(2) != D3DFMT_X8R8G8B8 || !ok {
		ret(5, D3DERR_INVALIDCALL)
		return
	}
	put_mode(arg(4), w, h)
	ret(5, D3D_OK)
}

D3D_GetAdapterDisplayMode :: proc() {
	w, h := desktop_size()
	put_mode(arg(2), u32(w), u32(h))
	ret(3, D3D_OK)
}

D3D_CheckDeviceType :: proc() {
	bb := arg(4)
	ok := bb == D3DFMT_X8R8G8B8 || bb == D3DFMT_A8R8G8B8 || bb == 0
	ret(6, ok ? D3D_OK : D3DERR_NOTAVAILABLE)
}

D3D_CheckDeviceFormat :: proc() {
	ret(7, fmt_supported(arg(6), arg(4)) ? D3D_OK : D3DERR_NOTAVAILABLE)
}

// None, 2, 4 and 8 samples: the game's Anti-aliasing row offers these, and
// the type it picks sets the host MSAA (d3d9_msaa.odin). WHY: docs/rendering.md §8
D3D_CheckDeviceMultiSampleType :: proc() {
	q := arg(6)
	if q != 0 {
		x86.wr32(q, 1)
	}
	t := arg(5)
	ret(7, t == 0 || t == 2 || t == 4 || t == 8 ? D3D_OK : D3DERR_NOTAVAILABLE)
}

D3D_CheckDepthStencilMatch :: proc() {ret(6, D3D_OK)}

D3D_CheckDeviceFormatConversion :: proc() {
	ret(5, fmt_supported(arg(3), 0) && fmt_supported(arg(4), D3DUSAGE_RENDERTARGET) ? D3D_OK : D3DERR_NOTAVAILABLE)
}

D3D_GetAdapterMonitor :: proc() {ret(2, 0x00040040)}

D3D_GetDeviceCaps :: proc() {
	put_caps(arg(3))
	ret(4, D3D_OK)
}

// D3DCAPS9 (304 bytes) for an SM 2.0 HAL device; bit meanings in d3d9caps.h.
put_caps :: proc(p: u32) {
	f :: proc(v: f32) -> u32 {return transmute(u32)v}
	x86.mem_zero(p, 304)
	vals := [?][2]u32 {
		{0, 1},              // DeviceType HAL
		{8, 0x00020000},     // Caps: READ_SCANLINE
		{12, 0x60020000},    // Caps2: CANAUTOGENMIPMAP | DYNAMICTEXTURES | FULLSCREENGAMMA
		{16, 0x000003a0},    // Caps3: ALPHA_FULLSCREEN_FLIP_OR_DISCARD | LINEAR_TO_SRGB | COPY_TO_*
		{20, 0x80000001},    // PresentationIntervals: IMMEDIATE | ONE
		{24, 0x00000001},    // CursorCaps: COLOR
		{28, 0x000bbff0},    // DevCaps: HW T&L, video-memory execution/textures, DRAWPRIMITIVES2EX
		{32, 0x001fcef2},    // PrimitiveMiscCaps
		{36, 0x07732191},    // RasterCaps
		{40, 0xff},          // ZCmpCaps
		{44, 0x3fff},        // SrcBlendCaps
		{48, 0x3fff},        // DestBlendCaps
		{52, 0xff},          // AlphaCmpCaps
		{56, 0x00084208},    // ShadeCaps
		{60, 0x0001ec45},    // TextureCaps: no POW2/SQUAREONLY restrictions
		{64, 0x07030700},    // TextureFilterCaps
		{68, 0x07030700},    // CubeTextureFilterCaps
		{72, 0x03030300},    // VolumeTextureFilterCaps
		{76, 0x3f},          // TextureAddressCaps
		{80, 0x3f},          // VolumeTextureAddressCaps
		{84, 0x1f},          // LineCaps
		{88, 8192}, {92, 8192}, {96, 2048}, {100, 32768}, {104, 8192}, {108, 16},
		{112, f(1e10)},      // MaxVertexW
		{116, f(-32768)}, {120, f(-32768)}, {124, f(32768)}, {128, f(32768)},
		{136, 0x1ff},        // StencilCaps incl. TWOSIDED
		{140, 0x00100008},   // FVFCaps: 8 texcoords, PSIZE
		{144, 0x03ffffff},   // TextureOpCaps
		{148, 8}, {152, 8},  // MaxTextureBlendStages, MaxSimultaneousTextures
		{156, 0x17b},        // VertexProcessingCaps
		{160, 8}, {164, 6}, {168, 4}, // lights, clip planes, blend matrices
		{176, f(256)},       // MaxPointSize
		{180, 0x000fffff}, {184, 0x00ffffff}, {188, 16}, {192, 255},
		{196, 0xfffe0200}, {200, 256}, // vs_2_0, 256 constants
		{204, 0xffff0200}, {208, f(8)}, // ps_2_0, PixelShader1xMaxValue
		{212, 0x51},         // DevCaps2: STREAMOFFSET | CAN_STRETCHRECT_FROM_TEXTURES | ...
		{232, 1},            // NumberOfAdaptersInGroup
		{236, 0x33f},        // DeclTypes: UBYTE4(N), SHORT2N/4N, USHORT2N/4N, FLOAT16_2/4
		{240, 4},            // NumSimultaneousRTs
		{244, 0x03000300},   // StretchRectFilterCaps
		{248, 1}, {252, 24}, {256, 32}, {260, 4},           // VS20Caps
		{264, 0x1f}, {268, 24}, {272, 32}, {276, 4}, {280, 512}, // PS20Caps
		{288, 65535}, {292, 65535},
	}
	for v in vals {
		x86.wr32(p + v[0], v[1])
	}
}

D3DCREATE_FPU_PRESERVE :: 0x2

D3D_CreateDevice :: proc() {
	pp, out := arg(5), arg(6)
	dev_focus, dev_behavior = arg(3), arg(4)
	// Without FPU_PRESERVE, D3D9 switches the x87 to single precision, round to
	// nearest, exceptions masked; game float code depends on the f32 results.
	if dev_behavior & D3DCREATE_FPU_PRESERVE == 0 {
		x86.fldcw((x86.cpu.fpu.cw & ~u16(0xf3f)) | 0x3f)
	}
	r := device_create(pp)
	if r != D3D_OK {
		x86.wr32(out, 0)
		ret(7, r)
		return
	}
	x86.wr32(out, device_obj)
	ret(7, D3D_OK)
}
