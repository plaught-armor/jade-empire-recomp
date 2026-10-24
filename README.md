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
- Steam only: Python 3 with `pefile` and `unicorn`, for unpacking the exe:
  `pip install pefile unicorn`.
- GOG on Linux without Wine: innoextract 1.9 or later, for extracting the
  offline installer.
- curl, to fetch the capstone 5.0.7 source the recompiler builds against.
- An x86-64 CPU with AVX2.

## Setting up the game files

The port needs two things from your copy of the game: the installed game
folder (data, movies, sound) and `JadeEmpire.exe`, whose code the recompiler
reads. The game folder stays as installed. Like the game, the port keeps its
settings (`JadeEmpire.ini`) and saves (`Save/`) there.

On Linux the scripts expect the game folder at `steamapps/common/Jade Empire`
inside the repository root, whichever store it came from, and the exe at
`unpacked/JadeEmpire.exe`. A symlink to the real folder is fine.

### Steam

1. Install Jade Empire: Special Edition through Steam. On Linux it does not
   matter whether Steam runs it with Proton; only the files are used. They
   are under `steamapps/common/Jade Empire` in your Steam library, usually
   `~/.local/share/Steam/steamapps/common/Jade Empire`.
2. Link it into the repository:

   ```sh
   mkdir -p steamapps/common
   ln -s ~/.local/share/Steam/steamapps/common/"Jade Empire" steamapps/common/
   ```

3. The Steam exe is packed with PECompact2 and must be unpacked. This needs
   Python 3 with `pefile` and `unicorn` (see [docs/unpack.md](docs/unpack.md)):

   ```sh
   mkdir -p unpacked
   python3 tools/unpack_pec2.py "steamapps/common/Jade Empire/JadeEmpire.exe" unpacked/JadeEmpire.exe
   ```

### GOG

1. Get the game folder, one of these ways:
   - Install it with GOG Galaxy, Heroic or the offline installer (under Wine
     on Linux).
   - On Linux, extract the offline installer with
     [innoextract](https://constexpr.org/innoextract/) 1.9 or later. Keep the
     two `.bin` files beside the `.exe`:

     ```sh
     innoextract -I app -d ~/Games/jade-gog "setup_jade_empire_1.00_(15538).exe"
     ```

     The game folder is then `~/Games/jade-gog/app`.
2. Link it into the repository:

   ```sh
   mkdir -p steamapps/common
   ln -s ~/Games/jade-gog/app "steamapps/common/Jade Empire"
   ```

3. The GOG exe is not packed. Copy it as is:

   ```sh
   mkdir -p unpacked
   cp "steamapps/common/Jade Empire/JadeEmpire.exe" unpacked/
   ```

The GOG folder also holds GOG's `d3d9.dll` stutter fix, the launcher and
`JadeEmpireConfig.exe`. The port uses none of them; its own settings are in
the game's Options menu.

### Checking the exe

```sh
sha256sum unpacked/JadeEmpire.exe
```

It must print one of the two hashes under [Requirements](#requirements). Any
other value means a different build of the game, or, for Steam, a failed
unpack. The recompiler's address lists do not fit other builds.

## Building

```sh
# 1. Build the recompiler and tools (tools/build.bat on Windows).
#    Then generate the recompiled code into port/src/rec (about 10 seconds).
tools/build.sh
port/build/x86rec unpacked/JadeEmpire.exe re/ghidra_funcs.txt port/src/rec

# 2. Build (about 45 seconds) and run.
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

1. Install Odin and Visual Studio (or its Build Tools) with the C++
   workload, and for Steam also Python.
2. Put `JadeEmpire.exe` in `unpacked\` as in step 3 for your store above,
   with your game folder's path in place of `steamapps/common/Jade Empire`
   (Steam: `python` in place of `python3`). The game folder does not need
   linking into the repository on Windows.
3. Run step 1 of [Building](#building), with `tools\build.bat` and
   `port\build\x86rec.exe`.
4. From an *x64 Native Tools Command Prompt*, run `port\build.bat`. It
   downloads the SDL3, FFmpeg and zlib sources and DLLs it needs and writes
   `port\build\win`.

This has not yet been tried on a real Windows PC.

Either way, put your unpacked (Steam) or original (GOG) `JadeEmpire.exe` in
`build\win` beside `jade.exe` and run `play.bat`. It finds the game in
Steam's default folder, or in `C:\GOG Games\Jade Empire` (the GOG offline
installer's default). For any other folder, such as a GOG Galaxy install or a
second Steam library, set `GAME` at the top of `play.bat`. A native exe and a
cross-built exe from the same commit and Odin version play online together.

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
