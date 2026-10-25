// What online peers must have the same of from the start of play (win32
// lockstep.odin), which the menus before it left as each peer's own: the
// guest's random state and counters, the game options the host plays on,
// player 2's hero; the state hash peers compare, of play alone, since the
// menus before it leave the rest of memory unlike; and the creatures' floats
// the joining peer takes the host's drift of (win32 Net_Fix).
// WHY: docs/hle.md §11
package native

import "core:fmt"
import "core:hash/xxhash"
import "core:slice"
import "../win32"
import "../x86"

// The guest's frame counters, read by play and run on in the menu.
SYNC_COUNTERS :: [2]u32{0x0076c918, 0x0076c91c}

// The game options (CClientOptions at [APP+APP_OPTIONS]) that change play:
// difficulty, auto-target and the like. Volumes, subtitles, rumble, the
// mini-map and the chapter shown in the shell stay each peer's own.
APP_OPTIONS :: 0xb8
SYNC_OPTIONS :: [?]u32{0x24, 0x28, 0xb0, 0xb8, 0xd4, 0x190, 0x194}
// The app's input block: the control scheme and bindings.
SYNC_INPUT :: [2]u32{0x604, 0x7d0}
// The control scheme in force, copied from the app's at a change.
INPUT_SCHEME_PP :: 0x0076c588 // [[it]+0x10]+0x48
APP_INPUT_SCHEME :: 0x7c0

sync_init :: proc() {
	win32.lock_begin_hook = sync_begin
	win32.net_state_hash = sync_hash
	win32.net_fix_take = sync_fix_take
	win32.net_fix_apply = sync_fix_apply
}

// The host's game options, for net_host_start.
sync_opts :: proc() -> []u8 {
	app := ld(APP)
	opt := ld(app + APP_OPTIONS)
	b: [dynamic]u8
	for o in SYNC_OPTIONS {
		v := ld(opt + o)
		append(&b, ..slice.bytes_from_ptr(&v, 4))
	}
	append(&b, ..x86.mem[app + SYNC_INPUT[0]:app + SYNC_INPUT[1]])
	return b[:]
}

// On the joining peer: the host's game options b in place of ours.
sync_opts_apply :: proc(b: []u8) {
	if len(b) != len(SYNC_OPTIONS) * 4 + int(SYNC_INPUT[1] - SYNC_INPUT[0]) {
		x86.fatal("net: the host sent %d bytes of game options", len(b))
	}
	app := ld(APP)
	opt := ld(app + APP_OPTIONS)
	for o, i in SYNC_OPTIONS {st(opt + o, (^u32)(&b[i * 4])^)}
	copy(x86.mem[app + SYNC_INPUT[0]:app + SYNC_INPUT[1]], b[len(SYNC_OPTIONS) * 4:])
	st(ld(ld(INPUT_SCHEME_PP) + 0x10) + 0x48, ld(app + APP_INPUT_SCHEME))
}

guest_texture_get: x86.Func
guest_render_states: x86.Func

// Render caches whose slots each peer's menus left unlike: their blocks come
// from the render part of the heap (win32 heap.odin), apart from play's.
// cdecl (name, flag) -> eax, the texture cache's texture of that name, made
// on a miss.
Texture_Get_0059cba0 :: proc() {
	win32.heap_render += 1
	guest_texture_get()
	win32.heap_render -= 1
}

// The render state blocks' table (0x76fafc), which reuses free slots.
Render_States_0059ad80 :: proc() {
	win32.heap_render += 1
	guest_render_states()
	win32.heap_render -= 1
}

// win32 lock_begin_hook.
@(private = "file")
sync_begin :: proc() {
	st(RAND_STATE, 1)
	for a in SYNC_COUNTERS {st(a, 0)}
	rand_render, rand_crowd = 1, {1, 1}
	ai_dice_reset()
	if !win32.net_on {return}
	setting_apply(.Coop, false)
	coop_hero_start(win32.net_hero())
}

// The player and every creature made in play, each once. Calls guest code.
@(private = "file")
sync_creatures :: proc(out: ^[dynamic]u32) {
	app := ld(APP)
	if app == 0 || ld(app + APP_MODULE) == 0 {return}
	saved := x86.cpu
	defer x86.cpu = saved
	x86.cpu.ecx = ld(app + APP_MODULE)
	p := win32.guest_call(GET_PLAYER)
	if p != 0 {append(out, p)}
	n := ld(ld(app + WORLD) + WORLD_DYNAMIC_N)
	for i in u32(0) ..< min(n + SCAN_SLACK, DYNAMIC_MAX) {
		o := win32.object_by_id(DYNAMIC_CREATURE + i)
		if o != 0 && o != p && ld(o + CREATURE_ID) == DYNAMIC_CREATURE + i {append(out, o)}
	}
}

// win32 net_state_hash: the random state, the frame and the creatures' ids.
@(private = "file")
sync_hash :: proc() -> u64 {
	h: xxhash.XXH3_state
	xxhash.XXH3_64_reset(&h)
	head := [2]u64{u64(ld(RAND_STATE)), u64(win32.vframe)}
	xxhash.XXH3_64_update(&h, slice.to_bytes(head[:]))
	cres := make([dynamic]u32, context.temp_allocator)
	sync_creatures(&cres)
	for o in cres {xxhash.XXH3_64_update(&h, x86.mem[o + CREATURE_ID:][:4])}
	return xxhash.XXH3_64_digest(&h)
}

// The floats of a creature the host corrects: position, facing, health.
SYNC_FIX :: [7]u32{CREATURE_POS, CREATURE_POS + 4, CREATURE_POS + 8, CREATURE_FACING, CREATURE_FACING + 4, CREATURE_FACING + 8, CREATURE_HEALTH}
// A drift past this between the peers is logged: more than a float's last
// bits, so play went another way on one of them.
SYNC_DRIFT_LOG :: 0.25

// win32 net_fix_take.
@(private = "file")
sync_fix_take :: proc(out: ^[dynamic]win32.Net_Fix_Entry) {
	cres := make([dynamic]u32, context.temp_allocator)
	sync_creatures(&cres)
	for o in cres {
		e := win32.Net_Fix_Entry{id = ld(o + CREATURE_ID)}
		for f, k in SYNC_FIX {e.v[k] = lf(o + f)}
		append(out, e)
	}
}

// win32 net_fix_apply: each creature in both own and host, and still in
// play, moved on by host's less own.
@(private = "file")
sync_fix_apply :: proc(own, host: []win32.Net_Fix_Entry, frame: i64) {
	cres := make([dynamic]u32, context.temp_allocator)
	sync_creatures(&cres)
	drift: f32
	worst: u32
	for &h in host {
		o := find(own, h.id)
		if o == nil {continue}
		for c in cres {
			if ld(c + CREATURE_ID) != h.id {continue}
			for f, k in SYNC_FIX {
				d := h.v[k] - o.v[k]
				if abs(d) > drift {drift, worst = abs(d), h.id}
				sf(c + f, lf(c + f) + d)
			}
			break
		}
	}
	if drift > SYNC_DRIFT_LOG {fmt.eprintfln("net: creature %08x drifted %.3f from the host's at frame %d", worst, drift, frame)}
	find :: proc(e: []win32.Net_Fix_Entry, id: u32) -> ^win32.Net_Fix_Entry {
		for &x in e {if x.id == id {return &x}}
		return nil
	}
}
