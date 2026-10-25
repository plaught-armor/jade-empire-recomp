// IDirect3DDevice9: the single device, rendering through an OpenGL 4.6 core
// context on the user32 window. Methods are bound by vtable position; those
// left nil fail by name when the game first calls them.
package win32

import "core:fmt"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"
import "../x86"

DEV9_METHODS := [?]Com_Method {
	{"QueryInterface", com_query}, {"AddRef", com_addref}, {"Release", com_release},
	{"TestCooperativeLevel", Dev_Ok1}, {"GetAvailableTextureMem", Dev_GetAvailableTextureMem}, {"EvictManagedResources", Dev_Ok1},
	{"GetDirect3D", Dev_GetDirect3D}, {"GetDeviceCaps", Dev_GetDeviceCaps}, {"GetDisplayMode", Dev_GetDisplayMode},
	{"GetCreationParameters", Dev_GetCreationParameters}, {"SetCursorProperties", Dev_Ok4}, {"SetCursorPosition", Dev_SetCursorPosition},
	{"ShowCursor", Dev_ShowCursor}, {"CreateAdditionalSwapChain", nil}, {"GetSwapChain", nil},
	{"GetNumberOfSwapChains", nil}, {"Reset", Dev_Reset}, {"Present", Dev_Present},
	{"GetBackBuffer", Dev_GetBackBuffer}, {"GetRasterStatus", nil}, {"SetDialogBoxMode", Dev_Ok2},
	{"SetGammaRamp", Dev_SetGammaRamp}, {"GetGammaRamp", Dev_GetGammaRamp}, {"CreateTexture", Dev_CreateTexture},
	{"CreateVolumeTexture", nil}, {"CreateCubeTexture", Dev_CreateCubeTexture}, {"CreateVertexBuffer", Dev_CreateVertexBuffer},
	{"CreateIndexBuffer", Dev_CreateIndexBuffer}, {"CreateRenderTarget", Dev_CreateRenderTarget}, {"CreateDepthStencilSurface", Dev_CreateDepthStencilSurface},
	{"UpdateSurface", nil}, {"UpdateTexture", nil}, {"GetRenderTargetData", nil},
	{"GetFrontBufferData", nil}, {"StretchRect", Dev_StretchRect}, {"ColorFill", nil},
	{"CreateOffscreenPlainSurface", Dev_CreateOffscreenPlainSurface}, {"SetRenderTarget", Dev_SetRenderTarget}, {"GetRenderTarget", Dev_GetRenderTarget},
	{"SetDepthStencilSurface", Dev_SetDepthStencilSurface}, {"GetDepthStencilSurface", Dev_GetDepthStencilSurface}, {"BeginScene", Dev_Ok1},
	{"EndScene", Dev_Ok1}, {"Clear", Dev_Clear}, {"SetTransform", Dev_SetTransform},
	{"GetTransform", Dev_GetTransform}, {"MultiplyTransform", Dev_MultiplyTransform}, {"SetViewport", Dev_SetViewport},
	{"GetViewport", Dev_GetViewport}, {"SetMaterial", Dev_SetMaterial}, {"GetMaterial", Dev_GetMaterial},
	{"SetLight", Dev_SetLight}, {"GetLight", Dev_GetLight}, {"LightEnable", Dev_LightEnable},
	{"GetLightEnable", Dev_GetLightEnable}, {"SetClipPlane", Dev_SetClipPlane}, {"GetClipPlane", Dev_GetClipPlane},
	{"SetRenderState", Dev_SetRenderState}, {"GetRenderState", Dev_GetRenderState}, {"CreateStateBlock", nil},
	{"BeginStateBlock", nil}, {"EndStateBlock", nil}, {"SetClipStatus", Dev_SetClipStatus},
	{"GetClipStatus", Dev_GetClipStatus}, {"GetTexture", Dev_GetTexture}, {"SetTexture", Dev_SetTexture},
	{"GetTextureStageState", Dev_GetTextureStageState}, {"SetTextureStageState", Dev_SetTextureStageState}, {"GetSamplerState", Dev_GetSamplerState},
	{"SetSamplerState", Dev_SetSamplerState}, {"ValidateDevice", Dev_ValidateDevice}, {"SetPaletteEntries", nil},
	{"GetPaletteEntries", nil}, {"SetCurrentTexturePalette", Dev_Ok2}, {"GetCurrentTexturePalette", nil},
	{"SetScissorRect", Dev_SetScissorRect}, {"GetScissorRect", Dev_GetScissorRect}, {"SetSoftwareVertexProcessing", Dev_SetSoftwareVertexProcessing},
	{"GetSoftwareVertexProcessing", Dev_GetSoftwareVertexProcessing}, {"SetNPatchMode", Dev_SetNPatchMode}, {"GetNPatchMode", Dev_GetNPatchMode},
	{"DrawPrimitive", Dev_DrawPrimitive}, {"DrawIndexedPrimitive", Dev_DrawIndexedPrimitive}, {"DrawPrimitiveUP", Dev_DrawPrimitiveUP},
	{"DrawIndexedPrimitiveUP", Dev_DrawIndexedPrimitiveUP}, {"ProcessVertices", nil}, {"CreateVertexDeclaration", Dev_CreateVertexDeclaration},
	{"SetVertexDeclaration", Dev_SetVertexDeclaration}, {"GetVertexDeclaration", Dev_GetVertexDeclaration}, {"SetFVF", Dev_SetFVF},
	{"GetFVF", Dev_GetFVF}, {"CreateVertexShader", Dev_CreateVertexShader}, {"SetVertexShader", Dev_SetVertexShader},
	{"GetVertexShader", Dev_GetVertexShader}, {"SetVertexShaderConstantF", Dev_SetVertexShaderConstantF}, {"GetVertexShaderConstantF", Dev_GetVertexShaderConstantF},
	{"SetVertexShaderConstantI", Dev_SetVertexShaderConstantI}, {"GetVertexShaderConstantI", Dev_GetVertexShaderConstantI}, {"SetVertexShaderConstantB", Dev_SetVertexShaderConstantB},
	{"GetVertexShaderConstantB", Dev_GetVertexShaderConstantB}, {"SetStreamSource", Dev_SetStreamSource}, {"GetStreamSource", Dev_GetStreamSource},
	{"SetStreamSourceFreq", Dev_SetStreamSourceFreq}, {"GetStreamSourceFreq", Dev_GetStreamSourceFreq}, {"SetIndices", Dev_SetIndices},
	{"GetIndices", Dev_GetIndices}, {"CreatePixelShader", Dev_CreatePixelShader}, {"SetPixelShader", Dev_SetPixelShader},
	{"GetPixelShader", Dev_GetPixelShader}, {"SetPixelShaderConstantF", Dev_SetPixelShaderConstantF}, {"GetPixelShaderConstantF", Dev_GetPixelShaderConstantF},
	{"SetPixelShaderConstantI", Dev_SetPixelShaderConstantI}, {"GetPixelShaderConstantI", Dev_GetPixelShaderConstantI}, {"SetPixelShaderConstantB", Dev_SetPixelShaderConstantB},
	{"GetPixelShaderConstantB", Dev_GetPixelShaderConstantB}, {"DrawRectPatch", nil}, {"DrawTriPatch", nil},
	{"DeletePatch", nil}, {"CreateQuery", nil},
}

#assert(len(DEV9_METHODS) == 119)

// D3DPRESENT_PARAMETERS as the game last set them.
Present_Params :: struct {
	width, height, format, count: u32,
	ms_type, ms_quality, swap_effect, hwnd: u32,
	windowed, auto_depth, depth_format, flags: u32,
	refresh, interval: u32,
}

device_obj: u32
dev_focus, dev_behavior: u32
gl_ctx: sdl.GLContext
pparams: Present_Params

D3DPRESENT_INTERVAL_IMMEDIATE :: 0x80000000

read_pparams :: proc(pp: u32) -> (p: Present_Params) {
	v := (^[14]u32)(&p)
	for i in 0 ..< u32(14) {
		v[i] = x86.rd32(pp + i * 4)
	}
	return
}

// JE_SCALE: render-target scale, 0 = auto. Auto renders at the smallest
// integer multiple that covers the display height (supersampled when the
// window is smaller); the window takes the largest integer multiple that fits
// the usable display. WHY: docs/rendering.md §1
rt_scale_req: u32
RT_SCALE_AUTO_MAX :: 4
RT_SCALE_MAX :: 8

scales_pick :: proc(w, h: u32) {
	full, usable := sdl.Rect{0, 0, i32(w), i32(h)}, sdl.Rect{0, 0, i32(w), i32(h)}
	if d := sdl.GetDisplayForWindow(window); d != 0 {
		_ = sdl.GetDisplayBounds(d, &full)
		_ = sdl.GetDisplayUsableBounds(d, &usable)
	}
	wnd_scale = max(1, min(usable.w / i32(w), usable.h / i32(h)))
	auto := clamp((u32(full.h) + h - 1) / h, 1, RT_SCALE_AUTO_MAX)
	rt_scale = rt_scale_req != 0 ? min(rt_scale_req, RT_SCALE_MAX) : auto
	fmt.eprintf("d3d9: %dx%d back buffer, render scale %d, window scale %d\n", w, h, rt_scale, wnd_scale)
}

// Creates the GL context on first use, then (re)applies present params:
// the window takes the back buffer size, zero sizes take the window's.
Dev_Reset :: proc() {ret(2, device_create(arg(1)))}

device_create :: proc(pp: u32) -> u32 {
	if window == nil {
		x86.fatal("CreateDevice before CreateWindowExA")
	}
	p := read_pparams(pp)
	if p.width == 0 {p.width = u32(wnd_w)}
	if p.height == 0 {p.height = u32(wnd_h)}
	if p.format == 0 {p.format = D3DFMT_X8R8G8B8}
	if p.count == 0 {p.count = 1}
	x86.wr32(pp, p.width); x86.wr32(pp + 4, p.height); x86.wr32(pp + 8, p.format); x86.wr32(pp + 12, p.count)
	pparams = p
	scales_pick(p.width, p.height)
	resize(i32(p.width), i32(p.height))
	state_reset(p.width, p.height)
	if gl_ctx == nil {
		_ = sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 4)
		_ = sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 6)
		_ = sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, i32(transmute(u32)sdl.GL_CONTEXT_PROFILE_CORE))
		_ = sdl.GL_SetAttribute(.DOUBLEBUFFER, 1)
		gl_ctx = sdl.GL_CreateContext(window)
		if gl_ctx == nil {
			x86.fatal("SDL_GL_CreateContext: %s", sdl.GetError())
		}
		gl.load_up_to(4, 6, sdl.gl_set_proc_address)
		fmt.eprintf("d3d9: GL %s on %s\n", gl.GetString(gl.VERSION), gl.GetString(gl.RENDERER))
		vt := com_vtable("d3d9.dll", "IDirect3DDevice9", DEV9_METHODS[:])
		device_obj = com_new(vt, 0)
		frame_init()
	}
	frame_reset(p)
	fullscreen_start()
	swap_vsync = p.interval != D3DPRESENT_INTERVAL_IMMEDIATE
	swap_apply()
	return D3D_OK
}

// The game's present interval asks for vsync.
swap_vsync: bool

// Vsync as the game asked, off while lock_fast.
swap_apply :: proc() {
	if gl_ctx == nil {return}
	_ = sdl.GL_SetSwapInterval(swap_vsync && !lock_fast ? 1 : 0)
}
