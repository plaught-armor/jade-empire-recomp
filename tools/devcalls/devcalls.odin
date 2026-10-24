// Counts the IDirect3DDevice9 vtable slots called through the device global,
// per straight-line run from each function start:
// reg <- [DEV]; reg2 <- [reg]; call [reg2 + off].
// Usage: devcalls <exe> <ghidra_funcs.txt> <device global, hex>
// WHY: docs/exe_inventory.md
package devcalls

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import cs "../capstone"
import "../common"
import "../pe"

main :: proc() {
	if len(os.args) != 4 {
		fmt.eprintln("usage: devcalls <exe> <ghidra_funcs.txt> <device global, hex>")
		os.exit(2)
	}
	img := pe.load(os.args[1])
	fs := common.ghidra_starts(os.args[2])
	h := os.args[3]
	if len(h) > 2 && (h[:2] == "0x" || h[:2] == "0X") do h = h[2:]
	dev, ok := strconv.parse_i64_of_base(h, 16)
	fmt.assertf(ok, "bad device address %q", os.args[3])
	assert(cs.open() != 0, "capstone open failed")
	slots: map[i64]int
	ci: cs.Insn
	for s in fs {
		if s < common.TEXT_LO || s >= common.TEXT_HI do continue
		// By capstone register id: holds the device, holds its vtable.
		devreg, vtreg: [256]bool
		o := int(s - img.base)
		code := img.data[o:min(o + 0x4000, len(img.data))]
		pc := u64(s)
		for len(code) > 0 && cs.decode(raw_data(code), len(code), pc, &ci) > 0 {
			code = code[ci.size:]
			pc += u64(ci.size)
			mn := cs.mnemonic(&ci)
			ops := ci.ops[:ci.op_count]
			if mn == "mov" && len(ops) == 2 && ops[0].type == cs.OP_REG {
				d, src := ops[0].reg, ops[1]
				devreg[d], vtreg[d] = false, false
				if src.type == cs.OP_MEM && src.base == 0 && src.index == 0 && src.disp == dev {
					devreg[d] = true
				} else if src.type == cs.OP_MEM && devreg[src.base] && src.disp == 0 && src.index == 0 {
					vtreg[d] = true
				}
			} else if mn == "call" && ops[0].type == cs.OP_MEM && vtreg[ops[0].base] {
				slots[floor_div(ops[0].disp, 4)] += 1
			}
			if mn == "ret" do break
		}
	}
	keys: [dynamic]i64
	for k in slots do append(&keys, k)
	slice.sort(keys[:])
	for k in keys do fmt.println(k, slots[k])
}

floor_div :: proc(a, b: i64) -> i64 {
	q := a / b
	return q - (a % b != 0 && (a < 0) != (b < 0) ? 1 : 0)
}
