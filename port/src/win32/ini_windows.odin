package win32

import win "core:sys/windows"

// A file's last write time and size.
Ini_Stamp :: struct {
	mtime: win.FILETIME,
	size:  [2]u32,
}

ini_stamp :: proc(path: string) -> (Ini_Stamp, bool) {
	d: win.WIN32_FILE_ATTRIBUTE_DATA
	if !win.GetFileAttributesExW(win.utf8_to_wstring(path, context.temp_allocator), win.GetFileExInfoStandard, &d) {return {}, false}
	return {d.ftLastWriteTime, {d.nFileSizeLow, d.nFileSizeHigh}}, true
}
