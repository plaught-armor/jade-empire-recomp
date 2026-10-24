package win32

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

// Replaces this process with path run on args and env: the same pid, so
// whatever waits on the port (play.sh) waits on.
relaunch_os :: proc(path: string, args, env: []string) -> ! {
	cstrs :: proc(s: []string) -> [^]cstring {
		out := make([]cstring, len(s) + 1, context.temp_allocator)
		for x, i in s {out[i] = strings.clone_to_cstring(x, context.temp_allocator)}
		return raw_data(out)
	}
	errno := linux.execve(strings.clone_to_cstring(path, context.temp_allocator), cstrs(args), cstrs(env))
	fmt.eprintfln("relaunch: cannot run %s: %v", path, errno)
	os.exit(1)
}
