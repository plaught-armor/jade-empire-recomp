// dialog.tlk with the connected pad's button names and the port's own
// strings. The game names controller buttons through strrefs 130700..130713
// (table 0x75cf90), and a few lines name 360 buttons in their text. When the
// pad's names differ from the 360's (pad_names), or the port has strings of
// its own (tlk_extra), CreateFileA hands the game a copy of dialog.tlk: the
// rewritten entries point at strings appended to the copy, and tlk_extra
// takes new strrefs from tlk_base on.
// WHY: docs/hle.md §5, docs/recompiler.md §11
package win32

import "base:builtin"
import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strings"
import "../x86"

TLK_NAME :: "dialog.tlk"
TLK_COUNT :: 0x0c // u32 entry count
TLK_ENTRIES :: 0x10 // u32 file offset of the entry table
TLK_STRINGS :: 0x14 // u32 file offset of the string data, the table's end
TLK_ENTRY :: 10 // u32 sound, u32 string offset (from the file start), u16 length

// A line to rewrite: its English original, and the text with {A}..{Start}
// standing for the pad's name of that 360 button.
Tlk_Line :: struct {
	ref:  u32,
	orig: string,
	text: string,
}
TLK_LINES := [?]Tlk_Line {
	{130700, "A", "{A}"},
	{130701, "B", "{B}"},
	{130703, "X", "{X}"},
	{130704, "Y", "{Y}"},
	{130706, "Left Button", "{LB}"},
	{130707, "Right Button", "{RB}"},
	{130708, "Left Trigger", "{LT}"},
	{130709, "Right Trigger", "{RT}"},
	{130710, "Left Stick", "{LS}"},
	{130711, "Right Stick", "{RS}"},
	{130712, "Back", "{Back}"},
	{130713, "Start", "{Start}"},
	{370, "LT:Prev - D-pad:Move Cursor - B:Cancel - RT:Next", "{LT}:Prev - D-pad:Move Cursor - {B}:Cancel - {RT}:Next"},
	{11567, "Press A to equip or unequip a gem.", "Press {A} to equip or unequip a gem."},
	{24433,
	 "Hold down the B button and move the left thumbstick to evade attacks in combat.",
	 "Hold down the {B} button and move the left thumbstick to evade attacks in combat."},
	{117112,
	 "Harmonic combo primed: switch to Legendary Strike and press (X button). This moves costs 5 Chi.",
	 "Harmonic combo primed: switch to Legendary Strike and press ({X} button). This moves costs 5 Chi."},
}

// Strings appended as strrefs tlk_base.., set before boot. tlk_base is the
// file's own entry count, known once the game opens it.
tlk_extra: []string
tlk_base: u32

// The rewritten copy for a guest open of dialog.tlk at host path, or nil to
// open the file itself. The copy is an unlinked temporary file.
tlk_open :: proc(path: string) -> ^os.File {
	if !strings.has_suffix(strings.to_lower(path, context.temp_allocator), TLK_NAME) {return nil}
	pad_open_first()
	names, own := pad_names()
	if !own && len(tlk_extra) == 0 {return nil}
	d, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return nil}
	n, _ := endian.get_u32(d[TLK_COUNT:], .Little)
	table, _ := endian.get_u32(d[TLK_ENTRIES:], .Little)
	data, _ := endian.get_u32(d[TLK_STRINGS:], .Little)
	if table + n * TLK_ENTRY != data || int(data) > len(d) {x86.fatal("tlk: %s layout not understood", TLK_NAME)}
	tlk_base = n
	// The new entries go at the table's end; the string data moves up by
	// them and every offset into it with it.
	grow := u32(len(tlk_extra) * TLK_ENTRY)
	out := make([dynamic]u8, 0, len(d) + int(grow) + 8192, context.temp_allocator)
	append(&out, ..d[:data])
	builtin.resize(&out, int(data + grow)) // win32 has a resize of its own
	append(&out, ..d[data:])
	endian.put_u32(out[TLK_COUNT:], .Little, n + u32(len(tlk_extra)))
	endian.put_u32(out[TLK_STRINGS:], .Little, data + grow)
	for i in 0 ..< n {
		e := table + i * TLK_ENTRY
		if at, _ := endian.get_u32(d[e + 4:], .Little); at >= data {endian.put_u32(out[e + 4:], .Little, at + grow)}
	}
	for l in TLK_LINES {
		if !own {break}
		e := int(table + l.ref * TLK_ENTRY)
		if l.ref >= n || e + TLK_ENTRY > len(d) {x86.fatal("tlk: strref %d outside %s", l.ref, TLK_NAME)}
		at, _ := endian.get_u32(d[e + 4:], .Little)
		k, _ := endian.get_u16(d[e + 8:], .Little)
		if int(at) + int(k) > len(d) || string(d[at:][:k]) != l.orig {
			fmt.eprintfln("tlk: strref %d is not \"%s\", left as is", l.ref, l.orig)
			continue
		}
		s := l.text
		for b in Pad_Btn {
			s, _ = strings.replace_all(s, fmt.tprintf("{{%v}}", b), names[b], context.temp_allocator)
		}
		endian.put_u32(out[e + 4:], .Little, u32(len(out)))
		endian.put_u16(out[e + 8:], .Little, u16(len(s)))
		append(&out, s)
	}
	for s, i in tlk_extra {
		e := data + u32(i) * TLK_ENTRY
		endian.put_u32(out[e:], .Little, max(u32))
		endian.put_u32(out[e + 4:], .Little, u32(len(out)))
		endian.put_u16(out[e + 8:], .Little, u16(len(s)))
		append(&out, s)
	}
	f, terr := os.create_temp_file("", "je-dialog-*.tlk")
	if terr != nil {x86.fatal("tlk: temp file: %v", terr)}
	_ = os.remove(os.name(f))
	if _, werr := os.write(f, out[:]); werr != nil {x86.fatal("tlk: write: %v", werr)}
	if own {fmt.eprintfln("tlk: button names %s, %s, %s, %s", names[.A], names[.B], names[.X], names[.Y])}
	if len(tlk_extra) > 0 {fmt.eprintfln("tlk: %d port strings from strref %d", len(tlk_extra), tlk_base)}
	return f
}
