// capstone 5.0.7, x86 32-bit, through the flat view in capstone.c (built by
// tools/build.sh).
package capstone

import "core:c"

when ODIN_OS == .Windows {
	foreign import cs "../../port/build/capstone/capstone.lib"
} else {
	foreign import cs "../../port/build/capstone/libcapstone.a"
}

// capstone's x86_op_type, cs_ac_type and cs_group_type values.
OP_REG :: 1
OP_IMM :: 2
OP_MEM :: 3
AC_READ :: 1
AC_WRITE :: 2
GRP_JUMP :: 1
GRP_CALL :: 2
GRP_RET :: 3

// One operand, its union fields copied raw (capstone.c je_op).
Op :: struct {
	type, size, access, _: u8,
	reg:                   u32,
	imm:                   i64,
	segment, base, index:  u32,
	scale:                 i32,
	disp:                  i64,
}

Insn :: struct {
	address:                             u32,
	size:                                u16,
	op_count, n_read, n_write, n_groups: u8,
	bytes:                               [16]u8,
	mnemonic:                            [32]u8,
	op_str:                              [160]u8,
	ops:                                 [8]Op,
	read, write:                         [64]u16,
	groups:                              [8]u8,
}

@(default_calling_convention = "c")
foreign cs {
	@(link_name = "je_cs_open")
	open :: proc() -> c.int ---
	@(link_name = "je_cs_reg_name")
	reg_name :: proc(reg: c.uint) -> cstring ---
	// The first instruction of code at addr; 0 when the bytes decode to none,
	// -1 when capstone cannot list its register accesses.
	@(link_name = "je_cs_decode")
	decode :: proc(code: [^]u8, len: c.size_t, addr: u64, out: ^Insn) -> c.int ---
}

has_group :: proc(i: ^Insn, g: u8) -> bool {
	for k in 0 ..< i.n_groups do if i.groups[k] == g do return true
	return false
}

mnemonic :: proc(i: ^Insn) -> string {
	return string(cstring(&i.mnemonic[0]))
}

op_str :: proc(i: ^Insn) -> string {
	return string(cstring(&i.op_str[0]))
}
