package x86rec

// Odin statements for one instruction (docs/recompiler.md).

import "core:fmt"
import "core:strings"

PACKAGE_INSNS :: 40000
COLD_LABELS :: 2000

// Instructions whose immediate is a count of frames at the game's 30 fps
// (ClampFPS): death-panel delay 0x42b750, a 5-frame update throttle 0x4d5094,
// creature trail and periodic-check intervals 0x4eaa30, 0x4f0800. The lift
// emits x86.frames(imm) instead, the count at the current frame rate.
// WHY: docs/rendering.md §5
FRAME_COUNTS := [?]u32{0x42B776, 0x4D5094, 0x4EAA3C, 0x4EAA43, 0x4F080B, 0x4F0826}

PREFIXES := [?]u8{0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65, 0x66, 0x67, 0xF0, 0xF2, 0xF3}

is_prefix :: proc(b: u8) -> bool {
	for p in PREFIXES do if b == p do return true
	return false
}

is_frame_count :: proc(a: u32) -> bool {
	for p in FRAME_COUNTS do if a == p do return true
	return false
}

size_t :: proc(size: int) -> string {
	switch size {
	case 1: return "u8"
	case 2: return "u16"
	case 4: return "u32"
	case 8: return "u64"
	}
	fmt.panicf("no type of size %d", size)
}

sign :: proc(size: int) -> string {
	switch size {
	case 1: return "0x80"
	case 2: return "0x8000"
	case 4: return "0x80000000"
	}
	fmt.panicf("no sign of size %d", size)
}

stype :: proc(size: int) -> string {
	switch size {
	case 1: return "i8"
	case 2: return "i16"
	case 4: return "i32"
	}
	return "None" // no signed type; a lift that reaches it fails to build
}

hexu :: proc(v: u32) -> string {
	return fmt.aprintf("0x%08x", v)
}

lit :: proc(v: i64, size: int) -> string {
	mask := size >= 8 ? max(u64) : (u64(1) << uint(8 * size)) - 1
	return fmt.aprintf("%s(0x%x)", size_t(size), u64(v) & mask)
}

r16_of :: proc(n: string) -> string {
	switch n {
	case "ax": return "eax"
	case "cx": return "ecx"
	case "dx": return "edx"
	case "bx": return "ebx"
	case "sp": return "esp"
	case "bp": return "ebp"
	case "si": return "esi"
	case "di": return "edi"
	}
	return ""
}

r8l_of :: proc(n: string) -> string {
	switch n {
	case "al": return "eax"
	case "cl": return "ecx"
	case "dl": return "edx"
	case "bl": return "ebx"
	}
	return ""
}

r8h_of :: proc(n: string) -> string {
	switch n {
	case "ah": return "eax"
	case "ch": return "ecx"
	case "dh": return "edx"
	case "bh": return "ebx"
	}
	return ""
}

is_r32 :: proc(n: string) -> bool {
	for r in R32 do if r == n do return true
	return false
}

// One instruction's lift. err is the first Unsupported reason; the
// statements are then discarded.
Lift :: struct {
	i:           ^Insn,
	live:        u8,
	fs:          ^X87, // the run cache, or nil for direct c.fpu access
	s:           [dynamic]string,
	frame_count: bool, // FRAME_COUNTS immediate emitted (see lift_imm)
	err:         string,
	// fuse_next: the next instruction's condition code when it consumes
	// this one's flags, and the flags live after it.
	fuse_cc:     string,
	fuse_after:  u8,
	fused:       string, // the fused condition, when the producer gave one
}

unsupported :: proc(L: ^Lift, msg: string) {
	if L.err == "" do L.err = msg
}

emit :: proc(L: ^Lift, line: string) {
	append(&L.s, line)
}

emitf :: proc(L: ^Lift, f: string, args: ..any) {
	append(&L.s, fmt.aprintf(f, ..args))
}

lift_reg :: proc(r: u32) -> string {
	return reg_names[r]
}

// Literal of immediate op; scaled by x86.frames when the instruction is in
// FRAME_COUNTS.
lift_imm :: proc(L: ^Lift, op: ^Cs_Op, size: int) -> string {
	if is_frame_count(L.i.address) {
		L.frame_count = true
		return fmt.aprintf("x86.frames(%s)", lit(op.imm, size))
	}
	return lit(op.imm, size)
}

lift_r32 :: proc(L: ^Lift, name: string) -> string {
	if !is_r32(name) {
		unsupported(L, strings.concatenate({"address reg ", name}))
		return ""
	}
	return strings.concatenate({"c.", name})
}

lift_ea :: proc(L: ^Lift, op: ^Cs_Op) -> string {
	parts: [dynamic]string
	if op.segment != 0 {
		seg := lift_reg(op.segment)
		if seg == "fs" {
			append(&parts, "c.fs_base")
		} else if seg != "ds" && seg != "es" && seg != "ss" && seg != "cs" {
			unsupported(L, strings.concatenate({"segment ", seg}))
		}
	}
	if op.base != 0 do append(&parts, lift_r32(L, lift_reg(op.base)))
	if op.index != 0 {
		ix := lift_r32(L, lift_reg(op.index))
		append(&parts, op.scale == 1 ? ix : fmt.aprintf("%s * %d", ix, op.scale))
	}
	d := u32(op.disp)
	if len(parts) == 0 do return hexu(d)
	e := strings.join(parts[:], " + ")
	if d != 0 {
		e = d < 0x80000000 ? fmt.aprintf("%s + 0x%x", e, d) : fmt.aprintf("%s - 0x%x", e, -d)
	}
	return e
}

lift_read :: proc(L: ^Lift, op: ^Cs_Op, ea := "") -> string {
	size := int(op.size)
	switch op.type {
	case OP_REG:
		n := lift_reg(op.reg)
		if is_r32(n) do return strings.concatenate({"c.", n})
		if r := r16_of(n); r != "" do return fmt.aprintf("u16(c.%s)", r)
		if r := r8l_of(n); r != "" do return fmt.aprintf("u8(c.%s)", r)
		if r := r8h_of(n); r != "" do return fmt.aprintf("u8(c.%s >> 8)", r)
		unsupported(L, strings.concatenate({"reg ", n}))
		return ""
	case OP_IMM:
		return lift_imm(L, op, size)
	case OP_MEM:
		return fmt.aprintf("x86.rd%d(%s)", size * 8, ea != "" ? ea : lift_ea(L, op))
	}
	unsupported(L, "operand")
	return ""
}

lift_write :: proc(L: ^Lift, op: ^Cs_Op, val: string, ea := "") -> string {
	switch op.type {
	case OP_REG:
		n := lift_reg(op.reg)
		if is_r32(n) do return fmt.aprintf("c.%s = %s", n, val)
		if r := r16_of(n); r != "" do return fmt.aprintf("c.%s = (c.%s & 0xffff0000) | u32(%s)", r, r, val)
		if r := r8l_of(n); r != "" do return fmt.aprintf("c.%s = (c.%s & 0xffffff00) | u32(%s)", r, r, val)
		if r := r8h_of(n); r != "" do return fmt.aprintf("c.%s = (c.%s & 0xffff00ff) | (u32(%s) << 8)", r, r, val)
		unsupported(L, strings.concatenate({"reg ", n}))
		return ""
	case OP_MEM:
		return fmt.aprintf("x86.wr%d(%s, %s)", int(op.size) * 8, ea != "" ? ea : lift_ea(L, op), val)
	}
	unsupported(L, "write operand")
	return ""
}

// The read expression of a read-modify-write operand and the EA its write
// uses; a memory operand's EA is computed once into `ea`.
lift_rmw :: proc(L: ^Lift, op: ^Cs_Op) -> (string, string) {
	if op.type == OP_MEM {
		emitf(L, "ea := u32(%s)", lift_ea(L, op))
		return lift_read(L, op, "ea"), "ea"
	}
	return lift_read(L, op), ""
}

// -- flags

// Store the live flags of an add/sub-family result.
flags_arith :: proc(out: ^[dynamic]string, kind: string, size: int, a, b, r: string, live: u8, cin := "None") {
	sg := sign(size)
	if live & CF != 0 {
		switch kind {
		case "add": append(out, fmt.aprintf("c.cf = %s < %s", r, a))
		case "sub": append(out, fmt.aprintf("c.cf = %s < %s", a, b))
		case "adc": append(out, fmt.aprintf("c.cf = %s ? %s <= %s : %s < %s", cin, r, a, r, a))
		case "sbb": append(out, fmt.aprintf("c.cf = %s ? %s <= %s : %s < %s", cin, a, b, a, b))
		case "neg": append(out, fmt.aprintf("c.cf = %s != 0", a))
		}
	}
	if live & OF != 0 {
		switch kind {
		case "add", "adc": append(out, fmt.aprintf("c.of = (~(%s ~ %s) & (%s ~ %s) & %s) != 0", a, b, a, r, sg))
		case "sub", "sbb": append(out, fmt.aprintf("c.of = ((%s ~ %s) & (%s ~ %s) & %s) != 0", a, b, a, r, sg))
		case "neg": append(out, fmt.aprintf("c.of = %s == %s", a, sg))
		case "inc": append(out, fmt.aprintf("c.of = %s == %s", r, sg))
		case "dec": append(out, fmt.aprintf("c.of = %s == %s - 1", r, sg))
		}
	}
	if live & AF != 0 {
		switch kind {
		case "neg": append(out, fmt.aprintf("c.af = (%s & 0xf) != 0", a))
		case "inc": append(out, fmt.aprintf("c.af = (%s & 0xf) == 0", r))
		case "dec": append(out, fmt.aprintf("c.af = (%s & 0xf) == 0xf", r))
		case: append(out, fmt.aprintf("c.af = ((%s ~ %s ~ %s) & 0x10) != 0", a, b, r))
		}
	}
	flags_result(out, size, r, live)
}

flags_result :: proc(out: ^[dynamic]string, size: int, r: string, live: u8) {
	if live & ZF != 0 do append(out, fmt.aprintf("c.zf = %s == 0", r))
	if live & SF != 0 do append(out, fmt.aprintf("c.sf = (%s & %s) != 0", r, sign(size)))
	if live & PF != 0 do append(out, fmt.aprintf("c.pf = x86.parity(u8(%s))", r))
}

flags_logic :: proc(out: ^[dynamic]string, size: int, r: string, live: u8) {
	if live & CF != 0 do append(out, "c.cf = false")
	if live & OF != 0 do append(out, "c.of = false")
	if live & AF != 0 do append(out, "c.af = false")
	flags_result(out, size, r, live)
}

// Fusable flag producers: their result or operands give the condition directly.
is_fuse_arith :: proc(m: string) -> bool {return m == "cmp" || m == "sub"}
is_fuse_logic :: proc(m: string) -> bool {return m == "test" || m == "and" || m == "or" || m == "xor"}

// Condition expression for flags of an arith (else logic) producer consumed
// by cc, or "".
fused_cond :: proc(arith: bool, cc: string, size: int, a, b, r: string) -> string {
	st := stype(size)
	if arith {
		switch cc {
		case "e": return fmt.aprintf("%s == %s", a, b)
		case "ne": return fmt.aprintf("%s != %s", a, b)
		case "b": return fmt.aprintf("%s < %s", a, b)
		case "ae": return fmt.aprintf("%s >= %s", a, b)
		case "be": return fmt.aprintf("%s <= %s", a, b)
		case "a": return fmt.aprintf("%s > %s", a, b)
		case "l": return fmt.aprintf("%s(%s) < %s(%s)", st, a, st, b)
		case "ge": return fmt.aprintf("%s(%s) >= %s(%s)", st, a, st, b)
		case "le": return fmt.aprintf("%s(%s) <= %s(%s)", st, a, st, b)
		case "g": return fmt.aprintf("%s(%s) > %s(%s)", st, a, st, b)
		case "s": return fmt.aprintf("%s(%s) < 0", st, r)
		case "ns": return fmt.aprintf("%s(%s) >= 0", st, r)
		}
		return ""
	}
	switch cc {
	case "e": return fmt.aprintf("%s == 0", r)
	case "ne": return fmt.aprintf("%s != 0", r)
	case "s", "l": return fmt.aprintf("%s(%s) < 0", st, r)
	case "ns", "ge": return fmt.aprintf("%s(%s) >= 0", st, r)
	case "le": return fmt.aprintf("%s(%s) <= 0", st, r)
	case "g": return fmt.aprintf("%s(%s) > 0", st, r)
	case "b": return "false"
	case "ae": return "true"
	case "be": return fmt.aprintf("%s == 0", r)
	case "a": return fmt.aprintf("%s != 0", r)
	case "p": return fmt.aprintf("x86.parity(u8(%s))", r)
	case "np": return fmt.aprintf("!x86.parity(u8(%s))", r)
	}
	return ""
}

// The fuse sink: keeps cond and returns the flags still to store.
fuse :: proc(L: ^Lift, arith: bool, size: int, a, b, r: string) -> u8 {
	if L.fuse_cc == "" do return L.live
	e := fused_cond(arith, L.fuse_cc, size, a, b, r)
	if e == "" do return L.live
	L.fused = e
	return L.fuse_after
}

// ---------------------------------------------------------------- x87

FARITH := [8]string{"fadd", "fmul", "fcom", "fcomp", "fsub", "fsubr", "fdiv", "fdivr"}

fop :: proc(kind, a, b: string) -> string {
	switch kind {
	case "fadd": return fmt.aprintf("%s + %s", a, b)
	case "fmul": return fmt.aprintf("%s * %s", a, b)
	case "fsub": return fmt.aprintf("%s - %s", a, b)
	case "fsubr": return fmt.aprintf("%s - %s", b, a)
	case "fdiv": return fmt.aprintf("%s / %s", a, b)
	case "fdivr": return fmt.aprintf("%s / %s", b, a)
	}
	fmt.panicf("fop %s", kind)
}

// x87 stack cache. The registers live in c.fpu, a global, and every guest
// store (wr32 and the like) may alias it as far as LLVM can tell, so each
// st(i), set_st and fpush reloaded top, the control word and the register.
// Within a run of instructions in one basic block, top moves by a known
// amount, so the run keeps the registers it touches in proc locals x87_0..7
// (physical register (x87t + j) & 7, x87t = top at the run's start) and writes
// back the changed registers, tags and top when the run ends: before any
// control transfer or call, at the block's end, and before an instruction
// that reads the whole x87 state (fxam, fprem, fnsave, frstor, fninit).
// fstsw reads only the status word and top, so it takes top from the run.
// WHY: docs/recompiler.md §4
X87 :: struct {
	used:   map[string]struct{}, // proc locals to declare
	active: bool,
	dt:     int, // top minus x87t, mod 8
	val:    [8]i8, // -1 not held, else whether x87_j is dirty
	tag:    [8]i8, // -1 untouched, 1 empty, 0 full, set by fpop / fpush
	single: bool, // x87s holds the precision control test
}

x87_reset :: proc(x: ^X87) {
	x.active = false
	x.dt = 0
	x.val = -1
	x.tag = -1
	x.single = false
}

x87_begin :: proc(x: ^X87, s: ^[dynamic]string) {
	if !x.active {
		append(s, "x87t = c.fpu.top")
		x.used["x87t: u32"] = {}
		x.active = true
	}
}

x87_key :: proc(x: ^X87, i: int) -> int {
	return (x.dt + i) & 7
}

x87_name :: proc(x: ^X87, j: int) -> string {
	x.used[fmt.aprintf("x87_%d: f64", j)] = {}
	return fmt.aprintf("x87_%d", j)
}

fs_st :: proc(x: ^X87, s: ^[dynamic]string, i: int) -> string {
	if x == nil do return fmt.aprintf("x86.st(%d)", i)
	x87_begin(x, s)
	j := x87_key(x, i)
	if x.val[j] < 0 {
		append(s, fmt.aprintf("%s = x86.st_phys(x87t + %d)", x87_name(x, j), j))
		x.val[j] = 0
	}
	return x87_name(x, j)
}

fs_set :: proc(x: ^X87, s: ^[dynamic]string, i: int, expr: string, raw: bool) {
	if x == nil {
		append(s, fmt.aprintf("x86.%s(%d, %s)", raw ? "set_st_raw" : "set_st", i, expr))
		return
	}
	x87_begin(x, s)
	j := x87_key(x, i)
	expr := expr
	if !raw {
		if !x.single {
			append(s, "x87s = c.fpu.cw & x86.PC_MASK == 0")
			x.used["x87s: bool"] = {}
			x.single = true
		}
		expr = fmt.aprintf("x86.round_pc(x87s, %s)", expr)
	}
	append(s, fmt.aprintf("%s = %s", x87_name(x, j), expr))
	x.val[j] = 1
}

fs_push :: proc(x: ^X87, s: ^[dynamic]string, expr: string) {
	if x == nil {
		append(s, fmt.aprintf("x86.fpush(%s)", expr))
		return
	}
	x87_begin(x, s)
	x.dt = (x.dt - 1) & 7
	j := x87_key(x, 0)
	append(s, fmt.aprintf("%s = %s", x87_name(x, j), expr))
	x.val[j] = 1
	x.tag[j] = 0
}

fs_pop :: proc(x: ^X87, s: ^[dynamic]string) {
	if x == nil {
		append(s, "x86.fpop()")
		return
	}
	x87_begin(x, s)
	x.tag[x87_key(x, 0)] = 1
	x.dt = (x.dt + 1) & 7
}

fs_xch :: proc(x: ^X87, s: ^[dynamic]string, i: int) {
	if x == nil {
		append(s, fmt.aprintf("x86.fxch(%d)", i))
		return
	}
	a, b := fs_st(x, s, 0), fs_st(x, s, i)
	if a != b {
		append(s, fmt.aprintf("%s, %s = %s, %s", a, b, b, a))
		x.val[x87_key(x, 0)] = 1
		x.val[x87_key(x, i)] = 1
	}
}

// fstsw's value: the status word with the run's top.
fs_sw :: proc(x: ^X87) -> string {
	if x == nil || !x.active do return "x86.fstsw()"
	return fmt.aprintf("(c.fpu.sw & ~u16(0x3800)) | u16(((x87t + %d) & 7) << 11)", x.dt)
}

fs_flush :: proc(x: ^X87, s: ^[dynamic]string) {
	if x == nil || !x.active do return
	// A register the run leaves empty keeps no value worth writing: the
	// guest cannot read it without first loading it again.
	for j in 0 ..< 8 {
		if x.val[j] == 1 && x.tag[j] != 1 {
			append(s, fmt.aprintf("x86.set_st_phys(x87t + %d, %s)", j, x87_name(x, j)))
		}
	}
	full, empty: int
	any_tag := false
	for j in 0 ..< 8 {
		if x.tag[j] == 0 do full |= 1 << uint(j)
		if x.tag[j] == 1 do empty |= 1 << uint(j)
		if x.tag[j] >= 0 do any_tag = true
	}
	if any_tag {
		append(s, fmt.aprintf("c.fpu.tag = (c.fpu.tag &~ x86.rot8(0x%x, x87t)) | x86.rot8(0x%x, x87t)", full | empty, empty))
	}
	if x.dt != 0 do append(s, fmt.aprintf("c.fpu.top = (x87t + %d) & 7", x.dt))
	x87_reset(x)
}

FCONST :: proc(modrm: u8) -> string {
	switch modrm {
	case 0xE8: return "1"
	case 0xE9: return "math.LN10 / math.LN2"
	case 0xEA: return "1 / math.LN2"
	case 0xEB: return "math.PI"
	case 0xEC: return "math.LN2 / math.LN10"
	case 0xED: return "math.LN2"
	case 0xEE: return "0"
	}
	return ""
}

// x87 instructions, decoded from the opcode bytes (D8-DF + ModRM).
lift_x87 :: proc(L: ^Lift) {
	ins := L.i
	b := ins.bytes[:ins.size]
	k := 0
	for is_prefix(b[k]) do k += 1
	op, modrm := b[k], b[k + 1]
	reg, rm := int((modrm >> 3) & 7), int(modrm & 7)
	s := &L.s
	fs := L.fs
	mem := modrm < 0xC0
	ea := ""
	if mem {
		for j in 0 ..< int(ins.nops) {
			if ins.ops[j].type == OP_MEM {
				ea = lift_ea(L, &ins.ops[j])
				break
			}
		}
		if L.err != "" do return
	}
	st :: proc(fs: ^X87, s: ^[dynamic]string, i: int) -> string {return fs_st(fs, s, i)}
	ld :: proc(kind, ea: string) -> string {
		switch kind {
		case "m32": return fmt.aprintf("f64(transmute(f32)x86.rd32(%s))", ea)
		case "m64": return fmt.aprintf("transmute(f64)x86.rd64(%s)", ea)
		case "i16": return fmt.aprintf("f64(i16(x86.rd16(%s)))", ea)
		case "i32": return fmt.aprintf("f64(i32(x86.rd32(%s)))", ea)
		case "i64": return fmt.aprintf("f64(i64(x86.rd64(%s)))", ea)
		case "m80": return fmt.aprintf("x86.ld80(%s)", ea)
		}
		return ""
	}
	fcom :: proc(fs: ^X87, s: ^[dynamic]string, i: int, pops: int) {
		a := fs_st(fs, s, 0)
		append(s, fmt.aprintf("x86.fcom(%s, %s)", a, fs_st(fs, s, i)))
		for _ in 0 ..< pops do fs_pop(fs, s)
	}
	arith :: proc(fs: ^X87, s: ^[dynamic]string, kind, src: string) {
		if kind == "fcom" || kind == "fcomp" {
			append(s, fmt.aprintf("x86.fcom(%s, %s)", fs_st(fs, s, 0), src))
			if kind == "fcomp" do fs_pop(fs, s)
			return
		}
		fs_set(fs, s, 0, fop(kind, fs_st(fs, s, 0), src), false)
	}

	switch {
	case (op == 0xD8 || op == 0xDC) && mem:
		arith(fs, s, FARITH[reg], ld(op == 0xD8 ? "m32" : "m64", ea))
	case op == 0xD8:
		arith(fs, s, FARITH[reg], st(fs, s, rm))
	case (op == 0xDA || op == 0xDE) && mem:
		arith(fs, s, FARITH[reg], ld(op == 0xDA ? "i32" : "i16", ea))
	case op == 0xDC || op == 0xDE:
		// st(i) = st(i) op st(0); register forms swap sub/subr and div/divr.
		if op == 0xDE && modrm == 0xD9 {
			fcom(fs, s, 1, 2)
			return
		}
		if reg == 2 || reg == 3 {
			fcom(fs, s, rm, reg == 3 || op == 0xDE ? 1 : 0)
			return
		}
		st0 := st(fs, s, 0)
		sti := st(fs, s, rm)
		expr: string
		switch reg {
		case 0: expr = fmt.aprintf("%s + %s", sti, st0)
		case 1: expr = fmt.aprintf("%s * %s", sti, st0)
		case 4: expr = fmt.aprintf("%s - %s", st0, sti)
		case 5: expr = fmt.aprintf("%s - %s", sti, st0)
		case 6: expr = fmt.aprintf("%s / %s", st0, sti)
		case 7: expr = fmt.aprintf("%s / %s", sti, st0)
		}
		fs_set(fs, s, rm, expr, false)
		if op == 0xDE do fs_pop(fs, s)
	case op == 0xD9 && mem:
		switch reg {
		case 0:
			fs_push(fs, s, ld("m32", ea))
		case 2, 3:
			append(s, fmt.aprintf("x86.wr32(%s, transmute(u32)f32(%s))", ea, st(fs, s, 0)))
			if reg == 3 do fs_pop(fs, s)
		case 5:
			append(s, fmt.aprintf("x86.fldcw(x86.rd16(%s))", ea))
			if fs != nil do fs.single = false
		case 7:
			append(s, fmt.aprintf("x86.wr16(%s, c.fpu.cw)", ea))
		case:
			unsupported(L, "fldenv/fstenv")
		}
	case op == 0xD9:
		switch {
		case reg == 0:
			fs_push(fs, s, st(fs, s, rm))
		case reg == 1:
			fs_xch(fs, s, rm)
		case modrm == 0xD0:
		case modrm == 0xE0:
			fs_set(fs, s, 0, fmt.aprintf("-%s", st(fs, s, 0)), false)
		case modrm == 0xE1:
			fs_set(fs, s, 0, fmt.aprintf("abs(%s)", st(fs, s, 0)), false)
		case modrm == 0xE4:
			append(s, fmt.aprintf("x86.fcom(%s, 0)", st(fs, s, 0)))
		case modrm == 0xE5:
			fs_flush(fs, s)
			append(s, "x86.fxam()")
		case FCONST(modrm) != "":
			fs_push(fs, s, FCONST(modrm))
		case modrm == 0xF0:
			fs_set(fs, s, 0, fmt.aprintf("x86.f2xm1(%s)", st(fs, s, 0)), false)
		case modrm == 0xF1:
			a := st(fs, s, 1)
			fs_set(fs, s, 1, fmt.aprintf("%s * math.log2(%s)", a, st(fs, s, 0)), false)
			fs_pop(fs, s)
		case modrm == 0xF2:
			fs_set(fs, s, 0, fmt.aprintf("x86.tan(%s)", st(fs, s, 0)), false)
			fs_push(fs, s, "1")
		case modrm == 0xF3:
			a := st(fs, s, 1)
			fs_set(fs, s, 1, fmt.aprintf("math.atan2(%s, %s)", a, st(fs, s, 0)), false)
			fs_pop(fs, s)
		case modrm == 0xF5 || modrm == 0xF8:
			fs_flush(fs, s)
			append(s, "x86.fprem()")
		case modrm == 0xFA:
			fs_set(fs, s, 0, fmt.aprintf("math.sqrt(%s)", st(fs, s, 0)), false)
		case modrm == 0xFB:
			// fsincos: st(0) = sin, then cos pushed; the push lands in another
			// register, so it goes first and both read the old st(0).
			v := st(fs, s, 0)
			fs_push(fs, s, fmt.aprintf("x86.cos(%s)", v))
			fs_set(fs, s, 1, fmt.aprintf("x86.sin(%s)", v), false)
		case modrm == 0xFC:
			fs_set(fs, s, 0, fmt.aprintf("x86.round_cw(%s)", st(fs, s, 0)), false)
		case modrm == 0xFD:
			a := st(fs, s, 0)
			fs_set(fs, s, 0, fmt.aprintf("x86.fscale(%s, %s)", a, st(fs, s, 1)), false)
		case modrm == 0xFE:
			fs_set(fs, s, 0, fmt.aprintf("x86.sin(%s)", st(fs, s, 0)), false)
		case modrm == 0xFF:
			fs_set(fs, s, 0, fmt.aprintf("x86.cos(%s)", st(fs, s, 0)), false)
		case:
			unsupported(L, fmt.aprintf("x87 d9 %02x", modrm))
		}
	case op == 0xDB && mem:
		switch reg {
		case 0:
			fs_push(fs, s, ld("i32", ea))
		case 2, 3:
			append(s, fmt.aprintf("x86.wr32(%s, u32(x86.fist32(%s)))", ea, st(fs, s, 0)))
			if reg == 3 do fs_pop(fs, s)
		case 1:
			append(s, fmt.aprintf("x86.wr32(%s, u32(x86.fist32_trunc(%s)))", ea, st(fs, s, 0)))
			fs_pop(fs, s)
		case 5:
			fs_push(fs, s, ld("m80", ea))
		case 7:
			append(s, fmt.aprintf("x86.st80(%s, %s)", ea, st(fs, s, 0)))
			fs_pop(fs, s)
		case:
			unsupported(L, "x87 db mem")
		}
	case op == 0xDB:
		switch {
		case modrm == 0xE2:
			append(s, "c.fpu.sw &= 0x7f00")
		case modrm == 0xE3:
			fs_flush(fs, s)
			append(s, "x86.fninit()")
		case 0xE8 <= modrm && modrm < 0xF8:
			a := st(fs, s, 0)
			append(s, fmt.aprintf("x86.fcomi(%s, %s)", a, st(fs, s, rm)))
		case:
			unsupported(L, fmt.aprintf("x87 db %02x", modrm))
		}
	case op == 0xDD && mem:
		switch reg {
		case 0:
			fs_push(fs, s, ld("m64", ea))
		case 2, 3:
			append(s, fmt.aprintf("x86.wr64(%s, transmute(u64)%s)", ea, st(fs, s, 0)))
			if reg == 3 do fs_pop(fs, s)
		case 1:
			append(s, fmt.aprintf("x86.wr64(%s, u64(x86.fist64_trunc(%s)))", ea, st(fs, s, 0)))
			fs_pop(fs, s)
		case 7:
			append(s, fmt.aprintf("x86.wr16(%s, %s)", ea, fs_sw(fs)))
		case 6:
			fs_flush(fs, s)
			append(s, fmt.aprintf("x86.fnsave(%s)", ea))
		case 4:
			fs_flush(fs, s)
			append(s, fmt.aprintf("x86.frstor(%s)", ea))
		case:
			unsupported(L, "x87 dd mem")
		}
	case op == 0xDD:
		switch reg {
		case 0: // ffree
		case 2, 3:
			fs_set(fs, s, rm, st(fs, s, 0), true)
			if reg == 3 do fs_pop(fs, s)
		case 4, 5:
			fcom(fs, s, rm, reg == 5 ? 1 : 0)
		case:
			unsupported(L, fmt.aprintf("x87 dd %02x", modrm))
		}
	case op == 0xDA:
		if modrm == 0xE9 {
			fcom(fs, s, 1, 2)
		} else {
			unsupported(L, "fcmov")
		}
	case op == 0xDF && mem:
		switch reg {
		case 0:
			fs_push(fs, s, ld("i16", ea))
		case 2, 3:
			append(s, fmt.aprintf("x86.wr16(%s, u16(x86.fist16(%s)))", ea, st(fs, s, 0)))
			if reg == 3 do fs_pop(fs, s)
		case 5:
			fs_push(fs, s, ld("i64", ea))
		case 7:
			append(s, fmt.aprintf("x86.wr64(%s, u64(x86.fist64(%s)))", ea, st(fs, s, 0)))
			fs_pop(fs, s)
		case:
			unsupported(L, "fbld/fbstp")
		}
	case op == 0xDF:
		switch {
		case modrm == 0xE0:
			append(s, fmt.aprintf("c.eax = (c.eax & 0xffff0000) | u32(%s)", fs_sw(fs)))
		case 0xE8 <= modrm && modrm < 0xF8:
			a := st(fs, s, 0)
			append(s, fmt.aprintf("x86.fcomi(%s, %s)", a, st(fs, s, rm)))
			fs_pop(fs, s)
		case:
			unsupported(L, fmt.aprintf("x87 df %02x", modrm))
		}
	case:
		unsupported(L, fmt.aprintf("x87 %02x", op))
	}
}

// ---------------------------------------------------------------- SSE

is_sse :: proc(L: ^Lift) -> bool {
	ins := L.i
	if ins.mnemonic == "stmxcsr" || ins.mnemonic == "ldmxcsr" do return true
	for j in 0 ..< int(ins.nops) {
		op := &ins.ops[j]
		if op.type == OP_REG {
			n := lift_reg(op.reg)
			if strings.has_prefix(n, "xmm") do return true
			if strings.has_prefix(n, "mm") {
				unsupported(L, "mmx")
				return true
			}
		}
	}
	return false
}

xr :: proc(op: ^Cs_Op) -> string {
	return fmt.aprintf("c.xmm[%s]", lift_reg(op.reg)[3:])
}

isx :: proc(op: ^Cs_Op) -> bool {
	return op != nil && op.type == OP_REG && strings.has_prefix(lift_reg(op.reg), "xmm")
}

v128 :: proc(L: ^Lift, op: ^Cs_Op) -> string {
	return isx(op) ? xr(op) : fmt.aprintf("x86.rd128(%s)", lift_ea(L, op))
}

// Scalar lane k of an xmm, or a scalar memory operand.
lane :: proc(L: ^Lift, op: ^Cs_Op, field: string, k := 0) -> string {
	if isx(op) do return fmt.aprintf("%s.%s[%d]", xr(op), field, k)
	switch field {
	case "f": return fmt.aprintf("transmute(f32)x86.rd32(%s)", lift_ea(L, op))
	case "d": return fmt.aprintf("transmute(f64)x86.rd64(%s)", lift_ea(L, op))
	case "q": return fmt.aprintf("x86.rd64(%s)", lift_ea(L, op))
	}
	return fmt.aprintf("x86.rd32(%s)", lift_ea(L, op))
}

store_lane :: proc(L: ^Lift, op: ^Cs_Op, field, val: string) {
	if isx(op) {
		emitf(L, "%s.%s[0] = %s", xr(op), field, val)
		return
	}
	n := field == "f" || field == "u" ? 32 : 64
	cv := field == "f" || field == "d" ? fmt.aprintf("transmute(u%d)", n) : ""
	emitf(L, "x86.wr%d(%s, %s(%s))", n, lift_ea(L, op), cv, val)
}

in_strs :: proc(s: string, list: ..string) -> bool {
	for x in list do if s == x do return true
	return false
}

// SSE/SSE2 subset over c.xmm (x86.Xmm raw unions).
lift_sse :: proc(L: ^Lift) {
	ins := L.i
	m := ins.mnemonic
	d := ins.nops > 0 ? &ins.ops[0] : nil
	a := ins.nops > 1 ? &ins.ops[1] : nil
	n2 := len(m) >= 2 ? m[len(m) - 2:] : ""
	switch {
	case in_strs(m, "movaps", "movups", "movapd", "movupd", "movdqa", "movdqu"):
		if isx(d) {
			emitf(L, "%s = %s", xr(d), v128(L, a))
		} else {
			emitf(L, "x86.wr128(%s, %s)", lift_ea(L, d), xr(a))
		}
	case m == "movss" || m == "movsd":
		f := m == "movss" ? "f" : "d"
		if isx(d) && isx(a) {
			emitf(L, "%s.%s[0] = %s.%s[0]", xr(d), f, xr(a), f)
		} else if isx(d) {
			emitf(L, "{{ v := %s; %s = {{}}; %s.%s[0] = v }}", lane(L, a, f), xr(d), xr(d), f)
		} else {
			store_lane(L, d, f, lane(L, a, f))
		}
	case m == "movd":
		if isx(d) {
			emitf(L, "{{ v := %s; %s = {{}}; %s.u[0] = v }}", lift_read(L, a), xr(d), xr(d))
		} else {
			emit(L, lift_write(L, d, fmt.aprintf("%s.u[0]", xr(a))))
		}
	case m == "movq":
		if isx(d) {
			emitf(L, "{{ v := %s; %s = {{}}; %s.q[0] = v }}", lane(L, a, "q"), xr(d), xr(d))
		} else {
			store_lane(L, d, "q", fmt.aprintf("%s.q[0]", xr(a)))
		}
	case m == "movlpd" || m == "movlps":
		if isx(d) {
			emitf(L, "%s.q[0] = %s", xr(d), lane(L, a, "q"))
		} else {
			store_lane(L, d, "q", fmt.aprintf("%s.q[0]", xr(a)))
		}
	case m == "movhpd" || m == "movhps":
		if isx(d) {
			emitf(L, "%s.q[1] = x86.rd64(%s)", xr(d), lift_ea(L, a))
		} else {
			emitf(L, "x86.wr64(%s, %s.q[1])", lift_ea(L, d), xr(a))
		}
	case len(m) >= 2 && in_strs(m[:len(m) - 2], "add", "sub", "mul", "div", "min", "max") && in_strs(n2, "ss", "sd", "ps", "pd"):
		op := m[:len(m) - 2]
		f := m[len(m) - 1] == 's' ? "f" : "d"
		n := m[len(m) - 2] == 's' ? 1 : (f == "f" ? 4 : 2)
		emitf(L, "{{ b := %s", n > 1 ? v128(L, a) : lane(L, a, f))
		for k in 0 ..< n {
			x := fmt.aprintf("%s.%s[%d]", xr(d), f, k)
			y := n > 1 ? fmt.aprintf("b.%s[%d]", f, k) : "b"
			if op == "min" || op == "max" {
				// x86 returns the second operand when either is NaN or both are zero.
				cmp := op == "min" ? "<" : ">"
				emitf(L, "%s = %s %s %s ? %s : %s", x, x, cmp, y, x, y)
			} else {
				sym: string
				switch op {
				case "add": sym = "+"
				case "sub": sym = "-"
				case "mul": sym = "*"
				case "div": sym = "/"
				}
				emitf(L, "%s %s= %s", x, sym, y)
			}
		}
		emit(L, "}")
	case m == "sqrtss" || m == "sqrtsd":
		f := m == "sqrtss" ? "f" : "d"
		emitf(L, "%s.%s[0] = math.sqrt(%s)", xr(d), f, lane(L, a, f))
	case m == "rcpss":
		emitf(L, "%s.f[0] = 1 / (%s)", xr(d), lane(L, a, "f"))
	case in_strs(m, "psubd", "paddd", "psubq", "paddq", "pcmpeqd"):
		w := m[len(m) - 1] == 'd' ? "u" : "q"
		n := w == "u" ? 4 : 2
		emitf(L, "{{ b := %s", v128(L, a))
		for k in 0 ..< n {
			x := fmt.aprintf("%s.%s[%d]", xr(d), w, k)
			if m == "pcmpeqd" {
				emitf(L, "%s = %s == b.u[%d] ? 0xffffffff : 0", x, x, k)
			} else {
				emitf(L, "%s %s= b.%s[%d]", x, strings.has_prefix(m, "psub") ? "-" : "+", w, k)
			}
		}
		emit(L, "}")
	case m == "pinsrw":
		src := a.type == OP_REG ? lift_read(L, a) : fmt.aprintf("x86.rd16(%s)", lift_ea(L, a))
		emitf(L, "%s.w[%d] = u16(%s)", xr(d), ins.ops[2].imm & 7, src)
	case m == "rsqrtss":
		emitf(L, "%s.f[0] = x86.rsqrt(%s)", xr(d), lane(L, a, "f"))
	case in_strs(m, "andps", "andpd", "pand", "orps", "orpd", "por", "xorps", "xorpd", "pxor", "andnps", "andnpd", "pandn"):
		b := strings.has_prefix(m, "p") ? m[1:] : strings.trim_right(strings.trim_right(m, "sd"), "p")
		sym: string
		switch b {
		case "and": sym = "&"
		case "or": sym = "|"
		case "xor": sym = "~"
		case "andn": sym = "andn"
		}
		if sym == "~" && isx(a) && lift_reg(a.reg) == lift_reg(d.reg) {
			emitf(L, "%s = {{}}", xr(d))
		} else {
			emitf(L, "{{ b := %s", v128(L, a))
			for k in 0 ..< 2 {
				x := fmt.aprintf("%s.q[%d]", xr(d), k)
				if sym == "andn" {
					emitf(L, "%s = ~%s & b.q[%d]", x, x, k)
				} else {
					emitf(L, "%s %s= b.q[%d]", x, sym, k)
				}
			}
			emit(L, "}")
		}
	case in_strs(m, "ucomiss", "comiss", "ucomisd", "comisd"):
		f := strings.has_suffix(m, "ss") ? "f" : "d"
		emitf(L, "x86.fcomi(f64(%s.%s[0]), f64(%s))", xr(d), f, lane(L, a, f))
	case m == "cvtsi2ss" || m == "cvtsi2sd":
		f := strings.has_suffix(m, "ss") ? "f" : "d"
		emitf(L, "%s.%s[0] = %s(i32(%s))", xr(d), f, f == "f" ? "f32" : "f64", lift_read(L, a))
	case m == "cvttss2si" || m == "cvttsd2si":
		f := m[5] == 's' ? "f" : "d"
		emit(L, lift_write(L, d, fmt.aprintf("x86.cvtt_i32(f64(%s))", lane(L, a, f))))
	case m == "cvtss2sd":
		emitf(L, "%s.d[0] = f64(%s)", xr(d), lane(L, a, "f"))
	case m == "cvtsd2ss":
		emitf(L, "%s.f[0] = f32(%s)", xr(d), lane(L, a, "d"))
	case m == "shufps":
		emitf(L, "%s = x86.shufps(%s, %s, %d)", xr(d), xr(d), v128(L, a), ins.ops[2].imm & 0xFF)
	case m == "pshufd":
		emitf(L, "%s = x86.pshufd(%s, %d)", xr(d), v128(L, a), ins.ops[2].imm & 0xFF)
	case m == "unpcklps":
		emitf(L, "{{ x, y := %s, %s; %s.u = {{x.u[0], y.u[0], x.u[1], y.u[1]}} }}", xr(d), v128(L, a), xr(d))
	case m == "pextrw":
		emit(L, lift_write(L, d, fmt.aprintf("u32(%s.w[%d])", xr(a), ins.ops[2].imm & 7)))
	case m == "psllq" || m == "psrlq":
		fn := m == "psllq" ? "x86.shl64" : "x86.shr64"
		cnt := a.type == OP_IMM ? fmt.aprintf("%d", a.imm & 0xFF) : fmt.aprintf("u32(min(%s.q[0], 64))", v128(L, a))
		emitf(L, "{{ n := u32(%s)", cnt)
		for k in 0 ..< 2 do emitf(L, "%s.q[%d] = %s(%s.q[%d], n)", xr(d), k, fn, xr(d), k)
		emit(L, "}")
	case strings.has_prefix(m, "cmp") && strings.has_suffix(m, "pd") && len(m) >= 5:
		p := m[3:len(m) - 2]
		pred := -1
		switch p {
		case "eq": pred = 0
		case "lt": pred = 1
		case "le": pred = 2
		case "unord": pred = 3
		case "neq": pred = 4
		case "nlt": pred = 5
		case "nle": pred = 6
		case "ord": pred = 7
		case "": if ins.nops == 3 do pred = int(ins.ops[2].imm & 7)
		}
		if pred < 0 {
			unsupported(L, m)
			return
		}
		emitf(L, "%s = x86.cmppd(%s, %s, %d)", xr(d), xr(d), v128(L, a), pred)
	case m == "stmxcsr":
		emitf(L, "x86.wr32(%s, c.mxcsr)", lift_ea(L, d))
	case m == "ldmxcsr":
		emitf(L, "c.mxcsr = x86.rd32(%s)", lift_ea(L, d))
	case:
		unsupported(L, m)
	}
}

// ---------------------------------------------------------------- integer ops

opbyte :: proc(ins: ^Insn) -> u8 {
	k := 0
	for k < int(ins.size) && is_prefix(ins.bytes[k]) do k += 1
	return k < int(ins.size) ? ins.bytes[k] : 0
}

// Statements for a non-control instruction. fuse_cc: the next
// instruction's condition code when it consumes this one's flags, "" else;
// the fused condition lands in L.fused. fs: the function's X87 run cache.
lift :: proc(ins: ^Insn, live: u8, fuse_cc: string, fuse_after: u8, fs: ^X87) -> Lift {
	L := Lift{i = ins, live = live, fs = fs, fuse_cc = fuse_cc, fuse_after = fuse_after}
	lift_body(&L)
	if L.err == "" do fmt.assertf(L.frame_count == is_frame_count(ins.address), "0x%x", ins.address)
	return L
}

lift_body :: proc(L: ^Lift) {
	ins := L.i
	live := L.live
	m := ins.mnemonic
	ops := ins.ops[:ins.nops]
	rep := ""
	if strings.has_prefix(m, "rep ") || strings.has_prefix(m, "repe ") || strings.has_prefix(m, "repne ") {
		k := strings.index_byte(m, ' ')
		rep, m = m[:k], m[k + 1:]
	}
	base := m

	if b := opbyte(ins); 0xD8 <= b && b <= 0xDF {
		lift_x87(L)
		return
	}
	if is_sse(L) {
		if L.err == "" do lift_sse(L)
		return
	}

	switch {
	case base == "mov":
		emit(L, lift_write(L, &ops[0], lift_read(L, &ops[1])))
	case base == "movzx" || base == "movsx":
		src := lift_read(L, &ops[1])
		if base == "movsx" {
			src = fmt.aprintf("%s(%s(%s))", size_t(int(ops[0].size)), stype(int(ops[1].size)), src)
		} else {
			src = fmt.aprintf("%s(%s)", size_t(int(ops[0].size)), src)
		}
		emit(L, lift_write(L, &ops[0], src))
	case base == "lea":
		e := lift_ea(L, &ops[1])
		emit(L, lift_write(L, &ops[0], ops[0].size == 4 ? e : fmt.aprintf("u16(%s)", e)))
	case base == "push":
		imm := ops[0].type == OP_IMM
		sz := imm ? 4 : int(ops[0].size)
		v := imm ? lit(ops[0].imm, 4) : lift_read(L, &ops[0])
		emitf(L, "v := %s", v)
		if sz == 2 {
			emit(L, "c.esp -= 2")
			emit(L, "x86.wr16(c.esp, v)")
		} else {
			emit(L, "c.esp -= 4")
			emit(L, "x86.wr32(c.esp, v)")
		}
	case base == "pop":
		sz := int(ops[0].size)
		emitf(L, "v := x86.rd%d(c.esp)", sz * 8)
		emitf(L, "c.esp += %d", sz)
		emit(L, lift_write(L, &ops[0], "v"))
	case base == "xchg":
		a, wa := lift_rmw(L, &ops[0])
		emitf(L, "t := %s", a)
		emit(L, lift_write(L, &ops[0], lift_read(L, &ops[1]), wa))
		emit(L, lift_write(L, &ops[1], "t"))
	case in_strs(base, "add", "sub", "adc", "sbb", "cmp"):
		size := int(ops[0].size)
		T := size_t(size)
		a, wa := lift_rmw(L, &ops[0])
		emitf(L, "a := %s", a)
		emitf(L, "b := %s", ops[1].type != OP_IMM ? lift_read(L, &ops[1]) : lift_imm(L, &ops[1], size))
		if base == "adc" || base == "sbb" {
			emit(L, "cin := c.cf")
			o := base == "adc" ? "+" : "-"
			emitf(L, "r := a %s b %s %s(cin ? 1 : 0)", o, o, T)
		} else {
			emitf(L, "r := a %s b", base == "add" ? "+" : "-")
		}
		if base != "cmp" do emit(L, lift_write(L, &ops[0], "r", wa))
		kind := base == "cmp" ? "sub" : base
		lv := live
		if is_fuse_arith(base) do lv = fuse(L, true, size, "a", "b", "r")
		flags_arith(&L.s, kind, size, "a", "b", "r", lv, "cin")
	case in_strs(base, "and", "or", "xor", "test"):
		size := int(ops[0].size)
		if base == "xor" && ops[1].type == OP_REG && ops[0].type == OP_REG && ops[0].reg == ops[1].reg {
			emit(L, lift_write(L, &ops[0], lit(0, size)))
			emitf(L, "r := %s", lit(0, size))
		} else {
			a, wa := lift_rmw(L, &ops[0])
			b := ops[1].type != OP_IMM ? lift_read(L, &ops[1]) : lit(ops[1].imm, size)
			o: string
			switch base {
			case "and", "test": o = "&"
			case "or": o = "|"
			case "xor": o = "~"
			}
			emitf(L, "r := %s %s %s", a, o, b)
			if base != "test" do emit(L, lift_write(L, &ops[0], "r", wa))
		}
		lv := fuse(L, false, size, "", "", "r")
		flags_logic(&L.s, size, "r", lv)
	case base == "inc" || base == "dec":
		size := int(ops[0].size)
		a, wa := lift_rmw(L, &ops[0])
		emitf(L, "a := %s", a)
		emitf(L, "r := a %s 1", base == "inc" ? "+" : "-")
		emit(L, lift_write(L, &ops[0], "r", wa))
		flags_arith(&L.s, base, size, "a", "1", "r", live)
	case base == "neg":
		size := int(ops[0].size)
		a, wa := lift_rmw(L, &ops[0])
		emitf(L, "a := %s", a)
		emit(L, "r := 0 - a")
		emit(L, lift_write(L, &ops[0], "r", wa))
		flags_arith(&L.s, "neg", size, "a", "0", "r", live)
	case base == "not":
		a, wa := lift_rmw(L, &ops[0])
		emit(L, lift_write(L, &ops[0], fmt.aprintf("~%s", a), wa))
	case in_strs(base, "shl", "sal", "shr", "sar", "rol", "ror", "rcl", "rcr"):
		size := int(ops[0].size)
		T, bits := size_t(size), size * 8
		a, wa := lift_rmw(L, &ops[0])
		n, known := shift_count(ins)
		if known && n == 0 do return
		emitf(L, "a := %s", a)
		emit(L, known ? fmt.aprintf("n := u32(%d)", n) : "n := c.ecx & 31")
		body: [dynamic]string
		switch base {
		case "shl", "sal":
			append(&body, "r := a << n")
			if live & CF != 0 do append(&body, fmt.aprintf("c.cf = (a >> (%d - n)) & 1 != 0", bits))
			if live & OF != 0 do append(&body, fmt.aprintf("c.of = ((r ~ a) & %s) != 0", sign(size)))
		case "shr":
			append(&body, "r := a >> n")
			if live & CF != 0 do append(&body, "c.cf = (a >> (n - 1)) & 1 != 0")
			if live & OF != 0 do append(&body, fmt.aprintf("c.of = (a & %s) != 0", sign(size)))
		case "sar":
			append(&body, fmt.aprintf("r := %s(%s(a) >> n)", T, stype(size)))
			if live & CF != 0 do append(&body, fmt.aprintf("c.cf = (%s(a) >> (n - 1)) & 1 != 0", stype(size)))
			if live & OF != 0 do append(&body, "c.of = false")
		case "rol", "ror":
			append(&body, fmt.aprintf("r := x86.%s%d(a, n)", base, bits))
			if live & CF != 0 do append(&body, base == "rol" ? "c.cf = r & 1 != 0" : fmt.aprintf("c.cf = (r & %s) != 0", sign(size)))
			if live & OF != 0 do append(&body, fmt.aprintf("c.of = ((r ~ a) & %s) != 0", sign(size)))
		case:
			append(&body, fmt.aprintf("r := x86.%s%d(a, n)", base, bits))
		}
		append(&body, lift_write(L, &ops[0], "r", wa))
		if in_strs(base, "shl", "sal", "shr", "sar") {
			flags_result(&body, size, "r", live)
			if live & AF != 0 do append(&body, "c.af = false")
		}
		if !known do emit(L, "if n != 0 {")
		append(&L.s, ..body[:])
		if !known do emit(L, "}")
	case base == "shld" || base == "shrd":
		a, wa := lift_rmw(L, &ops[0])
		emitf(L, "a := %s", a)
		emitf(L, "b := %s", lift_read(L, &ops[1]))
		emit(L, ops[2].type == OP_IMM ? fmt.aprintf("n := u32(%d)", ops[2].imm & 31) : "n := c.ecx & 31")
		emit(L, "if n != 0 {")
		if base == "shld" {
			emit(L, "r := (a << n) | (b >> (32 - n))")
			emit(L, "c.cf = (a >> (32 - n)) & 1 != 0")
		} else {
			emit(L, "r := (a >> n) | (b << (32 - n))")
			emit(L, "c.cf = (a >> (n - 1)) & 1 != 0")
		}
		emit(L, lift_write(L, &ops[0], "r", wa))
		flags_result(&L.s, 4, "r", ALL)
		emit(L, "c.of = false")
		emit(L, "}")
	case base == "imul":
		if len(ops) == 1 {
			size := int(ops[0].size)
			if size == 1 {
				emitf(L, "p := i16(i8(c.eax)) * i16(i8(%s))", lift_read(L, &ops[0]))
				emit(L, "c.eax = (c.eax & 0xffff0000) | u32(u16(p))")
				emit(L, "c.cf = p != i16(i8(p))")
				emit(L, "c.of = c.cf")
				return
			}
			if size == 2 {
				emitf(L, "p := i32(i16(c.eax)) * i32(i16(%s))", lift_read(L, &ops[0]))
				emit(L, "c.eax = (c.eax & 0xffff0000) | (u32(p) & 0xffff)")
				emit(L, "c.edx = (c.edx & 0xffff0000) | (u32(p) >> 16)")
				emit(L, "c.cf = p != i32(i16(p))")
				emit(L, "c.of = c.cf")
				return
			}
			emitf(L, "p := i64(i32(c.eax)) * i64(i32(%s))", lift_read(L, &ops[0]))
			emit(L, "c.eax = u32(p)")
			emit(L, "c.edx = u32(p >> 32)")
			emit(L, "c.cf = p != i64(i32(p))")
			emit(L, "c.of = c.cf")
		} else {
			size := int(ops[0].size)
			st := stype(size)
			// Immediates as signed literals: a u32 constant above
			// 0x7fffffff cannot be cast to i32 at compile time.
			sval :: proc(L: ^Lift, op: ^Cs_Op, size: int, st: string) -> string {
				if op.type == OP_IMM {
					bits := uint(8 * size)
					v := op.imm & ((i64(1) << bits) - 1)
					if v >= i64(1) << (bits - 1) do v -= i64(1) << bits
					return fmt.aprintf("i64(%d)", v)
				}
				return fmt.aprintf("i64(%s(%s))", st, lift_read(L, op))
			}
			x, y := len(ops) == 2 ? (&ops[0]) : (&ops[1]), len(ops) == 2 ? (&ops[1]) : (&ops[2])
			emitf(L, "p := %s * %s", sval(L, x, size, st), sval(L, y, size, st))
			emit(L, lift_write(L, &ops[0], fmt.aprintf("%s(p)", size_t(size))))
			if live & (CF | OF) != 0 {
				emitf(L, "c.cf = p != i64(%s(p))", st)
				emit(L, "c.of = c.cf")
			}
			flags_result(&L.s, size, fmt.aprintf("%s(p)", size_t(size)), live)
		}
	case base == "mul":
		if ops[0].size != 4 {
			unsupported(L, "mul8/16")
			return
		}
		emitf(L, "p := u64(c.eax) * u64(%s)", lift_read(L, &ops[0]))
		emit(L, "c.eax = u32(p)")
		emit(L, "c.edx = u32(p >> 32)")
		emit(L, "c.cf = c.edx != 0")
		emit(L, "c.of = c.cf")
	case base == "div" || base == "idiv":
		if ops[0].size != 4 {
			unsupported(L, "div8/16")
			return
		}
		if base == "div" {
			emitf(L, "d := u64(%s)", lift_read(L, &ops[0]))
			emit(L, "n := u64(c.edx) << 32 | u64(c.eax)")
		} else {
			emitf(L, "d := i64(i32(%s))", lift_read(L, &ops[0]))
			emit(L, "n := i64(u64(c.edx) << 32 | u64(c.eax))")
		}
		emit(L, "c.eax = u32(n / d)")
		emit(L, "c.edx = u32(n %% d)")
	case base == "cdq":
		emit(L, "c.edx = u32(i32(c.eax) >> 31)")
	case base == "cwde":
		emit(L, "c.eax = u32(i32(i16(c.eax)))")
	case base == "cbw":
		emit(L, "c.eax = (c.eax & 0xffff0000) | u32(u16(i16(i8(c.eax))))")
	case base == "leave":
		emit(L, "c.esp = c.ebp")
		emit(L, "c.ebp = x86.rd32(c.esp)")
		emit(L, "c.esp += 4")
	case base == "enter":
		if ops[1].imm != 0 {
			unsupported(L, "enter level")
			return
		}
		emit(L, "c.esp -= 4")
		emit(L, "x86.wr32(c.esp, c.ebp)")
		emit(L, "c.ebp = c.esp")
		emitf(L, "c.esp -= %d", ops[0].imm)
	case setcc_cond(m) != "":
		emit(L, lift_write(L, &ops[0], fmt.aprintf("u8(1) if %s else u8(0)", COND[setcc_cond(m)].expr)))
	case in_strs(base, "nop", "wait", "prefetcht0", "prefetchnta"):
	case base == "cld" || base == "std":
		emitf(L, "c.df = %s", base == "std" ? "true" : "false")
	case base == "clc":
		emit(L, "c.cf = false")
	case base == "stc":
		emit(L, "c.cf = true")
	case base == "cmc":
		emit(L, "c.cf = !c.cf")
	case base == "sahf":
		emit(L, "x86.sahf()")
	case base == "lahf":
		emit(L, "x86.lahf()")
	case base == "pushfd":
		emit(L, "c.esp -= 4")
		emit(L, "x86.wr32(c.esp, x86.get_eflags())")
	case base == "popfd":
		emit(L, "x86.set_eflags(x86.rd32(c.esp))")
		emit(L, "c.esp += 4")
	case base == "pushal":
		emit(L, "x86.pushad()")
	case base == "popal":
		emit(L, "x86.popad()")
	case base == "cpuid":
		emit(L, "x86.cpuid()")
	case in_strs(base, "bt", "bts", "btr", "btc"):
		op: string
		if ops[0].type != OP_REG && ops[1].type != OP_IMM {
			// Memory form with a register offset: signed bit index, so the
			// word addressed is ea + (offset >> 5) * 4.
			if ops[0].size != 4 {
				unsupported(L, "bt mem16,reg")
				return
			}
			emitf(L, "n := %s", lift_read(L, &ops[1]))
			emitf(L, "ea := u32(%s) + u32(i32(n) >> 5) * 4", lift_ea(L, &ops[0]))
			emit(L, "a := x86.rd32(ea)")
			emit(L, "c.cf = (a >> (n & 31)) & 1 != 0")
			switch base {
			case "bts": op = "a | (1 << (n & 31))"
			case "btr": op = "a &~ (1 << (n & 31))"
			case "btc": op = "a ~ (1 << (n & 31))"
			}
			if base != "bt" do emitf(L, "x86.wr32(ea, %s)", op)
			return
		}
		a, wa := lift_rmw(L, &ops[0])
		bits := int(ops[0].size) * 8
		emitf(L, "a := %s", a)
		emitf(L, "n := u32(%s) & %d", ops[1].type != OP_IMM ? lift_read(L, &ops[1]) : fmt.aprintf("%d", ops[1].imm), bits - 1)
		emit(L, "c.cf = (a >> n) & 1 != 0")
		switch base {
		case "bts": op = "a | (1 << n)"
		case "btr": op = "a &~ (1 << n)"
		case "btc": op = "a ~ (1 << n)"
		}
		if base != "bt" do emit(L, lift_write(L, &ops[0], op, wa))
	case base == "xlatb":
		emit(L, "c.eax = (c.eax & 0xffffff00) | u32(x86.rd8(c.ebx + (c.eax & 0xff)))")
	case in_strs(base, "movsb", "movsw", "movsd", "stosb", "stosw", "stosd", "lodsb", "lodsw", "lodsd", "cmpsb", "cmpsw", "cmpsd", "scasb", "scasw", "scasd") && (len(ops) == 0 || ops[0].type == OP_MEM || strings.has_prefix(base, "lods") || strings.has_prefix(base, "scas") || strings.has_prefix(base, "stos")):
		size := base[len(base) - 1] == 'b' ? 1 : base[len(base) - 1] == 'w' ? 2 : 4
		fn := base[:len(base) - 1]
		mode: string
		switch rep {
		case "rep": mode = ".Rep"
		case "repe": mode = ".Repe"
		case "repne": mode = ".Repne"
		case: mode = ".None"
		}
		if in_strs(fn, "movs", "stos", "lods") && rep == "repe" do mode = ".Rep"
		emitf(L, "x86.%s(%d, %s)", fn, size, mode)
	case base == "int3":
		emitf(L, "x86.trap(%s)", hexu(ins.address))
	case:
		unsupported(L, m)
	}
}
