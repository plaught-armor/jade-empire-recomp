// The main menu (CPanelMainMenu), condensed into two submenus: the top
// level is Singleplayer, Online, Options, Game Credits and Exit;
// Singleplayer holds New Game, Load Game and Play Mini-games, Online holds
// Host Online Game and Join Online Game when playing alone and Leave Online
// Game in an online game, each with a Back row (B goes back too). The panel
// is built once with the top level's five buttons; a level change relabels
// them and refills the list box with as many as the level has, the next
// frame, outside the button's own event. The online rows open a lobby here
// in the menu (win32 net.odin): hosting opens the game to a peer joining,
// joining asks for the host's address in the menu's help line (win32
// join_edit). Play starts for both at the host's New Game or Load Game: the
// joining peer takes the host's saves, settings and game options and
// activates the same row, and lockstep runs on both from the next Present.
// The lobby's news shows in the help line. A failed online game starts over
// alone with its reason (JE_NET_ERROR), shown once in the help line. The
// new rows' strings are appended to dialog.tlk (win32 tlk_extra). Online,
// the menu runs on player 1's inputs on both peers, and so does the level.
// WHY: docs/hle.md §11
package native

import "core:fmt"
import "core:strconv"
import "core:strings"
import "../win32"
import "../x86"

guest_menu_list: x86.Func
guest_menu_activate: x86.Func
guest_menu_focus: x86.Func
guest_menu_update: x86.Func
guest_menu_back: x86.Func

MENU_LIST :: 0x0076cc64 // the rows: count, capacity, ^{strref, desc strref}
MENU_DEMO :: 0x0076c590 // the demo's menu, left as it is
MENU_HELP :: 0xda8 // the panel's help line
MENU_LISTBOX :: 0x2c4 // the panel's list box of row buttons
MENU_ROWS_MAX :: 5 // the top level's rows: the buttons the panel builds
MENU_ROW_H :: 0x19 // a row's height in the list box, as the panel sets it
MENU_SHOWN :: 0x3d8 // f32, 1 once the panel is in and takes rows
MENU_ACTIVATE :: 0x0056a570 // thiscall (button, n), ret 8
MENU_FOCUS_SAVED :: 0xed44 // in the client (0x0076c924): the row focused at the panel's build
CLIENT :: 0x0076c924
LB_COUNT :: 0x4f0
LB_CONTROLS :: 0x4f8
LB_FLAGS :: 0x514 // bit 0: the list box frees its controls when cleared
LB_RECT :: 4 // x, y, w, h
LB_ADD :: 0x00523c40 // thiscall AddControls(^{count, cap, ^ctl}, own, rects, p4, unique), ret 0x14
LB_SELECT :: 0x00523a40 // thiscall (index, sound), ret 8
BUTTON_LABEL :: 0x28c // a row button's label text
BUTTON_STRREF :: 0x298 // the label's strref
STRREF_SET :: 0x005292f0 // thiscall text (strref), ret 4
NET_PORT_DEFAULT :: "47000"

// Label and description pairs.
Online_Str :: enum u8 {Host, Host_Desc, Join, Join_Desc, Leave, Leave_Desc, Single, Single_Desc, Online, Online_Desc, Back, Back_Desc}

ONLINE_STRS := [Online_Str]string {
	.Host       = "Host Online Game",
	.Host_Desc  = "Play this game online with a friend: they join here, then start a new game or load one and play starts for both. They can also join later, while you play. The address they join goes in the window title and on the clipboard. The router's port is opened by UPnP when it allows.",
	.Join       = "Join Online Game",
	.Join_Desc  = "Join a friend's online game by the address their window title shows, as player 2. Play starts when they start a new game or load one; in a game they already play, it starts at once.",
	.Leave      = "Leave Online Game",
	.Leave_Desc = "Close the online game and play alone; in play, the game starts over. A host's address to join is in the window title.",
	.Single      = "Singleplayer",
	.Single_Desc = "Play alone: start a new game, load a saved one, or play the mini-games.",
	.Online      = "Online",
	.Online_Desc = "Play with a friend over the internet: host an online game or join theirs, or leave the one being played.",
	.Back        = "Back",
	.Back_Desc   = "Back to the main menu.",
}

Menu_Level :: enum u8 {Top, Single, Online}
Menu_Row :: struct {label, desc: u32}

// The guest's own rows: New Game, Load Game, Play Mini-games, Options, Game
// Credits, Exit.
@(private = "file")
menu_stock: [6]Menu_Row
// The panel's row buttons, from its first level change.
@(private = "file")
menu_buttons: [MENU_ROWS_MAX]u32
@(private = "file")
menu_level: Menu_Level
// A level change waiting for the next frame.
@(private = "file")
menu_next: Maybe(Menu_Level)

JOIN_HINT :: "Type or paste the address (d-pad up/down picks letters, X erases, Y pastes). Enter or A joins, Esc or B goes back."

// The online strings' first index in win32 tlk_extra.
@(private = "file")
online_first: int

// JE_NET_ERROR: why the last online game ended, until shown and left; the
// row button it shows on.
menu_error: string
@(private = "file")
menu_error_at: u32

// After settings_load, which sets tlk_extra: appends the online rows' strings.
menu_online_init :: proc() {
	online_first = len(win32.tlk_extra)
	strs := make([]string, online_first + len(Online_Str))
	copy(strs, win32.tlk_extra)
	for s, i in ONLINE_STRS {strs[online_first + int(i)] = s}
	win32.tlk_extra = strs
}

@(private = "file")
strref :: proc(s: Online_Str) -> u32 {
	if win32.tlk_base == 0 {x86.fatal("menu: the main menu opened before %s was read", win32.TLK_NAME)}
	return win32.tlk_base + u32(online_first) + u32(s)
}

// The port's row with label strref ref.
@(private = "file")
online_row :: proc(ref: u32) -> (Online_Str, bool) {
	for s in ([]Online_Str{.Host, .Join, .Leave, .Single, .Online, .Back}) {
		if ref == strref(s) {return s, true}
	}
	return {}, false
}

// Builds the menu's rows, plain ret: the top level's in place of the guest's.
Menu_List_0056acd0 :: proc() {
	guest_menu_list()
	if ld(MENU_DEMO) != 0 {return}
	if ld(MENU_LIST) != len(menu_stock) {x86.fatal("menu: %d main menu rows, expected %d", ld(MENU_LIST), len(menu_stock))}
	p := ld(MENU_LIST + 8)
	for &r, i in menu_stock {r = {ld(p + u32(i) * 8), ld(p + u32(i) * 8 + 4)}}
	menu_level = .Top
	menu_next = nil
	menu_buttons = {}
	menu_list_set(.Top)
}

// A level's rows into MENU_LIST; their count.
@(private = "file")
menu_list_set :: proc(level: Menu_Level) -> int {
	own :: proc(s: Online_Str) -> Menu_Row {return {strref(s), strref(Online_Str(u8(s) + 1))}}
	rows: []Menu_Row
	switch level {
	case .Top:
		rows = {own(.Single), own(.Online), menu_stock[3], menu_stock[4], menu_stock[5]}
	case .Single:
		rows = {menu_stock[0], menu_stock[1], menu_stock[2], own(.Back)}
	case .Online:
		rows = win32.net_on || win32.net_lobby ? {own(.Leave), own(.Back)} : {own(.Host), own(.Join), own(.Back)}
	}
	if int(ld(MENU_LIST + 4)) < len(rows) {x86.fatal("menu: the main menu's row list holds %d, not %d", ld(MENU_LIST + 4), len(rows))}
	p := ld(MENU_LIST + 8)
	for r, i in rows {
		st(p + u32(i) * 8, r.label)
		st(p + u32(i) * 8 + 4, r.desc)
	}
	st(MENU_LIST, u32(len(rows)))
	return len(rows)
}

// Shows menu_next: the rows relabelled, the list box refilled with the
// level's buttons and the first row focused, or on going back the row that
// led to the submenu.
@(private = "file")
menu_level_show :: proc(this: u32) {
	from := menu_level
	menu_level = menu_next.?
	menu_next = nil
	lb := this + MENU_LISTBOX
	if menu_buttons[0] == 0 {
		if ld(lb + LB_COUNT) != MENU_ROWS_MAX {x86.fatal("menu: %d main menu buttons, expected %d", ld(lb + LB_COUNT), MENU_ROWS_MAX)}
		for &b, i in menu_buttons {b = ld(ld(lb + LB_CONTROLS) + u32(i) * 4)}
	}
	n := u32(menu_list_set(menu_level))
	p := ld(MENU_LIST + 8)
	esp := x86.cpu.esp
	arr := esp - 0x40 // {count, capacity, ^buttons}, the buttons, then the rect
	ctl := arr + 0xc
	rect := ctl + MENU_ROWS_MAX * 4
	st(arr, n)
	st(arr + 4, n)
	st(arr + 8, ctl)
	x86.cpu.esp = arr - 0x10
	for i in 0 ..< n {
		b := menu_buttons[i]
		st(ctl + i * 4, b)
		thiscall(STRREF_SET, b + BUTTON_LABEL, ld(p + i * 8))
	}
	// The focused row's button unfocused first: clearing the list box does
	// not, and it would stay lit. The list box frees the buttons it owns when
	// cleared: the hidden ones are kept for the next level.
	thiscall(LB_SELECT, lb, ~u32(0), 0)
	st(lb + LB_FLAGS, ld(lb + LB_FLAGS) &~ 1)
	thiscall(LB_ADD, lb, arr, 1, 0, 0, 1)
	for i in u32(0) ..< 4 {st(rect + i * 4, ld(lb + LB_RECT + i * 4))}
	st(rect + 0xc, n * MENU_ROW_H)
	thiscall(ld(ld(lb) + 4), lb, rect)
	focus := u32(0)
	if menu_level == .Top {focus = from == .Online ? 1 : 0}
	thiscall(LB_SELECT, lb, focus, 0)
	x86.cpu.esp = esp
}

// A row activated, thiscall(button, n), ret 8: the online rows' own. While
// the address editor is open no row acts.
Menu_Activate_0056a570 :: proc() {
	c := &x86.cpu
	this, button, n := c.ecx, ld(c.esp + 4), i32(ld(c.esp + 8))
	if win32.join_edit.state == .Open {
		c.esp += 12
		return
	}
	if n > 0 || n < -1 {
		ref := ld(button + BUTTON_STRREF)
		if r, ok := online_row(ref); ok {
			saved := x86.cpu
			online_activate(this, r)
			x86.cpu = saved
			c.esp += 12
			return
		}
		if !win32.lockstep && !win32.net_on && (ref == menu_stock[0].label || ref == menu_stock[1].label) {
			row := u8(ref == menu_stock[0].label ? 0 : 1)
			if win32.net_lobby && win32.net_slot != 0 {
				saved := x86.cpu
				menu_say(this, "the host starts play")
				x86.cpu = saved
				c.esp += 12
				return
			}
			if win32.net_lobby {
				saved := x86.cpu
				win32.net_host_start(row, settings_vals(), sync_opts(), coop_hero_pick())
				x86.cpu = saved
			} else if win32.lock_solo {
				win32.lock_pending = true
			}
		}
	}
	guest_menu_activate()
}

@(private = "file")
online_activate :: proc(this: u32, r: Online_Str) {
	#partial switch r {
	case .Single:
		menu_next = .Single
	case .Online:
		menu_next = .Online
	case .Back:
		menu_next = .Top
	case .Host:
		port, ok := strconv.parse_int(ini_port(), 10)
		if !ok || port <= 0 || port > 0xffff {
			menu_say(this, fmt.tprintf("NET_PORT %s is no port", ini_port()))
			return
		}
		if err := win32.net_host_open(port); err != "" {
			menu_say(this, err)
			return
		}
		win32.net_menu = true
		menu_next = .Online
	case .Join:
		addr := win32.join_clipboard()
		if addr == "" {
			if t, ok := win32.ini_get(win32.ini_load(SETTINGS_INI), SETTINGS_SECTION, "NET_JOIN"); ok {addr = t}
		}
		win32.join_edit_open(addr)
		join_show(this)
	case .Leave:
		if win32.net_lobby {
			win32.net_lobby_close()
			menu_next = .Online
			return
		}
		if win32.net_slot == 0 {win32.relaunch(true)}
		win32.relaunch(true, "JE_NET_ERROR=the host ended the online game")
	}
}

// [Port] NET_PORT, or NET_PORT_DEFAULT.
@(private = "file")
ini_port :: proc() -> string {
	if t, ok := win32.ini_get(win32.ini_load(SETTINGS_INI), SETTINGS_SECTION, "NET_PORT"); ok && t != "" {return t}
	return NET_PORT_DEFAULT
}

@(private = "file")
join_show :: proc(this: u32) {
	text_set(this + MENU_HELP, fmt.tprintf("Join at: %s\n%s", win32.join_edit_shown(), JOIN_HINT))
}

// A frame of the menu, thiscall(?), ret 4: shows the lobby's news and a
// level change, starts play on the joining peer and drives the address
// editor.
Menu_Update_00569d50 :: proc() {
	this := x86.cpu.ecx
	guest_menu_update()
	if msg, ended, ok := win32.net_news_take(); ok {
		saved := x86.cpu
		menu_say(this, msg)
		x86.cpu = saved
		if ended && menu_level == .Online {menu_next = .Online}
	}
	if win32.net_start_row >= 0 && !win32.net_on && transmute(f32)ld(this + MENU_SHOWN) == 1 {
		saved := x86.cpu
		join_start(this)
		x86.cpu = saved
	}
	if menu_next != nil {
		saved := x86.cpu
		menu_level_show(this)
		x86.cpu = saved
	}
	if win32.join_edit.state == .Closed {return}
	saved := x86.cpu
	defer x86.cpu = saved
	state, changed := win32.join_edit_tick()
	switch state {
	case .Closed:
	case .Open:
		if changed {join_show(this)}
	case .Done:
		addr := win32.join_edit_address()
		if addr == "" {
			join_cancel(this)
			return
		}
		if strings.index_byte(addr, ':') < 0 {addr = fmt.tprintf("%s:%s", addr, ini_port())}
		if !win32.ini_write(SETTINGS_INI, SETTINGS_SECTION, "NET_JOIN", addr) {
			fmt.eprintfln("menu: cannot write NET_JOIN to %s", SETTINGS_INI)
		}
		win32.join_edit_close()
		if err := win32.net_join_open(addr, coop_hero_pick()); err != "" {
			menu_say(this, err)
			return
		}
		win32.net_menu = true
		menu_say(this, "waiting for the host")
		menu_next = .Online
	case .Cancelled:
		join_cancel(this)
	}
}

// On the joining peer at the host's start: the host's saves, settings and
// game options taken, and its row activated as the host's was, through the
// first row button relabelled for it.
@(private = "file")
join_start :: proc(this: u32) {
	row := win32.net_start_row
	win32.net_start_row = -1
	win32.net_join_start()
	settings_sync(win32.net_settings)
	sync_opts_apply(win32.net_opts)
	b := menu_buttons[0]
	if b == 0 {b = ld(ld(this + MENU_LISTBOX + LB_CONTROLS))}
	ref := ld(b + BUTTON_STRREF)
	st(b + BUTTON_STRREF, menu_stock[row].label)
	thiscall(MENU_ACTIVATE, this, b, 1)
	st(b + BUTTON_STRREF, ref)
	st(ld(CLIENT) + MENU_FOCUS_SAVED, u32(row))
}

// msg in the help line until a second row is focused.
@(private = "file")
menu_say :: proc(this: u32, msg: string) {
	delete(menu_error)
	menu_error, menu_error_at = strings.clone(msg), 0
	text_set(this + MENU_HELP, fmt.tprintf("Online: %s", menu_error))
}

@(private = "file")
join_cancel :: proc(this: u32) {
	win32.join_edit_close()
	thiscall(STRREF_SET, this + MENU_HELP, strref(.Join_Desc))
}

// A row focused, thiscall(button, n), ret 8: the help line shows the
// address editor while it is open, and the last online game's end until a
// second row is focused.
Menu_Focus_0056a020 :: proc() {
	c := &x86.cpu
	this, button, n := c.ecx, ld(c.esp + 4), i32(ld(c.esp + 8))
	guest_menu_focus()
	if win32.net_on || n <= 0 {return}
	saved := x86.cpu
	defer x86.cpu = saved
	if win32.join_edit.state == .Open {
		join_show(this)
		return
	}
	if menu_error == "" {return}
	if menu_error_at == 0 {menu_error_at = button}
	if button != menu_error_at {
		menu_error = ""
		return
	}
	text_set(this + MENU_HELP, fmt.tprintf("Online: %s", menu_error))
}

// A row's B, thiscall(button, n), ret 8: in a submenu, back to the top
// level in place of the quit dialog.
Menu_Back_00569f60 :: proc() {
	c := &x86.cpu
	n := i32(ld(c.esp + 8))
	if menu_level == .Top || !(n > 0 || n < -1) {
		guest_menu_back()
		return
	}
	if win32.join_edit.state != .Open {menu_next = .Top}
	c.esp += 12
}

@(private = "file")
thiscall :: proc(fn, this: u32, args: ..u32) -> u32 {
	x86.cpu.ecx = this
	return win32.guest_call(fn, ..args)
}
