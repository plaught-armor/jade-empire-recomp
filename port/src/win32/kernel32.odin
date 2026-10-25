// kernel32 HLE: process, memory, time and locale services the CRT and game
// need. Every proc is stdcall: it reads its args with arg() and pops them in ret().
package win32

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf16"
import "../x86"

KERNEL32 := [?]Hle_Entry {
	{"kernel32.dll!GetVersionExA", GetVersionExA},
	{"kernel32.dll!GetModuleHandleA", GetModuleHandleA},
	{"kernel32.dll!LoadLibraryA", LoadLibraryA},
	{"kernel32.dll!GetProcAddress", GetProcAddress},
	{"kernel32.dll!GetModuleFileNameA", GetModuleFileNameA},
	{"kernel32.dll!GetCommandLineA", GetCommandLineA},
	{"kernel32.dll!GetStartupInfoA", GetStartupInfoA},
	{"kernel32.dll!GetEnvironmentStrings", GetEnvironmentStrings},
	{"kernel32.dll!GetEnvironmentStringsW", GetEnvironmentStringsW},
	{"kernel32.dll!FreeEnvironmentStringsA", ret1_1},
	{"kernel32.dll!FreeEnvironmentStringsW", ret1_1},
	{"kernel32.dll!SetEnvironmentVariableA", ret1_2},
	{"kernel32.dll!HeapCreate", HeapCreate},
	{"kernel32.dll!HeapDestroy", ret1_1},
	{"kernel32.dll!HeapAlloc", HeapAlloc},
	{"kernel32.dll!HeapFree", HeapFree},
	{"kernel32.dll!HeapReAlloc", HeapReAlloc},
	{"kernel32.dll!HeapSize", HeapSize},
	{"kernel32.dll!VirtualAlloc", VirtualAlloc},
	{"kernel32.dll!VirtualFree", ret1_3},
	{"kernel32.dll!VirtualQuery", VirtualQuery},
	{"kernel32.dll!VirtualProtect", VirtualProtect},
	{"kernel32.dll!LocalFree", LocalFree},
	{"kernel32.dll!GetSystemInfo", GetSystemInfo},
	{"kernel32.dll!GlobalMemoryStatus", GlobalMemoryStatus},
	{"kernel32.dll!GetStdHandle", GetStdHandle},
	{"kernel32.dll!SetStdHandle", ret1_2},
	{"kernel32.dll!GetFileType", GetFileType},
	{"kernel32.dll!SetHandleCount", SetHandleCount},
	{"kernel32.dll!GetLastError", GetLastError},
	{"kernel32.dll!SetLastError", SetLastError},
	{"kernel32.dll!InitializeCriticalSection", ret0_1},
	{"kernel32.dll!EnterCriticalSection", ret0_1},
	{"kernel32.dll!LeaveCriticalSection", ret0_1},
	{"kernel32.dll!DeleteCriticalSection", ret0_1},
	{"kernel32.dll!InterlockedExchange", InterlockedExchange},
	{"kernel32.dll!IsBadReadPtr", ret0_2},
	{"kernel32.dll!IsBadWritePtr", ret0_2},
	{"kernel32.dll!IsBadCodePtr", ret0_1},
	{"kernel32.dll!SetUnhandledExceptionFilter", ret0_1},
	{"kernel32.dll!GetCurrentProcess", GetCurrentProcess},
	{"kernel32.dll!GetCurrentThread", GetCurrentThread},
	{"kernel32.dll!GetCurrentProcessId", GetCurrentProcessId},
	{"kernel32.dll!GetCurrentThreadId", GetCurrentProcessId},
	{"kernel32.dll!GetProcessAffinityMask", GetProcessAffinityMask},
	{"kernel32.dll!SetProcessAffinityMask", ret1_2},
	{"kernel32.dll!ExitProcess", ExitProcess},
	{"kernel32.dll!TerminateProcess", TerminateProcess},
	{"kernel32.dll!GetTickCount", GetTickCount},
	{"kernel32.dll!QueryPerformanceFrequency", QueryPerformanceFrequency},
	{"kernel32.dll!QueryPerformanceCounter", QueryPerformanceCounter},
	{"kernel32.dll!GetSystemTimeAsFileTime", GetSystemTimeAsFileTime},
	{"kernel32.dll!GetLocalTime", GetSystemTime},
	{"kernel32.dll!GetSystemTime", GetSystemTime},
	{"kernel32.dll!Sleep", Sleep},
	{"kernel32.dll!OutputDebugStringA", OutputDebugStringA},
	{"kernel32.dll!GetACP", GetACP},
	{"kernel32.dll!GetOEMCP", GetOEMCP},
	{"kernel32.dll!GetCPInfo", GetCPInfo},
	{"kernel32.dll!MultiByteToWideChar", MultiByteToWideChar},
	{"kernel32.dll!WideCharToMultiByte", WideCharToMultiByte},
	{"kernel32.dll!GetStringTypeA", GetStringTypeA},
	{"kernel32.dll!GetStringTypeW", GetStringTypeW},
	{"kernel32.dll!LCMapStringA", LCMapStringA},
	{"kernel32.dll!LCMapStringW", LCMapStringW},
	{"kernel32.dll!GetCurrentDirectoryA", GetCurrentDirectoryA},
	{"kernel32.dll!SetCurrentDirectoryA", ret1_1},
}

ret0_1 :: proc() {ret(1, 0)}
ret0_2 :: proc() {ret(2, 0)}
ret1_1 :: proc() {ret(1, 1)}
ret1_2 :: proc() {ret(2, 1)}
ret1_3 :: proc() {ret(3, 1)}

// Guest-visible location of the game. The host side is the process's working
// directory, set by main to the game folder.
GAME_DIR :: `C:\Jade Empire`
EXE_PATH :: GAME_DIR + `\JadeEmpire.exe`

IMAGE_BASE :: 0x400000
MODULE_BASE :: 0x70000000 // module i is MODULE_BASE + i * 0x10000

modules: [dynamic]string

GetVersionExA :: proc() {
	p := arg(0)
	// Windows XP SP2, the newest version the game was tested on.
	x86.wr32(p + 4, 5)
	x86.wr32(p + 8, 1)
	x86.wr32(p + 12, 2600)
	x86.wr32(p + 16, 2)
	x86.mem_zero(p + 20, 128)
	ret(1, 1)
}

module_handle :: proc(name: string) -> u32 {
	n := strings.to_lower(name, context.temp_allocator)
	if i := strings.last_index_any(n, `\/`); i >= 0 {
		n = n[i + 1:]
	}
	if !strings.contains_rune(n, '.') {
		n = strings.concatenate({n, ".dll"}, context.temp_allocator)
	}
	if n == "jadeempire.exe" {
		return IMAGE_BASE
	}
	for m, i in modules {
		if m == n {
			return MODULE_BASE + u32(i) * 0x10000
		}
	}
	append(&modules, strings.clone(n))
	return MODULE_BASE + u32(len(modules) - 1) * 0x10000
}

GetModuleHandleA :: proc() {
	p := arg(0)
	ret(1, p == 0 ? IMAGE_BASE : module_handle(x86.cstr(p)))
}

LoadLibraryA :: proc() {
	ret(1, module_handle(x86.cstr(arg(0))))
}

// Only imports with an implementation resolve; others return 0 so the CRT
// takes its fallback path.
GetProcAddress :: proc() {
	h, p := arg(0), arg(1)
	k := (h - MODULE_BASE) / 0x10000
	if h < MODULE_BASE || int(k) >= len(modules) {
		ret(2, 0)
		return
	}
	name := p < 0x10000 ? fmt.tprintf("%s!#%d", modules[k], p) : fmt.tprintf("%s!%s", modules[k], x86.cstr(p))
	addr, ok := hle_bind(strings.clone(name))
	ret(2, ok ? addr : 0)
}

put_str :: proc(buf, n: u32, s: string) -> u32 {
	if n == 0 {
		return 0
	}
	k := min(u32(len(s)), n - 1)
	copy(x86.mem[buf:buf + k], s[:k])
	x86.wr8(buf + k, 0)
	return k
}

GetModuleFileNameA :: proc() {
	ret(3, put_str(arg(1), arg(2), EXE_PATH))
}

GetCurrentDirectoryA :: proc() {
	n, buf := arg(0), arg(1)
	if n <= u32(len(GAME_DIR)) {
		ret(2, u32(len(GAME_DIR)) + 1)
		return
	}
	ret(2, put_str(buf, n, GAME_DIR))
}

cmdline: u32
GetCommandLineA :: proc() {
	if cmdline == 0 {
		cmdline = heap_str(`"` + EXE_PATH + `"`)
	}
	ret(0, cmdline)
}

GetStartupInfoA :: proc() {
	p := arg(0)
	x86.mem_zero(p, 68)
	x86.wr32(p, 68)
	ret(1, 0)
}

env_a, env_w: u32
GetEnvironmentStrings :: proc() {
	if env_a == 0 {
		env_a = heap_alloc(2, true)
	}
	ret(0, env_a)
}

GetEnvironmentStringsW :: proc() {
	if env_w == 0 {
		env_w = heap_alloc(4, true)
	}
	ret(0, env_w)
}

HEAP_HANDLE :: 0x00ee0000
HEAP_ZERO_MEMORY :: 0x8

HeapCreate :: proc() {ret(3, HEAP_HANDLE)}
HeapAlloc :: proc() {ret(3, heap_alloc(arg(2), arg(1) & HEAP_ZERO_MEMORY != 0))}
HeapFree :: proc() {heap_free(arg(2)); ret(3, 1)}
HeapReAlloc :: proc() {ret(4, heap_realloc(arg(2), arg(3), arg(1) & HEAP_ZERO_MEMORY != 0))}
HeapSize :: proc() {ret(3, heap_size(arg(2)))}
LocalFree :: proc() {ret(1, 0)}

VA_LO :: 0x80000000
VA_HI :: 0xf0000000
va_top: u32 = VA_LO

// Play's reservations from VA_PLAY up, as heap_play.
VA_PLAY :: 0xb0000000

va_play :: proc() {
	if va_top > VA_PLAY {x86.fatal("VirtualAlloc: %08x in use before play, past %08x", va_top, VA_PLAY)}
	va_top = VA_PLAY
}

// Reservations come from a bump region; commit of an address already handed
// out returns it unchanged. Memory is never released.
VirtualAlloc :: proc() {
	addr, size := arg(0), arg(1)
	if addr != 0 {
		if addr >= VA_LO && addr + size <= va_top {
			ret(4, addr)
			return
		}
		x86.fatal("VirtualAlloc at fixed address %08x", addr)
	}
	sz := (size + 0xffff) &~ 0xffff
	if va_top + sz > VA_HI {
		last_error = 8 // ERROR_NOT_ENOUGH_MEMORY
		ret(4, 0)
		return
	}
	p := va_top
	va_top += sz
	ret(4, p)
}

VirtualQuery :: proc() {
	a, buf := arg(0), arg(1)
	page := a &~ 0xfff
	x86.wr32(buf, page)
	x86.wr32(buf + 4, page)
	x86.wr32(buf + 8, 0x04)       // PAGE_READWRITE
	x86.wr32(buf + 12, 0x1000)
	x86.wr32(buf + 16, 0x1000)    // MEM_COMMIT
	x86.wr32(buf + 20, 0x04)
	x86.wr32(buf + 24, 0x20000)   // MEM_PRIVATE
	ret(3, 28)
}

VirtualProtect :: proc() {
	old := arg(3)
	if old != 0 {
		x86.wr32(old, 0x04)
	}
	ret(4, 1)
}

GetSystemInfo :: proc() {
	p := arg(0)
	x86.mem_zero(p, 36)
	x86.wr32(p + 4, 0x1000)
	x86.wr32(p + 8, 0x10000)
	x86.wr32(p + 12, 0x7ffeffff)
	x86.wr32(p + 16, 1)
	x86.wr32(p + 20, 1)
	x86.wr32(p + 24, 586)
	x86.wr32(p + 28, 0x10000)
	x86.wr16(p + 32, 6)
	ret(1, 0)
}

GlobalMemoryStatus :: proc() {
	p := arg(0)
	x86.wr32(p, 32)
	x86.wr32(p + 4, 10)
	x86.wr32(p + 8, 0x7fff0000)   // physical total
	x86.wr32(p + 12, 0x60000000)  // physical free
	x86.wr32(p + 16, 0x7fff0000)
	x86.wr32(p + 20, 0x60000000)
	x86.wr32(p + 24, 0x7ffe0000)  // virtual total
	x86.wr32(p + 28, 0x60000000)
	ret(1, 0)
}

STD_INPUT :: 0xfffffff6
STD_ERROR :: 0xfffffff4

GetStdHandle :: proc() {ret(1, arg(0))}

GetFileType :: proc() {
	h := arg(0)
	ret(1, h >= STD_ERROR && h <= STD_INPUT ? 2 : 1) // FILE_TYPE_CHAR : FILE_TYPE_DISK
}

SetHandleCount :: proc() {ret(1, arg(0))}
GetLastError :: proc() {ret(0, last_error)}
SetLastError :: proc() {last_error = arg(0); ret(1, 0)}

InterlockedExchange :: proc() {
	p := arg(0)
	old := x86.rd32(p)
	x86.wr32(p, arg(1))
	ret(2, old)
}

GetCurrentProcess :: proc() {ret(0, 0xffffffff)}
GetCurrentThread :: proc() {ret(0, 0xfffffffe)}
GetCurrentProcessId :: proc() {ret(0, 0x1000)}

GetProcessAffinityMask :: proc() {
	x86.wr32(arg(1), 1)
	x86.wr32(arg(2), 1)
	ret(3, 1)
}

ExitProcess :: proc() {
	fmt.eprintf("win32: ExitProcess(%d)\n", arg(0))
	game_exit(int(arg(0)))
}

TerminateProcess :: proc() {
	fmt.eprintf("win32: TerminateProcess(%d)\n", arg(1))
	game_exit(int(arg(1)))
}

start_tick: time.Tick

// The game's clock: real time since boot, except that it runs at
// CLOCK_SLOW_RATE until clock_slow_to (host time since boot), the port's hit
// stop (native/pace.odin). Never at 0, so no frame has a zero time step.
CLOCK_SLOW_RATE :: 0.08
@(private = "file")
Game_Clock :: struct {
	game, real:    time.Duration, // the game time at host time real
	slow_to:       time.Duration,
}
@(private = "file")
gclock: Game_Clock

game_clock :: proc() -> time.Duration {
	now := host_now()
	if now <= gclock.real {return gclock.game}
	span := now - gclock.real
	slow := clamp(gclock.slow_to - gclock.real, 0, span)
	gclock.game += span - slow + time.Duration(f64(slow) * CLOCK_SLOW_RATE)
	gclock.real = now
	return gclock.game
}

// Slows the game clock for d of host time from now; a slow already running
// ends at the later of the two.
clock_slow :: proc(d: time.Duration) {
	game_clock()
	gclock.slow_to = max(gclock.slow_to, gclock.real + d)
}

GetTickCount :: proc() {
	clock_read()
	ret(0, u32(time.duration_milliseconds(game_clock())))
}

QPC_HZ :: 10_000_000

QueryPerformanceFrequency :: proc() {
	x86.wr64(arg(0), QPC_HZ)
	ret(1, 1)
}

QueryPerformanceCounter :: proc() {
	clock_read()
	x86.wr64(arg(0), u64(game_clock()) / 100)
	ret(1, 1)
}

// 100 ns ticks between 1601-01-01 and 1970-01-01.
FILETIME_UNIX :: 116444736000000000

GetSystemTimeAsFileTime :: proc() {
	x86.wr64(arg(0), u64(wall_now() / 100) + FILETIME_UNIX)
	ret(1, 0)
}

GetSystemTime :: proc() {
	p := arg(0)
	t := time.unix(0, wall_now())
	y, mon, d := time.date(t)
	h, mi, s := time.clock(t)
	x86.wr16(p, u16(y))
	x86.wr16(p + 2, u16(mon))
	x86.wr16(p + 4, u16(time.weekday(t)))
	x86.wr16(p + 6, u16(d))
	x86.wr16(p + 8, u16(h))
	x86.wr16(p + 10, u16(mi))
	x86.wr16(p + 12, u16(s))
	x86.wr16(p + 14, 0)
	ret(1, 0)
}

// Sleep call sites that only throttle and are skipped: their return
// addresses. 0x4af8ca: the area-load loop FUN_004af6a0 sleeps 10 ms after
// each streamed resource (about 300 per area, 3 s of a 6 s load).
// 0x4a4f13: after a save, the loop at 0x4a4ee0 redraws the save message 17
// times with a sleep of (3000 ms - save time) / 17 each. 0x4a4cc1 and
// 0x4a4f67 (in-game save), 0x556374 and 0x556579 (save screen): 250 ms after
// pausing the audio and 50 ms after resuming it, around every save.
// WHY: docs/hle.md §2
SLEEP_ELIDE := [?]u32{0x4af8ca, 0x4a4f13, 0x556533, 0x4a4cc1, 0x4a4f67, 0x556374, 0x556579}

Sleep :: proc() {
	ra := x86.rd32(x86.cpu.esp)
	for a in SLEEP_ELIDE {
		if a == ra {ret(1, 0); return}
	}
	d := time.Duration(arg(0)) * time.Millisecond
	if lockstep {vclock += d} else {time.sleep(d)}
	ret(1, 0)
}

// debug_bt: JE_CTL `dbgbt TEXT`; debug output containing TEXT also logs the guest stack.
debug_bt: string

OutputDebugStringA :: proc() {
	s := x86.cstr(arg(0))
	fmt.eprintf("debug: %s", s)
	if debug_bt != "" && strings.contains(s, debug_bt) {x86.print_guest_returns()}
	ret(1, 0)
}

GetACP :: proc() {ret(0, 1252)}
GetOEMCP :: proc() {ret(0, 437)}

GetCPInfo :: proc() {
	p := arg(1)
	x86.mem_zero(p, 20)
	x86.wr32(p, 1)
	x86.wr8(p + 4, '?')
	ret(2, 1)
}

// Code page conversions: CP_UTF8 is UTF-8, every other code page is treated
// as Latin-1. The game converts text with CP_UTF8 (0x424519 and others), and
// dialog.tlk holds UTF-8 (fiancé, protégé); read as Latin-1 it showed "Ã©".
CP_UTF8 :: 65001

MultiByteToWideChar :: proc() {
	cp, src, n, dst, dn := arg(0), arg(2), arg(3), arg(4), arg(5)
	if n == 0xffffffff {
		n = u32(len(x86.cstr(src))) + 1
	}
	if cp != CP_UTF8 {
		if dn == 0 {
			ret(6, n)
			return
		}
		k := min(n, dn)
		for i in 0 ..< k {
			x86.wr16(dst + i * 2, u16(x86.rd8(src + i)))
		}
		ret(6, k)
		return
	}
	b := make([]u8, n, context.temp_allocator)
	for i in 0 ..< n {b[i] = x86.rd8(src + i)}
	w := make([]u16, n, context.temp_allocator)
	w = w[:utf16.encode_string(w, string(b))]
	if dn == 0 {
		ret(6, u32(len(w)))
		return
	}
	if u32(len(w)) > dn {
		ret(6, 0) // ERROR_INSUFFICIENT_BUFFER
		return
	}
	for u, i in w {x86.wr16(dst + u32(i) * 2, u)}
	ret(6, u32(len(w)))
}

wlen :: proc(p: u32) -> u32 {
	n: u32 = 0
	for x86.rd16(p + n * 2) != 0 {
		n += 1
		if n == x86.CSTR_MAX {
			x86.fatal("unterminated guest wide string at %08x", p)
		}
	}
	return n
}

WideCharToMultiByte :: proc() {
	cp, src, n, dst, dn, used := arg(0), arg(2), arg(3), arg(4), arg(5), arg(7)
	if n == 0xffffffff {
		n = wlen(src) + 1
	}
	if used != 0 {
		x86.wr32(used, 0)
	}
	if cp == CP_UTF8 {
		w := make([]u16, n, context.temp_allocator)
		for i in 0 ..< n {w[i] = x86.rd16(src + i * 2)}
		b := make([]u8, n * 3, context.temp_allocator)
		k := u32(utf16.decode_to_utf8(b, w))
		if dn == 0 {
			ret(8, k)
			return
		}
		if k > dn {
			ret(8, 0) // ERROR_INSUFFICIENT_BUFFER
			return
		}
		for i in 0 ..< k {x86.wr8(dst + i, b[i])}
		ret(8, k)
		return
	}
	if dn == 0 {
		ret(8, n)
		return
	}
	k := min(n, dn)
	for i in 0 ..< k {
		w := x86.rd16(src + i * 2)
		x86.wr8(dst + i, w < 0x100 ? u8(w) : '?')
	}
	ret(8, k)
}

// CT_CTYPE1 classification of a Latin-1 character.
ctype1 :: proc(ch: u32) -> u16 {
	t: u16 = 0
	switch {
	case ch >= 'A' && ch <= 'Z': t |= 0x1 | 0x100
	case ch >= 'a' && ch <= 'z': t |= 0x2 | 0x100
	case ch >= '0' && ch <= '9': t |= 0x4
	}
	if (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F') {t |= 0x80}
	if ch == ' ' || (ch >= 9 && ch <= 13) {t |= 0x8}
	if ch == ' ' || ch == 9 {t |= 0x40}
	if ch < 32 || ch == 127 {t |= 0x20}
	if ch > 32 && ch < 127 && t & (0x1 | 0x2 | 0x4) == 0 {t |= 0x10}
	return t
}

GetStringTypeA :: proc() {
	src, n, out := arg(2), arg(3), arg(4)
	if n == 0xffffffff {n = u32(len(x86.cstr(src))) + 1}
	for i in 0 ..< n {x86.wr16(out + i * 2, ctype1(u32(x86.rd8(src + i))))}
	ret(5, 1)
}

GetStringTypeW :: proc() {
	src, n, out := arg(1), arg(2), arg(3)
	if n == 0xffffffff {n = wlen(src) + 1}
	for i in 0 ..< n {x86.wr16(out + i * 2, ctype1(u32(x86.rd16(src + i * 2))))}
	ret(4, 1)
}

LCMAP_LOWERCASE :: 0x100
LCMAP_UPPERCASE :: 0x200

map_case :: proc(ch: u32, flags: u32) -> u32 {
	if flags & LCMAP_LOWERCASE != 0 && ch >= 'A' && ch <= 'Z' {return ch + 32}
	if flags & LCMAP_UPPERCASE != 0 && ch >= 'a' && ch <= 'z' {return ch - 32}
	return ch
}

LCMapStringA :: proc() {
	flags, src, n, dst, dn := arg(1), arg(2), arg(3), arg(4), arg(5)
	if n == 0xffffffff {n = u32(len(x86.cstr(src))) + 1}
	if dn == 0 {ret(6, n); return}
	k := min(n, dn)
	for i in 0 ..< k {x86.wr8(dst + i, u8(map_case(u32(x86.rd8(src + i)), flags)))}
	ret(6, k)
}

LCMapStringW :: proc() {
	flags, src, n, dst, dn := arg(1), arg(2), arg(3), arg(4), arg(5)
	if n == 0xffffffff {n = wlen(src) + 1}
	if dn == 0 {ret(6, n); return}
	k := min(n, dn)
	for i in 0 ..< k {x86.wr16(dst + i * 2, u16(map_case(u32(x86.rd16(src + i * 2)), flags)))}
	ret(6, k)
}
