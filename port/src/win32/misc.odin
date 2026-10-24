// Small services: kernel32 time/locale/compare extras, the registry (always
// empty), COM init, gamma, XInput (no pad) and dbghelp (crash reporting only).
package win32

import "core:fmt"
import "core:time"
import "../x86"

MISC := [?]Hle_Entry {
	{"kernel32.dll!GetLocaleInfoA", GetLocaleInfoA},
	{"kernel32.dll!GetTimeZoneInformation", GetTimeZoneInformation},
	{"kernel32.dll!CompareFileTime", CompareFileTime},
	{"kernel32.dll!SystemTimeToFileTime", SystemTimeToFileTime},
	{"kernel32.dll!FileTimeToSystemTime", FileTimeToSystemTime},
	{"kernel32.dll!SystemTimeToTzSpecificLocalTime", SystemTimeToTzSpecificLocalTime},
	{"kernel32.dll!CompareStringA", CompareStringA},
	{"kernel32.dll!CompareStringW", CompareStringW},
	{"kernel32.dll!FormatMessageA", FormatMessageA},
	{"kernel32.dll!RaiseException", RaiseException},
	{"kernel32.dll!UnhandledExceptionFilter", UnhandledExceptionFilter},
	{"kernel32.dll!RtlUnwind", RtlUnwind},
	{"kernel32.dll!DebugBreak", DebugBreak},
	{"advapi32.dll!RegOpenKeyExA", RegOpenKeyExA},
	{"advapi32.dll!RegCloseKey", ret0_1},
	{"ole32.dll!CoInitialize", ret0_1},
	{"gdi32.dll!SetDeviceGammaRamp", ret1_2},
	{"xinput9_1_0.dll!XInputSetState", XInputSetState},
	{"dbghelp.dll!SymSetOptions", ret0_1},
	{"dbghelp.dll!SymInitialize", ret0_3},
	{"dbghelp.dll!SymGetModuleInfo64", ret0_4},
	{"dbghelp.dll!SymGetLineFromAddr64", ret0_5},
	{"dbghelp.dll!SymGetModuleBase64", ret0_3},
	{"dbghelp.dll!SymFunctionTableAccess64", ret0_3},
	{"dbghelp.dll!StackWalk64", ret0_9},
}

ret0_3 :: proc() {ret(3, 0)}
ret0_4 :: proc() {ret(4, 0)}
ret0_5 :: proc() {ret(5, 0)}
ret0_9 :: proc() {ret(9, 0)}

// LOCALE_* values the CRT asks for, as the US English locale reports them.
GetLocaleInfoA :: proc() {
	kind, buf, n := arg(1), arg(2), arg(3)
	v: string
	switch kind & 0xffff {
	case 0x0b: v = "437"            // LOCALE_IDEFAULTCODEPAGE
	case 0x1004: v = "1252"         // LOCALE_IDEFAULTANSICODEPAGE
	case 0x01: v = "0409"           // LOCALE_ILANGUAGE
	case 0x1001: v = "English"      // LOCALE_SENGLANGUAGE
	case 0x1002: v = "United States"// LOCALE_SENGCOUNTRY
	case 0x03: v = "ENU"            // LOCALE_SABBREVLANGNAME
	case 0x07: v = "USA"            // LOCALE_SABBREVCTRYNAME
	case 0x0e: v = "."              // LOCALE_SDECIMAL
	case 0x0f: v = ","              // LOCALE_STHOUSAND
	case:
		last_error = 87 // ERROR_INVALID_PARAMETER
		ret(4, 0)
		return
	}
	if n == 0 {
		ret(4, u32(len(v)) + 1)
		return
	}
	ret(4, put_str(buf, n, v) + 1)
}

// UTC with no daylight saving: the guest's local time equals UTC.
GetTimeZoneInformation :: proc() {
	x86.mem_zero(arg(0), 172)
	ret(1, 0) // TIME_ZONE_ID_UNKNOWN
}

CompareFileTime :: proc() {
	a, b := x86.rd64(arg(0)), x86.rd64(arg(1))
	ret(2, a < b ? 0xffffffff : (a > b ? 1 : 0))
}

SystemTimeToFileTime :: proc() {
	st, ft := arg(0), arg(1)
	t, ok := time.datetime_to_time(
		i64(x86.rd16(st)), i8(x86.rd16(st + 2)), i8(x86.rd16(st + 6)),
		i8(x86.rd16(st + 8)), i8(x86.rd16(st + 10)), i8(x86.rd16(st + 12)),
		i32(x86.rd16(st + 14)) * 1_000_000,
	)
	if !ok {
		last_error = 87
		ret(2, 0)
		return
	}
	x86.wr64(ft, filetime(t))
	ret(2, 1)
}

FileTimeToSystemTime :: proc() {
	ft, st := arg(0), arg(1)
	ns := (i64(x86.rd64(ft)) - FILETIME_UNIX) * 100
	t := time.unix(0, ns)
	y, mon, d := time.date(t)
	h, mi, s := time.clock(t)
	x86.wr16(st, u16(y))
	x86.wr16(st + 2, u16(mon))
	x86.wr16(st + 4, u16(time.weekday(t)))
	x86.wr16(st + 6, u16(d))
	x86.wr16(st + 8, u16(h))
	x86.wr16(st + 10, u16(mi))
	x86.wr16(st + 12, u16(s))
	x86.wr16(st + 14, u16((ns / 1_000_000) % 1000))
	ret(2, 1)
}

SystemTimeToTzSpecificLocalTime :: proc() {
	copy(x86.mem[arg(2):arg(2) + 16], x86.mem[arg(1):arg(1) + 16])
	ret(3, 1)
}

NORM_IGNORECASE :: 1

// CSTR_LESS_THAN 1, CSTR_EQUAL 2, CSTR_GREATER_THAN 3, ordinal on Latin-1.
compare_units :: proc(a: u32, na: u32, b: u32, nb: u32, wide: bool, fold: bool) -> u32 {
	for i in 0 ..< min(na, nb) {
		x := wide ? u32(x86.rd16(a + i * 2)) : u32(x86.rd8(a + i))
		y := wide ? u32(x86.rd16(b + i * 2)) : u32(x86.rd8(b + i))
		if fold {
			x = map_case(x, LCMAP_LOWERCASE)
			y = map_case(y, LCMAP_LOWERCASE)
		}
		if x != y {
			return x < y ? 1 : 3
		}
	}
	return na < nb ? 1 : (na > nb ? 3 : 2)
}

CompareStringA :: proc() {
	flags, a, na, b, nb := arg(1), arg(2), arg(3), arg(4), arg(5)
	if na == 0xffffffff {na = u32(len(x86.cstr(a)))}
	if nb == 0xffffffff {nb = u32(len(x86.cstr(b)))}
	ret(6, compare_units(a, na, b, nb, false, flags & NORM_IGNORECASE != 0))
}

CompareStringW :: proc() {
	flags, a, na, b, nb := arg(1), arg(2), arg(3), arg(4), arg(5)
	if na == 0xffffffff {na = wlen(a)}
	if nb == 0xffffffff {nb = wlen(b)}
	ret(6, compare_units(a, na, b, nb, true, flags & NORM_IGNORECASE != 0))
}

FormatMessageA :: proc() {
	last_error = 317 // ERROR_MR_MID_NOT_FOUND
	ret(7, 0)
}

// SEH is not modelled yet: a raised exception is fatal with its code.
RaiseException :: proc() {
	x86.fatal("RaiseException code %08x flags %x nargs %d", arg(0), arg(1), arg(2))
}

UnhandledExceptionFilter :: proc() {
	x86.fatal("UnhandledExceptionFilter record %08x", x86.rd32(arg(0)))
}

RtlUnwind :: proc() {
	x86.fatal("RtlUnwind target frame %08x", arg(0))
}

DebugBreak :: proc() {
	x86.fatal("DebugBreak")
}


RegOpenKeyExA :: proc() {
	fmt.eprintf("win32: RegOpenKeyExA(%08x, %s): not found\n", arg(0), x86.cstr(arg(1)))
	ret(5, ERROR_FILE_NOT_FOUND)
}

