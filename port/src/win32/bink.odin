// binkw32.dll on FFmpeg (movie.c). The game's player (0x67e420 .. 0x6800f0)
// opens a movie, creates a managed texture of its size, and per frame calls
// BinkWait, then BinkDoFrame and BinkCopyToBuffer into the locked texture,
// then BinkNextFrame. With render scaling on, the texture's GL storage is
// rt_scale times its size and CopyToBuffer writes a Lanczos-scaled frame
// straight into it.
// WHY: docs/hle.md §4
package win32

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"
import "../x86"

// On Windows the FFmpeg import libraries come from build/ffmpeg-win
// (build_windows.sh) and its DLLs ship beside jade.exe.
when ODIN_OS == .Windows {
	foreign import movie_lib {
		"../../build/win/movie.lib",
		"../../build/ffmpeg-win/lib/avformat.lib",
		"../../build/ffmpeg-win/lib/avcodec.lib",
		"../../build/ffmpeg-win/lib/swscale.lib",
		"../../build/ffmpeg-win/lib/swresample.lib",
		"../../build/ffmpeg-win/lib/avutil.lib",
	}
} else {
	foreign import movie_lib {
		"../../build/libmovie.a",
		"system:avformat",
		"system:avcodec",
		"system:swscale",
		"system:swresample",
		"system:avutil",
	}
}

Movie :: struct {}

Movie_Info :: struct {
	w, h, frames, fps_num, fps_den, rate, channels: i32,
}

@(default_calling_convention = "c")
foreign movie_lib {
	movie_open :: proc(path: cstring, audio: c.int, info: ^Movie_Info) -> ^Movie ---
	movie_close :: proc(m: ^Movie) ---
	movie_decode :: proc(m: ^Movie) -> c.int ---
	movie_copy :: proc(m: ^Movie, dst: rawptr, pitch, w, h, fmt: c.int) -> c.int ---
	movie_rewind :: proc(m: ^Movie) -> c.int ---
	movie_audio :: proc(m: ^Movie, data: ^[^]f32) -> c.int ---
	movie_error :: proc() -> cstring ---
}

BINK := [?]Hle_Entry {
	{"binkw32.dll!_BinkSetSoundSystem@8", proc() {ret(2, 1)}},
	{"binkw32.dll!_BinkOpenDirectSound@4", proc() {ret(1, 0)}},
	{"binkw32.dll!_BinkSetSoundTrack@8", proc() {ret(2, 0)}},
	{"binkw32.dll!_BinkOpen@8", Bink_Open},
	{"binkw32.dll!_BinkGetError@0", Bink_GetError},
	{"binkw32.dll!_BinkClose@4", Bink_Close},
	{"binkw32.dll!_BinkSetVolume@12", Bink_SetVolume},
	{"binkw32.dll!_BinkDoFrame@4", Bink_DoFrame},
	{"binkw32.dll!_BinkWait@4", Bink_Wait},
	{"binkw32.dll!_BinkNextFrame@4", Bink_NextFrame},
	{"binkw32.dll!_BinkPause@8", Bink_Pause},
	{"binkw32.dll!_BinkDX9SurfaceType@4", Bink_DX9SurfaceType},
	{"binkw32.dll!_BinkCopyToBuffer@28", Bink_CopyToBuffer},
}

// Guest BINK struct: the fields the game reads, in a zeroed block.
BINK_W :: 0x00
BINK_H :: 0x04
BINK_FRAMES :: 0x08
BINK_FRAME_NUM :: 0x0c // 1-based number of the current frame
BINK_LAST_FRAME :: 0x10
BINK_FPS_NUM :: 0x14
BINK_FPS_DEN :: 0x18
BINK_SIZE :: 0x200

// Frames a movies_hd replacement may differ from its .bik by: Matroska stores
// no frame count, so movie_open estimates it from the container duration.
// WHY: docs/hle.md §4
HD_FRAMES_SLACK :: 1

BINKSNDTRACK :: 0x4000 // BinkOpen flag: the game passes it with SetSoundTrack(0, 0) under NoSound

// BinkDX9SurfaceType codes, accepted back in BinkCopyToBuffer flags. Nonzero:
// the game replaces 0 by its own default type.
Bink_Fmt :: enum u32 {BGRA = 1, RGB565, RGB555}
BINK_FMT_BYTES := [Bink_Fmt]u32 {.BGRA = 4, .RGB565 = 2, .RGB555 = 2}

Bink :: struct {
	obj:      u32, // guest BINK struct
	m:        ^Movie,
	info:     Movie_Info,
	start_ns: u64, // wall time at which frame 1 is due
	pause_ns: u64, // when paused: the time of the pause; 0 when playing
	audio:    ^sdl.AudioStream, // nil without sound
	bound:    bool, // audio is bound to the device (unbound while paused)
}

binks: [dynamic]Bink

// The movie texture, by resource id and object; stale once the game releases it.
Bink_Target :: struct {
	id, obj: u32,
}

bink_err: u32 // guest error string
bink_tex: Bink_Target // the texture last found as a CopyToBuffer target
bink_up: []u8 // the scaled frame, before upload

bink_of :: proc(obj: u32) -> int {
	for b, i in binks {
		if b.obj == obj {return i}
	}
	x86.fatal("binkw32: unknown handle %08x", obj)
}

bink_set_error :: proc(s: string) {
	heap_free(bink_err)
	bink_err = heap_alloc(u32(len(s)) + 1, true)
	copy(([^]u8)(x86.ptr(bink_err))[:len(s)], s)
}

// BinkOpen(name, flags) -> HBINK or 0. A file that does not open fails with
// "Error opening file.", which makes the game retry under HD0:MOVIES and then
// skip the movie. A replacement movies_hd/<name>.mkv, when present, is played
// in its place (bink_hd).
Bink_Open :: proc() {
	name, flags := x86.cstr(arg(0)), arg(1)
	path := host_path(name)
	b := Bink{}
	audio := flags & BINKSNDTRACK == 0 && ds_stream != nil
	b.m = movie_open(strings.clone_to_cstring(path, context.temp_allocator), c.int(audio), &b.info)
	if b.m == nil {
		fmt.eprintfln("bink: %s (%s): %s", name, path, movie_error())
		bink_set_error("Error opening file.")
		ret(2, 0)
		return
	}
	bink_hd(&b, name, audio)
	if audio && b.info.rate > 0 {bink_audio_open(&b)}
	b.obj = heap_alloc(BINK_SIZE, true)
	x86.wr32(b.obj + BINK_W, u32(b.info.w))
	x86.wr32(b.obj + BINK_H, u32(b.info.h))
	x86.wr32(b.obj + BINK_FRAMES, u32(b.info.frames))
	x86.wr32(b.obj + BINK_FRAME_NUM, 1)
	x86.wr32(b.obj + BINK_FPS_NUM, u32(b.info.fps_num))
	x86.wr32(b.obj + BINK_FPS_DEN, u32(b.info.fps_den))
	b.start_ns = bink_now()
	append(&binks, b)
	bink_set_error("")
	fmt.eprintfln("bink: open %s %dx%d, %d frames", name, b.info.w, b.info.h, b.info.frames)
	ret(2, b.obj)
}

// Swaps in movies_hd/<name>.mkv (tools/upscale_movies.py) for the movie's
// decoding. The guest sees the .bik header: the game sizes its texture and
// timing from it, and CopyToBuffer scales the HD frame to whatever it fills.
// WHY: docs/hle.md §4
bink_hd :: proc(b: ^Bink, name: string, audio: bool) {
	base := name[strings.last_index_any(name, `\/`) + 1:]
	if dot := strings.last_index_byte(base, '.'); dot >= 0 {base = base[:dot]}
	path := host_path(strings.concatenate({`MOVIES_HD\`, base, ".mkv"}, context.temp_allocator))
	if !os.exists(path) {return}
	hi: Movie_Info
	m := movie_open(strings.clone_to_cstring(path, context.temp_allocator), c.int(audio), &hi)
	if m == nil {x86.fatal("bink: %s: %s", path, movie_error())}
	if i64(hi.w) * i64(b.info.h) != i64(hi.h) * i64(b.info.w) {
		x86.fatal("bink: %s is %dx%d, not the shape of %dx%d", path, hi.w, hi.h, b.info.w, b.info.h)
	}
	if abs(hi.frames - b.info.frames) > HD_FRAMES_SLACK {
		x86.fatal("bink: %s has %d frames, not the %d of the .bik", path, hi.frames, b.info.frames)
	}
	movie_close(b.m)
	b.m = m
	b.info.rate, b.info.channels = hi.rate, hi.channels
}

bink_audio_open :: proc(b: ^Bink) {
	src := sdl.AudioSpec{format = .F32, channels = 2, freq = b.info.rate}
	dst := sdl.AudioSpec{format = .F32, channels = 2, freq = DS_RATE}
	b.audio = sdl.CreateAudioStream(&src, &dst)
	if b.audio == nil {x86.fatal("bink: audio stream: %s", sdl.GetError())}
	if !sdl.BindAudioStream(ds_dev, b.audio) {
		x86.fatal("bink: bind audio stream: %s", sdl.GetError())
	}
	b.bound = true
}

// BinkGetError() -> the last error string: "" until an open fails, and
// again after one succeeds.
Bink_GetError :: proc() {
	if bink_err == 0 {bink_set_error("")}
	ret(0, bink_err)
}

Bink_Close :: proc() {
	i := bink_of(arg(0))
	b := binks[i]
	fmt.eprintfln("bink: close at frame %d of %d", x86.rd32(b.obj + BINK_FRAME_NUM), b.info.frames)
	if b.audio != nil {sdl.DestroyAudioStream(b.audio)}
	movie_close(b.m)
	heap_free(b.obj)
	unordered_remove(&binks, i)
	ret(1, 0)
}

// BinkSetVolume(bink, track, volume): 32768 is full volume.
Bink_SetVolume :: proc() {
	b := &binks[bink_of(arg(0))]
	if b.audio != nil && !sdl.SetAudioStreamGain(b.audio, f32(arg(2)) / 32768) {
		x86.fatal("bink: audio gain: %s", sdl.GetError())
	}
	ret(3, 0)
}

// BinkWait(bink) -> 1 while the current frame is not yet due, else 0.
Bink_Wait :: proc() {
	b := &binks[bink_of(arg(0))]
	if b.pause_ns != 0 {ret(1, 1); return}
	n := u64(x86.rd32(b.obj + BINK_FRAME_NUM) - 1)
	due := b.start_ns + n * 1_000_000_000 * u64(b.info.fps_den) / u64(b.info.fps_num)
	ret(1, bink_now() < due ? 1 : 0)
}

// BinkDoFrame(bink): decodes the current frame and queues its audio.
Bink_DoFrame :: proc() {
	b := &binks[bink_of(arg(0))]
	r := movie_decode(b.m)
	if r < 0 {x86.fatal("bink: decode frame %d: %s", x86.rd32(b.obj + BINK_FRAME_NUM), movie_error())}
	data: [^]f32
	n := movie_audio(b.m, &data)
	if b.audio != nil && n > 0 && !sdl.PutAudioStreamData(b.audio, data, n * 2 * size_of(f32)) {
		x86.fatal("bink: queue audio: %s", sdl.GetError())
	}
	x86.wr32(b.obj + BINK_LAST_FRAME, x86.rd32(b.obj + BINK_FRAME_NUM))
	ret(1, 0)
}

// BinkNextFrame(bink): advances; after the last frame it restarts at frame 1.
// The game calls it with 0 after closing a finished movie (0x67f0cd).
Bink_NextFrame :: proc() {
	if arg(0) == 0 {ret(1, 0); return}
	b := &binks[bink_of(arg(0))]
	k := x86.rd32(b.obj + BINK_FRAME_NUM)
	if k >= u32(b.info.frames) {
		if movie_rewind(b.m) < 0 {x86.fatal("bink: rewind: %s", movie_error())}
		b.start_ns = bink_now()
		k = 0
	}
	x86.wr32(b.obj + BINK_FRAME_NUM, k + 1)
	ret(1, 0)
}

// BinkPause(bink, pause): the clock stops and the audio is unbound.
Bink_Pause :: proc() {
	b := &binks[bink_of(arg(0))]
	pause := arg(1) != 0
	if pause && b.pause_ns == 0 {
		b.pause_ns = bink_now()
		if b.bound {sdl.UnbindAudioStream(b.audio); b.bound = false}
	} else if !pause && b.pause_ns != 0 {
		b.start_ns += bink_now() - b.pause_ns
		b.pause_ns = 0
		if b.audio != nil {
			if !sdl.BindAudioStream(ds_dev, b.audio) {
				x86.fatal("bink: bind audio stream: %s", sdl.GetError())
			}
			b.bound = true
		}
	}
	ret(2, pause ? 1 : 0)
}

bink_fmt :: proc(d3d: u32) -> Bink_Fmt {
	switch d3d {
	case D3DFMT_A8R8G8B8, D3DFMT_X8R8G8B8: return .BGRA
	case D3DFMT_R5G6B5: return .RGB565
	case D3DFMT_X1R5G5B5: return .RGB555
	}
	x86.fatal("bink: no copy for D3DFORMAT %d", d3d)
}

// BinkDX9SurfaceType(surface) -> the copy type for the surface's format.
// The game asks only when it first creates a movie texture, and keeps the
// answer for later movies, so the target is found in CopyToBuffer instead.
Bink_DX9SurfaceType :: proc() {
	t, _, _ := surf_owner(res_of(arg(0)))
	ret(1, u32(bink_fmt(t.format)))
}

// The single-level texture of the movie's size whose level-0 shadow is dest
// (the game locks it to copy each frame), or nil for any other buffer.
bink_target :: proc(b: ^Bink, dest: u32) -> ^Res {
	is_target :: proc(r: ^Res, b: ^Bink, dest: u32) -> bool {
		return r.kind == .Texture && r.levels == 1 && r.shadow == dest && r.w == u32(b.info.w) && r.h == u32(b.info.h)
	}
	c := bink_tex
	if c.id < u32(len(res)) && res[c.id].obj == c.obj && c.obj != 0 && is_target(&res[c.id], b, dest) {
		return &res[c.id]
	}
	bink_tex = {}
	for &r in res {
		if r.obj != 0 && is_target(&r, b, dest) {
			bink_tex = {com_id(r.obj), r.obj}
			return &r
		}
	}
	return nil
}

// The host-fed storage is X8R8G8B8 whatever the guest format: the scaled
// frame is not reduced to 16 bits.
bink_scale_storage :: proc(t: ^Res, k: u32) {
	assert(t.scale <= 1, "bink: target texture already scaled")
	gl.DeleteTextures(1, &t.gl)
	t.gl = tex_gl_create(gl.TEXTURE_2D, fmt_must(D3DFMT_X8R8G8B8), t.w * k, t.h * k, 1)
	t.scale, t.host_fed = k, true
	for obj in t.surfs {
		if obj == 0 {continue}
		sr := res_of(obj)
		sr.gl, sr.scale = t.gl, k
	}
}

// BinkCopyToBuffer(bink, dest, pitch, height, x, y, flags) -> 0. The frame
// goes into the guest buffer, or, under render scaling when dest is the
// movie texture's shadow, scaled into its GL storage. The texture is locked
// here; its unlock uploads nothing once it is host-fed.
Bink_CopyToBuffer :: proc() {
	b := &binks[bink_of(arg(0))]
	dest, pitch, rows, flags := arg(1), arg(2), arg(3), arg(6)
	if arg(4) != 0 || arg(5) != 0 {x86.fatal("bink: copy at %d,%d", arg(4), arg(5))}
	code := flags & 0xff
	if code < u32(Bink_Fmt.BGRA) || code > u32(Bink_Fmt.RGB555) {x86.fatal("bink: copy flags %08x", flags)}
	f := Bink_Fmt(code)
	bpp := BINK_FMT_BYTES[f]
	t := rt_scale > 1 ? bink_target(b, dest) : nil
	if t != nil && !t.host_fed {bink_scale_storage(t, rt_scale)}
	if t != nil {
		w, h := t.w * t.scale, t.h * t.scale
		if len(bink_up) < int(w * h * 4) {
			delete(bink_up)
			bink_up = make([]u8, w * h * 4)
		}
		if movie_copy(b.m, raw_data(bink_up), c.int(w * 4), c.int(w), c.int(h), c.int(Bink_Fmt.BGRA) - 1) < 0 {
			x86.fatal("bink: copy: %s", movie_error())
		}
		fi := fmt_must(D3DFMT_X8R8G8B8)
		gl.TextureSubImage2D(t.gl, 0, 0, 0, i32(w), i32(h), fi.format, fi.type, raw_data(bink_up))
	} else {
		w, h := u32(b.info.w), min(u32(b.info.h), rows)
		if pitch < w * bpp {x86.fatal("bink: pitch %d for %d pixels", pitch, w)}
		if movie_copy(b.m, x86.ptr(dest), c.int(pitch), c.int(w), c.int(h), c.int(code - 1)) < 0 {
			x86.fatal("bink: copy: %s", movie_error())
		}
	}
	ret(7, 0)
}

// The movie clock in nanoseconds: the virtual clock under lockstep.
bink_now :: proc() -> u64 {
	return lockstep ? u64(clock_read()) : sdl.GetTicksNS()
}
