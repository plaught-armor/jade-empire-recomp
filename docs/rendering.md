# Rendering enhancements

Runtime: `port/src/win32/d3d9_*.odin`, `user32.odin`. The guest always sees the
D3D9 sizes it asked for; enhancements live entirely on the GL side.

## §1 Render-target scale

- Every render target and depth surface (`D3DUSAGE_RENDERTARGET` or
  `D3DUSAGE_DEPTHSTENCIL`, and surfaces from `CreateRenderTarget`,
  `CreateDepthStencilSurface` and the back buffer) gets GL storage at
  `rt_scale` times its D3D size. The factor is stored per resource in
  `Res.scale` (1 for ordinary textures), so a texture created before a scale
  change, or one never rendered to, keeps its own size.
- Uniforms stay in D3D pixels: the viewport transform and the XYZRHW path
  are unchanged, so geometry is unchanged. The exception is `pos_fix`, the
  D3D9 half-pixel shift, which is half a *host* pixel (divided by the scale).
  Shifting by half a D3D pixel moves every primitive `scale / 2` host pixels
  right and down; a full-screen quad covering exactly NDC ±1 then misses the
  centres of host column 0 and row 0. The glow pass (`FUN_005cc100`) builds
  its blur chain from such quads without clearing, so those unwritten texels
  (uninitialised GL memory) were blurred into coloured blobs along the left
  and top edges. A half host pixel keeps full coverage and places the image
  within a quarter of a D3D pixel of exact supersampling. Only the GL viewport, scissor and clear rects are multiplied by
  `fb_scale()`, the scale of the bound render target. Point sprites multiply
  `gl_PointSize` by `vp_z.z = scale`.
- `StretchRect` scales source and destination rects by each resource's own
  scale and copies with `gl_blit`.
- `D3DXLoadSurfaceFromSurface` does the same. The save thumbnail uses it: a
  512x512 A8R8G8B8 render-target texture level (scaled) is copied into a
  512x512 `D3DPOOL_SYSTEMMEM` surface (scale 1), which the game then locks and
  writes as `Save/<slot>/SaveImage.tga`. A system-memory surface has no
  readback on lock, so the copy allocates its shadow and reads the level back
  into it. Only GPU-blittable color formats are accepted (no swizzled or
  compressed storage); an X-format source gets destination alpha cleared to 1.
  Palettes and color keys are fatal.
- CPU access goes through D3D-size images: `LockRect` on a scaled surface
  downsamples to a temporary texture on the GPU (`surf_read`) and reads that;
  an upload to a scaled surface goes to a temporary texture and is blitted up.
  Compressed formats are never scaled (asserted). Shadow readback asserts scale 1.
- Present blits the back buffer at `w*scale, h*scale` to the window with linear
  filtering. When the window is smaller than the render size this is
  supersampling.
- Window: guest size times `wnd_scale`, the largest integer multiple that fits
  the usable display bounds. Mouse coordinates are mapped back to guest
  pixels by the window-size ratio (`to_guest`), for `GetCursorPos`,
  `SetCursorPos` and the mouse message lParam.
- `JE_SCALE=N` sets the render scale (capped at 8). Unset or 0: auto, the
  smallest integer multiple that covers the display height, capped at 4. A
  640x480 back buffer on a 1280x720 display renders at 2x (1280x960).
  `CreateDevice` logs the chosen scales.

## §2 Anisotropic filtering

- `JE_ANISO=N` (default 16) raises `GL_TEXTURE_MAX_ANISOTROPY` to at least N on
  samplers that are linear and mipmapped; the game's own
  `D3DSAMP_MAXANISOTROPY` is kept when larger. Point-filtered or non-mipmapped
  samplers are left alone: those are UI, lookup and post-process textures where
  anisotropy is wrong or useless. The value is clamped to the driver maximum.
  `JE_ANISO=1` disables the override.

## §3 Load-screen fade

- With the load-time fixes (`docs/hle.md` §2) the loading screen shows for well
  under a second, so its full-screen art only flashes. Present
  (`d3d9_fade.odin`) therefore never shows it: the window keeps the last
  ordinary frame, fades it to black over 0.25 s, holds black, and fades the
  first frames after the load in over 0.35 s. Each fade-in step is capped at
  1/30 s so a long first frame still shows the fade.
- Detection reads guest state at each Present. The loading screen is GUI panel
  0x41: `[[[0x76c924] + 0xb4] + 0x8c]` is the GUI manager's table of open
  panels by id (lookup 0x55d9f0), non-zero while the panel is open. The save
  message reuses panel 0x41 as a 320x135 box over the game, so only a panel of
  full GUI size (width at +0xc, height at +0x10, both 640x480) counts as a
  load. The main menu's attract movie (`MOVIES\ATTRACT.bik`, after idling on
  the menu) plays over an open full-size panel 0x41, so while any Bink movie
  is open (`docs/hle.md` §4) nothing counts as a load; otherwise the movie
  would be held black. The panel opens one or two frames before the load-progress loop starts
  presenting through 0x4a34d0, and the main loop presents those frames, so a
  call-site test would hold a frame of loading art; the panel test does not.
- The save message (the smaller panel 0x41) is hidden too. It is the box
  players took for a loading screen: autosaves open it right after many area
  loads and mid-area, and it shows for about 21 frames (measured with a
  quicksave). The game does not run while saving, so Present keeps the last
  ordinary frame without fading it, and a save reads as a short hitch.
- Every Present copies an ordinary back buffer into a window-sized held frame,
  blits that to the window, and, while fading, draws a full-screen black
  triangle blended at alpha 1 - level. That draw uses its own pipeline and
  VAO and rebinds the device's; the raster, blend and depth state it changes
  is applied again from render state by the next guest draw.
- After a new game the game itself presents black frames for about 2 s before
  its own fade-in; that is not this fade.

## §4 Hi-res fonts

- The game's text is 2-bit bitmap fonts at 22 px: `fonts/<name>.abc` holds
  per-char metrics, `fonts/<name>.sbm` the 32x32 cells. An `.abc` is an 8-byte
  header (byte 0 = 0x16, the pixel size), then 8-byte entries for chars
  1..65534 (char c at 8 + (c-1)*8): u16 `.sbm` offset (a multiple of 1024),
  2 unused bytes, u8 plane 0-3, then the Windows ABC widths as s8 A (left
  bearing), u8 B (ink width), s8 C (right bearing). Each `.sbm` byte packs four
  cells as 2-bit planes, `(sbm[off + y*32 + x] >> plane*2) & 3`; ink starts at
  cell column 0. A char the font lacks has offset 0, plane 0 and widths 0, 1, 8.
  `fonts/<slot>.ini` names each slot's European font (`euroabc`): CERIGO uses
  `eurodialog` (dialogue), SAVA, FNT_GUI and FNT_CONSOLE use `eurogui`.
- Glyphs are drawn from a cache texture, 1024x1024 A8R8G8B8 MANAGED with one
  level, created at return address 0x646847 (cache init near 0x6467c0). The
  upload at 0x644f00 (ecx = request) finds the cache node (lookup 0x643a90),
  locks the whole texture (LockRect returns to 0x644f5e), and writes the cell
  at node+0xc +8 (x) / +6 (y): each texel is plane value * 0x55 in all four
  bytes, read from `[req+4] + [req+0x14]` (`[req+0xc]` = 1024 bytes); the char
  is u16 at req+0x18. Text quads (0x6409xx) span pen + A to pen + A + B and
  sample the cell's full 32-texel height, so a cell is a fixed box with ink
  from column 0 and the baseline at a fixed row.
- Replacement fonts are baked offline so no font file ships or loads at run
  time: `tools/fontbake` (Odin, stb_truetype; build with
  `odin build tools/fontbake -out:tools/fontbake/fontbake`, run
  `fontbake <game dir> <font file> <abc name> [scale]`) writes
  `<game>/fonts_hd/<name>.abc` and `<name>.glyphs`. It fixes the outline's
  scale so its `H` has the bitmap `H`'s ink height, takes the baseline row as
  one below the bitmap `H`'s last ink row, and rewrites A, B, C in a copy of the
  original `.abc` for every char the outline has (A = left edge of the pixel
  ink box, B = its width, C = rounded advance - A - B). The `.glyphs` file is
  `JEG1`, u32 scale S (default 4), u32 count, then per char u32 char, i16 x,
  i16 y, u16 w, u16 h and w*h 8-bit coverage: the ink box in a 32S cell, ink
  from column 0 (shifted by A), baseline at the bitmap's row. At startup the
  port (`win32/font_hd.odin`) loads every `fonts_hd/*.glyphs`; CreateFileA
  serves the baked `.abc` for any guest open of `<name>.abc`, so layout uses
  the outline's spacing.
- fontbake also takes a Texmod image of the whole glyph cache (a `.png`) in
  place of a font. Dialogue Overhaul's `JE-Fonts.tpf` is one: a ZIP XORed with
  0x3FA43FA4 (little-endian dword), entries under Texmod's fixed ZIP password,
  holding `texmod.def` and an 8192x8192 RGBA PNG (cache at 8x, glyph in alpha);
  `tools/untpf` unpacks it.
  Its cells are the cache as the main menu fills it: eurogui from slot 0, then
  eurodialog from slot 87, each in the order
  ``a-z A-Z 0-9 -+=`'",.!@#$%^&*()<>:;/\?`` (87 chars; slot s at cell s mod 32,
  s / 32). Matching each cell, scaled down, against the `.sbm` cells confirms
  the order. The glyphs were drawn over the original cells, so the original
  `.abc` stands; each cell is box-averaged to scale 4. The dialogue font in use
  is the mod's eurodialog; other chars (e.g. the ellipsis) take the Gaussian
  fallback below.
- At render scale k > 1 the cache texture gets GL storage at k times its size
  (Res.scale, as §1). At each glyph upload the lock notes char and cell; the
  unlock draws the baked glyph into the scaled cell, coverage in all four
  channels, directly when S = k and through a linear blit otherwise (exact 2x2
  averaging for S = 4, k = 2). A glyph from a font with no bake, or a char the
  outline lacks, is rebuilt from the guest's own cell: 2-bit coverage resampled
  with a Gaussian (sigma 0.55 cell texels, radius 2), then a smoothstep about
  coverage 0.4 with half-width 0.6/k. Plain bilinear left the bitmap's
  staircase blurred, bicubic alone kept it jagged; the pre-blur rounds stairs
  and the narrow smoothstep keeps an edge about one output pixel wide.
- The upload request names its font by a key internal to the cache: byte
  req+0x1a is not the font manager's slot (0x79be60, names at +0x40, count at
  +0xc0); mapping it from the slot drew the GUI outline for dialogue text. The
  cache (0x645c00) reopens every loaded font's files in its own order. So the
  font is found by content:
  the request's 1024 source bytes are compared with each replaced font's
  `.sbm` at the char's offset (the original files in `fonts/`). A char the bitmap lacks points at offset 0, which
  still matches only its own font.

## §5 Frame rate

- The game caps itself at 30 fps: with `[Game] ClampFPS=1` (default 1, read
  once at 0x4a42df) the main loop 0x4a3a40 waits until 33 ms have passed since
  the previous frame. `ClampFPS=0` runs uncapped, held by vsync.
- The engine runs on elapsed time. Each frame the main loop stores the time
  since the previous frame, clamped to 0.0001..0.25 s, at
  `[0x76c924]+0x20`. Movement, animation and the game clock use it. Measured
  with the same input at 30 and 60 fps (5 s of frames, then 3 s of walking
  forward from the same save): game clock +5.07 s / +5.03 s, walk distance
  10.528 m / 10.528 m. Animation time advances at the same wall rate.
  Combat (pirate camp, the fight after the slave-pen conversation, six light
  attacks): player and foe animations advance by elapsed frames / fps at
  both rates (60 fps: 0.167 per 10-frame sample, 30 fps: 0.233 per 7), and
  hits, stagger and the foe's combos play out alike.
  At 144 fps (gamescope `-r 144`): game clock +5.01 s, walk 10.533 m, and
  the same fight holds 144 fps once the build fixes in docs/recompiler.md §2
  are in (80-90 fps before).
  Death (`ApplyEffectToObject(GetPlayer(), 0, EffectDeath())`, then frames
  until panel 0x40): 187 frames / 6.23 s at 30 fps, 902 frames / 6.26 s at
  144. Unscaled, the 63-frame wait would have opened it about 1.7 s early.
- Conversations and in-engine cutscenes run at the `JE_FPS` rate (the
  slave-pen conversation holds 144). The 30 fps stretches are Bink movies
  (e.g. `J02_SKY_INTRO.bik` before that conversation): the movie loop 0x55a700
  presents once per movie frame at the movie's own rate, and the game does not
  update meanwhile (the frame counter at 0x76c918 stands still).
- The port overrides `ClampFPS` to 0 for every session (an `ini_override`;
  the file is not written) and Present sleeps to hold the Frame Rate setting
  (`JE_FPS=N`), 30 included, so a change is live. `JE_FPS=0` leaves only
  vsync. Online games run at 60 on both peers (docs/hle.md §11).
- Menus. With `JE_FPS` set, Present holds `JE_MENU_FPS` (default 60) while
  GUI panel 0x02 `MAINGAME` (main menu, load list) or 0x2c `LTI_INGAMETABS`
  (the in-game menu: Escape, J, I, C) is open, when that is below `JE_FPS`.
  `JE_MENU_FPS=0` runs menus at `JE_FPS`. The frame-rate average skips menu
  frames, so the frame counts keep the gameplay rate on return. The in-game
  menu pauses the game (the counter at 0x76c918 and the game clock stand
  still), so nothing runs at the lower rate. Measured at `JE_FPS=144`: main
  menu, load list and in-game menu 60 fps, the field 144 before and after.
- Frame counts. The 64-bit counter at 0x76c918 goes up by one per frame
  (0x4a48dc). Most of its readers turn a time into frames using the frame
  time (0x582c80, an item sequence), so they hold at any rate. A few use
  fixed counts written for 30 fps:

  | Site | Count | Use |
  |---|---|---|
  | 0x42b776 | 63 | death: frames until the death panel (0x40) opens |
  | 0x4d5094 | 5 | update throttle: work every 5th frame (0x4d7f04) |
  | 0x4eaa3c, 0x4eaa43 | 30 / 10 | creature trail: a point every 30 (10) frames, 5 kept |
  | 0x4f080b, 0x4f0826 | 30 / 10 | creature periodic check (0x479be0 event 9) |

  `FRAME_COUNTS` in `tools/x86rec/lift.odin` lists these instructions. The lift emits
  `x86.frames(imm)`, which returns the same span at the current rate:
  `x86.frame_rate` (Present's frame period, smoothed and rounded to whole
  fps) × imm / 30. At the stock cap the rate is 30 and the counts are unchanged.
  Frames longer than 100 ms (loads, hitches) are left out of the average: the
  throttle count is stored when an object is created, often during a load.
  Frames while a Bink movie is open are left out too: they come at the
  movie's rate, and without the skip the average sat at 30 when the movie
  closed and took about 30 frames to climb back, so counts taken right after
  a movie came out up to 4.8 times short at 144 fps.
- Not covered: per-frame steps that use neither the counter nor the frame
  time (a fixed lerp factor, a per-update counter in an object). None is known.
  Comparing runs at 30 and 60 fps with the same input is how one would surface.

## §6 Vertex and index buffer uploads

A buffer's guest shadow is mirrored into its GL buffer at draw time, not on
Unlock. Lock widens the buffer's dirty byte range; each draw uploads only the
dirty bytes it reads (`buf_sync`): per stream `offset + [first, first + n) *
stride`, where an indexed draw's vertices are `BaseVertexIndex +
MinVertexIndex` plus `NumVertices`, and for the index buffer `[startIndex,
startIndex + count)` indices. Uploaded bytes at either end of the dirty range
are trimmed off it; a draw reading the middle leaves the range as is, so it
stays a superset of what differs from GL.

A static buffer (no D3DUSAGE_DYNAMIC) uploads its whole dirty range at the
first draw that reads any of it, which clears the range. With the trim alone, a
static buffer filled once and drawn from its middle kept its dirty range, so
every draw from it uploaded again: about 900 KB a frame standing in the second
save, about 5% of the main thread in the driver's memcpy. Static buffers are
written once, at load, so the whole upload happens once. v47 against v46,
alternating: 5.77-5.89 against 6.13-6.26 M cycles per frame.

Why: the game locks most dynamic buffers with size 0 (to the end) and
D3DLOCK_DISCARD, then writes and draws a small part. Uploading the whole locked
range on Unlock sent 5–10 MB a frame in combat (~200 locks, about 1 GB/s at
128 fps); draw-ranged uploads send ~40 KB for the same frames, and combat at
`JE_FPS=144` went from 108–131 fps to 133–142 fps. The index hints are trusted
as D3D9 requires; a scan of every indexed draw's indices through a combat
found none outside them.

## §7 Shader constant uploads

The device keeps shader constants (`Vs_Consts`, `Ps_Consts` in `ds`) as
register files: one 16-byte slot per F, I or B register, a B register's BOOL
in the slot's first lane. A `Set*ShaderConstant*` call copies the guest data
straight into its slots; an F set marks the bank dirty and raises `const_hw`,
the bank's highest register written + 1. Shaders read only F registers (DEFI
and DEFB are fatal in `gen_scan`), so I and B are kept for the Get calls and
never uploaded.

Each shader's uniform block holds only the F registers it reads, packed
(v67). `const_layout`, at shader creation, lists the registers read by
static index, ascending, without the DEF'd ones (GLSL literals), in
`Shader.cregs`; `vc[i]` in the generated GLSL is `cregs[i]`. A shader that
reads constants relatively (the skinning shaders, `vc[a0.x + k]` with the
bone index from vertex data) cannot be bounded statically: its block is the
prefix c0 .. c(n-1), n covering `const_hw` and every static read, rounded up
to 16, carried in bits 16+ of the variant key (`const_key`), and reads go
through `vc_rel`, which returns 0 past n as D3D does for registers never
written. In the cave a non-skinned vertex shader reads about 30 of 256
registers, a pixel shader 1 to 3 of 32, and the bone palette ends at c188 (a
192-register prefix).

A draw packs the blocks of its stages whose bank is dirty or whose layout
(shader, prefix) differs from the last pushed (`upload_consts`) into the next
range of one ring buffer (`dg.const_ring`, `CONST_RING` bytes, ranges at
`UNIFORM_BUFFER_OFFSET_ALIGNMENT`) and binds it with `glBindBufferRange`.
Writing a range past everything written since the last
`glInvalidateBufferData` lets the driver write without waiting for or copying
around the GPU's reads; overwriting a fixed buffer the GPU may still read
makes it stage a copy, which is why the old path uploaded whole fixed blocks
(4608 and 1024 bytes) per dirty draw. Room for both blocks is made before
either is written, since a wrap invalidates the other block's range too, and
a wrap forgets every pushed layout. The shadow depth pass pushes its casters'
blocks through the same ring (§12). v67: 662 to 687 fps (`JE_FPS=1000`, cave
save); a typical draw now uploads about 500 bytes instead of 5.6 KB.

Comparing a set call's data with the slots and leaving the block clean when
nothing changed was tried (v66) and dropped: the game's set calls nearly always
change something, so draws uploaded as often and the compare cost 1.7% of the
main thread.

Raster state (`apply_raster`): `dg.raster` holds the GL state the last draw
set (cull, polygon mode, scissor, viewport, depth range, blend, color masks,
depth, stencil, polygon offset) and the MISC block it uploaded. A draw issues
only the calls for what differs, and uploads MISC only when its bytes differ.
Under glthread every GL call is marshalled on the main thread, and a draw used
to issue about 25 of them plus a MISC upload whatever changed. Code that sets
any of that state directly (Clear, the shadow, bloom, SMAA and fade passes, the
X8 alpha fill in `D3DXLoadSurfaceFromSurface`) calls `raster_lost`, and the
next draw sets it all again; a blit, which only disables the scissor test,
records that in the cache instead. v66: 636 to 662 fps (`JE_FPS=1000`, cave
save), the main thread's share in `win32::` from 19.0% to 16.1%.

## §8 MSAA

`port/src/win32/d3d9_msaa.odin`. The game's own Anti-aliasing row (Video
Settings, ini `[Graphics Options] FSAA`) sets the sample count.
`CheckDeviceMultiSampleType` reports 2, 4 and 8 samples, so the game lists
Off, 2x, 4x and 8x and stores the list index in `FSAA` (0 to 3); it passes the
chosen type in the present params' `MultiSampleType`, and every
`CreateDevice` and `Reset` gives the back buffer and the auto depth surface
each a `TEXTURE_2D_MULTISAMPLE` twin with that many samples (clamped to the
driver's color and depth maximums) at the surface's GL size, or none for
Off. Accept on the panel resets the device, so a change applies at once.
The game asks for no multisampled render targets or depth surfaces of its
own, and its frame effects, bloom and focus trails stay on with
anti-aliasing on. The game's default, and the shipped ini's, is Off. Until
v78 the port had its own Multisampling row (`[Port] MSAA`, `JE_MSAA`, default
4) and the game's row stayed at Off.

- State per twin (`Ms_Surf`): `live` means the twin holds the surface's
  content; `dirty` means it holds content the single-sample texture lacks.
- `fb_bind` attaches the twins only when every bound attachment has a live
  one, since a GL framebuffer cannot mix sample counts. Otherwise each bound
  live twin is resolved and dropped (`ms_pick`). A draw or clear on the twins
  marks them dirty (`ms_mark`).
- Every other access to the surface resolves first (`ms_read`: a blit,
  nearest for depth): `StretchRect` and `D3DXLoadSurfaceFromSurface` sources,
  `LockRect`, Present and the frame dumps. A write outside the framebuffer
  (blit destination, writable lock) resolves and drops the twin (`ms_write`),
  because GL cannot blit into a multisampled image.
- A dropped twin comes back on a clear that covers the whole surface
  (`ms_clear_arm`): no viewport or scissor cut, color for the back buffer,
  depth plus stencil for D24S8 (depth alone for formats without stencil).
  The game clears both every frame, so no single-to-multisample copy is
  needed.
- A frame in combat resolves color twice (glow capture, Present) and depth
  once (the `StretchRect` of the auto depth surface at `005e58c0`). The cost
  is within run-to-run noise at 600 fps.
- Alpha to coverage (v79): a draw on the twins whose alpha test is GREATER
  or GREATEREQUAL (MISC `mode.w` = the sample count, set in `apply_raster`)
  writes `gl_SampleMask` instead of discarding. The pixel program puts the
  test's edge half a step past the reference (ref + 0.5 for GREATER, ref - 0.5
  for GREATEREQUAL, in 0..255 alpha), spreads it over one pixel of alpha
  change (`fwidth`, at least one step) and covers that fraction of the
  samples, rounded; none covered still discards. Alpha flat at a value the
  test fails covers nothing, so fully transparent texels write no depth, as
  before. Foliage, grass and hair edges come out smooth instead of stair-
  stepped. Every alpha-tested draw in the game also blends (references 0, 8,
  89, 102 seen at Two Rivers); the covered samples still blend, so a gate on
  blending off would have caught nothing. The alpha written is the game's;
  only coverage changes. Off (no twins) keeps the plain test. There is no
  setting: it is part of the game's Anti-aliasing row.
- MSAA smooths geometry and alpha-tested edges; shader aliasing is left to
  SMAA (§9).

## §9 SMAA

`port/src/win32/d3d9_smaa.odin`. SMAA 1x (Jimenez et al.), on by default;
`JE_SMAA=0` turns it off. The shader is the reference `SMAA.hlsl` compiled as
GLSL 4 (`SMAA_GLSL_4`, `SMAA_PRESET_HIGH`, color edge detection) with its
precomputed area (160x560 RG8) and search (64x16 R8) textures, kept in
`port/src/win32/smaa/` under its MIT license and embedded with `#load`. The
`.bin` files are the byte arrays of `AreaTex.h` and `SearchTex.h`; the shader
file differs from upstream only in LF line endings and two non-ASCII bytes in
a comment diagram replaced by `.`.

- It runs once per frame over the back buffer, at the first `StretchRect` out
  of it (the glow capture, `005ce7b8`, which comes before the UI), else at
  Present. In a dialogue frame the subtitle text is byte-identical with and
  without SMAA, so the UI is untouched there.
- Three passes at the back buffer's GL size: edges (RG8), blend weights
  (RGBA8), neighborhood blending. The last pass writes into the MSAA color
  twin when it is live (every sample gets the pixel's result, and later draws
  stay multisampled); otherwise into a work texture blitted back into the
  surface.
- Texture coordinates: the device runs with `ClipControl(UPPER_LEFT)`, so the
  full-screen triangle maps clip y = +1 to texture row 0. The lookup textures
  are uploaded row 0 first, as in D3D.
- State: the passes use their own pipeline, VAO, framebuffer and samplers on
  units 0 to 2. The draw path sets everything else again from render state;
  the pipeline, VAO and samplers are restored after the passes.

## §10 Soft particles

`port/src/win32/d3d9_soft.odin`, on by default; `JE_SOFT=0` (setting SOFT)
turns it off. A blended particle quad fades out over `SOFT_RANGE` (0.4 world
units) of view depth in front of the scene behind it, so smoke, fire, sparks
and the hanging haze sheets no longer cut a hard line through floors and walls.

- Eligibility (`soft_prepare`, after `fb_bind`, before `apply_raster`): the
  fixed-function pixel stage (`ps 0`), a game vertex shader or FF transform
  (not pretransformed), alpha blending on, z test on, the bound depth surface
  the auto depth surface, and a vertex declaration with COLOR and TEXCOORD but
  no NORMAL or BLENDWEIGHT. Source blend SRCALPHA scales alpha; ONE, ONE scales
  color; any other blend is left hard. The projection transform must be a D3D
  perspective (`_34 = 1`, `_44 = 0`, `_43 != 0`). Stencil shadows (`ps 1`) and
  lit additive meshes (`ps 12`) never qualify.
- Depth copy: the scene depth is blitted from the bound framebuffer (its MSAA
  twin when live; the driver picks the resolved sample) into a texture of the same
  internal format on unit 16, past the 16 D3D samplers. It is copied again
  only when a z-writing draw, a z clear or Present has happened since, so a
  run of particle draws shares one copy.
- Fade: the FF program key gains a `soft` field; the program reads the copy
  with `texelFetch` at `gl_FragCoord`, undoes the viewport depth range
  (`vp_z`), and makes both depths linear with the projection's `_33` and `_43`
  (MISC `soft`): view z = `_43 / (z_ndc - _33)`, the fragment's own view z is
  `1 / gl_FragCoord.w`. The factor `clamp((z_scene - z_frag) / SOFT_RANGE)`
  multiplies alpha or color.
- In the quick-save cave the haze sheets lose their seams on the ledge and
  the walls. A frame with no eligible draw does no copy.

## §11 Bloom

`port/src/win32/d3d9_bloom.odin` and `port/src/native/glow.odin`, on by
default; `JE_BLOOM=0` (setting BLOOM) keeps the game's glow. This is a
deliberate change, not a bit-exact replacement: same strength, smoother shape.

- The game's pass is `0x5cc100`, cdecl(capture texture), plain `ret`, called at
  `0x5ce7be` right after the frame is StretchRect'd into the capture texture
  (`0x5ce7b8`), gated by flag bit 2 and byte `0x76ea6c`. It runs a bright pass
  through three 8-bit lookup textures (dump `ps037`, texreg2ar/gb), shrinks
  320 to 160 to 80 with `ps010` (t0 times v0, v0 = vc[94] = white), blurs with
  7 additive draws of `ps014` (4 taps each, weights in pixel constants) and
  adds the result back ONE, ONE with `ps010`. At 80 x 60 the glow shows blocks
  and shimmers as the camera moves.
- Globals: threshold f32 r, g, b at `0x75ebfc` (cave 0.204, 0.133, 0.035),
  rounded to 1/255 by the lookup build; `0x75ec08` is 1 + slope (cave 1.12, so
  slope 0.12); f32[28] tap weights at `0x75ec50` (cave sum 8.59); `0x75ec0c` is
  the dirty flag that rebuilds the lookups. Each lookup entry is
  `round((level - threshold) * slope)`, clamped at 0.
- Replacement (`Glow_005cc100`): skips the whole guest function, which leaves
  the cached blend state of `0x5c7a80` (`0x75d3c0/4`) consistent. Threshold is
  `(round(t * 255) + 0.5 / slope) / 255`: the lookup's rounding passes nothing
  below half an output level, so that dead zone moves into the threshold.
  Gain is slope times the weight sum (about 1.03 in the cave).
- Bloom (`bloom_frame`): R11F_G11F_B10F levels from half the back buffer's GL
  size, `BLOOM_LEVELS` (5) deep. The first level takes the 13-tap downsample of
  Jimenez's Call of Duty bloom with the bright pass `max(c - threshold, 0)` per
  tap; each further level the same filter without it. Going up, each level is
  added ONE, ONE onto the next larger through a 3 x 3 tent; the last tent adds
  level 0 times `gain / BLOOM_LEVELS` into the back buffer, its MSAA twin when
  live (marking it dirty). State touched outside render state (pipeline, VAO,
  unit 0's sampler) is restored.
- In the quick-save cave the image mean, left 200 px excluded, is 67.8, 42.6,
  31.6 with the game's glow and 67.8, 43.2, 31.1 with bloom: the strength
  matches within 0.6 levels, and the torch halos are round and steady.

## §12 Soft shadows

`port/src/win32/d3d9_shadow.odin`, on by default; `JE_SHADOW=0` (setting
SHADOW, row "Shadow Maps") keeps the game's stencil shadows. A deliberate
change: same placement and darkness, the creature's silhouette with soft edges
instead of an aliased volume blob.

- The game's shadows: each creature draws a stencil shadow volume with a
  vertex shader that extrudes back faces away from the light (`vs 99`, dump
  `vs098`, skinned). Then `0x5e5800` StretchRects the auto depth surface into
  a 640 x 480 D24S8 surface (13553030), fills a 640 x 480 mask target with a
  quad (`vs 108`, colour ARGB at VB +12) where the stencil count is above
  0x7f, and composites a 4-tap blur of the mask over the frame (`vs 115`,
  `ps 54`).
- `vs098` layout: vc0..3 projection times world-view, vc4..7 the inverse
  world-view (the light vc14 is in view space), vc13.x the position w,
  vc13.yzw the extrusion parameters (z = depth bias), vc16 the colour. Skinning
  blends 3 bones: `a0 = floor(v2.xyz)` indexes vc rows directly, weights
  `v1.xyz`. Stream 0 (stride 24): POSITION FLOAT3, NORMAL FLOAT3; stream 1
  (stride 12): BLENDWEIGHT SHORT4N at +0, BLENDINDICES UBYTE4 at +8.
- Recording (`shadow_draw`, from both draw entry points before
  `draw_prepare`): a volume draw is saved with its stream, index and constant
  state instead of drawn, up to `SHADOW_CASTERS` (64) a frame. The constants
  are kept packed as the volume shader's block (§7) in `shadow.consts`, one
  array for the frame's casters, not a whole register file per caster. Its bound
  (`shadow_bound`) is computed by skinning up to `SHADOW_BOUND_VERTS` (256)
  vertices on the CPU with the recorded bone palette, plus `SHADOW_BOUND_PAD`.
  The bind-pose positions are not usable: a skinned creature's raw vertices
  sit near the model origin, not where it stands, and a light box fitted to
  them misses the creature. Unskinned meshes use the raw positions; a mesh
  whose vertices cannot be read gets `SHADOW_RADIUS` (2.5).
- Depth pass (at the mask draw): an orthographic light box around all bounds,
  power-of-two side of at least `SHADOW_MIN_EXTENT` (4), centre snapped to
  texels so the map does not crawl, into a `SHADOW_SIZE` (2048) D32F map. Each
  caster is redrawn with its own vertex shader, vc0..3 replaced by light times
  world and vc13.yzw zeroed (no extrusion), polygon offset (1.5, 2).
- Mask pass: a full-screen pass into the game's mask target rebuilds each
  pixel's world position from the game's depth copy (scene projection: near
  0.1, infinite far, `z_ndc = 1 - 0.1 / w`) and filters the map with PCSS: a
  16-tap Poisson blocker search within `SHADOW_SEARCH`, a penumbra of
  `SHADOW_SOFT` per unit of blocker distance clamped to `SHADOW_MIN_PEN`
  texels and `SHADOW_MAX_PEN`, PCF through `sampler2DShadow`, normal offset,
  and interleaved-gradient-noise rotation. Output is the game's colour with
  alpha times the shadowed fraction; the game's blur and composite then run
  unchanged.
- The game's own Video row "Soft Shadows" is the master switch: Off draws no
  volumes and no mask, so neither path shows a shadow. The port's row is named
  "Shadow Maps" to keep the two apart.
- Creatures are drawn after the depth copy, so they are not in it and receive
  no shadow, as in the original. In the quick-save cave the light is nearly
  overhead, so the shadow is under the player's feet; pitched down over the
  grate, the original shows a blurred blob and the port the figure's outline
  at about the same darkness.

## §13 Widescreen GUI

The game's Video panel already offers Aspect Ratio (Normal / Widescreen) and
the 16:9 modes the port lists (`win32/user32.odin` `MODES`); the 3D view is
hor+ from ScrW/ScrH on its own. The GUI is not: it is laid out on a 640x480
virtual screen and scaled by GUI_SX = W / 640 (0x75b3b8) and GUI_SY = H / 480
(0x75b3bc), set at 0x597c60, so at 16:9 every panel, font and border is
stretched sideways. `native/widegui.odin` fixes it when W·3 > H·4
(`wide_gui_on`, no setting; at 4:3 the guest's own values stand):

- Every GUI draw goes through a clip-rect stack at 0x79df68 (10 bytes each:
  i16 x, y, w, h, flags). A pushed rect is its parent's origin plus its
  virtual rect times the scales (0x5da590), and a panel draws into its rect's
  viewport with a unit ortho. The root is the full viewport, set each GUI
  frame by 0x5da240. The native runs it, then sets GUI_SX to GUI_SY and makes
  the root a centered 4:3 rect: width round(640·GUI_SY), left edge
  (W − width) / 2. GUI_SX has 15 uses; the floating world labels (the
  "Level Up" text) still land on their objects.
- The mouse (0x51cea0) reads GetCursorPos minus the client rect's left edge
  from GetWindowInfo and divides by GUI_SX. `win32.client_dx` moves that
  rect by the root's left edge for the call, so the cursor hits the centered
  panels.
- The side bars are cleared to black by `Dev_Clear` (`win32.gui_bar_w`) after
  each full back-buffer clear; the game's clear colour (0x76f880) is olive.
- A movie drawn to the full screen (0x67f0e0, thiscall flags, x, y, w, h;
  w or h <= 0 is the back buffer's) is drawn at its own aspect, centered:
  the Bink and HD movies are all 4:3.
- The HUD is a GUI panel like the rest, so it is pillarboxed too rather than
  anchored to the screen edges.

## §14 Sharpening and vibrance

`port/src/win32/d3d9_cas.odin`, settings SHARPEN (Off, Low, Medium, High;
default Low) and VIBRANCE (Off, Low, Medium, High; default Off), and
MOVIE_SHARPEN and MOVIE_VIBRANCE (same levels, both default Low) in their
place while a movie plays. One
full-screen pass in the SMAA chain (`smaa_frame`, §9), after SMAA when that
is on, so it also runs before the UI and leaves the text alone.

- Sharpening is AMD's contrast-adaptive sharpening (FidelityFX CAS, MIT),
  the no-scaling form: per channel, the 3x3 neighbourhood's min and max give
  an amount `sqrt(min(mn, 2 - mx) / mx)`, so flat and already-contrasty areas
  sharpen less, and the cross neighbours are weighted by amount times
  `-1 / mix(8, 5, s)` with s = 0, 0.5, 1 for Low, Medium, High.
- Vibrance mixes away from Rec. 709 luma by `1 + v (1 - saturation)`, v =
  0.15, 0.3, 0.5, so muted colours gain more than saturated ones.
- The pass reads with `texelFetch` (edge pixels repeat) and keeps the alpha.
  With SMAA on, SMAA writes the work texture `smaa.out` and CAS writes the
  multisampled twin or the free blend texture; with SMAA off it reads the
  back buffer itself. It runs at the back buffer's GL size, so at render
  scale above 1 the sharpening is partly lost in the downscale.
- While a Bink movie is open only CAS runs, at the movie levels; SSAO and
  SMAA have nothing to do on film. The movies_hd replacements are already
  upscaled (realesr-animevideov3); the scene's level on top of the photo
  model x4plus looked oversharpened, so movies have their own. The pass
  runs over the whole frame, so text drawn over a movie is filtered too.

## §15 Ambient occlusion

`port/src/win32/d3d9_ssao.odin`, setting SSAO (Off, Low, Medium, High;
default Medium). Volumetric obscurance (Loos and Sloan 2010) from the scene
depth, at the head of the SMAA chain (§9), so it darkens the 3D view only.

- It runs only from the scene path: `smaa_frame(true)` from the StretchRect
  out of the back buffer, not from Present, which is the UI-only path.
- The view position of a pixel comes from the multisampled auto depth
  (resolved by `ms_read`) and the last perspective projection the game set
  (`ssao_projection`, called from `Dev_SetTransform(PROJECTION)`; the game
  alternates its right-handed scene projection with identity, which is
  skipped). Distance is `|_43 / (_34 z - _33)|`; texture row 0 is NDC y = +1;
  z = 1 (sky) counts as infinitely far.
- NDC is taken relative to the viewport that projection draws into on the
  back buffer, recorded by `ssao_projection` and `ssao_viewport` (from
  `Dev_SetViewport`); pixels outside it are left alone. Character creation
  draws its scene into the left panel only (aspect about 0.54); with
  full-screen NDC the reconstructed positions were wrong and the whole
  character came out heavily darkened.
- No normal is used. The first version was scalable ambient obscurance
  (McGuire et al.), which weights each tap by a normal rebuilt from the depth
  differences. That normal is flat per triangle, so on low-poly characters
  close to the camera the occlusion stepped per triangle: in the opening
  dialogue the back of the sparring partner's neck, between the hair and the
  collar, came out nearly black in triangles. An angle bias removed the
  triangles only by removing almost all the occlusion.
- 12 taps on a golden-angle spiral over a disk of 0.6 world units, rotated
  per pixel by interleaved gradient noise. Each tap stands for the column of
  the sphere of that radius along the view axis through it, half-height
  `h = R sqrt(1 - t^2)`; the part behind the tap's depth,
  `clamp(d + h - d_tap, 0, 2h)`, is the filled share. A tap more than two
  radii in front of the pixel is another object and counts half full. The
  occlusion is `max(2 filled / total - 1, 0)`: a flat surface is half full
  and stays unchanged, a crease darkens, a convex surface does not.
  Intensity 0.6, 1.0, 1.5 for Low, Medium, High. The disk is capped at a
  quarter of the viewport height and skipped below one pixel.
- The occlusion fades out between 40 and 80 units of distance, and as the
  disk shrinks from 3 pixels to 1. Without the distance fade, low-poly
  backdrops (the mountain behind the Two Rivers school gate) drew a dark line
  along every concave triangle edge, a wireframe look; without the pixel
  fade, the occlusion stopped along a visible line where the disk reached one
  pixel.
- A depth-aware 5x5 mean (neighbours within 5% of the pixel's distance)
  removes the noise and is multiplied into the back buffer, or its live
  multisampled twin, with blend `ZERO, SRC_COLOR` (alpha kept). SMAA and
  CAS then run on the darkened image.
- Without a perspective projection seen yet, or with the depth at another
  size than the target, the pass is skipped.

## §16 Draw distance

`port/src/native/drawdist.odin`, setting DRAW (Original, Far, Very Far,
Extreme: 100, 150, 200, 300% of the area's distances; default Very Far).

The scene projection's far plane is 10000 units (`_33` = -1.00001 with near
0.1), so geometry is never clipped by distance; the `FarClip` key at
0x6851fc belongs to the minigame camera. What limits the view are distances
each area sets when it loads (0x4acf30, keys of the area's section, missing
keys falling back to built-in defaults):

| Global | Key | Default | Effect past it |
|---|---|---|---|
| 0x75d08c, 0x75d090 | `characterfadenear`, `characterfadefar` | 16, 24 (stored doubled: 48) | creatures fade out, then are not drawn |
| 0x75f2cc | `animatehierarchylodfar` | 24 | animation not updated |
| 0x75f2d0 | `danglybonelodfar` | 24 | dangly bones not simulated |
| 0x75f2d4 | `windupdatelodfar` | 24 | wind not updated |
| 0x79e178 | `shadowlodfar` | 24 | no creature shadow |
| 0x79e180 | `clothlodfar` | 24 | cloth not simulated |

The LOD distances are compared with an object's `+0x1f8`, its camera
distance divided by its bounding box size times a constant (0x5aad62), so
large objects keep detail farther out. Grass types (array 0x79e448, 0x6c
bytes each, set by 0x6130a0 from the area's `grassfalloff`) fade between two
squared distances at `+0x50` and `+0x54`; 0x75f2dc keeps the largest end.

The native over 0x4acf30 keeps the area's values and writes them times the
scale; the one over 0x6130a0 multiplies the new grass type's falloffs by the
scale squared. A change of the setting rewrites the globals from the kept
values and multiplies every grass type's falloffs by the ratio of the
scales squared. Farther grass means more grass drawn (the area grows with
the square of the scale).

## §17 Effect budget

Models have a single mesh; the engine has no mesh LODs, so the LOD distances
in §16 are the whole of model LOD. The remaining visual LOD is
CEffectLODManager (`ceffectlodmanager.cpp`), which caps visual effects to an
Xbox budget. It keeps a list of live effects (count 0x76cae4, 12-byte
entries at 0x76caec, weight at `+8`) and their weighted sum at 0x76cadc.
0x50f2d0 (from 0x511f80, CVisualEffect) and 0x50f350 (from 0x501db0) add
entries; the prune 0x50f3e0 destroys the oldest while the sum is over 10;
the gate 0x50f080 returns 1 only while sum * 0.1 is at most 0.5, and its
callers (0x446bd0, 0x4bb480) skip optional effect spawns when it returns 0.

The port raises the cap to 40 and the gate to 20 with byte patches in the
generator's PATCHES table (docs/recompiler.md §9): the prune's two `cmp`
immediates, and the gate's `fmul` operand repointed from 0.1 at 0x6e2f38
to an existing 0.025 at 0x6e3460 (both read-only; 0.1 is shared, so it is
not patched in place). The pirate camp idles at a sum of 4 to 9, so the
original gate was already closed there much of the time. The list grows
on demand (0x50f210 doubles it), so a larger cap needs no storage change.
Not a setting; the frame cost of the extra effects is unmeasured.

## §18 Per-pixel lighting

The game lights in its vertex shaders: each lit shader (vs067 skinned,
vs071, 072, 082, 083, 084, 089, 090, 095, 115 static, by the order of
creation in Two Rivers) sums three point lights through `lit` with `dst`
attenuation into oD0, which the pixel stage interpolates. Point lights near
coarse geometry, torches on cave walls above all, smear across whole
triangles. With PPL on (`JE_PPL`, the Per-Pixel Lighting row, default on),
`win32/d3d9_ppl.odin` reruns that lighting per pixel from the shader's own
bytecode.

The split is automatic, per vertex shader, on first use. Two backward
slices over register components: S from oD0, O from every other output
(oPos, oFog, oPts, oD1, oT0-7). The rerun part is S without O: the
instructions only oD0 depends on. A forward reaching-definition pass finds
each read in the rerun part whose definition lies outside it, an input or a
value the rest of the shader also uses (the transformed position and normal,
in practice). Those are the cut values: keyed by register and the defining
instruction of each component, each gets one varying at locations 11 and
up, copied out by the vertex stage at its first read. The pixel stage (the
game's pixel shader or the fixed-function cascade, either one) declares the
vertex constant block at binding 0 with the vertex shader's packing, and a
function `ppl_d0()` that runs the rerun part, reloading the cut components
from their varyings where it reads them, and returns oD0. That replaces
`i_d0` as v0. The pixel variant is keyed by the vertex shader id and its
constant prefix length; the vertex variant by bit 0 of its key.

At every vertex the result equals the original, since the varyings equal
their vertex values there; between vertices it is the same lighting math on
interpolated position and normal. The normal is not renormalized, matching
what the shader computes from it (interpolated normals are slightly short
mid-triangle, darkening the light a little at most). A shader is left to
vertex lighting when its rerun part has no lighting op (`lit`, `rsq`,
`nrm`, `pow`, `rcp`: interpolating a linear result is already exact), uses
a0 or relative constants, or needs more than 12 varyings. The skinned shader
qualifies: the bone math feeds oPos, so it stays in the vertex stage and only
the skinned position and normal cross.
