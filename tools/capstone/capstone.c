// A flat view of one capstone x86 instruction for the Odin side
// (capstone.odin), so Odin binds three calls instead of capstone's nested
// unions. The operand fields are copied straight out of the C union, as
// Python's capstone binding reads them.
#include <stdint.h>
#include <string.h>
#include <capstone/capstone.h>

typedef struct {
	uint8_t type, size, access, pad;
	uint32_t reg;
	int64_t imm;
	uint32_t segment, base, index;
	int32_t scale;
	int64_t disp;
} je_op;

typedef struct {
	uint32_t address;
	uint16_t size;
	uint8_t op_count, n_read, n_write, n_groups;
	uint8_t bytes[16];
	char mnemonic[32];
	char op_str[160];
	je_op ops[8];
	uint16_t read[64], write[64];
	uint8_t groups[8];
} je_insn;

static csh handle;
static cs_insn *scratch;

int je_cs_open(void) {
	if (cs_open(CS_ARCH_X86, CS_MODE_32, &handle) != CS_ERR_OK) return 0;
	if (cs_option(handle, CS_OPT_DETAIL, CS_OPT_ON) != CS_ERR_OK) return 0;
	scratch = cs_malloc(handle);
	return scratch != NULL;
}

const char *je_cs_reg_name(unsigned reg) {
	return cs_reg_name(handle, reg);
}

// Decodes the first instruction of code at addr; 0 when the bytes decode
// to none, -1 when capstone cannot list its register accesses.
int je_cs_decode(const uint8_t *code, size_t len, uint64_t addr, je_insn *out) {
	if (!cs_disasm_iter(handle, &code, &len, &addr, scratch)) return 0;
	cs_insn *i = scratch;
	cs_x86 *x = &i->detail->x86;
	memset(out, 0, sizeof *out);
	out->address = (uint32_t)i->address;
	out->size = i->size;
	memcpy(out->bytes, i->bytes, i->size);
	memcpy(out->mnemonic, i->mnemonic, sizeof out->mnemonic);
	memcpy(out->op_str, i->op_str, sizeof out->op_str);
	out->op_count = x->op_count;
	out->n_groups = i->detail->groups_count < 8 ? i->detail->groups_count : 8;
	memcpy(out->groups, i->detail->groups, out->n_groups);
	for (int k = 0; k < x->op_count; k++) {
		cs_x86_op *o = &x->operands[k];
		je_op *d = &out->ops[k];
		d->type = (uint8_t)o->type;
		d->size = o->size;
		d->access = o->access;
		d->reg = (uint32_t)o->reg;
		d->imm = o->imm;
		d->segment = (uint32_t)o->mem.segment;
		d->base = (uint32_t)o->mem.base;
		d->index = (uint32_t)o->mem.index;
		d->scale = o->mem.scale;
		d->disp = o->mem.disp;
	}
	cs_regs r, w;
	uint8_t nr = 0, nw = 0;
	if (cs_regs_access(handle, i, r, &nr, w, &nw) != CS_ERR_OK) return -1;
	out->n_read = nr;
	out->n_write = nw;
	memcpy(out->read, r, nr * sizeof r[0]);
	memcpy(out->write, w, nw * sizeof w[0]);
	return 1;
}
