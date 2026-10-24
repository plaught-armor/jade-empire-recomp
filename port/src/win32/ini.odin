// Private profile (.ini) services. Edits from outside the game are seen, as
// on Windows: the parsed file is reused only while its size and modification
// time are unchanged (the game reads a key every frame, so the check is one
// stat call, ini_stamp: os.stat opens the file and resolves its full path).
package win32

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "../x86"

INI := [?]Hle_Entry {
	{"kernel32.dll!GetPrivateProfileStringA", GetPrivateProfileStringA},
	{"kernel32.dll!GetPrivateProfileIntA", GetPrivateProfileIntA},
	{"kernel32.dll!WritePrivateProfileStringA", WritePrivateProfileStringA},
}

Ini_Line :: struct {
	section: string, // section the line belongs to; "" before the first
	key:     string, // "" for headers, comments and blank lines
	value:   string,
	text:    string, // original line
}

// The last file parsed, heap-allocated; lines slice data.
Ini_Cache :: struct {
	path:  string,
	stamp: Ini_Stamp,
	data:  []u8,
	lines: [dynamic]Ini_Line,
}

ini_cache: Ini_Cache

// Lines of the file, valid until the next ini_load or ini_forget; empty when
// it does not exist.
ini_load :: proc(path: string) -> []Ini_Line {
	stamp, ok := ini_stamp(path)
	if !ok {
		ini_forget()
		return nil
	}
	c := &ini_cache
	if c.path == path && c.stamp == stamp {
		return c.lines[:]
	}
	ini_forget()
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return nil
	}
	c.path = strings.clone(path)
	c.stamp, c.data = stamp, data
	sec := ""
	s := string(data)
	for line in strings.split_lines_iterator(&s) {
		t := strings.trim_space(strings.trim_right(line, "\r"))
		l := Ini_Line{section = sec, text = strings.trim_right(line, "\r")}
		if strings.has_prefix(t, "[") {
			if e := strings.index_byte(t, ']'); e > 0 {
				sec = t[1:e]
				l.section = sec
			}
		} else if k := strings.index_byte(t, '='); k > 0 && t[0] != ';' {
			l.key = strings.trim_space(t[:k])
			l.value = strings.trim_space(t[k + 1:])
			if len(l.value) >= 2 && l.value[0] == '"' && l.value[len(l.value) - 1] == '"' {
				l.value = l.value[1:len(l.value) - 1]
			}
		}
		append(&c.lines, l)
	}
	return c.lines[:]
}

// Drops the parsed file.
ini_forget :: proc() {
	c := &ini_cache
	delete(c.path)
	delete(c.data)
	delete(c.lines)
	c^ = {}
}

// Host-side values that win over the file; never written back. Set at
// startup (native settings_boot): Intro Movies off skips the boot logo and
// movie sequence, a frame rate above 30 lifts ClampFPS.
Ini_Override :: struct {
	section, key, value: string,
}

ini_overrides: [dynamic]Ini_Override

ini_override :: proc(section, key, value: string) {
	append(&ini_overrides, Ini_Override{section, key, value})
}

ini_get :: proc(lines: []Ini_Line, app, key: string) -> (string, bool) {
	for o in ini_overrides {
		if strings.equal_fold(o.section, app) && strings.equal_fold(o.key, key) {
			return o.value, true
		}
	}
	for l in lines {
		if l.key != "" && strings.equal_fold(l.section, app) && strings.equal_fold(l.key, key) {
			return l.value, true
		}
	}
	return "", false
}

// Writes a NUL-separated, double-NUL-terminated list into buf[:n].
put_multi :: proc(buf, n: u32, items: []string) -> u32 {
	if n < 2 {
		return 0
	}
	at: u32 = 0
	for it in items {
		if at + u32(len(it)) + 2 > n {
			break
		}
		copy(x86.mem[buf + at:buf + at + u32(len(it))], it)
		at += u32(len(it))
		x86.wr8(buf + at, 0)
		at += 1
	}
	x86.wr8(buf + at, 0)
	return at
}

GetPrivateProfileStringA :: proc() {
	app, key, def, buf, n, file := arg(0), arg(1), arg(2), arg(3), arg(4), arg(5)
	lines := ini_load(guest_path(file))
	if app == 0 || key == 0 {
		items: [dynamic]string
		items.allocator = context.temp_allocator
		for l in lines {
			if app == 0 && l.key == "" && strings.has_prefix(strings.trim_space(l.text), "[") {
				append(&items, l.section)
			} else if app != 0 && l.key != "" && strings.equal_fold(l.section, x86.cstr(app)) {
				append(&items, l.key)
			}
		}
		ret(6, put_multi(buf, n, items[:]))
		return
	}
	v, ok := ini_get(lines, x86.cstr(app), x86.cstr(key))
	if !ok {
		v = def != 0 ? x86.cstr(def) : ""
	}
	ret(6, put_str(buf, n, v))
}

GetPrivateProfileIntA :: proc() {
	app, key, def, file := arg(0), arg(1), arg(2), arg(3)
	v, ok := ini_get(ini_load(guest_path(file)), x86.cstr(app), x86.cstr(key))
	if !ok {
		ret(4, def)
		return
	}
	// Leading decimal digits only, like the Win32 parser.
	k := 0
	for k < len(v) && (v[k] >= '0' && v[k] <= '9' || (k == 0 && v[k] == '-')) {
		k += 1
	}
	i, _ := strconv.parse_int(v[:k])
	ret(4, u32(i32(i)))
}

WritePrivateProfileStringA :: proc() {
	app, key, str, file := arg(0), arg(1), arg(2), arg(3)
	k, v: Maybe(string)
	if key != 0 {k = x86.cstr(key)}
	if str != 0 {v = x86.cstr(str)}
	if !ini_write(guest_path(file), x86.cstr(app), k, v) {
		last_error = ERROR_ACCESS_DENIED
		ret(4, 0)
		return
	}
	ret(4, 1)
}

// Replaces, deletes (value nil) or appends key in app; app with key nil
// deletes the section. False when the file cannot be written.
ini_write :: proc(path, app: string, key, value: Maybe(string)) -> bool {
	lines := ini_load(path)
	k, has_key := key.?
	v, has_value := value.?
	b := strings.builder_make(context.temp_allocator)
	done, in_sec, seen_sec := false, false, false
	for l in lines {
		mine := strings.equal_fold(l.section, app)
		if in_sec && !mine && !done && has_key && has_value {
			fmt.sbprintf(&b, "%s=%s\r\n", k, v)
			done = true
		}
		in_sec = mine
		seen_sec ||= mine
		if mine && !has_key {
			continue
		}
		if mine && l.key != "" && strings.equal_fold(l.key, k) {
			if has_value && !done {
				fmt.sbprintf(&b, "%s=%s\r\n", l.key, v)
			}
			done = true
			continue
		}
		fmt.sbprintf(&b, "%s\r\n", l.text)
	}
	if !done && has_key && has_value {
		if !seen_sec {
			fmt.sbprintf(&b, "[%s]\r\n", app)
		}
		fmt.sbprintf(&b, "%s=%s\r\n", k, v)
	}
	werr := os.write_entire_file(path, transmute([]u8)strings.to_string(b))
	ini_forget() // lines slice the old data; a write in the same tick keeps mtime
	if werr != nil {return false}
	dir_cache_forget(path) // the file may be new
	return true
}
