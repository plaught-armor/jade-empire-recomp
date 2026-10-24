// The exe mapped as it loads: headers and section raw data at their virtual
// addresses, as pefile's get_memory_mapped_image lays them out, with the
// import table read out.
package pe

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strings"

Image :: struct {
	base: u32,
	data: []u8, // the image from base
	iat:  map[u32]string, // IAT slot -> dll!name, the dll lowercased
}

le32 :: proc(b: []u8, o: int) -> u32 {
	v, ok := endian.get_u32(b[o:], .Little)
	assert(ok)
	return v
}

le16 :: proc(b: []u8, o: int) -> u16 {
	v, ok := endian.get_u16(b[o:], .Little)
	assert(ok)
	return v
}

cstr_at :: proc(b: []u8, o: int) -> string {
	n := 0
	for b[o + n] != 0 do n += 1
	return string(b[o:o + n])
}

load :: proc(path: string) -> (img: Image) {
	file, err := os.read_entire_file(path, context.allocator)
	fmt.assertf(err == nil, "cannot read %s: %v", path, err)
	pe := int(le32(file, 0x3c))
	assert(le32(file, pe) == 0x4550, "not a PE file")
	nsec := int(le16(file, pe + 6))
	opt := pe + 24
	img.base = le32(file, opt + 28)
	hdrs := int(le32(file, opt + 60))
	secs := opt + int(le16(file, pe + 20))
	size := hdrs
	for k in 0 ..< nsec {
		s := secs + 40 * k
		size = max(size, int(le32(file, s + 12)) + int(le32(file, s + 16)))
	}
	data := make([]u8, size)
	copy(data, file[:hdrs])
	for k in 0 ..< nsec {
		s := secs + 40 * k
		va, raw, ptr := int(le32(file, s + 12)), int(le32(file, s + 16)), int(le32(file, s + 20))
		copy(data[va:va + raw], file[ptr:ptr + raw])
	}
	img.data = data
	// The import directory, data directory 1.
	imp := int(le32(data, opt + 104))
	for d := imp; le32(data, d + 12) != 0; d += 20 {
		dll := strings.to_lower(cstr_at(data, int(le32(data, d + 12))))
		oft, ft := int(le32(data, d)), int(le32(data, d + 16))
		names := oft != 0 ? oft : ft
		for k := 0; le32(data, names + 4 * k) != 0; k += 1 {
			t := le32(data, names + 4 * k)
			name := t & 0x8000_0000 != 0 ? fmt.aprintf("ord%d", t & 0xffff) : cstr_at(data, int(t) + 2)
			img.iat[img.base + u32(ft + 4 * k)] = fmt.aprintf("%s!%s", dll, name)
		}
	}
	return
}

// The word at va, or false outside the image.
u32_at :: proc(img: Image, va: i64) -> (u32, bool) {
	o := va - i64(img.base)
	if o < 0 || o + 4 > i64(len(img.data)) do return 0, false
	return le32(img.data, int(o)), true
}
