import re, sys
# Symbolic x87 over straight-line runs of gwp.lines. Commutative + and * are
# printed with sorted operands so equal trees print equal.
lines = [l.split(': ', 1) for l in open(sys.argv[1])]
st = []
mem = {}
def name(op):
    op = op.strip('[]')
    return mem.get(op, op)
def bin(o, a, b):
    if o in '+*':
        a, b = sorted([a, b])
    return '(%s %s %s)' % (a, o, b)
out = []
for addr, ins in lines:
    m = re.match(r'(\w+)\s*(.*)', ins); mn, ops = m.group(1), m.group(2)
    ops = [x.strip() for x in ops.split(',')] if ops else []
    def reg(x):
        return int(re.match(r'st\(?(\d)?\)?', x).group(1) or 0)
    if mn == 'fld':
        if ops[0].startswith('st'):
            st.insert(0, st[reg(ops[0])])
        else:
            st.insert(0, name(ops[0]))
    elif mn in ('fmul', 'fadd', 'fsub', 'fsubr', 'fdiv'):
        o = {'fmul':'*','fadd':'+','fsub':'-','fdiv':'/'}[mn]
        if len(ops) == 1:
            st[0] = bin(o, st[0], name(ops[0]))
        else:
            d, sreg = reg(ops[0]), reg(ops[1])
            st[d] = bin(o, st[d], st[sreg])
    elif mn in ('fmulp', 'faddp', 'fsubp'):
        o = {'fmulp':'*','faddp':'+','fsubp':'-'}[mn]
        d = reg(ops[0])
        st[d] = bin(o, st[d], st[0]); st.pop(0)
    elif mn == 'fxch':
        d = reg(ops[0]); st[0], st[d] = st[d], st[0]
    elif mn == 'fstp':
        if ops[0].startswith('st'):
            d = reg(ops[0]); st[d] = st[0]; st.pop(0)
        else:
            mem[ops[0].strip('[]')] = st[0]; out.append('%s %s = %s' % (addr, ops[0], st[0])); st.pop(0)
    elif mn == 'call' or mn == 'jmp' or mn.startswith('j'):
        out.append('%s %s %s   stack=%d' % (addr, mn, ops, len(st)))
        if mn == 'call': mem = {}
        if mn == 'jmp': st = []
    elif mn.startswith('mov') and ops and ops[0].startswith('[esp'):
        mem.pop(ops[0].strip('[]'), None)
print('\n'.join(out))
