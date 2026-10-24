// DirectSound software mixer. Runs on the main thread: ds_pump tops the SDL
// stream up to DS_QUEUE frames, so buffer play cursors advance at the rate
// the device consumes audio (under lockstep, the virtual clock's). Callers: every cursor/status/play/stop call and
// Dev_Present. Output is 48 kHz stereo f32; buffers resample linearly.
//
// Gains: volume and pan are hundredths of a dB (10^(cB/2000)). A mono buffer
// with CTRL3D gets the D3D inverse-distance rolloff
// min / (min + rolloff * (clamp(d, min, max) - min)), the cone attenuation,
// and a constant-power pan from its listener-space direction. No doppler.
package win32

import "core:math"
import "core:math/linalg"
import "core:time"
import sdl "vendor:sdl3"
import "../x86"

DS_RATE :: 48000
DS_CHUNK :: 256 // frames mixed per step
DS_QUEUE :: 2400 // target queued frames, 50 ms
DS_PUMP_STEPS_MAX :: DS_QUEUE / DS_CHUNK + 1

ds_stream: ^sdl.AudioStream
ds_dev: sdl.AudioDeviceID // the playback device ds_stream is bound to

// Under lockstep the mix follows the virtual clock instead: the play
// cursors the game reads must not depend on a peer's audio device. A chunk
// that finds DS_LOCK_QUEUE frames already queued is dropped.
// WHY: docs/hle.md §10
DS_LOCK_QUEUE :: 2 * DS_QUEUE
ds_mixed: i64 // frames mixed under lockstep

ds_pump :: proc() {
	if ds_stream == nil {return}
	if lockstep {
		due := i64(vclock) * DS_RATE / i64(time.Second)
		for ds_mixed + DS_CHUNK <= due {
			ds_mixed += DS_CHUNK
			ds_chunk(!lock_fast && int(ds_queued()) < DS_LOCK_QUEUE * 2 * size_of(f32))
		}
		return
	}
	for _ in 0 ..< DS_PUMP_STEPS_MAX {
		if int(ds_queued()) >= DS_QUEUE * 2 * size_of(f32) {return}
		ds_chunk(true)
	}
}

ds_queued :: proc() -> i32 {
	q := sdl.GetAudioStreamQueued(ds_stream)
	if q < 0 {x86.fatal("dsound: audio stream: %s", sdl.GetError())}
	return q
}

// Online, the joiner shows player 2's camera, not the game's
// (native/coop_camera.odin), and hears from it: the mixer's listener is the
// game's carried by the rigid motion from the game's camera to the shown one,
// x' = rot * (x - from) + to. The guest's listener stays as the guest set it,
// and gains move no play cursor, so both peers' games stay the same.
Ds_View :: struct {
	on:       bool,
	rot:      matrix[3, 3]f32,
	from, to: [3]f32,
	// The reverb parameters of the sound environment at player 2.
	reverb:   [DS_REVERB_WORDS]u32,
}
ds_view: Ds_View
ds_ear: Ds3d_Listener // the listener a chunk is mixed for

// Mixes DS_CHUNK frames of the playing buffers, onto the stream if queue.
ds_chunk :: proc(queue: bool) {
	out: [DS_CHUNK * 2]f32
	ds_ear = ds_listener
	if ds_view.on {
		ds_ear.pos = ds_view.rot * (ds_listener.pos - ds_view.from) + ds_view.to
		ds_ear.front = ds_view.rot * ds_listener.front
		ds_ear.top = ds_view.rot * ds_listener.top
	}
	for &b in ds_bufs {
		if b.live && b.playing && !b.primary {ds_mix(&b, &out)}
	}
	rvb_chunk(&out)
	if !queue {return}
	for &s in out {s = clamp(s, -1, 1)}
	if !sdl.PutAudioStreamData(ds_stream, &out, size_of(out)) {
		x86.fatal("dsound: queue audio: %s", sdl.GetError())
	}
}

// Frame i of b as (left, right) in [-1, 1).
ds_sample :: #force_inline proc(b: ^Ds_Buf, i: u32) -> (l, r: f32) {
	a := b.data + i * b.fmt.align
	if b.fmt.bits == 16 {
		l = f32(i16(x86.rd16(a))) / 32768
		r = b.fmt.ch == 2 ? f32(i16(x86.rd16(a + 2))) / 32768 : l
	} else {
		l = (f32(x86.rd8(a)) - 128) / 128
		r = b.fmt.ch == 2 ? (f32(x86.rd8(a + 1)) - 128) / 128 : l
	}
	return
}

ds_mix :: proc(b: ^Ds_Buf, out: ^[DS_CHUNK * 2]f32) {
	frames := b.size / b.fmt.align
	step := f64(ds_rate(b)) / DS_RATE
	gl, gr := ds_gains(b)
	// The reverb's send (dsound_reverb.odin); online, the joiner's is the
	// environment's at player 2.
	send: ^[DS_CHUNK * 2]f32
	if b.has_reverb && rvb_gain > 0 {
		bus := rvb_bus(ds_view.on ? &ds_view.reverb : &b.reverb)
		bus.sent = true
		send = &bus.send
	}
	for i in 0 ..< DS_CHUNK {
		i0 := u32(b.pos)
		t := f32(b.pos - f64(i0))
		i1 := i0 + 1
		if i1 >= frames {i1 = b.looping ? 0 : i0}
		l0, r0 := ds_sample(b, i0)
		l1, r1 := ds_sample(b, i1)
		l, r := (l0 + (l1 - l0) * t) * gl, (r0 + (r1 - r0) * t) * gr
		out[2 * i] += l
		out[2 * i + 1] += r
		if send != nil {
			send[2 * i] += l
			send[2 * i + 1] += r
		}
		b.pos += step
		if b.pos >= f64(frames) {
			if !b.looping {
				b.playing, b.pos = false, 0
				return
			}
			b.pos = math.mod(b.pos, f64(frames))
		}
	}
}

ds_cb :: #force_inline proc(cb: f32) -> f32 {return math.pow(10, cb / 2000)}

ds_gains :: proc(b: ^Ds_Buf) -> (l, r: f32) {
	g := ds_cb(f32(b.vol))
	l, r = g, g
	if b.pan > 0 {l *= ds_cb(f32(-b.pan))}
	if b.pan < 0 {r *= ds_cb(f32(b.pan))}
	if b.flags & DSBCAPS_CTRL3D != 0 && b.fmt.ch == 1 && b.p3d.mode != DS3DMODE_DISABLE {
		g3, s := ds_3d(&b.p3d)
		l *= g3 * min(1, math.sqrt(1 - s))
		r *= g3 * min(1, math.sqrt(1 + s))
	}
	return
}

// World vector w in the listener frame (x right, y up, z front; left-handed).
ds_to_listener :: proc(w: [3]f32) -> [3]f32 {
	f := linalg.normalize0(ds_ear.front)
	rt := linalg.normalize0(linalg.cross(ds_ear.top, f))
	up := linalg.cross(f, rt)
	return {linalg.dot(w, rt), linalg.dot(w, up), linalg.dot(w, f)}
}

// 3D gain and pan s in [-1, 1] (-1 full left) of source p.
ds_3d :: proc(p: ^Ds3d_Buffer) -> (gain, s: f32) {
	rel := p.pos
	if p.mode == 0 { // world space: into the listener frame
		rel = ds_to_listener(p.pos - ds_ear.pos)
	}
	d := linalg.length(rel)
	min_d := max(p.min_d, 1e-6)
	dc := clamp(d, min_d, max(p.max_d, min_d))
	gain = min_d / (min_d + ds_ear.rolloff_f * (dc - min_d))
	if d > 1e-6 {s = clamp(rel.x / d, -1, 1)}
	if p.inside < 360 || p.outside < 360 {gain *= ds_cone(p, rel, d)}
	return
}

// Cone attenuation: the angle between the cone axis and the direction to the
// listener, full inside inside/2, outvol beyond outside/2, linear in cB between.
ds_cone :: proc(p: ^Ds3d_Buffer, rel: [3]f32, d: f32) -> f32 {
	axis := p.orient
	if p.mode == 0 { // the axis is world space; rotate it like the position
		axis = ds_to_listener(p.orient)
	}
	al := linalg.length(axis)
	if d <= 1e-6 || al <= 1e-6 {return 1}
	c := clamp(linalg.dot(axis, -rel) / (al * d), -1, 1)
	ang := math.to_degrees(math.acos(c)) * 2 // full cone angle that just contains the listener
	hi, lo := f32(p.inside), f32(p.outside)
	if ang <= hi {return 1}
	if ang >= lo || lo <= hi {return ds_cb(f32(p.outvol))}
	return ds_cb(f32(p.outvol) * (ang - hi) / (lo - hi))
}
