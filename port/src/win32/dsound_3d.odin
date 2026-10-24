// DirectSound 3D buffer, 3D listener and I3DL2 reverb interfaces: parameter
// storage for the mixer (dsound_mix.odin). Every Set* takes a trailing
// dwApply; DS3D_DEFERRED is honoured as immediate.
package win32

import "core:mem"
import "../x86"

DS3DMODE_DISABLE :: 2

ds3d_of :: proc(this: u32) -> ^Ds3d_Buffer {return &ds_buf_of(this).p3d}

ds_wr_vec :: proc(p: u32, v: [3]f32) {(^[3]f32)(x86.ptr(p))^ = v}

ds_rd_vec3 :: proc(first_arg: u32) -> [3]f32 {
	return {transmute(f32)arg(first_arg), transmute(f32)arg(first_arg + 1), transmute(f32)arg(first_arg + 2)}
}

ds_rd_f32 :: #force_inline proc(i: u32) -> f32 {return transmute(f32)arg(i)}

D3b_GetAllParameters :: proc() {
	p := arg(1)
	if x86.rd32(p) != 64 {x86.fatal("IDirectSound3DBuffer8::GetAllParameters: size %d", x86.rd32(p))}
	mem.copy(x86.ptr(p), ds3d_of(arg(0)), 64)
	ret(2, DS_OK)
}

D3b_SetAllParameters :: proc() {
	d, p := ds3d_of(arg(0)), arg(1)
	if x86.rd32(p) != 64 {x86.fatal("IDirectSound3DBuffer8::SetAllParameters: size %d", x86.rd32(p))}
	mem.copy(d, x86.ptr(p), 64)
	ret(3, DS_OK)
}

D3b_GetConeAngles :: proc() {
	d := ds3d_of(arg(0))
	if arg(1) != 0 {x86.wr32(arg(1), d.inside)}
	if arg(2) != 0 {x86.wr32(arg(2), d.outside)}
	ret(3, DS_OK)
}

D3b_GetConeOrientation :: proc() {ds_wr_vec(arg(1), ds3d_of(arg(0)).orient); ret(2, DS_OK)}
D3b_GetConeOutsideVolume :: proc() {x86.wr32(arg(1), u32(ds3d_of(arg(0)).outvol)); ret(2, DS_OK)}
D3b_GetMaxDistance :: proc() {x86.wr32(arg(1), transmute(u32)ds3d_of(arg(0)).max_d); ret(2, DS_OK)}
D3b_GetMinDistance :: proc() {x86.wr32(arg(1), transmute(u32)ds3d_of(arg(0)).min_d); ret(2, DS_OK)}
D3b_GetMode :: proc() {x86.wr32(arg(1), ds3d_of(arg(0)).mode); ret(2, DS_OK)}
D3b_GetPosition :: proc() {ds_wr_vec(arg(1), ds3d_of(arg(0)).pos); ret(2, DS_OK)}
D3b_GetVelocity :: proc() {ds_wr_vec(arg(1), ds3d_of(arg(0)).vel); ret(2, DS_OK)}

D3b_SetConeAngles :: proc() {
	d, i, o := ds3d_of(arg(0)), arg(1), arg(2)
	if i > 360 || o > 360 || i > o {
		ds_invalid("SetConeAngles", 4, o)
		return
	}
	d.inside, d.outside = i, o
	ret(4, DS_OK)
}

D3b_SetConeOrientation :: proc() {ds3d_of(arg(0)).orient = ds_rd_vec3(1); ret(5, DS_OK)}
D3b_SetConeOutsideVolume :: proc() {ds3d_of(arg(0)).outvol = i32(arg(1)); ret(3, DS_OK)}
D3b_SetMaxDistance :: proc() {ds3d_of(arg(0)).max_d = ds_rd_f32(1); ret(3, DS_OK)}
D3b_SetMinDistance :: proc() {ds3d_of(arg(0)).min_d = ds_rd_f32(1); ret(3, DS_OK)}

D3b_SetMode :: proc() {
	if arg(1) > DS3DMODE_DISABLE {
		ds_invalid("SetMode", 3, arg(1))
		return
	}
	ds3d_of(arg(0)).mode = arg(1)
	ret(3, DS_OK)
}

D3b_SetPosition :: proc() {ds3d_of(arg(0)).pos = ds_rd_vec3(1); ret(5, DS_OK)}
D3b_SetVelocity :: proc() {ds3d_of(arg(0)).vel = ds_rd_vec3(1); ret(5, DS_OK)}

// Listener methods: `this` is the primary buffer's 3D interface; the state is global.

D3l_GetAllParameters :: proc() {
	p := arg(1)
	if x86.rd32(p) != 64 {x86.fatal("IDirectSound3DListener8::GetAllParameters: size %d", x86.rd32(p))}
	mem.copy(x86.ptr(p), &ds_listener, 64)
	ret(2, DS_OK)
}

D3l_SetAllParameters :: proc() {
	p := arg(1)
	if x86.rd32(p) != 64 {x86.fatal("IDirectSound3DListener8::SetAllParameters: size %d", x86.rd32(p))}
	mem.copy(&ds_listener, x86.ptr(p), 64)
	ret(3, DS_OK)
}

D3l_GetDistanceFactor :: proc() {x86.wr32(arg(1), transmute(u32)ds_listener.dist_f); ret(2, DS_OK)}
D3l_GetDopplerFactor :: proc() {x86.wr32(arg(1), transmute(u32)ds_listener.doppler_f); ret(2, DS_OK)}
D3l_GetRolloffFactor :: proc() {x86.wr32(arg(1), transmute(u32)ds_listener.rolloff_f); ret(2, DS_OK)}
D3l_GetPosition :: proc() {ds_wr_vec(arg(1), ds_listener.pos); ret(2, DS_OK)}
D3l_GetVelocity :: proc() {ds_wr_vec(arg(1), ds_listener.vel); ret(2, DS_OK)}

D3l_GetOrientation :: proc() {
	ds_wr_vec(arg(1), ds_listener.front)
	ds_wr_vec(arg(2), ds_listener.top)
	ret(3, DS_OK)
}

D3l_SetDistanceFactor :: proc() {ds_listener.dist_f = ds_rd_f32(1); ret(3, DS_OK)}
D3l_SetDopplerFactor :: proc() {ds_listener.doppler_f = ds_rd_f32(1); ret(3, DS_OK)}
D3l_SetRolloffFactor :: proc() {ds_listener.rolloff_f = ds_rd_f32(1); ret(3, DS_OK)}
D3l_SetPosition :: proc() {ds_listener.pos = ds_rd_vec3(1); ret(5, DS_OK)}
D3l_SetVelocity :: proc() {ds_listener.vel = ds_rd_vec3(1); ret(5, DS_OK)}

D3l_SetOrientation :: proc() {
	ds_listener.front, ds_listener.top = ds_rd_vec3(1), ds_rd_vec3(4)
	ret(8, DS_OK)
}

D3l_CommitDeferredSettings :: proc() {ret(1, DS_OK)}

// DSFXI3DL2Reverb as dsound.h's I3DL2_ENVIRONMENT_PRESET_* (lRoom ..
// flHFReference), by DSFX_I3DL2_ENVIRONMENT_PRESET_* number.
Rvb_Params :: struct {
	room, room_hf:                                  i32,
	rolloff, decay, decay_hf:                       f32,
	reflections:                                    i32,
	reflections_delay:                              f32,
	reverb:                                         i32,
	reverb_delay, diffusion, density, hf_reference: f32,
}
#assert(size_of(Rvb_Params) == DS_REVERB_WORDS * 4)
DS_REVERB_PRESETS := [?]Rvb_Params {
	{-1000, -100, 0.0, 1.49, 0.83, -2602, 0.007, 200, 0.011, 100.0, 100.0, 5000.0}, // DEFAULT
	{-1000, -100, 0.0, 1.49, 0.83, -2602, 0.007, 200, 0.011, 100.0, 100.0, 5000.0}, // GENERIC
	{-1000, -6000, 0.0, 0.17, 0.10, -1204, 0.001, 207, 0.002, 100.0, 100.0, 5000.0}, // PADDEDCELL
	{-1000, -454, 0.0, 0.40, 0.83, -1646, 0.002, 53, 0.003, 100.0, 100.0, 5000.0}, // ROOM
	{-1000, -1200, 0.0, 1.49, 0.54, -370, 0.007, 1030, 0.011, 100.0, 60.0, 5000.0}, // BATHROOM
	{-1000, -6000, 0.0, 0.50, 0.10, -1376, 0.003, -1104, 0.004, 100.0, 100.0, 5000.0}, // LIVINGROOM
	{-1000, -300, 0.0, 2.31, 0.64, -711, 0.012, 83, 0.017, 100.0, 100.0, 5000.0}, // STONEROOM
	{-1000, -476, 0.0, 4.32, 0.59, -789, 0.020, -289, 0.030, 100.0, 100.0, 5000.0}, // AUDITORIUM
	{-1000, -500, 0.0, 3.92, 0.70, -1230, 0.020, -2, 0.029, 100.0, 100.0, 5000.0}, // CONCERTHALL
	{-1000, 0, 0.0, 2.91, 1.30, -602, 0.015, -302, 0.022, 100.0, 100.0, 5000.0}, // CAVE
	{-1000, -698, 0.0, 7.24, 0.33, -1166, 0.020, 16, 0.030, 100.0, 100.0, 5000.0}, // ARENA
	{-1000, -1000, 0.0, 10.05, 0.23, -602, 0.020, 198, 0.030, 100.0, 100.0, 5000.0}, // HANGAR
	{-1000, -4000, 0.0, 0.30, 0.10, -1831, 0.002, -1630, 0.030, 100.0, 100.0, 5000.0}, // CARPETEDHALLWAY
	{-1000, -300, 0.0, 1.49, 0.59, -1219, 0.007, 441, 0.011, 100.0, 100.0, 5000.0}, // HALLWAY
	{-1000, -237, 0.0, 2.70, 0.79, -1214, 0.013, 395, 0.020, 100.0, 100.0, 5000.0}, // STONECORRIDOR
	{-1000, -270, 0.0, 1.49, 0.86, -1204, 0.007, -4, 0.011, 100.0, 100.0, 5000.0}, // ALLEY
	{-1000, -3300, 0.0, 1.49, 0.54, -2560, 0.162, -613, 0.088, 79.0, 100.0, 5000.0}, // FOREST
	{-1000, -800, 0.0, 1.49, 0.67, -2273, 0.007, -2217, 0.011, 50.0, 100.0, 5000.0}, // CITY
	{-1000, -2500, 0.0, 1.49, 0.21, -2780, 0.300, -2014, 0.100, 27.0, 100.0, 5000.0}, // MOUNTAINS
	{-1000, -1000, 0.0, 1.49, 0.83, -10000, 0.061, 500, 0.025, 100.0, 100.0, 5000.0}, // QUARRY
	{-1000, -2000, 0.0, 1.49, 0.50, -2466, 0.179, -2514, 0.100, 21.0, 100.0, 5000.0}, // PLAIN
	{-1000, 0, 0.0, 1.65, 1.50, -1363, 0.008, -1153, 0.012, 100.0, 100.0, 5000.0}, // PARKINGLOT
	{-1000, -1000, 0.0, 2.81, 0.14, 429, 0.014, 648, 0.021, 80.0, 60.0, 5000.0}, // SEWERPIPE
	{-1000, -4000, 0.0, 1.49, 0.10, -449, 0.007, 1700, 0.011, 100.0, 100.0, 5000.0}, // UNDERWATER
	{-1000, -600, 0.0, 1.10, 0.83, -400, 0.005, 500, 0.010, 100.0, 100.0, 5000.0}, // SMALLROOM
	{-1000, -600, 0.0, 1.30, 0.83, -1000, 0.010, -200, 0.020, 100.0, 100.0, 5000.0}, // MEDIUMROOM
	{-1000, -600, 0.0, 1.50, 0.83, -1600, 0.020, -1000, 0.040, 100.0, 100.0, 5000.0}, // LARGEROOM
	{-1000, -600, 0.0, 1.80, 0.70, -1300, 0.015, -800, 0.030, 100.0, 100.0, 5000.0}, // MEDIUMHALL
	{-1000, -600, 0.0, 1.80, 0.70, -2000, 0.030, -1400, 0.060, 100.0, 100.0, 5000.0}, // LARGEHALL
	{-1000, -200, 0.0, 1.30, 0.90, 0, 0.002, 0, 0.010, 100.0, 75.0, 5000.0}, // PLATE
}
rvb_preset :: proc(b: ^Ds_Buf, preset: u32) {
	b.reverb_preset = preset
	b.reverb = transmute([DS_REVERB_WORDS]u32)DS_REVERB_PRESETS[preset]
}

Rvb_SetAllParameters :: proc() {
	b := ds_buf_of(arg(0))
	mem.copy(&b.reverb, x86.ptr(arg(1)), DS_REVERB_WORDS * 4)
	ret(2, DS_OK)
}

Rvb_GetAllParameters :: proc() {
	b := ds_buf_of(arg(0))
	mem.copy(x86.ptr(arg(1)), &b.reverb, DS_REVERB_WORDS * 4)
	ret(2, DS_OK)
}

Rvb_SetPreset :: proc() {
	if arg(1) >= len(DS_REVERB_PRESETS) {
		ds_invalid("SetPreset", 2, arg(1))
		return
	}
	rvb_preset(ds_buf_of(arg(0)), arg(1))
	ret(2, DS_OK)
}

Rvb_GetPreset :: proc() {x86.wr32(arg(1), ds_buf_of(arg(0)).reverb_preset); ret(2, DS_OK)}
Rvb_SetQuality :: proc() {ds_buf_of(arg(0)).reverb_quality = arg(1); ret(2, DS_OK)}
Rvb_GetQuality :: proc() {x86.wr32(arg(1), ds_buf_of(arg(0)).reverb_quality); ret(2, DS_OK)}
