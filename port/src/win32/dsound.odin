// DirectSound 8: software buffers mixed on the main thread into one SDL
// audio stream (dsound_mix.odin). Every interface of a buffer (the buffer
// itself, its 3D interface, its reverb effect) shares one host refcount, so
// the buffer dies when the last of them is released. The 3D listener is the
// primary buffer's 3D interface. Deferred 3D settings apply immediately.
// The I3DL2 reverb effect runs in dsound_reverb.odin.
package win32

import "core:fmt"
import "core:mem"
import sdl "vendor:sdl3"
import "../x86"

DSOUND := [?]Hle_Entry {
	{"dsound.dll!#11", DirectSoundCreate8},
}

DS8_METHODS := [?]Com_Method {
	{"QueryInterface", DS_QueryInterface}, {"AddRef", com_addref}, {"Release", com_release},
	{"CreateSoundBuffer", DS_CreateSoundBuffer}, {"GetCaps", DS_GetCaps},
	{"DuplicateSoundBuffer", DS_DuplicateSoundBuffer}, {"SetCooperativeLevel", DS_SetCooperativeLevel},
	{"Compact", DS_Compact}, {"GetSpeakerConfig", DS_GetSpeakerConfig},
	{"SetSpeakerConfig", DS_SetSpeakerConfig}, {"Initialize", nil}, {"VerifyCertification", nil},
}

DSB8_METHODS := [?]Com_Method {
	{"QueryInterface", Dsb_QueryInterface}, {"AddRef", Dsb_AddRef}, {"Release", Dsb_Release},
	{"GetCaps", Dsb_GetCaps}, {"GetCurrentPosition", Dsb_GetCurrentPosition},
	{"GetFormat", Dsb_GetFormat}, {"GetVolume", Dsb_GetVolume}, {"GetPan", Dsb_GetPan},
	{"GetFrequency", Dsb_GetFrequency}, {"GetStatus", Dsb_GetStatus}, {"Initialize", nil},
	{"Lock", Dsb_Lock}, {"Play", Dsb_Play}, {"SetCurrentPosition", Dsb_SetCurrentPosition},
	{"SetFormat", Dsb_SetFormat}, {"SetVolume", Dsb_SetVolume}, {"SetPan", Dsb_SetPan},
	{"SetFrequency", Dsb_SetFrequency}, {"Stop", Dsb_Stop}, {"Unlock", Dsb_Unlock},
	{"Restore", DS_Compact}, {"SetFX", Dsb_SetFX}, {"AcquireResources", nil},
	{"GetObjectInPath", Dsb_GetObjectInPath},
}

DS3D_METHODS := [?]Com_Method {
	{"QueryInterface", Dsb_QueryInterface}, {"AddRef", Dsb_AddRef}, {"Release", Dsb_Release},
	{"GetAllParameters", D3b_GetAllParameters}, {"GetConeAngles", D3b_GetConeAngles},
	{"GetConeOrientation", D3b_GetConeOrientation}, {"GetConeOutsideVolume", D3b_GetConeOutsideVolume},
	{"GetMaxDistance", D3b_GetMaxDistance}, {"GetMinDistance", D3b_GetMinDistance},
	{"GetMode", D3b_GetMode}, {"GetPosition", D3b_GetPosition}, {"GetVelocity", D3b_GetVelocity},
	{"SetAllParameters", D3b_SetAllParameters}, {"SetConeAngles", D3b_SetConeAngles},
	{"SetConeOrientation", D3b_SetConeOrientation}, {"SetConeOutsideVolume", D3b_SetConeOutsideVolume},
	{"SetMaxDistance", D3b_SetMaxDistance}, {"SetMinDistance", D3b_SetMinDistance},
	{"SetMode", D3b_SetMode}, {"SetPosition", D3b_SetPosition}, {"SetVelocity", D3b_SetVelocity},
}

DS3DL_METHODS := [?]Com_Method {
	{"QueryInterface", Dsb_QueryInterface}, {"AddRef", Dsb_AddRef}, {"Release", Dsb_Release},
	{"GetAllParameters", D3l_GetAllParameters}, {"GetDistanceFactor", D3l_GetDistanceFactor},
	{"GetDopplerFactor", D3l_GetDopplerFactor}, {"GetOrientation", D3l_GetOrientation},
	{"GetPosition", D3l_GetPosition}, {"GetRolloffFactor", D3l_GetRolloffFactor},
	{"GetVelocity", D3l_GetVelocity}, {"SetAllParameters", D3l_SetAllParameters},
	{"SetDistanceFactor", D3l_SetDistanceFactor}, {"SetDopplerFactor", D3l_SetDopplerFactor},
	{"SetOrientation", D3l_SetOrientation}, {"SetPosition", D3l_SetPosition},
	{"SetRolloffFactor", D3l_SetRolloffFactor}, {"SetVelocity", D3l_SetVelocity},
	{"CommitDeferredSettings", D3l_CommitDeferredSettings},
}

REVERB_METHODS := [?]Com_Method {
	{"QueryInterface", Dsb_QueryInterface}, {"AddRef", Dsb_AddRef}, {"Release", Dsb_Release},
	{"SetAllParameters", Rvb_SetAllParameters}, {"GetAllParameters", Rvb_GetAllParameters},
	{"SetPreset", Rvb_SetPreset}, {"GetPreset", Rvb_GetPreset},
	{"SetQuality", Rvb_SetQuality}, {"GetQuality", Rvb_GetQuality},
}

IID_IUnknown := [16]u8{0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}
IID_IDirectSound := [16]u8{0x83, 0xfa, 0x9a, 0x27, 0x81, 0x49, 0xce, 0x11, 0xa5, 0x21, 0x00, 0x20, 0xaf, 0x0b, 0xe5, 0x60}
IID_IDirectSound8 := [16]u8{0x93, 0x7e, 0x0a, 0xc5, 0x95, 0xf3, 0x34, 0x48, 0x9e, 0xf6, 0x7f, 0xa9, 0x9d, 0xe5, 0x09, 0x66}
IID_IDirectSoundBuffer := [16]u8{0x85, 0xfa, 0x9a, 0x27, 0x81, 0x49, 0xce, 0x11, 0xa5, 0x21, 0x00, 0x20, 0xaf, 0x0b, 0xe5, 0x60}
IID_IDirectSoundBuffer8 := [16]u8{0x49, 0xa4, 0x25, 0x68, 0x24, 0x75, 0x82, 0x4d, 0x92, 0x0f, 0x50, 0xe3, 0x6a, 0xb3, 0xab, 0x1e}
IID_IDirectSound3DBuffer := [16]u8{0x86, 0xfa, 0x9a, 0x27, 0x81, 0x49, 0xce, 0x11, 0xa5, 0x21, 0x00, 0x20, 0xaf, 0x0b, 0xe5, 0x60}
IID_IDirectSound3DListener := [16]u8{0x84, 0xfa, 0x9a, 0x27, 0x81, 0x49, 0xce, 0x11, 0xa5, 0x21, 0x00, 0x20, 0xaf, 0x0b, 0xe5, 0x60}
IID_IDirectSoundFXI3DL2Reverb8 := [16]u8{0x6a, 0x6a, 0x16, 0x4b, 0x66, 0x0d, 0xf3, 0x43, 0x80, 0xe3, 0xee, 0x62, 0x80, 0xde, 0xe1, 0xa4}
GUID_DSFX_STANDARD_I3DL2REVERB := [16]u8{0x71, 0x5e, 0x98, 0xef, 0xc7, 0xd5, 0xd4, 0x42, 0xba, 0x4d, 0x2d, 0x07, 0x3e, 0x2e, 0x96, 0xf4}
GUID_All_Objects := [16]u8{0xe5, 0x4d, 0x11, 0xaa, 0x62, 0xc2, 0x69, 0x41, 0xa1, 0xc8, 0x23, 0xd6, 0x98, 0xcc, 0x73, 0xb5}

DS_OK :: 0
DSERR_INVALIDPARAM :: 0x80070057

// Rejects a call's argument as DirectSound does, logging which call and value:
// the game reports only the HRESULT, with a SoundAPI.cpp line number.
ds_invalid :: proc(call: string, n: u32, value: u32) {
	fmt.eprintfln("dsound: %s rejected 0x%x (DSERR_INVALIDPARAM)", call, value)
	ret(n, DSERR_INVALIDPARAM)
}
DSERR_NOINTERFACE :: 0x80004002
DSERR_CONTROLUNAVAIL :: 0x8878001e
DSERR_INVALIDCALL :: 0x88780032
DSERR_NODRIVER :: 0x88780078
DSERR_OBJECTNOTFOUND :: 0x88781161

// DSBCAPS_*.
DSBCAPS_PRIMARYBUFFER :: 0x1
DSBCAPS_LOCHARDWARE :: 0x4
DSBCAPS_LOCSOFTWARE :: 0x8
DSBCAPS_CTRL3D :: 0x10
DSBCAPS_CTRLFX :: 0x200

DSBPLAY_LOOPING :: 1
DSBLOCK_FROMWRITECURSOR :: 1
DSBLOCK_ENTIREBUFFER :: 2
DSBSTATUS_PLAYING :: 1
DSBSTATUS_LOOPING :: 4
DSSPEAKER_STEREO :: 4
DSFXR_LOCSOFTWARE :: 2
DSBFREQUENCY_ORIGINAL :: 0

DS_BUFS_MAX :: 1024
DS_WRITE_LEAD_MS :: 15 // write cursor lead over the play cursor

Ds_Fmt :: struct {
	ch, bits, align: u32,
	rate:            u32,
}

// DS3DBUFFER, guest layout.
Ds3d_Buffer :: struct #packed {
	size:            u32,
	pos, vel:        [3]f32,
	inside, outside: u32, // cone angles, degrees
	orient:          [3]f32,
	outvol:          i32,
	min_d, max_d:    f32,
	mode:            u32, // 0 normal, 1 head-relative, 2 disabled
}

// DS3DLISTENER, guest layout.
Ds3d_Listener :: struct #packed {
	size:                         u32,
	pos, vel, front, top:         [3]f32,
	dist_f, rolloff_f, doppler_f: f32,
}

#assert(size_of(Ds3d_Buffer) == 64 && size_of(Ds3d_Listener) == 64)

// DSFXI3DL2Reverb, guest layout: 12 dwords (mixed LONG and FLOAT).
DS_REVERB_WORDS :: 12

Ds_Buf :: struct {
	live, primary:       bool,
	playing, looping:    bool,
	flags:               u32,
	data, size:          u32, // guest sample block; 0 for the primary buffer
	fmt:                 Ds_Fmt,
	freq:                u32, // 0: fmt.rate
	vol, pan:            i32, // hundredths of a dB
	pos:                 f64, // play position, frames
	p3d:                 Ds3d_Buffer,
	reverb:              [DS_REVERB_WORDS]u32,
	reverb_preset:       u32,
	reverb_quality:      u32,
	has_reverb:          bool,
	refs:                [Ds_Iface]u32, // per interface, as in dsound: each Release returns its own count
	obj, obj3d, obj_fx:  u32, // guest interfaces, 0 until asked for
}

// Interfaces of one buffer. The buffer lives while any count is non-zero.
Ds_Iface :: enum u8 {Main, I3d, Fx}

ds_bufs: [DS_BUFS_MAX]Ds_Buf
ds_listener: Ds3d_Listener
ds_data_refs: map[u32]u32 // sample block -> buffers sharing it (DuplicateSoundBuffer)

ds_buf_of :: proc(this: u32) -> ^Ds_Buf {
	id := com_id(this)
	if id >= DS_BUFS_MAX || !ds_bufs[id].live {x86.fatal("dsound: dead buffer object %08x", this)}
	return &ds_bufs[id]
}

ds_buf_new :: proc() -> (u32, ^Ds_Buf) {
	for &b, i in ds_bufs {
		if b.live {continue}
		b = {live = true, refs = {.Main = 1, .I3d = 0, .Fx = 0}}
		b.p3d = {size = 64, inside = 360, outside = 360, orient = {0, 0, 1}, min_d = 1, max_d = 1e9}
		b.obj = com_new(com_vtable("dsound.dll", "IDirectSoundBuffer8", DSB8_METHODS[:]), u32(i))
		return u32(i), &b
	}
	x86.fatal("dsound: more than %d buffers", DS_BUFS_MAX)
}

DirectSoundCreate8 :: proc() {
	out, outer := arg(1), arg(2)
	if outer != 0 {x86.fatal("DirectSoundCreate8: aggregation")}
	if ds_stream == nil {ds_open()}
	ds_listener = {size = 64, front = {0, 0, 1}, top = {0, 1, 0}, dist_f = 1, rolloff_f = 1, doppler_f = 1}
	x86.wr32(out, com_new(com_vtable("dsound.dll", "IDirectSound8", DS8_METHODS[:]), 0))
	ret(3, DS_OK)
}

DS_QueryInterface :: proc() {
	this, g, out := arg(0), arg(1), arg(2)
	if !guid_eq(g, IID_IUnknown) && !guid_eq(g, IID_IDirectSound) && !guid_eq(g, IID_IDirectSound8) {
		com_query()
	}
	x86.wr32(this + 4, x86.rd32(this + 4) + 1)
	x86.wr32(out, this)
	ret(3, DS_OK)
}

// Reads WAVEFORMATEX at p; only 8/16-bit mono/stereo PCM exists in the game.
ds_fmt_read :: proc(p: u32) -> Ds_Fmt {
	tag, ch, rate, align, bits := x86.rd16(p), u32(x86.rd16(p + 2)), x86.rd32(p + 4), u32(x86.rd16(p + 12)), u32(x86.rd16(p + 14))
	if tag != 1 || ch < 1 || ch > 2 || (bits != 8 && bits != 16) || align != ch * bits / 8 || rate == 0 {
		x86.fatal("dsound: unsupported format tag %d, %d ch, %d bits, align %d, %d Hz", tag, ch, bits, align, rate)
	}
	return {ch = ch, bits = bits, align = align, rate = rate}
}

ds_fmt_write :: proc(p: u32, f: Ds_Fmt) {
	x86.wr16(p, 1)
	x86.wr16(p + 2, u16(f.ch))
	x86.wr32(p + 4, f.rate)
	x86.wr32(p + 8, f.rate * f.align)
	x86.wr16(p + 12, u16(f.align))
	x86.wr16(p + 14, u16(f.bits))
}

DS_CreateSoundBuffer :: proc() {
	desc, out, outer := arg(1), arg(2), arg(3)
	if outer != 0 {x86.fatal("CreateSoundBuffer: aggregation")}
	if x86.rd32(desc) != 36 && x86.rd32(desc) != 20 {x86.fatal("CreateSoundBuffer: DSBUFFERDESC size %d", x86.rd32(desc))}
	flags, bytes, wfx := x86.rd32(desc + 4), x86.rd32(desc + 8), x86.rd32(desc + 16)
	_, b := ds_buf_new()
	b.flags = (flags &~ DSBCAPS_LOCHARDWARE) | DSBCAPS_LOCSOFTWARE
	if flags & DSBCAPS_PRIMARYBUFFER != 0 {
		b.primary = true
		b.fmt = {ch = 2, bits = 16, align = 4, rate = DS_RATE}
	} else {
		if wfx == 0 || bytes < 4 || bytes > 0x10000000 {x86.fatal("CreateSoundBuffer: %d bytes, format %08x", bytes, wfx)}
		b.fmt = ds_fmt_read(wfx)
		b.size = bytes - bytes % b.fmt.align
		b.data = heap_alloc(b.size, true)
		if b.fmt.bits == 8 {mem.set(x86.ptr(b.data), 0x80, int(b.size))} // 8-bit silence
		ds_data_refs[b.data] = 1
	}
	x86.wr32(out, b.obj)
	ret(4, DS_OK)
}

DS_DuplicateSoundBuffer :: proc() {
	src, out := ds_buf_of(arg(1)), arg(2)
	if src.primary {x86.fatal("DuplicateSoundBuffer of the primary buffer")}
	_, b := ds_buf_new()
	obj := b.obj
	b^ = src^
	b.obj, b.obj3d, b.obj_fx, b.refs = obj, 0, 0, {.Main = 1, .I3d = 0, .Fx = 0}
	b.playing, b.looping, b.pos, b.has_reverb = false, false, 0, false
	ds_data_refs[b.data] += 1
	x86.wr32(out, b.obj)
	ret(3, DS_OK)
}

DS_GetCaps :: proc() {
	p := arg(1)
	if x86.rd32(p) != 96 {x86.fatal("IDirectSound8::GetCaps: DSCAPS size %d", x86.rd32(p))}
	x86.mem_zero(p + 4, 92)
	x86.wr32(p + 4, 0xf1f) // primary/secondary mono, stereo, 8 and 16 bit, continuous rate
	x86.wr32(p + 8, 100)
	x86.wr32(p + 12, 200000)
	x86.wr32(p + 16, 1)
	ret(2, DS_OK)
}

DS_SetCooperativeLevel :: proc() {ret(3, DS_OK)}
DS_Compact :: proc() {ret(1, DS_OK)}
DS_SetSpeakerConfig :: proc() {ret(2, DS_OK)}

DS_GetSpeakerConfig :: proc() {
	x86.wr32(arg(1), DSSPEAKER_STEREO)
	ret(2, DS_OK)
}

// Interface of buffer b answering IID g, created on first request; 0 if none.
ds_iface :: proc(b: ^Ds_Buf, id: u32, g: u32) -> u32 {
	switch {
	case guid_eq(g, IID_IUnknown), guid_eq(g, IID_IDirectSoundBuffer), guid_eq(g, IID_IDirectSoundBuffer8):
		return b.obj
	case guid_eq(g, IID_IDirectSound3DBuffer):
		if b.primary || b.flags & DSBCAPS_CTRL3D == 0 {return 0}
		if b.obj3d == 0 {b.obj3d = com_new(com_vtable("dsound.dll", "IDirectSound3DBuffer8", DS3D_METHODS[:]), id)}
		return b.obj3d
	case guid_eq(g, IID_IDirectSound3DListener):
		if !b.primary {return 0}
		if b.obj3d == 0 {b.obj3d = com_new(com_vtable("dsound.dll", "IDirectSound3DListener8", DS3DL_METHODS[:]), id)}
		return b.obj3d
	case guid_eq(g, IID_IDirectSoundFXI3DL2Reverb8):
		return b.has_reverb ? ds_reverb_obj(b, id) : 0
	}
	x86.fatal("dsound: QueryInterface({%08x-%04x-%04x-...})", x86.rd32(g), x86.rd16(g + 4), x86.rd16(g + 6))
}

// Which interface of b the guest object o is.
ds_iface_kind :: proc(b: ^Ds_Buf, o: u32) -> Ds_Iface {
	switch o {
	case b.obj:
		return .Main
	case b.obj3d:
		return .I3d
	case b.obj_fx:
		return .Fx
	}
	x86.fatal("dsound: object %08x is not an interface of its buffer", o)
}

ds_reverb_obj :: proc(b: ^Ds_Buf, id: u32) -> u32 {
	if b.obj_fx == 0 {b.obj_fx = com_new(com_vtable("dsound.dll", "IDirectSoundFXI3DL2Reverb8", REVERB_METHODS[:]), id)}
	return b.obj_fx
}

Dsb_QueryInterface :: proc() {
	b := ds_buf_of(arg(0))
	o := ds_iface(b, com_id(arg(0)), arg(1))
	x86.wr32(arg(2), o)
	if o == 0 {
		ret(3, DSERR_NOINTERFACE)
		return
	}
	b.refs[ds_iface_kind(b, o)] += 1
	ret(3, DS_OK)
}

Dsb_AddRef :: proc() {
	b := ds_buf_of(arg(0))
	k := ds_iface_kind(b, arg(0))
	b.refs[k] += 1
	ret(1, b.refs[k])
}

Dsb_Release :: proc() {
	b := ds_buf_of(arg(0))
	k := ds_iface_kind(b, arg(0))
	if b.refs[k] == 0 {x86.fatal("dsound: Release of %08x with no references", arg(0))}
	b.refs[k] -= 1
	n := b.refs[k]
	if b.refs == {} {
		for o in ([3]u32{b.obj, b.obj3d, b.obj_fx}) {if o != 0 {heap_free(o)}}
		if b.data != 0 {
			ds_data_refs[b.data] -= 1
			if ds_data_refs[b.data] == 0 {
				delete_key(&ds_data_refs, b.data)
				heap_free(b.data)
			}
		}
		b^ = {}
	}
	ret(1, n)
}

Dsb_GetCaps :: proc() {
	b, p := ds_buf_of(arg(0)), arg(1)
	if x86.rd32(p) != 20 {x86.fatal("IDirectSoundBuffer8::GetCaps: DSBCAPS size %d", x86.rd32(p))}
	x86.wr32(p + 4, b.flags)
	x86.wr32(p + 8, b.size)
	x86.wr32(p + 12, 0)
	x86.wr32(p + 16, 0)
	ret(2, DS_OK)
}

// Play and write cursors, bytes. A stopped buffer has them equal.
ds_cursors :: proc(b: ^Ds_Buf) -> (play, write: u32) {
	if b.primary {return 0, 0}
	play = u32(b.pos) * b.fmt.align
	write = play
	if b.playing {
		lead := ds_rate(b) * DS_WRITE_LEAD_MS / 1000 * b.fmt.align
		write = (play + lead) % b.size
	}
	return
}

ds_rate :: #force_inline proc(b: ^Ds_Buf) -> u32 {return b.freq != 0 ? b.freq : b.fmt.rate}

Dsb_GetCurrentPosition :: proc() {
	b, pp, pw := ds_buf_of(arg(0)), arg(1), arg(2)
	ds_pump()
	play, write := ds_cursors(b)
	if pp != 0 {x86.wr32(pp, play)}
	if pw != 0 {x86.wr32(pw, write)}
	ret(3, DS_OK)
}

Dsb_GetFormat :: proc() {
	b, p, cap, written := ds_buf_of(arg(0)), arg(1), arg(2), arg(3)
	if p != 0 {
		if cap < 16 {
			ds_invalid("GetFormat", 4, cap)
			return
		}
		ds_fmt_write(p, b.fmt)
		if cap >= 18 {x86.wr16(p + 16, 0)}
	}
	if written != 0 {x86.wr32(written, 18)}
	ret(4, DS_OK)
}

Dsb_GetVolume :: proc() {x86.wr32(arg(1), u32(ds_buf_of(arg(0)).vol)); ret(2, DS_OK)}
Dsb_GetPan :: proc() {x86.wr32(arg(1), u32(ds_buf_of(arg(0)).pan)); ret(2, DS_OK)}
Dsb_GetFrequency :: proc() {x86.wr32(arg(1), ds_rate(ds_buf_of(arg(0)))); ret(2, DS_OK)}

Dsb_GetStatus :: proc() {
	b := ds_buf_of(arg(0))
	ds_pump()
	s: u32 = DSBSTATUS_PLAYING if b.playing || b.primary else 0
	if b.playing && b.looping {s |= DSBSTATUS_LOOPING}
	x86.wr32(arg(1), s)
	ret(2, DS_OK)
}

// The lock hands out the guest sample block itself, so Unlock has nothing to copy.
Dsb_Lock :: proc() {
	b := ds_buf_of(arg(0))
	off, n, p1, n1, p2, n2, flags := arg(1), arg(2), arg(3), arg(4), arg(5), arg(6), arg(7)
	if b.primary {x86.fatal("Lock of the primary buffer")}
	if flags & DSBLOCK_ENTIREBUFFER != 0 {
		off, n = 0, b.size
	} else if flags & DSBLOCK_FROMWRITECURSOR != 0 {
		_, off = ds_cursors(b)
	}
	if off >= b.size || n == 0 || n > b.size {
		ds_invalid("Lock", 8, off >= b.size ? off : n)
		return
	}
	first := min(n, b.size - off)
	x86.wr32(p1, b.data + off)
	x86.wr32(n1, first)
	if p2 != 0 {x86.wr32(p2, n > first ? b.data : 0)}
	if n2 != 0 {x86.wr32(n2, n - first)}
	ret(8, DS_OK)
}

Dsb_Unlock :: proc() {ret(5, DS_OK)}

Dsb_Play :: proc() {
	b, flags := ds_buf_of(arg(0)), arg(3)
	if !b.primary {
		ds_pump() // mix up to now before the buffer joins
		b.playing, b.looping = true, flags & DSBPLAY_LOOPING != 0
	}
	ret(4, DS_OK)
}

Dsb_Stop :: proc() {
	b := ds_buf_of(arg(0))
	ds_pump()
	b.playing = false
	ret(1, DS_OK)
}

Dsb_SetCurrentPosition :: proc() {
	b, p := ds_buf_of(arg(0)), arg(1)
	if !b.primary {
		if p >= b.size {
			ds_invalid("SetCurrentPosition", 2, p)
			return
		}
		b.pos = f64(p / b.fmt.align)
	}
	ret(2, DS_OK)
}

Dsb_SetFormat :: proc() {
	b := ds_buf_of(arg(0))
	if !b.primary {
		ret(2, DSERR_INVALIDCALL)
		return
	}
	b.fmt = ds_fmt_read(arg(1)) // the mix stays 48 kHz stereo float
	ret(2, DS_OK)
}

Dsb_SetVolume :: proc() {
	b, v := ds_buf_of(arg(0)), i32(arg(1))
	if v > 0 || v < -10000 {
		ds_invalid("SetVolume", 2, u32(v))
		return
	}
	b.vol = v
	ret(2, DS_OK)
}

Dsb_SetPan :: proc() {
	b, v := ds_buf_of(arg(0)), i32(arg(1))
	if v > 10000 || v < -10000 {
		ds_invalid("SetPan", 2, u32(v))
		return
	}
	b.pan = v
	ret(2, DS_OK)
}

Dsb_SetFrequency :: proc() {
	b, f := ds_buf_of(arg(0)), arg(1)
	if f != DSBFREQUENCY_ORIGINAL && (f < 100 || f > 200000) {
		ds_invalid("SetFrequency", 2, f)
		return
	}
	b.freq = f
	ret(2, DS_OK)
}

// DSEFFECTDESC is 32 bytes: size, flags, effect class GUID, 2 reserved.
Dsb_SetFX :: proc() {
	b, n, descs, results := ds_buf_of(arg(0)), arg(1), arg(2), arg(3)
	if b.flags & DSBCAPS_CTRLFX == 0 {
		ret(4, DSERR_CONTROLUNAVAIL)
		return
	}
	if n > 1 {x86.fatal("SetFX: %d effects", n)}
	b.has_reverb = false
	if n == 1 {
		g := descs + 8
		if !guid_eq(g, GUID_DSFX_STANDARD_I3DL2REVERB) {
			x86.fatal("SetFX: effect {%08x-%04x-%04x-...}", x86.rd32(g), x86.rd16(g + 4), x86.rd16(g + 6))
		}
		b.has_reverb = true
		rvb_preset(b, 0) // DSFX_I3DL2_ENVIRONMENT_PRESET_DEFAULT
		b.reverb_quality = 2
		if results != 0 {x86.wr32(results, DSFXR_LOCSOFTWARE)}
	}
	ret(4, DS_OK)
}

Dsb_GetObjectInPath :: proc() {
	b, obj, idx, iid, out := ds_buf_of(arg(0)), arg(1), arg(2), arg(3), arg(4)
	is_rvb := guid_eq(obj, GUID_DSFX_STANDARD_I3DL2REVERB) || guid_eq(obj, GUID_All_Objects)
	if !is_rvb || idx != 0 || !b.has_reverb {
		x86.wr32(out, 0)
		ret(5, DSERR_OBJECTNOTFOUND)
		return
	}
	if !guid_eq(iid, IID_IDirectSoundFXI3DL2Reverb8) && !guid_eq(iid, IID_IUnknown) {
		x86.wr32(out, 0)
		ret(5, DSERR_NOINTERFACE)
		return
	}
	x86.wr32(out, ds_reverb_obj(b, com_id(arg(0))))
	b.refs[.Fx] += 1
	ret(5, DS_OK)
}

// Opens the playback device. Without one it plays into SDL's silent dummy
// driver: the game's own no-sound path (DirectSoundCreate8 failing) crashes
// later on a null pointer, and online peers must take the same path anyway.
ds_open :: proc() {
	if !ds_open_driver() {
		fmt.eprintfln("dsound: no audio device: %s; running without sound", sdl.GetError())
		sdl.QuitSubSystem({.AUDIO})
		// OVERRIDE, as a plain hint loses to an SDL_AUDIO_DRIVER in the
		// environment naming the driver that just failed.
		sdl.SetHintWithPriority(sdl.HINT_AUDIO_DRIVER, "dummy", .OVERRIDE)
		if !ds_open_driver() {x86.fatal("dsound: dummy audio driver: %s", sdl.GetError())}
	}
	// A device of its own rather than SDL_OpenAudioDeviceStream, so that
	// Bink movie audio can bind a second stream to it.
	spec := sdl.AudioSpec{format = .F32, channels = 2, freq = DS_RATE}
	ds_stream = sdl.CreateAudioStream(&spec, &spec)
	if ds_stream == nil {x86.fatal("dsound: audio stream: %s", sdl.GetError())}
	if !sdl.BindAudioStream(ds_dev, ds_stream) {x86.fatal("dsound: bind audio stream: %s", sdl.GetError())}
	if !sdl.ResumeAudioDevice(ds_dev) {x86.fatal("dsound: resume audio device: %s", sdl.GetError())}
	fmt.eprintfln("dsound: SDL audio driver %s", sdl.GetCurrentAudioDriver())
}

// Starts SDL audio with the current driver hint and opens ds_dev on it.
ds_open_driver :: proc() -> bool {
	if !sdl.InitSubSystem({.AUDIO}) {return false}
	spec := sdl.AudioSpec{format = .F32, channels = 2, freq = DS_RATE}
	ds_dev = sdl.OpenAudioDevice(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec)
	return ds_dev != 0
}
