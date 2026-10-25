# Jade Empire static recompilation

A native port of *Jade Empire: Special Edition* (PC, 2007). The game's x86
code is statically recompiled to [Odin](https://odin-lang.org). The Windows,
Direct3D 9, DirectSound and Bink layers underneath it are replaced with SDL3,
OpenGL and FFmpeg. It runs on 64-bit Linux and Windows and adds online
two-player co-op, higher-resolution rendering and controller support.

**This repository contains no game code or data.** You need your own copy of
the game from Steam or GOG. The installer reads the game's code from your own
`JadeEmpire.exe` and translates it on your computer. Because a finished build
contains that translated game code, there are no ready-made downloads: build
it yourself, and do not share your build.

**Works with the Steam and GOG versions of Jade Empire: Special Edition.**
Both contain the same version of the game, and the port is built the same way
from either. The Origin/EA app and retail disc versions have not been tried
and may not work.

## What you need

- **Jade Empire: Special Edition from Steam or GOG**, installed. Other
  versions (Origin, the EA app, the retail disc) are untested and may not
  work.
- **A 64-bit PC** whose processor supports AVX2. Almost every Intel or AMD
  processor made since 2015 does.
- **A copy of this repository.** Download it with the green *Code* button on
  GitHub (*Download ZIP*) and unzip it anywhere, or use `git clone`.
- **These programs, to build the port:**
  - [Odin](https://odin-lang.org), the programming language the port is
    written in. Use a recent nightly build, and make sure the `odin` command
    works in a terminal.
  - **Linux:** a C compiler (gcc or clang), curl, and SDL3 and FFmpeg with
    their development files. Install them from your distribution's packages:
    SDL3, plus `libavcodec`, `libavformat`, `libavutil`, `libswscale` and
    `libswresample`.
  - **Windows:** Visual Studio or the free Visual Studio Build Tools, with
    *Desktop development with C++* selected.
  - **Steam version only:** [Python 3](https://www.python.org). The Steam
    `JadeEmpire.exe` is compressed and copy-protected, and the installer uses
    Python to make a readable copy of it.

## Installing

The installer builds the port from your own game and puts it in your game
folder, next to `JadeEmpire.exe`. It leaves the game's own files alone. The
port keeps its settings (`JadeEmpire.ini`) and your saves (the `Save` folder)
in the game folder, just as the original game does.

### Linux

Open a terminal in the repository's folder and run:

```sh
./install.sh
```

It finds a Steam install by itself. If your game is somewhere else (GOG, or
another Steam library), give the game folder:

```sh
./install.sh "/path/to/Jade Empire"
```

It takes a minute or two (longer the first time). To play, run `jade` in the
game folder. To start in fullscreen, run `JE_FULLSCREEN=1 ./jade` there.

**GOG without Wine.** GOG's offline installer is a Windows program. To get
the game folder without running it, download the installer from your GOG
library (one `.exe` and two `.bin` files; keep all three in one folder) and
unpack it with [innoextract](https://constexpr.org/innoextract/) 1.9 or
later:

```sh
innoextract -I app -d ~/Games/jade-gog "setup_jade_empire_1.00_(15538).exe"
./install.sh ~/Games/jade-gog/app
```

### Windows

Double-click `install.bat` in the repository's folder. It finds the game in
Steam's usual folder, or in `C:\GOG Games\Jade Empire`, where GOG's offline
installer puts it. If your game is somewhere else (GOG Galaxy, or another
Steam library), run it from a command prompt with the game folder:

```bat
install.bat "D:\Games\Jade Empire"
```

The first time takes several minutes: it also downloads SDL3 and FFmpeg. To
play, double-click `play.bat` in the game folder. Windows support has been
tested under Wine, not yet on a real Windows PC.

### If something goes wrong

The installer says in plain words what is missing. When a build step fails,
it shows the end of `port/build/install.log`, which has the full details.

### Updating

Get the new version of this repository, then run the installer again.

## For developers

`port/play.sh` rebuilds the port when its source has changed and runs it with
a log of each session in `port/logs/`. It expects the game folder (or a link
to it) at `steamapps/common/Jade Empire` inside this repository, with a usable
exe in it (the GOG exe, or the Steam one unpacked to
`JadeEmpire.unpacked.exe`). The steps `install.sh` runs, by hand:

```sh
tools/build.sh                     # the recompiler and the other tools
port/build/x86rec "<usable exe>" re/ghidra_funcs.txt port/src/rec
port/build.sh                      # the game, as port/jade
```

`port/jade` runs on the folder it is in, or on a game folder given as its
first argument. [docs/unpack.md](docs/unpack.md) explains the Steam unpacking.

`port/build_windows.sh` cross-builds the Windows version on Linux. It needs
clang-cl, lld-link and the Windows SDK files downloaded by
[xwin](https://github.com/Jake-Shadle/xwin), and puts everything in
`port/build/jade-win.zip`, for your own use only. A Windows version built on
Linux and one built on Windows play online together, as long as both come
from the same version of this repository and the same Odin version.

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
