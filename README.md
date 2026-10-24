# Jade Empire static recompilation

A native port of *Jade Empire: Special Edition* (PC, 2007), made by statically
recompiling the game's x86 code to [Odin](https://odin-lang.org) and replacing
the Windows, Direct3D 9, DirectSound and Bink layers underneath it with SDL3,
OpenGL and FFmpeg. It runs on Linux and Windows (64-bit) and adds online
two-player co-op, higher-resolution rendering and controller support.

**This repository contains no game code or data.** You need your own copy of
the game (the Steam release). The recompiled code is generated on your machine
from your own `JadeEmpire.exe`; nothing from the game is shipped here or in a
build.

## Requirements

- The Steam release of Jade Empire: Special Edition. Its `JadeEmpire.exe` has
  sha256 `0d25f18c028a7dffff9dd110b7be677f7e9b63e1cad86c1eb8e4e8e189c54fe5`;
  other builds are not supported.
- [Odin](https://odin-lang.org) (a recent dev build; vendor `sdl3` is used).
- SDL3 and the FFmpeg development libraries (`libavcodec`, `libavformat`,
  `libavutil`, `libswscale`, `libswresample`), plus a C compiler for
  `port/src/win32/movie.c`.
- Python 3 with `pefile`, `capstone` and `unicorn`:
  `pip install pefile capstone unicorn`.
- An x86-64 CPU with AVX2.

## Building

The scripts expect the game at `steamapps/common/Jade Empire` inside the
repository root (a symlink is fine) and the unpacked exe at
`unpacked/JadeEmpire.exe`.

```sh
# 1. Unpack the PECompact2-packed exe (docs/unpack.md).
python3 tools/unpack_pec2.py "steamapps/common/Jade Empire/JadeEmpire.exe" unpacked/JadeEmpire.exe

# 2. Generate the recompiled code into port/src/rec (about 4 minutes).
python3 tools/x86rec.py unpacked/JadeEmpire.exe re/ghidra_funcs.txt port/src/rec

# 3. Build (about 45 seconds) and run.
port/build.sh
port/play.sh
```

`play.sh` rebuilds when sources changed and logs each session to
`port/logs/`. `JE_FULLSCREEN=1 port/play.sh` starts fullscreen.

### Windows

`port/build_windows.sh` cross-builds a Windows exe on Linux (needs clang-cl,
lld-link and the Windows SDK splatted by [xwin](https://github.com/Jake-Shadle/xwin));
it downloads the SDL3 and FFmpeg DLLs and zips everything as
`port/build/jade-win.zip`. On Windows, put `jade.exe` and its DLLs in a folder
together with your unpacked `JadeEmpire.exe` and run `play.bat`; set `GAME` if
the game is not in the default Steam folder.

## Online co-op

On the title menu, pick **Online → Host Online Game**. The address to give
your friend appears in the window title and on the clipboard; UDP port 47000
is opened through UPnP when the router allows it, otherwise forward it by
hand. The other player picks **Online → Join Online Game** and types or pastes
that address. Both players must run the same build and the same game files;
the joiner plays on the host's save and settings. See `docs/hle.md` §11.

## Documentation

- [docs/unpack.md](docs/unpack.md): unpacking the shipped exe.
- [docs/recompiler.md](docs/recompiler.md): the x86 → Odin recompiler.
- [docs/hle.md](docs/hle.md): the Windows API layer and online co-op.
- [docs/rendering.md](docs/rendering.md): rendering enhancements.
- [docs/game_map.md](docs/game_map.md): the gameplay code the port touches.
- [docs/modding.md](docs/modding.md): data formats, script VM and automation.
- [docs/exe_inventory.md](docs/exe_inventory.md): static inventory of the exe.

## Legal

This is an unofficial fan project, not affiliated with or endorsed by
BioWare, Electronic Arts or Valve. Jade Empire is a trademark of its owners.
The repository holds only original code, documentation, and address and name
lists produced by analysis; it contains no copyrighted game code, assets or
data, and you must own the game to use it.

The code is licensed under the GNU General Public License v3.0; see
[LICENSE](LICENSE). `port/src/win32/smaa/` carries its own license.
