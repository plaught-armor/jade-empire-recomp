package x86rec

import cs "../capstone"
import "../pe"
import "core:encoding/hex"
import "core:fmt"
import "core:strings"

TEXT_LO :: 0x401000
TEXT_HI :: 0x6E1000
DATA_LO :: 0x6E1000
DATA_HI :: 0x895000
OEP :: 0x6B4923

Patch :: struct {
	va:       u32,
	old, new: string,
}

// Guest byte patches applied before decoding: (va, original bytes, new bytes).
// WHY: docs/recompiler.md §9
PATCHES := [?]Patch {
	// New Game's hideload box: duration 1.5 and 0.25 become -0.999, so the
	// timer dur + 1.0 is about 0.001 and closes the box on its first update.
	{0x5699d9, "0000c03f", "77be7fbf"},
	{0x569a04, "0000803e", "77be7fbf"},
	// CXbInput's per-axis stick deadzone, -6535..6535 on each of left X/Y and
	// right X/Y, becomes 0: the port applies a radial one (win32/pad.odin).
	{0x668481, "79e6", "0000"}, {0x668487, "8719", "0000"},
	{0x6684d5, "79e6", "0000"}, {0x6684dc, "8719", "0000"},
	{0x668521, "79e6", "0000"}, {0x668527, "8719", "0000"},
	{0x66856d, "79e6", "0000"}, {0x668574, "8719", "0000"},
	// CPanelCustomVideo's row label strrefs, nine at 0x75b868, are read from
	// the port's table at 0x00a00000 instead, 30 rows: the game's nine, then
	// the port's video settings (port/src/native/settings.odin, VIDEO_ROWS_N).
	{0x54ee97, "8b14bd68b87500", "8b14bd0000a000"},
	{0x54d4b0, "3b0c8568b87500", "3b0c850000a000"},
	{0x54d849, "3b04ad68b87500", "3b04ad0000a000"},
	{0x54d4bc, "83f809", "83f81e"}, {0x54f293, "83ff09", "83ff1e"},
	// The selection handler gives rows 5 to 7 the value arrows, not row 8
	// (Brightness, a slider): cmp edi,7; jne becomes cmp edi,8; je, so the
	// port's rows get them too.
	{0x54e4aa, "83ff070f85ae000000", "83ff080f84ae000000"},
	// CPanelOptionsCont's rows, five of {strref, default, min, max} at
	// 0x703448, are built from the port's table at 0x00a00100, eighteen
	// rows: the game's five, then the port's pad settings (CONTROL_ROWS_N).
	// Their description strrefs at 0x6ff1fc move to 0x00a00280 likewise. Stepping
	// and the game's config still use its own five.
	{0x574051, "6a05", "6a12"}, {0x574064, "6a05", "6a12"},
	{0x57406f, "be48347000", "be0001a000"},
	{0x574181, "81fe48347000", "81fe0001a000"},
	{0x574296, "817c241c48347000", "817c241c0001a000"},
	{0x5742e6, "83f805", "83f812"},
	{0x57015f, "8b04bdfcf16f00", "8b04bd8002a000"},
	// CEffectLODManager's budget, sized for the Xbox: the prune 0x50f3e0
	// destroys the oldest effects while the weighted count [0x76cadc] is over
	// 10, and the gate 0x50f080 allows optional spawns only while count * 0.1
	// is at most 0.5. The cap becomes 40 and the gate's factor 0.025 (an
	// existing read-only constant), so optional spawns run to 20.
	{0x50f3e0, "833ddcca76000a", "833ddcca760028"},
	{0x50f446, "833ddcca76000a", "833ddcca760028"},
	{0x50f09e, "d80d382f6e00", "d80d60346e00"},
	// DoEvade's bounds, the dots of the dodge direction with the facing and
	// its right against +-cos 45 (doubles 0x6e53c8, 0x6e53c0, shared), read
	// from the port's front, back and two roll bounds at 0x00a00310
	// instead (native/dodge.odin): +-cos 30 for the flips, +-sin 30 for the
	// rolls, so every direction past the flips rolls.
	{0x4c3418, "dc15c8536e00", "dc151003a000"},
	{0x4c354f, "dc1dc0536e00", "dc1d1803a000"},
	{0x4c369d, "dc15c8536e00", "dc152003a000"},
	{0x4c36ee, "dc1dc0536e00", "dc1d2803a000"},
	// The save message's redraw loops after a save, in the main loop
	// (0x4a4ee0) and the save screen's callback (0x556500), run once instead
	// of 17 times: each pass presents a frame, about 280 ms per save.
	{0x4a4ed2, "bf11000000", "bf01000000"},
	{0x5564e7, "be11000000", "be01000000"},
}

// One decoded instruction: capstone's fields this tool reads, with its GPR
// effect (gpr_effect) worked out from capstone's register lists at decode.
Insn :: struct {
	address:        u32,
	size:           u8,
	nops:           u8,
	use, kill, mod: u8,
	bytes:          [16]u8,
	mnemonic:       string,
	op_str:         string,
	ops:            [4]cs.Op,
}

// The mapped exe, PATCHES applied.
img: pe.Image

// Decoded instructions by pc - TEXT_LO: 0 undecoded, -1 no instruction,
// else 1 + an index into the pool. The pool grows by chunks that never
// move, so an ^Insn stays valid.
CHUNK :: 4096
insn_at: []i32
insn_chunks: [dynamic]^[CHUNK]Insn
insn_n: int
mnemonics: map[string]string
// capstone register names by id; "" for none.
reg_names: [256]string

image_load :: proc(path: string) {
	img = pe.load(path)
	data := img.data
	for p in PATCHES {
		o := int(p.va - img.base)
		old, _ := hex.decode(transmute([]u8)p.old)
		nw, _ := hex.decode(transmute([]u8)p.new)
		for b, k in old do fmt.assertf(data[o + k] == b, "patch %x: old bytes differ", p.va)
		copy(data[o:], nw)
	}
	insn_at = make([]i32, TEXT_HI - TEXT_LO)
	assert(cs.open() != 0, "capstone open failed")
	for r in 1 ..< len(reg_names) {
		n := cs.reg_name(u32(r))
		if n != nil do reg_names[r] = strings.clone_from_cstring(n)
	}
}

// The word at va, or false outside the image.
img_u32 :: proc(va: i64) -> (u32, bool) {
	return pe.u32_at(img, va)
}

// The decoded instruction at pc in .text, or nil when it does not decode.
insn :: proc(pc: u32) -> ^Insn {
	assert(TEXT_LO <= pc && pc < TEXT_HI)
	slot := &insn_at[pc - TEXT_LO]
	if slot^ == 0 do slot^ = decode(pc)
	if slot^ < 0 do return nil
	k := int(slot^ - 1)
	return &insn_chunks[k / CHUNK][k % CHUNK]
}

@(private = "file")
decode :: proc(pc: u32) -> i32 {
	@(static) ci: cs.Insn
	o := int(pc - img.base)
	code := img.data[o:min(o + 16, len(img.data))]
	r := cs.decode(raw_data(code), len(code), u64(pc), &ci)
	fmt.assertf(r >= 0, "capstone lists no register accesses at %08x", pc)
	if r == 0 do return -1
	fmt.assertf(ci.op_count <= 4, "%08x: %d operands", pc, ci.op_count)
	m := string(cstring(&ci.mnemonic[0]))
	mn, ok := mnemonics[m]
	if !ok {
		mn = strings.clone(m)
		mnemonics[mn] = mn
	}
	i := Insn {
		address  = ci.address,
		size     = u8(ci.size),
		nops     = ci.op_count,
		bytes    = ci.bytes,
		mnemonic = mn,
		op_str   = strings.clone(string(cstring(&ci.op_str[0]))),
	}
	copy(i.ops[:], ci.ops[:ci.op_count])
	i.use, i.kill, i.mod = gpr_effect(&i, ci.read[:ci.n_read], ci.write[:ci.n_write])
	if insn_n % CHUNK == 0 do append(&insn_chunks, new([CHUNK]Insn))
	insn_chunks[insn_n / CHUNK][insn_n % CHUNK] = i
	insn_n += 1
	return i32(insn_n)
}
