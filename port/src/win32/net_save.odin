// The online game's files (net.odin): the peer that joins plays on the
// host's Save as it was at the start of play, the host's JadeEmpire.ini
// outside [Port], the host's gameplay settings and game options, not on its
// own. At the start the host lists Save (names and sizes) into a manifest
// with the ini, the settings and the options; the joining peer fetches it
// before it starts and builds a mirror of Save in a temp folder, each file
// at its size but unread, which host_path maps the guest's Save onto. A
// mirror file's contents are fetched from the host, deflated, when the
// guest first opens it, so only the save loaded and the thumbnails shown
// cross the network. On the host, a start file the game is about to change
// or delete is copied aside first, so a peer that joins later is served
// Save as it was at the start. Nothing the joining peer's game writes
// reaches its own Save or ini.
// WHY: docs/hle.md §11
package win32

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "vendor:zlib"

NET_SAVE_DIR :: "Save"
NET_INI :: "JadeEmpire.ini"
// The blob id of the manifest; entry i of the manifest is blob i + 1.
NET_BLOB_MANIFEST :: 0

// On the joining peer: the mirror of the host's Save, which host_path maps
// the guest's Save onto (it does not exist when the host had no Save), the
// host's ini that it maps JadeEmpire.ini onto, and the host's settings,
// every Setting_Id's value in order, and the host's game options, for
// native code to put in force.
net_save: string
net_ini: string
net_settings: []i32
net_opts: []u8

@(private = "file")
Save_Entry :: struct {
	path: string, // under Save, '/' between components
	size: i64,
	dir:  bool,
}

@(private = "file")
Blob :: struct {
	data: []u8, // deflated
	raw:  u32,
}

@(private = "file")
Net_Save :: struct {
	tmp:      string, // a temp folder of the mirror and ini, or of the host's copies
	entries:  [dynamic]Save_Entry,
	// Each start file's host path to its entry: on the host, under Save; on
	// the joining peer, under net_save, for the files not yet fetched.
	files:    map[string]int,
	kept:     map[int]string, // on the host: a start file the game changed, as it was ("" when it could not be kept)
	manifest: []u8,
	blobs:    map[u32]Blob, // on the host: each blob as first deflated
}
@(private = "file")
ns: Net_Save

// On the host at the start of play: lists Save and makes the manifest of
// it, the ini, settings and game options opts.
net_save_host :: proc(settings: []i32, opts: []u8) {
	root := fmt.tprintf("./%s", NET_SAVE_DIR)
	has_save := os.is_dir(root)
	if has_save {save_walk(root, "")}
	b: [dynamic]u8
	put(&b, u8(has_save))
	put(&b, u32(len(ns.entries)))
	for e, i in ns.entries {
		put(&b, u8(e.dir))
		put(&b, e.size)
		put(&b, u16(len(e.path)))
		append(&b, e.path)
		if !e.dir {ns.files[fmt.aprintf("%s/%s", root, e.path)] = i}
	}
	ini, err := os.read_entire_file(NET_INI, context.temp_allocator)
	if err != nil {
		put(&b, i32(-1))
	} else {
		t := ini_without_port(string(ini))
		put(&b, i32(len(t)))
		append(&b, t)
	}
	put(&b, u32(len(settings)))
	for v in settings {put(&b, v)}
	put(&b, u32(len(opts)))
	append(&b, ..opts)
	ns.manifest = b[:]
	fmt.eprintfln("net: serving Save as at the start, %d entries", len(ns.entries))
}

@(private = "file")
save_walk :: proc(dir, rel: string) {
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {return}
	slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	for fi in infos {
		p := rel == "" ? strings.clone(fi.name) : fmt.aprintf("%s/%s", rel, fi.name)
		is_dir := fi.type == .Directory
		append(&ns.entries, Save_Entry{path = p, size = is_dir ? 0 : fi.size, dir = is_dir})
		if is_dir {save_walk(fmt.tprintf("%s/%s", dir, fi.name), p)}
	}
}

// JadeEmpire.ini text without its [Port] section, whose lines are each
// peer's own.
ini_without_port :: proc(text: string) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	port := false
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		t := strings.trim_space(line)
		if strings.has_prefix(t, "[") {port = strings.equal_fold(t, "[Port]")}
		if !port {
			strings.write_string(&b, line)
			strings.write_byte(&b, '\n')
		}
	}
	return strings.to_string(b)
}

@(private = "file")
put :: proc(b: ^[dynamic]u8, v: $T) {
	v := v
	append(b, ..slice.bytes_from_ptr(&v, size_of(T)))
}

@(private = "file")
get :: proc(b: ^[]u8, $T: typeid) -> T {
	if len(b) < size_of(T) {net_save_bad()}
	v := (^T)(raw_data(b^))^
	b^ = b[size_of(T):]
	return v
}

@(private = "file")
get_bytes :: proc(b: ^[]u8, n: int) -> []u8 {
	if n < 0 || len(b) < n {net_save_bad()}
	s := b[:n]
	b^ = b[n:]
	return s
}

@(private = "file")
net_save_bad :: proc() -> ! {
	net_fail("the save list from the host is malformed")
}

// On the joining peer before it starts: the host's manifest m into the
// mirror of its Save, its ini, net_settings and net_opts.
net_save_join :: proc(m: []u8) {
	tmp, err := os.temp_directory(context.temp_allocator)
	if err == nil {ns.tmp, err = os.make_directory_temp(tmp, "jade_net_*", context.allocator)}
	if err != nil {net_fail("cannot make a folder for the host's Save: %v", err)}
	net_save = fmt.aprintf("%s/%s", ns.tmp, NET_SAVE_DIR)
	net_ini = fmt.aprintf("%s/%s", ns.tmp, NET_INI)
	b := m
	has_save := get(&b, u8) != 0
	if has_save {
		if err = os.make_directory(net_save); err != nil {net_fail("cannot make %s: %v", net_save, err)}
	}
	n := int(get(&b, u32))
	bytes: i64
	for i in 0 ..< n {
		dir := get(&b, u8) != 0
		size := get(&b, i64)
		rel := string(get_bytes(&b, int(get(&b, u16))))
		if !has_save || rel == "" || strings.has_prefix(rel, "/") || strings.contains(rel, "..") || strings.contains_rune(rel, '\\') {net_save_bad()}
		append(&ns.entries, Save_Entry{path = strings.clone(rel), size = size, dir = dir})
		p := fmt.aprintf("%s/%s", net_save, rel)
		if dir {
			err = os.make_directory_all(p)
		} else {
			err = placeholder(p, size)
			ns.files[p] = i
			bytes += size
		}
		if err != nil {net_fail("cannot make %s: %v", p, err)}
	}
	if k := int(get(&b, i32)); k >= 0 {
		if werr := os.write_entire_file(net_ini, get_bytes(&b, k)); werr != nil {net_fail("cannot write %s: %v", net_ini, werr)}
	}
	net_settings = make([]i32, int(get(&b, u32)))
	for &v in net_settings {v = get(&b, i32)}
	net_opts = slice.clone(get_bytes(&b, int(get(&b, u32))))
	fmt.eprintfln("net: playing on the host's Save (%d entries, %d MB to fetch as opened), ini and settings", n, bytes >> 20)
}

// A file of size bytes at p whose contents are yet to come.
@(private = "file")
placeholder :: proc(p: string, size: i64) -> os.Error {
	f := os.open(p, {.Write, .Create, .Trunc}) or_return
	defer os.close(f)
	return os.truncate(f, size)
}

// CreateFileA on an existing file at host path p, before opening it: on the
// host, a start file opened to write is copied aside first; on the joining
// peer, a mirror file is fetched unless the open empties it.
net_save_open :: proc(p: string, write: bool, disp: u32) {
	if !net_on {return}
	i, ok := ns.files[p]
	if !ok {return}
	if net_slot == 0 {
		if write || disp == CREATE_ALWAYS || disp == TRUNCATE_EXISTING {keep(i, p)}
		return
	}
	key, _ := delete_key(&ns.files, p)
	defer delete(key)
	if disp == CREATE_ALWAYS || disp == TRUNCATE_EXISTING || ns.entries[i].size == 0 {return}
	what := fmt.tprintf("%s/%s", NET_SAVE_DIR, ns.entries[i].path)
	data, sent := net_blob_fetch(u32(i) + 1, what, u32(min(ns.entries[i].size, i64(max(u32)))))
	defer delete(data)
	if i64(len(data)) != ns.entries[i].size {net_fail("%s from the host is %d bytes, not %d", what, len(data), ns.entries[i].size)}
	if err := os.write_entire_file(p, data); err != nil {net_fail("cannot write %s: %v", p, err)}
	fmt.eprintfln("net: fetched %s, %d bytes as %d", what, len(data), sent)
}

// DeleteFileA of the file at host path p, before it goes: on the host a
// start file is copied aside; on the joining peer a mirror file is no
// longer fetched.
net_save_remove :: proc(p: string) {
	if !net_on {return}
	i, ok := ns.files[p]
	if !ok {return}
	if net_slot == 0 {
		keep(i, p)
		return
	}
	key, _ := delete_key(&ns.files, p)
	delete(key)
}

// On the host: start file i, at p, copied aside once.
@(private = "file")
keep :: proc(i: int, p: string) {
	if i in ns.kept {return}
	err: os.Error
	if ns.tmp == "" {
		tmp, terr := os.temp_directory(context.temp_allocator)
		err = terr
		if err == nil {ns.tmp, err = os.make_directory_temp(tmp, "jade_net_*", context.allocator)}
	}
	dst := ""
	if err == nil {
		dst = fmt.aprintf("%s/%d", ns.tmp, i)
		err = os.copy_file(dst, p)
	}
	if err != nil {
		fmt.eprintfln("net: cannot keep %s as at the start (%v); a peer that joins cannot have it", p, err)
		delete(dst)
		dst = ""
	}
	ns.kept[i] = dst
}

// On the host: blob id deflated, and its raw size; ok false when there is
// no such blob or it cannot be read.
net_save_blob :: proc(id: u32) -> (data: []u8, raw: u32, ok: bool) {
	if b, have := ns.blobs[id]; have {return b.data, b.raw, true}
	src: []u8
	if id == NET_BLOB_MANIFEST {
		src = ns.manifest
	} else {
		i := int(id) - 1
		if i >= len(ns.entries) || ns.entries[i].dir {return}
		p := fmt.tprintf("./%s/%s", NET_SAVE_DIR, ns.entries[i].path)
		if k, kept := ns.kept[i]; kept {p = k}
		if p == "" {return}
		err: os.Error
		src, err = os.read_entire_file(p, context.temp_allocator)
		if err != nil {
			fmt.eprintfln("net: cannot read %s for the peer: %v", p, err)
			return
		}
	}
	n := zlib.compressBound(zlib.uLong(len(src)))
	out := make([]u8, n)
	if zlib.compress2(raw_data(out), &n, raw_data(src), zlib.uLong(len(src)), zlib.DEFAULT_COMPRESSION) != zlib.OK {
		delete(out)
		return
	}
	b := Blob{data = out[:n], raw = u32(len(src))}
	ns.blobs[id] = b
	return b.data, b.raw, true
}

// On the joining peer: blob data, deflated, inflated to its raw size;
// heap-allocated.
net_save_inflate :: proc(data: []u8, raw: u32, what: string) -> []u8 {
	out := make([]u8, raw)
	n := zlib.uLongf(raw)
	if zlib.uncompress(raw_data(out), &n, raw_data(data), zlib.uLong(len(data))) != zlib.OK || n != zlib.uLongf(raw) {
		net_fail("%s from the host does not unpack", what)
	}
	return out
}

// At exit: the temp folder removed. Nothing goes back to Save.
net_save_close :: proc() {
	if ns.tmp != "" {_ = os.remove_all(ns.tmp)}
}
