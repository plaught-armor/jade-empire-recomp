// S3TC (DXT1/3/5) block codec for D3DX mip generation on compressed
// textures. The encoder is a bounding-box fit (endpoints at the per-channel
// min/max inset by 1/16 of the range, nearest-palette indices): fast and
// adequate for small mip levels, not a quality encoder.
package win32

Rgba :: [4]u8

Dxt :: enum {DXT1, DXT3, DXT5}

dxt_kind :: proc(format: u32) -> Dxt {
	switch format {
	case D3DFMT_DXT1: return .DXT1
	case D3DFMT_DXT2, D3DFMT_DXT3: return .DXT3
	}
	return .DXT5
}

dxt_565_to :: proc(c: u16) -> Rgba {
	r, g, b := u32(c >> 11) & 31, u32(c >> 5) & 63, u32(c) & 31
	return {u8(r << 3 | r >> 2), u8(g << 2 | g >> 4), u8(b << 3 | b >> 2), 255}
}

dxt_to_565 :: proc(c: Rgba) -> u16 {
	return u16(u32(c.r) * 31 / 255) << 11 | u16(u32(c.g) * 63 / 255) << 5 | u16(u32(c.b) * 31 / 255)
}

dxt_mix :: proc(a, b: Rgba, wa, wb, d: u32) -> (o: Rgba) {
	for i in 0 ..< 4 {o[i] = u8((u32(a[i]) * wa + u32(b[i]) * wb) / d)}
	return
}

dxt_color_palette :: proc(c0, c1: u16, four: bool) -> (p: [4]Rgba) {
	p[0], p[1] = dxt_565_to(c0), dxt_565_to(c1)
	if four {
		p[2], p[3] = dxt_mix(p[0], p[1], 2, 1, 3), dxt_mix(p[0], p[1], 1, 2, 3)
	} else {
		p[2], p[3] = dxt_mix(p[0], p[1], 1, 1, 2), {0, 0, 0, 0}
	}
	return
}

dxt_alpha_palette :: proc(a0, a1: u8) -> (p: [8]u8) {
	p[0], p[1] = a0, a1
	if a0 > a1 {
		for i in 1 ..< u32(7) {p[i + 1] = u8(((7 - i) * u32(a0) + i * u32(a1)) / 7)}
	} else {
		for i in 1 ..< u32(5) {p[i + 1] = u8(((5 - i) * u32(a0) + i * u32(a1)) / 5)}
		p[6], p[7] = 0, 255
	}
	return
}

// Decodes one block at b into px (row-major 4x4).
dxt_decode :: proc(k: Dxt, b: []u8, px: ^[16]Rgba) {
	cb := b[8:] if k != .DXT1 else b
	c0, c1 := u16(cb[0]) | u16(cb[1]) << 8, u16(cb[2]) | u16(cb[3]) << 8
	pal := dxt_color_palette(c0, c1, k != .DXT1 || c0 > c1)
	bits := u32(cb[4]) | u32(cb[5]) << 8 | u32(cb[6]) << 16 | u32(cb[7]) << 24
	for i in 0 ..< 16 {px[i] = pal[(bits >> (2 * u32(i))) & 3]}
	switch k {
	case .DXT1:
	case .DXT3:
		for i in 0 ..< 16 {
			a := (b[i / 2] >> (4 * u8(i & 1))) & 15
			px[i].a = a << 4 | a
		}
	case .DXT5:
		ap := dxt_alpha_palette(b[0], b[1])
		ab: u64
		for j in 0 ..< 6 {ab |= u64(b[2 + j]) << (8 * u64(j))}
		for i in 0 ..< 16 {px[i].a = ap[(ab >> (3 * u64(i))) & 7]}
	}
}

dxt_dist :: proc(a, b: Rgba) -> i32 {
	d: i32
	for i in 0 ..< 3 {
		e := i32(a[i]) - i32(b[i])
		d += e * e
	}
	return d
}

// Color half of a block: 8 bytes at out.
dxt_encode_color :: proc(px: ^[16]Rgba, out: []u8, allow_transparent: bool) {
	lo, hi := Rgba{255, 255, 255, 0}, Rgba{0, 0, 0, 0}
	transparent := false
	for p in px {
		if allow_transparent && p.a < 128 {transparent = true; continue}
		for i in 0 ..< 3 {lo[i], hi[i] = min(lo[i], p[i]), max(hi[i], p[i])}
	}
	for i in 0 ..< 3 {
		if lo[i] > hi[i] {lo[i], hi[i] = 0, 0} // every texel transparent
		inset := (hi[i] - lo[i]) / 16
		lo[i], hi[i] = lo[i] + inset, hi[i] - inset
	}
	c0, c1 := dxt_to_565(hi), dxt_to_565(lo)
	// four-color mode needs c0 > c1, three-color (transparent index 3) c0 <= c1
	if transparent == (c0 > c1) {c0, c1 = c1, c0}
	pal := dxt_color_palette(c0, c1, c0 > c1)
	bits: u32
	for p, i in px {
		best: u32 = 3 if transparent && p.a < 128 else 0
		if best != 3 {
			n: u32 = c0 > c1 ? 4 : 3
			for j in 1 ..< n {if dxt_dist(p, pal[j]) < dxt_dist(p, pal[best]) {best = j}}
		}
		bits |= best << (2 * u32(i))
	}
	out[0], out[1], out[2], out[3] = u8(c0), u8(c0 >> 8), u8(c1), u8(c1 >> 8)
	for j in 0 ..< 4 {out[4 + j] = u8(bits >> (8 * u32(j)))}
}

dxt_encode_alpha5 :: proc(px: ^[16]Rgba, out: []u8) {
	a0, a1: u8 = 0, 255
	for p in px {a0, a1 = max(a0, p.a), min(a1, p.a)}
	ab: u64
	if a0 != a1 {
		pal := dxt_alpha_palette(a0, a1)
		for p, i in px {
			best: u64 = 0
			for j in 1 ..< u64(8) {
				if abs(i32(p.a) - i32(pal[j])) < abs(i32(p.a) - i32(pal[best])) {best = j}
			}
			ab |= best << (3 * u64(i))
		}
	}
	out[0], out[1] = a0, a1
	for j in 0 ..< 6 {out[2 + j] = u8(ab >> (8 * u64(j)))}
}

dxt_encode :: proc(k: Dxt, px: ^[16]Rgba, out: []u8) {
	switch k {
	case .DXT1:
		dxt_encode_color(px, out, true)
	case .DXT3:
		for i in 0 ..< 8 {
			lo, hi := (u32(px[2 * i].a) * 15 + 127) / 255, (u32(px[2 * i + 1].a) * 15 + 127) / 255
			out[i] = u8(lo | hi << 4)
		}
		dxt_encode_color(px, out[8:], false)
	case .DXT5:
		dxt_encode_alpha5(px, out)
		dxt_encode_color(px, out[8:], false)
	}
}

// Whole-level conversions; w, h in texels, data in D3D block order.
dxt_decode_level :: proc(k: Dxt, src: []u8, w, h: u32, dst: []Rgba) {
	bs: u32 = k == .DXT1 ? 8 : 16
	bw := max(1, (w + 3) / 4)
	for by in 0 ..< max(1, (h + 3) / 4) {
		for bx in 0 ..< bw {
			px: [16]Rgba
			o := (by * bw + bx) * bs
			dxt_decode(k, src[o:o + bs], &px)
			for i in 0 ..< u32(16) {
				x, y := bx * 4 + i % 4, by * 4 + i / 4
				if x < w && y < h {dst[y * w + x] = px[i]}
			}
		}
	}
}

dxt_encode_level :: proc(k: Dxt, src: []Rgba, w, h: u32, dst: []u8) {
	bs: u32 = k == .DXT1 ? 8 : 16
	bw := max(1, (w + 3) / 4)
	for by in 0 ..< max(1, (h + 3) / 4) {
		for bx in 0 ..< bw {
			px: [16]Rgba
			for i in 0 ..< u32(16) { // edge blocks repeat the last row/column
				x, y := min(bx * 4 + i % 4, w - 1), min(by * 4 + i / 4, h - 1)
				px[i] = src[y * w + x]
			}
			o := (by * bw + bx) * bs
			dxt_encode(k, &px, dst[o:o + bs])
		}
	}
}

// 2x2 box reduction of src (w x h) into dst (max(1, w/2) x max(1, h/2)).
rgba_halve :: proc(src: []Rgba, w, h: u32, dst: []Rgba) {
	dw, dh := max(1, w / 2), max(1, h / 2)
	for y in 0 ..< dh {
		for x in 0 ..< dw {
			x0, y0 := min(2 * x, w - 1), min(2 * y, h - 1)
			x1, y1 := min(2 * x + 1, w - 1), min(2 * y + 1, h - 1)
			s: [4]u32
			for p in ([4]Rgba{src[y0 * w + x0], src[y0 * w + x1], src[y1 * w + x0], src[y1 * w + x1]}) {
				for i in 0 ..< 4 {s[i] += u32(p[i])}
			}
			for i in 0 ..< 4 {dst[y * dw + x][i] = u8((s[i] + 2) / 4)}
		}
	}
}
