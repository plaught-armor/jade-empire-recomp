// Player 2's hero online: a creature of the port's own, spawned next to the
// player, looking like the hero player 2 picked (players.2da) and as strong
// as the player. Its template and its scripts are generated resources
// (win32/res_gen.odin): the template is written here, the scripts are
// assembled by coop/gen.sh. The spawn script creates it and brings it to life
// (it is created dead); the stats the template cannot carry, the player's
// maxima, go into the creature's own base overrides; the setup script then
// gives it the hero's styles and the player's and fills its pools. It is
// spawned again whenever its id no longer finds it, as after an area change,
// unless the area has one already: a saved game keeps it like any creature
// made in play, so a game saved with player 2 in comes back with player 2's
// hero, and that is what makes it a co-op game (coop_hero_find).
// WHY: docs/recompiler.md §10
package native

import "core:encoding/endian"
import "core:math/bits"
import "core:fmt"
import "../win32"
import "../x86"

guest_create_object: x86.Func

HERO_TEMPLATE :: "jec_p2.cre"
HERO_SPAWN :: "jec_p2_spawn"
HERO_SETUP :: "jec_p2_setup"
HERO_REVIVE :: "jec_p2_revive"
HERO_LOOK :: "jec_p2_look"
HERO_DROP :: "jec_p2_drop"
HERO_SPAWN_NCS :: #load("coop/spawn.ncs")
HERO_SETUP_NCS :: #load("coop/setup.ncs")
HERO_REVIVE_NCS :: #load("coop/revive.ncs")
HERO_LOOK_NCS :: #load("coop/look.ncs")
HERO_DROP_NCS :: #load("coop/drop.ncs")

// The heroes of players.2da: appearance row and starting styles, by row.
Hero :: struct {
	name:       string,
	appearance: i32,
	styles:     [2]u32,
}
HEROES := [?]Hero {
	{"Blossom", 0, {52, 14}},
	{"Ming", 5, {21, 14}},
	{"Shen", 7, {25, 14}},
	{"Jen Zi", 2, {21, 14}},
	{"Ling", 3, {23, 14}},
	{"Prodigy", 6, {52, 14}},
	{"Tan", 8, {23, 14}},
}

hero: int // the HEROES row player 2 plays
hero_id: u32 // player 2's creature, or 0
hero_ready: bool // its stats and styles are set
@(private = "file")
hero_model: u32 // the model whose anim events are registered
@(private = "file")
hero_from: u64 // player_sig of the player when they were
// A hero to switch to, a HEROES row, or -1: a Player 2's Hero pick in couch
// co-op (settings.odin); online, win32 net_hero_switch.
coop_hero_next: int = -1
@(private = "file")
hero_drop: u32 // the style of the hero switched from, 0 once handled

// While the spawn script runs, nws_CreateObject's object is player 2's.
@(private = "file")
spawning: bool

// Base overrides a creature keeps of its own, in place of its template's:
// a flag and a value each (CCreature_GetHealthBase 0x4c63b0 and its siblings).
CREATURE_HEALTH_BASE :: 0x7b0
CREATURE_CHI_BASE :: 0x7b8
CREATURE_FOCUS_MAX :: 0x488 // f32 in the focus meter at 0x484 (nws_GetMaxFocus 0x4859c0)
VT_AS_CREATURE :: 0x18
CREATURE_VT_MAX_HEALTH :: 0xe0
CREATURE_VT_MAX_CHI :: 0xe4

// In the setup script, the style id of slot i is the int constant
// SETUP_STYLE + i, as CONST's opcode, type and big-endian value.
SETUP_STYLE :: 0x7e570000
SETUP_SLOTS :: 34

// The hero the Player 2's Hero setting names, a players.2da row, 0 Blossom
// by default.
coop_hero_pick :: proc() -> i32 {
	return clamp(setting_val[.P2_Hero], 0, len(HEROES) - 1)
}

// Registers the template and scripts for player 2's hero h, a HEROES row
// (online, the joining peer's pick); before boot, as co-op can be turned on
// in game.
coop_hero_init :: proc(h: i32) {
	if h >= 0 && int(h) < len(HEROES) {hero = int(h)}
	setup_script = make([]u8, len(HERO_SETUP_NCS))
	copy(setup_script, HERO_SETUP_NCS)
	win32.res_gen_set(HERO_TEMPLATE, hero_template(HEROES[hero].appearance))
	win32.res_gen_set(HERO_SPAWN + ".ncs", HERO_SPAWN_NCS)
	win32.res_gen_set(HERO_SETUP + ".ncs", setup_script)
	win32.res_gen_set(HERO_REVIVE + ".ncs", HERO_REVIVE_NCS)
	look_script = make([]u8, len(HERO_LOOK_NCS))
	copy(look_script, HERO_LOOK_NCS)
	win32.res_gen_set(HERO_LOOK + ".ncs", look_script)
	drop_script = make([]u8, len(HERO_DROP_NCS))
	copy(drop_script, HERO_DROP_NCS)
	win32.res_gen_set(HERO_DROP + ".ncs", drop_script)
}

@(private = "file")
drop_script: []u8 // HERO_DROP_NCS with the style filled in

// Player 2 plays hero h from now on: the template's look for a creature
// spawned later, and hero_setup gives the one in play the look and styles,
// taking away the old hero's own style (hero_drop).
@(private = "file")
hero_switch :: proc(h: int) {
	if h == hero || h < 0 || h >= len(HEROES) {return}
	fmt.eprintfln("coop: player 2's hero %s, was %s", HEROES[h].name, HEROES[hero].name)
	hero_drop = HEROES[hero].styles[0]
	hero = h
	win32.res_gen_set(HERO_TEMPLATE, hero_template(HEROES[hero].appearance))
	hero_ready = false
}

@(private = "file")
look_script: []u8 // HERO_LOOK_NCS with the appearance filled in

@(private = "file")
setup_script: []u8 // HERO_SETUP_NCS with the styles filled in

// A creature template (GFF "CRE V3.2"): appearance app, a 100 health base
// the player's maxima replace, rank 1, no scripts.
@(private = "file")
hero_template :: proc(app: i32) -> []u8 {
	Field :: struct {
		type, data: u32,
		label:      string,
	}
	FIELDS :: [?]Field {
		{14, 1, "Looks"},
		{5, 0, "Appearance"},
		{17, 0, "DecalTint"}, // three f32 in the field data
		{14, 2, "Stats"},
		{4, 100, "HealthBase"},
		{4, 0, "FocusBase"},
		{5, 1, "Rank"},
		{14, 3, "Scripts"},
	}
	// Struct type, offset into the field indices (or the field), field count.
	STRUCTS :: [?][3]u32{{0xffffffff, 0, 3}, {0, 12, 2}, {0, 20, 3}, {0, 0, 0}}
	INDICES :: [?]u32{0, 3, 7, 1, 2, 4, 5, 6}
	TINT :: 1.0 / 255
	fields := FIELDS
	fields[1].data = u32(app)
	out: [dynamic]u8
	u32s :: proc(out: ^[dynamic]u8, vs: ..u32) {
		for v in vs {
			b: [4]u8
			endian.put_u32(b[:], .Little, v)
			append(out, ..b[:])
		}
	}
	at_structs := u32(56)
	at_fields := at_structs + 12 * len(STRUCTS)
	at_labels := at_fields + 12 * len(FIELDS)
	at_data := at_labels + 16 * len(FIELDS)
	at_indices := at_data + 12
	at_lists := at_indices + 4 * len(INDICES)
	append(&out, ..transmute([]u8)string("CRE V3.2"))
	u32s(&out, at_structs, len(STRUCTS), at_fields, len(FIELDS), at_labels, len(FIELDS))
	u32s(&out, at_data, 12, at_indices, 4 * len(INDICES), at_lists, 0)
	for s in STRUCTS {u32s(&out, s[0], s[1], s[2])}
	for f, i in fields {u32s(&out, f.type, u32(i), f.data)}
	for f in fields {
		l: [16]u8
		copy(l[:], f.label)
		append(&out, ..l[:])
	}
	u32s(&out, transmute(u32)f32(TINT), transmute(u32)f32(TINT), transmute(u32)f32(TINT))
	for i in INDICES {u32s(&out, i)}
	return out[:]
}

// nws_CreateObject: the object it pushes while the spawn script runs is
// player 2's.
Create_Object_004922e0 :: proc() {
	guest_create_object()
	if !spawning {return}
	vm := ld(ld(APP) + SCRIPT_VM)
	n := ld(vm + VM_STACK_N)
	if n > 0 {hero_id = ld(ld(vm + VM_STACK) + 4 * (n - 1))}
}

SCRIPT_VM :: 0x9c
VM_STACK_N :: 0x190 // cells on the VM stack
VM_STACK :: 0x1a0 // ^[]u32 cell values

// Player 2's creature for the player p, spawned or set up as needed: 0 while
// there is none yet. Calls guest code.
coop_hero :: proc(p: u32) -> u32 {
	if win32.net_hero_switch >= 0 {
		hero_switch(int(win32.net_hero_switch))
		win32.net_hero_switch = -1
	}
	if coop_hero_next >= 0 {
		hero_switch(coop_hero_next)
		coop_hero_next = -1
	}
	cre := coop_hero_find(p)
	if cre == 0 {
		spawning = true
		win32.run_script(HERO_SPAWN, ld(p + CREATURE_ID))
		spawning = false
		if hero_id == 0 {return 0}
		cre = win32.object_by_id(hero_id)
		if cre == 0 {return 0}
	}
	// Set up again whenever the player levels or learns or upgrades a style.
	if sig := player_sig(p); !hero_ready || sig != hero_from {
		hero_ready, hero_from = true, sig
		hero_setup(p, cre)
	}
	// Spawned after the area's set-up, which gives each creature there its
	// model's anim events and its style's moves: in combat stance with a new
	// model, the same for player 2's hero, else its blows never land.
	if m := vcall(cre, CREATURE_VT_MODEL); m != hero_model && m != 0 && ld(cre + CREATURE_COMBAT) != 0 {
		hero_model = m
		model_setup(cre, m)
	}
	// Back from coop_hero_away: at the player's side again.
	if vcall(cre, OBJ_VT_INACTIVE) == 0 {
		vcall(cre, OBJ_VT_ACTIVATE)
		place_beside(cre, p)
		fmt.eprintfln("coop: player 2 back")
	}
	// The player taken somewhere by a script (an arena, a jump): along too.
	dx, dy := lf(cre + CREATURE_POS) - lf(p + CREATURE_POS), lf(cre + CREATURE_POS + 4) - lf(p + CREATURE_POS + 4)
	if dx * dx + dy * dy > LEASH * LEASH {
		place_beside(cre, p)
		fmt.eprintfln("coop: player 2 brought along")
	}
	return cre
}

// Player 2's creature as the world has it: the one hero_id names, else one an
// area kept, a saved game's or one left behind there, which hero_id then
// names. Its hero is the HEROES row of its look: both peers load the same
// game, so the saved hero is theirs whatever was picked. One more found is
// put out of the world. The scan runs again only when the player or the
// count of creatures made in play changes, as a load or an area change does.
// 0 for none. Calls guest code.
coop_hero_find :: proc(p: u32) -> u32 {
	if hero_id != 0 {
		if o := win32.object_by_id(hero_id); o != 0 && is_hero(o) {return o}
		hero_id, hero_ready = 0, false
	}
	n := ld(ld(ld(APP) + WORLD) + WORLD_DYNAMIC_N)
	if scanned == {p, n} {return 0}
	scanned = {p, n}
	found := u32(0)
	for i in u32(0) ..< min(n + SCAN_SLACK, DYNAMIC_MAX) {
		o := win32.object_by_id(DYNAMIC_CREATURE + i)
		if o == 0 || ld(o + CREATURE_ID) != DYNAMIC_CREATURE + i || !is_hero(o) {continue}
		if found != 0 {
			if vcall(o, OBJ_VT_ACTIVE) != 0 {vcall(o, OBJ_VT_DEACTIVATE, 0)}
			fmt.eprintfln("coop: player 2 %08x more, out", ld(o + CREATURE_ID))
			continue
		}
		found = o
		// None of its own (-1): saved before it had, so the pick's.
		app := i32(ld(vcall(o, VT_AS_CREATURE) + CREATURE_APPEARANCE))
		for h, r in HEROES {
			if h.appearance == app {hero = r}
		}
		hero_id = ld(o + CREATURE_ID)
		fmt.eprintfln("coop: player 2 %s %08x found", HEROES[hero].name, hero_id)
	}
	return found
}

// Ids of the creatures made in play run up from DYNAMIC_CREATURE (type 2 in
// the top 5 bits, 0x8000 for made in play, index in the low bits); the world
// counts them (0x460630).
DYNAMIC_CREATURE :: 0x10008000
DYNAMIC_MAX :: 0x4000
SCAN_SLACK :: 8 // past the count, for indices freed below it
WORLD :: 0xa0 // the app's world
WORLD_DYNAMIC_N :: 0x3c
CREATURE_RESREF :: 0xc // its template's, upper case (saved by 0x4d8840)
CREATURE_APPEARANCE :: 0x4cc // appearance.2da row of its own, else -1 for its template's (0x408ac0)
LOOK_APPEARANCE :: 0x7e580000 // the look script's appearance, filled in
DROP_STYLE :: 0x7e590000 // the drop script's style, filled in

@(private = "file")
scanned: [2]u32 // the player and count of the last scan

// Whether o was made from player 2's template.
@(private = "file")
is_hero :: proc(o: u32) -> bool {
	r := x86.mem[o + CREATURE_RESREF:][:16]
	return string(r[:len(HERO_RESREF)]) == HERO_RESREF && r[len(HERO_RESREF)] == 0
}

HERO_RESREF :: "JEC_P2"

LEASH :: 30.0 // metres player 2's hero may be from the player

// Creature states of the dead, as GetIsDead 0x4839b0 tests them: 8 while
// the death plays (about 3 s), then 9. Resurrection takes only in 9.
STATE_DYING :: 8
STATE_DEAD :: 9
RESPAWN_SEC :: 3.0 // dead before player 2's hero comes back at the player's side

@(private = "file")
dead_for: f32 // seconds player 2's hero has been dead

// Whether cre, player 2's creature, is dead; dt seconds on, it is brought
// back to life at the player p's side with full pools by the revive script.
// Calls guest code.
coop_hero_dead :: proc(p, cre: u32, dt: f32) -> bool {
	c := vcall(cre, VT_AS_CREATURE)
	dead := has_state(c, STATE_DEAD)
	if !dead && !has_state(c, STATE_DYING) {
		dead_for = 0
		return false
	}
	dead_for += dt
	if !dead || dead_for < RESPAWN_SEC {return true}
	dead_for = 0
	place_beside(cre, p)
	win32.run_script(HERO_REVIVE, ld(cre + CREATURE_ID))
	fmt.eprintfln("coop: player 2 revived")
	return true
}

// Takes player 2's creature out of the world while player 2 is not in, as
// SetObjectActive does; coop_hero brings it back. Calls guest code.
coop_hero_away :: proc() {
	cre := hero_id != 0 ? win32.object_by_id(hero_id) : 0
	if cre == 0 || vcall(cre, OBJ_VT_ACTIVE) == 0 {return}
	vcall(cre, OBJ_VT_DEACTIVATE, 0)
	fmt.eprintfln("coop: player 2 away")
}

// A style entry's level (1 + upgrades bought, GetCombatStyleLevel 0x49d3b0)
// and its upgrades, 12 groups of 5 bits (0x4ceba0 adds to both).
STYLE_UPGRADES :: 0x10 // u64
STYLE_REPLAY :: 0xbc // nonzero: a newly added style, set up afresh by 0x4ced10
CREATURE_REPLAY_UPGRADES :: 0x004ced10 // thiscall creature: sets up the flagged entries (0x4cf3ef on load)
// thiscall creature: registers its model's HitOn, HitOff, Cast and slam anim
// events, those first dropping the old. The area set-up (0x4d0516) does it
// for the creatures there; a blow arms its contacts only on HitOn (0x4bbd90).
CREATURE_ANIM_EVENTS :: 0x004cf410
CREATURE_VT_MODEL :: 0xcc

upgrades :: proc(e: u32) -> u64 {return u64(ld(e + STYLE_UPGRADES + 4)) << 32 | u64(ld(e + STYLE_UPGRADES))}

// The entries hero_setup has the replay apply, with the upgrades they take.
@(private = "file")
replay: [16]struct {
	entry: u32,
	want:  u64,
}
@(private = "file")
replay_n: int

// Applies an entry's new upgrades (thiscall creature (entry, ^new, 2da, 0),
// ret 0x10: those set in new +0x10 and not in the entry's, their count added
// to its level, then the entry takes new's). The replay first sets the entry
// up afresh (0x46b510: level 1, no upgrades, every multiplier 1) and only then
// copies it to new, so new has none; for an entry of hero_setup's, new takes
// the upgrades it is to have, and all of them are applied to the fresh entry.
guest_style_upgrade: x86.Func
Style_Upgrade_004ceba0 :: proc() {
	e, n := ld(x86.cpu.esp + 4), ld(x86.cpu.esp + 8)
	for r in replay[:replay_n] {
		if r.entry != e {continue}
		st(n + STYLE_UPGRADES, u32(r.want))
		st(n + STYLE_UPGRADES + 4, u32(r.want >> 32))
	}
	guest_style_upgrade()
}

// A style's LevelUp 2da: a row per upgrade group, its choices then label
// then choice_1 .. choice_5, each a StyleAdvance.2da row. Its name is the
// styledata row's LevelUp2DA, as 0x4ced10 finds it (0x4ceebc .. 0x4cf103).
STYLES_2DA :: 0x12 // the style's styledata row in column 4
STYLEDATA_2DA :: 0x4d
STYLEADVANCE_2DA :: 0x57 // the effect in column 3 (0x4cacf0)
LEVELUP_2DA :: 0x006f0c10 // "LevelUp2DA"
LV_CHOICES :: 0
LV_CHOICE_1 :: 2
ADVANCE_EFFECT :: 3
TWODA_STRING :: 0x00658370 // thiscall 2da (row, ^column CString, ^out CString)
TWODA_SIZE :: 0x84
TWODA_NEW :: 0x00658b90 // thiscall: the ctor
TWODA_SET_NAME :: 0x00434230 // thiscall 2da (^resref, 0)
TWODA_LOAD :: 0x00659a70 // thiscall
TWODA_VT_DELETE :: 0 // thiscall (1)
CSTRING_SIZE :: 12
CSTRING_EMPTY :: 0x00653480 // thiscall
CSTRING_FROM :: 0x006534b0 // thiscall (^chars)
CSTRING_FREE :: 0x005a1a50 // thiscall
RESREF_FROM :: 0x00656be0 // thiscall resref (^CString)
GROUPS :: 12
TIERS :: 5

// Loads style s's LevelUp 2da, 0 if it has none. lv_free frees it. Calls
// guest code.
@(private = "file")
lv_load :: proc(s: u32) -> u32 {
	saved := x86.cpu
	defer x86.cpu = saved
	x86.cpu.esp -= 0x40
	out, col, name, ref := x86.cpu.esp, x86.cpu.esp + 4, x86.cpu.esp + 4 + CSTRING_SIZE, x86.cpu.esp + 4 + 2 * CSTRING_SIZE
	st(out, 0)
	x86.cpu.ecx = ld(ld(RULES))
	x86.cpu.ecx = win32.guest_call(RULES_2DA, STYLES_2DA)
	if win32.guest_call(TWODA_INT, s, 4, out) == 0 {return 0}
	x86.cpu.ecx = ld(ld(RULES))
	data := win32.guest_call(RULES_2DA, STYLEDATA_2DA)
	x86.cpu.ecx = name
	win32.guest_call(CSTRING_EMPTY)
	x86.cpu.ecx = col
	win32.guest_call(CSTRING_FROM, LEVELUP_2DA)
	x86.cpu.ecx = data
	win32.guest_call(TWODA_STRING, ld(out), col, name)
	x86.cpu.ecx = col
	win32.guest_call(CSTRING_FREE)
	x86.cpu.ecx = ref
	win32.guest_call(RESREF_FROM, name)
	x86.cpu.ecx = name
	win32.guest_call(CSTRING_FREE)
	t := win32.guest_call_c(OPERATOR_NEW, TWODA_SIZE)
	if t == 0 {return 0}
	x86.cpu.ecx = t
	win32.guest_call(TWODA_NEW)
	x86.cpu.ecx = t
	win32.guest_call(TWODA_SET_NAME, ref, 0)
	x86.cpu.ecx = t
	win32.guest_call(TWODA_LOAD)
	return t
}

@(private = "file")
lv_free :: proc(t: u32) {
	if t == 0 {return}
	saved := x86.cpu
	defer x86.cpu = saved
	x86.cpu.ecx = t
	win32.guest_call(ld(ld(t) + TWODA_VT_DELETE), 1)
}

// Cell (row, col) of the 2da t, ok false for none. Calls guest code.
@(private = "file")
twoda_int :: proc(t, row, col: u32) -> (v: u32, ok: bool) {
	saved := x86.cpu
	defer x86.cpu = saved
	x86.cpu.esp -= 4
	out := x86.cpu.esp
	st(out, 0)
	x86.cpu.ecx = t
	ok = win32.guest_call(TWODA_INT, row, col, out) != 0
	return ld(out), ok
}

// A LevelUp 2da's groups: how many tiers each has and what its first tier
// does (its StyleAdvance effect), 0 tiers past the last.
@(private = "file")
Lv_Group :: struct {
	tiers, effect: u32,
}
@(private = "file")
lv_groups :: proc(t: u32) -> (gs: [GROUPS]Lv_Group) {
	if t == 0 {return}
	saved := x86.cpu
	defer x86.cpu = saved
	x86.cpu.ecx = ld(ld(RULES))
	adv := win32.guest_call(RULES_2DA, STYLEADVANCE_2DA)
	for g in u32(0) ..< GROUPS {
		n, ok := twoda_int(t, g, LV_CHOICES)
		if !ok {break}
		row, _ := twoda_int(t, g, LV_CHOICE_1)
		e, _ := twoda_int(adv, row, ADVANCE_EFFECT)
		gs[g] = {min(n, TIERS), e}
	}
	return
}

// The upgrades u of a style with groups from, as a style with groups to:
// each group of to takes the tiers of the first unmatched group of from with
// the same effect, as far as it has tiers; the tiers left over go to the
// groups of to in order, as far as they have room. So the level stays,
// unless to has fewer tiers in all.
@(private = "file")
upgrades_as :: proc(u: u64, from, to: [GROUPS]Lv_Group) -> u64 {
	have: [GROUPS]u32
	for g in 0 ..< GROUPS {
		for t in 0 ..< TIERS {
			if u >> u64(TIERS * g + t) & 1 != 0 {have[g] += 1}
		}
	}
	got: [GROUPS]u32
	used: [GROUPS]bool
	for d in 0 ..< GROUPS {
		if to[d].tiers == 0 {continue}
		for s in 0 ..< GROUPS {
			if used[s] || have[s] == 0 || from[s].effect != to[d].effect {continue}
			used[s] = true
			got[d] = min(have[s], to[d].tiers)
			have[s] -= got[d]
			break
		}
	}
	left: u32
	for h in have {left += h}
	for d in 0 ..< GROUPS {
		n := min(left, to[d].tiers - got[d])
		got[d] += n
		left -= n
	}
	out: u64
	for d in 0 ..< GROUPS {out |= (u64(1) << got[d] - 1) << u64(TIERS * d)}
	return out
}

// What hero_setup takes from the player p, hashed: maxima, styles, their
// levels and upgrades. Calls guest code.
@(private = "file")
player_sig :: proc(p: u32) -> u64 {
	pc := vcall(p, VT_AS_CREATURE)
	h := u64(vcall(pc, CREATURE_VT_MAX_HEALTH))
	h = h * 31 + u64(vcall(pc, CREATURE_VT_MAX_CHI))
	h = h * 31 + u64(ld(pc + CREATURE_FOCUS_MAX))
	es := ld(p + CREATURE_STYLES)
	for i in 0 ..< ld(p + CREATURE_STYLE_N) {
		e := ld(es + 4 * i)
		h = h * 31 + u64(ld(e))
		h = h * 31 + u64(x86.mem[e + STYLE_LEVEL])
		h = h * 31 + upgrades(e)
	}
	return h
}

// Registers the anim events of model m of cre, player 2's creature, and
// switches it to its style again: a switch reaches the anims only in combat
// stance (0x4bd646) and does nothing for the style in use (0x4bd594), so the
// one in use is first marked another of its styles. Calls guest code.
@(private = "file")
model_setup :: proc(cre, m: u32) {
	saved := x86.cpu
	defer x86.cpu = saved
	x86.cpu.ecx = cre
	win32.guest_call(CREATURE_ANIM_EVENTS)
	n := ld(cre + CREATURE_STYLE_N)
	if n < 2 {return}
	i := ld(cre + CREATURE_STYLE)
	if i >= n {i = 0}
	s := ld(ld(ld(cre + CREATURE_STYLES) + 4 * i))
	st(cre + CREATURE_STYLE, (i + 1) % n)
	x86.cpu.ecx = cre
	win32.guest_call(ld(ld(cre) + CREATURE_VT_SWITCH_STYLE), s, 0, 1)
	fmt.eprintfln("coop: player 2 model %x, style %x", m, s)
}

// Gives cre, player 2's creature, the player p's maxima, the hero's styles and
// p's, and full pools.
@(private = "file")
hero_setup :: proc(p, cre: u32) {
	pc := vcall(p, VT_AS_CREATURE)
	health := vcall(pc, CREATURE_VT_MAX_HEALTH)
	chi := vcall(pc, CREATURE_VT_MAX_CHI)
	st(cre + CREATURE_HEALTH_BASE, 1)
	st(cre + CREATURE_HEALTH_BASE + 4, health)
	st(cre + CREATURE_CHI_BASE, 1)
	st(cre + CREATURE_CHI_BASE + 4, chi)
	st(cre + CREATURE_FOCUS_MAX, ld(pc + CREATURE_FOCUS_MAX))
	h := HEROES[hero]
	// Its look as its own, not the template's, which is the hero picked at
	// boot: a saved game keeps the creature's own (0x4cb340), and its hero
	// with it.
	if i32(ld(vcall(cre, VT_AS_CREATURE) + CREATURE_APPEARANCE)) != h.appearance {
		copy(look_script, HERO_LOOK_NCS)
		for k := 0; k + 6 <= len(look_script); k += 1 {
			if look_script[k] != 0x04 || look_script[k + 1] != 0x03 {continue}
			if v, _ := endian.get_u32(look_script[k + 2:], .Big); v == LOOK_APPEARANCE {
				endian.put_u32(look_script[k + 2:], .Big, u32(h.appearance))
			}
		}
		win32.run_script(HERO_LOOK, ld(cre + CREATURE_ID))
	}
	styles: [SETUP_SLOTS]u32
	n := 0
	for s in h.styles {styles[n] = s; n += 1}
	// A style entry holds the style id first; one with the sign bit set is
	// skipped (HasStyle 0x4bd2c0).
	es := ld(p + CREATURE_STYLES)
	for i in 0 ..< ld(p + CREATURE_STYLE_N) {
		s := ld(ld(es + 4 * i))
		if s & 0x8000_0000 != 0 || s == h.styles[0] || s == h.styles[1] {continue}
		if n == SETUP_SLOTS {break}
		styles[n] = s
		n += 1
	}
	for i in n ..< SETUP_SLOTS {styles[i] = h.styles[0]} // a style added twice stays one
	copy(setup_script, HERO_SETUP_NCS)
	for k := 0; k + 6 <= len(setup_script); k += 1 {
		if setup_script[k] != 0x04 || setup_script[k + 1] != 0x03 {continue}
		v, _ := endian.get_u32(setup_script[k + 2:], .Big)
		if v < SETUP_STYLE || v >= SETUP_STYLE + SETUP_SLOTS {continue}
		endian.put_u32(setup_script[k + 2:], .Big, styles[v - SETUP_STYLE])
		k += 5
	}
	win32.run_script(HERO_SETUP, ld(cre + CREATURE_ID))
	// The hero switched from's own style, unless the player or the new hero
	// has it.
	if d := hero_drop; d != 0 {
		hero_drop = 0
		keep := d == h.styles[0] || d == h.styles[1]
		for i in 0 ..< ld(p + CREATURE_STYLE_N) {
			if ld(ld(es + 4 * i)) == d {keep = true}
		}
		if !keep {
			copy(drop_script, HERO_DROP_NCS)
			for k := 0; k + 6 <= len(drop_script); k += 1 {
				if drop_script[k] != 0x04 || drop_script[k + 1] != 0x03 {continue}
				if v, _ := endian.get_u32(drop_script[k + 2:], .Big); v == DROP_STYLE {
					endian.put_u32(drop_script[k + 2:], .Big, d)
				}
			}
			win32.run_script(HERO_DROP, ld(cre + CREATURE_ID))
		}
	}
	// The styles both know take the player's upgrades; the hero's own take
	// those of the player's highest style, group by group of the same effect
	// in the two styles' LevelUp 2das (upgrades_as), which differ by kind of
	// style: a fist style's damage, chi strike and speed against a magic
	// style's chi cost, damage and duration. An upgrade is its
	// styleadvance.2da effects on the entry, so the bits alone do nothing:
	// the game's set-up of a newly added style (0x4ced10, as loading runs it)
	// applies them to the entry afresh (Style_Upgrade_004ceba0). One the
	// source no longer has stays.
	top := u32(0)
	for i in 0 ..< ld(p + CREATURE_STYLE_N) {
		e := ld(es + 4 * i)
		if top == 0 || x86.mem[e + STYLE_LEVEL] > x86.mem[top + STYLE_LEVEL] {top = e}
	}
	top_groups: [GROUPS]Lv_Group
	top_read := false
	ces := ld(cre + CREATURE_STYLES)
	replay_n = 0
	for j in 0 ..< ld(cre + CREATURE_STYLE_N) {
		c, from := ld(ces + 4 * j), top
		for i in 0 ..< ld(p + CREATURE_STYLE_N) {
			if e := ld(es + 4 * i); ld(e) == ld(c) {from = e}
		}
		if from == 0 || replay_n == len(replay) {continue}
		have := upgrades(c)
		want := upgrades(from)
		if ld(from) != ld(c) && want != 0 {
			if !top_read {
				t := lv_load(ld(top))
				top_groups = lv_groups(t)
				lv_free(t)
				top_read = true
			}
			t := lv_load(ld(c))
			want = upgrades_as(want, top_groups, lv_groups(t))
			lv_free(t)
			fmt.eprintfln("coop: player 2 style %x takes style %x's upgrades %016x as %016x", ld(c), ld(top), upgrades(top), want)
			// Upgrades laid out another way (a save from before the
			// groups were matched) are replaced; fewer are not taken.
			if bits.count_ones(want) < bits.count_ones(have) {want = have}
		} else {
			want |= have
		}
		if want == have {continue}
		replay[replay_n] = {c, want}
		replay_n += 1
		st(c + STYLE_REPLAY, 1)
	}
	if replay_n > 0 {
		saved := x86.cpu
		x86.cpu.ecx = cre
		win32.guest_call(CREATURE_REPLAY_UPGRADES)
		x86.cpu = saved
		replay_n = 0
	}
	for j in 0 ..< ld(cre + CREATURE_STYLE_N) {
		c := ld(ces + 4 * j)
		fmt.eprintfln("coop: player 2 style %x level %d upgrades %016x", ld(c), x86.mem[c + STYLE_LEVEL], upgrades(c))
	}
	fmt.eprintfln("coop: player 2 %s %08x, health %d, chi %d, %d styles", h.name, ld(cre + CREATURE_ID), health, chi, n)
}

// thiscall(obj) through its vtable slot.
@(private = "file")
vcall :: proc(obj, slot: u32, args: ..u32) -> u32 {
	saved := x86.cpu
	defer x86.cpu = saved
	x86.cpu.ecx = obj
	return win32.guest_call(ld(ld(obj) + slot), ..args)
}
