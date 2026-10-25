// PE loader: maps JadeEmpire.exe at its fixed base and binds every import to
// an HLE pseudo-address (x86.HLE_BASE + slot * 4).
package win32

import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../x86"

Image :: struct {
	base:  u32,
	entry: u32,
	size:  u32,
}

le16 :: proc(b: []u8, o: int) -> u32 {return u32(b[o]) | u32(b[o + 1]) << 8}
le32 :: proc(b: []u8, o: int) -> u32 {return le16(b, o) | le16(b, o + 2) << 16}

// The exe's code, x86.TEXT_LO up to x86.TEXT_HI as loaded, read from the file
// without mapping it; nil when the file is not a 32-bit x86 PE. The unpacked
// Steam exe and the GOG exe differ in their headers and section layout, not in
// this range.
exe_text :: proc(path: string, allocator := context.allocator) -> []u8 {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(data) < 0x400 || data[0] != 'M' || data[1] != 'Z' do return nil
	pe := int(le32(data, 0x3c))
	if pe + 24 > len(data) || le32(data, pe) != 0x4550 || le16(data, pe + 4) != 0x14c do return nil
	opt := pe + 24
	base := le32(data, opt + 28)
	text := make([]u8, x86.TEXT_HI - x86.TEXT_LO, allocator)
	sec := opt + int(le16(data, pe + 20))
	for i in 0 ..< int(le16(data, pe + 6)) {
		s := sec + i * 40
		lo := i64(base) + i64(le32(data, s + 12))
		raw, n := int(le32(data, s + 20)), int(le32(data, s + 16))
		if raw > len(data) do continue
		n = min(n, len(data) - raw)
		a, b := max(lo, x86.TEXT_LO), min(lo + i64(n), x86.TEXT_HI)
		if a < b do copy(text[a - x86.TEXT_LO:b - x86.TEXT_LO], data[raw + int(a - lo):raw + int(b - lo)])
	}
	return text
}

// XXH3 of exe_text for the build the port is made from: the GOG exe and the
// unpacked Steam exe. The packed Steam exe does not match.
EXE_TEXT_HASH :: 0x67f40e0206ba4295

// Names a game folder's exe may have, in the order they are tried: the
// unpacked Steam copy first, since the Steam folder also holds the packed
// original under the plain name.
EXE_NAMES :: [?]string{"JadeEmpire.unpacked.exe", "JadeEmpire.exe"}

// The first EXE_NAMES file in game whose code is the supported build's, or
// false after printing what was found instead.
exe_find :: proc(game: string, allocator := context.allocator) -> (string, bool) {
	for name in EXE_NAMES {
		path, _ := filepath.join({game, name}, allocator)
		if !os.exists(path) do continue
		text := exe_text(path, context.temp_allocator)
		if text != nil && xxhash.XXH3_64(text) == EXE_TEXT_HASH do return path, true
		fmt.eprintfln("%s is not the supported Jade Empire build, or is still packed", path)
	}
	fmt.eprintfln("no usable JadeEmpire.exe in %s. GOG: the installed one works as is. Steam: unpack it to JadeEmpire.unpacked.exe beside it (README).", game)
	return "", false
}

load_pe :: proc(path: string) -> Image {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		x86.fatal("cannot read %s: %v", path, err)
	}
	defer delete(data)
	if len(data) < 0x400 || data[0] != 'M' || data[1] != 'Z' {
		x86.fatal("%s is not a PE file", path)
	}
	pe := int(le32(data, 0x3c))
	if le32(data, pe) != 0x4550 || le16(data, pe + 4) != 0x14c {
		x86.fatal("%s is not a 32-bit x86 PE", path)
	}
	nsec := int(le16(data, pe + 6))
	opt := pe + 24
	opt_size := int(le16(data, pe + 20))
	img := Image {
		base  = le32(data, opt + 28),
		entry = le32(data, opt + 16),
		size  = le32(data, opt + 56),
	}
	img.entry += img.base
	hdr_size := le32(data, opt + 60)
	copy(x86.mem[img.base:img.base + hdr_size], data[:hdr_size])
	sec := opt + opt_size
	for i in 0 ..< nsec {
		s := sec + i * 40
		va := img.base + le32(data, s + 12)
		raw_size := int(le32(data, s + 16))
		raw := int(le32(data, s + 20))
		if raw_size > 0 {
			copy(x86.mem[va:va + u32(raw_size)], data[raw:raw + raw_size])
		}
	}
	bind_imports(img.base, img.base + le32(data, opt + 96 + 8))
	return img
}

// Walks the import directory in guest memory and fills each IAT slot.
bind_imports :: proc(base, dir: u32) {
	missing := 0
	for d := dir; x86.rd32(d + 12) != 0; d += 20 {
		dll := strings.to_lower(x86.cstr(base + x86.rd32(d + 12)), context.temp_allocator)
		names := base + x86.rd32(d)
		iat := base + x86.rd32(d + 16)
		if x86.rd32(d) == 0 {
			names = iat
		}
		for k: u32 = 0; x86.rd32(names + k * 4) != 0; k += 1 {
			t := x86.rd32(names + k * 4)
			name: string
			if t & 0x80000000 != 0 {
				name = fmt.aprintf("%s!#%d", dll, t & 0xffff)
			} else {
				name = fmt.aprintf("%s!%s", dll, x86.cstr(base + t + 2))
			}
			addr, ok := hle_bind(name)
			if !ok {
				missing += 1
			}
			x86.wr32(iat + k * 4, addr)
		}
	}
	fmt.eprintf("win32: %d imports without an HLE implementation\n", missing)
}
