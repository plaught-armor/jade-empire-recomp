#!/usr/bin/env python3
"""Jade Empire compiled NWScript (.ncs) tool. WHY: docs/modding.md §2

Usage:
  ncs.py dis FILE.ncs           disassemble, naming engine calls
  ncs.py asm OUT.ncs 'STMT; ...' assemble a main() made of call statements

The assembler takes engine calls with literal arguments, nested freely:
  ActionMoveToObject(GetObjectByTag("j00c_master_c1"), 1)
Omitted trailing arguments take the engine defaults from
re/nwscript_functions.tsv. Literals: int, float, "string", OBJECT_SELF,
OBJECT_INVALID; a Vector or EngineType argument must be a call such as
GetPosition(o) or Location(GetArea(o), Vector(1.0, 2.0, 0.0), 90.0).
A ScriptState argument (AssignCommand, DelayCommand, ActionDoCommand) is
itself a call statement, compiled as a closure the engine runs later:
  AssignCommand(GetObjectByTag("j00c_master_c1"), ActionStartConversation(GetPlayer()))
A Vector call's component is CALL.x, .y or .z, a Float. Int and Float
operands combine with + - * / (Int only when both are) and compare with
== != < <= > >= (same types; the result is an Int). Two String or two
Object operands compare with == and != only.
No variables or control flow. A final
`return EXPR` makes main() return that Int, which the control channel's
exec reports (docs/modding.md §3). The VM keeps a result only from an
int-typed stack cell, and a copy carries the cell's type, so a Float is
returned scaled, as FloatToInt(EXPR * 1000.0).
"""
import ast
import os
import struct
import sys

HEADER = b"NCS V1.0"
PROGRAM = 0x42
CODE_START = 13
TABLE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "re", "nwscript_functions.tsv")
OBJECT_SELF = 0
OBJECT_INVALID = 1  # NWScript constant; the VM maps it to the invalid object id
TYPE = {"Int": 3, "Float": 4, "String": 5, "Object": 6}
SLOTS = {"Void": 0, "Vector": 3}  # stack cells of a result; every other type is 1
# Parameter types accepted; a Vector or EngineType (Location, Effect) only from a call.
ARGS = set(TYPE) | {"Vector", "EngineType", "ScriptState"}
VECTOR_FIELDS = ("x", "y", "z")  # cell order of a Vector on the VM stack, lowest first
# Operator opcodes and their operand-type byte (NWScript's II, FF, IF, FI).
NUMERIC = ("Int", "Float")
OPERAND_TYPES = {("Int", "Int"): 0x20, ("Float", "Float"): 0x21,
                 ("Int", "Float"): 0x25, ("Float", "Int"): 0x26}
# EQUAL/NEQUAL also take two Objects (OO) or two Strings (SS).
EQUALITY_TYPES = {("Object", "Object"): 0x22, ("String", "String"): 0x23}
ARITHMETIC = {ast.Add: 0x14, ast.Sub: 0x15, ast.Mult: 0x16, ast.Div: 0x17}
COMPARISONS = {ast.Eq: 0x0B, ast.NotEq: 0x0C, ast.GtE: 0x0D, ast.Gt: 0x0E, ast.Lt: 0x0F, ast.LtE: 0x10}
# A closure, as the compiler emits it (j01_cut_bscout1.ncs): STORE_STATE 0x10
# with the frame sizes to save, a JMP over the body, the body, RETN. main()
# has no locals, so both sizes are 0.
STORE_STATE = bytes([0x2C, 0x10]) + struct.pack(">ii", 0, 0)

# Opcode -> (name, total length, or None when the length depends on operands).
OPS = {
    0x01: ("CPDOWNSP", 8), 0x02: ("RSADD", 2), 0x03: ("CPTOPSP", 8), 0x04: ("CONST", None),
    0x05: ("ACTION", 5), 0x06: ("LOGANDII", 2), 0x07: ("LOGORII", 2), 0x08: ("INCORII", 2),
    0x09: ("EXCORII", 2), 0x0A: ("BOOLANDII", 2), 0x0B: ("EQUAL", None), 0x0C: ("NEQUAL", None),
    0x0D: ("GEQ", 2), 0x0E: ("GT", 2), 0x0F: ("LT", 2), 0x10: ("LEQ", 2), 0x11: ("SHLEFTII", 2),
    0x12: ("SHRIGHTII", 2), 0x13: ("USHRIGHTII", 2), 0x14: ("ADD", 2), 0x15: ("SUB", 2),
    0x16: ("MUL", 2), 0x17: ("DIV", 2), 0x18: ("MOD", 2), 0x19: ("NEG", 2), 0x1A: ("COMP", 2),
    0x1B: ("MOVSP", 6), 0x1C: ("STORE_STATEALL", 2), 0x1D: ("JMP", 6), 0x1E: ("JSR", 6),
    0x1F: ("JZ", 6), 0x20: ("RETN", 2), 0x21: ("DESTRUCT", 8), 0x22: ("NOTI", 2),
    0x23: ("DECISP", 6), 0x24: ("INCISP", 6), 0x25: ("JNZ", 6), 0x26: ("CPDOWNBP", 8),
    0x27: ("CPTOPBP", 8), 0x28: ("DECIBP", 6), 0x29: ("INCIBP", 6), 0x2A: ("SAVEBP", 2),
    0x2B: ("RESTOREBP", 2), 0x2C: ("STORE_STATE", 10), 0x2D: ("NOP", 2),
}


def load_table():
    """id -> (name, return, [param types], [defaults]) and name -> id."""
    by_id, by_name = {}, {}
    with open(TABLE) as f:
        for line in f:
            if line.startswith("#") or line.startswith("id\t"):
                continue
            i, name, ret, params, defaults = line.rstrip("\n").split("\t")
            assert int(i) not in by_id and name not in by_name, "duplicate table row: %s" % line
            by_id[int(i)] = (name, ret, params.split(",") if params else [], defaults.split("|") if defaults else [])
            by_name[name] = int(i)
    return by_id, by_name


def insn_len(code, pc):
    op, ty = code[pc], code[pc + 1]
    name, n = OPS[op]
    if n is not None:
        return n
    if op == 0x04:
        return 4 + struct.unpack_from(">H", code, pc + 2)[0] if ty == 5 else 6
    return 4 if ty == 0x24 else 2  # EQUAL/NEQUAL on structures carry a size


def operand(code, pc, n):
    op, ty = code[pc], code[pc + 1]
    if op == 0x04:
        if ty == 3:
            return str(struct.unpack_from(">i", code, pc + 2)[0])
        if ty == 4:
            return repr(struct.unpack_from(">f", code, pc + 2)[0])
        if ty == 5:
            return repr(code[pc + 4:pc + n].decode("latin-1"))
        return "object %#x" % struct.unpack_from(">I", code, pc + 2)[0]
    if op == 0x05:
        fid, argc = struct.unpack_from(">HB", code, pc + 2)
        return "%s(%d) argc=%d" % (TABLE_BY_ID.get(fid, ("?",))[0], fid, argc)
    if n == 6:
        return str(struct.unpack_from(">i", code, pc + 2)[0])
    if n == 8:
        return "%d %d" % struct.unpack_from(">iH", code, pc + 2)
    if n == 10:
        return "%d %d" % struct.unpack_from(">ii", code, pc + 2)
    return "type=%#x" % ty


def disassemble(data):
    if data[:8] != HEADER or data[8] != PROGRAM:
        raise SystemExit("not an NCS V1.0 program")
    size = struct.unpack_from(">I", data, 9)[0]
    if size != len(data):
        raise SystemExit("header size %d, file %d" % (size, len(data)))
    out, pc = [], CODE_START
    for _ in range(len(data)):
        if pc >= len(data):
            break
        if data[pc] not in OPS:
            raise SystemExit("unknown opcode %#x at %#x" % (data[pc], pc))
        n = insn_len(data, pc)
        out.append("%06x %-14s %s" % (pc, OPS[data[pc]][0], operand(data, pc, n)))
        pc += n
    if pc != len(data):
        raise SystemExit("code overruns the file at %#x" % pc)
    return out


def literal(v, ty):
    if isinstance(v, ast.Name) and v.id in ("OBJECT_SELF", "OBJECT_INVALID"):
        if ty != "Object":
            raise SystemExit("%s where %s expected" % (v.id, ty))
        return bytes([0x04, 6]) + struct.pack(">I", OBJECT_SELF if v.id == "OBJECT_SELF" else OBJECT_INVALID)
    if isinstance(v, ast.UnaryOp) and isinstance(v.op, ast.USub) and isinstance(v.operand, ast.Constant):
        if not isinstance(v.operand.value, (int, float)) or isinstance(v.operand.value, bool):
            raise SystemExit("-%r is not a number" % (v.operand.value,))
        v = ast.Constant(value=-v.operand.value)  # a negative literal parses as a negation
    if not isinstance(v, ast.Constant):
        raise SystemExit("unsupported argument %s" % ast.dump(v))
    x = v.value
    if ty == "Int" and isinstance(x, int):
        return bytes([0x04, 3]) + struct.pack(">i", x)
    if ty == "Float" and isinstance(x, (int, float)):
        return bytes([0x04, 4]) + struct.pack(">f", float(x))
    if ty == "String" and isinstance(x, str):
        b = x.encode("latin-1")
        return bytes([0x04, 5]) + struct.pack(">H", len(b)) + b
    raise SystemExit("literal %r where %s expected" % (x, ty))


def default(text, ty):
    """A defaults-column entry as an ast literal of type ty."""
    if text in ("OBJECT_SELF", "OBJECT_INVALID"):
        return ast.Name(id=text)
    if text[:1].isalpha() and ty != "String":
        raise SystemExit("default %s has no known value; pass the argument explicitly" % text)
    if ty == "String":
        return ast.Constant(value=text.strip('"'))
    return ast.Constant(value=float(text) if ty == "Float" else int(text))


def emit_call(node):
    """Code for one call expression; returns (bytes, result type)."""
    if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Name):
        raise SystemExit("expected an engine call, got %s" % ast.dump(node))
    name = node.func.id
    if name not in TABLE_BY_NAME:
        raise SystemExit("unknown engine function %s" % name)
    fid = TABLE_BY_NAME[name]
    _, ret, params, defaults = TABLE_BY_ID[fid]
    args = list(node.args)
    first_default = len(params) - len(defaults)
    if not first_default <= len(args) <= len(params):
        raise SystemExit("%s takes %d..%d arguments" % (name, first_default, len(params)))
    for i in range(len(args), len(params)):
        args.append(default(defaults[i - first_default], params[i]))
    code = b""
    for a, ty in reversed(list(zip(args, params))):  # the last argument is pushed first
        if ty not in ARGS:
            raise SystemExit("%s: parameter type %s not supported" % (name, ty))
        if ty == "ScriptState":
            body = statement(a) + bytes([0x20, 0])
            code += STORE_STATE + bytes([0x1D, 0]) + struct.pack(">i", 6 + len(body)) + body
        elif isinstance(a, (ast.Call, ast.Attribute, ast.BinOp, ast.Compare)):
            c, rt = expr(a)
            if rt != ty:
                raise SystemExit("%s is %s where %s expected" % (ast.unparse(a), rt, ty))
            code += c
        else:
            code += literal(a, ty)
    return code + bytes([0x05, 0]) + struct.pack(">HB", fid, len(params)), ret


def operand_type(node):
    """Type of a bare literal used as an operator operand, from its Python value."""
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
        node = node.operand
    if not isinstance(node, ast.Constant) or isinstance(node.value, bool):
        raise SystemExit("unsupported operand %s" % ast.unparse(node))
    if isinstance(node.value, int):
        return "Int"
    if isinstance(node.value, float):
        return "Float"
    if isinstance(node.value, str):
        return "String"
    raise SystemExit("operand %r is not a number or a string" % (node.value,))


def binary(op, left, right):
    """Code for left OP right on Int and Float operands, or == and != on two
    Strings or two Objects; (bytes, type)."""
    code, types = b"", []
    for side in (left, right):  # the left operand is pushed first
        if isinstance(side, (ast.Constant, ast.UnaryOp)):
            ty = operand_type(side)
            code += literal(side, ty)
        else:
            c, ty = expr(side)
            code += c
        types.append(ty)
    pair = tuple(types)
    if pair in EQUALITY_TYPES and op in (ast.Eq, ast.NotEq):
        return code + bytes([COMPARISONS[op], EQUALITY_TYPES[pair]]), "Int"
    for side, ty in zip((left, right), pair):
        if ty not in NUMERIC:
            raise SystemExit("%s is %s; this operator takes Int and Float" % (ast.unparse(side), ty))
    if op in COMPARISONS:
        if pair[0] != pair[1]:
            raise SystemExit("comparison of %s with %s" % pair)
        return code + bytes([COMPARISONS[op], OPERAND_TYPES[pair]]), "Int"
    if op not in ARITHMETIC:
        raise SystemExit("unsupported operator %s" % op.__name__)
    rt = "Int" if pair == ("Int", "Int") else "Float"
    return code + bytes([ARITHMETIC[op], OPERAND_TYPES[pair]]), rt


def expr(node):
    """Code for a call, a Vector component (CALL.x, .y, .z) or an operator
    expression over them and numeric literals; (bytes, type)."""
    if isinstance(node, ast.BinOp):
        return binary(type(node.op), node.left, node.right)
    if isinstance(node, ast.Compare):
        if len(node.ops) != 1:
            raise SystemExit("chained comparison %s" % ast.unparse(node))
        return binary(type(node.ops[0]), node.left, node.comparators[0])
    if not isinstance(node, ast.Attribute):
        return emit_call(node)
    if node.attr not in VECTOR_FIELDS:
        raise SystemExit("unknown field .%s; a Vector has .x, .y, .z" % node.attr)
    c, rt = emit_call(node.value)
    if rt != "Vector":
        raise SystemExit("%s is %s, not a Vector" % (ast.unparse(node.value), rt))
    # Copy the component to the top, store it over the vector's first cell,
    # then drop the rest.
    k = VECTOR_FIELDS.index(node.attr)
    c += bytes([0x03, 1]) + struct.pack(">iH", -12 + 4 * k, 4)
    c += bytes([0x01, 1]) + struct.pack(">iH", -16, 4)
    c += bytes([0x1B, 0]) + struct.pack(">i", -12)
    return c, "Float"


def statement(node):
    """Code for one call whose result is dropped."""
    c, rt = emit_call(node)
    cells = SLOTS.get(rt, 1)
    if cells:
        c += bytes([0x1B, 0]) + struct.pack(">i", -4 * cells)  # drop the unused result
    return c


def assemble(src):
    body = ast.parse(src).body
    ret = body[-1] if body and isinstance(body[-1], ast.Return) else None
    code = b""
    for stmt in body[:-1] if ret else body:
        if not isinstance(stmt, ast.Expr):
            raise SystemExit("only call statements and a final return are supported")
        code += statement(stmt.value)
    if ret is None:
        code += bytes([0x20, 0])
        return HEADER + bytes([PROGRAM]) + struct.pack(">I", CODE_START + len(code)) + code
    c, rt = expr(ret.value)
    if rt != "Int":
        raise SystemExit("return of %s; only Int is supported" % rt)
    # As the compiler emits an int main (e.g. j04_c_gold_14b.ncs): reserve the
    # result cell, call the body, which copies its value down into the cell.
    head = bytes([0x02, TYPE[rt], 0x1E, 0]) + struct.pack(">i", 8) + bytes([0x20, 0])
    tail = bytes([0x01, 0]) + struct.pack(">iH", -8, 4) + bytes([0x1B, 0]) + struct.pack(">i", -4) + bytes([0x20, 0])
    code = head + code + c + tail
    return HEADER + bytes([PROGRAM]) + struct.pack(">I", CODE_START + len(code)) + code


TABLE_BY_ID, TABLE_BY_NAME = load_table()


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "dis":
        with open(sys.argv[2], "rb") as f:
            print("\n".join(disassemble(f.read())))
    elif len(sys.argv) == 4 and sys.argv[1] == "asm":
        with open(sys.argv[2], "wb") as f:
            f.write(assemble(sys.argv[3]))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
