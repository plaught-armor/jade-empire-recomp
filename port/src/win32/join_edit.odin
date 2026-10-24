// The main menu's join address editor (native/menu_online.odin): while it
// is open the keyboard and player 1's pad edit the address instead of
// steering the game. The keyboard types, Left and Right move, Backspace and
// Delete erase, Ctrl+V pastes, Enter joins and Escape cancels. On the pad
// the d-pad's up and down step the character at the cursor through
// JOIN_CHARS (past the end they add one), left and right move, X erases, Y
// pastes, A or Start joins and B cancels. Never under lockstep.
// WHY: docs/hle.md §11
package win32

import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

JOIN_CHARS :: "0123456789.:abcdefghijklmnopqrstuvwxyz-"
JOIN_MAX :: 64
// A d-pad direction held repeats after JOIN_REPEAT_FIRST, then every
// JOIN_REPEAT.
JOIN_REPEAT_FIRST :: 350 * time.Millisecond
JOIN_REPEAT :: 70 * time.Millisecond

// Pad_Input.buttons bits: PAD_BUTTONS' order, then PAD_DPAD's.
JOIN_A :: 1 << 0
JOIN_B :: 1 << 1
JOIN_X :: 1 << 2
JOIN_Y :: 1 << 3
JOIN_START :: 1 << 7
JOIN_UP :: 1 << 10
JOIN_DOWN :: 1 << 11
JOIN_LEFT :: 1 << 12
JOIN_RIGHT :: 1 << 13
JOIN_DPAD :: JOIN_UP | JOIN_DOWN | JOIN_LEFT | JOIN_RIGHT

Join_Edit_State :: enum {Closed, Open, Done, Cancelled}

Join_Edit :: struct {
	state:   Join_Edit_State,
	text:    [JOIN_MAX]u8,
	n:       int,
	cur:     int, // 0 ..= n
	held:    u16, // pad buttons down at the last tick
	since:   time.Tick, // when the d-pad direction held went down or last repeated
	first:   bool, // that direction has not repeated yet
	changed: bool, // text or cursor moved since join_edit_tick last said
	hold:    bool, // the game sees the pad released until its buttons are up
}

join_edit: Join_Edit

// Opens the editor on text; the pad buttons already down (the press that
// opened it) count as held.
join_edit_open :: proc(text: string) {
	join_edit = {state = .Open, held = pad_sample(pad).buttons, hold = true, changed = true}
	join_insert(text)
}

join_edit_close :: proc() {
	join_edit.state = .Closed
}

// The address typed so far.
join_edit_address :: proc() -> string {
	return string(join_edit.text[:join_edit.n])
}

// The address with the cursor: the character under it in brackets, or a
// trailing underscore.
join_edit_shown :: proc() -> string {
	e := &join_edit
	if e.cur == e.n {return strings.concatenate({string(e.text[:e.n]), "_"}, context.temp_allocator)}
	return strings.concatenate({string(e.text[:e.cur]), "[", string(e.text[e.cur:e.cur + 1]), "]", string(e.text[e.cur + 1:e.n])}, context.temp_allocator)
}

// Whether the game sees player 1's pad, now in_, released.
join_edit_holds :: proc(in_: Pad_Input) -> bool {
	e := &join_edit
	if e.hold && e.state != .Open && in_.buttons == 0 {e.hold = false}
	return e.hold
}

// A frame of the pad: the state after it, and whether the text or cursor
// moved since the last call.
join_edit_tick :: proc() -> (state: Join_Edit_State, changed: bool) {
	e := &join_edit
	if e.state == .Open {
		b := pad_sample(pad).buttons
		down := b & ~e.held
		if b & JOIN_DPAD != e.held & JOIN_DPAD {
			e.since, e.first = time.tick_now(), true
		} else if b & JOIN_DPAD != 0 && time.tick_since(e.since) >= (e.first ? JOIN_REPEAT_FIRST : JOIN_REPEAT) {
			e.since, e.first = time.tick_now(), false
			down |= b & JOIN_DPAD
		}
		e.held = b
		join_pad(down)
	}
	changed, e.changed = e.changed, false
	return e.state, changed
}

@(private = "file")
join_pad :: proc(down: u16) {
	e := &join_edit
	switch {
	case down & (JOIN_A | JOIN_START) != 0: e.state = .Done
	case down & JOIN_B != 0: e.state = .Cancelled
	case down & JOIN_X != 0: join_erase(e.cur < e.n ? e.cur : e.cur - 1)
	case down & JOIN_Y != 0: join_paste()
	case down & JOIN_UP != 0: join_step(1)
	case down & JOIN_DOWN != 0: join_step(-1)
	case down & JOIN_LEFT != 0: join_move(-1)
	case down & JOIN_RIGHT != 0: join_move(1)
	}
}

// A key from the window while the editor is open; every key stops here.
join_edit_key :: proc(k: sdl.KeyboardEvent) {
	if !k.down {return}
	ctrl := k.mod & {.LCTRL, .RCTRL} != {}
	e := &join_edit
	#partial switch k.scancode {
	case .RETURN, .KP_ENTER: e.state = .Done
	case .ESCAPE: e.state = .Cancelled
	case .BACKSPACE: join_erase(e.cur - 1)
	case .DELETE: join_erase(e.cur)
	case .LEFT: join_move(-1)
	case .RIGHT: join_move(1)
	case .HOME: join_move(-e.cur)
	case .END: join_move(e.n - e.cur)
	case .V: if ctrl {join_paste()}
	}
}

// Text the window typed while the editor is open.
join_edit_text :: proc(s: string) {
	join_insert(s)
}

// Puts in at the cursor the characters of s JOIN_CHARS has, lower case.
@(private = "file")
join_insert :: proc(s: string) {
	e := &join_edit
	for r in s {
		c := r >= 'A' && r <= 'Z' ? r + ('a' - 'A') : r
		if e.n >= JOIN_MAX {break}
		if r >= 0x80 || strings.index_byte(JOIN_CHARS, u8(c)) < 0 {continue}
		copy(e.text[e.cur + 1:e.n + 1], e.text[e.cur:e.n])
		e.text[e.cur] = u8(c)
		e.n += 1
		e.cur += 1
		e.changed = true
	}
}

@(private = "file")
join_erase :: proc(at: int) {
	e := &join_edit
	if at < 0 || at >= e.n {return}
	copy(e.text[at:e.n - 1], e.text[at + 1:e.n])
	e.n -= 1
	if e.cur > at {e.cur -= 1}
	e.changed = true
}

@(private = "file")
join_move :: proc(d: int) {
	e := &join_edit
	e.cur = clamp(e.cur + d, 0, e.n)
	e.changed = true
}

// The character at the cursor d steps on through JOIN_CHARS; at the end, a
// new one, the first or the last.
@(private = "file")
join_step :: proc(d: int) {
	e := &join_edit
	chars := JOIN_CHARS
	if e.cur == e.n {
		if e.n >= JOIN_MAX {return}
		e.text[e.n] = chars[d > 0 ? 0 : len(JOIN_CHARS) - 1]
		e.n += 1
	} else {
		i := strings.index_byte(JOIN_CHARS, e.text[e.cur])
		e.text[e.cur] = chars[(i + d + len(JOIN_CHARS)) % len(JOIN_CHARS)]
	}
	e.changed = true
}

// The clipboard in place of the text.
@(private = "file")
join_paste :: proc() {
	t := sdl.GetClipboardText()
	if t == nil {return}
	defer sdl.free(t)
	join_edit.n, join_edit.cur = 0, 0
	join_insert(strings.trim_space(string(cstring(t))))
	join_edit.changed = true
}

// The clipboard, when it holds only an address's characters, or "".
join_clipboard :: proc() -> string {
	t := sdl.GetClipboardText()
	if t == nil {return ""}
	defer sdl.free(t)
	s := strings.trim_space(string(cstring(t)))
	if len(s) == 0 || len(s) > JOIN_MAX {return ""}
	for c in transmute([]u8)s {
		l := c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c
		if strings.index_byte(JOIN_CHARS, l) < 0 {return ""}
	}
	return strings.clone(s, context.temp_allocator)
}
