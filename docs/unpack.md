# Unpacking JadeEmpire.exe

`steamapps/common/Jade Empire/JadeEmpire.exe` (sha256 `0d25f18c…54fe5`,
linked 2007-01-23, MSVC 7.1, relocations stripped, fixed base `0x400000`) is
PECompact2-packed with the 2007 Steam DRM wrapper inside the stub.

`tools/unpack_pec2.py` emulates the stub under unicorn and dumps the image at
the original entry point, before any CRT initialiser runs, so `.data` holds its
link-time contents.

```
python tools/unpack_pec2.py "steamapps/common/Jade Empire/JadeEmpire.exe" unpacked/JadeEmpire.exe
```

Needs `unicorn` and `pefile` (any venv).

## What the stub does

1. Packed entry `0x401000`: `mov eax, 0x89ce08; jmp eax` (7 bytes).
2. Decompresses the image into `VirtualAlloc` memory and back over `.text`.
3. Resolves every game import with `LoadLibraryA`/`GetProcAddress`, writing
   both the real IAT (`0x6e1000`) and the original lookup table
   (`0x7596cc`, unreferenced afterwards).
4. Steam check, cdecl, from heap code: `SteamStartup(0xe, err)`, then
   `SteamIsAppSubscribed(appid, &subscribed, &pending, err)`; continues only
   when both return nonzero and `subscribed != 0`. Then `SteamCleanup`.
5. Jumps to OEP `0x6b4923` (MSVC CRT `WinMainCRTStartup`, first call
   `GetVersionExA`).

APIs only the stub uses (dropped from the rebuilt imports): `steam.dll`
`SteamStartup`/`SteamIsAppSubscribed`/`SteamCleanup`, `FreeLibrary`,
`OpenProcess`, `ShellExecuteA`, `wsprintfA`.

## Output layout

| Section | VA | Notes |
|---|---|---|
| `.text` | `0x401000`–`0x6e1000` | RX; split from the packer's merged block at `BaseOfData` |
| `.data` | `0x6e1000`–`0x895000` | RW; IAT at its start, then `.rdata`/`.data` |
| `.rsrc` | `0x895000` | unchanged |
| `.idata` | `0x89d000` | rebuilt import directory: 199 functions, 14 DLLs |

Imports by DLL: kernel32 108, user32 37, binkw32 13, d3dx9_29 13, winmm 7,
dbghelp 7, vorbisfile 6, advapi32 2, d3d9/dinput8/dsound/gdi32/xinput9_1_0/ole32 1.
This is the platform surface the port's HLE layer must provide.

## Verification

Copied into the game folder as `JadeEmpire.unpacked.exe` (the game changes
into its own exe's directory and requires `override/`), run under Wine 11.19
with a fresh prefix and no Steam: all imports bind; game code runs through
`WinMain`, the resource system and `RenderSystem`, logging to `logs/d3d.log`.
It then stops at `RenderSystem.ApplySettings: ERROR: Device does not support
the default display mode` followed by an access violation reading `0x5e8`
(`0x59384a`, called from `0x4a55d9`). That is display configuration under
Wine, not the unpack.

### Fix: run windowed

`RenderSystem.ApplySettings` (`0x597680`) only looks up a display mode on the
fullscreen path (`0x596260`, FindMode). It tries the ini mode, then falls back
to 640×480, 32 bpp, 60 Hz, and returns `D3DERR_NOTAVAILABLE` if neither is
enumerated; the caller then crashes on the failed device. The windowed path
(`0x595e10`) skips the lookup. Inferred cause: the host only enumerates its
native refresh rate (144 Hz here), so the 60 Hz modes are never found.

Set `Windowed=1` in `[Render]` of `steamapps/common/Jade Empire/JadeEmpire.ini`
(the original is backed up as `JadeEmpire.ini.orig`), then run from the game
folder:

```
WINEPREFIX=<prefix> wine JadeEmpire.unpacked.exe
```

`logs/d3d.log` then shows `Setting Windowed Mode:
640x480xD3DFMT_X8R8G8B8xD3DFMT_D24S8x144Hz`, `Created HAL Device`, and the
intro movies (`BLACK`, `PUBLISHER`, `BWLOGO`, `GRAYMATR`). This is the
reference run for the port. Harmless log noise: `English\dialog.tlk` and
`dialogF.tlk` not found.

The binary keeps BioWare's assert paths (e.g.
`c:\backup\bioware\jadepc\warriors\CCreature.h`, `.\canimationsystem.cpp`),
useful for naming functions.
