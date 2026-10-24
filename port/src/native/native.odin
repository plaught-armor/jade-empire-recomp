// Hand-written replacements for hot guest functions. Each matches its
// recompiled body's architectural effects bit for bit and replaces it in the
// dispatch table; the generator calls it directly from every package. The recompiled body stays registered here as the fallback and as
// the reference for JE_NATIVE=check. WHY: docs/recompiler.md §8
package native

import "base:intrinsics"
import "core:fmt"
import "core:os"
import x86s "core:simd/x86"
import "../x86"

Mode :: enum u8 {
	On,    // native bodies run
	Off,   // JE_NATIVE=0: the recompiled bodies run
	Check, // JE_NATIVE=check: both run, results compared, the guest's kept
}

mode: Mode

Entry :: struct {
	addr:  u32,
	fn:    x86.Func,
	guest: ^x86.Func, // receives the recompiled body at registration
}

FUNCS := [?]Entry{
	{0x0040eba0, Quat_ToMatrix3_0040eba0, &guest_quat_matrix},
	{0x004123d0, Obj_Pos_004123d0, &guest_obj_pos},
	{0x00420f60, Cam_Update_00420f60, &guest_cam_update},
	{0x0043b0a0, Ai_Pattern_Idle_0043b0a0, &guest_ai_pattern_idle},
	{0x0043c680, Ai_Probs_0043c680, &guest_ai_probs},
	{0x0043df70, Ai_Update_0043df70, &guest_ai_update},
	{0x0043fec0, Anim_Start_0043fec0, &guest_anim_start},
	{0x0044a8d0, Combat_Tick_0044a8d0, &guest_combat_tick},
	{0x0044c3c0, Combat_Release_0044c3c0, &guest_combat_release},
	{0x0044cb00, Combat_Press_0044cb00, &guest_combat_press},
	{0x0045c720, Move_Dir_0045c720, &guest_move_dir},
	{0x0045c980, Move_Anim_0045c980, &guest_move_anim},
	{0x0045d6b0, Collide_0045d6b0, &guest_collide},
	{0x00463570, Player_Control_00463570, &guest_player_control},
	{0x00464aa0, Control_Frame_00464aa0, &guest_control_frame},
	{0x0051e090, Gui_Draw_0051e090, &guest_gui_draw},
	{0x00424700, Get_Player_00424700, &guest_get_player},
	{0x005df230, Scene_Tick_005df230, &guest_scene_tick},
	{0x004922e0, Create_Object_004922e0, &guest_create_object},
	{0x004acf30, Area_Lod_004acf30, &guest_area_lod},
	{0x004ad720, Nearest_004ad720, &guest_nearest},
	{0x004ad810, Shape_First_004ad810, &guest_shape_first},
	{0x004ad850, Shape_Next_004ad850, &guest_shape_next},
	{0x004fd870, Trigger_Event_004fd870, &guest_trigger_event},
	{0x004611b0, Object_By_Id_004611b0, &guest_object_by_id},
	{0x004709c0, Target_Upkeep_004709c0, &guest_target_upkeep},
	{0x004ceba0, Style_Upgrade_004ceba0, &guest_style_upgrade},
	{0x0051cea0, Gui_Mouse_0051cea0, &guest_gui_mouse},
	{0x0054d570, Video_Apply_0054d570, &guest_video_apply},
	{0x0054d880, Video_Defaults_0054d880, &guest_video_defaults},
	{0x0054db10, Video_Prev_0054db10, &guest_video_prev},
	{0x0054dee0, Video_Next_0054dee0, &guest_video_next},
	{0x0054e2a0, Video_Select_0054e2a0, &guest_video_select},
	{0x0054e890, Video_Ctor_0054e890, &guest_video_ctor},
	{0x00569d50, Menu_Update_00569d50, &guest_menu_update},
	{0x00569f60, Menu_Back_00569f60, &guest_menu_back},
	{0x0056a020, Menu_Focus_0056a020, &guest_menu_focus},
	{0x0056a570, Menu_Activate_0056a570, &guest_menu_activate},
	{0x0056acd0, Menu_List_0056acd0, &guest_menu_list},
	{0x00570050, Cont_Accept_00570050, &guest_cont_accept},
	{0x00570390, Cont_Prev_00570390, &guest_cont_prev},
	{0x005704c0, Cont_Next_005704c0, &guest_cont_next},
	{0x00570650, Cont_Defaults_00570650, &guest_cont_defaults},
	{0x00573a10, Cont_Ctor_00573a10, &guest_cont_ctor},
	{0x0059e170, Node_GetWorldPosOri_0059e170, &guest_node_world},
	{0x005aa990, Object_BoxZGap_005aa990, &guest_box_zgap},
	{0x005b6e60, Quat_Unpack32_005b6e60, &guest_quat_unpack32},
	{0x005b6f50, Quat_Unpack_005b6f50, &guest_quat_unpack},
	{0x005c0320, Math_SqrtNewton_005c0320, &guest_sqrt_newton},
	{0x005c0480, Plane_BoxMaxDist_005c0480, &guest_plane_box_dist},
	{0x005c10d0, Quat_Normalize_005c10d0, &guest_quat_normalize},
	{0x005c1180, Quat_Slerp_005c1180, &guest_quat_slerp},
	{0x005c1e70, Aabb_Outcode_005c1e70, &guest_aabb_outcode},
	{0x005c2320, Segment_AabbClip_005c2320, &guest_segment_aabb_clip},
	{0x005c2690, Segment_SphereTest_005c2690, &guest_segment_sphere},
	{0x005c3eb0, Aabb_Transform3x3_005c3eb0, &guest_aabb_transform},
	{0x005c55c0, Segment_SphereHit_005c55c0, &guest_segment_sphere_hit},
	{0x005cc100, Glow_005cc100, &guest_glow},
	{0x005da240, Gui_Root_005da240, &guest_gui_root},
	{0x005ffa00, AnimTrack_FindKey_005ffa00, &guest_anim_find_key},
	{0x0060d2f0, Anim_Play_0060d2f0, &guest_anim_play},
	{0x0060e8f0, Anim_ApplyLayer_0060e8f0, &guest_anim_apply},
	{0x006130a0, Grass_Set_006130a0, &guest_grass_set},
	{0x00630fb0, Emitter_InterpColorSize_00630fb0, &guest_emitter_interp},
	{0x00631670, Emitter_ParticleBasis_00631670, &guest_emitter_basis},
	{0x006661d0, Axis_Deadzone_006661d0, &guest_axis_dz},
	{0x006678e0, Xb_Input_006678e0, &guest_xb_input},
	{0x0067f0e0, Movie_Draw_0067f0e0, &guest_movie_draw},
	{0x006b32a0, ftol2_006b32a0, &guest_ftol2},
	{0x006ba8f0, ceil_006ba8f0, &guest_ceil},
}

// After rec.register: takes each recompiled body out of the dispatch table and
// puts the native one in its place.
register :: proc() {
	switch os.get_env("JE_NATIVE", context.temp_allocator) {
	case "", "1":
		mode = .On
	case "0":
		mode = .Off
	case "check":
		mode = .Check
	case:
		x86.fatal("JE_NATIVE must be 0, 1 or check")
	}
	for e in FUNCS {
		g := x86.dispatch[e.addr - x86.TEXT_LO]
		if g == nil {
			x86.fatal("native %08x has no recompiled body", e.addr)
		}
		e.guest^ = g
		x86.dispatch[e.addr - x86.TEXT_LO] = e.fn
	}
	fmt.eprintfln("native: %d functions, mode %v", len(FUNCS), mode)
}

// Mismatches seen under JE_NATIVE=check; the first CHECK_REPORTS are printed.
// Progress prints at each power of two calls from 1024.
CHECK_REPORTS :: 20
check_fails: int
check_calls: int
check_fallbacks: int // calls where a native proc ran the guest body instead

// Fallbacks by native: its address, or a span's exit. The summary prints them.
FELL_MAX :: 32
fell_addr: [FELL_MAX]u32
fell_n: [FELL_MAX]int

fell :: proc "contextless" (addr: u32) {
	check_fallbacks += 1
	for i in 0 ..< FELL_MAX {
		if fell_addr[i] == addr || fell_addr[i] == 0 {
			fell_addr[i] = addr
			fell_n[i] += 1
			return
		}
	}
}

// The register state a guest function hands back: the GPRs and the x87 state
// that is not stale (empty registers' contents are unobservable).
cpu_matches :: proc(a, b: ^x86.Cpu) -> bool {
	if a.eax != b.eax || a.ecx != b.ecx || a.edx != b.edx || a.ebx != b.ebx ||
	   a.esp != b.esp || a.ebp != b.ebp || a.esi != b.esi || a.edi != b.edi {
		return false
	}
	fa, fb := &a.fpu, &b.fpu
	if fa.top != fb.top || fa.tag != fb.tag || fa.sw != fb.sw || fa.cw != fb.cw {
		return false
	}
	for i in 0 ..< 8 {
		if fa.tag >> uint(i) & 1 == 0 && transmute(u64)fa.st[i] != transmute(u64)fb.st[i] {
			return false
		}
	}
	return true
}

check_report :: proc(addr: u32, what: string, native, guest: []u32) {
	check_fails += 1
	if check_fails > CHECK_REPORTS {
		return
	}
	fmt.eprintfln("native check %08x: %s differs (call %d)\n  native %08x\n  guest  %08x",
		addr, what, check_calls, native, guest)
}

// Output dwords a native proc writes: n of them at addr.
Region :: struct {
	addr, n: u32,
}

CHECK_OUT_MAX :: 24

// JE_NATIVE=check: the native proc, then the guest body from the same
// registers and outputs; the guest's result stands.
check :: proc(addr: u32, native_fn, guest: x86.Func, outs: []Region) {
	c := &x86.cpu
	check_calls += 1
	in_out, nat_out, g_out: [CHECK_OUT_MAX]u32
	k := gather(outs, in_out[:])
	in_cpu := c^
	mode = .On
	native_fn()
	mode = .Check
	nat_cpu := c^
	gather(outs, nat_out[:])
	c^ = in_cpu
	scatter(outs, in_out[:])
	guest()
	gather(outs, g_out[:])
	if nat_out != g_out {
		check_report(addr, "outputs", nat_out[:k], g_out[:k])
	}
	if !cpu_matches(&nat_cpu, c) {
		n := [?]u32{nat_cpu.eax, nat_cpu.ecx, nat_cpu.edx, nat_cpu.esp, u32(nat_cpu.fpu.sw), u32(nat_cpu.fpu.tag), nat_cpu.fpu.top}
		g := [?]u32{c.eax, c.ecx, c.edx, c.esp, u32(c.fpu.sw), u32(c.fpu.tag), c.fpu.top}
		check_report(addr, "eax ecx edx esp sw tag top", n[:], g[:])
	}
	if check_calls & (check_calls - 1) == 0 && check_calls >= 1024 {
		fmt.eprintfln("native check: %d calls, %d fell back, %d mismatches", check_calls, check_fallbacks, check_fails)
		for i in 0 ..< FELL_MAX {
			if fell_n[i] != 0 {fmt.eprintfln("  fell back %08x: %d", fell_addr[i], fell_n[i])}
		}
	}
}

// A native span (tools/x86rec.py, SPAN_HEAD) under JE_NATIVE=check: span_check
// runs the native stretch, keeps what it left, puts the registers and outputs
// back and returns false, so the recompiled stretch runs; span_end, at the exit
// block, compares. live picks the GPRs compared (bit k is R32 order: eax ecx
// edx ebx esp ebp esi edi), as the recompiled body drops writes the exit does
// not read. The outputs are dwords; SPAN_OUT_MAX bounds them. A span that
// starts at a loop head is entered again on each pass of the recompiled loop,
// and one that starts at a function entry again by each recursive call: while
// its check is pending for the same exit at the same or a deeper stack
// pointer, the first entry's run stands, the later entries run nothing and
// the exits of deeper frames compare nothing.
SPAN_OUT_MAX :: 1024
SPAN_REGIONS_MAX :: 4

@(private = "file")
Span_Pending :: struct {
	exit:    u32, // 0 when no check is pending
	esp:     u32,
	live:    u8,
	k:       int,
	regions: [SPAN_REGIONS_MAX]Region,
	n:       int,
	cpu:     x86.Cpu,
	out:     [SPAN_OUT_MAX]u32,
}

@(private = "file")
span_pending: Span_Pending

@(private = "file")
span_in: [SPAN_OUT_MAX]u32

span_check :: proc(exit: u32, native_fn: proc() -> bool, outs: []Region, live: u8) -> bool {
	c := &x86.cpu
	p := &span_pending
	if p.exit == exit && c.esp <= p.esp {
		return false
	}
	assert(len(outs) <= SPAN_REGIONS_MAX)
	total := u32(0)
	for r in outs {total += r.n}
	assert(total <= SPAN_OUT_MAX)
	check_calls += 1
	k := gather(outs, span_in[:])
	in_cpu := c^
	mode = .On
	ok := native_fn()
	mode = .Check
	if ok {
		p.exit, p.esp, p.live, p.k, p.n = exit, in_cpu.esp, live, k, len(outs)
		copy(p.regions[:], outs)
		p.cpu = c^
		gather(outs, p.out[:])
	} else {
		fell(exit)
	}
	c^ = in_cpu
	scatter(outs, span_in[:])
	return false
}

span_end :: proc(exit: u32) {
	c := &x86.cpu
	p := &span_pending
	if p.exit != exit || c.esp < p.cpu.esp {
		return
	}
	p.exit = 0
	g_out: [SPAN_OUT_MAX]u32
	gather(p.regions[:p.n], g_out[:])
	for i in 0 ..< p.k {
		if p.out[i] != g_out[i] {
			lo := max(i - 2, 0)
			hi := min(i + 6, p.k)
			check_report(exit, fmt.tprintf("span output dword %d", i), p.out[lo:hi], g_out[lo:hi])
			break
		}
	}
	a, b := p.cpu, c^
	ga := [8]u32{a.eax, a.ecx, a.edx, a.ebx, a.esp, a.ebp, a.esi, a.edi}
	gb := [8]u32{b.eax, b.ecx, b.edx, b.ebx, b.esp, b.ebp, b.esi, b.edi}
	for r in 0 ..< 8 {
		if p.live >> uint(r) & 1 == 0 {
			ga[r], gb[r] = 0, 0
		}
	}
	a.eax, a.ecx, a.edx, a.ebx, a.esp, a.ebp, a.esi, a.edi = b.eax, b.ecx, b.edx, b.ebx, b.esp, b.ebp, b.esi, b.edi
	if ga != gb || !cpu_matches(&a, &b) {
		n := [?]u32{ga[3], ga[4], ga[5], ga[6], ga[7], u32(a.fpu.sw), u32(a.fpu.tag), a.fpu.top}
		g := [?]u32{gb[3], gb[4], gb[5], gb[6], gb[7], u32(b.fpu.sw), u32(b.fpu.tag), b.fpu.top}
		check_report(exit, "ebx esp ebp esi edi sw tag top", n[:], g[:])
	}
}

@(private = "file")
gather :: proc(outs: []Region, buf: []u32) -> int {
	k := 0
	for r in outs {
		for i in 0 ..< r.n {buf[k] = ld(r.addr + i * 4); k += 1}
	}
	return k
}

@(private = "file")
scatter :: proc(outs: []Region, buf: []u32) {
	k := 0
	for r in outs {
		for i in 0 ..< r.n {st(r.addr + i * 4, buf[k]); k += 1}
	}
}

// The f32 rule (docs/recompiler.md §8): x87 code whose every operand is a
// dword load or an earlier result under single precision control gives the
// same bits as f32 SSE operations while every value stays a normal f32. A
// native proc checks f32_state, brackets its f32 work (an out-of-line proc, so
// no operation moves across the MXCSR accesses) with f32_begin and f32_end,
// checks its outputs are finite, and runs the guest body when any check fails.

// MXCSR rounding control, flush-to-zero and denormals-are-zero.
MXCSR_MODES :: 0xe040
// Exception flags for an operand or result outside the normal f32 range.
MXCSR_RANGE :: x86s._MM_EXCEPT_INVALID | x86s._MM_EXCEPT_DENORM | x86s._MM_EXCEPT_OVERFLOW | x86s._MM_EXCEPT_UNDERFLOW
F32_EXP :: 0x7f800000

// The MXCSR instructions, declared here so they inline: under
// -use-separate-modules core:simd/x86's _mm_getcsr stays an out-of-line call.
@(private = "file", default_calling_convention = "none")
foreign _ {
	@(link_name = "llvm.x86.sse.stmxcsr")
	stmxcsr :: proc(p: rawptr) ---
	@(link_name = "llvm.x86.sse.ldmxcsr")
	ldmxcsr :: proc(p: rawptr) ---
}

@(private)
csr_get :: #force_inline proc "contextless" () -> (csr: u32) {
	stmxcsr(&csr)
	return
}

@(private = "file")
csr_set :: #force_inline proc "contextless" (csr: u32) {
	csr := csr
	ldmxcsr(&csr)
}

// Single precision control, an empty x87 stack and default MXCSR modes.
@(private)
f32_state :: #force_inline proc "contextless" (csr: u32) -> bool {
	c := &x86.cpu
	return c.fpu.cw & x86.PC_MASK == 0 && c.fpu.tag == 0xff && csr & MXCSR_MODES == 0
}

@(private)
f32_begin :: proc "contextless" (csr: u32) {csr_set(csr &~ x86s._MM_EXCEPT_MASK)}

// Restores the MXCSR; false when the work left the normal f32 range.
@(private)
f32_end :: proc "contextless" (csr: u32) -> bool {
	flags := csr_get() & MXCSR_RANGE
	csr_set(csr)
	return flags == 0
}

// n dwords at a hold finite floats.
@(private)
finite :: #force_inline proc "contextless" (a: u32, n: u32) -> bool {
	for i in 0 ..< n {
		if ld(a + i * 4) & F32_EXP == F32_EXP {return false}
	}
	return true
}

// The n bytes at a and the m bytes at b share none. An f32 path whose writes
// are apart from its inputs leaves those inputs for the exact path's rerun.
@(private)
apart :: #force_inline proc "contextless" (a, n, b, m: u32) -> bool {
	return u64(a) + u64(n) <= u64(b) || u64(b) + u64(m) <= u64(a)
}

// Guest memory. Defined here so it inlines: under -use-separate-modules x86's
// #force_inline helpers stay out-of-line calls from another module.
@(private)
ld :: #force_inline proc "contextless" (a: u32) -> u32 {
	return intrinsics.unaligned_load((^u32)(rawptr(x86.MEM_BASE + uintptr(a))))
}

@(private)
st :: #force_inline proc "contextless" (a: u32, v: u32) {
	intrinsics.unaligned_store((^u32)(rawptr(x86.MEM_BASE + uintptr(a))), v)
}

// movzx word.
@(private)
ld16 :: #force_inline proc "contextless" (a: u32) -> u32 {
	return u32((^u16)(rawptr(x86.MEM_BASE + uintptr(a)))^)
}

// movzx byte.
@(private)
ld8 :: #force_inline proc "contextless" (a: u32) -> u32 {
	return u32((^u8)(rawptr(x86.MEM_BASE + uintptr(a)))^)
}

// mov byte.
@(private)
st8 :: #force_inline proc "contextless" (a: u32, v: u8) {
	(^u8)(rawptr(x86.MEM_BASE + uintptr(a)))^ = v
}

// fld dword.
@(private)
lf :: #force_inline proc "contextless" (a: u32) -> f32 {return transmute(f32)ld(a)}

// A call from a native proc into guest code: the dispatch entry, as the
// recompiled body's call_ext makes it, or x86.call when probing or for an
// address outside the recompiled text.
@(private)
call_guest :: proc(addr: u32) {
	if addr >= x86.TEXT_LO && addr < x86.TEXT_HI && x86.probe_n == 0 {
		#no_bounds_check f := x86.dispatch[addr - x86.TEXT_LO]
		if f != nil {
			f()
			return
		}
	}
	x86.call(addr)
}

// fld qword.
@(private)
lf64 :: #force_inline proc "contextless" (a: u32) -> f64 {
	return transmute(f64)(u64(ld(a)) | u64(ld(a + 4)) << 32)
}

// fstp dword.
@(private)
sf :: #force_inline proc "contextless" (a: u32, v: f32) {st(a, transmute(u32)v)}
