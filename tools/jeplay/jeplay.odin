// Play-automation driver over the control channel. WHY: docs/modding.md §4
//
// Each command is assembled into the next of SLOTS script slots,
// override/zz_c00.ncs .. zz_c63.ncs, in turn, and run there. The slots must exist
// when the game starts (override/ is indexed once at startup). A deferred command
// (AssignCommand, DelayCommand, ActionDoCommand) keeps only its script's name and
// the engine reads that file again when the command fires, so a slot is not
// rewritten until SLOTS - 1 later commands have run. WHY: docs/modding.md §3
// State comes from the engine (GetIsInCombat, GetHealth, GetIsInConversation),
// never from screen pixels.
//
// A failure exits 1 with a message after releasing what the command holds
// down (the stick, block, a button), as the Python tool's finally blocks did.
package jeplay

import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "../common"
import "../hexgrid"
import "../jectl"
import "../ncs"
import "../pe"
import "../twoda"

USAGE :: `Usage: jeplay <ctl dir> <game dir> <command> [args] [--reply TEXT]...
  --reply TEXT      in every conversation the command meets (a use, travel or
                    talk), a reply containing TEXT is taken first
  init              create the script slots in override/ (then restart the game)
  query 'EXPR'      run ` + "`return EXPR`" + ` (an Int or String engine call) and print it
  do 'STMT; ...'    run engine call statements as the player
  goto TAG          jump the player to the object tagged TAG
  talk [N] [TEXT...] advance conversations and cutscenes until over (at most N
                    steps); a reply containing one of the TEXTs is taken first
  use TAG          use the nearest object tagged TAG (door, chest, shrine) as a click does,
                    standing at the engine's use point for it
  face TAG          turn the player toward the nearest object tagged TAG with the mouse
  ask TAG           have the object tagged TAG start its conversation with the player
  fight [N]         fight until combat ends (at most N rounds); heals when low
  walk X Y          walk the player to world (X, Y) with the stick along a grid route
  travel X Y        walk to (X, Y), fighting, talking and closing popups on the way
  walkto TAG        walk the player to the use point of the nearest object tagged TAG
  cross TAG         walk into the area transition trigger tagged TAG until the area loads
  pos               print the player's world x y
  recover           chi heal to full health while chi lasts (travel does this
                    after each fight)
  anims [TAG]       print the animations the player (or the object tagged TAG) plays
  panels            print the ids of the open GUI panels
  popups            close open notice popups with the attack button
  settle            wait until a movie or area load is over
  minigame [N]      play a flying minigame: fire held, sweeping side to side
  save              quick save (F5) a clean state: refuses unless idle, then clears
                    the action queues of the player and of every object a do or
                    ask named, so no test command is written into the save`

SLOTS :: 64 // slots used in turn; see the file comment
SLOT_NEXT :: "slot" // file in the ctl dir: index of the slot the next command uses
SLOT_INIT :: "return GetIsObjectValid(GetPlayer())" // placeholder content of a new slot
FRAMES_ATTACK :: 6 // frames a click is held, then released for as long
HEAL_FRACTION :: 0.4 // chi heal below this share of maximum health
FRAMES_STRONG :: 30 // frames a strong attack's wind-up and swing take before the next input
LIGHT_COMBO :: 3 // light attacks per round
RECOVER_HEALS :: 4 // chi heals one recover tries at most
FRAMES_HEAL :: 60 // Left Shift held this long channels one chi heal (1 chi per health)
CHI_MIN :: 10 // chi below which a heal is not tried; the player blocks instead
FRAMES_BLOCK :: 45 // frames Space is held for one blocking round
FRAMES_GUARD :: 20 // frames Space is held against a telegraphed blockable attack
FRAMES_EVADE :: 24 // frames an evade (the stick pushed twice) takes
FRAMES_FLICK :: 4 // frames the stick is pushed to start an evade
// Player base-channel animations in which block can rise but has not: Space
// held from before such a state does not block; a new press does.
UNGUARDED_ANIMS := [?]string{"ready", "cwalk", "crun", "run", "pause", "observe"}
EVADE_METHOD :: "Evade Method=2" // JadeEmpire.ini [InputOptions]: block + direction evades
GUARD_ANIM :: "blk" // AS rows whose anim starts so are the style's block, not an attack
OPENING_ANIMS := [?]string{"dmg", "kback", "kd"} // hit reactions: the foe cannot attack or block
RECOVERY_SUFFIX :: "tran" // an attack's recovery anim (m2tran, m4tran): the foe is open
GUARD_CHAIN :: 12 // blockable attacks one held block answers before it is dropped
LEARN_FILE :: "fightlearn.json" // file in the ctl dir: what each answer to each foe anim cost (see choose)
ANSWERS := [?]string{"block", "side", "back"} // answers to an attack, in the order tried while none has cost
ANSWER_WINDOW :: 45 // frames after an answer in which a hit counts against it
// Anims a hit is never blamed on: OPENING_ANIMS, GUARD_ANIM, "cddg", "face", UNGUARDED_ANIMS.
NOT_ATTACKS := [?]string{"dmg", "kback", "kd", "blk", "cddg", "face", "ready", "cwalk", "crun", "run", "pause", "observe"}
PATIENCE :: 3 // rounds guarded waiting for an opening before attacking anyway
CALM_ROUNDS :: 3 // rounds out of combat before the fight counts as over
FRAMES_TALK :: 90 // frames between dialog advances
// Dialog advances a talk command makes at most by default; story dialogs run
// past 60 lines (the Spirit Thief lesson in Tien's Landing).
TALK_STEPS :: 200
FRAMES_NUDGE :: 4 // frames a step key is held to move the camera after a jump
TALK_CLICK :: [2]int{160, 377} // the first reply line in the 640x480 dialog layout
// Guest layout of the conversation reply panel. WHY: docs/modding.md §5
APP :: 0x76C924 // global: the client app
APP_GUI :: 0xB4 // app -> GUI manager
GUI_PANELS :: 0x8C // GUI manager -> table of open panels by id (0x6d entries)
GUI_CURSEL :: 0x64 // GUI manager -> the CGuiPanel.LTI_CURSELOBJ panel (the use marker)
CURSEL_OBJ :: 0x120 // that panel -> id of the object a click uses, NO_OBJECT when none
NO_OBJECT :: 0xFFFFFFFF
OBJECT_TYPE_CREATURE :: 2 // GetObjectType of an NPC; Jade renumbered the NWN values (nwscript.nss)
FACE_TRIES :: 4 // turns toward an object before giving up on highlighting it
TARGET_CANDIDATES :: 32 // most objects the engine's selector (0x461970) ranks, so Tab presses that visit them all
// Mouse-look: the engine recentres the cursor every frame and turns the player
// by the DirectInput motion. WHY: docs/modding.md §4
MOUSE :: 0x75B528 // global: the game's mouse state (this of 0x51cea0)
MOUSE_CENTER :: 0x10 // -> the point the cursor is recentred on, two i32 (screen pixels)
TURN_GAIN :: 0.309 // degrees the player turns clockwise per pixel of rightward motion, measured in j02_ruins
TURN_PX :: 100 // pixels per move at most; a 200-pixel move turns only 47 degrees, not 62
TURN_TOL :: 2.0 // degrees; a facing this close to the target counts as facing it
TURN_STEPS :: 12 // mouse moves one face takes at most
FRAMES_TURN :: 4 // frames for a move to turn the player
PANEL_REPLY :: 0x17 // "lti_convorep", the bottom bar with the reply list
PANEL_XY :: 0x04 // panel, list box and item: x, y, w, h as four i32
LISTBOX :: 0xD4 // reply panel -> its ListBoxReply control
REPLY_COUNT :: 0x5C4 // reply panel -> number of reply items
REPLY_ITEMS :: 0x5CC // reply panel -> array of item pointers
ITEM_TEXT :: 0x1B8 // item -> CExoString {char *, length with the NUL}
REPLIES_MAX :: 16
REPLY_INSET :: 24 // pixels right of an item's left edge where it is clicked
TEXT_MAX :: 1024
PANEL_MOVIE :: 0x41 // CPanelLoadingScreen, open while a movie plays
GUI_SIZE :: [2]int{640, 480} // the GUI's virtual screen, the size of a full-screen panel
// Notice panels that block movement until the attack button closes them:
// "You received" and the tutorial text box, seen together after the toad.
POPUPS := [?]int{0x18, 0x43}
PANEL_PAUSED :: 0x3d // PAUSED notice; Return resumes the game
PANEL_DEATH :: 0x40 // death panel: the walk is over
POPUPS_MAX :: 8 // popups closed in one go at most
FRAMES_POPUP :: 20 // frames after a close for the next popup to come up
PANEL_MINIGAME :: 0x5A // the flying minigame's HUD, open while it runs
SWEEP_STEPS :: 12 // walk steps the minigame ship holds one direction
MINIGAME_STEPS :: 6000 // walk steps a minigame takes at most by default
FRAMES_SETTLE_WAIT :: 30 // frames between loading-panel checks
SETTLE_STEPS :: 400 // checks before a movie or load counts as hung (~6.5 min)
TRAVEL_LEGS :: 12 // interruptions one travel command handles at most
FIGHT_ROUNDS :: 120 // rounds a fight takes at most when travel starts it
PANEL_COUNT :: 0x6D // panel ids; the lookup 0x55d9f0 rejects 0x6d
PANEL_NAME :: 0x1C // panel field: pointer to its "CGuiPanel.<NAME>" string
PANEL_NAME_MAX :: 48 // bytes read for a panel name
LEDGER :: "touched" // file in the ctl dir: tags of objects test commands named
TAG_CALL :: "GetObjectByTag(" // a tag literal follows it (see touch)
SAVE_FILE :: "Save/Quick Save/save.sac"
FRAMES_SETTLE :: 30 // frames for cleared queues to take effect before saving
FRAMES_SAVE :: 120 // frames a quick save takes to write
WAKE_POINTS :: [2][2]int{{300, 200}, {320, 240}} // 640x480 pointer moves that put input back in keyboard mode
REACH :: 1.2 // metres between centres; farther targets are closed on with the stick (bodies stop about 1.0 apart; punches reach little past that)
CLOSE_STEPS :: 12 // stick steps one close_in takes at most
TARGET :: "GetPlayerCreatureCombatTarget()"
STR_MAX :: 256 // characters query_str reads at most
// Characters query_str can tell apart: printable ASCII. Any other reads as "?".
STR_ALPHABET := " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
ANIM_CHANNELS :: 3 // model animation channels the anims control command reports
PLAYER_GONE :: "no object tagged PLAYER" // control-channel error while the player object is absent (area swap)
MODEL_GONE :: "has no creature model" // end of the anims error for a creature out of the scene
ID_DIGITS :: 8 // hex digits of an object id in ObjectToString's text
// The player's state one fight round reads, as Int expressions (Player_State order).
PLAYER_STATE := [?]string {
	"GetIsDead(GetPlayer())",
	"GetIsInConversation(GetPlayer()) + GetInCutsceneMode()",
	"GetIsInCombat()",
	"GetHealth(GetPlayer())",
	"GetMaxHealth(GetPlayer())",
	"GetChi(GetPlayer())",
}
// A creature's state, as Int expressions with %s for the creature (Creature
// field order). mm: millimetres from the player.
CREATURE_STATE := [?]string {
	"GetIsObjectValid(%s)",
	"GetIsDead(%s)",
	"GetHealth(%s)",
	"GetCurrentStyle(%s)",
	"GetIsEnemy(GetPlayer(), %s)",
	"FloatToInt(GetDistanceBetween(GetPlayer(), %s) * 1000.0)",
	"GetStringLength(ObjectToString(%s))",
}
OBJECT_CREATURE :: 2 // object type: the class field of an object id (bits 27..31)
FOE_SCAN :: 12 // nearest creatures examined for a foe
TAG_SCAN :: 16 // objects sharing one tag examined for the nearest
FOE_RANGE :: 30 // metres; creatures farther are not counted as foes
THREAT_RANGE :: 3.5 // metres; foes this near besides the one fought are watched too
HIT_FOES :: 6 // foes note_hit locates: 2 positions each + 3 for the player within SLOTS / 4
HOSTILE_MAX :: 10 // reputation toward the player at or below which a creature is hostile
// One Int for a scanned creature: -1 when invalid, else millimetres from the
// player * 4 + 2 when hostile + 1 when dead (NWScript comparisons give 0 or 1).
SCAN_PACKED :: "GetIsObjectValid(%s) * (FloatToInt(GetDistanceBetween(GetPlayer(), %s) * 1000.0) * 4" +
	" + (GetIsEnemy(GetPlayer(), %s) <= 10) * 2 + GetIsDead(%s) + 1) - 1" // 10: HOSTILE_MAX
PEEK_CHUNK :: 4096 // bytes per peek (the control channel's limit)
STICK :: 32000 // left stick deflection while walking (of 32767)
FRAMES_STEP :: 8 // frames the stick is held per walking step
APP_SCENE :: 0xA0 // app -> scene holder whose +0x124 is the game camera (SetCameraFacing 0x492e80)
SCENE_CAMERA :: 0x124
CAMERA_POS :: 0x7C // camera -> world position, three floats
RUN_STEP :: 0.19 // metres the player runs per frame the stick is held, measured in j02_ruins
STUCK_DIST :: 0.05 // metres closer to the waypoint STUCK_STEPS steps must get
STUCK_STEPS :: 8 // steps in a row without progress before replanning or giving up
REPLANS :: 3 // replans one walk makes around unmapped obstacles before giving up
OBSTACLE_AHEAD :: 1.0 // metres ahead of a stuck player where the unmapped obstacle is put
OBSTACLE_RADIUS :: 0.9 // metres of grid blocked around it
BAND_CELLS_MAX :: 4096 // 0xfe cells one hardened band blocks at most
ARRIVE :: 0.6 // metres from a waypoint at which it counts as reached
WALK_STEPS :: 800 // steps one walk takes at most
SNAP_RINGS :: 6 // hex steps a blocked walk end may move to reach an open cell
// One step's view of the world, read in one batch (see Sense).
SENSE_STATE := [?]string{"GetIsInConversation(GetPlayer())", "GetInCutsceneMode()", "GetIsInCombat()"}
SENSE_WHY := [?]string{"conversation", "cutscene", "combat"}

Point :: hexgrid.Point

// One animation a model channel plays.
Anim :: struct {
	name:         string,
	time, speed:  f64,
	flags:        int,
}

Chans :: [ANIM_CHANNELS][]Anim // base, head, weapon

Creature :: struct {
	valid, dead, hp, style, enemy, mm, digits: int, // CREATURE_STATE
	expr:  string,
	id:    u32,
	label: string, // how foe found it
}

// A telegraphed attack: its AS row's label and anim, plus who plays it and
// in which style (set once swing sees it).
Move :: struct {
	label, anim: string,
	unblockable: int,
	style:       int,
	by:          Creature,
	has_by:      bool,
}

// The key watch's ignore takes for a move: (attacker id, anim).
Answered :: struct {
	id:   u32,
	anim: string,
}

// The player's hp and base channel and state ids at the last swing (see note_hit).
Last :: struct {
	hp:     int,
	base:   []Anim,
	states: []string,
}

// The last answer given (see answered_with).
Answer :: struct {
	key, answer: string,
	frame:       int,
}

// What each answer to one "style:anim" cost: answers in first-seen order,
// rows [tries, damage].
Learn :: struct {
	answers: [dynamic]string,
	rows:    [dynamic][2]int,
}

Player_State :: struct {
	dead, talk, combat, hp, top, chi: int, // PLAYER_STATE
}

// Why walking must stop ("conversation", "cutscene", "combat" or ""), the
// player's (x, y), the camera-to-player heading (see stick_toward), the
// open panel ids, whether a load or movie is up (here is unset then), and
// the (x, y) of another object if one was asked for.
Sense :: struct {
	why:     string,
	here:    Point,
	bearing: f64,
	panels:  []int,
	loading: bool,
	there:   Point,
}

Reply :: struct {
	text: string,
	x, y: int,
}

Round_State :: struct {
	blocked: bool, // light attacks did no damage
	waited:  int, // rounds guarded since the last attack
}

Game :: struct {
	ctl, game: string,
	styles:    map[int]map[string]Move, // combat style -> {anim: AS row} (see telegraph)
	last:      Maybe(Last),
	frame:     int, // frame number at the last swing
	answer:    Maybe(Answer),
	learned:   map[string]^Learn, // "style:anim" -> costs (see choose)
	prefer:    [dynamic]string, // reply texts every talk takes first (--reply)
}

// What a failure releases: the cleanup stack stands in for Python's finally.
Cleanup_Kind :: enum {
	Btn, // "btn NAME up"
	Key, // "up NAME"
	Stick, // stick centred
	Fight, // learned table saved, Space up
	Minigame, // fire up, stick centred
}

Cleanup :: struct {
	kind: Cleanup_Kind,
	name: string,
	g:    ^Game,
}

cleanups: [dynamic]Cleanup
failing: bool

push_cleanup :: proc(g: ^Game, kind: Cleanup_Kind, name := "") {
	append(&cleanups, Cleanup{kind, name, g})
}

pop_cleanup :: proc() {
	run_cleanup(pop(&cleanups))
}

run_cleanup :: proc(c: Cleanup) {
	switch c.kind {
	case .Btn:
		send(c.g, fmt.aprintf("btn %s up", c.name))
	case .Key:
		send(c.g, strings.concatenate({"up ", c.name}))
	case .Stick:
		stick_off(c.g)
	case .Fight:
		save_learned(c.g)
		send(c.g, "up Space")
	case .Minigame:
		send(c.g, "btn L up")
		stick_off(c.g)
	}
}

// Releases what is held (see Cleanup), prints the message, exits 1. A
// failure while releasing exits with its own message.
fail :: proc(format: string, args: ..any) -> ! {
	msg := fmt.aprintf(format, ..args)
	if !failing {
		failing = true
		for len(cleanups) > 0 do run_cleanup(pop(&cleanups))
	}
	fmt.eprintln(msg)
	os.exit(1)
}

check :: proc(ok: bool, format: string, args: ..any) {
	if !ok do fail(strings.concatenate({"assertion failed: ", format}), ..args)
}

join :: proc(dir, name: string) -> string {
	return strings.has_suffix(dir, "/") ? strings.concatenate({dir, name}) : strings.concatenate({dir, "/", name})
}

write_file :: proc(path: string, data: []u8) {
	if err := os.write_entire_file(path, data); err != nil do fail("%s: %v", path, err)
}

atoi :: proc(s: string) -> int {
	v, ok := strconv.parse_int(s, 10)
	if !ok do fail("invalid literal for int(): %q", s)
	return v
}

atof :: proc(s: string) -> f64 {
	v, ok := strconv.parse_f64(s)
	if !ok do fail("could not convert string to float: %q", s)
	return v
}

hex_bytes :: proc(s: string) -> []u8 {
	b, ok := hex.decode(transmute([]u8)s)
	if !ok do fail("bad hex %q", s)
	return b
}

// Python's float %: the result takes the sign of b.
py_mod :: proc(a, b: f64) -> f64 {
	r := math.mod(a, b)
	if r != 0 && (r < 0) != (b < 0) do r += b
	return r
}

degrees :: proc(r: f64) -> f64 {return r * (180.0 / math.PI)}
radians :: proc(d: f64) -> f64 {return d * (math.PI / 180.0)}

has_prefix_any :: proc(s: string, prefixes: []string) -> bool {
	for p in prefixes do if strings.has_prefix(s, p) do return true
	return false
}

// "name@time ..." of a channel, as the prints show it.
anim_list :: proc(chan: []Anim) -> string {
	parts := make([]string, len(chan))
	for a, i in chan do parts[i] = fmt.aprintf("%s@%.2f", a.name, a.time)
	return strings.join(parts, " ")
}

// Python's repr of an (x, y) tuple.
point_repr :: proc(p: Point) -> string {
	return fmt.aprintf("(%s, %s)", common.py_repr_float(p.x), common.py_repr_float(p.y))
}

// Python's repr of a list of ints.
ints_repr :: proc(v: []int) -> string {
	parts := make([]string, len(v))
	for x, i in v do parts[i] = fmt.aprintf("%d", x)
	return strings.concatenate({"[", strings.join(parts, ", "), "]"})
}

// Bytes decoded as UTF-8, each invalid byte replaced by U+FFFD.
utf8_replace :: proc(b: []u8) -> string {
	sb := strings.builder_make()
	for i := 0; i < len(b); {
		r, n := utf8.decode_rune(b[i:])
		if r == utf8.RUNE_ERROR && n <= 1 {
			strings.write_rune(&sb, 0xFFFD)
			i += 1
			continue
		}
		strings.write_bytes(&sb, b[i:i + n])
		i += n
	}
	return strings.to_string(sb)
}

game_new :: proc(ctl, game: string) -> ^Game {
	g := new(Game)
	g.ctl, g.game = ctl, game
	g.learned = load_learned(ctl)
	for i in 0 ..< SLOTS {
		p := slot_path(game, i)
		if !os.exists(p) do fail("%s missing: run init, then restart the game", p)
	}
	return g
}

send :: proc(g: ^Game, line: string) -> string {
	r := jectl.send(g.ctl, line)
	if !strings.has_prefix(r, "ok") do fail("%s -> %s", line, r)
	return r
}

// Assembles src into the next slot and runs it as the player.
run :: proc(g: ^Game, src: string) {
	code := ncs.assemble(src)
	i := next_slot(g)
	write_file(slot_path(g.game, i), code)
	w := strings.fields(send(g, strings.concatenate({"exec ", slot_name(i)})))
	if len(w) != 4 || w[1] != "1" do fail("exec failed: %s", strings.join(w, " "))
}

// Index of the slot to write now; advances the one stored in the ctl dir.
next_slot :: proc(g: ^Game) -> int {
	path := join(g.ctl, SLOT_NEXT)
	i := 0
	if os.exists(path) {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil do fail("%s: %v", path, err)
		i = atoi(strings.trim_space(string(data)))
	}
	check(0 <= i && i < SLOTS, "%d", i)
	write_file(path, transmute([]u8)fmt.aprintf("%d", (i + 1) % SLOTS))
	return i
}

allowed :: proc(a, allow: string) -> bool {
	return allow != "" && strings.has_prefix(a, "err") && strings.has_suffix(a, allow)
}

// Sends command lines to run in one frame (jectl.send_batch); answers. An
// error answer ending in allow is returned, any other exits.
batch :: proc(g: ^Game, lines: []string, allow := "") -> []string {
	r := jectl.send_batch(g.ctl, lines)
	for a, k in r do if !strings.has_prefix(a, "ok") && !allowed(a, allow) do fail("%s -> %s", lines[k], a)
	return r
}

query :: proc(g: ^Game, expr: string) -> int {
	v, _, _ := queries(g, {expr})
	return v[0]
}

// Runs `return EXPR` for each Int expression, all in one frame; the values
// in order. Command lines in extra go in the same batch, before the
// scripts, and their answers are returned too (an answer may be an error
// ending in allow, see batch; gone is set when a script's is, its value
// left 0). Each expression takes the next slot, so a batch stays well under
// SLOTS (a slot a deferred command names must not be rewritten).
queries :: proc(g: ^Game, exprs: []string, extra: []string = nil, allow := "") -> (vals: []int, answers: []string, gone: bool) {
	check(0 < len(exprs) && len(exprs) <= SLOTS / 4, "%d", len(exprs))
	lines := make([dynamic]string)
	append(&lines, ..extra)
	for e in exprs {
		i := next_slot(g)
		write_file(slot_path(g.game, i), ncs.assemble(strings.concatenate({"return ", e})))
		append(&lines, strings.concatenate({"exec ", slot_name(i)}))
	}
	r := batch(g, lines[:], allow)
	int_type, _ := ncs.type_byte("Int")
	vals = make([]int, len(exprs))
	for e, k in exprs {
		a := r[len(extra) + k]
		if allowed(a, allow) {
			gone = true
			continue
		}
		w := strings.fields(a)
		if len(w) != 4 || w[1] != "1" do fail("exec failed for %s: %s", e, a)
		if atoi(w[2]) != int(int_type) do fail("%s: result type %s", e, w[2])
		vals[k] = atoi(w[3])
	}
	return vals, r[:len(extra)], gone
}

// The value of String expression expr. Script results are Int only (the VM
// keeps no other type), so this reads the length, then each character as
// its index in STR_ALPHABET, a batch of queries at a time. expr is evaluated
// once per character: it must not change meanwhile. WHY: docs/modding.md §2
query_str :: proc(g: ^Game, expr: string) -> string {
	n := query(g, fmt.aprintf("GetStringLength(%s)", expr))
	check(0 <= n && n <= STR_MAX, "(%s, %d)", expr, n)
	esc, _ := strings.replace_all(STR_ALPHABET, "\\", "\\\\")
	esc, _ = strings.replace_all(esc, "\"", "\\\"")
	alphabet := strings.concatenate({"\"", esc, "\""})
	out := strings.builder_make()
	for k := 0; k < n; k += SLOTS / 4 {
		exprs: [dynamic]string
		for i in k ..< min(n, k + SLOTS / 4) do append(&exprs, fmt.aprintf("FindSubString(%s, GetSubString(%s, %d, 1))", alphabet, expr, i))
		idx, _, _ := queries(g, exprs[:])
		for i in idx do strings.write_byte(&out, 0 <= i && i < len(STR_ALPHABET) ? STR_ALPHABET[i] : '?')
	}
	return strings.to_string(out)
}

// Tags src names in GetObjectByTag(\s*"TAG" calls, in order.
tag_literals :: proc(src: string) -> []string {
	out: [dynamic]string
	pos := 0
	for {
		k := strings.index(src[pos:], TAG_CALL)
		if k < 0 do break
		start := pos + k
		pos = start + 1
		i := start + len(TAG_CALL)
		for i < len(src) {
			r, n := utf8.decode_rune(src[i:])
			if !common.py_space(r) do break
			i += n
		}
		if i >= len(src) || src[i] != '"' do continue
		end := strings.index_byte(src[i + 1:], '"')
		if end < 0 do continue
		append(&out, src[i + 1:i + 1 + end])
		pos = i + 2 + end
	}
	return out[:]
}

// Records in the ledger every tag src names, as a command may have queued
// actions on that object. WHY: docs/modding.md §4
touch :: proc(g: ^Game, src: string) {
	tags := tag_literals(src)
	if len(tags) == 0 do return
	path := join(g.ctl, LEDGER)
	f, err := os.open(path, {.Write, .Append, .Create})
	if err != nil do fail("%s: %v", path, err)
	defer os.close(f)
	sb := strings.builder_make()
	for t in tags do fmt.sbprintf(&sb, "%s\n", t)
	if _, werr := os.write_string(f, strings.to_string(sb)); werr != nil do fail("%s: %v", path, werr)
}

// Tags in the ledger, each once, in first-seen order.
touched :: proc(g: ^Game) -> []string {
	path := join(g.ctl, LEDGER)
	if !os.exists(path) do return nil
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do fail("%s: %v", path, err)
	out: [dynamic]string
	seen: map[string]bool
	for t in strings.split(string(data), "\n") {
		if t == "" || t in seen do continue
		seen[t] = true
		append(&out, t)
	}
	return out[:]
}

frames :: proc(g: ^Game, n: int) {
	send(g, fmt.aprintf("wait %d", n))
}

// n bytes of guest memory at addr.
peek :: proc(g: ^Game, addr: u32, n: int) -> []u8 {
	r := strings.fields(send(g, fmt.aprintf("peek %x %d", addr, n)))
	if len(r) != 2 || len(r[1]) != 2 * n do fail("peek %#x %d -> %s", addr, n, strings.join(r, " "))
	return hex_bytes(r[1])
}

peek32 :: proc(g: ^Game, addr: u32) -> u32 {
	return pe.le32(peek(g, addr, 4), 0)
}

// (x, y, w, h) of a GUI control at addr.
rect :: proc(g: ^Game, addr: u32) -> [4]int {
	b := peek(g, addr + PANEL_XY, 16)
	return {int(i32(pe.le32(b, 0))), int(i32(pe.le32(b, 4))), int(i32(pe.le32(b, 8))), int(i32(pe.le32(b, 12)))}
}

// The GUI manager's table of open panels by id.
panel_table :: proc(g: ^Game) -> u32 {
	return peek32(g, peek32(g, peek32(g, APP) + APP_GUI) + GUI_PANELS)
}

// One attack without moving the mouse (a move turns the camera): light with
// L, strong with R. With cs (creatures, see creature), cs are watched while
// the button is held and released; the attack one telegraphs is returned at
// once (the button released), else nil.
attack :: proc(g: ^Game, button := "L", cs: []Creature = nil) -> ^Move {
	send(g, fmt.aprintf("btn %s down", button))
	push_cleanup(g, .Btn, button)
	move := watch(g, cs, FRAMES_ATTACK)
	pop_cleanup()
	return move != nil ? move : watch(g, cs, FRAMES_ATTACK)
}

// Holds key for frames frames while watching cs (see watch); the attack one
// telegraphs, which ends the hold early, or nil.
hold :: proc(g: ^Game, key: string, n: int, cs: []Creature) -> ^Move {
	send(g, strings.concatenate({"down ", key}))
	push_cleanup(g, .Key, key)
	move := watch(g, cs, n)
	pop_cleanup()
	return move
}

// An Int expression for the id of the object expr names. A script returns
// only ints (the VM's return cell reads type 0 for an object), so
// ObjectToString's 8 lower-case hex digits are decoded in the script; the
// top digit's product wraps in the VM's 32-bit int, so mask the value with
// 0xFFFFFFFF. WHY: docs/modding.md §2
id_expr :: proc(expr: string) -> string {
	parts: [ID_DIGITS]string
	for k in 0 ..< ID_DIGITS {
		parts[k] = fmt.aprintf(`FindSubString("0123456789abcdef", GetSubString(ObjectToString(%s), %d, 1)) * %d`, expr, k, 1 << uint(4 * (ID_DIGITS - 1 - k)))
	}
	return strings.join(parts[:], " + ")
}

// The CREATURE_STATE values of the creature expr names, read in one frame,
// plus expr and id (its object id).
creature :: proc(g: ^Game, expr: string) -> Creature {
	exprs: [dynamic]string
	for e in CREATURE_STATE {
		s, _ := strings.replace_all(e, "%s", expr)
		append(&exprs, s)
	}
	append(&exprs, id_expr(expr))
	v, _, _ := queries(g, exprs[:])
	c := Creature {
		valid  = v[0],
		dead   = v[1],
		hp     = v[2],
		style  = v[3],
		enemy  = v[4],
		mm     = v[5],
		digits = v[6],
		expr   = expr,
		id     = u32(v[7] & 0xFFFFFFFF),
	}
	check(c.valid == 0 || c.digits == ID_DIGITS, "%v", c)
	return c
}

nearest_creature :: proc(n: int) -> string {
	return fmt.aprintf("GetNearestObject(GetPlayer(), %d, %d)", OBJECT_CREATURE, n)
}

// The creature to fight (see creature, label: how it was found), or false.
// Creatures whose ids are in gone (see anims) are passed over.
//
// The combat target while it lives; otherwise the nearest live hostile
// creature within FOE_RANGE. Fights spread out, so the engine's target is
// often unset while a group is still coming. WHY: docs/modding.md §4
foe :: proc(g: ^Game, gone: map[u32]bool) -> (Creature, bool) {
	c := creature(g, TARGET)
	if c.valid != 0 && c.dead == 0 && c.id not_in gone {
		c.label = "target"
		return c, true
	}
	for n in 0 ..< FOE_SCAN {
		c = creature(g, nearest_creature(n))
		if c.valid == 0 || c.mm > FOE_RANGE * 1000 do return {}, false
		if c.dead == 0 && c.enemy <= HOSTILE_MAX && c.id not_in gone {
			c.label = fmt.aprintf("nearest creature %d", n)
			return c, true
		}
	}
	return {}, false
}

// The live hostile creatures other than c within THREAT_RANGE, nearest
// first, each with only expr and id set. A group attacks from several
// sides, so all of them are watched, not only the one fought. Two round
// trips: one packs each of the FOE_SCAN nearest creatures into one Int (see
// SCAN_PACKED), one reads the ids of the near hostiles; a frame per
// creature (see creature) left the player unguarded for a dozen frames each
// round. WHY: docs/modding.md §5
near_foes :: proc(g: ^Game, c: Creature, gone: map[u32]bool) -> []Creature {
	exprs: [FOE_SCAN]string
	packs: [FOE_SCAN]string
	for n in 0 ..< FOE_SCAN {
		exprs[n] = nearest_creature(n)
		packs[n], _ = strings.replace_all(SCAN_PACKED, "%s", exprs[n])
	}
	packed, _, _ := queries(g, packs[:])
	hits: [dynamic]string
	for v, n in packed {
		if v < 0 || f64(v / 4) > THREAT_RANGE * 1000 do break
		if v & 3 == 2 do append(&hits, exprs[n])
	}
	if len(hits) == 0 do return nil
	ids_src: [dynamic]string
	for e in hits[:min(len(hits), SLOTS / 4)] do append(&ids_src, id_expr(e))
	ids, _, _ := queries(g, ids_src[:])
	out: [dynamic]Creature
	for i, k in ids {
		id := u32(i & 0xFFFFFFFF)
		if id != c.id && id not_in gone do append(&out, Creature{expr = hits[k], id = id})
	}
	return out[:]
}

// The anims command's reply as animations per model channel (base, head,
// weapon). WHY: docs/modding.md §5
parse_anims :: proc(reply: string) -> Chans {
	w := strings.fields(reply)
	out: Chans
	k := 1
	for ch in 0 ..< ANIM_CHANNELS {
		check(w[k] == "|", "%v", w)
		n := atoi(w[k + 1])
		rows := make([]Anim, n)
		for i in 0 ..< n {
			b := k + 2 + 4 * i
			flags, ok := strconv.parse_int(w[b + 3], 16)
			if !ok do fail("invalid literal for int() with base 16: %q", w[b + 3])
			rows[i] = Anim{w[b], atof(w[b + 1]), atof(w[b + 2]), flags}
		}
		out[ch] = rows
		k += 2 + 4 * n
	}
	return out
}

// The animations a creature plays now (see parse_anims), or false when it
// has no model: a foe that flees the fight leaves the scene while its object
// stays valid, alive and hostile. ref is a hex object id or a tag.
anims :: proc(g: ^Game, ref: string) -> (Chans, bool) {
	r := jectl.send(g.ctl, strings.concatenate({"anims ", ref}))
	if strings.has_prefix(r, "err") && strings.has_suffix(r, MODEL_GONE) do return {}, false
	if !strings.has_prefix(r, "ok") do fail("anims %s -> %s", ref, r)
	return parse_anims(r), true
}

py_int :: proc(s: string) -> int {
	return s == "" ? 0 : atoi(strings.trim_space(s))
}

// The attack a creature of combat style style is winding up or swinging,
// read from the animations of its model's base channel (anims) and the
// style's AS table, or nil. Rows sharing an anim count as unblockable when
// any is. WHY: docs/modding.md §5
telegraph :: proc(g: ^Game, style: int, base: []Anim) -> ^Move {
	if style not_in g.styles {
		moves := make(map[string]Move)
		for r in twoda.style_attacks(g.game, style) {
			a := strings.to_lower(r["anim"])
			if strings.has_prefix(a, GUARD_ANIM) do continue
			u := py_int(r["unblockable"])
			if u == 0 {
				if m, ok := moves[a]; ok do u = m.unblockable
			}
			moves[a] = Move{label = r["label"], anim = r["anim"], unblockable = u}
		}
		g.styles[style] = moves
	}
	moves := g.styles[style]
	for an in base {
		n := strings.to_lower(an.name)
		if m, ok := moves[n]; ok do return new_clone(m)
		// An anim outside the AS table that has hit the player (style 98's
		// m1tran lands through a held block) is an attack too.
		// WHY: docs/modding.md §5
		if learn_key(style, n) in g.learned do return new_clone(Move{label = n, anim = n})
	}
	return nil
}

// Reads the base-channel animation of each creature in cs once, all in one
// round trip (answered in the next frame the port presents): the frame
// number and the first attack one telegraphs or nil. The attack is its AS
// row plus by, the creature. Creatures whose model is gone are passed
// over. WHY: docs/modding.md §5
swing :: proc(g: ^Game, cs: []Creature) -> (int, ^Move) {
	// A foe can change style mid-fight (the Two Rivers lieutenant uses
	// three), so the style is read with the animation. WHY: docs/modding.md §5
	n := len(cs)
	exprs: [dynamic]string
	extra: [dynamic]string
	append(&extra, "frame", "anims PLAYER", "states PLAYER")
	for c in cs {
		append(&exprs, fmt.aprintf("GetCurrentStyle(%s)", c.expr))
		append(&extra, fmt.aprintf("anims %08x", c.id))
	}
	append(&exprs, "GetHealth(GetPlayer())")
	v, ans, _ := queries(g, exprs[:], extra[:], MODEL_GONE)
	styles, hp := v[:n], v[n]
	fr, me, st, replies := ans[0], ans[1], ans[2], ans[3:]
	g.frame = atoi(strings.fields(fr)[1])
	note_hit(g, cs, hp, parse_anims(me)[0], strings.fields(st)[2:], styles, replies)
	for c, k in cs {
		a := replies[k]
		if strings.has_prefix(a, "err") && strings.has_suffix(a, MODEL_GONE) do continue
		move := telegraph(g, styles[k], parse_anims(a)[0])
		if move != nil {
			move.by, move.has_by, move.style = c, true, styles[k]
			return g.frame, move
		}
	}
	return g.frame, nil
}

Foe_Seen :: struct {
	d:     f64,
	style: int,
	reply: string, // its anims answer
}

// Prints a line when the player's hp fell since the last swing: the
// player's base channel and state ids (the states command; 9 blocking) then
// and now, and per foe in cs its style, base channel, distance and bearing
// off the player's facing (0 ahead, +left). Records hp, base and states in
// g.last. WHY: docs/modding.md §5
note_hit :: proc(g: ^Game, cs: []Creature, hp: int, base: []Anim, states: []string, styles: []int, replies: []string) {
	last, had := g.last.?
	g.last = Last{hp, base, states}
	if !had || hp >= last.hp do return
	cs := cs[:min(len(cs), HIT_FOES)]
	exprs: [dynamic]string
	append(&exprs, "FloatToInt(GetFacing(GetPlayer()) * 1000.0)")
	objs: [dynamic]string
	append(&objs, "GetPlayer()")
	for c in cs do append(&objs, c.expr)
	for o in objs {
		for a in ([?]string{"x", "y"}) do append(&exprs, fmt.aprintf("FloatToInt(GetPosition(%s).%s * 1000.0)", o, a))
	}
	iv, _, _ := queries(g, exprs[:])
	v := make([]f64, len(iv))
	for x, i in iv do v[i] = f64(x) / 1000.0
	f, p := v[0], Point{v[1], v[2]}
	foes := make([]Foe_Seen, len(cs))
	for k in 0 ..< len(cs) do foes[k] = Foe_Seen{hexgrid.dist(p, Point{v[3 + 2 * k], v[4 + 2 * k]}), styles[k], replies[k]}
	blame(g, last.hp - hp, last.base, foes)
	fmt.printf("  hit: -%d hp to %d, player was %s [%s] now %s [%s]\n", last.hp - hp, hp, anim_list(last.base), strings.join(last.states, " "), anim_list(base), strings.join(states, " "))
	for c, k in cs {
		q := Point{v[3 + 2 * k], v[4 + 2 * k]}
		rel := py_mod(degrees(math.atan2(q.y - p.y, q.x - p.x)) - f + 180.0, 360.0) - 180.0
		a := replies[k]
		chan := strings.has_prefix(a, "err") ? "-" : anim_list(parse_anims(a)[0])
		fmt.printf("    foe %x style %d at %.1f m bearing %+.0f: %s\n", c.id, styles[k], hexgrid.dist(p, q), rel, chan)
	}
}

// Key of the learned table for anim played by a creature of style.
learn_key :: proc(style: int, anim: string) -> string {
	return fmt.aprintf("%d:%s", style, strings.to_lower(anim))
}

// The [tries, damage] row of answer to key, made empty when new.
learn_row :: proc(g: ^Game, key, answer: string) -> ^[2]int {
	l := g.learned[key]
	if l == nil {
		l = new(Learn)
		g.learned[key] = l
	}
	for a, i in l.answers do if a == answer do return &l.rows[i]
	append(&l.answers, answer)
	append(&l.rows, [2]int{})
	return &l.rows[len(l.rows) - 1]
}

// Python's repr of one key's answers: {'block': [1, 5], ...}.
learn_repr :: proc(l: ^Learn) -> string {
	parts := make([]string, len(l.answers))
	for a, i in l.answers do parts[i] = fmt.aprintf("%s: [%d, %d]", common.py_repr_str(a), l.rows[i][0], l.rows[i][1])
	return strings.concatenate({"{", strings.join(parts, ", "), "}"})
}

json_int :: proc(v: json.Value) -> int {
	#partial switch x in v {
	case json.Integer:
		return int(x)
	case json.Float:
		return int(x)
	}
	fail("%s: expected a number, got %v", LEARN_FILE, v)
}

// The learned table saved in ctl (see LEARN_FILE), empty when none is.
// Keys are taken in sorted order, the order save_learned writes them.
load_learned :: proc(ctl: string) -> map[string]^Learn {
	out := make(map[string]^Learn)
	path := join(ctl, LEARN_FILE)
	if !os.exists(path) do return out
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do fail("%s: %v", path, err)
	root, jerr := json.parse(data, parse_integers = true)
	if jerr != nil do fail("%s: %v", path, jerr)
	top, ok := root.(json.Object)
	if !ok do fail("%s: not an object", path)
	keys: [dynamic]string
	for k in top do append(&keys, k)
	slice.sort(keys[:])
	for k in keys {
		inner, iok := top[k].(json.Object)
		if !iok do fail("%s: %s is not an object", path, k)
		l := new(Learn)
		answers: [dynamic]string
		for a in inner do append(&answers, a)
		slice.sort(answers[:])
		for a in answers {
			row, rok := inner[a].(json.Array)
			if !rok || len(row) != 2 do fail("%s: %s %s is not a pair", path, k, a)
			append(&l.answers, a)
			append(&l.rows, [2]int{json_int(row[0]), json_int(row[1])})
		}
		out[k] = l
	}
	return out
}

// A JSON string literal as Python's json.dump writes it (ensure_ascii).
json_str :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	for r in s {
		switch {
		case r == '"':
			strings.write_string(sb, `\"`)
		case r == '\\':
			strings.write_string(sb, `\\`)
		case r == '\n':
			strings.write_string(sb, `\n`)
		case r == '\r':
			strings.write_string(sb, `\r`)
		case r == '\t':
			strings.write_string(sb, `\t`)
		case r == '\b':
			strings.write_string(sb, `\b`)
		case r == '\f':
			strings.write_string(sb, `\f`)
		case r < 0x20 || (0x7F <= r && r < 0x10000):
			if r < 0x7F || r > 0x7F do fmt.sbprintf(sb, `\u%04x`, int(r))
			else do strings.write_rune(sb, r) // DEL stays as is
		case r >= 0x10000:
			v := int(r) - 0x10000
			fmt.sbprintf(sb, `\u%04x\u%04x`, 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
		case:
			strings.write_rune(sb, r)
		}
	}
	strings.write_byte(sb, '"')
}

// Writes the learned table as json.dump(indent=1, sort_keys=True) does.
save_learned :: proc(g: ^Game) {
	sb := strings.builder_make()
	keys: [dynamic]string
	for k in g.learned do append(&keys, k)
	slice.sort(keys[:])
	if len(keys) == 0 {
		strings.write_string(&sb, "{}")
	} else {
		strings.write_string(&sb, "{\n")
		for k, i in keys {
			l := g.learned[k]
			strings.write_string(&sb, " ")
			json_str(&sb, k)
			names := slice.clone(l.answers[:])
			slice.sort(names)
			if len(names) == 0 {
				strings.write_string(&sb, ": {}")
			} else {
				strings.write_string(&sb, ": {\n")
				for a, j in names {
					row := learn_row(g, k, a)
					strings.write_string(&sb, "  ")
					json_str(&sb, a)
					fmt.sbprintf(&sb, ": [\n   %d,\n   %d\n  ]", row[0], row[1])
					strings.write_string(&sb, j + 1 < len(names) ? ",\n" : "\n")
				}
				strings.write_string(&sb, " }")
			}
			strings.write_string(&sb, i + 1 < len(keys) ? ",\n" : "\n")
		}
		strings.write_string(&sb, "}")
	}
	write_file(join(g.ctl, LEARN_FILE), sb.buf[:])
}

// The answer (one of ANSWERS) to move that has cost least damage per try
// so far; untried answers cost nothing, so each is tried in turn once the
// ones before it have let a hit through. Block is never chosen against an
// unblockable attack. WHY: docs/modding.md §5
choose :: proc(g: ^Game, move: Move) -> string {
	l := g.learned[learn_key(move.style, move.anim)]
	answers := ANSWERS[:]
	options := move.unblockable != 0 ? answers[1:] : answers
	cost :: proc(l: ^Learn, a: string) -> f64 {
		if l == nil do return 0
		for x, i in l.answers {
			if x == a {
				n, d := l.rows[i][0], l.rows[i][1]
				return n != 0 ? f64(d) / f64(n) : 0
			}
		}
		return 0
	}
	best, best_cost := options[0], cost(l, options[0])
	for a in options[1:] {
		if c := cost(l, a); c < best_cost do best, best_cost = a, c
	}
	return best
}

// Counts one try of answer against move; a hit within ANSWER_WINDOW frames
// is charged to it (see blame).
answered_with :: proc(g: ^Game, move: Move, answer: string) {
	key := learn_key(move.style, move.anim)
	learn_row(g, key, answer)[0] += 1
	g.answer = Answer{key, answer, g.frame}
}

// Charges a hit of dmg to the answer given within ANSWER_WINDOW frames, else
// to the anim of the nearest foe that is attacking, answered by "block"
// when the player's base channel mine shows a block, else "none". A blamed
// anim is an attack from then on (see telegraph). WHY: docs/modding.md §5
blame :: proc(g: ^Game, dmg: int, mine: []Anim, foes: []Foe_Seen) {
	key, answer: string
	if a, ok := g.answer.?; ok && g.frame - a.frame <= ANSWER_WINDOW {
		key, answer = a.key, a.answer
		learn_row(g, key, answer)[1] += dmg
	} else {
		// min over (distance, style, anim) tuples, as Python compares them
		have := false
		bd: f64
		bs: int
		bn: string
		for f in foes {
			if strings.has_prefix(f.reply, "err") do continue
			for an in parse_anims(f.reply)[0] {
				if has_prefix_any(strings.to_lower(an.name), NOT_ATTACKS[:]) do continue
				less := !have || f.d < bd || (f.d == bd && (f.style < bs || (f.style == bs && an.name < bn)))
				if less do have, bd, bs, bn = true, f.d, f.style, an.name
			}
		}
		if !have {
			fmt.printf("  learn: -%d hp, no attacking foe to blame\n", dmg)
			return
		}
		key = learn_key(bs, bn)
		answer = "none"
		for m in mine do if strings.has_prefix(strings.to_lower(m.name), GUARD_ANIM) do answer = "block"
		row := learn_row(g, key, answer)
		row[0] += 1
		row[1] += dmg
	}
	fmt.printf("  learn: %s %s now %s\n", key, answer, learn_repr(g.learned[key]))
}

answered :: proc(move: Move) -> Answered {
	return {move.by.id, strings.to_lower(move.anim)}
}

// Lets n frames pass while reading the creatures in cs every frame (see
// swing); the attack one telegraphs as soon as one shows, else nil.
// ignore: an answered() key, the attack already answered, passed over.
// cs nil: just wait. WHY: docs/modding.md §5
watch :: proc(g: ^Game, cs: []Creature, n: int, ignore: Maybe(Answered) = nil) -> ^Move {
	if cs == nil {
		frames(g, n)
		return nil
	}
	end, have_end := 0, false
	for _ in 0 ..= n {
		now, move := swing(g, cs)
		if !have_end do end, have_end = now + n, true
		if now >= end do return nil
		if move != nil {
			ig, ok := ignore.?
			if !ok || answered(move^) != ig do return move
		}
	}
	return nil
}

// Answers an attack one of the creatures in cs telegraphs: block a
// blockable one (see guard), evade an unblockable one, also one that
// follows a block. refs: see sense_refs. WHY: docs/modding.md §5
defend :: proc(g: ^Game, refs: [2]u32, cs: []Creature, move: ^Move) {
	move := move
	if choose(g, move^) == "block" do move = guard(g, cs, 0, move)
	if move != nil do evade(g, refs, move^, choose(g, move^))
}

// Holds block (Space) and returns the player's base channel (see
// parse_anims). Block is raised by a press, not by Space being down: held
// through a heal, an evade or a lull, the player stands ready unguarded
// while Space is down. So Space is pressed anew when the player stands
// ready. Also returns the player's state ids (9 is blocking).
// WHY: docs/modding.md §5
raise_block :: proc(g: ^Game) -> ([]Anim, []string) {
	send(g, "down Space")
	mine, ok := anims(g, "PLAYER")
	base := ok ? mine[0] : nil
	for a in base {
		if has_prefix_any(strings.to_lower(a.name), UNGUARDED_ANIMS[:]) {
			send(g, "up Space")
			send(g, "down Space")
			break
		}
	}
	return base, strings.fields(send(g, "states PLAYER"))[2:]
}

// Holds block for n frames watching cs, then on while they chain blockable
// attacks (move: one already showing), so the block is never dropped
// between them; a block raised after an attack starts can be too late.
// Block stays held after: the caller releases Space before it attacks,
// heals or evades (fight releases it on the way out). Returns the
// unblockable attack that ended the block, else nil. WHY: docs/modding.md §5
guard :: proc(g: ^Game, cs: []Creature, n: int, move: ^Move = nil) -> ^Move {
	raise_block(g)
	move := move
	if move == nil do move = watch(g, cs, n)
	for _ in 0 ..< GUARD_CHAIN {
		if move == nil || choose(g, move^) != "block" do return move
		answered_with(g, move^, "block")
		mine, states := raise_block(g)
		fmt.printf("  block: %s, player %s [%s] hp %d\n", describe(move), anim_list(mine), strings.join(states, " "), query(g, "GetHealth(GetPlayer())"))
		nxt := watch(g, cs, FRAMES_GUARD, answered(move^))
		// A heavy swing (style 98's Attack_C) lands after FRAMES_GUARD:
		// the block stays up while the same attack still plays.
		if nxt != nil do move = nxt
		else do _, move = swing(g, cs)
	}
	return move
}

// Evades sideways from creature c: the stick pushed with block held (the
// "Both" Evade Method, see EVADE_METHOD; it starts in the frame, where the
// double tap took a dozen frames and slams landed mid-tap), at right angles
// to the line from c, where a back flip still took slams. Block stays held
// after. answer "back" evades straight away from c instead. move: the
// attack evaded, its by c. refs: see sense_refs. WHY: docs/modding.md §5
evade :: proc(g: ^Game, refs: [2]u32, move: Move, answer: string) {
	c := move.by
	answered_with(g, move, answer)
	s := sense(g, refs, c.expr)
	check(!s.loading, "evade: the player object is gone")
	side := degrees(math.atan2(s.here.y - s.there.y, s.here.x - s.there.x))
	side += answer == "side" ? 90.0 : 0.0
	send(g, "down Space")
	push_cleanup(g, .Stick)
	stick_toward(g, side, s)
	frames(g, FRAMES_FLICK)
	mine, ok := anims(g, "PLAYER")
	fmt.printf("  evade %s: heading %.0f bearing %.0f at %.1f m: %s\n", answer, side, s.bearing, hexgrid.dist(s.here, s.there), ok ? anim_list(mine[0]) : "-")
	pop_cleanup()
	frames(g, FRAMES_EVADE - FRAMES_FLICK)
}

// Steps the player with the left stick until who is in REACH, as a player
// closes on a foe; no jumps. Attacks then track the engine's lock-on
// target, so the player is not turned by script. WHY: docs/modding.md §4
close_in :: proc(g: ^Game, refs: [2]u32, who: string) {
	s := sense(g, refs, who)
	push_cleanup(g, .Stick)
	for _ in 0 ..< CLOSE_STEPS {
		if s.loading || hexgrid.dist(s.here, s.there) <= REACH do break
		stride(g, refs, s, s.there)
		s = sense(g, refs, who)
	}
	pop_cleanup()
}

// The object tagged tag nearest the player in the player's area, as (script
// expression, id in 8 hex digits as the control channel takes it). Tags
// repeat in an area (two chi shrines in j02_ruins), and the control
// channel's tag lookup takes the first. Exits when none is in the area.
// WHY: docs/modding.md §4
nearest_tagged :: proc(g: ^Game, tag: string) -> (string, string) {
	have := false
	best_mm: int
	best_o, best_id: string
	for n in 0 ..< TAG_SCAN {
		o := fmt.aprintf("GetObjectByTag(%s, %d)", tag, n)
		v, _, _ := queries(g, {fmt.aprintf("GetIsObjectValid(%s)", o), fmt.aprintf("GetArea(%s) == GetArea(GetPlayer())", o), fmt.aprintf("FloatToInt(GetDistanceBetween(GetPlayer(), %s) * 1000.0)", o), id_expr(o)})
		if v[0] == 0 do break
		if v[1] != 0 && (!have || v[2] < best_mm) {
			have, best_mm, best_o, best_id = true, v[2], o, fmt.aprintf("%08x", u32(v[3] & 0xFFFFFFFF))
		}
	}
	if !have do fail("no object tagged %s in the player's area", tag)
	return best_o, best_id
}

// World (x, y) the engine's reach test measures use of the object tag names
// (a tag, or an id from nearest_tagged) from: the usepoint control command's
// answer (a placeable's .pwk walk-to point rotated into the world, else the
// object's position). WHY: docs/modding.md §4
use_point :: proc(g: ^Game, tag: string) -> Point {
	w := strings.fields(send(g, strings.concatenate({"usepoint ", strings.trim(tag, "\"")})))
	if len(w) != 5 do fail("usepoint %s -> %s", tag, strings.join(w, " "))
	return {atof(w[1]), atof(w[2])}
}

// Debug only: jump the player to the use point of the object tagged tag.
// Play-throughs walk (see use); a jump skips the triggers and collision on
// the way. ActionJumpToObject on a placeable lands short or nowhere.
// WHY: docs/modding.md §4
jump_to_use_point :: proc(g: ^Game, tag: string) {
	p := use_point(g, tag)
	run(g, fmt.aprintf("AssignCommand(GetPlayer(), ActionJumpToLocation(Location(GetArea(GetPlayer()), Vector(%s, %s, GetPosition(GetPlayer()).z), 0.0)))", common.py_repr_float(p.x), common.py_repr_float(p.y)))
	frames(g, FRAMES_ATTACK)
}

// Debug only: jump the player to the object tagged tag, then step back and
// forth: the camera keeps its old place until the player walks.
goto_tag :: proc(g: ^Game, tag: string) {
	jump_to_use_point(g, tag)
	for k in ([?]string{"S", "W"}) {
		send(g, strings.concatenate({"down ", k}))
		frames(g, FRAMES_NUDGE)
		send(g, strings.concatenate({"up ", k}))
	}
}

// Turns the player toward the object the script expression obj names with
// the mouse, as a player does. The engine rewrites the player's facing from
// the camera every frame, so SetFacing does not hold. WHY: docs/modding.md §4
face :: proc(g: ^Game, obj: string) {
	b := peek(g, MOUSE + MOUSE_CENTER, 8)
	cx, cy := int(i32(pe.le32(b, 0))), int(i32(pe.le32(b, 4)))
	check(0 <= cx - TURN_PX && cx + TURN_PX < GUI_SIZE[0] && 0 <= cy && cy < GUI_SIZE[1], "(%d, %d)", cx, cy)
	exprs: [dynamic]string
	for o in ([?]string{"GetPlayer()", obj}) {
		for a in ([?]string{"x", "y"}) do append(&exprs, fmt.aprintf("FloatToInt(GetPosition(%s).%s * 1000.0)", o, a))
	}
	append(&exprs, "FloatToInt(GetFacing(GetPlayer()) * 1000.0)")
	d: f64
	for _ in 0 ..< TURN_STEPS {
		iv, _, _ := queries(g, exprs[:])
		px, py, ox, oy, f := f64(iv[0]) / 1000.0, f64(iv[1]) / 1000.0, f64(iv[2]) / 1000.0, f64(iv[3]) / 1000.0, f64(iv[4]) / 1000.0
		d = py_mod(degrees(math.atan2(oy - py, ox - px)) - f + 180.0, 360.0) - 180.0
		if abs(d) <= TURN_TOL do return
		send(g, fmt.aprintf("move %d %d", cx + clamp(common.py_round(-d / TURN_GAIN), -TURN_PX, TURN_PX), cy))
		frames(g, FRAMES_TURN)
	}
	fail("face: BUG still %.1f degrees off %s after %d moves", d, obj, TURN_STEPS)
}

// Uses the nearest object tagged tag (a door, chest or shrine) as a player
// does: walk to its use point with the stick (handling what triggers start
// on the way), face it, click. A click posts a use event only for the
// highlighted object, and the engine never walks the player to it outside
// cutscenes. Returns "load" when an area load ended the walk.
// WHY: docs/modding.md §4
use :: proc(g: ^Game, tag: string) -> string {
	obj, oid := nearest_tagged(g, tag)
	// A creature's use point is its centre: stop at arm's length, not in its body.
	near := query(g, fmt.aprintf("GetObjectType(%s) == %d", obj, OBJECT_TYPE_CREATURE)) != 0 ? REACH : ARRIVE
	if travel(g, use_point(g, oid), near) == "load" do return "load"
	id, _ := strconv.parse_uint(oid, 16)
	lit := false
	for _ in 0 ..< FACE_TRIES {
		face(g, obj)
		if highlighted(g) == u32(id) {
			lit = true
			break
		}
	}
	if !lit do cycle_highlight(g, tag, u32(id))
	attack(g)
	return ""
}

// Presses Next Target (Tab) until the object id oid is highlighted, as a
// player does when facing picks a nearer object. The engine ranks the
// objects within 6 m by facing angle and distance, skips any out of line of
// sight, and keeps a Tab offset into that ranking (player + 0x1238), so
// facing alone can leave another object marked. WHY: docs/modding.md §4
cycle_highlight :: proc(g: ^Game, tag: string, oid: u32) {
	seen: [dynamic]string
	for _ in 0 ..< TARGET_CANDIDATES {
		menu_key(g, "Tab")
		frames(g, FRAMES_TURN)
		h := highlighted(g)
		if h == oid do return
		append(&seen, fmt.aprintf("%08x", h))
	}
	fail("use %s: %08x not highlighted after facing and %d Tabs (saw %s)", tag, oid, TARGET_CANDIDATES, strings.join(seen[:], " "))
}

// Id of the object a click would use now (the one the game marks), or
// NO_OBJECT. A click on anything else posts no use event, so use checks
// this before clicking. WHY: docs/modding.md §4
highlighted :: proc(g: ^Game) -> u32 {
	return peek32(g, peek32(g, peek32(g, peek32(g, APP) + APP_GUI) + GUI_CURSEL) + CURSEL_OBJ)
}

// Fights until no live hostile is near and the engine is out of combat.
// Block (Space) is held while a round reads the state and released only to
// attack or heal (see fight_round): an unguarded frame lets a swing land,
// and a hit's stun lets the rest of the combo land too. Exits unless the
// game's Evade Method is "Both" (see evade). WHY: docs/modding.md §5
fight :: proc(g: ^Game, rounds: int) {
	path := join(g.game, "JadeEmpire.ini")
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do fail("%s: %v", path, err)
	if !slice.contains(common.py_splitlines(string(data)), EVADE_METHOD) do fail("fight needs %s in JadeEmpire.ini [InputOptions]", EVADE_METHOD)
	push_cleanup(g, .Fight)
	fight_rounds(g, rounds)
	pop_cleanup()
}

player_state :: proc(g: ^Game) -> Player_State {
	v, _, _ := queries(g, PLAYER_STATE[:])
	return {v[0], v[1], v[2], v[3], v[4], v[5]}
}

// The rounds of fight.
fight_rounds :: proc(g: ^Game, rounds: int) {
	calm, idle, idle_hp := 0, 0, -1
	st := Round_State{}
	refs := sense_refs(g)
	gone: map[u32]bool
	for i in 0 ..< rounds {
		s := player_state(g)
		if s.dead != 0 do fail("player died in round %d", i)
		if s.talk != 0 {
			fmt.printf("round %d: conversation or cutscene\n", i)
			send(g, "up Space")
			talk(g, TALK_STEPS, nil)
			continue
		}
		c, have := foe(g, gone)
		// A hostile that the engine has not put in combat (an ambush group not
		// yet triggered) neither fights back nor takes hits, so out of combat
		// it does not hold the fight open. WHY: docs/modding.md §4
		if have && s.combat == 0 {
			idle = c.hp == idle_hp ? idle + 1 : 0
			idle_hp = c.hp
			if idle >= CALM_ROUNDS do have = false
		}
		if !have {
			calm = s.combat != 0 ? 0 : calm + 1
			if calm == CALM_ROUNDS {
				fmt.printf("combat over after %d rounds\n", i)
				return
			}
			send(g, "up Space")
			send(g, "key Tab")
			frames(g, FRAMES_ATTACK)
			continue
		}
		calm = 0
		send(g, "down Space")
		chans, ok := anims(g, fmt.aprintf("%08x", c.id))
		if !ok {
			fmt.printf("round %d: foe %s %x left the scene\n", i, c.label, c.id)
			gone[c.id] = true
			continue
		}
		base := chans[0]
		cs: [dynamic]Creature
		append(&cs, c)
		append(&cs, ..near_foes(g, c, gone))
		_, move := swing(g, cs[:])
		mine, states := raise_block(g)
		fmt.printf("round %d hp %d/%d chi %d anim %s [%s] foe %s style %d hp %d at %.1f m anim %s, %d near%s\n", i, s.hp, s.top, s.chi, anim_list(mine), strings.join(states, " "), c.label, c.style, c.hp, f64(c.mm) / 1000.0, anim_list(base), len(cs) - 1, describe(move))
		st = fight_round(g, refs, s, cs[:], move, base, st)
	}
	fail("still fighting after %d rounds", rounds)
}

// " -> Label [UNBLOCKABLE] by ID" for a telegraphed attack, "" for nil.
describe :: proc(move: ^Move) -> string {
	if move == nil do return ""
	by := move.has_by ? fmt.aprintf(" by %x", move.by.id) : ""
	return fmt.aprintf(" -> %s%s%s", move.label, strings.repeat(" UNBLOCKABLE", max(0, move.unblockable)), by)
}

// How a foe whose base channel plays base can be attacked: "open" in a hit
// reaction or an attack's recovery, "guard" while it blocks, else "busy"
// (ready, walking, evading: it may start an attack at any frame).
// WHY: docs/modding.md §5
opening :: proc(base: []Anim) -> string {
	for a in base {
		n := strings.to_lower(a.name)
		if has_prefix_any(n, OPENING_ANIMS[:]) || strings.has_suffix(n, RECOVERY_SUFFIX) do return "open"
		if strings.has_prefix(n, GUARD_ANIM) do return "guard"
	}
	return "busy"
}

// One round against creature c = cs[0], the rest of cs the other foes near
// (see near_foes), s the player's state, base c's base channel: defend
// against a telegraphed attack, heal or block when low, else attack when c
// is open (see opening) and guard while it is not. A player mid-swing
// cannot block or evade, so attacking a foe that may start an attack is
// left until PATIENCE guarded rounds pass. Every wait watches cs, so an
// attack one starts meanwhile is defended at once. WHY: docs/modding.md §4
fight_round :: proc(g: ^Game, refs: [2]u32, s: Player_State, cs: []Creature, move: ^Move, base: []Anim, st: Round_State) -> Round_State {
	blocked, waited := st.blocked, st.waited
	move := move
	c := cs[0]
	if move == nil && f64(s.hp) < HEAL_FRACTION * f64(s.top) {
		// Out of chi, a heal does nothing; a held block keeps most hits off.
		if s.chi >= CHI_MIN {
			send(g, "up Space")
			move = hold(g, "Left_Shift", FRAMES_HEAL, cs)
			if move == nil do return st
		} else {
			move = guard(g, cs, FRAMES_BLOCK)
		}
	}
	state := opening(base)
	if move == nil && state == "busy" && waited < PATIENCE {
		move = guard(g, cs, FRAMES_GUARD)
		if move == nil do return {blocked, waited + 1}
	}
	if move == nil {
		waited = 0
		send(g, "up Space")
		close_in(g, refs, c.expr)
		// A blocking foe takes no damage from light attacks; a strong attack
		// (the style's Slam) breaks the block. So the round after light ones
		// failed is strong, but only one on one: the Slam commits the player
		// for about 1.5 s, and other foes hit meanwhile. WHY: docs/modding.md §5
		if (blocked || state == "guard") && len(cs) == 1 {
			move = attack(g, "R", cs)
			if move == nil do move = watch(g, cs, FRAMES_STRONG)
		} else {
			for _ in 0 ..< LIGHT_COMBO {
				move = attack(g, "L", cs)
				if move != nil do break
			}
		}
	}
	if move != nil {
		fmt.printf("  defend: %s\n", describe(move))
		defend(g, refs, cs, move)
		return {blocked, waited}
	}
	return {!blocked && query(g, fmt.aprintf("GetHealth(%s)", c.expr)) >= c.hp, waited}
}

// World (x, y) of the player, read to the millimetre.
position :: proc(g: ^Game) -> Point {
	x := f64(query(g, "FloatToInt(GetPosition(GetPlayer()).x * 1000.0)")) / 1000.0
	y := f64(query(g, "FloatToInt(GetPosition(GetPlayer()).y * 1000.0)")) / 1000.0
	return {x, y}
}

// The pathfinding grid of the player's area, read from guest memory.
grid :: proc(g: ^Game) -> hexgrid.Grid {
	obj, ok := strconv.parse_uint(strings.fields(send(g, "area"))[1], 16)
	if !ok do fail("area: bad object")
	header := peek(g, u32(obj) + hexgrid.AREA_GRID, hexgrid.HEADER_SIZE)
	ptr, n := hexgrid.header_cells(header)
	cells: [dynamic]u8
	for k := 0; k < n; k += PEEK_CHUNK do append(&cells, ..peek(g, ptr + u32(k), min(PEEK_CHUNK, n - k)))
	return hexgrid.parse(header, cells[:])
}

// Waypoints from here to (x, y) on gr; exits when either end is blocked or
// no route joins them.
plan :: proc(gr: hexgrid.Grid, here: Point, x, y: f64) -> [dynamic]Point {
	ends: [2]int
	for p, k in ([2]Point{here, {x, y}}) {
		name := k == 0 ? "start" : "goal"
		i := hexgrid.cell_at(gr, p)
		j := i == hexgrid.NONE ? hexgrid.NONE : hexgrid.nearest_open(gr, i, SNAP_RINGS)
		if j == hexgrid.NONE do fail("walk: %s %.1f,%.1f is off the grid or walled in", name, p.x, p.y)
		if j != i {
			c := hexgrid.center(gr, j)
			fmt.printf("walk: %s %.1f,%.1f is blocked, using %.1f,%.1f\n", name, p.x, p.y, c.x, c.y)
		}
		ends[k] = j
	}
	a, b := ends[0], ends[1]
	snapped := b != hexgrid.cell_at(gr, {x, y})
	path := hexgrid.route(gr, a, b)
	if path == nil {
		cut := hexgrid.first_blocked(gr, hexgrid.route(gr, a, b, through = true))
		c := hexgrid.center(gr, cut)
		fail("walk: no route from %s to %s; first blocked cell on the cheapest way at %.1f,%.1f (byte %#x; a closed placeable patches the live grid, see docs/modding.md §6)", point_repr(here), point_repr({x, y}), c.x, c.y, gr.cells[cut])
	}
	pts := make([dynamic]Point)
	append(&pts, ..hexgrid.waypoints(gr, path))
	if !snapped do pts[len(pts) - 1] = {x, y}
	// Both ends in one cell: the route is that cell alone. Walks index the
	// first leg from pts[1], so the start is kept as pts[0].
	if len(pts) == 1 do inject_at(&pts, 0, here)
	check(len(pts) >= 2, "%v", pts)
	parts := make([]string, len(pts))
	for p, i in pts do parts[i] = fmt.aprintf("%.1f,%.1f", p.x, p.y)
	fmt.printf("walk: %d waypoints: %s\n", len(pts), strings.join(parts, " "))
	return pts
}

is_popup :: proc(id: int) -> bool {
	for p in POPUPS do if p == id do return true
	return false
}

// Dismisses open notice popups with the attack button, as the popup asks,
// and prints which ones closed. Exits when one will not close.
close_popups :: proc(g: ^Game) {
	for _ in 0 ..< POPUPS_MAX {
		up := -1
		for i in panels(g) {
			if is_popup(i) {
				up = i
				break
			}
		}
		if up < 0 do return
		fmt.printf("popup: closing panel %#x\n", up)
		attack(g)
		frames(g, FRAMES_POPUP)
	}
	fail("popup: BUG panels %s still open", ints_repr(panels(g)))
}

// Guest addresses sense reads: the GUI panel table and the game camera.
// Both stay put within an area. WHY: docs/modding.md §6
sense_refs :: proc(g: ^Game) -> [2]u32 {
	table := panel_table(g)
	cam := peek32(g, peek32(g, peek32(g, APP) + APP_SCENE) + SCENE_CAMERA)
	check(table != 0 && cam != 0, "(%d, %d)", table, cam)
	return {table, cam}
}

// Reads a Sense in one frame (a frame per round trip lets a running player
// cover RUN_STEP metres unsteered each). other: an object expression whose
// position to read too.
sense :: proc(g: ^Game, refs: [2]u32, other := "") -> Sense {
	table, cam := refs[0], refs[1]
	exprs: [dynamic]string
	append(&exprs, ..SENSE_STATE[:])
	objs: [dynamic]string
	append(&objs, "GetPlayer()")
	if other != "" do append(&objs, other)
	for o in objs {
		for a in ([?]string{"x", "y"}) do append(&exprs, fmt.aprintf("FloatToInt(GetPosition(%s).%s * 1000.0)", o, a))
	}
	peeks := []string{fmt.aprintf("peek %x %d", table, 4 * PANEL_COUNT), fmt.aprintf("peek %x 8", cam + CAMERA_POS)}
	v, ans, gone := queries(g, exprs[:], peeks, PLAYER_GONE)
	if gone {
		// The player object is gone while an area swaps, before the loading
		// panel opens: treat it as the load it is.
		return Sense{loading = true}
	}
	n := len(SENSE_STATE)
	s: Sense
	if other != "" do s.there = {f64(v[n + 2]) / 1000.0, f64(v[n + 3]) / 1000.0}
	for k in 0 ..< n {
		if v[k] != 0 {
			s.why = SENSE_WHY[k]
			break
		}
	}
	s.here = {f64(v[n]) / 1000.0, f64(v[n + 1]) / 1000.0}
	pb := hex_bytes(strings.fields(ans[0])[1])
	check(len(pb) == 4 * PANEL_COUNT, "%d", len(pb))
	ptrs: [PANEL_COUNT]u32
	for i in 0 ..< PANEL_COUNT do ptrs[i] = pe.le32(pb, 4 * i)
	cb := hex_bytes(strings.fields(ans[1])[1])
	check(len(cb) == 8, "%d", len(cb))
	cx, cy := f64(transmute(f32)pe.le32(cb, 0)), f64(transmute(f32)pe.le32(cb, 4))
	movie := ptrs[PANEL_MOVIE]
	if movie != 0 {
		r := rect(g, movie)
		s.loading = r[2] == GUI_SIZE[0] && r[3] == GUI_SIZE[1]
	}
	s.bearing = degrees(math.atan2(s.here.y - cy, s.here.x - cx))
	open: [dynamic]int
	for p, i in ptrs do if p != 0 do append(&open, i)
	s.panels = open[:]
	return s
}

// Holds the left stick toward deg (0 = right, 90 = up).
stick :: proc(g: ^Game, deg: f64) {
	batch(g, {fmt.aprintf("axis leftx %d", common.py_round(STICK * math.cos(radians(deg)))), fmt.aprintf("axis lefty %d", common.py_round(-STICK * math.sin(radians(deg))))})
}

// Releases the left stick.
stick_off :: proc(g: ^Game) {
	batch(g, {"axis leftx 0", "axis lefty 0"})
}

// Holds the left stick so the player moves along world heading (degrees,
// 0 = +x, 90 = +y). The stick moves the player relative to the camera:
// stick up along the camera-to-player heading s.bearing, stick right 90
// degrees clockwise of it. WHY: docs/modding.md §6
stick_toward :: proc(g: ^Game, heading: f64, s: Sense) {
	stick(g, heading - s.bearing + 90.0)
}

// One walking step from s.here toward goal: the stick is held for
// FRAMES_STEP frames, fewer when goal is nearer than that covers, so the
// player stops near it. Returns the next Sense. The stick stays held.
stride :: proc(g: ^Game, refs: [2]u32, s: Sense, goal: Point) -> Sense {
	d := hexgrid.dist(s.here, goal)
	stick_toward(g, degrees(math.atan2(goal.y - s.here.y, goal.x - s.here.x)), s)
	frames(g, max(1, min(FRAMES_STEP, int(d / RUN_STEP))))
	return sense(g, refs)
}

// Walks the player to (x, y) with the left stick along a route on the
// area's pathfinding grid, as a player would; no jumps. The walk ends near
// metres (at least ARRIVE) from (x, y). Returns what stopped the walk early
// (a conversation, cutscene, combat or area load a trigger began), or ""
// on arrival; exits when stuck, which is a bug to look at.
// WHY: docs/modding.md §6
walk :: proc(g: ^Game, x, y: f64, near := ARRIVE) -> string {
	gr, refs := grid(g), sense_refs(g)
	s := sense(g, refs)
	pts := plan(gr, s.here, x, y)
	k, still, replans := 1, 0, 0
	best := math.inf_f64(1) // nearest the player has been to waypoint k
	push_cleanup(g, .Stick)
	for step in 0 ..< WALK_STEPS {
		// A transition trigger loads another area: the player object is
		// gone until the load ends, so the walk is over.
		if s.loading {
			fmt.println("walk: stopped by a load or movie")
			pop_cleanup()
			return "load"
		}
		if slice.contains(s.panels, PANEL_DEATH) do fail("walk: player died at %.2f,%.2f", s.here.x, s.here.y)
		if slice.contains(s.panels, PANEL_PAUSED) {
			fmt.println("walk: game paused, resuming with Return")
			stick_off(g)
			send(g, "key Return")
			frames(g, FRAMES_POPUP)
			s = sense(g, refs)
			continue
		}
		for i in s.panels {
			if is_popup(i) {
				stick_off(g)
				close_popups(g)
				break
			}
		}
		if s.why != "" {
			fmt.printf("walk: stopped by %s at %.2f,%.2f\n", s.why, s.here.x, s.here.y)
			pop_cleanup()
			return s.why
		}
		for _ in 0 ..< len(pts) {
			if k == len(pts) - 1 || hexgrid.dist(s.here, pts[k]) > ARRIVE do break
			k, best = k + 1, math.inf_f64(1)
		}
		if k == len(pts) - 1 && hexgrid.dist(s.here, pts[k]) <= max(ARRIVE, near) {
			fmt.printf("walk: arrived at %.2f,%.2f after %d steps\n", s.here.x, s.here.y, step)
			pop_cleanup()
			return ""
		}
		s = stride(g, refs, s, pts[k])
		if s.loading do continue // s.here is unset; the check at the loop top ends the walk
		// Progress is getting closer to the waypoint: a walk sliding along
		// a wall or circling it moves every step yet gets nowhere.
		d := hexgrid.dist(s.here, pts[k])
		if d < best - STUCK_DIST do still, best = 0, d
		else do still += 1
		if still == STUCK_STEPS {
			if replans == REPLANS do fail("walk: BUG stuck at %.2f,%.2f heading for %.2f,%.2f", s.here.x, s.here.y, pts[k].x, pts[k].y)
			gr = learn_obstacle(gr, s.here, pts[k])
			pts, k, still, replans, best = plan(gr, s.here, x, y), 1, 0, replans + 1, math.inf_f64(1)
		}
	}
	fail("walk: not there after %d steps, at %.2f,%.2f", WALK_STEPS, s.here.x, s.here.y)
}

// gr with what stopped a stuck walk from here toward goal blocked: the
// whole 0xfe band when the leg crosses a soft one (the band was a real
// wall), else a disc OBSTACLE_AHEAD along the leg (something the grid
// lacks, a body or a prop). WHY: docs/modding.md §6
learn_obstacle :: proc(gr: hexgrid.Grid, here, goal: Point) -> hexgrid.Grid {
	band := hexgrid.soft_on_leg(gr, here, goal)
	if band != hexgrid.NONE {
		hard, n := hexgrid.harden_band(gr, band, BAND_CELLS_MAX)
		c := hexgrid.center(hard, band)
		fmt.printf("walk: no progress at %.2f,%.2f; band at %.1f,%.1f is a wall, blocking %d cells and replanning\n", here.x, here.y, c.x, c.y, n)
		return hard
	}
	d := max(hexgrid.dist(here, goal), 1e-3)
	f := min(OBSTACLE_AHEAD, d) / d
	ob := Point{here.x + f * (goal.x - here.x), here.y + f * (goal.y - here.y)}
	fmt.printf("walk: no progress at %.2f,%.2f; blocking %.1f,%.1f and replanning\n", here.x, here.y, ob.x, ob.y)
	return hexgrid.block_disc(gr, ob, OBSTACLE_RADIUS)
}

// Walks to within near metres of p (see walk) and deals with whatever a
// trigger starts on the way: fight a combat, play a conversation or cutscene
// through, wait out a load (which ends the trip: the area changed), close
// popups. Returns "load" when an area load ended it, or "" on arrival.
travel :: proc(g: ^Game, p: Point, near := ARRIVE) -> string {
	for _ in 0 ..< TRAVEL_LEGS {
		why := walk(g, p.x, p.y, near)
		if why == "" do return ""
		if why == "load" {
			settle(g, SETTLE_STEPS)
			return why
		}
		if why == "combat" {
			fight(g, FIGHT_ROUNDS)
			recover(g)
		} else {
			talk(g, TALK_STEPS, nil)
		}
		close_popups(g)
	}
	fail("travel: still not at %.1f,%.1f after %d interruptions", p.x, p.y, TRAVEL_LEGS)
}

// Takes the area transition trigger tagged tag: travel to a point inside
// the trigger's outline. The trigger's position need not lie inside its
// outline (j02t_100_120's is 3 m outside), and the AREATRANS label shows on
// approach, well before the outline is entered, so neither the position nor
// where the label appears is enough. Exits unless an area load ended the
// trip. WHY: docs/modding.md §4
cross :: proc(g: ^Game, tag: string) {
	p := inner_point(trigger_outline(g, tag))
	if travel(g, p) != "load" do fail("cross: at %s (%.2f,%.2f) with no area load", tag, p.x, p.y)
}

// The outline of the trigger tagged tag as (x, y) pairs, from the polygon
// control command (the engine's own copy). WHY: docs/modding.md §4
trigger_outline :: proc(g: ^Game, tag: string) -> []Point {
	w := strings.fields(send(g, strings.concatenate({"polygon ", tag})))
	if len(w) == 0 || w[0] != "ok" do fail("polygon %s -> %s", tag, strings.join(w, " "))
	n := atoi(w[1])
	v := make([]f64, len(w) - 2)
	for t, i in w[2:] do v[i] = atof(t)
	check(len(v) == n * 3, "polygon %s: %d values for %d points", tag, len(v), n)
	out := make([]Point, n)
	for i in 0 ..< n do out[i] = {v[i * 3], v[i * 3 + 1]}
	return out
}

// A point inside polygon poly: the vertex mean when it is inside (always,
// for a convex outline), else the first inside midpoint of a vertex pair.
inner_point :: proc(poly: []Point) -> Point {
	n := len(poly)
	sx, sy: f64
	for p in poly do sx, sy = sx + p.x, sy + p.y
	mean := Point{sx / f64(n), sy / f64(n)}
	if inside(mean, poly) do return mean
	for i in 0 ..< n {
		for j in i + 2 ..< n {
			p := Point{(poly[i].x + poly[j].x) / 2, (poly[i].y + poly[j].y) / 2}
			if inside(p, poly) do return p
		}
	}
	parts := make([]string, n)
	for p, i in poly do parts[i] = point_repr(p)
	fail("cross: no inside point found for outline [%s]", strings.join(parts, ", "))
}

// Whether point p lies inside polygon poly (even-odd ray test).
inside :: proc(p: Point, poly: []Point) -> bool {
	hit := false
	for a, i in poly {
		b := poly[(i + 1) % len(poly)]
		if (a.y > p.y) != (b.y > p.y) && p.x < a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y) do hit = !hit
	}
	return hit
}

// After a fight, chi heals back to full health while chi lasts: neither
// health nor chi regenerates out of combat, so the next fight would start
// where this one ended. Warns when chi runs out first. WHY: docs/modding.md §6
recover :: proc(g: ^Game) {
	for _ in 0 ..< RECOVER_HEALS {
		v, _, _ := queries(g, {PLAYER_STATE[3], PLAYER_STATE[4], PLAYER_STATE[5]})
		hp, top, chi := v[0], v[1], v[2]
		if hp >= top do return
		if chi < CHI_MIN {
			fmt.printf("recover: LOW hp %d/%d with chi %d; find a chi shrine\n", hp, top, chi)
			return
		}
		wake_keys(g)
		hold(g, "Left_Shift", FRAMES_HEAL, nil)
	}
	fmt.printf("recover: hp still below maximum after %d heals\n", RECOVER_HEALS)
}

hex_ids :: proc(ids: []int) -> string {
	parts := make([]string, len(ids))
	for p, i in ids do parts[i] = fmt.aprintf("%#x", p)
	return strings.join(parts, " ")
}

// Waits out a movie or area load: until the loading panel closes and the
// player object exists again (it is gone for part of an area swap).
settle :: proc(g: ^Game, steps: int) {
	for i in 0 ..< steps {
		if !loading(g) {
			v, _, gone := queries(g, {"GetIsObjectValid(GetPlayer())"}, nil, PLAYER_GONE)
			if !gone && v[0] != 0 {
				fmt.printf("settle: clear after %d waits, panels %s\n", i, hex_ids(panels(g)))
				return
			}
		}
		frames(g, FRAMES_SETTLE_WAIT)
	}
	fail("settle: loading panel still open after %d waits", steps)
}

// Plays a flying minigame: holds fire and sweeps the ship from side to side
// until the minigame panel closes (won, or lost and back to a menu).
minigame :: proc(g: ^Game, steps: int) {
	if !slice.contains(panels(g), PANEL_MINIGAME) do fail("minigame: panel %#x not open", PANEL_MINIGAME)
	send(g, "btn L down")
	push_cleanup(g, .Minigame)
	for i in 0 ..< steps {
		stick(g, i % (2 * SWEEP_STEPS) < SWEEP_STEPS ? 0.0 : 180.0)
		frames(g, FRAMES_STEP)
		if ps := panels(g); !slice.contains(ps, PANEL_MINIGAME) {
			fmt.printf("minigame: over after %d steps, panels %s\n", i, ints_repr(ps))
			pop_cleanup()
			return
		}
	}
	fail("minigame: still running after %d steps", steps)
}

// The reply list on screen with click points, top first.
//
// Read from the reply panel's items, so a choice is made by its text rather
// than its position. WHY: docs/modding.md §5
replies :: proc(g: ^Game) -> []Reply {
	panel := peek32(g, panel_table(g) + 4 * PANEL_REPLY)
	if panel == 0 do return nil
	n := int(peek32(g, panel + REPLY_COUNT))
	check(n <= REPLIES_MAX, "reply count %d", n)
	pr := rect(g, panel)
	lr := rect(g, panel + LISTBOX)
	items := peek32(g, panel + REPLY_ITEMS)
	out: [dynamic]Reply
	for i in 0 ..< n {
		item := peek32(g, items + u32(4 * i))
		ir := rect(g, item)
		ix, iy, ih, lh := ir[0], ir[1], ir[3], lr[3]
		if iy >= lh {
			fmt.printf("reply %d below the visible list, skipped\n", i)
			continue
		}
		b := peek(g, item + ITEM_TEXT, 8)
		ptr, size := pe.le32(b, 0), int(pe.le32(b, 4))
		check(size <= TEXT_MAX, "reply %d text size %d", i, size)
		// An empty CExoString has no buffer: size 0 (seen while a line is set up).
		text := ""
		if size != 0 {
			raw := peek(g, ptr, size)
			if z, ok := slice.linear_search(raw, 0); ok do raw = raw[:z]
			text = utf8_replace(raw)
		}
		// A tall last item may run past the list's bottom; click its visible part.
		append(&out, Reply{text, pr[0] + lr[0] + ix + REPLY_INSET, pr[1] + lr[1] + iy + min(ih, lh - iy) / 2})
	}
	return out[:]
}

// Advances conversations and waits out cutscenes until both are over.
//
// GetIsInConversation(player) is 1 in a dialog; a cinematic without one
// only sets GetInCutsceneMode. A reply not chosen before in this run is
// taken first, after any containing a prefer or g.prefer text; when all
// have been, the last (a hub's exit). With no replies on screen a click
// skips the spoken line. WHY: docs/modding.md §4
talk :: proc(g: ^Game, steps: int, prefer: []string) {
	chosen: map[string]bool
	pref: [dynamic]string
	append(&pref, ..prefer)
	append(&pref, ..g.prefer[:])
	for i in 0 ..< steps {
		if query(g, "GetIsInConversation(GetPlayer())") != 0 {
			rs := replies(g)
			wanted, fresh := -1, -1
			for r, k in rs {
				if r.text in chosen do continue
				if fresh < 0 do fresh = k
				if wanted < 0 {
					for t in pref do if strings.contains(r.text, t) do wanted = k
				}
			}
			pick := wanted >= 0 ? wanted : fresh >= 0 ? fresh : len(rs) - 1
			if pick >= 0 {
				// The first reply equal to the pick, as list.index finds it.
				first := pick
				for r, k in rs {
					if r == rs[pick] {
						first = k
						break
					}
				}
				fmt.printf("reply %d/%d: %s\n", first + 1, len(rs), rs[pick].text)
				chosen[rs[pick].text] = true
				send(g, fmt.aprintf("click %d %d", rs[pick].x, rs[pick].y))
			} else {
				send(g, fmt.aprintf("click %d %d", TALK_CLICK[0], TALK_CLICK[1]))
			}
		} else if query(g, "GetInCutsceneMode()") == 0 {
			fmt.printf("conversation over after %d steps\n", i)
			return
		}
		frames(g, FRAMES_TALK)
	}
	fail("conversation still open after %d steps", steps)
}

// Ids of the GUI panels open now, from the GUI manager's table.
panels :: proc(g: ^Game) -> []int {
	b := peek(g, panel_table(g), 4 * PANEL_COUNT)
	out: [dynamic]int
	for i in 0 ..< PANEL_COUNT do if pe.le32(b, 4 * i) != 0 do append(&out, i)
	return out[:]
}

// Class name of open panel pid, e.g. "CGuiPanel.AREAMINIMAP", from the name
// pointer at panel + 0x1C; false if pid is not open (each read is a frame,
// so a panel listed a moment ago may have closed). WHY: docs/modding.md §5
panel_name :: proc(g: ^Game, pid: int) -> (string, bool) {
	panel := peek32(g, panel_table(g) + u32(4 * pid))
	if panel == 0 do return "", false
	raw := peek(g, peek32(g, panel + PANEL_NAME), PANEL_NAME_MAX)
	end, found := slice.linear_search(raw, 0)
	check(found && end > 0, "panel %#x: name not terminated in %d bytes", pid, PANEL_NAME_MAX)
	return common.latin1(raw[:end]), true
}

// Whether a load screen or movie is up: panel 0x41 at full GUI size. The
// save message reuses that panel as a small box over the running game.
// WHY: docs/rendering.md §3
loading :: proc(g: ^Game) -> bool {
	panel := peek32(g, panel_table(g) + 4 * PANEL_MOVIE)
	if panel == 0 do return false
	r := rect(g, panel)
	return r[2] == GUI_SIZE[0] && r[3] == GUI_SIZE[1]
}

// Why a save now would capture a transient state, or "" when idle.
busy :: proc(g: ^Game) -> string {
	if query(g, "GetIsDead(GetPlayer())") != 0 do return "player dead"
	if query(g, "GetIsInCombat()") != 0 do return "in combat"
	if query(g, "GetIsInConversation(GetPlayer())") != 0 do return "in conversation"
	if query(g, "GetInCutsceneMode()") != 0 do return "in cutscene"
	if peek32(g, panel_table(g) + 4 * PANEL_MOVIE) != 0 do return "movie or loading screen open"
	return ""
}

// Taps a keyboard shortcut (F5, J, Escape...) after moving the mouse. Once
// gamepad input is used (the stick, pad buttons), the engine ignores
// keyboard shortcuts until the mouse moves; movement keys still work.
// WHY: docs/modding.md §3
menu_key :: proc(g: ^Game, name: string) {
	wake_keys(g)
	send(g, strings.concatenate({"key ", name}))
}

// Moves the mouse so the engine takes keyboard shortcuts again (see
// menu_key). WHY: docs/modding.md §3
wake_keys :: proc(g: ^Game) {
	for p in WAKE_POINTS do send(g, fmt.aprintf("move %d %d", p[0], p[1]))
}

mtime_ns :: proc(path: string) -> (i64, bool) {
	fi, err := os.stat(path, context.allocator)
	if err != nil do return 0, false
	return fi.modification_time._nsec, true
}

// Quick saves after clearing what test commands queued.
//
// A command such as AssignCommand(npc, ActionMoveToObject(...)) leaves an
// action in that object's queue, and a save stores queues: one left on the
// then-inactive dragon in the Spirit Cave stalled its conversation after the
// next load. WHY: docs/modding.md §4
save :: proc(g: ^Game) {
	if why := busy(g); why != "" do fail("not saving: %s", why)
	tags := touched(g)
	for t in tags {
		if query(g, fmt.aprintf(`GetIsObjectValid(GetObjectByTag("%s", 0))`, t)) == 0 {
			fmt.printf("ledger tag %s: no such object here, skipped\n", t)
			continue
		}
		run(g, fmt.aprintf(`AssignCommand(GetObjectByTag("%s", 0), ClearAllActions())`, t))
	}
	run(g, "AssignCommand(GetPlayer(), ClearAllActions())")
	frames(g, FRAMES_SETTLE)
	path := join(g.game, SAVE_FILE)
	before, _ := mtime_ns(path)
	menu_key(g, "F5")
	frames(g, FRAMES_SAVE)
	if after, ok := mtime_ns(path); !ok || after == before do fail("quick save not written: %s", path)
	if len(tags) > 0 {
		if err := os.remove(join(g.ctl, LEDGER)); err != nil do fail("%s: %v", LEDGER, err)
	}
	fmt.printf("saved; cleared %d ledger objects and the player\n", len(tags))
}

slot_name :: proc(i: int) -> string {
	return fmt.aprintf("zz_c%02d", i)
}

slot_path :: proc(game: string, i: int) -> string {
	return join(join(game, "override"), strings.concatenate({slot_name(i), ".ncs"}))
}

// Writes a placeholder into every missing slot; the game sees them after a restart.
init_slots :: proc(game: string) {
	code := ncs.assemble(SLOT_INIT)
	made := 0
	for i in 0 ..< SLOTS {
		p := slot_path(game, i)
		if !os.exists(p) {
			write_file(p, code)
			made += 1
		}
	}
	fmt.printf("created %d of %d slots; restart the game if it is running\n", made, SLOTS)
}

main :: proc() {
	if len(os.args) < 4 do fail("%s", USAGE)
	if os.args[3] == "init" && len(os.args) == 4 {
		init_slots(os.args[2])
		return
	}
	g := game_new(os.args[1], os.args[2])
	cmd := os.args[3]
	a: [dynamic]string
	append(&a, ..os.args[4:])
	for {
		k := -1
		for s, i in a[:max(0, len(a) - 1)] {
			if s == "--reply" {
				k = i
				break
			}
		}
		if k < 0 do break
		append(&g.prefer, a[k + 1])
		remove_range(&a, k, k + 2)
	}
	n := 0
	if (cmd == "talk" || cmd == "fight") && len(a) > 0 do n = atoi(a[0])
	tag := len(a) > 0 ? fmt.aprintf(`"%s"`, a[0]) : "" // an NWScript string literal; tags hold no quotes
	switch {
	case cmd == "query" && len(a) == 1:
		b: [dynamic]u8
		if ncs.expr(&b, ncs.parse_expr(a[0])) == "String" do fmt.println(query_str(g, a[0]))
		else do fmt.println(query(g, a[0]))
	case cmd == "do" && len(a) == 1:
		touch(g, a[0])
		run(g, a[0])
	case cmd == "goto" && len(a) == 1:
		goto_tag(g, tag)
	case cmd == "use" && len(a) == 1:
		use(g, tag)
	case cmd == "face" && len(a) == 1:
		obj, _ := nearest_tagged(g, tag)
		face(g, obj)
	case cmd == "ask" && len(a) == 1:
		// The player's own ActionStartConversation does nothing: the engine runs
		// actions that move the player only inside cutscenes and conversations
		// (as with walk-to-use); the NPC's starts it. WHY: docs/modding.md §4
		src := fmt.aprintf("AssignCommand(GetObjectByTag(%s, 0), ActionStartConversation(GetPlayer()))", tag)
		touch(g, src)
		run(g, src)
	case cmd == "talk":
		talk(g, n != 0 ? n : TALK_STEPS, len(a) > 0 ? a[1:] : nil)
	case cmd == "fight" && len(a) <= 1:
		fight(g, n != 0 ? n : 60)
	case cmd == "walk" && len(a) == 2:
		walk(g, atof(a[0]), atof(a[1]))
	case cmd == "walkto" && len(a) == 1:
		_, id := nearest_tagged(g, tag)
		p := use_point(g, id)
		walk(g, p.x, p.y)
	case cmd == "travel" && len(a) == 2:
		travel(g, {atof(a[0]), atof(a[1])})
	case cmd == "cross" && len(a) == 1:
		cross(g, a[0])
	case cmd == "settle" && len(a) == 0:
		settle(g, SETTLE_STEPS)
	case cmd == "minigame" && len(a) <= 1:
		minigame(g, len(a) > 0 ? atoi(a[0]) : MINIGAME_STEPS)
	case cmd == "popups" && len(a) == 0:
		close_popups(g)
	case cmd == "panels" && len(a) == 0:
		for i in panels(g) {
			name, ok := panel_name(g, i)
			fmt.printf("%#x %s\n", i, ok ? name : "(closed since listed)")
		}
	case cmd == "anims" && len(a) <= 1:
		ref := len(a) > 0 ? a[0] : "PLAYER"
		chans, ok := anims(g, ref)
		if !ok do fail("anims: %s has no creature model", ref)
		for name, k in ([?]string{"base", "head", "weapon"}) {
			parts := make([]string, len(chans[k]))
			for r, i in chans[k] do parts[i] = fmt.aprintf("%s@%.2f x%.2f %x", r.name, r.time, r.speed, r.flags)
			fmt.println(name, strings.join(parts, " "))
		}
	case cmd == "recover" && len(a) == 0:
		recover(g)
	case cmd == "pos" && len(a) == 0:
		p := position(g)
		fmt.printf("%.3f %.3f\n", p.x, p.y)
	case cmd == "save" && len(a) == 0:
		save(g)
	case:
		fail("%s", USAGE)
	}
}
