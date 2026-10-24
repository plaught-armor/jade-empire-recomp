// Unpacks a Texmod .tpf: the file is a ZIP XORed with 0x3FA43FA4 (little-
// endian dword), entries encrypted (ZipCrypto) under Texmod's fixed
// password. Writes every entry (texmod.def and the replacement images) flat
// into <out dir>.
// Usage: untpf <file.tpf> <out dir>
// WHY: docs/rendering.md §4
package untpf

import "core:bytes"
import "core:compress/zlib"
import "core:encoding/endian"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"

PASSWORD := [?]u8 {
	0x73, 0x2A, 0x63, 0x7D, 0x5F, 0x0A, 0xA6, 0xBD, 0x7D, 0x65, 0x7E, 0x67, 0x61, 0x2A,
	0x7F, 0x7F, 0x74, 0x61, 0x67, 0x5B, 0x60, 0x70, 0x45, 0x74, 0x5C, 0x22, 0x74, 0x5D,
	0x6E, 0x6A, 0x73, 0x41, 0x77, 0x6E, 0x46, 0x47, 0x77, 0x49, 0x0C, 0x4B, 0x46, 0x6F,
}

le32 :: proc(b: []u8, o: int) -> int {
	v, ok := endian.get_u32(b[o:], .Little)
	assert(ok, "truncated ZIP")
	return int(v)
}

le16 :: proc(b: []u8, o: int) -> int {
	v, ok := endian.get_u16(b[o:], .Little)
	assert(ok, "truncated ZIP")
	return int(v)
}

// The traditional PKWARE cipher's three keys.
Keys :: struct {
	k0, k1, k2: u32,
}

crc_table: [256]u32

crc_byte :: proc(crc: u32, c: u8) -> u32 {
	return crc >> 8 ~ crc_table[(crc ~ u32(c)) & 0xff]
}

update :: proc(k: ^Keys, c: u8) {
	k.k0 = crc_byte(k.k0, c)
	k.k1 = (k.k1 + k.k0 & 0xff) * 134775813 + 1
	k.k2 = crc_byte(k.k2, u8(k.k1 >> 24))
}

decrypt :: proc(k: ^Keys, buf: []u8) {
	for &c in buf {
		t := k.k2 | 2
		c ~= u8((t * (t ~ 1)) >> 8)
		update(k, c)
	}
}

main :: proc() {
	if len(os.args) != 3 {
		fmt.eprintln("usage: untpf <file.tpf> <out dir>")
		os.exit(2)
	}
	for n in 0 ..< u32(256) {
		c := n
		for _ in 0 ..< 8 do c = c & 1 != 0 ? 0xEDB88320 ~ c >> 1 : c >> 1
		crc_table[n] = c
	}
	d, err := os.read_entire_file(os.args[1], context.allocator)
	fmt.assertf(err == nil, "read %s: %v", os.args[1], err)
	key := [4]u8{0xa4, 0x3f, 0xa4, 0x3f}
	for &c, i in d do c ~= key[i & 3]
	// The end of central directory record, searched from the end.
	eocd := -1
	for o := len(d) - 22; o >= 0; o -= 1 {
		if le32(d, o) == 0x06054b50 {
			eocd = o
			break
		}
	}
	assert(eocd >= 0, "no ZIP end record")
	count, cd := le16(d, eocd + 10), le32(d, eocd + 16)
	for _ in 0 ..< count {
		assert(le32(d, cd) == 0x02014b50, "bad central directory entry")
		flags, method := le16(d, cd + 8), le16(d, cd + 10)
		crc, csize, usize := u32(le32(d, cd + 16)), le32(d, cd + 20), le32(d, cd + 24)
		nlen, xlen, clen := le16(d, cd + 28), le16(d, cd + 30), le16(d, cd + 32)
		local := le32(d, cd + 42)
		n := string(d[cd + 46:cd + 46 + nlen])
		cd += 46 + nlen + xlen + clen
		if flags & 0x800 == 0 do for c in transmute([]u8)n do assert(c < 0x80, "non-ASCII cp437 entry name")
		fmt.println(n, usize)
		name := n
		name, _ = strings.replace_all(name, "\\", "/")
		name = name[strings.last_index_byte(name, '/') + 1:]
		assert(name != "" && !strings.contains(name, ".."))
		assert(le32(d, local) == 0x04034b50, "bad local header")
		body := local + 30 + le16(d, local + 26) + le16(d, local + 28)
		data := make([]u8, csize)
		copy(data, d[body:body + csize])
		if flags & 1 != 0 {
			k := Keys{0x12345678, 0x23456789, 0x34567890}
			for c in PASSWORD do update(&k, c)
			decrypt(&k, data)
			// The 12-byte header's last byte checks the password: the CRC's top
			// byte, or the DOS time's when the sizes follow the data.
			check := flags & 8 != 0 ? u8(le16(d, local + 10) >> 8) : u8(crc >> 24)
			assert(data[11] == check, "bad password")
			data = data[12:]
		}
		out: []u8
		switch method {
		case 0:
			out = data
		case 8:
			buf: bytes.Buffer
			zerr := zlib.inflate_from_byte_array_raw(data, &buf, expected_output_size = usize)
			fmt.assertf(zerr == nil, "%s: inflate: %v", n, zerr)
			out = bytes.buffer_to_bytes(&buf)
		case:
			fmt.panicf("%s: compression method %d", n, method)
		}
		fmt.assertf(len(out) == usize && hash.crc32(out) == crc, "%s: bad CRC", n)
		path := strings.concatenate({os.args[2], "/", name})
		werr := os.write_entire_file(path, out)
		fmt.assertf(werr == nil, "write %s: %v", path, werr)
	}
}
