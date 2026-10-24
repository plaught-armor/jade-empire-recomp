# Jade Empire static recompilation

A native port of *Jade Empire: Special Edition* (PC, 2007). The game's x86
code is statically recompiled to [Odin](https://odin-lang.org). The Windows,
Direct3D 9, DirectSound and Bink layers underneath it are replaced with SDL3,
OpenGL and FFmpeg. It runs on 64-bit Linux and Windows and adds online
two-player co-op, higher-resolution rendering and controller support.

**This repository contains no game code or data.** You need your own copy of
the game from Steam or GOG. The build reads the game's code from your own
`JadeEmpire.exe` and translates it on your computer. Because a finished build
contains that translated game code, there are no ready-made downloads: build
it yourself, and do not share your build.

**Works with the Steam and GOG versions of Jade Empire: Special Edition.**
Both contain the same version of the game, and the port is built the same way
from either. The Origin/EA app and retail disc versions have not been tried
and may not work.

## What you need

- **Jade Empire: Special Edition from Steam or GOG.** Other versions (Origin,
  the EA app, the retail disc) are untested and may not work.
- **A 64-bit PC** whose processor supports AVX2. Almost every Intel or AMD
  processor made since 2015 does.
- **These programs, to build the port:**
  - [Odin](https://odin-lang.org), the programming language the port is
    written in. Use a recent nightly build.
  - SDL3 and FFmpeg, with their development files. On Linux, install them
    from your distribution's packages: SDL3, plus `libavcodec`,
    `libavformat`, `libavutil`, `libswscale` and `libswresample`.
  - A C compiler, such as gcc or clang.
  - curl, which downloads one more library during the build.
- **Steam only:** Python 3, with two add-ons installed by
  `pip install pefile unicorn`. They remove the copy protection from the
  Steam `JadeEmpire.exe`.
- **GOG on Linux, if you do not use Wine:**
  [innoextract](https://constexpr.org/innoextract/) 1.9 or later, which opens
  GOG's installer without running it.

## Setting up the game files

The port uses two things from your copy of the game:

- **The game folder**, with the game's data, movies and sound. It stays where
  it is, unchanged. The port keeps its settings (`JadeEmpire.ini`) and your
  saves (the `Save` folder) in it, just as the original game does.
- **`JadeEmpire.exe`**, the game's program. The port reads the game's code
  from it while building. It is not run.

On Linux the build and play scripts look for the game folder at
`steamapps/common/Jade Empire` inside this repository, whichever store it
came from. You do not move the game there; you make a link (a kind of
shortcut) at that spot that points to the real folder. The exe goes in a
folder named `unpacked`.

Follow the steps for your store. Run every command from the top folder of
this repository.

### Steam

1. Install Jade Empire: Special Edition in Steam as usual. It does not matter
   whether Steam is set to run it with Proton. Steam puts the game in
   `steamapps/common/Jade Empire` inside your Steam library, usually
   `~/.local/share/Steam/steamapps/common/Jade Empire`.
2. Make the link to the game folder. If your Steam library is somewhere else,
   change the path in the second line:

   ```sh
   mkdir -p steamapps/common
   ln -s ~/.local/share/Steam/steamapps/common/"Jade Empire" steamapps/common/
   ```

3. Steam's `JadeEmpire.exe` is compressed and protected, so the port cannot
   read it as it is. This command makes a readable copy in `unpacked`
   ([docs/unpack.md](docs/unpack.md) explains how it works):

   ```sh
   mkdir -p unpacked
   python3 tools/unpack_pec2.py "steamapps/common/Jade Empire/JadeEmpire.exe" unpacked/JadeEmpire.exe
   ```

### GOG

1. Get the game folder in one of these ways:
   - Install the game with GOG Galaxy, Heroic, or the offline installer. On
     Linux, the offline installer runs under Wine.
   - On Linux, without Wine: download the offline installer from your GOG
     library. It is one `.exe` and two `.bin` files; keep all three in one
     folder. Then unpack it with innoextract:

     ```sh
     innoextract -I app -d ~/Games/jade-gog "setup_jade_empire_1.00_(15538).exe"
     ```

     The game folder is then `~/Games/jade-gog/app`.
2. Make the link to the game folder. If it is somewhere else, change the path
   in the second line:

   ```sh
   mkdir -p steamapps/common
   ln -s ~/Games/jade-gog/app "steamapps/common/Jade Empire"
   ```

3. GOG's `JadeEmpire.exe` has no copy protection, so a plain copy is enough:

   ```sh
   mkdir -p unpacked
   cp "steamapps/common/Jade Empire/JadeEmpire.exe" unpacked/
   ```

The GOG folder also has a few extras: a launcher, `JadeEmpireConfig.exe` and
GOG's `d3d9.dll` stutter fix. The port does not need them. All its settings
are in the game's own Options menu.

### Checking the exe

Make sure you have the right version of the game:

```sh
sha256sum unpacked/JadeEmpire.exe
```

This prints a long code that acts as the file's fingerprint. It must be one
of these:

| Store | Code |
|---|---|
| Steam | `0d25f18c028a7dffff9dd110b7be677f7e9b63e1cad86c1eb8e4e8e189c54fe5` |
| GOG (installer 1.00 (15538)) | `38224cc99f054f04f83190a369b82b2bc3ca65de114d780909a8ae2d09dc03c1` |

If it is not, you have a different version of the game, or, for Steam, step
3 failed. The port is made for these two versions only.

## Building

```sh
# 1. Build the port's tools, then use them to translate the game's code
#    into Odin (about 10 seconds).
tools/build.sh
port/build/x86rec unpacked/JadeEmpire.exe re/ghidra_funcs.txt port/src/rec

# 2. Build the game (about 45 seconds) and start it.
port/build.sh
port/play.sh
```

After that, `port/play.sh` is all you need to play. It rebuilds by itself
when the source code has changed, and keeps a log of each session in
`port/logs/`. To start in fullscreen, run `JE_FULLSCREEN=1 port/play.sh`.

### Windows

There are two ways to get a Windows version.

**Build it on Linux.** `port/build_windows.sh` makes a Windows version from
Linux. It needs clang-cl, lld-link and the Windows SDK files downloaded by
[xwin](https://github.com/Jake-Shadle/xwin). It fetches SDL3 and FFmpeg for
Windows itself and puts everything in `port/build/jade-win.zip`, for your own
use only.

**Build it on Windows.** This has not been tried on a real Windows PC yet.

1. Install Odin and Visual Studio (the free Community edition or the Build
   Tools), with "Desktop development with C++" selected. For the Steam
   version, also install Python and run `pip install pefile unicorn`.
2. Do step 3 for your store above, to put `JadeEmpire.exe` in `unpacked\`.
   Use your real game folder's path in place of
   `steamapps/common/Jade Empire`, and for Steam type `python` instead of
   `python3`. Windows does not need the link from step 2.
3. Build the tools and translate the game's code:

   ```bat
   tools\build.bat
   port\build\x86rec.exe unpacked\JadeEmpire.exe re\ghidra_funcs.txt port\src\rec
   ```

4. Open *x64 Native Tools Command Prompt* from the Start menu (Visual Studio
   installs it), go to this repository's folder and run `port\build.bat`. It
   downloads the rest of what it needs and puts the game in `port\build\win`.

**Playing.** Either way, copy your `JadeEmpire.exe` from `unpacked` into the
folder with `jade.exe` and run `play.bat`. It finds the game by itself in
Steam's usual folder, or in `C:\GOG Games\Jade Empire`, where GOG's offline
installer puts it. If your game is anywhere else (a GOG Galaxy install, or a
second Steam library), open `play.bat` in Notepad and set the `GAME` line near
the top to your game folder.

A Windows version built on Linux and one built on Windows play online
together, as long as both come from the same version of this repository and
the same Odin version.

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
