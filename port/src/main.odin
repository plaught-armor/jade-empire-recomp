package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "native"
import "rec"
import "win32"
import "x86"

// Usage: jade [<game dir> [<exe>]]. The game dir defaults to the folder jade
// is in, and the exe to the one win32.exe_find picks there. The game runs
// with the game dir as its working directory. `jade --version` prints the
// version line and exits.
main :: proc() {
	if len(os.args) == 2 && os.args[1] == "--version" {
		print_version()
		return
	}
	if len(os.args) > 3 {
		fmt.eprintln("usage: jade [<game dir> [<JadeEmpire.exe>]] | jade --version")
		os.exit(2)
	}
	print_version()
	game, exe := game_paths()
	x86.mem_init()
	x86.fault_init()
	x86.hle_trace = os.get_env("JE_HLE_TRACE", context.temp_allocator) != ""
	win32.frame_dump_dir = os.get_env("JE_FRAME_DUMP", context.allocator)
	win32.play_mark_dir = os.get_env("JE_MARK_DIR", context.allocator)
	win32.shader_dump_dir = os.get_env("JE_SHADER_DUMP", context.allocator)
	if tf, ok := strconv.parse_uint(os.get_env("JE_TRACE_FRAME", context.temp_allocator), 10); ok {win32.trace_frame = u32(tf)}
	win32.input_script_load(os.get_env("JE_INPUT_SCRIPT", context.allocator))
	win32.ctl_open(os.get_env("JE_CTL", context.allocator))
	native.stick_log_on = os.get_env("JE_STICK_LOG", context.temp_allocator) != ""
	rec.register()
	// A relaunch (win32 relaunch.odin) runs again on these from any folder.
	win32.relaunch_game, win32.relaunch_exe = game, exe
	if err := os.set_working_directory(game); err != nil {
		fmt.eprintfln("cannot enter %s: %v", game, err)
		os.exit(1)
	}
	// The port's settings: JadeEmpire.ini [Port], then JE_<key>.
	// WHY: docs/recompiler.md §11
	net_host := os.get_env("JE_NET_HOST", context.allocator)
	net_join := os.get_env("JE_NET_JOIN", context.allocator)
	net_open := os.get_env("JE_NET_OPEN", context.temp_allocator) != ""
	win32.net_menu = os.get_env("JE_NET_MENU", context.temp_allocator) != ""
	native.menu_error = os.get_env("JE_NET_ERROR", context.allocator)
	solo := os.get_env("JE_LOCKSTEP", context.temp_allocator)
	if net_host != "" || net_join != "" || solo != "" {
		win32.lockstep_start()
		win32.net_on = net_host != "" || net_join != ""
		if n, ok := strconv.parse_int(solo, 10); ok {win32.lock_hash_every = i64(n)}
		dump := os.get_env("JE_LOCK_DUMP", context.allocator)
		if i := strings.index_byte(dump, ':'); i > 0 {
			if n, ok := strconv.parse_int(dump[:i], 10); ok {win32.lock_dump_frame, win32.lock_dump_path = i64(n), dump[i + 1:]}
		}
	}
	native.settings_load()
	native.menu_online_init()
	hero := native.coop_hero_pick()
	if win32.net_on {
		hero = win32.net_connect(net_host, net_join, exe, native.settings_vals(), hero, net_open)
		if win32.net_settings != nil {native.settings_sync(win32.net_settings)}
	}
	native.settings_boot()
	native.dodge_init()
	native.coop_hero_init(hero)
	win32.font_hd_init()
	win32.tex_hd_init()
	win32.boot(exe)
	fmt.eprintln("entry point returned")
}

// The game dir and exe from the command line, filled in as main describes
// and made absolute; exits when no usable exe is found.
game_paths :: proc() -> (game, exe: string) {
	if len(os.args) > 1 {
		game = os.args[1]
	} else {
		self, err := os.get_executable_path(context.temp_allocator)
		if err != nil {
			fmt.eprintfln("cannot find jade's own folder: %v", err)
			os.exit(1)
		}
		game = filepath.dir(self)
	}
	if len(os.args) > 2 {
		exe = os.args[2]
	} else {
		ok: bool
		exe, ok = win32.exe_find(game, context.temp_allocator)
		if !ok do os.exit(1)
	}
	return absolute(game), absolute(exe)
}

// path made absolute, or path when it cannot be.
absolute :: proc(path: string) -> string {
	abs, err := os.get_absolute_path(path, context.allocator)
	return err == nil ? abs : path
}

// The line bug reports quote (the first of every log): the build ID online
// peers compare (docs/hle.md §11), the target and the net protocol version.
print_version :: proc() {
	id := win32.JE_BUILD_ID if win32.JE_BUILD_ID != "" else "none"
	fmt.eprintfln("jade: build %s (%v, %s), net protocol %d", id, ODIN_OS, ODIN_MICROARCH_STRING, win32.NET_VERSION)
}
