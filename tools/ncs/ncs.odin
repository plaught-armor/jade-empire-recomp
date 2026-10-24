// Jade Empire compiled NWScript (.ncs) tool. WHY: docs/modding.md §2
//
// Usage:
//   ncs dis FILE.ncs           disassemble, naming engine calls
//   ncs asm OUT.ncs 'STMT; ...' assemble a main() made of call statements
//
// The assembler takes engine calls with literal arguments, nested freely:
//   ActionMoveToObject(GetObjectByTag("j00c_master_c1"), 1)
// Omitted trailing arguments take the engine defaults from
// re/nwscript_functions.tsv (built in). Literals: int, float, "string",
// OBJECT_SELF, OBJECT_INVALID; a Vector or EngineType argument must be a call
// such as GetPosition(o) or Location(GetArea(o), Vector(1.0, 2.0, 0.0), 90.0).
// A ScriptState argument (AssignCommand, DelayCommand, ActionDoCommand) is
// itself a call statement, compiled as a closure the engine runs later:
//   AssignCommand(GetObjectByTag("j00c_master_c1"), ActionStartConversation(GetPlayer()))
// A Vector call's component is CALL.x, .y or .z, a Float. Int and Float
// operands combine with + - * / (Int only when both are) and compare with
// == != < <= > >= (same types; the result is an Int). Two String or two
// Object operands compare with == and != only.
// No variables or control flow. A final
// `return EXPR` makes main() return that Int, which the control channel's
// exec reports (docs/modding.md §3). The VM keeps a result only from an
// int-typed stack cell, and a copy carries the cell's type, so a Float is
// returned scaled, as FloatToInt(EXPR * 1000.0).
//
// The source is Python expression syntax (the tool was Python's ast first);
// parse reads the subset above.
package ncs

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "../common"

USAGE :: `Usage:
  ncs dis FILE.ncs           disassemble, naming engine calls
  ncs asm OUT.ncs 'STMT; ...' assemble a main() made of call statements`

HEADER :: "NCS V1.0"
PROGRAM :: 0x42
CODE_START :: 13
TABLE :: #load("../../re/nwscript_functions.tsv", string)
OBJECT_SELF :: 0
OBJECT_INVALID :: 1 // NWScript constant; the VM maps it to the invalid object id
VECTOR_FIELDS :: [3]string{"x", "y", "z"} // cell order of a Vector on the VM stack, lowest first
// A closure, as the compiler emits it (j01_cut_bscout1.ncs): STORE_STATE 0x10
// with the frame sizes to save, a JMP over the body, the body, RETN. main()
// has no locals, so both sizes are 0.
STORE_STATE :: [10]u8{0x2C, 0x10, 0, 0, 0, 0, 0, 0, 0, 0}

// Stack cell type byte of a value type.
type_byte :: proc(t: string) -> (u8, bool) {
	switch t {
	case "Int": return 3, true
	case "Float": return 4, true
	case "String": return 5, true
	case "Object": return 6, true
	}
	return 0, false
}

// Stack cells of a result; every other type is 1.
slots :: proc(t: string) -> int {
	switch t {
	case "Void": return 0
	case "Vector": return 3
	}
	return 1
}

// Parameter types accepted; a Vector or EngineType (Location, Effect) only from a call.
arg_ok :: proc(t: string) -> bool {
	_, ok := type_byte(t)
	return ok || t == "Vector" || t == "EngineType" || t == "ScriptState"
}

numeric :: proc(t: string) -> bool {return t == "Int" || t == "Float"}

// Operator operand-type byte (NWScript's II, FF, IF, FI); EQUAL/NEQUAL also
// take two Objects (OO) or two Strings (SS).
operand_types :: proc(a, b: string) -> (u8, bool) {
	switch {
	case a == "Int" && b == "Int": return 0x20, true
	case a == "Float" && b == "Float": return 0x21, true
	case a == "Int" && b == "Float": return 0x25, true
	case a == "Float" && b == "Int": return 0x26, true
	}
	return 0, false
}

equality_types :: proc(a, b: string) -> (u8, bool) {
	switch {
	case a == "Object" && b == "Object": return 0x22, true
	case a == "String" && b == "String": return 0x23, true
	}
	return 0, false
}

arithmetic :: proc(op: string) -> (u8, bool) {
	switch op {
	case "+": return 0x14, true
	case "-": return 0x15, true
	case "*": return 0x16, true
	case "/": return 0x17, true
	}
	return 0, false
}

comparison :: proc(op: string) -> (u8, bool) {
	switch op {
	case "==": return 0x0B, true
	case "!=": return 0x0C, true
	case ">=": return 0x0D, true
	case ">": return 0x0E, true
	case "<": return 0x0F, true
	case "<=": return 0x10, true
	}
	return 0, false
}

Op_Info :: struct {
	name: string,
	n:    int, // total length, 0 when it depends on operands
}

OPS := [0x2E]Op_Info {
	0x01 = {"CPDOWNSP", 8}, 0x02 = {"RSADD", 2}, 0x03 = {"CPTOPSP", 8}, 0x04 = {"CONST", 0},
	0x05 = {"ACTION", 5}, 0x06 = {"LOGANDII", 2}, 0x07 = {"LOGORII", 2}, 0x08 = {"INCORII", 2},
	0x09 = {"EXCORII", 2}, 0x0A = {"BOOLANDII", 2}, 0x0B = {"EQUAL", 0}, 0x0C = {"NEQUAL", 0},
	0x0D = {"GEQ", 2}, 0x0E = {"GT", 2}, 0x0F = {"LT", 2}, 0x10 = {"LEQ", 2}, 0x11 = {"SHLEFTII", 2},
	0x12 = {"SHRIGHTII", 2}, 0x13 = {"USHRIGHTII", 2}, 0x14 = {"ADD", 2}, 0x15 = {"SUB", 2},
	0x16 = {"MUL", 2}, 0x17 = {"DIV", 2}, 0x18 = {"MOD", 2}, 0x19 = {"NEG", 2}, 0x1A = {"COMP", 2},
	0x1B = {"MOVSP", 6}, 0x1C = {"STORE_STATEALL", 2}, 0x1D = {"JMP", 6}, 0x1E = {"JSR", 6},
	0x1F = {"JZ", 6}, 0x20 = {"RETN", 2}, 0x21 = {"DESTRUCT", 8}, 0x22 = {"NOTI", 2},
	0x23 = {"DECISP", 6}, 0x24 = {"INCISP", 6}, 0x25 = {"JNZ", 6}, 0x26 = {"CPDOWNBP", 8},
	0x27 = {"CPTOPBP", 8}, 0x28 = {"DECIBP", 6}, 0x29 = {"INCIBP", 6}, 0x2A = {"SAVEBP", 2},
	0x2B = {"RESTOREBP", 2}, 0x2C = {"STORE_STATE", 10}, 0x2D = {"NOP", 2},
}

Fn :: struct {
	name, ret:        string,
	params, defaults: []string,
}

by_id: map[int]Fn
by_name: map[string]int

@(init)
load_table :: proc "contextless" () {
	context = runtime.default_context()
	text := TABLE
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "#") || strings.has_prefix(line, "id\t") do continue
		f := strings.split(strings.trim_right(line, "\r"), "\t")
		fmt.assertf(len(f) == 5, "bad table row: %s", line)
		i, ok := strconv.parse_int(f[0], 10)
		fmt.assertf(ok && i not_in by_id && f[1] not_in by_name, "duplicate table row: %s", line)
		by_id[i] = {f[1], f[2], f[3] != "" ? strings.split(f[3], ",") : nil, f[4] != "" ? strings.split(f[4], "|") : nil}
		by_name[f[1]] = i
	}
}

be :: proc(b: ^[dynamic]u8, v: i64, n: int) {
	for k := n - 1; k >= 0; k -= 1 do append(b, u8(u64(v) >> uint(8 * k)))
}

be_at :: proc(d: []u8, o, n: int) -> u64 {
	v: u64
	for k in 0 ..< n do v = v << 8 | u64(d[o + k])
	return v
}

i32_at :: proc(d: []u8, o: int) -> i32 {return i32(u32(be_at(d, o, 4)))}

insn_len :: proc(code: []u8, pc: int) -> int {
	op, ty := code[pc], code[pc + 1]
	if n := OPS[op].n; n != 0 do return n
	if op == 0x04 do return ty == 5 ? 4 + int(be_at(code, pc + 2, 2)) : 6
	return ty == 0x24 ? 4 : 2 // EQUAL/NEQUAL on structures carry a size
}

operand :: proc(code: []u8, pc, n: int) -> string {
	op, ty := code[pc], code[pc + 1]
	if op == 0x04 {
		switch ty {
		case 3: return fmt.aprintf("%d", i32_at(code, pc + 2))
		case 4: return common.py_repr_float(f64(transmute(f32)u32(be_at(code, pc + 2, 4))))
		case 5: return common.py_repr_str(common.latin1(code[pc + 4:pc + n]))
		}
		return fmt.aprintf("object %#x", be_at(code, pc + 2, 4))
	}
	if op == 0x05 {
		fid, argc := int(be_at(code, pc + 2, 2)), code[pc + 4]
		name := "?"
		if f, ok := by_id[fid]; ok do name = f.name
		return fmt.aprintf("%s(%d) argc=%d", name, fid, argc)
	}
	switch n {
	case 6: return fmt.aprintf("%d", i32_at(code, pc + 2))
	case 8: return fmt.aprintf("%d %d", i32_at(code, pc + 2), be_at(code, pc + 6, 2))
	case 10: return fmt.aprintf("%d %d", i32_at(code, pc + 2), i32_at(code, pc + 6))
	}
	return fmt.aprintf("type=%#x", ty)
}

disassemble :: proc(data: []u8) -> []string {
	if len(data) < CODE_START || string(data[:8]) != HEADER || data[8] != PROGRAM do common.die("not an NCS V1.0 program")
	size := int(be_at(data, 9, 4))
	if size != len(data) do common.die("header size %d, file %d", size, len(data))
	out: [dynamic]string
	pc := CODE_START
	for _ in 0 ..< len(data) {
		if pc >= len(data) do break
		if int(data[pc]) >= len(OPS) || OPS[data[pc]].name == "" do common.die("unknown opcode %#x at %#x", data[pc], pc)
		n := insn_len(data, pc)
		append(&out, fmt.aprintf("%06x %-14s %s", pc, OPS[data[pc]].name, operand(data, pc, n)))
		pc += n
	}
	if pc != len(data) do common.die("code overruns the file at %#x", pc)
	return out[:]
}

// Expression syntax tree, shaped as Python's ast for the subset parsed.
Kind :: enum {
	Call, // name(args)
	Name, // name
	Attr, // args[0].name
	Bin, // args[0] name args[1]
	Compare, // args[0] ops[0] args[1] ops[1] ...
	Neg, // -args[0]
	Int,
	Float,
	Str,
	Bool,
}

Node :: struct {
	kind: Kind,
	name: string,
	args: []^Node,
	ops:  []string,
	i:    i64,
	f:    f64,
	s:    string,
}

Stmt :: struct {
	ret:   bool,
	value: ^Node,
}

constant :: proc(n: ^Node) -> bool {return n.kind >= .Int}

// Python source text of a node, for messages.
unparse :: proc(n: ^Node) -> string {
	switch n.kind {
	case .Call:
		a := make([]string, len(n.args))
		for x, k in n.args do a[k] = unparse(x)
		return fmt.aprintf("%s(%s)", n.name, strings.join(a, ", "))
	case .Name: return n.name
	case .Attr: return fmt.aprintf("%s.%s", unparse(n.args[0]), n.name)
	case .Bin: return fmt.aprintf("%s %s %s", unparse(n.args[0]), n.name, unparse(n.args[1]))
	case .Compare:
		sb := strings.builder_make()
		strings.write_string(&sb, unparse(n.args[0]))
		for op, k in n.ops do fmt.sbprintf(&sb, " %s %s", op, unparse(n.args[k + 1]))
		return strings.to_string(sb)
	case .Neg: return fmt.aprintf("-%s", unparse(n.args[0]))
	case .Int: return fmt.aprintf("%d", n.i)
	case .Float: return common.py_repr_float(n.f)
	case .Str: return common.py_repr_str(n.s)
	case .Bool: return n.i != 0 ? "True" : "False"
	}
	return "?"
}

Parser :: struct {
	src: string,
	pos: int,
}

is_ident :: proc(c: u8) -> bool {
	return 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || c == '_' || '0' <= c && c <= '9'
}

// Skips blanks, and line ends too inside brackets (depth > 0).
skip :: proc(p: ^Parser, depth: int) {
	for p.pos < len(p.src) {
		c := p.src[p.pos]
		if c == ' ' || c == '\t' || c == '\f' || depth > 0 && (c == '\n' || c == '\r') {
			p.pos += 1
		} else if c == '\\' && p.pos + 1 < len(p.src) && p.src[p.pos + 1] == '\n' {
			p.pos += 2
		} else if c == '#' {
			for p.pos < len(p.src) && p.src[p.pos] != '\n' do p.pos += 1
		} else do break
	}
}

// The next token's text without consuming it: an operator, a name, or the
// first character of a literal.
peek :: proc(p: ^Parser, depth: int) -> string {
	skip(p, depth)
	if p.pos >= len(p.src) do return ""
	s := p.src[p.pos:]
	for op in ([]string{"==", "!=", "<=", ">=", "**", "//"}) do if strings.has_prefix(s, op) do return op
	if is_ident(s[0]) && !('0' <= s[0] && s[0] <= '9') {
		e := 1
		for e < len(s) && is_ident(s[e]) do e += 1
		return s[:e]
	}
	return s[:1]
}

take :: proc(p: ^Parser, depth: int, want: string) -> bool {
	if peek(p, depth) != want do return false
	p.pos += len(want)
	return true
}

expect :: proc(p: ^Parser, depth: int, want: string) {
	if !take(p, depth, want) do common.die("syntax error at %d: expected %q", p.pos, want)
}

new_node :: proc(kind: Kind, name: string, args: ..^Node) -> ^Node {
	n := new(Node)
	n^ = {kind = kind, name = name, args = make([]^Node, len(args))}
	copy(n.args, args)
	return n
}

comparison_expr :: proc(p: ^Parser, d: int) -> ^Node {
	left := additive(p, d)
	ops: [dynamic]string
	args: [dynamic]^Node
	append(&args, left)
	for {
		t := peek(p, d)
		if _, ok := comparison(t); !ok do break
		p.pos += len(t)
		append(&ops, t)
		append(&args, additive(p, d))
	}
	if len(ops) == 0 do return left
	n := new_node(.Compare, "")
	n.args, n.ops = args[:], ops[:]
	return n
}

additive :: proc(p: ^Parser, d: int) -> ^Node {
	n := multiplicative(p, d)
	for {
		t := peek(p, d)
		if t != "+" && t != "-" do return n
		p.pos += 1
		n = new_node(.Bin, t, n, multiplicative(p, d))
	}
}

multiplicative :: proc(p: ^Parser, d: int) -> ^Node {
	n := unary(p, d)
	for {
		t := peek(p, d)
		if t == "//" || t == "%" || t == "**" do common.die("unsupported operator %s", t)
		if t != "*" && t != "/" do return n
		p.pos += 1
		n = new_node(.Bin, t, n, unary(p, d))
	}
}

unary :: proc(p: ^Parser, d: int) -> ^Node {
	if take(p, d, "-") do return new_node(.Neg, "", unary(p, d))
	if peek(p, d) == "+" do common.die("unsupported unary +")
	return postfix(p, d)
}

postfix :: proc(p: ^Parser, d: int) -> ^Node {
	n := atom(p, d)
	for {
		if take(p, d, ".") {
			t := peek(p, d)
			if t == "" || !is_ident(t[0]) do common.die("syntax error at %d: expected a field name", p.pos)
			p.pos += len(t)
			n = new_node(.Attr, t, n)
		} else if take(p, d, "(") {
			if n.kind != .Name do common.die("expected an engine call, got %s(...)", unparse(n))
			args: [dynamic]^Node
			for !take(p, d + 1, ")") {
				append(&args, comparison_expr(p, d + 1))
				if !take(p, d + 1, ",") {
					expect(p, d + 1, ")")
					break
				}
			}
			n.kind, n.args = .Call, args[:]
		} else do return n
	}
}

atom :: proc(p: ^Parser, d: int) -> ^Node {
	t := peek(p, d)
	switch {
	case t == "":
		common.die("syntax error: unexpected end of source")
	case t == "(":
		p.pos += 1
		n := comparison_expr(p, d + 1)
		expect(p, d + 1, ")")
		return n
	case t == "\"" || t == "'":
		n := new_node(.Str, "")
		sb := strings.builder_make()
		// Adjacent string literals join, as in Python.
		for {
			string_literal(p, &sb)
			t2 := peek(p, d)
			if t2 != "\"" && t2 != "'" do break
		}
		n.s = strings.to_string(sb)
		return n
	case '0' <= t[0] && t[0] <= '9' || t == "." && p.pos + 1 < len(p.src) && '0' <= p.src[p.pos + 1] && p.src[p.pos + 1] <= '9':
		return number(p)
	case is_ident(t[0]):
		p.pos += len(t)
		if t == "True" || t == "False" {
			n := new_node(.Bool, "")
			n.i = t == "True" ? 1 : 0
			return n
		}
		return new_node(.Name, t)
	}
	common.die("syntax error at %d: unexpected %q", p.pos, t)
}

number :: proc(p: ^Parser) -> ^Node {
	s := p.src[p.pos:]
	e := 0
	is_float := false
	if len(s) > 1 && s[0] == '0' && strings.index_byte("xXoObB", s[1]) >= 0 {
		e = 2
		for e < len(s) && is_ident(s[e]) do e += 1
	} else {
		for e < len(s) && ('0' <= s[e] && s[e] <= '9' || s[e] == '_') do e += 1
		if e < len(s) && s[e] == '.' {
			is_float = true
			e += 1
			for e < len(s) && ('0' <= s[e] && s[e] <= '9' || s[e] == '_') do e += 1
		}
		if e < len(s) && (s[e] == 'e' || s[e] == 'E') {
			is_float = true
			e += 1
			if e < len(s) && (s[e] == '+' || s[e] == '-') do e += 1
			for e < len(s) && ('0' <= s[e] && s[e] <= '9' || s[e] == '_') do e += 1
		}
	}
	text, _ := strings.remove_all(s[:e], "_")
	p.pos += e
	if e < len(s) && is_ident(s[e]) do common.die("syntax error at %d: bad number %q", p.pos, s[:e + 1])
	n := new_node(.Int, "")
	ok: bool
	if is_float {
		n.kind = .Float
		n.f, ok = strconv.parse_f64(text)
	} else {
		n.i, ok = strconv.parse_i64(text)
		if ok && len(text) > 1 && text[0] == '0' && strings.index_byte("xXoObB", text[1]) < 0 {
			for c in transmute([]u8)text do if c != '0' do common.die("syntax error: leading zeros in %s", text)
		}
	}
	if !ok do common.die("syntax error: bad number %q", text)
	return n
}

// A Python string literal at p.pos (no prefixes), appended to sb as text.
string_literal :: proc(p: ^Parser, sb: ^strings.Builder) {
	q := p.src[p.pos]
	triple := strings.has_prefix(p.src[p.pos:], q == '"' ? `"""` : "'''")
	p.pos += triple ? 3 : 1
	for {
		if p.pos >= len(p.src) do common.die("unterminated string literal")
		c := p.src[p.pos]
		if c == q && (!triple || strings.has_prefix(p.src[p.pos:], q == '"' ? `"""` : "'''")) {
			p.pos += triple ? 3 : 1
			return
		}
		if c == '\n' && !triple do common.die("unterminated string literal")
		if c != '\\' {
			r, n := utf8_rune(p.src[p.pos:])
			strings.write_rune(sb, r)
			p.pos += n
			continue
		}
		p.pos += 1
		if p.pos >= len(p.src) do common.die("unterminated string literal")
		e := p.src[p.pos]
		p.pos += 1
		switch e {
		case '\n':
		case '\\', '\'', '"': strings.write_byte(sb, e)
		case 'a': strings.write_byte(sb, 7)
		case 'b': strings.write_byte(sb, 8)
		case 'f': strings.write_byte(sb, 12)
		case 'n': strings.write_byte(sb, '\n')
		case 'r': strings.write_byte(sb, '\r')
		case 't': strings.write_byte(sb, '\t')
		case 'v': strings.write_byte(sb, 11)
		case '0' ..= '7':
			v := int(e - '0')
			for k := 0; k < 2 && p.pos < len(p.src) && '0' <= p.src[p.pos] && p.src[p.pos] <= '7'; k += 1 {
				v = v * 8 + int(p.src[p.pos] - '0')
				p.pos += 1
			}
			strings.write_rune(sb, rune(v))
		case 'x', 'u', 'U':
			n := e == 'x' ? 2 : e == 'u' ? 4 : 8
			if p.pos + n > len(p.src) do common.die("truncated \\%c escape", e)
			v, ok := strconv.parse_int(p.src[p.pos:p.pos + n], 16)
			if !ok do common.die("truncated \\%c escape", e)
			strings.write_rune(sb, rune(v))
			p.pos += n
		case:
			// Python keeps an unknown escape as written.
			strings.write_byte(sb, '\\')
			p.pos -= 1
		}
	}
}

utf8_rune :: proc(s: string) -> (rune, int) {
	for r, i in s {
		_ = i
		n := 1
		for n < len(s) && s[n] & 0xC0 == 0x80 do n += 1
		return r, n
	}
	return 0, 0
}

// Statements separated by ';' or line ends: expressions, and `return EXPR`.
parse :: proc(src: string) -> []Stmt {
	p := Parser{src = src}
	out: [dynamic]Stmt
	for {
		for take(&p, 0, ";") || take(&p, 0, "\n") || take(&p, 0, "\r") {}
		if peek(&p, 0) == "" do break
		st: Stmt
		if peek(&p, 0) == "return" {
			p.pos += len("return")
			st.ret = true
		}
		st.value = comparison_expr(&p, 0)
		append(&out, st)
		t := peek(&p, 0)
		if t != "" && t != ";" && t != "\n" && t != "\r" do common.die("syntax error at %d: unexpected %q", p.pos, t)
	}
	return out[:]
}

// One expression, as Python's ast.parse(mode="eval").
parse_expr :: proc(src: string) -> ^Node {
	p := Parser{src = src}
	n := comparison_expr(&p, 0)
	for take(&p, 0, "\n") || take(&p, 0, "\r") {}
	if peek(&p, 0) != "" do common.die("syntax error at %d: unexpected %q", p.pos, peek(&p, 0))
	return n
}

literal :: proc(b: ^[dynamic]u8, v: ^Node, ty: string) {
	v := v
	if v.kind == .Name && (v.name == "OBJECT_SELF" || v.name == "OBJECT_INVALID") {
		if ty != "Object" do common.die("%s where %s expected", v.name, ty)
		append(b, 0x04, 6)
		be(b, v.name == "OBJECT_SELF" ? OBJECT_SELF : OBJECT_INVALID, 4)
		return
	}
	if v.kind == .Neg && constant(v.args[0]) {
		c := v.args[0]
		if c.kind != .Int && c.kind != .Float do common.die("-%s is not a number", unparse(c))
		// a negative literal parses as a negation
		neg := new(Node)
		neg^ = c^
		neg.i, neg.f = -c.i, -c.f
		v = neg
	}
	if !constant(v) do common.die("unsupported argument %s", unparse(v))
	switch {
	case ty == "Int" && (v.kind == .Int || v.kind == .Bool):
		if v.i < i64(min(i32)) || v.i > i64(max(i32)) do common.die("argument out of range: %d", v.i)
		append(b, 0x04, 3)
		be(b, i64(v.i), 4)
	case ty == "Float" && (v.kind == .Int || v.kind == .Bool || v.kind == .Float):
		f := v.kind == .Float ? v.f : f64(v.i)
		f32v := f32(f)
		if f32v != f32v + 0 || (abs(f) <= max(f64) && abs(f32v) > max(f32)) do common.die("float too large to pack with f format")
		append(b, 0x04, 4)
		be(b, i64(transmute(u32)f32v), 4)
	case ty == "String" && v.kind == .Str:
		s := make([dynamic]u8)
		for r in v.s {
			if r > 0xff do common.die("'latin-1' codec can't encode character %q", r)
			append(&s, u8(r))
		}
		append(b, 0x04, 5)
		be(b, i64(len(s)), 2)
		append(b, ..s[:])
	case:
		common.die("literal %s where %s expected", unparse(v), ty)
	}
}

// A defaults-column entry as a literal node of type ty.
default_arg :: proc(text, ty: string) -> ^Node {
	if text == "OBJECT_SELF" || text == "OBJECT_INVALID" do return new_node(.Name, text)
	if len(text) > 0 && (('a' <= text[0] && text[0] <= 'z') || ('A' <= text[0] && text[0] <= 'Z')) && ty != "String" {
		common.die("default %s has no known value; pass the argument explicitly", text)
	}
	n := new_node(.Int, "")
	ok := true
	switch ty {
	case "String":
		n.kind, n.s = .Str, strings.trim(text, "\"")
	case "Float":
		n.kind = .Float
		n.f, ok = strconv.parse_f64(strings.trim_space(text))
	case:
		n.i, ok = strconv.parse_i64(strings.trim_space(text), 10)
	}
	if !ok do common.die("default %s is not a %s", text, ty)
	return n
}

emit_call :: proc(b: ^[dynamic]u8, node: ^Node) -> string {
	if node.kind != .Call do common.die("expected an engine call, got %s", unparse(node))
	fid, ok := by_name[node.name]
	if !ok do common.die("unknown engine function %s", node.name)
	fn := by_id[fid]
	args := make([dynamic]^Node)
	append(&args, ..node.args)
	first_default := len(fn.params) - len(fn.defaults)
	if !(first_default <= len(args) && len(args) <= len(fn.params)) do common.die("%s takes %d..%d arguments", node.name, first_default, len(fn.params))
	for i in len(args) ..< len(fn.params) do append(&args, default_arg(fn.defaults[i - first_default], fn.params[i]))
	for i := len(args) - 1; i >= 0; i -= 1 { // the last argument is pushed first
		a, ty := args[i], fn.params[i]
		if !arg_ok(ty) do common.die("%s: parameter type %s not supported", node.name, ty)
		switch {
		case ty == "ScriptState":
			body := make([dynamic]u8)
			statement(&body, a)
			append(&body, 0x20, 0)
			st := STORE_STATE
			append(b, ..st[:])
			append(b, 0x1D, 0)
			be(b, i64(6 + len(body)), 4)
			append(b, ..body[:])
		case a.kind == .Call || a.kind == .Attr || a.kind == .Bin || a.kind == .Compare:
			rt := expr(b, a)
			if rt != ty do common.die("%s is %s where %s expected", unparse(a), rt, ty)
		case:
			literal(b, a, ty)
		}
	}
	append(b, 0x05, 0)
	be(b, i64(fid), 2)
	append(b, u8(len(fn.params)))
	return fn.ret
}

// Type of a bare literal used as an operator operand.
operand_type :: proc(node: ^Node) -> string {
	n := node
	if n.kind == .Neg do n = n.args[0]
	#partial switch n.kind {
	case .Int: return "Int"
	case .Float: return "Float"
	case .Str: return "String"
	}
	common.die("unsupported operand %s", unparse(n))
}

// Code for left OP right on Int and Float operands, or == and != on two
// Strings or two Objects; returns the result type.
binary :: proc(b: ^[dynamic]u8, op: string, left, right: ^Node) -> string {
	sides := [2]^Node{left, right}
	types: [2]string
	for side, k in sides { // the left operand is pushed first
		if constant(side) || side.kind == .Neg {
			types[k] = operand_type(side)
			literal(b, side, types[k])
		} else do types[k] = expr(b, side)
	}
	if t, ok := equality_types(types[0], types[1]); ok && (op == "==" || op == "!=") {
		c, _ := comparison(op)
		append(b, c, t)
		return "Int"
	}
	for side, k in sides do if !numeric(types[k]) do common.die("%s is %s; this operator takes Int and Float", unparse(side), types[k])
	ot, _ := operand_types(types[0], types[1])
	if c, ok := comparison(op); ok {
		if types[0] != types[1] do common.die("comparison of %s with %s", types[0], types[1])
		append(b, c, ot)
		return "Int"
	}
	a, ok := arithmetic(op)
	if !ok do common.die("unsupported operator %s", op)
	append(b, a, ot)
	return types[0] == "Int" && types[1] == "Int" ? "Int" : "Float"
}

// Code for a call, a Vector component (CALL.x, .y, .z) or an operator
// expression over them and numeric literals; returns the result type.
expr :: proc(b: ^[dynamic]u8, node: ^Node) -> string {
	#partial switch node.kind {
	case .Bin:
		return binary(b, node.name, node.args[0], node.args[1])
	case .Compare:
		if len(node.ops) != 1 do common.die("chained comparison %s", unparse(node))
		return binary(b, node.ops[0], node.args[0], node.args[1])
	case .Attr:
	case:
		return emit_call(b, node)
	}
	k := -1
	for f, i in VECTOR_FIELDS do if f == node.name do k = i
	if k < 0 do common.die("unknown field .%s; a Vector has .x, .y, .z", node.name)
	rt := emit_call(b, node.args[0])
	if rt != "Vector" do common.die("%s is %s, not a Vector", unparse(node.args[0]), rt)
	// Copy the component to the top, store it over the vector's first cell,
	// then drop the rest.
	append(b, 0x03, 1)
	be(b, i64(-12 + 4 * k), 4)
	be(b, 4, 2)
	append(b, 0x01, 1)
	be(b, i64(-16), 4)
	be(b, 4, 2)
	append(b, 0x1B, 0)
	be(b, i64(-12), 4)
	return "Float"
}

// Code for one call whose result is dropped.
statement :: proc(b: ^[dynamic]u8, node: ^Node) {
	rt := emit_call(b, node)
	if cells := slots(rt); cells != 0 {
		append(b, 0x1B, 0) // drop the unused result
		be(b, i64(-4 * cells), 4)
	}
}

assemble :: proc(src: string) -> []u8 {
	body := parse(src)
	ret := len(body) > 0 && body[len(body) - 1].ret
	code := make([dynamic]u8)
	for st in body[:len(body) - (ret ? 1 : 0)] {
		if st.ret do common.die("only call statements and a final return are supported")
		statement(&code, st.value)
	}
	out := make([dynamic]u8)
	append(&out, HEADER)
	append(&out, PROGRAM)
	if !ret {
		append(&code, 0x20, 0)
		be(&out, i64(CODE_START + len(code)), 4)
		append(&out, ..code[:])
		return out[:]
	}
	c := make([dynamic]u8)
	rt := expr(&c, body[len(body) - 1].value)
	if rt != "Int" do common.die("return of %s; only Int is supported", rt)
	// As the compiler emits an int main (e.g. j04_c_gold_14b.ncs): reserve the
	// result cell, call the body, which copies its value down into the cell.
	full := make([dynamic]u8)
	append(&full, 0x02, 3, 0x1E, 0)
	be(&full, 8, 4)
	append(&full, 0x20, 0)
	append(&full, ..code[:])
	append(&full, ..c[:])
	append(&full, 0x01, 0)
	be(&full, i64(-8), 4)
	be(&full, 4, 2)
	append(&full, 0x1B, 0)
	be(&full, i64(-4), 4)
	append(&full, 0x20, 0)
	be(&out, i64(CODE_START + len(full)), 4)
	append(&out, ..full[:])
	return out[:]
}

main :: proc() {
	a := os.args
	if len(a) == 3 && a[1] == "dis" {
		data, err := os.read_entire_file(a[2], context.allocator)
		if err != nil do common.die("%s: %v", a[2], err)
		fmt.println(strings.join(disassemble(data), "\n"))
	} else if len(a) == 4 && a[1] == "asm" {
		code := assemble(a[3])
		if err := os.write_entire_file(a[2], code); err != nil do common.die("%s: %v", a[2], err)
	} else do common.die(USAGE)
}
