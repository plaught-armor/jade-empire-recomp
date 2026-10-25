# HLE layer

The `port/src/win32/` packages implement the Windows imports the game calls.
Each import is an Odin proc registered by DLL and name. This file records the
behavior that departs from a direct translation of the Win32 call.

## §1 Paths

- A guest path under `C:\Jade Empire`, or a relative one, maps onto the host
  working directory, which `main` sets to the game folder. A path on another
  drive is treated as rooted in the game folder.
- Each component is matched case-insensitively, as NTFS does. An exact match
  wins over a case-folded one. A component that does not exist keeps its
  spelling, so creating a file uses the guest's spelling.
- Directory listings are cached (`dir_cache` in `file.odin`) and keyed by the
  host directory path as `host_path` builds it. Without the cache, every
  case-mismatched component (`Sound`, `SOUND` and `Data` against `sound` and
  `data`) and every probe of `override/` for a file that is not there re-read
  the whole directory. That was about 670 reads in the first 45 s, with
  `override/` holding 3181 entries, and about 10% of a load's CPU time.
- The cache is invalidated by every guest change to the file system: a file
  created by CreateFileA, DeleteFileA, CreateDirectoryA, RemoveDirectoryA, and
  WritePrivateProfileStringA. Each drops the listing of the containing
  directory and of the path itself. Host-side writes go only to directories
  named by environment variables (frame and shader dumps), which are not
  looked up through `host_path`. The cache holds at most `DIR_CACHE_MAX`
  directories and is cleared when full.
- A save's thumbnail, `SaveImage.tga` in the save's folder, is written by the
  game (its statically linked D3DX, from function 0x55e880) as a 512×512
  32-bit TGA of 1,048,594 bytes. With 44 saves that was 44 MB of an 81 MB
  `Save` folder. When the guest closes a handle it opened for writing on a
  file of that name, `thumb_shrink` in `file.odin` box-filters the image to
  256×256 24-bit (196,626 bytes) and keeps the origin bits of the header. The
  load and save menus draw it at about 290 pixels wide, so nothing visible is
  lost. Images narrower than 512 pixels, or whose sides the factor (width
  / 256, rounded down) does not divide, are left alone. Thumbnails written before the change
  keep their size.

## §2 Elided sleeps

`Sleep` returns at once when its return address is in `SLEEP_ELIDE`
(`kernel32.odin`). A site goes on that list only when the code after it does
not depend on time having passed: it only throttles or holds a screen up.
The frame limiter at 0x4a4398 is kept.

| Return address | Site | Saved |
|---|---|---|
| 0x4af8ca | Area-load loop `FUN_004af6a0`: 10 ms after each streamed resource. The loop does not recheck anything after the sleep. | about 300 sleeps, 3 s per load |
| 0x4a4f13 | After a save, the loop at 0x4a4ee0 redraws the save message 17 times with a sleep of (3000 ms - save time) / 17 each: a 3 s minimum display. | about 3 s per save |
| 0x556533 | The same 3 s minimum display after a save from the save screen: `0x556320`, the callback the save panel (and its overwrite confirmation, panel 7) calls, redraws panel 0x41 in the loop at 0x556500. | about 3 s per save |
| 0x4a4cc1, 0x4a4f67 | Around an in-game save (quicksave, autosave): 250 ms after "My Pause" (`0x669ce0`) on the audio object at 0x76c92c, 50 ms after "My Resume" (`0x669d70`). Both calls are synchronous and the port runs no guest threads, so nothing finishes during the wait. | 300 ms per save |
| 0x556374, 0x556579 | The same two waits around a save from the save screen (`0x556320`). | 300 ms per save |

Measured with the save/load input script (`docs/recompiler.md` §6) and frame
dumps every 30 frames. The original timings were 5.8 s for a new-game load and
5.9 s for a quick load (F9). After eliding 0x4af8ca they were 2.4 s and 3.3 s.
After inlining the helpers (`docs/recompiler.md` §2), 2.2 s and 2.5 s, counting
about 1 s of normal frames in each. With the directory cache (§1) and 0x4a4f13
elided, no 30-frame window in a new-game load, a quicksave or a quick load
takes longer than normal play. The loading screen and the save message still
show for a few frames. The save message's redraw loops also run once instead
of 17 times (`docs/recompiler.md` §9), so a save takes about one frame plus
the save work itself.

## §3 Registry

`RegOpenKeyExA` always fails with ERROR_FILE_NOT_FOUND. The game's only call
(0x5980bc, `SettingsSerializer::Init`) opens `HKLM\Software\BioWare\JadeEmpire`
and stores the handle at 0x76ec08; the only other use of that handle is
`RegCloseKey` in 0x597da0. No registry value is ever read (the executable does
not import `RegQueryValueExA`), so the logged "Registry key not found!" is
harmless and the settings come from `JadeEmpire.ini`.

## §4 Bink movies

`binkw32.dll` is implemented on FFmpeg (`port/src/win32/bink.odin`, decoding
in `port/src/win32/movie.c`). The decoder side is C so that FFmpeg's structs
are read through its own headers, whose layouts change between major
versions; `build.sh` compiles it into `build/libmovie.a`, and
`build_windows.sh` into `build/win/movie.lib` against FFmpeg's shared LGPL
Windows build, whose DLLs ship beside `jade.exe`.

Player (0x67e420 .. 0x6800f0). The game opens `English\Movies\X.bik`, which
does not exist, and then `MOVIES\X.bik`. Each frame: `BinkWait` (nonzero
returns at once), `BinkDoFrame`, `LockRect` on its movie texture,
`BinkCopyToBuffer(bink, bits, pitch, height, 0, 0, type)`, `UnlockRect`, a
draw, then `BinkNextFrame`. At the last frame of a non-looping movie it closes
the movie (0x67e670) and then calls `BinkNextFrame(0)`, which is a no-op.

- Guest struct: a zeroed 0x200-byte block holding width, height, frame count,
  current frame (1-based), last decoded frame and frame rate at +0x00..+0x18.
- Timing: frame n is due at open time + (n - 1) / fps. `BinkPause` shifts the
  start time by the paused interval.
- Audio: unless the open flags carry `BINKSNDTRACK` (0x4000, set under
  `NoSound`), the first audio track is decoded to stereo f32 and queued on an
  SDL audio stream bound to the DirectSound device. The device is therefore
  opened with `OpenAudioDevice` plus a separately bound stream: a device from
  `OpenAudioDeviceStream` refuses further bindings.
- Surface type: `BinkDX9SurfaceType` maps A8R8G8B8/X8R8G8B8, R5G6B5 and
  X1R5G5B5 to the nonzero codes 1..3; a 0 would be replaced by the game's own
  default. The game asks only for the first movie: 0x67e490 first tries YUY2,
  falls back to R5G6B5 and stores that format at 0x769da0, so later
  `CreateTexture` calls succeed at once and skip the `GetSurfaceLevel` and
  surface-type call. The movie texture is therefore found in
  `BinkCopyToBuffer`, as the single-level texture of the movie's size whose
  level-0 shadow is the destination.

Upscaling. Under render scaling (`docs/rendering.md` §1) the movie texture's
GL storage is reallocated at `rt_scale` times its size, in X8R8G8B8 whatever
the guest format, and marked `host_fed`, so its unlock uploads nothing.
`BinkCopyToBuffer` converts the frame with swscale's Lanczos filter, on all
cores, straight to that size and uploads it. A 640x480 movie to 1920x1440
costs about 1.8 ms per frame on a 16-thread Ryzen 7 7700X.

HD replacements. When `movies_hd/X.mkv` exists in the game directory,
`BinkOpen` decodes it instead of `X.bik`; the guest still sees the `.bik`
header, so the texture size and timing are unchanged and the HD frame is
scaled to whatever the copy fills. The shape must match the `.bik`, and so
must the frame count, give or take one: Matroska has no frame count, so the
decoder estimates it from the container duration, and the `.bik`'s count and
frame rate are what drive the timing. The four shipped replacements decode
to exactly the `.bik` counts (1, 417, 481 and 151 frames).
`tools/upscale_movies.py <game dir> <realesrgan-ncnn-vulkan> [name ...]`
makes them: Real-ESRGAN `realesr-animevideov3` 4x on the GPU, Lanczos to
2560x1920 (4x the back buffer, the largest render scale), 10-bit AV1 by
SVT-AV1 at CRF 20, and the original audio as FLAC. `realesrgan-x4plus`
restores more fine detail but paints Bink's block artifacts into hard edges
and looked oversharpened in play; animevideov3 is softer, and the port
sharpens movies itself at a separate level (rendering.md §14). It runs at
about 4.4 frames per second at 800x600 on a Radeon RX 7900 XTX (x4plus
about 1), and the game has 230 787 frames (60 137 at 640x480, 170 650 at
800x600), about 14.5 hours in all.

## §5 Gamepad

`win32/pad.odin` presents one SDL3 gamepad to the game as a DirectInput 8
joystick plus XInput rumble. SDL handles device discovery, hot-plug and
controller mappings; the game sees one fixed Xbox 360 layout.

- Enumeration. The game enumerates game controllers from 0x667360. A call with
  `DIEDFL_FORCEFEEDBACK` (0x100) set gets no device: rumble goes through XInput,
  not DirectInput effects, and the effect interfaces are not implemented.
  The game enumerates only once, at start, so the device is listed even with
  no pad connected and reads as centred until one is: a pad plugged in later
  takes the slot (`pad_open` on SDL's gamepad-added event).
- Product name. The device reports "Controller (XBOX 360 For Windows)", the
  name of Microsoft's 360 driver. The game matches it against the layout table
  at 0x703668 and, on a match, sets the 360 flag at 0x76d738. That flag selects
  the 360 button labels and the XInputSetState rumble path.
- Objects. Axes: X, Y (left stick), Z (triggers, LT minus RT), Rx, Ry (right
  stick). One POV (d-pad), twelve buttons: A, B, X, Y, LB, RB, Back, Start,
  left stick, right stick, LT, RT. The triggers count as buttons when pressed
  past 8000 of 32767, and released below 4000, so they can be bound like any
  other button and a trigger resting near 8000 does not chatter.
- Stick deadzone. The game has two of its own, both taken out: CXbInput
  0x6678e0 zeroes each axis within 6535 of centre (patched out,
  docs/recompiler.md §9), and 0x6661d0 maps each axis, read as a float in
  -1..1, through (|v| - dz) / (1 - dz) with dz 0.6, so the stick did nothing
  until 60% of its travel and small deflections never walked. The native hook
  (port/src/native/stick.odin) sets that axis's dz, an f32 at
  this + port * 0x33a8 + 0x3810 + 4 * (action - 0x10), to 0 for the call, so
  the value passes through unchanged. `pad_stick` reads a stick within `JE_STICK_DZ`
  percent (default 12) of centre, by length, as centred, and stretches the
  rest, up to 95% deflection, over the full range along the stick's angle, so
  small deflections neither jump to 20% nor snap to an axis. `JE_STICK=0`
  applies the game's original deadzones: each axis within 6535 of centre
  reading 0, then the 60% float deadzone.
- Binding screen. The controls page calls GetObjectInfo BYOFFSET at 0x666334
  for each offset in the table 0x75c3e0..0x75c490 and shows "-" for an
  object that returns DIERR_OBJECTNOTFOUND. Missing objects must return that
  error, not fail the call.
- State. GetDeviceState fills DIJOYSTATE (0x50 bytes) with axes scaled to the
  range set through DIPROP_RANGE. A centred d-pad reads 0xffffffff. A
  disconnected pad reads as centred and released, and the next connected pad
  is opened in its place.
- Rumble. XInputSetState is called from 0x6689b0, 0x668aa0 and 0x668b70 with
  user 0. It forwards both motor speeds to `SDL_RumbleGamepad`; a pad without
  rumble logs once and the call still succeeds. Any other user, or no pad,
  returns ERROR_DEVICE_NOT_CONNECTED (1167).
- Button names. The game names controller buttons through strrefs
  130700..130713 (table 0x75cf90), and four lines (370, 11567, 24433, 117112)
  name 360 buttons in their text. When the connected pad is a PlayStation or
  Switch controller (`pad_names`), `win32/tlk.odin` hands the game an unlinked
  temporary copy of dialog.tlk whose entries for those strrefs point at
  rewritten strings, and GetObjectInfo reports the pad's own names. The pad
  must be connected when dialog.tlk opens; a pad swapped in later keeps the
  first pad's names. The "No Target" binding still shows "Left Stick": it
  comes from a name lookup (0x594ae0) whose source is not yet traced.
- Second pad. A second connected pad opens as `pad2`, player 2 of couch
  co-op (docs/recompiler.md §10). The game never sees it: `pad2_read` hands
  `native/coop.odin` its left stick, through the same radial deadzone, and
  its held buttons. A pad plugged in fills the first free slot, `pad` then
  `pad2`; when the first pad goes, the second does not move up.
- Tests. `JE_INPUT_SCRIPT` `Pad.<name>` actions drive a virtual SDL gamepad
  through the same path (docs/recompiler.md §6); `JE_CTL`'s `pad2` and
  `axis2` drive a second one as player 2 (§7 there); `pad2 off` detaches it
  (player 2 out: the henchman comes back) and `pad2 on` attaches a new one.

## §6 Fixed-function vertex stage

`port/src/win32/d3d9_ffvs.odin`. Every draw seen so far binds a vertex shader
or uses pretransformed (POSITIONT) vertices; a traced gameplay frame (frame
1300 in Two Rivers) had 150 DrawIndexedPrimitive calls, all with shaders. The
game still calls SetTransform about 20 times per frame, so the transform and
lighting path exists so an unseen fixed-function draw renders instead of
stopping the session.

- Program per declaration (`ffvs_key`: inputs present, texcoord component
  counts, POSITIONT). All other state is in the FFVS uniform block, binding 3,
  filled by `ffvs_upload` per draw.
- Position: WORLD * VIEW * PROJECTION. Matrices are uploaded as D3D stores
  them, so GLSL `m * v` is the D3D row-vector product `v * M`. Normals use the
  inverse transpose of WORLD * VIEW.
- Lighting in view space: up to 8 enabled lights (more is fatal), directional,
  point and spot, with range, attenuation and falloff; global ambient
  (D3DRS_AMBIENT); material color sources apply only with COLORVERTEX and the
  named vertex color present. Non-local viewer is (0, 0, -1) toward the eye.
- Vertex fog (FOGTABLEMODE NONE): FOGVERTEXMODE EXP, EXP2 or LINEAR on view
  z, or distance with RANGEFOGENABLE. FOGVERTEXMODE NONE uses the specular
  alpha, as for pretransformed vertices. This choice is not checked against
  Windows.
- Table fog (FOGTABLEMODE LINEAR, EXP, EXP2) is per pixel in the shared
  pixel epilogue, for fixed-function and shader draws alike. Its depth is eye
  w (`1 / gl_FragCoord.w`) when the projection matrix is W-friendly (`_34`
  not 0, `_44` 0), else window z, as D3D9's w-based fog. The game uses only
  table LINEAR fog, from vertex shaders, with start and end in world units
  (10 to 77 at Two Rivers, 5 to 60 in a cave). Until v80 the epilogue used
  window z (0 to 1) always, so `(end - z) / (end - start)` stayed above 1
  and the game had no fog at all.
- Texture coordinates: TCI generation (camera-space normal, position,
  reflection) and TEXTURETRANSFORMFLAGS COUNT1..4 with the stage's TEXTUREn
  matrix. The input is padded as D3D does, first missing component 1, so a 2D
  translation sits in row 3. The FF pixel stage reads oT[TEXCOORDINDEX], so a
  stage's result is written to that set. Two stages claiming one set, or a
  set other than the stage number under a pixel shader, are fatal.
- Fatal, as not observed: vertex blending (VERTEXBLEND), point scaling,
  per-vertex point size, sphere-map generation.
- Verification: the five representative programs compile under
  glslangValidator. No game draw exercises the path yet, so its output has not
  been compared with Windows.

## §7 vorbisfile reopen

`vorbis.odin` keys host decoder state by the guest `OggVorbis_File` address.
On the Two Rivers school-to-town transition the game calls `ov_test_callbacks`
again on the same `OggVorbis_File` (0x821bc0, a streaming-music slot) without
calling `ov_clear` first; the call comes from FUN_00670fb0 (return address
0x671975). The port used to treat this as fatal ("vorbisfile: 00821bc0 opened
twice").

Reference libvorbisfile accepts it: `_ov_open1` begins with
`memset(vf, 0, sizeof(*vf))`, so the old stream is overwritten and leaked and
its close callback is never called. The port does the same for the guest side,
leaving the old datasource alone and not calling its close callback. It frees
its own host copy (stb_vorbis decoder, slurped stream bytes, guest
`vorbis_info`) and logs one `vorbisfile: ... reopened without ov_clear` line
per occurrence.

## §8 dbghelp

The `dbghelp.dll` imports (`misc.odin`) return 0. `SymInitialize` is called
once at startup, from the crash-reporter setup at 0x595510, and its result is
used only to log "SymInitialize() fails!" (0x595528). The remaining imports
(`StackWalk64`, `SymGetLineFromAddr64` and the others) run only when the game
writes a crash report. Failing all of them means a crash report has no symbol
names, and the log line is harmless.

## §9 Code pages

`MultiByteToWideChar` and `WideCharToMultiByte` (`kernel32.odin`) convert
UTF-8 when the code page is `CP_UTF8` (65001) and treat every other code page
as Latin-1. The game converts its text with `CP_UTF8` (pushes of 0xfde9 at
0x42451a, 0x424b8e, 0x425e7c, 0x42769f, 0x42793f, 0x427c76, 0x427d03, 0x428673,
0x4a4de1 and 0x52fecc), and `dialog.tlk` holds UTF-8: 30 strings carry é
(strref 91862, Gao the Lesser's "your precious protégé", and the fiancé lines of
Seamstress Lan's quest). Until v102 both conversions were Latin-1 for every
code page, so é showed as "Ã©". The fonts index glyphs by UTF-16 unit
(`.abc` has 65535 entries), so é draws once decoded. Tested with a settings
label holding "protégé" on the Video panel.

A malformed UTF-8 sequence becomes U+FFFD, and a destination too small returns
0 without writing, as `ERROR_INSUFFICIENT_BUFFER` would; `GetLastError` is not
set.

## §10 Game clock

`GetTickCount` and `QueryPerformanceCounter` (10 MHz) read one clock,
`game_clock()` in `kernel32.odin`: host time since boot, except that it runs
at 0.08 of real time while a hit stop is on (`clock_slow`, called by
`native/pace.odin`; docs/recompiler.md §10). It never stops, so no frame has
a zero time step. The port runs no guest threads and its own frame pacing
uses host time, so nothing else waits on it.

## §11 Lockstep and online play

Online co-op is input lockstep (`win32/lockstep.odin`, `win32/net.odin`): each
peer runs the game from the start of play (the host's New Game or Load Game;
from boot before v153), and the only thing the peers exchange is pad input,
plus the host's creature floats as a drift correction (v153, below). Every
guest-visible value must then follow from the inputs alone.
`JE_NET_HOST=port` hosts (player 1), `JE_NET_JOIN=host:port` joins (player 2,
whose pad drives the henchman through the couch co-op path, docs/recompiler.md
§10; co-op is forced on). `JE_LOCKSTEP=n` turns lockstep on without a network
and logs `lockstep: frame N hash H` every n frames, so two runs on the same
`JE_INPUT_SCRIPT` can be diffed; with host or join it logs the same lines on
both peers.

**Clock.** Host time gives way to a virtual clock, `vclock`. Each presented
frame moves it to at least frame × 1/60 s (`lock_frame`, called from
`Dev_Present`), `Sleep`/`SleepEx` add their length instead of sleeping, and
each `GetTickCount`, `QueryPerformanceCounter` or Bink clock read adds 1 µs,
so a guest loop polling the clock still ends. `game_clock()` (§10) runs on
it, as do message and DirectInput event times and the AI and input-buffer
timers in `native/`. The frame cap is forced to 60 and frame-rate tracking
is off. The wall clock (`GetSystemTimeAsFileTime`, `GetLocalTime`) is the
host's time at the handshake plus `vclock`; every file time is that epoch,
so the save list sorts by name. `FindFirstFileA` lists names sorted
case-insensitively (NTFS order) in every mode.

**Input.** Under lockstep the guest reads input only through `pad_in`, two
`Pad_Input` records (axes, button and d-pad bits, and a `Kbm`) sampled once
per frame. `pump` drops focus events and collects the keyboard and mouse
into `kbm.odin` instead of the guest (it still handles quit, the port's host
keys and pad hotplug). Each frame `kbm_take` packs the local keys (DIK bits),
mouse buttons, cursor, motion, wheel and up to four typed characters. Player
1's (the host's, or the only player's) ride in its record, and every peer
replays them into the guest at the same frame (`kbm_apply`): key, char and
mouse messages, DirectInput keyboard and mouse events, `GetAsyncKeyState`
(`kbm_vk_down`) and `GetCursorPos`. `SetCursorPos` moves that replayed
cursor, and warps the real one only on the peer whose mouse is player 1's.
The game has one keyboard and mouse, so the joiner's become player 2's pad
(`kbm_pad`, after the first keyboard layout: WASD moves, the mouse looks,
the buttons and keys map to the pad buttons), with its mouse held in the
window. Keys and buttons already down when lockstep starts are ignored until
let go. Key auto-repeat is not replayed, and the mouse lags by the net delay
like the pads. Pad names are the Xbox 360 set on both peers, and
`XInputSetState` succeeds without a pad. Rumble still goes to the local pad.

**Audio.** The mixer would otherwise pull samples at the audio device's
pace. Under lockstep `ds_pump` mixes exactly `vclock` × 48000 frames and
drops chunks while the device queue is full, so buffer play positions follow
the virtual clock. There is always a device: with no playback device
`ds_open` falls back to SDL's silent `dummy` driver, because the game's own
path for a failed `DirectSoundCreate8` dereferences the missing object and
crashes. The fallback sets the driver hint at override priority, since a
plain hint loses to an `SDL_AUDIO_DRIVER` in the environment naming the
driver that just failed (tested on Linux with
`SDL_AUDIO_DRIVER=pulseaudio PULSE_SERVER=unix:/nonexistent`).

**Scratch.** The game unpacks the save it loads into `scratch` (the
`SaveImage.tga` the load screen shows, `INPROGRESS\*.sav`) and writes a save
there before copying it into `Save`. Under lockstep `host_path` maps the
guest's `scratch` onto a fresh empty folder per process (`jade_scratch_*` in
the system temp folder, removed by `game_exit`), so stale files from games
before cannot differ between peers. Found as a desync around frame 506 of
the Two Rivers load in about one run in twenty when several runs shared one
game folder: one run's load screen read `SaveImage.tga` while another
rewrote it, and got the 2x2 missing-texture placeholder instead of the
512x512 image. 100 concurrent runs after the change agreed. The guest's
`logs` folder (`logs\d3d.log`) maps the same way, onto `logs` in the same
temp folder, left for the game to make: a peer whose game folder had no
`logs` yet (a first run, or a fresh copy of the folder) differed from one
that had it by frame 60, about 18800 heap bytes, every time.

**AI dice.** `native/ai.odin` rolls from its own random state, seeded 0
under lockstep (wall time otherwise).

**Net protocol** (UDP). The joiner resends HELLO until WELCOME. HELLO
carries the port version, the build ID (`tools/build_id`, which build.sh,
build_windows.sh and build.bat pass in as `JE_BUILD_ID`: a hash of every
file under `port/src` with line endings read as LF, the recompiled code
included, and the Odin version, so two machines that build the same commit
match whatever `-microarch`, linker or OS each used: a native Windows build
matches a cross-built one, and a Linux and a Windows peer play together, since
no game state reads the host's libm: its cos, pow and exp reach only the
audio mixer's gains and reverb, which never write guest memory. The Vorbis
decoder does write guest memory (`ov_read` decodes PCM straight into the
guest's buffer), so `win32/vorbis.c` builds stb_vorbis with its sin and cos
taken from `x86/libm.odin`; the prebuilt stb_vorbis took them from each
platform's libm, and a Linux and a Wine run then differed by 1 in 276 PCM
samples from frame 10 on. Its pow, exp and log only size codebooks (integer
results checked against exact powers), and floor and ldexp are exact. Tested:
solo `JE_LOCKSTEP=10` hashes equal on Linux and Wine through frame 17600, and
a Linux host with a Wine joiner checked hashes through frame 6960 with a save
load and a fight. A build made without
it hashes its own binary instead; `jade --version` and the first line of
every log print it), a hash of the game exe's code (0x401000 to 0x6e1000 as
loaded, so the GOG exe and the unpacked Steam exe match) and a hash of the
names and sizes of the files under `override` and `textures_hd`; any difference is
a REJECT with the reason logged on both sides. `Save`, `JadeEmpire.ini` and
the gameplay settings are not compared: the joiner takes the host's (Save
and settings from the host, below). HELLO also carries the joiner's pick of
player 2's hero (its `P2_HERO` setting), which is not compared: WELCOME carries
it back with the epoch and the delay, and both peers build that hero. Before
the WELCOME the host times 16 round trips (PING, echoed as PONG, one at a
time) and picks the delay: half the round trip 14 of 16 came back within,
in whole frames, plus 2 frames for frame-time jitter, at least 3 and at most
30; it logs the times and the pick. That is the starting delay; in play each
peer moves its own, since only it writes its inputs. Each input's round trip
is timed from when it was made to the peer's ack of it, less two frames'
work (the ack goes out with the peer's next frame and is read at this
peer's next, waits a ping does not have; it also keeps long load frames from
counting as latency). Over the last 64 round trips the same pick gives the
delay wanted. A delay short of it rises a frame each frame: the previous
input is repeated for the frame skipped. Once no round trip has asked for
the current delay or more for 1 s (NET_CALM), it falls a frame each frame
toward what they ask, but only on a frame whose input equals the last one,
so the input that is not made loses nothing. Each change is logged (`net:
delay D frames at frame F`), and the range at exit. A hash rides with the
first input made after it (`hash_at`), not frame + delay. `JE_NET_DELAY`
(0..30) on the host sets the starting delay instead, and on either peer keeps
that peer's delay fixed. A peer that waits over 1 ms for the peer's input moves its
frame schedule (`fps_wait`) later by the wait. Without that it caught up
with a burst of frames and waited again: on localhost with delay 3 the
joiner, its schedule ahead of the host's, stalled on 3706 of 4600 frames
(50 s in all); with it, 8 frames and 18 ms. Rollback (predicting the peer's
input and replaying on a miss) is not done: for an action RPG a frame or two
more delay costs less. Tested: a
joiner with `JE_P2_HERO=3` and a host without it both spawned Jen Zi, hashes
equal through frame 2940. Each peer then sends its input
for frame f + delay when frame f starts and starts a frame only once both
inputs for it are in. While stalled it resends everything the peer has not
acked after 5 ms, then after twice as long each time up to 250 ms, so a lost
packet is covered quickly and a slow link is not flooded. A peer sends BYE
at exit (`ExitProcess`, the ctl `quit`). When the peer that joined sends BYE
or stays silent for 10 s, the host plays on alone (v142): it logs `net: peer
left at frame N` or `net: peer lost at frame N`, then the traffic and stall
lines (the stall total takes in the wait cut short by the loss, 10 s for a
lost peer), then `net: playing on alone; the peer can join again`, and from
then on takes its own pad at once for
player 1 and a released input for player 2. Player 2 is then out, as a couch
pad turned off is: the henchman comes back and the hero is put away. The
joiner's game is the host's, so a joiner whose host leaves or is lost exits.
Tested on localhost with the joiner quitting at frame 1621 and killed at
frame 1607: the host walked on into the School Gate conversation and quit
cleanly 1300 frames later. At exit each peer logs `net: sent N input packets, B bytes;
received N, B bytes; last hash checked frame F` and how many frames waited
over 1 ms on the peer's input, with the time in all (counted from boot, so a
host that has lost a peer once still counts that wait).

**Rejoin** (v146, protocol version 6). A player who left can start the game
again with the same `JE_NET_JOIN` and come back into the game in play. The
host keeps every frame's pair of inputs from boot (`log`, 32 bytes a frame,
about 3.5 MB an hour at 30 frames a second) and the hash of every 60th frame.
Since the rejoiner replays from boot, it must also start from the save files
the host started from: every joiner plays on the host's `Save` as it was at
the host's boot (Save and settings from the host, below). While alone, the host
answers a hello from any address after the 10 s loss timeout, or at once from
the lost peer's own address; it logs `net: ADDR rejoins at frame N` and
sends a welcome marked rejoin. The rejoiner then asks for the log in bursts
of up to 16 packets of 1200 bytes (each frame delta-coded against the one
before, with the hash on every 60th), at most 4096 frames past what it has
played, and replays it with `fps_wait`, vsync and sound out off
(`lock_fast`), checking each hash it reaches (`net: desync replaying frame
N` on a miss). Meanwhile the host plays on alone. Once the rejoiner is within
30 frames of the host's newest frame it sends READY; the host picks a
handover frame 60 frames past its newest (`net: rejoining peer caught up at
frame N; player 2 back at frame M`), serves the log up to it and answers
each READY with a HANDOVER naming that frame and the delay. At that frame
both rebuild their input rings around it, the rejoiner turns `lock_fast`
off and frees the log, and both log `net: player 2 back in play at frame M,
delay D frames`; from there it is the usual lockstep. Only one rejoiner is
served at a time (a new hello takes the place of the last).
Tested on localhost: joiner killed at frame 1607, a new one started
(gamescope at 1000 Hz so the replay is not held to the display) said hello
at host frame 1608, caught up at 1992 and was back in play at 2053, 18 s
after the restart. The hero came back, hashes were equal through frame 2760,
both screenshots showed the same frame of the School Gate conversation, the
rejoiner quit at 2798, the host played on alone and quit cleanly, and `Save`
was unchanged. Through the WAN mock's `bad` profile (asymmetric 140 ms round
trip, burst loss, bufferbloat spikes; 299 of 5430 packets lost), where the
proxy gives the new joiner the dead one's address so the host takes its hello
at once as `net: peer restarted at frame 1611`: caught up at 1910, back in
play at 1971 with delay 7, 8 s after the restart, hashes equal through 2700.
With the link dark from 1 s into the rejoin (the `far` profile, 240 ms
round trip): for 3 s, the log asks picked up where they stopped and player 2
was back at 1943, hashes equal through 2640; for 12 s, the rejoiner logged
`net: host lost at frame 1684` and exited, removing its temporary save copy,
and the host logged `net: rejoining peer lost at frame 2291`, played on
alone and quit cleanly.

**Main menu and open host** (v147, protocol version 7,
`native/menu_online.odin`, `win32/join_edit.odin`, `win32/upnp.odin`). The
title menu (CPanelMainMenu) is condensed into two submenus (v150): the top
level is Singleplayer, Online, Options, Game Credits and Exit; Singleplayer
holds New Game, Load Game and Play Mini-games, and Online holds Host Online
Game and Join Online Game when playing alone, New Game, Load Game and Leave
Online Game on a hosting lobby, and Leave Online Game when joined or in an
online game, each with a Back row. The panel built again while a lobby is
open (back from Load Game) opens at Online. B in a submenu goes back too, in place of the
quit dialog, and going back focuses the row that led there. The demo's menu
is left as it is. Five hooks do it: the row list build (0x0056acd0) puts the
top level's rows in place of the game's six (kept for the submenus), so the
panel builds five buttons; row activation (0x0056a570) and focus
(0x0056a020) act on the port's rows by their label strref; the B handler
(0x00569f60) goes back; and the menu's frame (0x00569d50) shows a level
change and drives the address editor. A level change waits for that frame,
outside the button's own event: it rewrites the row list, relabels the
first buttons (label text at button+0x28c), unfocuses the focused one,
refills the list box (panel+0x2c4) with as many as the level has through its
AddControls (0x00523c40), its owning flag cleared first so the hidden
buttons are not freed, sets the list box's height to 25 per row and focuses
a row (0x00523a40). A stock row activated in a submenu saves the submenu's
top row as the one to focus when the panel is built again, at the top level.
Online, the menu runs on player 1's inputs on both peers, and so does the
level. The port's labels and help lines are appended to `dialog.tlk`'s
strings (`tlk_extra`) at boot. Since lockstep starts at boot, each row starts the
port over (`relaunch`: `execve` on Linux, a child process waited on under
Windows so `play.bat` keeps its log) after `game_end`, which says BYE,
removes the scratch folder, the router forward and the joiner's copy of the
host's `Save`.

- Host relaunches with `JE_NET_HOST=` the `[Port]` `NET_PORT` (default
  47000), `JE_NET_OPEN=1` and `JE_NET_MENU=1`. An open host does not wait for
  a peer: it starts out alone, as a host whose peer left, with delay 4
  frames, so a joiner comes in through the rejoin path at any point of play.
- Join opens an editor in the menu's help line, prefilled from the clipboard
  when that holds only address characters, else from `NET_JOIN`. The
  keyboard types, pastes (Ctrl+V), Enter joins, Esc cancels; on the pad the
  d-pad steps the character under the cursor through `0-9 . : a-z -` (and
  adds one past the end), X erases, Y pastes, A or Start joins, B cancels.
  While it is open no row acts and the game sees the pad released until its
  buttons come up. The address (`:NET_PORT` added when it has no port) is
  written to `[Port]` `NET_JOIN`, which is each peer's own, and the port
  relaunches with `JE_NET_JOIN` and `JE_NET_MENU=1`.
- Leave relaunches with no online game. Online the menu runs in lockstep on
  player 1's input, so the joiner's game takes the same row on the same
  frame and relaunches too, with `JE_NET_ERROR=the host ended the online
  game`. The online hooks add only that fixed row and act only on it, so
  they keep both peers the same.

With `JE_NET_MENU` set, a failure that would exit (`net_fail`: no answer,
a reject, a port in use) or a joiner's lost host relaunches alone with
`JE_NET_ERROR=` the reason, and the menu shows `Online: <reason>` in the help
line of the first row focused until another row is. A reject carries which
part of the config differed (`Net_Mismatch`), so the joiner says why, not
only the host.

**Router.** An open host starts a thread that sends an SSDP M-SEARCH for an
InternetGatewayDevice (3 s), to the multicast group and unicast to the
default gateway (Linux `/proc/net/route`, else the LAN address with last
byte 1): a stateful host firewall (ufw) drops the answer to the multicast
ask, since it comes from an address the ask did not go to (found on a
TP-Link with MiniUPnPd: multicast never answered, unicast at once), reads its description for a WANIPConnection:2,
WANIPConnection:1 or WANPPPConnection:1 control URL, and asks it by SOAP to
forward UDP at the port to this machine (`AddPortMapping`, lease 0, and on a
refusal again with 7200 s for routers that take only forwards that lapse),
then for the public address (`GetExternalIPAddress`). The machine's LAN
address is the TCP socket's own end toward the router, or before that the
source address of a UDP socket connected to 8.8.8.8 (nothing is sent; Odin's
`enumerate_interfaces` lists no interfaces on Linux). `pump` puts the
outcome in the window title (with no forward, that UPnP did not open the
port: a forward made by hand cannot be seen), the address to join (public,
else LAN) on the
clipboard, and logs `upnp: forwarded UDP P, join at A` or `upnp: no forward
(why); LAN address A`. At exit `DeletePortMapping` takes the forward back.

Tested headless on localhost: menu Host relaunched as an open host, menu
Join (address from `NET_JOIN`) relaunched, rejoined and logged `player 2
back in play`, and `NET_JOIN` was written. A joiner with `JE_MAGNET=0` was
rejected, relaunched alone and showed `Online: the host has other gameplay
settings (...)`, gone once the next row was focused. The host's Leave row
relaunched it alone with Host and Join back. With no UPnP router on the test
network the title showed the LAN address. Not tested: a real router, a real
WAN link, two rejoins in a row. The peers then still had to start from the
same config and `Save`, moved between machines by hand; since v149 the
joiner takes the host's.

**Lobby in the main menu** (v153, protocol version 11). Host and Join no
longer relaunch: they open a lobby in the running menu (`net_host_open`,
`net_join_open`; `JE_NET_HOST`/`JE_NET_JOIN` open the same lobby at boot).
The joiner says hello every `NET_HELLO_EVERY` until welcomed; the host
welcomes a hello whose config matches, and both show the lobby's news
(`net_news_take`: joined, left, lost, no answer) in the menu's help line.
Lockstep starts at the host's New Game or Load Game row: the host sets
`lock_pending`, makes the `Save` manifest then (with its game options), and
plays alone from the next Present; the peer in the lobby, or one that joins
later, comes in by the rejoin path, so every join is a rejoin. The joiner
takes the host's options and settings and activates the same row
(`MENU_ACTIVATE`) in its own menu. Leave in play still relaunches, since
lockstep play cannot go back to the menu's state; Leave in the lobby only
closes it.

Since the peers' menus ran on their own before play, `lock_begin` resets
what play reads, and native code (`sync_begin`, `native/sync.odin`) the
rest:

- The CRT `rand`/`srand` state is set to 1, the game's frame counters
  (0x76c918, 0x76c91c) to 0, the AI dice reseeded.
- The game options that change play (CClientOptions at [app+0xb8]:
  difficulty, auto-target and the like) and the app's input block
  (app+0x604..0x7d0, the control scheme and bindings) are the host's
  (`sync_opts`, sent in the manifest). Volumes, subtitles, rumble and the
  mini-map stay each peer's own.
- Heap: from play on, blocks come from `HEAP_PLAY` (0x40000000) up, and
  blocks freed below it stay unused, so where play's blocks lie (the game
  orders some work by address) follows from play alone. VirtualAlloc
  reservations likewise from `VA_PLAY` (0xb0000000).
- Render caches the menus left unlike: blocks allocated while `heap_render`
  is set come from `HEAP_RENDER` (0x70000000) up, with their own free lists,
  so they move no play block. Native hooks set it around the texture cache's
  get (0x59cba0), the render state block table (0x59ad80), the scene's draw
  phases 1 and 2 (0x5df230) and the GUI draw (0x51e090).
- Random streams: `rand` calls from the renderer (return address
  0x5e0000..0x640000) take a stream of their own, since how much it draws
  follows the look settings; a crowd's update (0x4d7e70) runs on streams of
  its own for the CRT's and the game's LCG ([0x76c588]+0x24), since it draws
  only near the camera, which each peer has its own of.
- The frame rate is 60 online on both peers (the game's ClampFPS is forced
  off at boot so a rate change is live).

**Drift correction** (`Net_Fix`). The creatures' positions, facings and
health drift between the peers by a last bit now and then (seen from about
frame 6000, 1e-5 to 1e-6), so the hash leaves them out. At each hash frame
both peers snapshot them (`net_fix_snap`, `NET_FIX_KEEP` 4 kept); the host
sends its snapshot unreliably, in chunks of `NET_FIX_CHUNK` 40 entries {id,
7 floats}. When the joiner reaches a frame it holds both for, it adds the
host's value less its own to each creature still in play, and logs `net:
creature ID drifted D from the host's at frame N` past 0.25. A rejoin's
replay applies none.

`JE_INPUT_SCRIPT` takes `+N:Action`, N counting frames of lockstep play, for
runs whose menus differ in length.

Tested headless on localhost: with the joiner in the lobby from the start,
hashes equal through frame 11340 and drift held at 1e-5 or less. With the
joiner joining 4000 frames into the host's menu, one run held through 11460;
another desynced at 6660 (creature set different), an online-only
divergence not found yet: two solo `JE_LOCKSTEP=60` runs on the same script
agree through 11280.

**Player 2's hero on an open host** (v148, protocol version 8). A peer that
joins a running game plays its own pick of hero, not the one the host booted
with. The host keeps a list of hero switches, {frame, hero}: at each
handover frame (`net_switch_at`, at the top of `net_frame`, before replay) it
appends the hello's pick unless it is player 2's hero already (the last
entry's, or the boot one) or the frame already has one, and on every
frame that has an entry, on both peers, it sets `net_hero_switch`, which
`coop_hero` takes (recompiler.md §10). WELCOME carries the list (at most
`NET_SWITCH_MAX`, 16, changes of hero; later ones are dropped on both
peers alike and the hero stays), so a peer that rejoins
replays the earlier switches at their frames and stays in step. A switch
waits while `coop_hero` is not called (dialogue, cutscenes) and lands at
the next frame it is, which both peers reach on the same inputs. The pick
is the joiner's own: `settings_sync` leaves `P2_HERO` out.

**Save and settings from the host** (v149, protocol version 9,
`win32/net_save.odin`). The joiner plays on the host's `Save`, the host's
`JadeEmpire.ini` and the host's gameplay settings, never on its own, so
peers need not copy saves or match configs by hand and a rejoin always
boots as the host did. Only the build ID, the game exe, `override` and
`textures_hd` must match (the config check above).

- At boot, before it hosts, the host lists `Save` (every folder and file
  under it, sorted by name, with sizes) into a manifest with
  `JadeEmpire.ini` less `[Port]` (each peer's own: display, `NET_JOIN`,
  `P2_HERO`) and every `Setting_Id`'s value (`settings_vals`).
- After the WELCOME and before its own boot, the joiner fetches the
  manifest and builds a mirror of `Save` in a temp folder (`jade_net_*`):
  each folder made, each file made at its size but not filled. `host_path`
  maps the guest's `Save` onto the mirror and `JadeEmpire.ini` onto the
  host's ini written beside it, inside the lockstep block with `scratch`.
  `settings_sync` puts the host's value in force for each setting outside
  `SETTINGS_LOOK` that differs and logs it (`net: DRAW 200, the host's (ours
  100)`); the joiner's own ini and `Save` are never read or written. Accept
  in the Control panel while online writes the host's values to the
  joiner's ini.
- A mirror file is filled when the guest first opens it (`CreateFileA` on an
  existing file, `net_save_open`), unless the open empties it
  (`CREATE_ALWAYS`, `TRUNCATE_EXISTING`) or it is empty. So only what the
  game reads crosses: the thumbnails the Load menu shows and the save
  loaded (1 MB and 0.7 MB raw, 0.4 to 0.7 MB and 0.2 MB deflated), not all
  of `Save` (81 MB here). `net: fetched Save/<path>, N bytes as M` logs
  each. The game's frame waits on the fetch, and the host waits on the
  joiner's input as on any slow frame.
- On the host, a boot file the game is about to open to write, empty or
  delete (`DeleteFileA`, `net_save_remove`) is first copied aside to a temp
  folder once, and served from there, so a joiner that comes later still
  gets `Save` as at boot.
- Blobs: the manifest is blob 0 and manifest entry i is blob i + 1, each
  deflated (zlib, default level) on the host once and cached. The joiner
  sends BLOB_REQ {id, from} and the host answers with up to 32 BLOB packets
  of at most 1200 bytes ({id, size, raw, at, count} and the bytes); the
  joiner takes only the packet that follows what it has and asks again
  from there every 50 ms or once a burst is in. A size of 0 means the host
  cannot send it; 10 s with no progress (30 s for the manifest) fails the
  join. So does a raw size over the file's size in the manifest (16 MB for
  the manifest itself) or a deflated size over zlib's bound for it, checked
  as the first packets come in, before the blob is inflated.
- At exit the joiner removes the temp folder; nothing goes back to `Save`.
  A `Save.net` folder left by versions before 149 is no longer used.

Tested headless on localhost: a joiner whose ini differed (`DRAW`, `BLEND`,
`TURN`, `[Difficulty] Combat`) logged the three settings, listed the host's
132 entries in its Load menu with the same thumbnails, fetched two
thumbnails and the save loaded, and both loaded the same game with hashes
equal. An open host deleted the save its Load menu showed, the copies
aside held its two files, and a joiner that then rejoined fetched that
thumbnail (served from the copies) while replaying, caught up and played
with hashes equal. The host's `Save` and ini and the joiner's own `Save`
were unchanged after every run.

Tested headless on localhost: an open host with hero 0 (Blossom); a joiner
with `JE_P2_HERO=3` logged `coop: player 2's hero Jen Zi, was Blossom` on
both peers at its handover (3057); it was killed and a second joiner with
`JE_P2_HERO=6` rejoined, replayed the Jen Zi switch, and at its handover
(4679) both peers switched to Tan and dropped Jen Zi's own style. Hashes
stayed equal through frame 5340.

**Input packets** (protocol version 3 on) carry no magic: the first byte is the
kind, and only handshake packets start with `NET_MAGIC`. The header is 6
bytes: kind, the ack and the first frame as their low 16 bits (rebuilt
against the receiver's own frame by `frame_near`), and a count byte whose top
bit says a hash follows (frame low 16 bits and the 64-bit hash, 10 bytes).
Each input is coded against the one before it (the first against frame
first - 1's, which the receiver already holds or the packet is dropped): a
mask byte with one bit per changed axis, one for changed buttons and one for
the pad turning on or off, then each changed axis as a zigzag delta and the
buttons as an XOR, both LEB128 varints. An unchanged input is one byte. A
hash rides along in every packet whose range covers its frame until that is
acked. A packet whose first frame is past the next one wanted, or older than
the ring, is dropped; the ack is clamped to the frames actually sent. Over
about 4700 frames on localhost this is 9.6 bytes a packet against 88.6 for
version 2 (41-byte header, 16 bytes an input), 9.3 times less, before the
28 bytes of UDP and IP headers.

**Desync check.** Every 60 frames each peer sends a state hash. Before v153
it was XXH3 of the game's .data (0x75b000..0x889d74), the port's data page
(0xa00000..0xa01000), the heap up to `heap_top`, the VirtualAlloc region up
to `va_top`, `vclock` and the mixed sample count. Since v153 it is
`net_state_hash` (`native/sync.odin`): the CRT random state, the play frame
and the ids of the player and every dynamic creature, since memory outside
play keeps what each peer's menus left (lobby, below). A
mismatch logs `net: desync at frame N` once. The `JE_LOCKSTEP` lines carry
the clock and the mixed count as well, and `JE_LOCK_DUMP=frame:path` writes
the memory at that frame to `path.img` (the whole image, 0x400000..0xa01000),
`path.heap` and `path.va`,
so the dumps of two runs that disagree can be diffed word by word (heap
blocks are tagged `HEAP` and `FREE`).

Tested headless (two gamescope instances on localhost, frame-exact
`JE_INPUT_SCRIPT`): title, Load menu, save load, walk and a bandit fight with
player 2 attacking, 67 hashes equal through frame 4020 and the two screens
identical. Two `JE_LOCKSTEP=60` runs of the same script also match. Drive such
tests with `JE_INPUT_SCRIPT`, not the ctl channel (docs/recompiler.md §7): a
ctl `wait` ends a few frames late by a varying amount, so ctl `pad` commands
land on different frames in two runs and the runs diverge.

Peers on different CPUs (v152): the game's math is bit-exact whatever
`-microarch` built it (no fused multiply-add, the SIMD natives keep the scalar
order, and the transcendentals the game and its natives use come from
`x86/libm.odin`, not the system libm: docs/recompiler.md §4), so the build ID
covers sources, compiler and OS but not the CPU. Checked over localhost in the
dragonfly minigame: a `-microarch:native` (Zen 4, AVX-512) host and an
`x86-64-v3` joiner built in another directory, both flying and firing, kept
equal hashes through frame 6180, and again through frame 4740 with the
joiner's glibc held off its AVX2 and FMA variants
(`GLIBC_TUNABLES=glibc.cpu.hwcaps=-AVX2,-FMA,-AVX512F`). Two physical CPUs
and two glibc releases are untested. Rendering and audio still call the
system libm; they do not feed the game state. Tested
over localhost only, real links untested. Through a proxy that delays 50 ms with 20 ms of jitter (reordering
packets) and drops 5% of them, 78 hashes stayed equal through frame 4680; the
game then runs slower than 60 fps, as a 100 ms round trip exceeds the 4-frame
delay. A second mock WAN proxy (different delay per direction, burst loss,
duplicated packets, delay spikes that grow by 400 ms, blackouts) kept all 78
hashes equal through frame 4680 in three runs. At a 240 ms round trip with 2%
loss, the host picked a 10-frame delay; 105 ms stalled in all. Over poor
Wi-Fi (90/50 ms each way, 70% loss in bursts, a spike every 15 s), it picked
8 frames and stalled 3.6 s in all, nearly all of it during the spikes.
With the delay moving in play (v140) the far and blackout runs kept their
delay (10 frames, 276 ms stalled; 6 frames, 6.3 s); the spikes still stall
(4.3 s, the delay rising to 19 and back within seconds, 9.3 frames on
average), since a rise only helps inputs made after it and the round trips
that show a spike come a round trip late. Holding the delay up for 2 s
before each fall halved the stall time but averaged 14.5 frames, more lag
than the stalls it saved. What it does fix is a lasting change: with the
round trip going from 60 to 260 ms 40 s in, a fixed 4-frame delay stalled
31 s in all (every frame from then on), the moving one 0.4 s as it rose to
11 frames. All hashes stayed equal in each run.
Blackouts of 2 s and 4 s stalled both peers for 6.3 s, and play then resumed
without a peer-lost error (NET_LOST is 10 s). Area changes need nothing
extra: with the host walking from j01_beach into j01_town and straight back
(two loads, the trigger entered by stick and A from the input script), all 58
hashes stayed equal through frame 3480. Player 2's hero was set up again on
entering the town and was found by its id on the return, and the joiner's
stick moved it after both loads. Each peer shows its own player's camera; both
peers draw both views so drawing stays the same on both
(docs/recompiler.md §10).

## §12 I3DL2 reverb

The game sets DirectSound's I3DL2 reverb effect (`SetFX`) on every 3D mono
buffer it makes (flags 0x302b8). When a sound starts, exosoundbank
`0x674c70` passes the buffer the parameters of the sound environment the
player stands in (`SetAllParameters`), from its four callers (`0x679d87`,
`0x67a745`, `0x67b0f0`, `0x67b7fd`), but only when CExoSound has an
environment (`[[0x76c92c]+0x448]` non-null) and the sound's byte `+0x159` is
set. Buffers with the effect but no parameters keep the DirectSound default
preset. CExoSound's update (`0x66fb6d`) picks the environment: the first of
the area's sound shapes (`0x668d40` count, `0x668cf0` shape, `0x4fe440`
point in shape) around the point 1.8 m over the player's feet with a
non-zero environment, else environment 0. `0x4ae500` maps it through the
area's table (`[[area+0x1c]+0x140]`, 0x28 bytes an entry, reverb index at
`+0x18`), and `0x669600` makes that index current (`[+0x440]` table, 0x30
bytes an entry, `[+0x444]` count; index 0 means none; only while byte
`0x769d90` is set). At Two Rivers this is the FOREST preset with lRoom -830.

The port runs the effect (`win32/dsound_reverb.odin`). It is linear and
comes before the buffer's volume, 3D gains and pan, so a buffer's reverb
mixed with its gains equals the reverb of its mixed signal: buffers with the
same twelve parameters send their mixed left and right into one of four
buses, and each bus runs the reverb once per channel. A bus is freed once its
tail has rung out (reflections and reverb delays plus 1.2 times the decay
time after the last send); with all four in use, the one quiet longest is
taken over. The model follows the I3DL2 parameters:
- the send is low-passed to lRoomHF at flHFReference and scaled by lRoom;
- four early reflection taps (0, 4.1, 7.9 and 12.3 ms) start
  flReflectionsDelay later, at lReflections;
- the late tail starts flReverbDelay after the reflections. It passes four
  allpasses (gain 0.65 times flDiffusion) into an eight-line feedback delay
  network mixed by a Hadamard matrix. The line lengths are 37 to 80 ms,
  scaled by 0.5 + 0.5 flDensity. Each line decays 60 dB over flDecayTime,
  its highs over flDecayTime times flDecayHFRatio (capped at 1), at lReverb.

The output is the wet signal only; the dry signal is mixed as before. In the
Two Rivers fight the wet signal ran about 18 dB under the dry one, with no
NaN. The joiner hears player 2's environment instead (`ds_view.reverb`,
docs/recompiler.md §10). The Reverb row (`JE_REVERB`, docs/recompiler.md §11)
scales the wet signal: Low by 0.5, High by 2, and Off stops the sends, so
the mixer plays every buffer dry, as before the effect was mixed.

## §13 Windows build without Visual Studio

The Windows build needs no Visual Studio and no Windows SDK. It links with
the `lld-link` that ships in Odin's Windows release, against the libraries in
`port/winlib/lib` alone (`/nodefaultlib`; `-ignore-vs-search` on Windows,
where Odin otherwise stops with "Windows SDK not found"). `port/build.bat`
and `tools/build.bat` take the Odin release from `tools/odin.bat`, which
downloads the pinned `dev-2026-10` zip into `port/build/odin` and checks its
sha256. `port/build_windows.sh` cross-builds with the host Odin and the same
libraries. The library folder reaches `lld-link` through `LIB` on Windows,
as Odin splits `-extra-linker-flags` at spaces, so a `/libpath:` there cannot
name a folder with a space in it.

`port/winlib/lib` holds:
- import libraries for the system DLLs Odin's packages import (kernel32,
  advapi32, bcrypt, dnsapi, ntdll, shell32, ws2_32), made by `llvm-dlltool`
  from the export lists in `port/winlib/def`. `libucrt.lib` names
  `ucrtbase.dll`, which every `api-ms-win-crt-*` set forwards to; it ships
  with Windows 10 and later, so the exe needs no Visual C++ redistributable;
- `jadecrt.lib` (`port/winlib/crt.c`), the part of the C runtime that
  Visual Studio's static libraries put in an exe: `mainCRTStartup` (the
  ucrtbase set-up libcmt does, then Odin's `main`), the TLS directory
  (`_tls_used`, without which Odin's thread-local variables have no
  storage), `__chkstk`, `_fltused`, and `memcpy` and `memmove`, which live in
  `vcruntime140.dll`, not in ucrtbase;
- the C code, prebuilt: zlib 1.3.1 (Odin's own `vendor/zlib/libz.lib` holds
  MSVC link-time code generation objects, which `lld-link` cannot read;
  `tools/odin.bat` copies this one over it in its private Odin), capstone
  5.0.7 with `tools/capstone/capstone.c`, `movie.lib` (§4) and
  `vorbis.lib` (§7, built `/fp:precise -ffp-contract=off` like the Linux
  build). All of it is compiled `/Zl /GS-`: no default library and no
  security cookie, whose check lives in libcmt.

`port/winlib/build.sh` regenerates the folder on Linux, from xwin's copy of
the SDK (for the export lists and headers) and clang-cl; rerun it after a C
change. The build ID (§11) hashes the Odin version with the commit hash cut
to 7 digits, as the release's `odin.exe` reports 7 and an Odin built from a
checkout may report more.
