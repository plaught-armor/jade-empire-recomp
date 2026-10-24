// COM objects for HLE interfaces. A guest object is a 12-byte block
// {vtable, refcount, host id}; each vtable slot is an HLE import named
// "dll!Interface::Method", so a call to a method without an implementation
// fails naming it.
package win32

import "core:fmt"
import "../x86"

Com_Method :: struct {
	name: string,
	fn:   x86.Func, // nil: not implemented yet
}

com_vtables: map[string]u32

// Guest vtable for iface, built once.
com_vtable :: proc(dll, iface: string, methods: []Com_Method) -> u32 {
	if vt, ok := com_vtables[iface]; ok {
		return vt
	}
	vt := heap_alloc(u32(len(methods)) * 4, false)
	for m, i in methods {
		name := fmt.aprintf("%s!%s::%s", dll, iface, m.name)
		if m.fn != nil {
			impl_index[name] = m.fn
		}
		slot, _ := hle_bind(name)
		x86.wr32(vt + u32(i) * 4, slot)
	}
	com_vtables[iface] = vt
	return vt
}

COM_OBJ_SIZE :: 12

com_new :: proc(vt: u32, id: u32) -> u32 {
	p := heap_alloc(COM_OBJ_SIZE, false)
	x86.wr32(p, vt)
	x86.wr32(p + 4, 1)
	x86.wr32(p + 8, id)
	return p
}

com_id :: #force_inline proc "contextless" (this: u32) -> u32 {
	return ld32(this + 8)
}

com_query :: proc() {
	g := arg(1)
	x86.fatal("QueryInterface(%08x, {%08x-%04x-%04x-...})", arg(0), x86.rd32(g), x86.rd16(g + 4), x86.rd16(g + 6))
}

com_addref :: proc() {
	this := arg(0)
	n := x86.rd32(this + 4) + 1
	x86.wr32(this + 4, n)
	ret(1, n)
}

// Frees the guest block at zero; host state keyed by the id stays (objects
// with real host resources supply their own Release).
com_release :: proc() {
	this := arg(0)
	n := x86.rd32(this + 4)
	if n == 0 {
		x86.fatal("Release(%08x) of a dead object", this)
	}
	n -= 1
	x86.wr32(this + 4, n)
	if n == 0 {
		heap_free(this)
	}
	ret(1, n)
}

guid_eq :: proc(p: u32, g: [16]u8) -> bool {
	for b, i in g {
		if x86.rd8(p + u32(i)) != b {
			return false
		}
	}
	return true
}
