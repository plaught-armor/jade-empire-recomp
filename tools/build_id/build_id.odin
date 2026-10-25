// Prints the build ID that online peers compare (docs/hle.md §11).
//
// usage: odin run tools/build_id
//
// The ID is 16 hex digits of a sha256 over the Odin compiler's version and
// every file under port/src (the recompiled code in src/rec included), in
// path order. Line endings are hashed as LF, so a CRLF checkout or a src/rec
// generated on Windows gives the same ID as on Linux. Builds with the same ID
// run the game identically whatever -microarch, linker or machine made them,
// on Linux or Windows: the x87 and libm math is bit-exact
// (docs/recompiler.md §8) and no game state reads the host OS's libm, so a
// Linux and a Windows peer play together. The compiler that builds this tool
// is the one that builds the port (build.sh, build_windows.sh, build.bat run
// it with the same odin), so its version comes from ODIN_VERSION. Only the
// first 7 digits of the commit hash count: a release's odin.exe reports 7, an
// odin built from a checkout as many as git prints (9 here).
package build_id

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// More files than port/src will ever hold (about 400 today).
FILES_MAX :: 100_000

// port/, from this file's own folder.
PORT :: #directory + "/../../port"

main :: proc() {
	if len(os.args) != 1 {
		fmt.eprintln("usage: odin run tools/build_id")
		os.exit(2)
	}
	src, aerr := filepath.abs(PORT + "/src", context.allocator)
	if aerr != nil {fail("cannot resolve %s: %v", PORT + "/src", aerr)}
	paths := src_paths(src)
	slice.sort(paths)
	h: sha2.Context_256
	sha2.init_256(&h)
	commit := ODIN_VERSION_HASH[:min(7, len(ODIN_VERSION_HASH))]
	sha2.update(&h, transmute([]u8)fmt.tprintf("odin version %s:%s\n", ODIN_VERSION, commit))
	for p in paths {
		line := fmt.tprintf("%s src/%s\n", file_hash(src, p), p)
		sha2.update(&h, transmute([]u8)line)
		free_all(context.temp_allocator)
	}
	sum: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&h, sum[:])
	fmt.println(string(hex.encode(sum[:8])))
}

// Every file under src, as a path relative to it with / separators.
src_paths :: proc(src: string) -> []string {
	paths := make([dynamic]string)
	w := os.walker_create(src)
	defer os.walker_destroy(&w)
	for info in os.walker_walk(&w) {
		if path, err := os.walker_error(&w); err != nil {fail("cannot walk %s: %v", path, err)}
		if info.type == .Directory {continue}
		rel, rerr := filepath.rel(src, info.fullpath)
		if rerr != .None {fail("%s is not under %s", info.fullpath, src)}
		if len(paths) == FILES_MAX {fail("more than %d files under %s", FILES_MAX, src)}
		slashed, serr := filepath.replace_separators(rel, '/')
		if serr != nil {fail("out of memory: %v", serr)}
		append(&paths, slashed)
	}
	if path, err := os.walker_error(&w); err != nil {fail("cannot walk %s: %v", path, err)}
	return paths[:]
}

// The lowercase hex sha256 of the file with CRLF read as LF, in temp memory.
file_hash :: proc(src, rel: string) -> string {
	full, jerr := filepath.join({src, rel}, context.temp_allocator)
	if jerr != nil {fail("out of memory: %v", jerr)}
	data, err := os.read_entire_file(full, context.temp_allocator)
	if err != nil {fail("cannot read %s: %v", full, err)}
	lf, _ := strings.replace_all(string(data), "\r\n", "\n", context.temp_allocator)
	sum: [sha2.DIGEST_SIZE_256]u8
	h: sha2.Context_256
	sha2.init_256(&h)
	sha2.update(&h, transmute([]u8)lf)
	sha2.final(&h, sum[:])
	return string(hex.encode(sum[:], context.temp_allocator))
}

fail :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	os.exit(1)
}
