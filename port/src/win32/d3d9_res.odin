// Direct3D 9 resources: textures, surfaces, vertex and index buffers. Each is
// a COM object whose host id indexes `res`. Lockable data lives in a guest
// "shadow" block (Lock returns a pointer into it) and is uploaded to the GL
// object on Unlock.
//
// Orientation: image row 0 (the top in D3D) is GL row 0 everywhere, both for
// uploads and for rendering (ClipControl UPPER_LEFT puts NDC y = +1 at row 0;
// see d3d9_draw.odin), so D3D texture coordinates sample GL textures
// unchanged and only Present flips.
package win32

import gl "vendor:OpenGL"
import "../x86"

Res_Kind :: enum u32 {Free, Texture, Cube, Surface, VB, IB}

// D3DRESOURCETYPE per kind.
RES_TYPE := [Res_Kind]u32 {.Free = 0, .Texture = 3, .Cube = 5, .Surface = 1, .VB = 6, .IB = 7}

D3DPOOL_DEFAULT :: 0
D3DPOOL_SYSTEMMEM :: 2
D3DUSAGE_AUTOGENMIPMAP :: 0x400
D3DLOCK_READONLY :: 0x10
D3DERR_NOTFOUND :: 0x88760866

Res :: struct {
	kind:     Res_Kind,
	obj:      u32, // guest COM object
	gl:       u32, // texture or buffer name
	format:   u32, // D3DFORMAT (or FVF for vertex buffers)
	usage:    u32,
	pool:     u32,
	w, h:     u32, // texels; buffers: w = byte size
	levels:   u32,
	shadow:   u32, // guest copy of all levels/faces, 0 until first lock
	parent:   u32, // surfaces of a texture: the texture's res index + 1
	level:    u32,
	face:     u32,
	surfs:    [dynamic]u32, // texture: surface objects per face*levels + level
	lock_lo:  u32, // buffers: dirty byte range since the last upload
	lock_hi:  u32,
	lock_flags: u32, // D3DLOCK_* of the open lock
	locked:   bool,
	lod:      u32,
	scale:    u32, // render targets, depth surfaces: GL storage is scale x w/h; 0 = 1
	host_fed: bool, // GL storage written by the host (Bink upscale); unlocks upload nothing
}

res: [dynamic]Res
res_free: [dynamic]u32

res_new :: proc(kind: Res_Kind, vt: u32) -> (u32, ^Res) {
	id: u32
	if len(res_free) > 0 {
		id = pop(&res_free)
	} else {
		id = u32(len(res))
		append(&res, Res{})
	}
	r := &res[id]
	r^ = Res{kind = kind}
	r.obj = com_new(vt, id)
	return id, r
}

res_of :: proc(this: u32) -> ^Res {
	id := com_id(this)
	if id >= u32(len(res)) || res[id].kind == .Free || res[id].obj != this {
		x86.fatal("bad d3d9 resource object %08x", this)
	}
	return &res[id]
}

res_destroy :: proc(id: u32) {
	r := &res[id]
	res_unbind(r.obj)
	switch r.kind {
	case .Texture, .Cube, .Surface:
		if r.parent == 0 && r.gl != 0 {gl.DeleteTextures(1, &r.gl)}
	case .VB, .IB:
		gl.DeleteBuffers(1, &r.gl)
	case .Free:
		x86.fatal("double destroy of d3d9 resource %d", id)
	}
	for s in r.surfs {
		if s != 0 {res_destroy(com_id(s))}
	}
	delete(r.surfs)
	if r.shadow != 0 {heap_free(r.shadow)}
	heap_free(r.obj)
	r^ = Res{}
	append(&res_free, id)
}

// Texture surfaces live as long as their texture: their count only tracks
// the game's references, and the texture's Release frees them.
Res_Release :: proc() {
	this := arg(0)
	r := res_of(this)
	n := x86.rd32(this + 4)
	if n == 0 {
		x86.fatal("Release(%08x) of a dead resource", this)
	}
	n -= 1
	x86.wr32(this + 4, n)
	if n == 0 && r.parent == 0 {
		res_destroy(com_id(this))
	}
	ret(1, n)
}

// IDirect3DResource9 methods shared by every kind.
Res_GetDevice :: proc() {
	x86.wr32(arg(1), device_obj)
	x86.wr32(device_obj + 4, x86.rd32(device_obj + 4) + 1)
	ret(2, D3D_OK)
}

Res_SetPrivateData :: proc() {ret(5, D3D_OK)}
Res_GetPrivateData :: proc() {ret(4, D3DERR_NOTFOUND)}
Res_FreePrivateData :: proc() {ret(2, D3D_OK)}
Res_SetPriority :: proc() {ret(2, 0)}
Res_GetPriority :: proc() {ret(1, 0)}
Res_PreLoad :: proc() {ret(1, 0)}
Res_GetType :: proc() {ret(1, RES_TYPE[res_of(arg(0)).kind])}

RES_METHODS := [?]Com_Method {
	{"QueryInterface", com_query}, {"AddRef", com_addref}, {"Release", Res_Release},
	{"GetDevice", Res_GetDevice}, {"SetPrivateData", Res_SetPrivateData},
	{"GetPrivateData", Res_GetPrivateData}, {"FreePrivateData", Res_FreePrivateData},
	{"SetPriority", Res_SetPriority}, {"GetPriority", Res_GetPriority},
	{"PreLoad", Res_PreLoad}, {"GetType", Res_GetType},
}

// Vtable = the shared IUnknown/IDirect3DResource9 slots then the interface's own.
res_vtable :: proc(iface: string, own: []Com_Method) -> u32 {
	if vt, ok := com_vtables[iface]; ok {
		return vt
	}
	all := make([]Com_Method, len(RES_METHODS) + len(own))
	copy(all, RES_METHODS[:])
	copy(all[len(RES_METHODS):], own)
	return com_vtable("d3d9.dll", iface, all)
}

// D3DSURFACE_DESC {Format, Type, Usage, Pool, MultiSampleType, MultiSampleQuality, Width, Height}.
put_surface_desc :: proc(p: u32, r: ^Res, w, h: u32) {
	x86.mem_zero(p, 32)
	x86.wr32(p, r.format)
	x86.wr32(p + 4, RES_TYPE[.Surface])
	x86.wr32(p + 8, r.usage)
	x86.wr32(p + 12, r.pool)
	x86.wr32(p + 24, w)
	x86.wr32(p + 28, h)
}
