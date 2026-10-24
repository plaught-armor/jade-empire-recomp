// kernel32 file services over the host file system. Guest paths under
// GAME_DIR (or relative ones) map onto the host working directory, matched
// case-insensitively per component the way NTFS resolves them; under
// lockstep the scratch and logs folders map onto lock_scratch and lock_logs.
package win32

import "core:fmt"
import "core:io"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "../x86"

FILE := [?]Hle_Entry {
	{"kernel32.dll!CreateFileA", CreateFileA},
	{"kernel32.dll!ReadFile", ReadFile},
	{"kernel32.dll!WriteFile", WriteFile},
	{"kernel32.dll!ReadFileEx", ReadFileEx},
	{"kernel32.dll!GetOverlappedResult", GetOverlappedResult},
	{"kernel32.dll!CancelIo", ret1_1},
	{"kernel32.dll!CloseHandle", CloseHandle},
	{"kernel32.dll!GetFileSize", GetFileSize},
	{"kernel32.dll!GetFileInformationByHandle", GetFileInformationByHandle},
	{"kernel32.dll!SetFilePointer", SetFilePointer},
	{"kernel32.dll!SetFilePointerEx", SetFilePointerEx},
	{"kernel32.dll!SetEndOfFile", SetEndOfFile},
	{"kernel32.dll!FlushFileBuffers", FlushFileBuffers},
	{"kernel32.dll!DeleteFileA", DeleteFileA},
	{"kernel32.dll!CreateDirectoryA", CreateDirectoryA},
	{"kernel32.dll!RemoveDirectoryA", RemoveDirectoryA},
	{"kernel32.dll!FindFirstFileA", FindFirstFileA},
	{"kernel32.dll!FindNextFileA", FindNextFileA},
	{"kernel32.dll!FindClose", FindClose},
	{"kernel32.dll!GetDiskFreeSpaceExA", GetDiskFreeSpaceExA},
	{"kernel32.dll!SleepEx", SleepEx},
	{"kernel32.dll!CreateMutexA", CreateMutexA},
	{"kernel32.dll!OpenMutexA", OpenMutexA},
	{"kernel32.dll!ReleaseMutex", ret1_1},
	{"kernel32.dll!SetEvent", ret1_1},
}

ERROR_FILE_NOT_FOUND :: 2
ERROR_PATH_NOT_FOUND :: 3
ERROR_ACCESS_DENIED :: 5
ERROR_INVALID_HANDLE :: 6
ERROR_NO_MORE_FILES :: 18
ERROR_HANDLE_EOF :: 38
ERROR_FILE_EXISTS :: 80
ERROR_ALREADY_EXISTS :: 183
ERROR_DIR_NOT_EMPTY :: 145
ERROR_DIRECTORY :: 267 // the name is not a directory
INVALID_HANDLE :: 0xffffffff
FILE_FLAG_BACKUP_SEMANTICS :: 0x02000000

// ---------------------------------------------------------------- paths

// Host path for a guest path, resolved case-insensitively against existing
// entries; components that do not exist keep their spelling. Temp-allocated.
host_path :: proc(guest: string) -> string {
	p, _ := strings.replace_all(guest, `\`, "/", context.temp_allocator)
	lower := strings.to_lower(p, context.temp_allocator)
	game := `c:/jade empire`
	if strings.has_prefix(lower, game) && (len(p) == len(game) || p[len(game)] == '/') {
		p = p[len(game):]
	} else if len(p) >= 2 && p[1] == ':' {
		p = p[2:] // other drives: treat as rooted in the game dir
	}
	out := strings.builder_make(context.temp_allocator)
	strings.write_string(&out, ".")
	rest := strings.trim_left(p, "/")
	if lock_scratch != "" {
		first := rest
		if i := strings.index_byte(rest, '/'); i >= 0 {first = rest[:i]}
		root := ""
		if strings.equal_fold(first, "scratch") {root = lock_scratch}
		if strings.equal_fold(first, "logs") {root = lock_logs}
		if net_save != "" && strings.equal_fold(first, "save") {root = net_save}
		if net_ini != "" && strings.equal_fold(strings.trim_prefix(rest, "./"), NET_INI) {return net_ini}
		if root != "" {
			strings.builder_reset(&out)
			strings.write_string(&out, root)
			rest = rest[len(first):]
		}
	}
	for part in strings.split_iterator(&rest, "/") {
		if part == "" || part == "." {
			continue
		}
		dir := strings.to_string(out)
		strings.write_byte(&out, '/')
		strings.write_string(&out, match_entry(dir, part))
	}
	return strings.to_string(out)
}

// Name of the entry in dir equal to part ignoring case, or part itself. An
// exact match wins over a case-folded one.
match_entry :: proc(dir, part: string) -> string {
	if part == ".." {
		return part
	}
	l := dir_listing(dir)
	if l == nil {
		return part
	}
	if name, ok := l.names[part]; ok {
		return name
	}
	low := make([]u8, len(part), context.temp_allocator)
	for c, i in transmute([]u8)part {low[i] = lower(c)}
	if name, ok := l.names[string(low)]; ok {
		return name
	}
	return part
}

// Cached listing of one host directory, keyed in dir_cache by the directory
// path as host_path builds it. names maps every entry's exact name, and its
// ASCII-lowercase form when no entry has that exact name, to the entry's
// name; all of those strings point into blob.
// WHY: docs/hle.md §1
Dir_Listing :: struct {
	blob:  []u8,
	names: map[string]string,
}

DIR_CACHE_MAX :: 512

dir_cache: map[string]Dir_Listing

// Listing of dir, read once and kept until a guest change to dir drops it
// (dir_cache_forget). nil when dir cannot be read; that is not cached.
dir_listing :: proc(dir: string) -> ^Dir_Listing {
	if l, ok := &dir_cache[dir]; ok {
		return l
	}
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return nil
	}
	if len(dir_cache) >= DIR_CACHE_MAX {
		for k, v in dir_cache {dir_listing_free(k, v)}
		clear(&dir_cache)
	}
	total := 0
	for fi in infos {total += 2 * len(fi.name)}
	l := Dir_Listing {
		blob  = make([]u8, total),
		names = make(map[string]string, 2 * len(infos)),
	}
	at := 0
	for fi in infos {
		n := len(fi.name)
		copy(l.blob[at:], fi.name)
		for i in 0 ..< n {l.blob[at + n + i] = lower(fi.name[i])}
		name, low := string(l.blob[at:][:n]), string(l.blob[at + n:][:n])
		at += 2 * n
		l.names[name] = name // an exact name replaces a folded alias
		if low not_in l.names {l.names[low] = name}
	}
	assert(at == total)
	dir_cache[strings.clone(dir)] = l
	return &dir_cache[dir]
}

dir_cache_drop :: proc(dir: string) {
	if dir not_in dir_cache {
		return
	}
	k, l := delete_key(&dir_cache, dir)
	dir_listing_free(k, l)
}

dir_listing_free :: proc(k: string, l: Dir_Listing) {
	delete(k)
	delete(l.blob)
	delete(l.names)
}

// Drops the cached listings a guest change to host path p can make stale:
// the directory holding p, and p itself when it is a directory.
dir_cache_forget :: proc(p: string) {
	if k := strings.last_index_byte(p, '/'); k > 0 {
		dir_cache_drop(p[:k])
	}
	dir_cache_drop(p)
}

guest_path :: proc(p: u32) -> string {
	return host_path(x86.cstr(p))
}

// ---------------------------------------------------------------- handles

Obj_Kind :: enum u8 {
	None,
	File,
	Find,
	Mutex,
}

Obj :: struct {
	kind:     Obj_Kind,
	file:     ^os.File,
	pos:      i64,      // file pointer; reads and writes are positional
	names:    []string, // Find: matching entries, then the next index
	find_dir: string,
	find_i:   int,
	thumb:    string, // File: a save thumbnail written through it, shrunk at close
}

HANDLE_BASE :: 0x100
HANDLE_MAX :: 4096

objs: [dynamic]Obj

new_handle :: proc(o: Obj) -> u32 {
	for &e, i in objs {
		if e.kind == .None {
			e = o
			return HANDLE_BASE + u32(i) * 4
		}
	}
	if len(objs) >= HANDLE_MAX {
		x86.fatal("more than %d open guest handles", HANDLE_MAX)
	}
	append(&objs, o)
	return HANDLE_BASE + u32(len(objs) - 1) * 4
}

get_obj :: proc(h: u32, kind: Obj_Kind) -> ^Obj {
	i := int(h - HANDLE_BASE) / 4
	if h < HANDLE_BASE || h & 3 != 0 || i >= len(objs) || objs[i].kind != kind {
		return nil
	}
	return &objs[i]
}

// ---------------------------------------------------------------- files

GENERIC_WRITE :: 0x40000000
CREATE_NEW :: 1
CREATE_ALWAYS :: 2
OPEN_EXISTING :: 3
OPEN_ALWAYS :: 4
TRUNCATE_EXISTING :: 5

CreateFileA :: proc() {
	path := tex_hd_open(font_hd_open(guest_path(arg(0))))
	gen := tlk_open(path)
	if gen == nil {gen = res_gen_open(path)}
	if gen != nil {
		last_error = 0
		ret(7, new_handle({kind = .File, file = gen}))
		return
	}
	access, disp := arg(1), arg(4)
	if os.exists(path) {net_save_open(path, access & GENERIC_WRITE != 0, disp)}
	exists := os.exists(path)
	if os.is_dir(path) {
		// Directories open only with backup semantics, and only with a disposition
		// that accepts an existing entry (the save code opens Scratch\INPROGRESS
		// with OPEN_ALWAYS after CreateDirectoryA reports it exists).
		d, err := os.open(path)
		if arg(5) & FILE_FLAG_BACKUP_SEMANTICS == 0 || (disp != OPEN_EXISTING && disp != OPEN_ALWAYS) || err != nil {
			if err == nil {os.close(d)}
			last_error = ERROR_ACCESS_DENIED
			ret(7, INVALID_HANDLE)
			return
		}
		last_error = disp == OPEN_ALWAYS ? ERROR_ALREADY_EXISTS : 0
		ret(7, new_handle({kind = .File, file = d}))
		return
	}
	flags := access & GENERIC_WRITE != 0 ? os.O_RDWR : os.O_RDONLY
	switch disp {
	case CREATE_NEW:
		if exists {last_error = ERROR_FILE_EXISTS; ret(7, INVALID_HANDLE); return}
		flags += {.Create}
	case CREATE_ALWAYS:
		flags += {.Create, .Trunc}
	case OPEN_EXISTING, TRUNCATE_EXISTING:
		if !exists {last_error = ERROR_FILE_NOT_FOUND; ret(7, INVALID_HANDLE); return}
		if disp == TRUNCATE_EXISTING {flags += {.Trunc}}
	case OPEN_ALWAYS:
		flags += {.Create}
	case:
		x86.fatal("CreateFileA: disposition %d", disp)
	}
	f, err := os.open(path, flags)
	if err != nil {
		last_error = exists ? ERROR_ACCESS_DENIED : ERROR_PATH_NOT_FOUND
		ret(7, INVALID_HANDLE)
		return
	}
	if !exists {dir_cache_forget(path)}
	thumb := ""
	if access & GENERIC_WRITE != 0 && strings.equal_fold(path[strings.last_index_byte(path, '/') + 1:], THUMB_NAME) {
		thumb = strings.clone(path)
	}
	// CREATE_ALWAYS/OPEN_ALWAYS report an existing file through last error.
	last_error = exists && (disp == CREATE_ALWAYS || disp == OPEN_ALWAYS) ? ERROR_ALREADY_EXISTS : 0
	ret(7, new_handle({kind = .File, file = f, thumb = thumb}))
}

// Overlapped I/O carries its file offset in OVERLAPPED.Offset/OffsetHigh.
ovl_offset :: proc(ovl: u32) -> i64 {
	return i64(x86.rd64(ovl + 8))
}

// Reads n bytes at the handle's position (or the overlapped offset).
// Returns bytes read, or -1 on a bad handle.
file_read :: proc(h, buf, n, ovl: u32) -> i64 {
	o := get_obj(h, .File)
	if o == nil {
		return -1
	}
	at := ovl != 0 ? ovl_offset(ovl) : o.pos
	k, err := os.read_at(o.file, x86.mem[buf:buf + n], at)
	if err != nil && err != io.Error.EOF {
		x86.fatal("ReadFile: %v", err)
	}
	if ovl == 0 {
		o.pos += i64(k)
	} else {
		x86.wr32(ovl, 0)
		x86.wr32(ovl + 4, u32(k))
	}
	return i64(k)
}

ReadFile :: proc() {
	h, buf, n, got, ovl := arg(0), arg(1), arg(2), arg(3), arg(4)
	k := file_read(h, buf, n, ovl)
	if k < 0 {
		last_error = ERROR_INVALID_HANDLE
		ret(5, 0)
		return
	}
	if got != 0 {
		x86.wr32(got, u32(k))
	}
	// Overlapped reads complete synchronously; EOF is an error there.
	if ovl != 0 && k == 0 && n > 0 {
		last_error = ERROR_HANDLE_EOF
		ret(5, 0)
		return
	}
	ret(5, 1)
}

WriteFile :: proc() {
	h, buf, n, got, ovl := arg(0), arg(1), arg(2), arg(3), arg(4)
	if h == STD_ERROR || h == STD_ERROR + 1 {
		fmt.eprint(string(x86.mem[buf:buf + n]))
		if got != 0 {x86.wr32(got, n)}
		ret(5, 1)
		return
	}
	o := get_obj(h, .File)
	if o == nil {
		last_error = ERROR_INVALID_HANDLE
		ret(5, 0)
		return
	}
	at := ovl != 0 ? ovl_offset(ovl) : o.pos
	if _, err := os.seek(o.file, at, .Start); err != nil {
		x86.fatal("WriteFile seek: %v", err)
	}
	k, err := os.write(o.file, x86.mem[buf:buf + n])
	if err != nil {
		x86.fatal("WriteFile: %v", err)
	}
	if ovl == 0 {o.pos += i64(k)}
	if got != 0 {x86.wr32(got, u32(k))}
	ret(5, 1)
}

// Completion routines queued by ReadFileEx run at the next alertable wait.
Apc :: struct {
	routine, err, n, ovl: u32,
}

apcs: [dynamic]Apc

ReadFileEx :: proc() {
	h, buf, n, ovl, routine := arg(0), arg(1), arg(2), arg(3), arg(4)
	k := file_read(h, buf, n, ovl)
	if k < 0 {
		last_error = ERROR_INVALID_HANDLE
		ret(5, 0)
		return
	}
	append(&apcs, Apc{routine, k == 0 && n > 0 ? ERROR_HANDLE_EOF : 0, u32(k), ovl})
	ret(5, 1)
}

// Runs queued completion routines (stdcall, 3 args) on the guest stack.
run_apcs :: proc() -> bool {
	ran := len(apcs) > 0
	for len(apcs) > 0 {
		a := pop_front(&apcs)
		x86.push32(a.ovl)
		x86.push32(a.n)
		x86.push32(a.err)
		x86.push32(0) // return address; generated code returns natively
		guest_enter(a.routine)
	}
	return ran
}

WAIT_IO_COMPLETION :: 0xc0

SleepEx :: proc() {
	ms, alertable := arg(0), arg(1)
	esp := x86.cpu.esp
	if alertable != 0 && run_apcs() {
		x86.cpu.esp = esp
		ret(2, WAIT_IO_COMPLETION)
		return
	}
	d := time.Duration(ms) * time.Millisecond
	if lockstep {vclock += d} else {time.sleep(d)}
	ret(2, 0)
}

GetOverlappedResult :: proc() {
	ovl, got := arg(1), arg(2)
	x86.wr32(got, x86.rd32(ovl + 4))
	ret(4, 1)
}

CloseHandle :: proc() {
	h := arg(0)
	i := int(h - HANDLE_BASE) / 4
	if h < HANDLE_BASE || i >= len(objs) || objs[i].kind == .None {
		last_error = ERROR_INVALID_HANDLE
		ret(1, 0)
		return
	}
	if objs[i].kind == .File {
		os.close(objs[i].file)
	}
	if objs[i].thumb != "" {
		thumb_shrink(objs[i].thumb)
		delete(objs[i].thumb)
	}
	objs[i] = {}
	ret(1, 1)
}

// The thumbnail each save carries. The game writes it as a 512x512 32-bit
// TGA, 1 MB of a save's 2 to 4; its load menu shows it scaled into a smaller
// frame and reads any size and depth, so the port keeps it at THUMB_SIZE,
// 24-bit. Both peers shrink the same bytes the same way.
// WHY: docs/hle.md §1
THUMB_NAME :: "SaveImage.tga"
THUMB_SIZE :: 256
TGA_HEADER :: 18
TGA_TRUE_COLOR :: 2 // uncompressed
TGA_ORIGIN :: 0x30 // the descriptor's origin bits; the rest are alpha depth

// Rewrites the uncompressed true-colour TGA at host path p box-filtered down
// by a whole factor to THUMB_SIZE across, 24-bit. Other files stay as they are.
thumb_shrink :: proc(p: string) {
	d, err := os.read_entire_file(p, context.temp_allocator)
	if err != nil || len(d) < TGA_HEADER || d[1] != 0 || d[2] != TGA_TRUE_COLOR {return}
	w, h, bpp := int(d[12]) | int(d[13]) << 8, int(d[14]) | int(d[15]) << 8, int(d[16])
	k := w / THUMB_SIZE
	if (bpp != 24 && bpp != 32) || k < 2 || w % k != 0 || h % k != 0 {return}
	px := bpp / 8
	src := d[TGA_HEADER + int(d[0]):]
	if len(src) < w * h * px {return}
	ow, oh := w / k, h / k
	out := make([]u8, TGA_HEADER + ow * oh * 3, context.temp_allocator)
	out[2] = TGA_TRUE_COLOR
	out[12], out[13], out[14], out[15] = u8(ow), u8(ow >> 8), u8(oh), u8(oh >> 8)
	out[16], out[17] = 24, d[17] & TGA_ORIGIN
	for y in 0 ..< oh {
		for x in 0 ..< ow {
			sum: [3]int
			for dy in 0 ..< k {
				row := ((y * k + dy) * w + x * k) * px
				for dx in 0 ..< k {
					for c in 0 ..< 3 {sum[c] += int(src[row + dx * px + c])}
				}
			}
			o := TGA_HEADER + (y * ow + x) * 3
			for c in 0 ..< 3 {out[o + c] = u8((sum[c] + k * k / 2) / (k * k))}
		}
	}
	if werr := os.write_entire_file(p, out); werr != nil {x86.fatal("thumbnail %s: %v", p, werr)}
}

file_len :: proc(o: ^Obj) -> i64 {
	n, err := os.file_size(o.file)
	if err != nil {
		x86.fatal("file size: %v", err)
	}
	return n
}

GetFileSize :: proc() {
	o := get_obj(arg(0), .File)
	if o == nil {
		last_error = ERROR_INVALID_HANDLE
		ret(2, INVALID_HANDLE)
		return
	}
	n := file_len(o)
	if hi := arg(1); hi != 0 {
		x86.wr32(hi, u32(n >> 32))
	}
	ret(2, u32(n))
}

// A file's time as a FILETIME. Under lockstep every file has the handshake's
// time: the same files have other times on another peer's disk.
filetime :: proc(t: time.Time) -> u64 {
	ns := lockstep ? lock_epoch : time.time_to_unix_nano(t)
	return u64(ns / 100) + FILETIME_UNIX
}

GetFileInformationByHandle :: proc() {
	o := get_obj(arg(0), .File)
	p := arg(1)
	if o == nil {
		last_error = ERROR_INVALID_HANDLE
		ret(2, 0)
		return
	}
	fi, err := os.fstat(o.file, context.temp_allocator)
	if err != nil {
		x86.fatal("fstat: %v", err)
	}
	x86.mem_zero(p, 52)
	x86.wr32(p, 0x80) // FILE_ATTRIBUTE_NORMAL
	x86.wr64(p + 4, filetime(fi.creation_time))
	x86.wr64(p + 12, filetime(fi.access_time))
	x86.wr64(p + 20, filetime(fi.modification_time))
	x86.wr32(p + 32, u32(fi.size >> 32))
	x86.wr32(p + 36, u32(fi.size))
	x86.wr32(p + 40, 1)
	x86.wr32(p + 44, u32(fi.inode >> 32))
	x86.wr32(p + 48, u32(fi.inode))
	ret(2, 1)
}

// New position for a FILE_BEGIN/CURRENT/END move, or -1 when it is negative.
file_seek :: proc(o: ^Obj, d: i64, method: u32) -> i64 {
	base: i64
	switch method {
	case 0: base = 0
	case 1: base = o.pos
	case 2: base = file_len(o)
	case: x86.fatal("SetFilePointer: method %d", method)
	}
	if base + d < 0 {
		return -1
	}
	o.pos = base + d
	return o.pos
}

SetFilePointer :: proc() {
	o := get_obj(arg(0), .File)
	lo, hi, method := arg(1), arg(2), arg(3)
	if o == nil {
		last_error = ERROR_INVALID_HANDLE
		ret(4, INVALID_HANDLE)
		return
	}
	d := i64(i32(lo))
	if hi != 0 {
		d = i64(u64(x86.rd32(hi)) << 32 | u64(lo))
	}
	pos := file_seek(o, d, method)
	if pos < 0 {
		last_error = 131 // ERROR_NEGATIVE_SEEK
		ret(4, INVALID_HANDLE)
		return
	}
	if hi != 0 {
		x86.wr32(hi, u32(pos >> 32))
	}
	last_error = 0
	ret(4, u32(pos))
}

SetFilePointerEx :: proc() {
	o := get_obj(arg(0), .File)
	d := i64(u64(arg(2)) << 32 | u64(arg(1)))
	out, method := arg(3), arg(4)
	if o == nil {
		last_error = ERROR_INVALID_HANDLE
		ret(5, 0)
		return
	}
	pos := file_seek(o, d, method)
	if pos < 0 {
		last_error = 131
		ret(5, 0)
		return
	}
	if out != 0 {
		x86.wr64(out, u64(pos))
	}
	ret(5, 1)
}

SetEndOfFile :: proc() {
	o := get_obj(arg(0), .File)
	if o == nil || os.truncate(o.file, o.pos) != nil {
		last_error = ERROR_ACCESS_DENIED
		ret(1, 0)
		return
	}
	ret(1, 1)
}

FlushFileBuffers :: proc() {
	o := get_obj(arg(0), .File)
	if o != nil {
		os.flush(o.file)
	}
	ret(1, 1)
}

// Win32 error for a failed unlink or rmdir. Windows reports a directory
// passed to DeleteFile as access denied, and a file passed to RemoveDirectory
// as ERROR_DIRECTORY.
remove_error :: proc(e: posix.Errno) -> u32 {
	#partial switch e {
	case .ENOENT: return ERROR_FILE_NOT_FOUND
	case .ENOTDIR: return ERROR_DIRECTORY
	case .ENOTEMPTY, .EEXIST: return ERROR_DIR_NOT_EMPTY
	case .EISDIR, .EPERM, .EACCES, .EBUSY, .EROFS: return ERROR_ACCESS_DENIED
	}
	return ERROR_ACCESS_DENIED
}

DeleteFileA :: proc() {
	p := guest_path(arg(0))
	net_save_remove(p)
	if posix.unlink(strings.clone_to_cstring(p, context.temp_allocator)) != .OK {
		last_error = remove_error(posix.errno())
		ret(1, 0)
		return
	}
	dir_cache_forget(p)
	ret(1, 1)
}

CreateDirectoryA :: proc() {
	p := guest_path(arg(0))
	if os.exists(p) {
		last_error = ERROR_ALREADY_EXISTS
		ret(2, 0)
		return
	}
	if os.make_directory(p) != nil {
		last_error = ERROR_PATH_NOT_FOUND
		ret(2, 0)
		return
	}
	dir_cache_forget(p)
	ret(2, 1)
}

RemoveDirectoryA :: proc() {
	p := guest_path(arg(0))
	if posix.rmdir(strings.clone_to_cstring(p, context.temp_allocator)) != .OK {
		last_error = remove_error(posix.errno())
		ret(1, 0)
		return
	}
	dir_cache_forget(p)
	ret(1, 1)
}

// ---------------------------------------------------------------- find

// Case-insensitive DOS wildcard match: '*' any run, '?' one character.
wild_match :: proc(pat, s: string) -> bool {
	p, i := 0, 0
	star, mark := -1, 0
	for i < len(s) {
		if p < len(pat) && (pat[p] == '?' || lower(pat[p]) == lower(s[i])) {
			p += 1; i += 1
		} else if p < len(pat) && pat[p] == '*' {
			star = p; mark = i; p += 1
		} else if star >= 0 {
			p = star + 1; mark += 1; i = mark
		} else {
			return false
		}
	}
	for p < len(pat) && pat[p] == '*' {
		p += 1
	}
	return p == len(pat)
}

lower :: proc(c: u8) -> u8 {
	return c >= 'A' && c <= 'Z' ? c + 32 : c
}

// Fills WIN32_FIND_DATAA for entry name in dir.
put_find_data :: proc(p: u32, dir, name: string) {
	x86.mem_zero(p, 320)
	path := tex_hd_open(fmt.tprintf("%s/%s", dir, name))
	if data, ok := res_gen_get(path); ok {
		x86.wr32(p, 0x80)
		x86.wr32(p + 32, u32(len(data)))
		put_str(p + 44, 260, name)
		return
	}
	fi, err := os.stat(path, context.temp_allocator)
	if err == nil {
		x86.wr32(p, fi.type == .Directory ? 0x10 : 0x80)
		x86.wr64(p + 4, filetime(fi.creation_time))
		x86.wr64(p + 12, filetime(fi.access_time))
		x86.wr64(p + 20, filetime(fi.modification_time))
		x86.wr32(p + 28, u32(fi.size >> 32))
		x86.wr32(p + 32, u32(fi.size))
	}
	put_str(p + 44, 260, name)
}

FindFirstFileA :: proc() {
	g, data := x86.cstr(arg(0)), arg(1)
	k := strings.last_index_any(g, `\/`)
	dir := k >= 0 ? host_path(g[:k]) : "."
	pat := g[k + 1:]
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		last_error = ERROR_PATH_NOT_FOUND
		ret(2, INVALID_HANDLE)
		return
	}
	names: [dynamic]string
	if wild_match(pat, ".") {append(&names, strings.clone("."))}
	if wild_match(pat, "..") {append(&names, strings.clone(".."))}
	for fi in infos {
		if wild_match(pat, fi.name) {
			append(&names, strings.clone(fi.name))
		}
	}
	tex_hd_list(dir, pat, &names)
	res_gen_list(dir, pat, &names)
	// In NTFS's order, case-insensitive by name, not the host file system's.
	slice.sort_by(names[:], proc(a, b: string) -> bool {
		for i in 0 ..< min(len(a), len(b)) {
			if lower(a[i]) != lower(b[i]) {return lower(a[i]) < lower(b[i])}
		}
		return len(a) < len(b)
	})
	if len(names) == 0 {
		delete(names)
		last_error = ERROR_FILE_NOT_FOUND
		ret(2, INVALID_HANDLE)
		return
	}
	put_find_data(data, dir, names[0])
	ret(2, new_handle({kind = .Find, names = names[:], find_dir = strings.clone(dir), find_i = 1}))
}

FindNextFileA :: proc() {
	o := get_obj(arg(0), .Find)
	if o == nil {
		last_error = ERROR_INVALID_HANDLE
		ret(2, 0)
		return
	}
	if o.find_i >= len(o.names) {
		last_error = ERROR_NO_MORE_FILES
		ret(2, 0)
		return
	}
	put_find_data(arg(1), o.find_dir, o.names[o.find_i])
	o.find_i += 1
	ret(2, 1)
}

FindClose :: proc() {
	o := get_obj(arg(0), .Find)
	if o == nil {
		last_error = ERROR_INVALID_HANDLE
		ret(1, 0)
		return
	}
	for n in o.names {delete(n)}
	delete(o.names)
	delete(o.find_dir)
	o^ = {}
	ret(1, 1)
}

GetDiskFreeSpaceExA :: proc() {
	free_gb := u64(64) << 30
	for i in u32(1) ..= 3 {
		if p := arg(i); p != 0 {x86.wr64(p, free_gb)}
	}
	ret(4, 1)
}

// ---------------------------------------------------------------- mutexes

// A single process: named mutexes are always new, OpenMutex never finds one.
CreateMutexA :: proc() {
	h := new_handle({kind = .Mutex})
	last_error = 0
	ret(3, h)
}

OpenMutexA :: proc() {
	last_error = ERROR_FILE_NOT_FOUND
	ret(3, 0)
}
