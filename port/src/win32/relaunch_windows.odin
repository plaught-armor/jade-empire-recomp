package win32

import "core:fmt"
import "core:os"
import win "core:sys/windows"
import "../x86"

// Windows has no exec: runs path on args and env with this process's
// output, gives back the guest's memory, and exits with the new process's
// code once it ends, so play.bat waits on.
relaunch_os :: proc(path: string, args, env: []string) -> ! {
	p, err := os.process_start({command = args, env = env, stdout = os.stdout, stderr = os.stderr})
	if err != nil {
		fmt.eprintfln("relaunch: cannot run %s: %v", path, err)
		os.exit(1)
	}
	_ = win.VirtualFree(rawptr(x86.MEM_BASE), 0, win.MEM_RELEASE)
	state, werr := os.process_wait(p)
	if werr != nil {
		fmt.eprintfln("relaunch: cannot wait on %s: %v", path, werr)
		os.exit(1)
	}
	os.exit(state.exit_code)
}
