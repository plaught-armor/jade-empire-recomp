package x86rec

// capstone 5.0.7 through the flat view in capstone.c (built by build.sh).

import "core:c"

when ODIN_OS == .Windows {
	foreign import cs "../../port/build/capstone/capstone.lib"
} else {
	foreign import cs "../../port/build/capstone/libcapstone.a"
}

// capstone's x86_op_type and cs_ac_type values.
OP_REG :: 1
OP_IMM :: 2
OP_MEM :: 3
AC_READ :: 1
AC_WRITE :: 2

// One operand, its union fields copied raw (capstone.c je_op).
Cs_Op :: struct {
	type, size, access, _: u8,
	reg:                   u32,
	imm:                   i64,
	segment, base, index:  u32,
	scale:                 i32,
	disp:                  i64,
}

Cs_Insn :: struct {
	address:                    u32,
	size:                       u16,
	op_count, n_read, n_write:  u8,
	bytes:                      [16]u8,
	mnemonic:                   [32]u8,
	op_str:                     [160]u8,
	ops:                        [8]Cs_Op,
	read, write:                [64]u16,
}

@(default_calling_convention = "c")
foreign cs {
	je_cs_open :: proc() -> c.int ---
	je_cs_reg_name :: proc(reg: c.uint) -> cstring ---
	je_cs_decode :: proc(code: [^]u8, len: c.size_t, addr: u64, out: ^Cs_Insn) -> c.int ---
}
