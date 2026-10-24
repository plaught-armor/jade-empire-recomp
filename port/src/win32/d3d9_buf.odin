// Vertex and index buffers: a guest shadow the game locks and writes, mirrored
// into a GL buffer at draw time over the dirty bytes the draw reads.
// WHY: docs/rendering.md §6
package win32

import gl "vendor:OpenGL"
import "../x86"

D3DFMT_VERTEXDATA :: 100
D3DUSAGE_DYNAMIC :: 0x200

BUF_OWN := [?]Com_Method {{"Lock", Buf_Lock}, {"Unlock", Buf_Unlock}, {"GetDesc", Buf_GetDesc}}

buf_create :: proc(kind: Res_Kind, size, usage, format, pool, out: u32) -> u32 {
	if size == 0 {
		x86.wr32(out, 0)
		return D3DERR_INVALIDCALL
	}
	iface := kind == .VB ? "IDirect3DVertexBuffer9" : "IDirect3DIndexBuffer9"
	_, r := res_new(kind, res_vtable(iface, BUF_OWN[:]))
	r.format, r.usage, r.pool, r.w = format, usage, pool, size
	r.shadow = heap_alloc(size, true)
	gl.CreateBuffers(1, &r.gl)
	gl.NamedBufferData(r.gl, int(size), x86.ptr(r.shadow), gl.DYNAMIC_DRAW)
	r.lock_lo, r.lock_hi = size, 0
	x86.wr32(out, r.obj)
	return D3D_OK
}

// (this, Length, Usage, FVF, Pool, ppVertexBuffer, pSharedHandle)
Dev_CreateVertexBuffer :: proc() {
	ret(7, buf_create(.VB, arg(1), arg(2), arg(3), arg(4), arg(5)))
}

// (this, Length, Usage, Format, Pool, ppIndexBuffer, pSharedHandle)
Dev_CreateIndexBuffer :: proc() {
	ret(7, buf_create(.IB, arg(1), arg(2), arg(3), arg(4), arg(5)))
}

// (this, OffsetToLock, SizeToLock, ppbData, Flags); size 0 locks to the end.
Buf_Lock :: proc() {
	r := res_of(arg(0))
	off, n := arg(1), arg(2)
	if off > r.w || (n != 0 && n > r.w - off) {
		ret(5, D3DERR_INVALIDCALL)
		return
	}
	if n == 0 {
		n = r.w - off
	}
	if arg(4) & D3DLOCK_READONLY == 0 {
		r.lock_lo = min(r.lock_lo, off)
		r.lock_hi = max(r.lock_hi, off + n)
	}
	x86.wr32(arg(3), r.shadow + off)
	ret(5, D3D_OK)
}

// Uploads the dirty bytes of [lo, hi) and trims them off the dirty range when
// they lie at one of its ends; dirty bytes inside the range stay dirty. A
// buffer without D3DUSAGE_DYNAMIC uploads its whole dirty range instead, so a
// draw reading the middle of a static buffer does not upload it every frame.
buf_sync :: proc(r: ^Res, lo, hi: i64) {
	a := max(i64(r.lock_lo), lo, 0)
	b := min(i64(r.lock_hi), hi, i64(r.w))
	if b <= a {return}
	if r.usage & D3DUSAGE_DYNAMIC == 0 {
		a, b = i64(r.lock_lo), min(i64(r.lock_hi), i64(r.w))
	}
	gl.NamedBufferSubData(r.gl, int(a), int(b - a), x86.ptr(r.shadow + u32(a)))
	switch {
	case a == i64(r.lock_lo) && b == i64(r.lock_hi): r.lock_lo, r.lock_hi = r.w, 0
	case a == i64(r.lock_lo): r.lock_lo = u32(b)
	case b == i64(r.lock_hi): r.lock_hi = u32(a)
	}
}

// Uploads nothing: draws upload what they read (buf_sync).
Buf_Unlock :: proc() {
	ret(1, D3D_OK)
}

// D3DVERTEXBUFFER_DESC {Format, Type, Usage, Pool, Size, FVF};
// D3DINDEXBUFFER_DESC {Format, Type, Usage, Pool, Size}.
Buf_GetDesc :: proc() {
	r := res_of(arg(0))
	p := arg(1)
	x86.wr32(p, r.kind == .VB ? D3DFMT_VERTEXDATA : r.format)
	x86.wr32(p + 4, RES_TYPE[r.kind])
	x86.wr32(p + 8, r.usage)
	x86.wr32(p + 12, r.pool)
	x86.wr32(p + 16, r.w)
	if r.kind == .VB {
		x86.wr32(p + 20, r.format)
	}
	ret(2, D3D_OK)
}
