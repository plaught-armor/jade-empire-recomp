// vorbisfile.dll on stb_vorbis. All six imports are cdecl. Open reads the
// whole stream through the guest read callback into host memory, then
// decodes from there; the guest seek/tell callbacks are not needed.
//
// The game reads OggVorbis_File.vi (offset 0x48) directly for channels (+4)
// and rate (+8), so open writes a guest vorbis_info there; ov_info is not
// imported. Host state is keyed by the guest OggVorbis_File address.
package win32

import "core:c"
import "core:fmt"
import "core:mem"
import "../x86"

// stb_vorbis built from src/win32/vorbis.c by build.sh (and for Windows by
// winlib/build.sh into winlib/lib), not Odin's prebuilt vendor:stb/vorbis: the decoded samples are
// guest state and must match across OSes.
// WHY: docs/hle.md §11
when ODIN_OS == .Windows {
	foreign import vorbis_lib "../../winlib/lib/vorbis.lib"
} else {
	foreign import vorbis_lib "../../build/libvorbis.a"
}

Stbv :: struct {}

Stbv_Info :: struct {
	sample_rate:                c.uint,
	channels:                   c.int,
	setup_memory_required:      c.uint,
	setup_temp_memory_required: c.uint,
	temp_memory_required:       c.uint,
	max_frame_size:             c.int,
}

@(default_calling_convention = "c")
foreign vorbis_lib {
	@(link_name = "stb_vorbis_open_memory")
	stbv_open_memory :: proc(data: [^]u8, len: c.int, error: ^c.int, alloc_buffer: rawptr) -> ^Stbv ---
	@(link_name = "stb_vorbis_get_info")
	stbv_get_info :: proc(f: ^Stbv) -> Stbv_Info ---
	@(link_name = "stb_vorbis_close")
	stbv_close :: proc(f: ^Stbv) ---
	@(link_name = "stb_vorbis_stream_length_in_samples")
	stbv_stream_length_in_samples :: proc(f: ^Stbv) -> c.uint ---
	@(link_name = "stb_vorbis_seek")
	stbv_seek :: proc(f: ^Stbv, sample_number: c.uint) -> c.int ---
	@(link_name = "stb_vorbis_get_samples_short_interleaved")
	stbv_get_samples_short_interleaved :: proc(f: ^Stbv, channels: c.int, buffer: [^]c.short, num_shorts: c.int) -> c.int ---
}

// vorbis.c's sin and cos.
@(export, link_name = "je_vorbis_sin")
vorbis_sin :: proc "c" (x: f64) -> f64 {return x86.sin_f64(x)}

@(export, link_name = "je_vorbis_cos")
vorbis_cos :: proc "c" (x: f64) -> f64 {return x86.cos_f64(x)}

VORBIS := [?]Hle_Entry {
	{"vorbisfile.dll!ov_test_callbacks", ov_test_callbacks},
	{"vorbisfile.dll!ov_test_open", ov_test_open},
	{"vorbisfile.dll!ov_pcm_total", ov_pcm_total},
	{"vorbisfile.dll!ov_clear", ov_clear},
	{"vorbisfile.dll!ov_read", ov_read},
	{"vorbisfile.dll!ov_pcm_seek", ov_pcm_seek},
}

OV_EINVAL :: -131
OV_ENOTVORBIS :: -132
OV_VF_VI :: 0x48 // OggVorbis_File.vi
OV_VI_SIZE :: 32 // vorbis_info: version, channels, rate, bitrate x3, bitrate_window, codec_setup
OV_READ_CHUNK :: 0x10000
OV_FILE_MAX :: 0x10000000

Ov_File :: struct {
	v:        ^Stbv,
	data:     []u8,
	ch:       u32,
	ds:       u32, // guest datasource
	close_fn: u32, // guest close callback, 0 if none
	vi:       u32, // guest vorbis_info
}

ov_files: map[u32]Ov_File

ov_of :: proc(vf: u32) -> ^Ov_File {
	f, ok := &ov_files[vf]
	if !ok {x86.fatal("vorbisfile: OggVorbis_File %08x not open", vf)}
	return f
}

// Drains the guest read callback: size_t read(void *ptr, size_t size, size_t nmemb, void *ds).
ov_slurp :: proc(read_fn, ds, initial, ibytes: u32) -> []u8 {
	buf := make([dynamic]u8)
	if ibytes != 0 {append(&buf, ..([^]u8)(x86.ptr(initial))[:ibytes])}
	tmp := heap_alloc(OV_READ_CHUNK, false)
	for _ in 0 ..< OV_FILE_MAX / OV_READ_CHUNK {
		n := guest_call_c(read_fn, tmp, 1, OV_READ_CHUNK, ds)
		if n == 0 {
			heap_free(tmp)
			return buf[:]
		}
		if n > OV_READ_CHUNK {x86.fatal("vorbisfile: read callback returned %d", n)}
		append(&buf, ..([^]u8)(x86.ptr(tmp))[:n])
	}
	x86.fatal("vorbisfile: stream over %d bytes", OV_FILE_MAX)
}

// int ov_test_callbacks(void *ds, OggVorbis_File *vf, char *initial, long ibytes, ov_callbacks cb)
ov_test_callbacks :: proc() {
	ds, vf, initial, ibytes := arg(0), arg(1), arg(2), arg(3)
	read_fn, close_fn := arg(4), arg(6)
	if _, open := ov_files[vf]; open {ov_drop_reopened(vf)}
	data := ov_slurp(read_fn, ds, initial, ibytes)
	err: c.int
	v := stbv_open_memory(raw_data(data), i32(len(data)), &err, nil)
	if v == nil {
		delete(data)
		ret(0, transmute(u32)i32(OV_ENOTVORBIS))
		return
	}
	info := stbv_get_info(v)
	vi := heap_alloc(OV_VI_SIZE, true)
	x86.wr32(vi + 4, u32(info.channels))
	x86.wr32(vi + 8, u32(info.sample_rate))
	x86.wr32(vf, ds)
	x86.wr32(vf + OV_VF_VI, vi)
	ov_files[vf] = {v = v, data = data, ch = u32(info.channels), ds = ds, close_fn = close_fn, vi = vi}
	ret(0, 0)
}

// The game reopens a stream's OggVorbis_File without ov_clear on area
// transitions. Real vorbisfile memsets vf and leaks the old stream without
// calling its close callback; match that, but free the host-side copy.
// WHY: docs/hle.md §7
ov_drop_reopened :: proc(vf: u32) {
	f := ov_files[vf]
	fmt.eprintf("vorbisfile: %08x reopened without ov_clear; old stream dropped\n", vf)
	stbv_close(f.v)
	delete(f.data)
	heap_free(f.vi)
	delete_key(&ov_files, vf)
}

ov_test_open :: proc() {
	_ = ov_of(arg(0))
	ret(0, 0)
}

// ogg_int64_t ov_pcm_total(OggVorbis_File *vf, int i); i = -1: whole stream.
ov_pcm_total :: proc() {
	f, i := ov_of(arg(0)), i32(arg(1))
	if i > 0 {
		x86.cpu.edx = 0xffffffff
		ret(0, transmute(u32)i32(OV_EINVAL))
		return
	}
	x86.cpu.edx = 0
	ret(0, u32(stbv_stream_length_in_samples(f.v)))
}

// int ov_pcm_seek(OggVorbis_File *vf, ogg_int64_t pos)
ov_pcm_seek :: proc() {
	f, lo, hi := ov_of(arg(0)), arg(1), arg(2)
	if hi != 0 || lo > u32(stbv_stream_length_in_samples(f.v)) || stbv_seek(f.v, lo) == 0 {
		ret(0, transmute(u32)i32(OV_EINVAL))
		return
	}
	ret(0, 0)
}

// long ov_read(OggVorbis_File *vf, char *buf, int len, int bigendian, int word, int sgned, int *bitstream)
ov_read :: proc() {
	f, buf, n, big, word, sgned, bs := ov_of(arg(0)), arg(1), arg(2), arg(3), arg(4), arg(5), arg(6)
	if big != 0 || word != 2 || sgned != 1 {x86.fatal("ov_read: bigendian %d, word %d, signed %d", big, word, sgned)}
	shorts := n / 2 / f.ch * f.ch
	got := stbv_get_samples_short_interleaved(f.v, i32(f.ch), ([^]i16)(x86.ptr(buf)), i32(shorts))
	if bs != 0 {x86.wr32(bs, 0)}
	ret(0, u32(got) * f.ch * 2)
}

ov_clear :: proc() {
	vf := arg(0)
	f := ov_of(vf)
	stbv_close(f.v)
	delete(f.data)
	heap_free(f.vi)
	if f.close_fn != 0 {guest_call_c(f.close_fn, f.ds)}
	delete_key(&ov_files, vf)
	mem.zero(x86.ptr(vf + OV_VF_VI), 4)
	ret(0, 0)
}
