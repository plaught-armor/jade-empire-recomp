// The I3DL2 reverb effect's DSP. The game sets the effect on every 3D sound
// buffer and gives each the parameters of the sound environment the player
// stands in when the sound starts (exosoundbank, 0x674c70). The effect is
// linear and comes before the buffer's volume, 3D gains and pan, so a sound's
// reverb panned by its gains is the reverb of its panned signal: the buffers
// sharing parameters send their mixed left and right into one bus, and each
// bus runs the reverb once per channel. A bus is kept while its tail rings.
//
// The model: the send is low-passed by lRoomHF at flHFReference and scaled by
// lRoom; four early reflection taps start flReflectionsDelay later at
// lReflections; the late tail starts flReverbDelay after them, through four
// allpasses (flDiffusion) into an eight-line feedback delay network (line
// lengths by flDensity) whose lines decay over flDecayTime, high frequencies
// over flDecayTime * flDecayHFRatio, at lReverb. Output is the wet signal
// only; the buffer's dry signal is mixed as before.
// WHY: docs/hle.md §12
package win32

import "core:math"
import "core:simd"

RVB_BUSES :: 4
RVB_PRE :: 1 << 15 // frames of send kept; reflections and late delays reach 0.4 s
RVB_LINE :: 1 << 12 // frames per tail line; the longest is 3.9 s / 48 kHz scaled
RVB_AP :: 1 << 9 // frames per allpass
RVB_LINES :: 8

Lanes :: #simd[RVB_LINES]f32

// Line lengths at full density, and allpass lengths, in milliseconds.
@(private = "file")
LINE_MS := [RVB_LINES]f32{37.3, 41.9, 47.3, 53.1, 59.3, 66.7, 73.1, 79.7}
@(private = "file")
AP_MS := [4]f32{4.3, 5.9, 7.7, 10.1}
// Early reflection taps after flReflectionsDelay, in milliseconds, and gains.
@(private = "file")
TAP_MS := [4]f32{0, 4.1, 7.9, 12.3}
@(private = "file")
TAP_GAIN := [4]f32{0.6, 0.5, 0.45, 0.4}
// Output signs of the lines, so the sum does not favour the matrix's first row.
@(private = "file")
LINE_SIGN :: Lanes{1, -1, 1, -1, 1, -1, 1, -1}

// One bus's reverb state for one channel.
@(private = "file")
Rvb_Chan :: struct {
	lp:   f32, // the room HF low-pass
	pre:  [RVB_PRE]f32,
	ap:   [4][RVB_AP]f32,
	line: [RVB_LINES][RVB_LINE]f32,
	damp: Lanes, // per line, the decay HF low-pass
}

Rvb_Bus :: struct {
	key:      [DS_REVERB_WORDS]u32, // the parameters, as the guest set them
	used:     bool,
	sent:     bool, // a buffer sent to it this chunk
	quiet:    int, // frames since a send
	ring:     int, // frames its tail rings after the last send
	send:     [DS_CHUNK * 2]f32,
	// Derived from key.
	lp_a:     f32,
	room:     f32,
	refl:     [4]f32,
	refl_at:  [4]int,
	late_at:  int,
	late:     f32,
	ap_k:     f32,
	ap_at:    [4]int,
	line_at:  [RVB_LINES]int,
	gain:     Lanes, // per line, decay at low frequencies
	damp_a:   Lanes, // per line, the decay HF low-pass coefficient
	w:        int, // the rings' write position
	ch:       [2]Rvb_Chan,
}

rvb_buses: [RVB_BUSES]Rvb_Bus
rvb_gain: f32 = 1 // JE_REVERB's wet level; 0 = no reverb, as before the effect was mixed

// The bus for parameters key, made if none has them. With every bus in use
// the one quiet longest is taken over.
rvb_bus :: proc(key: ^[DS_REVERB_WORDS]u32) -> ^Rvb_Bus {
	free := -1
	for &b, i in rvb_buses {
		if b.used && b.key == key^ {return &b}
		if free < 0 || !b.used && rvb_buses[free].used || b.used == rvb_buses[free].used && b.quiet > rvb_buses[free].quiet {free = i}
	}
	b := &rvb_buses[free]
	b^ = {}
	b.key, b.used = key^, true
	rvb_derive(b)
	return b
}

@(private = "file")
mb :: proc(v: u32) -> f32 {return math.pow(10, f32(i32(v)) / 2000)}

@(private = "file")
pf :: proc(v: u32) -> f32 {return transmute(f32)v}

@(private = "file")
rvb_derive :: proc(b: ^Rvb_Bus) {
	k := &b.key
	ms :: proc(v: f32) -> int {return int(v * DS_RATE / 1000 + 0.5)}
	decay := clamp(pf(k[3]), 0.1, 20)
	hf_ratio := clamp(pf(k[4]), 0.1, 1) // a tail brighter than its lows is kept flat
	refl_delay, late_delay := clamp(pf(k[6]), 0, 0.3), clamp(pf(k[8]), 0, 0.1)
	diffusion, density := clamp(pf(k[9]), 0, 100) / 100, clamp(pf(k[10]), 0, 100) / 100
	w := 2 * math.PI * clamp(pf(k[11]), 20, 20000) / DS_RATE
	b.lp_a = lp_coeff(mb(k[1]), w)
	b.room = mb(k[0])
	for i in 0 ..< 4 {
		b.refl[i] = mb(k[5]) * TAP_GAIN[i]
		b.refl_at[i] = int(refl_delay * DS_RATE) + ms(TAP_MS[i])
	}
	b.late_at = int((refl_delay + late_delay) * DS_RATE)
	b.late = mb(k[7]) / math.sqrt(f32(RVB_LINES))
	b.ap_k = 0.65 * diffusion
	for i in 0 ..< 4 {b.ap_at[i] = ms(AP_MS[i])}
	scale := 0.5 + 0.5 * density
	gain, damp_a: [RVB_LINES]f32
	for i in 0 ..< RVB_LINES {
		n := ms(LINE_MS[i] * scale)
		b.line_at[i] = n
		t := f32(n) / DS_RATE
		g := math.pow(10, -3 * t / decay)
		gain[i] = g
		damp_a[i] = lp_coeff(math.pow(10, -3 * t / (decay * hf_ratio)) / g, w)
	}
	b.gain, b.damp_a = transmute(Lanes)gain, transmute(Lanes)damp_a
	b.ring = int((refl_delay + late_delay + decay * 1.2) * DS_RATE)
}

// The one-pole low-pass y += (1 - a) (x - y) whose gain at w radians a
// sample is g.
@(private = "file")
lp_coeff :: proc(g, w: f32) -> f32 {
	if g >= 0.9999 {return 0}
	g2, c := g * g, math.cos(w)
	return (1 - g2 * c - math.sqrt(max(0, 2 * g2 * (1 - c) - g2 * g2 * (1 - c * c)))) / (1 - g2)
}

// Adds every ringing bus's wet signal to out and clears the sends.
rvb_chunk :: proc(out: ^[DS_CHUNK * 2]f32) {
	for &b in rvb_buses {
		if !b.used {continue}
		if b.sent {b.quiet = 0} else {b.quiet += DS_CHUNK}
		if b.quiet > b.ring {
			b.used = false
			continue
		}
		rvb_run(&b, out)
		b.send = {}
		b.sent = false
	}
}

@(private = "file")
rvb_run :: proc(b: ^Rvb_Bus, out: ^[DS_CHUNK * 2]f32) #no_bounds_check {
	w := b.w
	for i in 0 ..< DS_CHUNK {
		for c in 0 ..< 2 {
			s := &b.ch[c]
			s.lp += (1 - b.lp_a) * (b.send[2 * i + c] - s.lp)
			s.pre[w & (RVB_PRE - 1)] = s.lp * b.room
			wet: f32
			for t in 0 ..< 4 {wet += s.pre[(w - b.refl_at[t]) & (RVB_PRE - 1)] * b.refl[t]}
			x := s.pre[(w - b.late_at) & (RVB_PRE - 1)] * b.late
			for a in 0 ..< 4 {
				d := s.ap[a][(w - b.ap_at[a]) & (RVB_AP - 1)]
				v := x + b.ap_k * d
				s.ap[a][w & (RVB_AP - 1)] = v
				x = d - b.ap_k * v
			}
			o: [RVB_LINES]f32
			for l in 0 ..< RVB_LINES {o[l] = s.line[l][(w - b.line_at[l]) & (RVB_LINE - 1)]}
			ov := transmute(Lanes)o
			wet += simd.reduce_add_ordered(ov * LINE_SIGN)
			s.damp += (1 - b.damp_a) * (ov - s.damp)
			fb := hadamard(s.damp * b.gain) + Lanes(x)
			f := transmute([RVB_LINES]f32)fb
			for l in 0 ..< RVB_LINES {s.line[l][w & (RVB_LINE - 1)] = f[l]}
			out[2 * i + c] += wet * rvb_gain
		}
		w += 1
	}
	b.w = w & (RVB_PRE - 1)
}

// The 8-point Hadamard transform over sqrt(8): lossless mixing of the lines.
@(private = "file")
hadamard :: #force_inline proc "contextless" (v: Lanes) -> Lanes {
	S1 :: Lanes{1, -1, 1, -1, 1, -1, 1, -1}
	S2 :: Lanes{1, 1, -1, -1, 1, 1, -1, -1}
	S4 :: Lanes{1, 1, 1, 1, -1, -1, -1, -1}
	v := v
	v = v * S1 + simd.swizzle(v, 1, 0, 3, 2, 5, 4, 7, 6)
	v = v * S2 + simd.swizzle(v, 2, 3, 0, 1, 6, 7, 4, 5)
	v = v * S4 + simd.swizzle(v, 4, 5, 6, 7, 0, 1, 2, 3)
	return v * (1 / math.SQRT_TWO / 2)
}
