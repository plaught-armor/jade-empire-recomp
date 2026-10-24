// The port's settings, as rows of the game's Video Settings panel
// (CPanelCustomVideo) below its own nine, and the pad's of its Control panel
// (CPanelOptionsCont) below its own five. Each setting is read at startup
// from JadeEmpire.ini, section [Port], then from the environment as
// JE_<key>, which wins. The panels' rows come from strref tables the
// generator points at SETTINGS_ROWS and CONTROL_ROWS (docs/recompiler.md
// §9); the port's rows carry strrefs appended to dialog.tlk (win32
// tlk_extra). Left and right change a row's pending value, Accept puts the
// panel's pending values in force and writes every setting to the ini,
// Cancel drops them. JE_NATIVE has no effect here.
// WHY: docs/recompiler.md §11
package native

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "../win32"
import "../x86"

guest_video_ctor: x86.Func
guest_video_prev: x86.Func
guest_video_next: x86.Func
guest_video_select: x86.Func
guest_video_defaults: x86.Func
guest_video_apply: x86.Func
guest_cont_ctor: x86.Func
guest_cont_prev: x86.Func
guest_cont_next: x86.Func
guest_cont_defaults: x86.Func
guest_cont_accept: x86.Func

// The Video panel's settings come first, then the Control panel's from
// CONTROL_FIRST.

Setting_Id :: enum u8 {
	Fps,
	Menu_Fps,
	Scale,
	Smaa,
	Sharpen,
	Vibrance,
	Ssao,
	Draw,
	Soft,
	Ppl,
	Bloom,
	Shadow,
	Aniso,
	Hd_Tex,
	Fullscreen,
	Intro,
	Reverb,
	Blend,
	Blend_Ms,
	Turn, // CONTROL_FIRST
	Stick_Dz,
	Flick,
	Camera,
	Aim,
	Buffer,
	Ai,
	Parry,
	Pace,
	Hit_Stop,
	Magnet,
	Coop,
	P2_Hero,
}

// One value of a setting and the text its row shows.
Opt :: struct {
	val:  i32,
	name: string,
}

Setting :: struct {
	key:   string, // [Port] key; JE_<key> in the environment
	label: string,
	desc:  string,
	opts:  []Opt, // nil: Off 0, On 1
	def:   i32,
}

SETTINGS := [Setting_Id]Setting {
	.Fps = {
		"FPS", "Frame Rate",
		"Highest frame rate. Changes to or from 30 apply after a restart.",
		{{30, "30"}, {60, "60"}, {90, "90"}, {120, "120"}, {144, "144"}, {165, "165"}, {240, "240"}, {0, "Unlimited"}},
		30,
	},
	.Menu_Fps = {
		"MENU_FPS", "Menu Frame Rate",
		"Highest frame rate in menus, when Frame Rate is above 30.",
		{{30, "30"}, {60, "60"}, {120, "120"}, {0, "Same as game"}},
		win32.MENU_FPS_DEFAULT,
	},
	.Scale = {
		"SCALE", "Render Scale",
		"Renders at this multiple of the resolution. Applies after a restart.",
		{{0, "Auto"}, {1, "1x"}, {2, "2x"}, {3, "3x"}, {4, "4x"}},
		0,
	},
	.Smaa = {"SMAA", "SMAA", "Anti-aliasing of the finished image.", nil, 1},
	.Sharpen = {
		"SHARPEN", "Sharpening",
		"Contrast-adaptive sharpening of the finished image.",
		{{0, "Off"}, {1, "Low"}, {2, "Medium"}, {3, "High"}},
		1,
	},
	.Vibrance = {
		"VIBRANCE", "Vibrance",
		"Richer muted colours. Off keeps the original colours.",
		{{0, "Off"}, {1, "Low"}, {2, "Medium"}, {3, "High"}},
		0,
	},
	.Ssao = {
		"SSAO", "Ambient Occlusion",
		"Darkens creases, corners and contact points.",
		{{0, "Off"}, {1, "Low"}, {2, "Medium"}, {3, "High"}},
		2,
	},
	.Draw = {
		"DRAW", "Draw Distance",
		"How far away creatures, grass and animation detail stay visible.",
		{{100, "Original"}, {150, "Far"}, {200, "Very Far"}, {300, "Extreme"}},
		200,
	},
	.Soft = {"SOFT", "Soft Particles", "Smoke, fire and sparks fade where they meet walls and floors.", nil, 1},
	.Ppl = {"PPL", "Per-Pixel Lighting", "Lights shade each pixel instead of each vertex. Off keeps the original lighting.", nil, 1},
	.Bloom = {"BLOOM", "Bloom", "Smooth glow around bright light. Off keeps the original glow.", nil, 1},
	.Shadow = {"SHADOW", "Shadow Maps", "Creature shadows from a shadow map, with soft edges. Off keeps the original shadows.", nil, 1},
	.Aniso = {
		"ANISO", "Anisotropic Filtering",
		"Keeps textures sharp at glancing angles.",
		{{1, "Off"}, {2, "2x"}, {4, "4x"}, {8, "8x"}, {16, "16x"}},
		16,
	},
	.Hd_Tex = {"HDTEX", "HD Textures", "Upscaled textures from textures_hd, where present. Applies after a restart.", nil, 1},
	.Fullscreen = {"FULLSCREEN", "Fullscreen", "Borderless fullscreen. Alt+Enter also switches it.", nil, 0},
	.Intro = {"INTRO", "Intro Movies", "Logos and opening movie at launch. Applies after a restart.", nil, 0},
	.Reverb = {
		"REVERB", "Reverb",
		"Echo of the place a sound is heard in. Original is the game's level.",
		{{0, "Off"}, {1, "Low"}, {2, "Original"}, {3, "High"}},
		2,
	},
	.Blend = {
		"BLEND", "Animation Blending",
		"Eases animation changes over the blend time. Off keeps the original.",
		nil, 1,
	},
	.Blend_Ms = {
		"BLEND_MS", "Blend Time",
		"Shortest blend between two animations with Animation Blending on.",
		{{60, "60 ms"}, {90, "90 ms"}, {120, "120 ms"}, {160, "160 ms"}, {200, "200 ms"}, {250, "250 ms"}},
		BLEND_MS_DEFAULT,
	},
	.Turn = {
		"TURN", "Turn to Run",
		"Out of combat, turn toward the stick and run instead of strafing.",
		nil, 1,
	},
	.Stick_Dz = {
		"STICK_DZ", "Stick Deadzone",
		"How far a stick moves before it registers. Original ignores most of it.",
		{{-1, "Original"}, {0, "0%"}, {4, "4%"}, {8, "8%"}, {12, "12%"}, {16, "16%"}, {20, "20%"}, {25, "25%"}, {30, "30%"}},
		win32.PAD_STICK_DZ_DEFAULT,
	},
	.Flick = {
		"FLICK", "Target Flick",
		"In combat, flick the right stick left or right to switch target.",
		nil, 1,
	},
	.Camera = {
		"CAMERA", "Free Camera",
		"Out of combat, the right stick turns and tilts the camera.",
		nil, 1,
	},
	.Aim = {
		"AIM", "Aimed Targeting",
		"In combat, a new target is picked toward the stick or the view, not only the nearest.",
		nil, 1,
	},
	.Buffer = {
		"BUFFER", "Input Buffer",
		"In combat, an attack pressed a little early is kept and plays when the last one allows.",
		nil, 1,
	},
	.Ai = {
		"AI", "Enemy AI",
		"Foes fight by their rank: fodder blocks now and then, soldiers and arena fighters dodge and punish, assassins, bosses and Death's Hand break guards and read baits. Each foe has its own temperament, shifts it as it tires and as it reads your habits, and only a few press you at once. Original is the game as shipped. Skilled caps the best at middle rank.",
		{{0, "Original"}, {1, "Skilled"}, {2, "Master"}},
		2,
	},
	.Parry = {
		"PARRY", "Parry",
		"A block raised just before a foe's blow lands staggers the attacker.",
		nil, 1,
	},
	.Pace = {
		"PACE", "Combat Pace",
		"How fast your attacks play and recover. Original is the game as shipped.",
		{{0, "Original"}, {1, "Quick"}, {2, "Fast"}},
		1,
	},
	.Hit_Stop = {
		"HIT_STOP", "Hit Stop",
		"A blow that lands holds the action for an instant, longer for a power attack.",
		nil, 1,
	},
	.Magnet = {
		"MAGNET", "Attack Magnetism",
		"Attacks close in on your target. Reach and angle grow with mastery of the style in use.",
		nil, 1,
	},
	.Coop = {
		"COOP", "Co-op",
		"A second pad plays your follower: stick to move, A quick attack, X power attack, B dodge, right trigger block.",
		nil, 0,
	},
	.P2_Hero = {
		"P2_HERO", "Player 2's Hero",
		"The hero player 2 plays. Online, the pick of the one who joins; a saved game with player 2 in keeps its hero until the pick changes.",
		{{0, "Blossom"}, {1, "Ming"}, {2, "Shen"}, {3, "Jen Zi"}, {4, "Ling"}, {5, "Prodigy"}, {6, "Tan"}},
		0,
	},
}

// Values in force, and the panel's pending ones while it is open.
setting_val: [Setting_Id]i32
setting_edit: [Setting_Id]i32

// The game's 30 fps limit (ClampFPS) is read once, at boot; kept then, a
// frame rate change waits for a restart.
@(private = "file")
fps_clamped: bool

@(private = "file")
REVERB_GAINS := [?]f32{0, 0.5, 1, 2}

SETTINGS_INI :: "JadeEmpire.ini"
SETTINGS_SECTION :: "Port"

// CPanelCustomVideo. Its rows' label strrefs, the game's nine then the
// port's, at a guest address the generator's patches point at; nothing else
// uses the page. VIDEO_ROWS_N is the row count the patches give the panel.
SETTINGS_ROWS :: 0x00a00000
VIDEO_ROWS_GAME :: 0x0075b868 // the game's table, nine strrefs
VIDEO_ROWS_GAME_N :: 9
VIDEO_ROWS_N :: 28
CONTROL_FIRST :: Setting_Id.Turn
VIDEO_N :: int(CONTROL_FIRST)
CONTROL_N :: len(Setting_Id) - VIDEO_N
#assert(VIDEO_ROWS_GAME_N + VIDEO_N == VIDEO_ROWS_N)

VIDEO_LABELS :: 0xdc // list control of the row labels
VIDEO_MANAGER :: 0x28 // GUI manager
WIDGET_PARENT :: 0x28 // the control holding the widget
VIDEO_BUTTONS :: [?]u32{0x1144, 0x1408, 0x16cc} // Accept, Cancel, Default
VIDEO_VALUE_OF :: 0x0054d810 // thiscall(row), ret 4: the row's value widget
VIDEO_ROW_OF :: 0x0054d4a0 // thiscall(label widget), ret 4: its row, -1 if none
LIST_ITEM :: 0x00521bd0 // thiscall(index), ret 4
LIST_SEL :: 0x51e // i16 selected index, -1 for none
VT_LIST :: 0x10 // control's list
VT_ITEM_WIDGET :: 0x48
VT_MANAGER_HELP :: 0x0 // the manager's help area
HELP_SET :: 0x00560520 // thiscall(strref), ret 4
WIDGET_TEXT :: 0x28c // the widget's text
TEXT_SET :: 0x00529280 // thiscall(^CExoString), ret 4
EXOSTR_INIT :: 0x006534b0 // thiscall ^CExoString, (^char), ret 4
EXOSTR_FREE :: 0x005a1a50 // thiscall ^CExoString
// CPanelOptionsCont. Its rows, 16 bytes each {strref, default, min, max},
// and their description strrefs, the game's five then the port's, on the
// same page; the generator's patches size the panel to CONTROL_ROWS_N.
CONTROL_ROWS :: 0x00a00100
CONTROL_DESCS :: 0x00a00280
CONTROL_ROWS_GAME :: 0x00703448
CONTROL_DESCS_GAME :: 0x006ff1fc
CONTROL_ROWS_GAME_N :: 5
CONTROL_ROWS_N :: 18
CONTROL_ROW_SIZE :: 16
#assert(CONTROL_ROWS_GAME_N + CONTROL_N == CONTROL_ROWS_N)
#assert(CONTROL_ROWS + CONTROL_ROWS_N * CONTROL_ROW_SIZE <= CONTROL_DESCS)

CONT_FOCUS :: 0x2c // the control with focus
CONT_VALUES :: 0x2c4 // list control of the row values
CONT_LABELS :: 0x810 // list control of the row labels
VT_ITEM_VALUE :: 0x40 // a value item's text widget
VALUE_TEXT :: 0x1b8
ARG_CLICK :: 0x0075b528 // a handler's argument when an arrow is clicked

SCRATCH :: 0x400 // below the live stack: a CExoString and its text
SCRATCH_TEXT_MAX :: 0x100

// Reads every setting; before boot, after the working directory is the
// game's. Also hands win32 the rows' strings. settings_boot puts them in
// force.
settings_load :: proc() {
	lines := win32.ini_load(SETTINGS_INI)
	for s, id in SETTINGS {
		v := s.def
		if t, ok := win32.ini_get(lines, SETTINGS_SECTION, s.key); ok {
			if n, nok := strconv.parse_int(t, 10); nok {v = i32(n)}
		}
		if t := os.get_env(fmt.tprintf("JE_%s", s.key), context.temp_allocator); t != "" {
			if n, nok := strconv.parse_int(t, 10); nok {v = i32(n)}
		}
		setting_val[id] = v
	}
	// JE_STICK=0, the older switch, keeps the game's deadzone.
	if os.get_env("JE_STICK", context.temp_allocator) == "0" {setting_val[.Stick_Dz] = -1}
	strs := make([]string, 2 * len(Setting_Id))
	for s, id in SETTINGS {
		strs[2 * int(id)], strs[2 * int(id) + 1] = s.label, s.desc
	}
	win32.tlk_extra = strs
}

// Puts every setting in force; before boot, once an online game's joining
// peer has the host's (settings_sync).
settings_boot :: proc() {
	for id in Setting_Id {setting_apply(id, true)}
	win32.ctl_set = setting_set
}

// ctl's set: the setting with [Port] key key, in force at v until exit.
@(private = "file")
setting_set :: proc(key: string, v: i32) -> bool {
	for s, id in SETTINGS {
		if s.key != key {continue}
		setting_val[id] = v
		setting_apply(id, false)
		return true
	}
	return false
}

// The settings that change the game rather than only its look: an online
// game's joining peer takes the host's (win32/net_save.odin).
SETTINGS_LOOK :: bit_set[Setting_Id]{.Fps, .Menu_Fps, .Scale, .Smaa, .Sharpen, .Vibrance, .Ssao, .Soft, .Ppl, .Bloom, .Shadow, .Aniso, .Fullscreen, .Reverb}

// Every setting's value, in Setting_Id order, for the host to send.
settings_vals :: proc() -> []i32 {
	return slice.enumerated_array(&setting_val)
}

// On an online game's joining peer before settings_boot: vals, the host's
// settings_vals, in place of ours for every setting that changes the game.
// Player 2's hero stays ours, the pick our hello carried.
settings_sync :: proc(vals: []i32) {
	if len(vals) != len(Setting_Id) {x86.fatal("net: the host sent %d settings, not %d", len(vals), len(Setting_Id))}
	for id in Setting_Id {
		if id in SETTINGS_LOOK || id == .P2_Hero || setting_val[id] == vals[int(id)] {continue}
		fmt.eprintfln("net: %s %d, the host's (ours %d)", SETTINGS[id].key, vals[int(id)], setting_val[id])
		setting_val[id] = vals[int(id)]
	}
}

// Puts setting_val[id] in force; at boot, also what only boot can set.
@(private = "file")
setting_apply :: proc(id: Setting_Id, boot: bool) {
	v := setting_val[id]
	switch id {
	case .Fps:
		// Lockstep runs at its own fixed rate (win32/lockstep.odin).
		if win32.lockstep {v = win32.LOCK_RATE}
		if boot {
			fps_clamped = v == 30
			if !fps_clamped {win32.ini_override("Game", "ClampFPS", "0")}
		}
		if !fps_clamped {win32.fps_cap = u32(max(v, 0))}
	case .Menu_Fps:
		win32.menu_fps_cap = u32(max(v, 0))
	case .Scale:
		if boot {win32.rt_scale_req = u32(max(v, 0))}
	case .Smaa:
		win32.smaa_on = v != 0
	case .Sharpen:
		win32.cas_sharp = u32(clamp(v, 0, 3))
	case .Vibrance:
		win32.cas_vibrance = u32(clamp(v, 0, 3))
	case .Ssao:
		win32.ssao_level = u32(clamp(v, 0, 3))
	case .Draw:
		draw_scale = f32(clamp(v, 100, 400)) / 100
		draw_apply()
	case .Soft:
		win32.soft_on = v != 0
	case .Ppl:
		win32.ppl_on = v != 0
	case .Bloom:
		win32.bloom_on = v != 0
	case .Shadow:
		win32.shadow_on = v != 0
	case .Aniso:
		win32.aniso_force = u32(max(v, 1))
	case .Hd_Tex:
		if boot {win32.tex_hd_req = v != 0}
	case .Fullscreen:
		win32.fullscreen_set(v != 0)
	case .Intro:
		// NoLogos alone skips the boot logo and movie sequence (0x551240);
		// NoMovies would also stop every in-game movie (0x6801b0).
		if boot && v == 0 {win32.ini_override("Render", "NoLogos", "1")}
	case .Reverb:
		// Low and High are 6 dB under and over the game's level.
		win32.rvb_gain = REVERB_GAINS[clamp(v, 0, len(REVERB_GAINS) - 1)]
	case .Blend:
		blend_on = v != 0
	case .Blend_Ms:
		blend_min = f32(clamp(v, 0, 1000)) / 1000
	case .Turn:
		turn_on = v != 0
	case .Stick_Dz:
		win32.stick_radial, stick_on = v >= 0, v >= 0
		if v >= 0 {win32.stick_dz = f32(min(v, 50)) / 100}
	case .Flick:
		flick_on = v != 0
	case .Camera:
		cam_on = v != 0
	case .Aim:
		aim_on = v != 0
	case .Buffer:
		buffer_on = v != 0
	case .Parry:
		parry_on = v != 0
	case .Pace:
		pace_level = clamp(v, 0, len(PACES) - 1)
	case .Hit_Stop:
		hit_stop_on = v != 0
	case .Magnet:
		magnet_on = v != 0
	case .Coop:
		// Online, player 2 is the peer that joined.
		coop_on = v != 0 || win32.net_on
	case .P2_Hero:
		// Online, a pick takes at the next join (win32 net_hero_switch).
		if !boot && !win32.net_on {coop_hero_next = int(clamp(v, 0, len(HEROES) - 1))}
	case .Ai:
		ai_tier = clamp(v, 0, 2)
	}
}

// The text a row shows for v.
@(private = "file")
setting_name :: proc(id: Setting_Id, v: i32) -> string {
	opts := SETTINGS[id].opts
	if opts == nil {
		switch v {
		case 0:
			return "Off"
		case 1:
			return "On"
		}
	}
	for o in opts {
		if o.val == v {return o.name}
	}
	return fmt.tprintf("%d", v)
}

// The value after (step 1) or before (step -1) v, stopping at the ends. A
// value off the list moves to the first listed one.
@(private = "file")
setting_step :: proc(id: Setting_Id, v: i32, step: int) -> i32 {
	opts := SETTINGS[id].opts
	if opts == nil {return step > 0 ? 1 : 0}
	for o, i in opts {
		if o.val == v {return opts[clamp(i + step, 0, len(opts) - 1)].val}
	}
	return opts[0].val
}

// The setting on a panel row, if the row is the port's.
@(private = "file")
row_setting :: proc(row: u32) -> (Setting_Id, bool) {
	if row < VIDEO_ROWS_GAME_N || row >= VIDEO_ROWS_N {return {}, false}
	return Setting_Id(row - VIDEO_ROWS_GAME_N), true
}

// thiscall(obj) through its vtable slot.
@(private = "file")
vcall :: proc(obj, slot: u32, args: ..u32) -> u32 {
	x86.cpu.ecx = obj
	return win32.guest_call(ld(ld(obj) + slot), ..args)
}

@(private = "file")
thiscall :: proc(fn, this: u32, args: ..u32) -> u32 {
	x86.cpu.ecx = this
	return win32.guest_call(fn, ..args)
}

// The panel row selected in the list control list, or -1.
@(private = "file")
selected_row :: proc(this, list: u32) -> u32 {
	if list == 0 {return max(u32)}
	sel := i16(ld16(list + LIST_SEL))
	if sel < 0 {return max(u32)}
	item := thiscall(LIST_ITEM, this + VIDEO_LABELS, u32(i32(sel)))
	return thiscall(VIDEO_ROW_OF, this, vcall(item, VT_ITEM_WIDGET))
}

// Shows a row's pending value in its value widget.
@(private = "file")
row_show :: proc(this: u32, id: Setting_Id) {
	w := thiscall(VIDEO_VALUE_OF, this, VIDEO_ROWS_GAME_N + u32(id))
	if w == 0 {return}
	text_set(w + WIDGET_TEXT, setting_name(id, setting_edit[id]))
}

// Sets a widget's text to s through a CExoString below the live stack.
text_set :: proc(text_of: u32, s: string) {
	s := s
	if len(s) >= SCRATCH_TEXT_MAX {s = s[:SCRATCH_TEXT_MAX - 1]}
	esp := x86.cpu.esp
	text := esp - SCRATCH
	str := text - 0x20 // CExoString
	copy(x86.mem[text:][:len(s)], s)
	st8(text + u32(len(s)), 0)
	x86.cpu.esp = str - 0x10
	thiscall(EXOSTR_INIT, str, text)
	thiscall(TEXT_SET, text_of, str)
	thiscall(EXOSTR_FREE, str)
	x86.cpu.esp = esp
}

@(private = "file")
rows_show :: proc(this: u32) {
	for i in 0 ..< VIDEO_N {row_show(this, Setting_Id(i))}
}

// Ctor, thiscall(?), ret 4: builds the panel's rows from SETTINGS_ROWS. The
// port's rows open on the values in force.
Video_Ctor_0054e890 :: proc() {
	if win32.tlk_base == 0 {x86.fatal("settings: the video panel opened before %s was read", win32.TLK_NAME)}
	for i in u32(0) ..< VIDEO_ROWS_GAME_N {st(SETTINGS_ROWS + i * 4, ld(VIDEO_ROWS_GAME + i * 4))}
	for i in u32(0) ..< u32(VIDEO_N) {
		st(SETTINGS_ROWS + (VIDEO_ROWS_GAME_N + i) * 4, win32.tlk_base + 2 * i)
	}
	setting_val[.Fullscreen] = i32(win32.fullscreen()) // Alt+Enter may have switched it
	edit_open(0, VIDEO_N)
	this := x86.cpu.ecx
	guest_video_ctor()
	saved := x86.cpu
	rows_show(this)
	x86.cpu = saved
}

// Left on a row, thiscall(control, dir -1), ret 8. The game's own rows end
// at 7; the port's step back.
Video_Prev_0054db10 :: proc() {
	video_step(guest_video_prev, max(u32), -1)
}

// Right on a row, thiscall(control, dir 1), ret 8.
Video_Next_0054dee0 :: proc() {
	video_step(guest_video_next, 1, 1)
}

@(private = "file")
video_step :: proc(guest: x86.Func, dir: u32, step: int) {
	c := &x86.cpu
	this, control, d := c.ecx, ld(c.esp + 0x4), ld(c.esp + 0x8)
	guest()
	if d != dir {return}
	saved := x86.cpu
	defer x86.cpu = saved
	id, ok := row_setting(selected_row(this, vcall(control, VT_LIST)))
	if !ok {return}
	setting_edit[id] = setting_step(id, setting_edit[id], step)
	row_show(this, id)
}

// Selection, thiscall(widget, ?), ret 8: shows the selected row's help text.
Video_Select_0054e2a0 :: proc() {
	c := &x86.cpu
	this, w := c.ecx, ld(c.esp + 0x4)
	guest_video_select()
	for b in VIDEO_BUTTONS {
		if w == this + b {return}
	}
	saved := x86.cpu
	defer x86.cpu = saved
	id, ok := row_setting(selected_row(this, vcall(ld(w + WIDGET_PARENT), VT_LIST)))
	if !ok {return}
	thiscall(HELP_SET, vcall(ld(this + VIDEO_MANAGER), VT_MANAGER_HELP), win32.tlk_base + 2 * u32(id) + 1)
}

// Default, thiscall(keep aspect), ret 4: the port's rows go back to their
// defaults too, pending until Accept.
Video_Defaults_0054d880 :: proc() {
	this := x86.cpu.ecx
	guest_video_defaults()
	saved := x86.cpu
	edit_defaults(0, VIDEO_N)
	rows_show(this)
	x86.cpu = saved
}

// Accept, thiscall(?, ?), ret 8: the pending values go in force and to the
// ini before the game applies its own.
Video_Apply_0054d570 :: proc() {
	edit_commit(0, VIDEO_N)
	guest_video_apply()
}

// The pending values of settings first ..< first + n start as those in force.
@(private = "file")
edit_open :: proc(first, n: int) {
	for i in first ..< first + n {setting_edit[Setting_Id(i)] = setting_val[Setting_Id(i)]}
}

@(private = "file")
edit_defaults :: proc(first, n: int) {
	for i in first ..< first + n {setting_edit[Setting_Id(i)] = SETTINGS[Setting_Id(i)].def}
}

// Puts the changed pending values of settings first ..< first + n in force,
// then writes every setting to the ini.
@(private = "file")
edit_commit :: proc(first, n: int) {
	for i in first ..< first + n {
		id := Setting_Id(i)
		if setting_edit[id] == setting_val[id] {continue}
		setting_val[id] = setting_edit[id]
		setting_apply(id, false)
	}
	for s, id in SETTINGS {
		if !win32.ini_write(SETTINGS_INI, SETTINGS_SECTION, s.key, fmt.tprintf("%d", setting_val[id])) {
			fmt.eprintfln("settings: cannot write %s", SETTINGS_INI)
			break
		}
	}
}

// Shows a Control panel row's pending value in its value widget.
@(private = "file")
cont_show :: proc(this: u32, id: Setting_Id) {
	row := CONTROL_ROWS_GAME_N + u32(int(id) - VIDEO_N)
	item := thiscall(LIST_ITEM, this + CONT_VALUES, row)
	if item == 0 {return}
	text_set(vcall(item, VT_ITEM_VALUE) + VALUE_TEXT, setting_name(id, setting_edit[id]))
}

@(private = "file")
cont_rows_show :: proc(this: u32) {
	for i in VIDEO_N ..< VIDEO_N + CONTROL_N {cont_show(this, Setting_Id(i))}
}

// Control panel ctor, thiscall(?): builds the panel's rows from CONTROL_ROWS
// and their descriptions from CONTROL_DESCS. The game's own rows show blank
// values past its five; the port's are filled in after.
Cont_Ctor_00573a10 :: proc() {
	if win32.tlk_base == 0 {x86.fatal("settings: the control panel opened before %s was read", win32.TLK_NAME)}
	for i in u32(0) ..< CONTROL_ROWS_GAME_N {
		for k in u32(0) ..< CONTROL_ROW_SIZE / 4 {
			st(CONTROL_ROWS + i * CONTROL_ROW_SIZE + k * 4, ld(CONTROL_ROWS_GAME + i * CONTROL_ROW_SIZE + k * 4))
		}
		st(CONTROL_DESCS + i * 4, ld(CONTROL_DESCS_GAME + i * 4))
	}
	for i in u32(0) ..< u32(CONTROL_N) {
		id := u32(VIDEO_N) + i
		r := CONTROL_ROWS + (CONTROL_ROWS_GAME_N + i) * CONTROL_ROW_SIZE
		st(r, win32.tlk_base + 2 * id)
		for k in u32(1) ..< CONTROL_ROW_SIZE / 4 {st(r + k * 4, 0)}
		st(CONTROL_DESCS + (CONTROL_ROWS_GAME_N + i) * 4, win32.tlk_base + 2 * id + 1)
	}
	edit_open(VIDEO_N, CONTROL_N)
	this := x86.cpu.ecx
	guest_cont_ctor()
	saved := x86.cpu
	cont_rows_show(this)
	x86.cpu = saved
}

// Left on a row, thiscall(control, dir -1 or ARG_CLICK), ret 8. The game
// steps its own five rows and blanks any other's value; the port's step
// back and show again.
Cont_Prev_00570390 :: proc() {
	cont_step(guest_cont_prev, max(u32), -1)
}

// Right on a row, thiscall(control, dir 1 or ARG_CLICK), ret 8.
Cont_Next_005704c0 :: proc() {
	cont_step(guest_cont_next, 1, 1)
}

@(private = "file")
cont_step :: proc(guest: x86.Func, dir: u32, step: int) {
	c := &x86.cpu
	this, d := c.ecx, ld(c.esp + 0x8)
	guest()
	if d != dir && d != ARG_CLICK {return}
	if ld(this + CONT_FOCUS) != this + CONT_LABELS {return}
	row := i32(i16(ld16(this + CONT_LABELS + LIST_SEL)))
	if row < CONTROL_ROWS_GAME_N || row >= CONTROL_ROWS_N {return}
	saved := x86.cpu
	defer x86.cpu = saved
	id := Setting_Id(VIDEO_N + int(row) - CONTROL_ROWS_GAME_N)
	setting_edit[id] = setting_step(id, setting_edit[id], step)
	cont_show(this, id)
}

// Default, thiscall(?, 1 or ARG_CLICK), ret 8: the port's rows go back to
// their defaults too, pending until Accept.
Cont_Defaults_00570650 :: proc() {
	c := &x86.cpu
	this, d := c.ecx, ld(c.esp + 0x8)
	guest_cont_defaults()
	if d != 1 && d != ARG_CLICK {return}
	saved := x86.cpu
	edit_defaults(VIDEO_N, CONTROL_N)
	cont_rows_show(this)
	x86.cpu = saved
}

// Accept, thiscall(?, 1 or ARG_CLICK), ret 8: the pending values go in force
// and to the ini before the game applies its own.
Cont_Accept_00570050 :: proc() {
	if d := ld(x86.cpu.esp + 0x8); d == 1 || d == ARG_CLICK {edit_commit(VIDEO_N, CONTROL_N)}
	guest_cont_accept()
}
