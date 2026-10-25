# JadeEmpire.exe inventory

Static inventory of the game exe: the unpacked Steam exe (sha256
`53445f0e…afe`, see `docs/unpack.md`) or the GOG exe (sha256 `38224cc9…3c1`),
whose code is the same. The counts below were taken from the unpacked Steam
exe. It records what the x86 → Odin recompiler and the win32 HLE
layer have to handle. Everything here is static analysis; nothing was observed
at runtime except where `docs/unpack.md` says so.

Reproduce:

```
tools/build.sh
port/build/inventory "<exe>" re/ghidra_funcs.txt out.json --data-seeds
port/build/srcmap    "<exe>" re/ghidra_funcs.txt
port/build/devcalls  "<exe>" re/ghidra_funcs.txt 0x76f4f8
port/build/funcnames "<exe>" re > re/funcnames.txt
```

Data files: `re/ghidra_funcs.txt` (7504 Ghidra 12.1.4 function starts,
default auto-analysis), `re/srcmap.txt` (source file → address range),
`re/names.txt` (curated symbols, with confidence).

## 1. Shape

| Fact | Value |
|---|---|
| Compiler | MSVC 7.1, C++, SEH + C++ EH, `/GS` cookie (`0x769df4`) |
| Relocations | stripped; fixed base `0x400000` |
| `.text` | `0x401000`–`0x6e1000`, 2.88 MiB |
| Functions | 7504 Ghidra starts; about 17.8k entry points once `.data` code pointers are included (see §2) |
| Instructions reached | about 807k |
| RTTI | only CRT/std types; game classes have none, so vtables are recovered by hand |
| Threads | **none**: `CreateThread` is not imported. The only asynchrony is overlapped file I/O (`ReadFileEx` + `SleepEx` APCs, `CancelIo`, `GetOverlappedResult`) |
| CPU affinity | `WinMain` pins the process to CPU 0 |
| Frame cap | `ClampFPS` ini key; 33 ms per frame (30 fps) |

Single-threaded code is the most important finding for the recompiler: guest
state can be one global CPU context, with no locking. The overlapped reads can
be completed synchronously by the HLE layer, with the APC called at the next
alertable wait.

## 2. Code discovery

Coverage of `.text` by recursive descent, from different seed sets:

| Seeds | Bytes reached | Coverage |
|---|---|---|
| Ghidra function starts + OEP | 2,538,722 | 84.2% |
| plus every aligned `.data` dword pointing into `.text` | 2,770,299 | 91.9% |

Ghidra misses about 10.3k entry points that are reachable only through data:
virtual methods, C++ EH unwind funclets (one 125 KB block at `0x6c17d0`), CRT
initializer tables (`0x6e014b` onward) and callbacks. Seeding from `.data`
finds them, but it also produces false positives. Garbage mnemonics (`in`,
`outsb`, `iretd`, `das`, `ljmp`, `les`) appear in the histogram, so some
"pointers" are really data. The remaining 8.1% of `.text` is `int3` padding,
switch index byte tables, and unreferenced code.

Consequences for the recompiler:

- The function set is Ghidra starts ∪ data pointers ∪ direct call targets. A
  data-pointer seed is accepted only if it decodes cleanly to a terminating
  path; otherwise it is dropped.
- Any indirect target missing from the set must fail loudly at runtime (log the
  address once, like BoF4's `unported`), never be silently ignored.

## 3. Instruction mix

| Class | Count | Notes |
|---|---|---|
| x87 | about 70k (8.7%) | All game floating point. `fnstsw` + `test ah` + `jp` compare idiom (3264 `fnstsw`), `fldcw` around float-to-int conversion (965), `fsin`/`fcos`/`fpatan`/`fsqrt` present |
| SSE/SSE2 | about 990 | Almost all in CRT SSE2 math paths (`movlpd`, `mulsd`, `pextrw`) selected by `cpuid`; a few `movss`/`movaps` |
| MMX-like | about 97 | CRT only |
| String ops | about 1020 | `rep movsd/movsb/stosd/stosb`, `repe cmpsb` |
| `call` | 71k | |

Indirect control flow:

| Kind | Count |
|---|---|
| `call [reg+disp]` (virtual calls) | 10,973 |
| `call [IAT]` | 552 |
| `call reg` | 225 |
| `jmp [idx*4+table]` (switches) | 378 over 372 tables, about 21.7k entries |
| `jmp [reg+disp]` | 96 |
| `jmp [IAT]` | 24 |

x87 needs exact emulation: an 80-bit register stack, tag word, precision and
rounding control (`fldcw`), and status flags for the `fnstsw` idiom. Running it
as f64 is a possible speed path, but it has to be checked against a reference
run first. Switch tables are plain absolute 32-bit tables and resolve
statically.

## 4. Module map

The assert strings name 111 `.cpp` files. The linker kept object files
contiguous, so each file covers one address range. The full list is in
`re/srcmap.txt`; the coarse layout is:

| Range | Content |
|---|---|
| `0x401000`–`0x47a000` | game core, A–Z: `aimaster`, `canimationsystem`, `cappbase`, `ccampaign`, `cconversation`, `cjournal`, `pathfind`… |
| `0x47a480`–`0x4a3400` | `vmachinecommands.cpp`: NWScript engine commands; table init at `0x4a0e50` |
| `0x4a3400`–`0x4a5800` | `WinMain.cpp` |
| `0x4a8000`–`0x593000` | game objects, effects, GUI (`cgui*`, `cpanel*`), world map, minigame panels |
| `0x593800`–`0x598000` | PC render wrapper: `Dx9_State`, `ImmRender`, `RenderDevice`, `RenderSystem` |
| `0x598000`–`0x5f5000` | Aurora renderer: `aurdxcore`, `aurorainterface`, scene/light |
| `0x5f5000`–`0x667000` | Exo core: strings, GFF, 2DA, TLK, `exoresman`, `exoresfile`, `exofile`, `lyt` |
| `0x667420` | `xbinput.cpp` (input) |
| `0x6769e0`–`0x67e800` | sound sources, sound banks, movie player |
| `0x6819d0`–`0x693600` | minigame engine (`cminigame`, `mg*`) |
| `0x697470` | `scriptvmcore.cpp` (NWScript VM core) |
| `0x69c59e`–`0x6b22ec` | import thunks |
| `0x6b2306`–`0x6e1000` | MSVC CRT, EH funclets, initializers |

Because the code is laid out by source file, the generated Odin can be split
into one file per object module instead of by arbitrary size.

## 5. Control flow anchors

Symbols are listed in `re/names.txt`.

- `WinMainCRTStartup` `0x6b4923` calls `WinMain` `0x4a53b0` at `0x6b4aa9`.
- `WinMain` reads `Render` `Width`/`Height` (default 640×480) through
  `Ini_GetInt` `0x597fd0`. It leaves if a `JadeEmpPC` window already exists,
  sets up the window (`0x4a3660`) and `ClipCursor`, optionally installs the
  exception logger (`LogExceptions`), then calls `MainLoop`.
- `MainLoop` `0x4a3a40`:
  1. Single-instance mutex `JadeEmpire`.
  2. `new CAppManager` (0xed60 bytes, ctor `0x40e820`) stored in
     `g_AppManager` `0x76c924`.
  3. Subsystem init, then `Render_Init` `0x5d9640`; exits on failure.
  4. Up to three loading passes, and `Autoload` save handling.
  5. Loop while `PumpMessages` `0x5d9900` returns nonzero: frame clamp,
     per-clock delta times (written to AppManager +0x20/+0x24/+0x28, clamped
     to 0.0001–0.25 s), the movie path (`0x67e710`/`0x67f0e0`) or the game
     path (update, render, `Clear` on `g_D3DDevice` `0x76f4f8`, GUI, save
     requests with a 50 MiB free-disk check).
- NWScript command table: `VMCmd_InitCommandTable` `0x4a0e50` allocates
  `0x108c` bytes (1059 slots) and fills 528+ of them with handler addresses in
  `0x47a480`–`0x4a0270`.

## 6. Platform surface

Imports: 199 functions from 14 DLLs (listed in `docs/unpack.md`). The
notable ones:

- **kernel32**: no threads. Files go through `CreateFileA`/`ReadFile`/
  `ReadFileEx`/`SetFilePointerEx`/`Find*File`. Config uses
  `GetPrivateProfile*`/`WritePrivateProfileStringA`. Timing uses
  `QueryPerformance*`/`GetTickCount`/`Sleep`/`SleepEx`. The remainder is
  CRT plumbing (heap, locale, environment).
- **user32**: one window, a message pump, cursor clip/capture,
  `ChangeDisplaySettingsA`/`EnumDisplaySettingsA`, `GetAsyncKeyState`.
- **Input**: `DirectInput8Create`, plus `XInputSetState` (rumble only;
  `XInputGetState` appears nowhere, not even as a string).
- **Audio**: `dsound` ordinal 11 (`DirectSoundCreate8`); `vorbisfile` for
  music; `winmm` `mmio*` for WAV parsing.
- **Video**: Bink 1 (13 functions, DX9 surface copy path).
- **d3dx9_29**: matrix helpers, `D3DXCreateMatrixStack`, cube texture
  creation, `D3DXFilterTexture`, surface load and save. Small enough to
  reimplement.
- **dbghelp**: crash stack walk only; can be stubbed.

### D3D9 device usage

These are calls through `g_D3DDevice`, counted by vtable slot. This is a lower
bound, because calls made through a device pointer held in a register or
member are not counted.

| Method (slot) | Calls | | Method (slot) | Calls |
|---|---|---|---|---|
| SetVertexShaderConstantF (94) | 81 | | GetRenderTarget (38) | 5 |
| SetTexture (65) | 72 | | GetRenderState/GetTexture (58, 64) | 5 each |
| SetSamplerState (69) | 38 | | DrawPrimitiveUP (83) | 5 |
| SetRenderState (57) | 33 | | SetPixelShaderConstantF (109) | 23 |
| SetPixelShader (107) | 23 | | GetDepthStencilSurface (40) | 6 |
| CreateTexture (23) | 17 | | SetTransform (44) | 6 |
| SetRenderTarget (37) | 15 | | SetViewport/GetViewport (47, 48) | 7/8 |
| CreateVertexBuffer (26) | 5 | | SetStreamSource (100) | 5 |
| Clear (43) | 14 | | StretchRect (34) | 8 |
| DrawPrimitive (81) | 12 | | SetDepthStencilSurface (39) | 9 |

Also seen once or twice each: GetDeviceCaps, Present, GetBackBuffer,
SetGammaRamp, CreateVolumeTexture, CreateCubeTexture, CreateDepthStencilSurface,
CreateOffscreenPlainSurface, BeginScene, EndScene, SetClipPlane,
SetTextureStageState, SetScissorRect, DrawIndexedPrimitive(UP),
CreateVertexDeclaration, SetVertexDeclaration, SetFVF, SetVertexShader,
SetIndices, CreatePixelShader.

There is no `SetLight` or `SetMaterial`: lighting is done in shaders. Most
render state goes through the `Dx9_State` cache wrappers rather than directly
to the device.

Shaders ship precompiled in `shaderpc/`: 62 `vs_1_1` and 1 `vs_2_0` (`.vso`),
60 `ps_1_1` and 7 `ps_2_0` (`.pso`). The HLE layer needs a D3D9 shader
model 1–2 bytecode → SPIR-V translator (DXVK's `dxso` is the reference) and an
emulation of whatever fixed-function draws remain (`SetFVF` paths).

## 7. Open questions

- ~~Which ini keys the device check under Wine needs.~~ Resolved: `Windowed=1`
  skips the fullscreen mode lookup (`docs/unpack.md`, "Fix: run windowed").
- vtable layouts of the core classes (AppManager, render device, resource
  manager) for `hand/` overrides.
- Exact list of fixed-function draws, to size the FFP emulation.
- Whether the `.data` code pointers that fail to decode cleanly are data or
  code that was missed.

## 8. Function names

`re/funcnames.txt` gives readable names to 2973 of the 7504 Ghidra function
starts; `tools/x86rec` turns each into a proc name `<name>_<address>`
(for example `Quat_Slerp_005c1180`), and unnamed functions keep `r_<address>`.
The address stays in every name, so names are unique even when two functions
log the same method, and a profile or crash address still greps straight to
the proc. `tools/funcnames` builds the file from five sources, the first
that names a function winning:

| Source | Count | Evidence |
|---|---|---|
| `curated` | 74 | `re/names.txt`, including the hottest functions of the v17 profile, named by hand from Ghidra pseudocode (`inf` there means inferred) |
| `ghidra` | 343 | CRT and library functions Ghidra's signatures recognized |
| `method` | 211 | the single `CClass::Method` that the function's own log and assert strings name (`"CCampaign::LoadCampaignData - STARTED"`); a function whose strings name two methods is left out |
| `nws` | 631 | the NWScript engine function the action table (`re/nwscript_handlers.tsv`) dispatches to it; a handler shared by several actions gets `_etc` |
| `file` | 1714 | the `.cpp` its assert strings name, also given to the functions between two that name the same file with none naming another, because MSVC links each object file contiguously |

The `file` names are a module, not a function: `ccampaign_004255f0` says
where the code came from, not what it does. The game classes have no RTTI
(§1), and only 140 vtables are referenced from code, 5 of them with a
`method`-named slot, so vtables add nothing yet. The rendering and math code
around `0x598000`–`0x640000` has almost no strings; its hot functions are
named by hand, and more hand names belong in `re/names.txt`.
