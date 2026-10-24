// PE loader: maps JadeEmpire.exe at its fixed base and binds every import to
// an HLE pseudo-address (x86.HLE_BASE + slot * 4).
package win32

import "core:fmt"
import "core:os"
import "core:strings"
import "../x86"

Image :: struct {
	base:  u32,
	entry: u32,
	size:  u32,
}

le16 :: proc(b: []u8, o: int) -> u32 {return u32(b[o]) | u32(b[o + 1]) << 8}
le32 :: proc(b: []u8, o: int) -> u32 {return le16(b, o) | le16(b, o + 2) << 16}

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
