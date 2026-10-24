// Vertex declarations (D3DVERTEXELEMENT9 lists) and the FVF codes that
// imply one. Draws consume the decl bound by SetVertexDeclaration or,
// after SetFVF, the decl derived from the FVF.
package win32

import "../x86"

// D3DDECLTYPE
Decl_Type :: enum u8 {
	FLOAT1, FLOAT2, FLOAT3, FLOAT4, D3DCOLOR, UBYTE4, SHORT2, SHORT4, UBYTE4N, SHORT2N, SHORT4N,
	USHORT2N, USHORT4N, UDEC3, DEC3N, FLOAT16_2, FLOAT16_4, UNUSED,
}

// D3DDECLUSAGE
Decl_Usage :: enum u8 {
	POSITION, BLENDWEIGHT, BLENDINDICES, NORMAL, PSIZE, TEXCOORD, TANGENT, BINORMAL, TESSFACTOR,
	POSITIONT, COLOR, FOG, DEPTH, SAMPLE,
}

DECL_TYPE_SIZE := [Decl_Type]u8 {
	.FLOAT1 = 4, .FLOAT2 = 8, .FLOAT3 = 12, .FLOAT4 = 16, .D3DCOLOR = 4, .UBYTE4 = 4, .SHORT2 = 4,
	.SHORT4 = 8, .UBYTE4N = 4, .SHORT2N = 4, .SHORT4N = 8, .USHORT2N = 4, .USHORT4N = 8, .UDEC3 = 4,
	.DEC3N = 4, .FLOAT16_2 = 4, .FLOAT16_4 = 8, .UNUSED = 0,
}

Decl_Elem :: struct {
	stream, offset: u16,
	type:           Decl_Type,
	method:         u8,
	usage:          Decl_Usage,
	index:          u8,
}

DECL_ELEMS_MAX :: 64

Decl :: struct {
	elems: [dynamic]Decl_Elem,
	fvf:   u32, // nonzero when derived from an FVF
	vao:   u32, // GL vertex array holding the attribute formats, 0 until first draw
}

decls: [dynamic]Decl
fvf_decls: map[u32]u32 // FVF code -> decl id

DECL_OWN := [?]Com_Method {
	{"QueryInterface", com_query}, {"AddRef", com_addref}, {"Release", com_release},
	{"GetDevice", Res_GetDevice}, {"GetDeclaration", Decl_GetDeclaration},
}

decl_add :: proc(d: Decl) -> u32 {
	for e in d.elems {
		assert(e.type != .UNUSED && e.stream < STREAMS)
	}
	append(&decls, d)
	return u32(len(decls) - 1)
}

// (this, pVertexElements, ppDecl): the list ends with Stream 0xFF.
Dev_CreateVertexDeclaration :: proc() {
	p := arg(1)
	d: Decl
	for i in 0 ..< u32(DECL_ELEMS_MAX + 1) {
		if i == DECL_ELEMS_MAX {
			x86.fatal("d3d9: vertex declaration at %08x has no end marker", p)
		}
		q := p + i * 8
		stream := x86.rd16(q)
		if stream == 0xff {
			break
		}
		e := Decl_Elem {
			stream = stream, offset = x86.rd16(q + 2), type = Decl_Type(x86.rd8(q + 4)),
			method = x86.rd8(q + 5), usage = Decl_Usage(x86.rd8(q + 6)), index = x86.rd8(q + 7),
		}
		if u8(e.type) > u8(Decl_Type.UNUSED) || u8(e.usage) > u8(Decl_Usage.SAMPLE) || e.stream >= STREAMS {
			x86.wr32(arg(2), 0)
			ret(3, D3DERR_INVALIDCALL)
			return
		}
		append(&d.elems, e)
	}
	vt := com_vtable("d3d9.dll", "IDirect3DVertexDeclaration9", DECL_OWN[:])
	x86.wr32(arg(2), com_new(vt, decl_add(d)))
	ret(3, D3D_OK)
}

// (this, pElement, pNumElements): the count includes the end marker.
Decl_GetDeclaration :: proc() {
	d := &decls[com_id(arg(0))]
	n := u32(len(d.elems))
	if p := arg(1); p != 0 {
		for e, i in d.elems {
			q := p + u32(i) * 8
			x86.wr16(q, e.stream)
			x86.wr16(q + 2, e.offset)
			x86.wr8(q + 4, u8(e.type))
			x86.wr8(q + 5, e.method)
			x86.wr8(q + 6, u8(e.usage))
			x86.wr8(q + 7, e.index)
		}
		q := p + n * 8 // D3DDECL_END
		x86.wr16(q, 0xff)
		x86.wr16(q + 2, 0)
		x86.wr32(q + 4, u32(Decl_Type.UNUSED))
	}
	x86.wr32(arg(2), n + 1)
	ret(3, D3D_OK)
}

// D3DFVF_* bits.
FVF_POSITION_MASK :: 0x400e
FVF_XYZ :: 0x2
FVF_XYZRHW :: 0x4
FVF_XYZW :: 0x4002
FVF_NORMAL :: 0x10
FVF_PSIZE :: 0x20
FVF_DIFFUSE :: 0x40
FVF_SPECULAR :: 0x80
FVF_LASTBETA_UBYTE4 :: 0x1000
FVF_LASTBETA_D3DCOLOR :: 0x8000

// The declaration an FVF implies, on stream 0 (D3D9 docs "Mapping FVF
// Codes to a Directx 9 Declaration").
fvf_decl :: proc(fvf: u32) -> u32 {
	if id, ok := fvf_decls[fvf]; ok {
		return id
	}
	d := Decl{fvf = fvf}
	off: u16
	put :: proc(d: ^Decl, off: ^u16, t: Decl_Type, u: Decl_Usage, idx: u8 = 0) {
		append(&d.elems, Decl_Elem{offset = off^, type = t, usage = u, index = idx})
		off^ += u16(DECL_TYPE_SIZE[t])
	}
	pos := fvf & FVF_POSITION_MASK
	switch pos {
	case FVF_XYZ: put(&d, &off, .FLOAT3, .POSITION)
	case FVF_XYZRHW: put(&d, &off, .FLOAT4, .POSITIONT)
	case FVF_XYZW: put(&d, &off, .FLOAT4, .POSITION)
	case 0x6, 0x8, 0xa, 0xc, 0xe: // XYZB1..XYZB5
		put(&d, &off, .FLOAT3, .POSITION)
		betas := (pos - 4) / 2
		last_idx := fvf & (FVF_LASTBETA_UBYTE4 | FVF_LASTBETA_D3DCOLOR) != 0
		weights := last_idx ? betas - 1 : betas
		if weights > 0 {
			put(&d, &off, Decl_Type(u32(Decl_Type.FLOAT1) + weights - 1), .BLENDWEIGHT)
		}
		if last_idx {
			put(&d, &off, fvf & FVF_LASTBETA_UBYTE4 != 0 ? .UBYTE4 : .D3DCOLOR, .BLENDINDICES)
		}
	case 0:
	case: x86.fatal("d3d9: unsupported FVF position %x", pos)
	}
	if fvf & FVF_NORMAL != 0 {put(&d, &off, .FLOAT3, .NORMAL)}
	if fvf & FVF_PSIZE != 0 {put(&d, &off, .FLOAT1, .PSIZE)}
	if fvf & FVF_DIFFUSE != 0 {put(&d, &off, .D3DCOLOR, .COLOR, 0)}
	if fvf & FVF_SPECULAR != 0 {put(&d, &off, .D3DCOLOR, .COLOR, 1)}
	TC_TYPE := [4]Decl_Type{.FLOAT2, .FLOAT3, .FLOAT4, .FLOAT1}
	for i in 0 ..< (fvf >> 8) & 0xf {
		put(&d, &off, TC_TYPE[(fvf >> (16 + 2 * i)) & 3], .TEXCOORD, u8(i))
	}
	id := decl_add(d)
	fvf_decls[fvf] = id
	return id
}

decl_stride :: proc(d: ^Decl, stream: u16) -> u32 {
	n: u32
	for e in d.elems {
		if e.stream == stream {
			n = max(n, u32(e.offset) + u32(DECL_TYPE_SIZE[e.type]))
		}
	}
	return n
}

// Binding: decl id + 1 (0 = none).
Dev_SetVertexDeclaration :: proc() {
	o := arg(1)
	bind.decl, bind.decl_obj = o == 0 ? 0 : com_id(o) + 1, o
	ds.fvf = 0
	ret(2, D3D_OK)
}

Dev_GetVertexDeclaration :: proc() {
	_ = addref_out(arg(1), bind.decl_obj)
	ret(2, D3D_OK)
}
