package win32

import "core:strings"
import "core:sys/posix"

// A file's modification time and size.
Ini_Stamp :: struct {
	mtime: posix.timespec,
	size:  posix.off_t,
}

ini_stamp :: proc(path: string) -> (Ini_Stamp, bool) {
	st: posix.stat_t
	if posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK {return {}, false}
	return {st.st_mtim, st.st_size}, true
}
