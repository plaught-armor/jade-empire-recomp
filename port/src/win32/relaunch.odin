// Starting over: the port runs itself again on the same game, from boot,
// with the online settings changed. Leaving an online game in play, and an
// online game the main menu opened failing (net_fail), end this way, since
// lockstep play cannot go back to the menu's own state.
// WHY: docs/hle.md §11
package win32

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import sdl "vendor:sdl3"

// The game folder and the unpacked exe, absolute: main sets them before it
// enters the game folder.
relaunch_game: string
relaunch_exe: string

// What a relaunch drops from the environment before it adds its own.
RELAUNCH_DROP :: [?]string{"JE_NET_HOST", "JE_NET_JOIN", "JE_NET_ERROR"}

// Ends this game as game_exit does (telling the peer when bye is set) and
// runs the port again with the environment less RELAUNCH_DROP plus set,
// each KEY=VALUE.
relaunch :: proc(bye: bool, set: ..string) -> ! {
	assert(relaunch_game != "" && relaunch_exe != "")
	env, err := os.environ(context.temp_allocator)
	if err != nil {
		fmt.eprintfln("relaunch: cannot read the environment: %v", err)
		game_exit(1, bye)
	}
	keep := make([dynamic]string, 0, len(env) + len(set), context.temp_allocator)
	drop := RELAUNCH_DROP
	for e in env {
		key := e[:max(strings.index_byte(e, '='), 0)]
		if !slice.contains(drop[:], key) {append(&keep, e)}
	}
	append(&keep, ..set)
	self, serr := os.get_executable_path(context.temp_allocator)
	if serr != nil {
		fmt.eprintfln("relaunch: cannot find the port's executable: %v", serr)
		game_exit(1, bye)
	}
	fmt.eprintfln("relaunch: starting over with %s", len(set) > 0 ? strings.join(set, " ", context.temp_allocator) : "no online game")
	game_end(bye)
	sdl.Quit()
	relaunch_os(self, {self, relaunch_game, relaunch_exe}, keep[:])
}
