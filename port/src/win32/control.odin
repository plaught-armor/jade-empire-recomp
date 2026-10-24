// Live control channel for driven test play (JE_CTL=<dir>). The port makes an
// empty file <dir>/in and reads the command lines appended to it once per
// presented frame (a file, not a FIFO, so it works on Windows too);
// each command answers one line in <dir>/out. Lines are `<id> <command>
// args...`, answers `<id> ok [data]` or `<id> err <reason>`. Input commands
// queue real SDL events through the JE_INPUT_SCRIPT path, so they behave
// like physical input. A `wait` holds back every later command until its
// frames have been presented.
// WHY: docs/recompiler.md §7
package win32

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"
import "../x86"

CTL_LINE_MAX :: 512
CTL_QUEUE_MAX :: 256
CTL_PEEK_MAX :: 4096
CTL_SCAN_MAX :: 1 << 16 // matches kept by scan

Ctl_Scan_Type :: enum u8 {U8, U16, U32, F32}

ctl_dir: string
ctl_in: ^os.File
ctl_out: ^os.File
ctl_buf: [dynamic]u8   // bytes read, not yet a whole line
ctl_queue: [dynamic]string
ctl_wait_until: u32
ctl_wait_id: string
ctl_scan: [dynamic]u32
ctl_scan_type: Ctl_Scan_Type

ctl_open :: proc(dir: string) {
	if dir == "" {return}
	ctl_dir = dir
	inp := fmt.tprintf("%s/in", dir)
	os.remove(inp) // an old one, or the FIFO earlier ports made
	err: os.Error
	if ctl_in, err = os.open(inp, {.Read, .Write, .Create, .Trunc}); err != nil {x86.fatal("JE_CTL: open %s: %v", inp, err)}
	out := fmt.tprintf("%s/out", dir)
	if ctl_out, err = os.open(out, {.Write, .Create, .Trunc, .Append}); err != nil {x86.fatal("JE_CTL: open %s: %v", out, err)}
	input_pad_wanted = true
	input_pad2_wanted = true
	fmt.eprintf("ctl: listening on %s/in\n", dir)
}

ctl_reply :: proc(id, text: string) {
	line := fmt.tprintf("%s %s\n", id, text)
	if n, err := os.write(ctl_out, transmute([]u8)line); err != nil || n != len(line) {
		x86.fatal("JE_CTL: write reply: %v", err)
	}
}

// Moves whole lines appended to <dir>/in into the queue. A line over CTL_LINE_MAX
// or a full queue is fatal: the client broke the protocol.
ctl_read :: proc() {
	chunk: [1024]u8
	for _ in 0 ..< 64 {
		n, err := os.read(ctl_in, chunk[:])
		if err != nil && err != .EOF {x86.fatal("JE_CTL: read: %v", err)}
		if n <= 0 {break}
		append(&ctl_buf, ..chunk[:n])
	}
	for _ in 0 ..< CTL_QUEUE_MAX {
		nl := -1
		for b, i in ctl_buf {if b == '\n' {nl = i; break}}
		if nl < 0 {break}
		if len(ctl_queue) == CTL_QUEUE_MAX {x86.fatal("JE_CTL: over %d queued commands", CTL_QUEUE_MAX)}
		append(&ctl_queue, strings.clone(strings.trim_space(string(ctl_buf[:nl]))))
		remove_range(&ctl_buf, 0, nl + 1)
	}
	if len(ctl_buf) > CTL_LINE_MAX {x86.fatal("JE_CTL: line over %d bytes", CTL_LINE_MAX)}
}

// Once per presented frame, before input_script_step.
ctl_step :: proc(b: ^Res, frame: u32) {
	if ctl_in == nil {return}
	ctl_read()
	if ctl_wait_id != "" {
		if frame < ctl_wait_until {return}
		ctl_reply(ctl_wait_id, fmt.tprintf("ok %d", frame))
		delete(ctl_wait_id)
		ctl_wait_id = ""
	}
	for _ in 0 ..< CTL_QUEUE_MAX {
		if len(ctl_queue) == 0 || ctl_wait_id != "" {break}
		line := ctl_queue[0]
		ordered_remove(&ctl_queue, 0)
		if line != "" {ctl_exec(b, frame, line)}
		delete(line)
	}
}

// Puts a [Port] setting in force by its key; set by package native.
ctl_set: proc(key: string, v: i32) -> bool

ctl_exec :: proc(b: ^Res, frame: u32, line: string) {
	f := strings.fields(line, context.temp_allocator)
	id := f[0]
	if len(f) < 2 {ctl_reply(id, "err no command"); return}
	a := f[2:]
	switch f[1] {
	case "frame":
		ctl_reply(id, fmt.tprintf("ok %d", frame))
	case "wait":
		n, ok := ctl_uint(a, 0)
		if !ok {ctl_reply(id, "err wait N"); return}
		ctl_wait_id, ctl_wait_until = strings.clone(id), frame + n
	case "shot":
		if len(a) != 1 {ctl_reply(id, "err shot PATH"); return}
		frame_dump(b, a[0])
		ctl_reply(id, fmt.tprintf("ok %d", frame))
	case "key", "down", "up":
		ctl_reply(id, ctl_key(f[1], a, frame))
	case "move", "click", "btn":
		ctl_reply(id, ctl_mouse(f[1], a, frame))
	case "pad", "axis", "pad2", "axis2":
		ctl_reply(id, ctl_pad(f[1], a, frame))
	case "peek":
		ctl_reply(id, ctl_peek(a))
	case "poke":
		ctl_reply(id, ctl_poke(a))
	case "scan", "next", "list":
		ctl_reply(id, ctl_scan_cmd(f[1], a))
	case "trace":
		if len(a) != 1 || (a[0] != "on" && a[0] != "off") {ctl_reply(id, "err trace on|off"); return}
		x86.hle_trace = a[0] == "on"
		ctl_reply(id, fmt.tprintf("ok %d", frame))
	case "dbgbt":
		if len(a) == 0 {ctl_reply(id, "err dbgbt TEXT|off"); return}
		delete(debug_bt)
		debug_bt = a[0] == "off" ? "" : strings.join(a, " ")
		ctl_reply(id, "ok")
	case "probe":
		ctl_reply(id, ctl_probe(a))
	case "watch":
		ctl_reply(id, ctl_watch(a))
	case "objs":
		ctl_reply(id, ctl_objs())
	case "area":
		ctl_reply(id, ctl_area(a))
	case "exec":
		ctl_reply(id, ctl_run_script(a))
	case "usepoint":
		ctl_reply(id, ctl_use_point(a))
	case "anims":
		ctl_reply(id, ctl_anims(a))
	case "polygon":
		ctl_reply(id, ctl_polygon(a))
	case "states":
		ctl_reply(id, ctl_states(a))
	case "set":
		v, ok := ctl_int(a, 1)
		if !ok || ctl_set == nil || !ctl_set(a[0], v) {ctl_reply(id, "err set KEY VALUE"); return}
		ctl_reply(id, fmt.tprintf("ok %d", frame))
	case "quit":
		ctl_reply(id, "ok")
		game_exit(0)
	case:
		ctl_reply(id, fmt.tprintf("err unknown command %q", f[1]))
	}
}

// Game object lookup, from the conversation speaker search at 0x44e310.
CTL_WORLD_PP :: 0x76c924     // [[this]+0xa0] is the world object
CTL_OBJ_BY_ID :: 0x461950    // thiscall world, (^u32 id) -> object or 0
CTL_TAGS_OFF :: 0x14c        // world: sorted array of ^{hash, id}, count at +4
CTL_OBJS_MAX :: 4096
CTL_VT_POSITION :: 0x74      // object vtable slot: -> struct, xyz f32 at +4
CTL_VT_AREA_KIND :: 0xa8     // object vtable slot: 1 when CTL_AREA_OF finds its area
CTL_AREA_OF :: 0x4d8180      // thiscall object -> its area object, or 0
CTL_VT_IN_AREA :: 0x2c       // object vtable slot: non-zero when CTL_OBJ_AREA_ID holds its area
CTL_OBJ_AREA_ID :: 0x8       // object: id of its area
CTL_OBJ_TAG :: 0x20          // object: ^tag C string
CTL_PLAYER_TAG :: "PLAYER"   // the player's id differs per load (0x29520000, 0x29320000 seen)

// objs: log every tagged object (id, object, vtable, position, tag) to stderr.
// Calls guest code; the CPU state is restored afterwards.
ctl_objs :: proc() -> string {
	if x86.rd32(CTL_WORLD_PP) == 0 {return "err no world"}
	world := x86.rd32(x86.rd32(CTL_WORLD_PP) + 0xa0)
	if world == 0 {return "err no world"}
	tab, n := x86.rd32(world + CTL_TAGS_OFF), x86.rd32(world + CTL_TAGS_OFF + 4)
	if n > CTL_OBJS_MAX {return fmt.tprintf("err %d tags", n)}
	saved := x86.cpu
	defer x86.cpu = saved
	slot := x86.cpu.esp - 0x400 // scratch u32 well below the live stack
	for i in 0 ..< n {
		id := x86.rd32(x86.rd32(tab + i * 4) + 4)
		obj := ctl_obj_by_id(world, slot, id)
		if obj == 0 {continue}
		x86.cpu.ecx = obj
		pos := guest_call(x86.rd32(x86.rd32(obj) + CTL_VT_POSITION))
		if pos == 0 {continue}
		f := transmute([3]f32)[3]u32{x86.rd32(pos + 4), x86.rd32(pos + 8), x86.rd32(pos + 12)}
		tag, _ := x86.probe_cstr(x86.rd32(obj + CTL_OBJ_TAG))
		fmt.eprintf("obj: %08x %08x vt=%08x %.2f %.2f %.2f %s\n", id, obj, x86.rd32(obj), f.x, f.y, f.z, tag)
	}
	return fmt.tprintf("ok %d", n)
}

// area [TAG]: "ok PTR", the guest address of the area holding the first object
// tagged TAG (default the player), so its fields can be peeked: its
// pathfinding grid, docs/modding.md §6. Resolved as GetArea's handler
// (0x4817e0) does: when vtable slot CTL_VT_AREA_KIND answers 1 the area comes
// from CTL_AREA_OF; otherwise, when slot CTL_VT_IN_AREA answers non-zero, the
// area's id is at object + CTL_OBJ_AREA_ID.
// Calls guest code; the CPU state is restored afterwards.
ctl_area :: proc(a: []string) -> string {
	if len(a) > 1 {return "err area [TAG]"}
	tag := len(a) == 1 ? a[0] : CTL_PLAYER_TAG
	id, ok := ctl_find_tag(tag)
	if !ok {return fmt.tprintf("err no object tagged %s", tag)}
	world := x86.rd32(x86.rd32(CTL_WORLD_PP) + 0xa0)
	saved := x86.cpu
	defer x86.cpu = saved
	slot := x86.cpu.esp - 0x400
	obj := ctl_obj_by_id(world, slot, id)
	if obj == 0 {return fmt.tprintf("err no object %x", id)}
	area: u32
	x86.cpu.ecx = obj
	if guest_call(x86.rd32(x86.rd32(obj) + CTL_VT_AREA_KIND)) == 1 {
		x86.cpu.ecx = obj
		area = guest_call(CTL_AREA_OF)
	} else {
		x86.cpu.ecx = obj
		if guest_call(x86.rd32(x86.rd32(obj) + CTL_VT_IN_AREA)) != 0 {
			area = ctl_obj_by_id(world, slot, x86.rd32(obj + CTL_OBJ_AREA_ID))
		}
	}
	if area == 0 {return fmt.tprintf("err %s is in no area", tag)}
	return fmt.tprintf("ok %x", area)
}

// The object with id, or 0. slot is a scratch u32 below the live stack;
// the caller saves and restores the CPU state.
ctl_obj_by_id :: proc(world, slot, id: u32) -> u32 {
	x86.wr32(slot, id)
	x86.cpu.esp = slot - 0x10
	x86.cpu.ecx = world
	return guest_call(CTL_OBJ_BY_ID, slot)
}

// Id of the first object tagged tag, or false. Calls guest code; the CPU
// state is restored afterwards.
ctl_find_tag :: proc(tag: string) -> (u32, bool) {
	if x86.rd32(CTL_WORLD_PP) == 0 {return 0, false}
	world := x86.rd32(x86.rd32(CTL_WORLD_PP) + 0xa0)
	if world == 0 {return 0, false}
	tab, n := x86.rd32(world + CTL_TAGS_OFF), x86.rd32(world + CTL_TAGS_OFF + 4)
	if n > CTL_OBJS_MAX {return 0, false}
	saved := x86.cpu
	defer x86.cpu = saved
	slot := x86.cpu.esp - 0x400
	for i in 0 ..< n {
		id := x86.rd32(x86.rd32(tab + i * 4) + 4)
		obj := ctl_obj_by_id(world, slot, id)
		if obj == 0 {continue}
		if t, ok := x86.probe_cstr(x86.rd32(obj + CTL_OBJ_TAG)); ok && t == tag {return id, true}
	}
	return 0, false
}

// Script runner, from the dialog condition check at 0x44e610.
CTL_VM_OFF :: 0x9c             // [[CTL_WORLD_PP]+0x9c] is the script VM
CTL_RUN_SCRIPT :: 0x697840     // thiscall VM, (^CExoString name, object id, 1) -> 0 failed
CTL_EXOSTR_INIT :: 0x6534b0    // thiscall ^CExoString (12 bytes), (^char); 0x653540 is the copy ctor
CTL_EXOSTR_FREE :: 0x5a1a50    // thiscall ^CExoString
CTL_SCRIPT_NAME_MAX :: 16      // resref length
CTL_VM_RESULT_TYPE :: 0x0      // VM: type of main()'s return value (3 int), as read by 0x6948c0
CTL_VM_RESULT :: 0x4           // VM: main()'s return value

// exec SCRIPT [ID]: run script resource SCRIPT (.ncs, override/ or archives)
// with OBJECT_SELF = object id ID (hex; default the player, see objs).
// Replies "ok R TYPE VALUE": R is RunScript's result (0 failed), TYPE and VALUE
// are the VM's return-value cell (TYPE 3 = int; meaningful only when the
// script returns a value). Calls guest code; the CPU state is restored afterwards.
// WHY: docs/modding.md §3
ctl_run_script :: proc(a: []string) -> string {
	if len(a) < 1 || len(a) > 2 || len(a[0]) > CTL_SCRIPT_NAME_MAX {return "err exec SCRIPT [ID]"}
	self: u32
	if len(a) == 2 {
		v, ok := ctl_uint(a, 1, 16)
		if !ok {return fmt.tprintf("err object id %q", a[1])}
		self = v
	} else {
		v, ok := ctl_find_tag(CTL_PLAYER_TAG)
		if !ok {return "err no object tagged " + CTL_PLAYER_TAG}
		self = v
	}
	r, ty, val, err := run_script(a[0], self)
	if err != "" {return err}
	return fmt.tprintf("ok %d %d %d", r, ty, val)
}

// Runs script resource name with OBJECT_SELF = object id self: r is
// RunScript's result (0 failed), ty and val the VM's return-value cell; err
// is a ctl reply when there is no VM. Calls guest code; the CPU state is
// restored afterwards.
run_script :: proc(name: string, self: u32) -> (r, ty: u32, val: i32, err: string) {
	if x86.rd32(CTL_WORLD_PP) == 0 {return 0, 0, 0, "err no world"}
	vm := x86.rd32(x86.rd32(CTL_WORLD_PP) + CTL_VM_OFF)
	if vm == 0 {return 0, 0, 0, "err no script VM"}
	saved := x86.cpu
	defer x86.cpu = saved
	at := x86.cpu.esp - 0x400 // scratch, well below the live stack
	str := at - 0x20          // CExoString
	for i in 0 ..< len(name) {x86.mem[at + u32(i)] = name[i]}
	x86.mem[at + u32(len(name))] = 0
	x86.cpu.esp = str - 0x10
	x86.cpu.ecx = str
	guest_call(CTL_EXOSTR_INIT, at)
	x86.cpu.ecx = vm
	r = guest_call(CTL_RUN_SCRIPT, str, self, 1)
	ty, val = x86.rd32(vm + CTL_VM_RESULT_TYPE), i32(x86.rd32(vm + CTL_VM_RESULT))
	x86.cpu.ecx = str
	guest_call(CTL_EXOSTR_FREE)
	return
}

// The game object with id id, or 0. Calls guest code; the CPU state is
// restored afterwards.
object_by_id :: proc(id: u32) -> u32 {
	if x86.rd32(CTL_WORLD_PP) == 0 {return 0}
	world := x86.rd32(x86.rd32(CTL_WORLD_PP) + 0xa0)
	if world == 0 {return 0}
	saved := x86.cpu
	defer x86.cpu = saved
	return ctl_obj_by_id(world, x86.cpu.esp - 0x400, id)
}

// Use point, from the reach test at 0x4bc330.
CTL_USE_POINT :: 0x4b7050 // thiscall user, (target id, ^[3]f32 point, ^f32 space) -> 1, or 0 when out of area

// usepoint ID|TAG: where the player must stand to use the object, as the
// engine's reach test computes it: the walk-to point of the target's model
// nearest the player (a placeable's .pwk), else the target's position. ID is a
// hex object id, else the first object tagged TAG (tags repeat; a caller
// wanting the nearest resolves the id itself). Replies "ok X Y Z S", S the
// player's personal space in metres. Calls guest code; the CPU state is
// restored afterwards. WHY: docs/modding.md §4
ctl_use_point :: proc(a: []string) -> string {
	if len(a) != 1 {return "err usepoint ID|TAG"}
	target, ok := ctl_object_ref(a[0])
	if !ok {return fmt.tprintf("err no object tagged %s", a[0])}
	player, found := ctl_find_tag(CTL_PLAYER_TAG)
	if !found {return "err no object tagged " + CTL_PLAYER_TAG}
	world := x86.rd32(x86.rd32(CTL_WORLD_PP) + 0xa0)
	saved := x86.cpu
	defer x86.cpu = saved
	slot := x86.cpu.esp - 0x400 // scratch: id u32, then point [3]f32, then space f32
	user := ctl_obj_by_id(world, slot, player)
	if user == 0 {return "err no player object"}
	point, space := slot + 4, slot + 16
	for i in u32(0) ..< 4 {x86.wr32(point + i * 4, 0)}
	x86.cpu.esp = slot - 0x10
	x86.cpu.ecx = user
	if guest_call(CTL_USE_POINT, target, point, space) == 0 {return fmt.tprintf("err %08x not in the player's area", target)}
	f := transmute([4]f32)[4]u32{x86.rd32(point), x86.rd32(point + 4), x86.rd32(point + 8), x86.rd32(space)}
	return fmt.tprintf("ok %.3f %.3f %.3f %.3f", f[0], f[1], f[2], f[3])
}

// Animation layers, from the creature model's "AnimState" save at 0x500180
// (the model's vtable is 0x6f4780; 0x4fefa0 is the same save for other models).
CTL_CRE_MODEL :: 0x520        // creature: ^model, found by scanning a live creature
CTL_MODEL_VT :: 0x6f4780      // the creature model's vtable; anything else is not a model
CTL_MODEL_CHANNELS :: [3]u32{0x40, 0x90, 0x94} // model: ^anim interface per channel (base, head, weapon), or 0
CTL_VT_ANIM_COUNT :: 0x34     // anim vtable slot: thiscall () -> layer count
CTL_VT_ANIM_LAYER :: 0x38     // anim vtable slot: thiscall (i, ^cstr name, ^f32 time, ^u32 unsaved, ^u32 flags, ^f32 speed)
CTL_ANIM_LAYERS_MAX :: 16

// anims ID|TAG: the animations a creature is playing now, as the save game
// writes them: per channel (base, head, weapon) "| N" then one "NAME TIME
// SPEED FLAGS" group per layer. ID is a hex object id (as
// GetPlayerCreatureCombatTarget returns), else the first object tagged TAG.
// Reads a foe's attack as it winds up. Calls guest code; the CPU state is
// restored afterwards. WHY: docs/modding.md §5
ctl_anims :: proc(a: []string) -> string {
	if len(a) != 1 {return "err anims ID|TAG"}
	if x86.rd32(CTL_WORLD_PP) == 0 {return "err no world"}
	id, ok := ctl_object_ref(a[0])
	if !ok {return fmt.tprintf("err no object tagged %s", a[0])}
	world := x86.rd32(x86.rd32(CTL_WORLD_PP) + 0xa0)
	saved := x86.cpu
	defer x86.cpu = saved
	slot := x86.cpu.esp - 0x400 // scratch: id u32, then the five layer outputs
	obj := ctl_obj_by_id(world, slot, id)
	if obj == 0 {return fmt.tprintf("err no object %x", id)}
	model := x86.rd32(obj + CTL_CRE_MODEL)
	if model == 0 || !ctl_addr_ok(model, 0x98) || x86.rd32(model) != CTL_MODEL_VT {return fmt.tprintf("err %x has no creature model", id)}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "ok")
	for off in CTL_MODEL_CHANNELS {
		if !ctl_anim_channel(&b, x86.rd32(model + off), slot) {return strings.to_string(b)}
	}
	return strings.to_string(b)
}

// states ID|TAG: the ids in a creature's state list (CTL_CRE_STATES), hex:
// "ok N id...". 9 is blocking (vt+0xa4 at 0x4c67d0 tests it; the hit loop
// 0x447410 takes the blocked branch while it is set).
// WHY: docs/modding.md §5
CTL_CRE_STATES :: 0x678     // creature: list {count u32, ?, ^array of ^{id u16, ...}} (lookup 0x58b5c0)
CTL_STATES_MAX :: 64

ctl_states :: proc(a: []string) -> string {
	if len(a) != 1 {return "err states ID|TAG"}
	if x86.rd32(CTL_WORLD_PP) == 0 {return "err no world"}
	id, ok := ctl_object_ref(a[0])
	if !ok {return fmt.tprintf("err no object tagged %s", a[0])}
	world := x86.rd32(x86.rd32(CTL_WORLD_PP) + 0xa0)
	saved := x86.cpu
	defer x86.cpu = saved
	obj := ctl_obj_by_id(world, x86.cpu.esp - 0x400, id)
	if obj == 0 {return fmt.tprintf("err no object %x", id)}
	list := obj + CTL_CRE_STATES
	n := x86.rd32(list)
	arr := x86.rd32(list + 8)
	if n > CTL_STATES_MAX || (n > 0 && !ctl_addr_ok(arr, n * 4)) {return fmt.tprintf("err %x state list %d at %x", id, n, arr)}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "ok %d", n)
	for i in 0 ..< n {
		e := x86.rd32(arr + i * 4)
		if !ctl_addr_ok(e, 2) {return fmt.tprintf("err %x state %d at %x", id, i, e)}
		fmt.sbprintf(&b, " %x", x86.rd32(e) & 0xffff)
	}
	return strings.to_string(b)
}

// polygon ID|TAG: a trigger's outline in world metres, "ok N x y z ...".
// A trigger fires when the player enters this polygon; its position (what
// GetPosition returns) need not lie inside it. WHY: docs/modding.md §4
CTL_TRIGGER_VT :: 0x6f3d18   // the trigger's vtable; anything else has no outline
CTL_TRG_POINTS :: 0x19c      // trigger: ^[N][3]f32 outline (found in a live j02t_100_120)
CTL_TRG_COUNT :: 0x1a0       // trigger: N, then min x, max x, min y, max y as f32
CTL_TRG_POINTS_MAX :: 64

ctl_polygon :: proc(a: []string) -> string {
	if len(a) != 1 {return "err polygon ID|TAG"}
	if x86.rd32(CTL_WORLD_PP) == 0 {return "err no world"}
	id, ok := ctl_object_ref(a[0])
	if !ok {return fmt.tprintf("err no object tagged %s", a[0])}
	world := x86.rd32(x86.rd32(CTL_WORLD_PP) + 0xa0)
	saved := x86.cpu
	defer x86.cpu = saved
	obj := ctl_obj_by_id(world, x86.cpu.esp - 0x400, id)
	if obj == 0 {return fmt.tprintf("err no object %x", id)}
	if x86.rd32(obj) != CTL_TRIGGER_VT {return fmt.tprintf("err %x is not a trigger", id)}
	n := x86.rd32(obj + CTL_TRG_COUNT)
	pts := x86.rd32(obj + CTL_TRG_POINTS)
	if n < 3 || n > CTL_TRG_POINTS_MAX || !ctl_addr_ok(pts, n * 12) {return fmt.tprintf("err %x outline %d at %x", id, n, pts)}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "ok %d", n)
	for i in 0 ..< n * 3 {
		fmt.sbprintf(&b, " %.3f", transmute(f32)x86.rd32(pts + i * 4))
	}
	return strings.to_string(b)
}

// Appends " | N" and N layer groups of the anim interface iface (" | 0" when
// 0) to b; false, with an error appended, when the count is implausible.
// slot is scratch below the live stack; the caller restores the CPU state.
ctl_anim_channel :: proc(b: ^strings.Builder, iface, slot: u32) -> bool {
	if iface == 0 {strings.write_string(b, " | 0"); return true}
	vt := x86.rd32(iface)
	x86.cpu.esp = slot - 0x10
	x86.cpu.ecx = iface
	n := guest_call(x86.rd32(vt + CTL_VT_ANIM_COUNT))
	if n > CTL_ANIM_LAYERS_MAX {fmt.sbprintf(b, " err %d layers", n); return false}
	fmt.sbprintf(b, " | %d", n)
	name, time, unsaved, flags, speed := slot + 4, slot + 8, slot + 12, slot + 16, slot + 20
	for i in 0 ..< n {
		for k in u32(1) ..= 5 {x86.wr32(slot + k * 4, 0)}
		x86.cpu.ecx = iface
		guest_call(x86.rd32(vt + CTL_VT_ANIM_LAYER), i, name, time, unsaved, flags, speed)
		s, _ := x86.probe_cstr(x86.rd32(name))
		f := transmute([2]f32)[2]u32{x86.rd32(time), x86.rd32(speed)}
		fmt.sbprintf(b, " %s %.3f %.3f %x", len(s) > 0 ? s : "-", f[0], f[1], x86.rd32(flags))
	}
	return true
}

// watch ADDR LEN: log guest stores into [ADDR, ADDR+LEN) (hex). watch off: none.
ctl_watch :: proc(a: []string) -> string {
	when !x86.WATCH {return "err watch needs a build with -define:JE_WATCH=true"}
	if len(a) == 1 && a[0] == "off" {x86.watch_set(0, 0); return "ok"}
	if len(a) != 2 {return "err watch ADDR LEN|off"}
	lo, lok := strconv.parse_uint(a[0], 16)
	n, nok := strconv.parse_uint(a[1], 16)
	if !lok || !nok || n == 0 || lo > 0xffffffff || n > 0x10000 {return "err watch ADDR LEN|off"}
	x86.watch_set(u32(lo), u32(n))
	return "ok"
}

// probe ADDR[=ARG0]...: log calls to these guest functions (hex), only those
// whose first stack argument is ARG0 (hex) when given. probe off: none.
// probe dump ecx|0..3 OFF N: every probe line also shows N dwords (decimal)
// at entry at OFF (hex) past ecx or that stack argument; N 0 is off.
ctl_probe :: proc(a: []string) -> string {
	if len(a) == 0 {return "err probe ADDR[=ARG0]...|off|dump"}
	if a[0] == "off" {x86.probe_clear(); return "ok"}
	if a[0] == "dump" {return ctl_probe_dump(a[1:])}
	for i in 0 ..< len(a) {
		parts := strings.split_n(a[i], "=", 2, context.temp_allocator)
		addr, ok := ctl_uint(parts, 0, 16)
		if !ok || addr < x86.TEXT_LO || addr >= x86.TEXT_HI {return fmt.tprintf("err probe address %q", a[i])}
		arg0: Maybe(u32)
		if len(parts) == 2 {
			v, vok := ctl_uint(parts, 1, 16)
			if !vok {return fmt.tprintf("err probe argument %q", a[i])}
			arg0 = v
		}
		if !x86.probe_add(addr, arg0) {return fmt.tprintf("err over %d probes", x86.PROBE_MAX)}
	}
	return "ok"
}

ctl_probe_dump :: proc(a: []string) -> string {
	usage :: "err probe dump ecx|0..3 OFF N"
	if len(a) != 3 {return usage}
	arg := x86.PROBE_DUMP_ECX
	if a[0] != "ecx" {
		v, ok := strconv.parse_uint(a[0], 10)
		if !ok || v >= x86.PROBE_ARGS {return usage}
		arg = int(v)
	}
	off, ook := strconv.parse_uint(a[1], 16)
	n, nok := strconv.parse_uint(a[2], 10)
	if !ook || !nok || off > 0x10000 || n > x86.PROBE_DUMP_WORDS {return usage}
	x86.probe_dump_set(arg, u32(off), u32(n))
	return "ok"
}

// An object named on the control channel: exactly CTL_ID_DIGITS hex digits
// (ObjectToString's form) is an object id, anything else is a tag and names
// the first object carrying it. false when no object has that tag.
CTL_ID_DIGITS :: 8
ctl_object_ref :: proc(ref: string) -> (u32, bool) {
	if len(ref) == CTL_ID_DIGITS {
		if v, ok := strconv.parse_uint(ref, 16); ok {return u32(v), true}
	}
	return ctl_find_tag(ref)
}

ctl_uint :: proc(a: []string, i: int, base := 10) -> (u32, bool) {
	if i >= len(a) {return 0, false}
	v, ok := strconv.parse_uint(a[i], base)
	return u32(v), ok && v <= uint(max(u32))
}

ctl_int :: proc(a: []string, i: int) -> (i32, bool) {
	if i >= len(a) {return 0, false}
	v, ok := strconv.parse_int(a[i], 10)
	return i32(v), ok && v >= int(min(i32)) && v <= int(max(i32))
}

ctl_tap :: proc(t: Input_Tap) {
	if len(input_taps) >= INPUT_SCRIPT_MAX {x86.fatal("JE_CTL: over %d pending input events", INPUT_SCRIPT_MAX)}
	append(&input_taps, t)
}

// key NAME [N]: tap, or hold N frames. down NAME / up NAME: hold until up.
ctl_key :: proc(cmd: string, a: []string, frame: u32) -> string {
	if len(a) < 1 {return "err key NAME [N]"}
	// Commands split on spaces, so "_" stands for one inside an SDL key name.
	name, _ := strings.replace_all(a[0], "_", " ", context.temp_allocator)
	key := sdl.GetScancodeFromName(strings.clone_to_cstring(name, context.temp_allocator))
	if key == .UNKNOWN {return fmt.tprintf("err unknown key %q", a[0])}
	held := u32(INPUT_TAP_FRAMES)
	if len(a) > 1 {
		n, ok := ctl_uint(a, 1)
		if !ok || n == 0 {return "err bad hold"}
		held = n
	}
	if cmd != "up" {ctl_tap({frame = frame, kind = .Key, down = true, key = key})}
	if cmd == "key" {ctl_tap({frame = frame + held, kind = .Key, key = key})}
	if cmd == "up" {ctl_tap({frame = frame, kind = .Key, key = key})}
	return "ok"
}

// move X Y; click X Y [L|M|R]; btn L|M|R down|up. Guest client pixels.
ctl_mouse :: proc(cmd: string, a: []string, frame: u32) -> string {
	btn_of :: proc(s: string) -> u8 {
		switch s {
		case "L": return 1
		case "M": return 2
		case "R": return 3
		}
		return 0
	}
	if cmd == "btn" {
		if len(a) != 2 || btn_of(a[0]) == 0 || (a[1] != "down" && a[1] != "up") {return "err btn L|M|R down|up"}
		ctl_tap({frame = frame, kind = .Button, down = a[1] == "down", btn = btn_of(a[0])})
		return "ok"
	}
	x, okx := ctl_uint(a, 0)
	y, oky := ctl_uint(a, 1)
	if !okx || !oky {return "err X Y"}
	ctl_tap({frame = frame, kind = .Move, x = f32(x), y = f32(y)})
	if cmd == "click" {
		btn := u8(1)
		if len(a) > 2 {btn = btn_of(a[2])}
		if btn == 0 {return "err button L|M|R"}
		ctl_tap({frame = frame, kind = .Button, down = true, btn = btn})
		ctl_tap({frame = frame + INPUT_TAP_FRAMES, kind = .Button, btn = btn})
	}
	return "ok"
}

// pad NAME [N]: button or full axis tap/hold. axis NAME V: set an axis to
// V (-32768..32767) until changed. pad2 and axis2 do the same on player 2's
// pad; pad2 off and pad2 on unplug it and plug it back.
ctl_pad :: proc(cmd: string, a: []string, frame: u32) -> string {
	if len(a) < 1 {return "err pad NAME [N] | axis NAME V"}
	cn := strings.clone_to_cstring(a[0], context.temp_allocator)
	p2 := strings.has_suffix(cmd, "2")
	cmd := p2 ? cmd[:len(cmd) - 1] : cmd
	// pad2 off / pad2 on: unplug player 2's virtual pad, plug it back.
	if cmd == "pad" && p2 && len(a) == 1 && (a[0] == "off" || a[0] == "on") {
		if (a[0] == "on") == (input_pad2 != nil) {return "ok"}
		if input_pad2 != nil {
			id := sdl.GetJoystickID(input_pad2)
			sdl.CloseJoystick(input_pad2)
			input_pad2 = nil
			if !sdl.DetachVirtualJoystick(id) {return fmt.tprintf("err detach: %s", sdl.GetError())}
		} else {
			input_pad2 = input_pad_new("JE_INPUT_SCRIPT gamepad 2")
		}
		return "ok"
	}
	if p2 && input_pad2 == nil {return "err pad2 is off"}
	t := Input_Tap{frame = frame, down = true, value = 32767, p2 = p2}
	if bt := sdl.GetGamepadButtonFromString(cn); bt != .INVALID && cmd == "pad" {
		t.kind, t.pad = .Pad_Button, c.int(bt)
	} else if ax := sdl.GetGamepadAxisFromString(cn); ax != .INVALID {
		t.kind, t.pad = .Pad_Axis, c.int(ax)
	} else {
		return fmt.tprintf("err unknown gamepad control %q", a[0])
	}
	if cmd == "axis" {
		if len(a) != 2 {return "err axis NAME V"}
		v, ok := strconv.parse_int(a[1], 10)
		if !ok || v < -32768 || v > 32767 {return "err axis value"}
		t.value = i16(v)
		ctl_tap(t)
		return "ok"
	}
	held := u32(INPUT_TAP_FRAMES)
	if len(a) > 1 {
		n, ok := ctl_uint(a, 1)
		if !ok || n == 0 {return "err bad hold"}
		held = n
	}
	ctl_tap(t)
	t.frame, t.down = frame + held, false
	ctl_tap(t)
	return "ok"
}

ctl_addr_ok :: proc(a, n: u32) -> bool {
	return a >= x86.NULL_GUARD && u64(a) + u64(n) <= x86.MEM_SIZE
}

// peek ADDR N: N bytes as hex. Addresses are hexadecimal.
ctl_peek :: proc(a: []string) -> string {
	addr, oka := ctl_uint(a, 0, 16)
	n, okn := ctl_uint(a, 1)
	if !oka || !okn || n == 0 || n > CTL_PEEK_MAX || !ctl_addr_ok(addr, n) {return "err peek ADDR N"}
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "ok ")
	for i in 0 ..< n {fmt.sbprintf(&sb, "%02x", x86.rd8(addr + i))}
	return strings.to_string(sb)
}

// poke ADDR HEXBYTES
ctl_poke :: proc(a: []string) -> string {
	addr, oka := ctl_uint(a, 0, 16)
	if !oka || len(a) != 2 || len(a[1]) % 2 != 0 || len(a[1]) / 2 > CTL_PEEK_MAX {return "err poke ADDR HEX"}
	n := u32(len(a[1]) / 2)
	if !ctl_addr_ok(addr, n) {return "err poke range"}
	for i in 0 ..< n {
		v, ok := strconv.parse_uint(a[1][i * 2:][:2], 16)
		if !ok {return "err poke HEX"}
		x86.wr8(addr + i, u8(v))
	}
	return "ok"
}

// Guest ranges that hold game state: .data, the HLE heap, VirtualAlloc.
ctl_ranges :: proc() -> [3][2]u32 {
	return {{0x6e1000, 0x895000}, {HEAP_LO, heap_top}, {VA_LO, va_top}}
}

ctl_value_at :: proc(t: Ctl_Scan_Type, p: u32) -> f64 {
	switch t {
	case .U8: return f64(x86.rd8(p))
	case .U16: return f64(x86.rd16(p))
	case .U32: return f64(i32(x86.rd32(p)))
	case .F32: return f64(transmute(f32)x86.rd32(p))
	}
	return 0
}

// scan TYPE V: new match set of aligned values equal to V (f32 within 0.01).
// next V: keep the matches now equal to V. list: up to 64 matches.
ctl_scan_cmd :: proc(cmd: string, a: []string) -> string {
	switch cmd {
	case "list":
		sb := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&sb, "ok %d", len(ctl_scan))
		for p, i in ctl_scan {
			if i == 64 {break}
			fmt.sbprintf(&sb, " %08x=%v", p, ctl_value_at(ctl_scan_type, p))
		}
		return strings.to_string(sb)
	case "scan":
		if len(a) != 2 {return "err scan u8|u16|u32|f32 V"}
		switch a[0] {
		case "u8": ctl_scan_type = .U8
		case "u16": ctl_scan_type = .U16
		case "u32": ctl_scan_type = .U32
		case "f32": ctl_scan_type = .F32
		case: return "err scan type"
		}
		v, ok := strconv.parse_f64(a[1])
		if !ok {return "err scan value"}
		clear(&ctl_scan)
		step := ctl_scan_type == .U8 ? u32(1) : (ctl_scan_type == .U16 ? 2 : 4)
		for r in ctl_ranges() {
			for p := r[0]; p + 4 <= r[1]; p += step {
				if ctl_match(ctl_value_at(ctl_scan_type, p), v) {
					if len(ctl_scan) == CTL_SCAN_MAX {return fmt.tprintf("err over %d matches", CTL_SCAN_MAX)}
					append(&ctl_scan, p)
				}
			}
		}
		return fmt.tprintf("ok %d", len(ctl_scan))
	}
	if len(a) != 1 {return "err next V"}
	v, ok := strconv.parse_f64(a[0])
	if !ok {return "err next value"}
	kept := 0
	for p in ctl_scan {
		if ctl_match(ctl_value_at(ctl_scan_type, p), v) {
			ctl_scan[kept] = p
			kept += 1
		}
	}
	remove_range(&ctl_scan, kept, len(ctl_scan))
	return fmt.tprintf("ok %d", kept)
}

ctl_match :: proc(x, v: f64) -> bool {
	return abs(x - v) < 0.01
}
