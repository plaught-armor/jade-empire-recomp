// Recovers the NWScript command table: action id -> handler address.
// Usage: cmdtable <exe> > re/nwscript_handlers.tsv
// WHY: docs/modding.md §2
//
// FUN_004a0e50 (CVirtualMachineCommands setup) allocates 0x108c bytes, one
// handler pointer per action id, and fills them with stores of the form
//   mov REG, [esi + 0x10] ; mov dword ptr [REG + 4*id], HANDLER
// where HANDLER is an immediate or a register loaded with one earlier. The
// ACTION opcode's id indexes this table, so it is the ground truth that
// re/nwscript_functions.tsv (names from xoreos) is checked against.
package cmdtable

import "core:fmt"
import "core:os"
import "core:slice"
import cs "../capstone"
import "../pe"

TABLE_BYTES :: 0x108C
// The setup function's code, decoded straight through.
SETUP_LO :: 0x4a0e50
SETUP_HI :: 0x4a33d0

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: cmdtable <exe>")
		os.exit(2)
	}
	img := pe.load(os.args[1])
	assert(cs.open() != 0, "capstone open failed")
	esi: u32
	for r in u32(1) ..< 256 do if n := cs.reg_name(r); n != nil && n == "esi" do esi = r
	regs: map[u32]u32 // register -> the immediate it holds
	bases: map[u32]bool // registers holding the table
	table: map[int]u32
	ci: cs.Insn
	o := int(SETUP_LO - img.base)
	code := img.data[o:SETUP_HI - img.base]
	pc := u64(SETUP_LO)
	for len(code) > 0 {
		r := cs.decode(raw_data(code), len(code), pc, &ci)
		fmt.assertf(r > 0, "%x does not decode", pc)
		code = code[ci.size:]
		pc += u64(ci.size)
		if cs.mnemonic(&ci) != "mov" || ci.op_count != 2 do continue
		d, s := ci.ops[0], ci.ops[1]
		if d.type == cs.OP_MEM && d.size == 4 && d.base in bases && d.index == 0 && d.segment == 0 {
			// mov dword ptr [base + off], imm / reg
			off := int(d.disp)
			fmt.assertf(off >= 0 && off % 4 == 0 && off < TABLE_BYTES, "%x: offset %d", ci.address, off)
			if s.type == cs.OP_IMM {
				table[off / 4] = u32(s.imm)
			} else {
				fmt.assertf(s.type == cs.OP_REG && s.reg in regs, "store from unknown register: %x %s", ci.address, cs.op_str(&ci))
				table[off / 4] = regs[s.reg]
			}
			continue
		}
		if d.type != cs.OP_REG || d.size != 4 do continue
		delete_key(&regs, d.reg)
		delete_key(&bases, d.reg)
		if s.type == cs.OP_MEM && s.size == 4 && s.base == esi && s.index == 0 && s.disp == 0x10 && s.segment == 0 {
			bases[d.reg] = true
		} else if s.type == cs.OP_IMM {
			regs[d.reg] = u32(s.imm)
		}
	}
	ids: [dynamic]int
	for k in table do append(&ids, k)
	slice.sort(ids[:])
	fmt.println("# action id -> handler, from FUN_004a0e50 (tools/cmdtable)")
	fmt.println("id\thandler")
	for i in ids do fmt.printf("%d\t%#x\n", i, table[i])
	fmt.eprintf("%d ids filled of %d\n", len(ids), TABLE_BYTES / 4)
}
