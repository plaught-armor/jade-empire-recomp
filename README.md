# Jade Empire static recompilation

A native port of *Jade Empire: Special Edition* (PC, 2007). The game's x86
code is statically recompiled to [Odin](https://odin-lang.org). The Windows,
Direct3D 9, DirectSound and Bink layers underneath it are replaced with SDL3,
OpenGL and FFmpeg. It runs on 64-bit Linux and Windows and adds online
two-player co-op, higher-resolution rendering and controller support.

**This repository contains no game code or data.** You need your own copy of
the game (the Steam or GOG release). The recompiled code is generated on your
machine from your own `JadeEmpire.exe`. A build contains that recompiled game code, so
there are no prebuilt releases. Build it yourself, and do not share your
build.

**Tested with the Steam and GOG releases of Jade Empire: Special Edition.**
Both ship the same build of the game, and the recompiler generates the same
code from either exe. The Origin/EA app and retail disc versions have not been
tried. Their exes may differ from the one the recompiler's address lists were
made from.

## Requirements

- The Steam or GOG release of Jade Empire: Special Edition. The Steam
  `JadeEmpire.exe` has sha256
  `0d25f18c028a7dffff9dd110b7be677f7e9b63e1cad86c1eb8e4e8e189c54fe5`; the GOG
  one (installer 1.00 (15538)) has sha256
  `38224cc99f054f04f83190a369b82b2bc3ca65de114d780909a8ae2d09dc03c1`. Other
  builds are not supported.
- [Odin](https://odin-lang.org), a recent dev build (the port uses vendor
  `sdl3`).
- SDL3 and the FFmpeg development libraries (`libavcodec`, `libavformat`,
  `libavutil`, `libswscale`, `libswresample`).
- A C compiler, for `port/src/win32/movie.c`.
- Python 3 with `pefile` and `unicorn`, only for unpacking the Steam exe:
  `pip install pefile unicorn`.
- curl, to fetch the capstone 5.0.7 source the recompiler builds against.
- An x86-64 CPU with AVX2.

## Building

The scripts expect the game at `steamapps/common/Jade Empire` inside the
repository root (a symlink is fine), whichever store it came from. The exe the
port runs goes to `unpacked/JadeEmpire.exe`.

```sh
# 1. Steam: unpack the PECompact2-packed exe (docs/unpack.md).
python3 tools/unpack_pec2.py "steamapps/common/Jade Empire/JadeEmpire.exe" unpacked/JadeEmpire.exe
#    GOG: the exe is not packed; copy it as is.
mkdir -p unpacked && cp "steamapps/common/Jade Empire/JadeEmpire.exe" unpacked/

# 2. Build the recompiler and tools (tools/build.bat on Windows).
#    Then generate the recompiled code into port/src/rec (about 10 seconds).
tools/build.sh
port/build/x86rec unpacked/JadeEmpire.exe re/ghidra_funcs.txt port/src/rec

# 3. Build (about 45 seconds) and run.
port/build.sh
port/play.sh
```

`play.sh` rebuilds when sources have changed. It logs each session to
`port/logs/`. `JE_FULLSCREEN=1 port/play.sh` starts fullscreen.

### Windows

`port/build_windows.sh` cross-builds a Windows exe on Linux. It needs
clang-cl, lld-link and the Windows SDK splatted by
[xwin](https://github.com/Jake-Shadle/xwin). It downloads the SDL3 and FFmpeg
DLLs and zips everything as `port/build/jade-win.zip`, for your own use only.

To build on Windows itself:

1. Install Odin, Python and Visual Studio (or its Build Tools) with the C++
   workload.
2. Run steps 1 and 2 above, with `python` in place of `python3` (GOG: copy
   the exe instead of unpacking it).
3. From an *x64 Native Tools Command Prompt*, run `port\build.bat`. It
   downloads the SDL3, FFmpeg and zlib sources and DLLs it needs and writes
   `port\build\win`.

This has not yet been tried on a real Windows PC.

Either way, put your unpacked (Steam) or original (GOG) `JadeEmpire.exe` in
`build\win` beside `jade.exe` and run `play.bat`. Set `GAME` if the game is not
in the default Steam folder. A native exe and a cross-built exe from the same commit and
Odin version play online together.

## Online co-op

1. The host picks **Online → Host Online Game** on the title menu. The
   address to give your friend appears in the window title and on the
   clipboard.
2. UDP port 47000 is opened through UPnP when the router allows it. Otherwise,
   forward it by hand.
3. The other player picks **Online → Join Online Game** and types or pastes
   that address.

Both players need the same game files. Their builds of the port must come
from the same commit and the same Odin version; the peers check this. The OS
and CPU do not matter: a Linux player and a Windows player can play together,
and the game's math is bit-exact on any x86-64 build. A Steam player and a GOG
player can play together too. The joiner plays on the
host's save and settings. See `docs/hle.md` §11.

## Documentation

- [docs/unpack.md](docs/unpack.md): unpacking the shipped exe.
- [docs/recompiler.md](docs/recompiler.md): the x86 → Odin recompiler.
- [docs/hle.md](docs/hle.md): the Windows API layer and online co-op.
- [docs/rendering.md](docs/rendering.md): rendering enhancements.
- [docs/game_map.md](docs/game_map.md): the gameplay code the port touches.
- [docs/modding.md](docs/modding.md): data formats, script VM and automation.
- [docs/exe_inventory.md](docs/exe_inventory.md): static inventory of the exe.

## Legal

This is an unofficial fan project. It is not affiliated with or endorsed by
BioWare, Electronic Arts or Valve. Jade Empire is a trademark of its owners.

The repository holds only original code, documentation, and address and name
lists produced by analysis. It contains no copyrighted game code, assets or
data. You must own the game to use it.

The code is licensed under the GNU General Public License v3.0; see
[LICENSE](LICENSE). `port/src/win32/smaa/` carries its own license.
