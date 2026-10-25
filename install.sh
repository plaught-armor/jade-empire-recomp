#!/bin/sh
# Builds the port from your own copy of Jade Empire and puts it in the game
# folder, beside JadeEmpire.exe. Afterwards, run `jade` in that folder to play.
#
# Usage: ./install.sh [game folder]
# Without a folder it looks in Steam's usual library folders.
#
# The Steam JadeEmpire.exe is packed (docs/unpack.md): the first run unpacks it
# into JadeEmpire.unpacked.exe beside it, with Python's pefile and unicorn
# installed into port/build/venv. The GOG exe is used as it is. Nothing else in
# the game folder is changed.
set -eu
cd "$(dirname "$0")"
repo="$PWD"

fail() {
	echo
	echo "$*"
	exit 1
}

STEAM_PACKED=0d25f18c028a7dffff9dd110b7be677f7e9b63e1cad86c1eb8e4e8e189c54fe5
STEAM_UNPACKED=53445f0e2c33dd9f7c862999fbf9d834d6c4381cc573580cdba6fa0d2e1bcafe
GOG=38224cc99f054f04f83190a369b82b2bc3ca65de114d780909a8ae2d09dc03c1

# The game folder.
if [ $# -gt 1 ]; then
	fail "usage: ./install.sh [game folder]"
elif [ $# -eq 1 ]; then
	game="$1"
else
	game=
	for d in "$HOME/.local/share/Steam/steamapps/common/Jade Empire" \
		"$HOME/.steam/steam/steamapps/common/Jade Empire" \
		"$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common/Jade Empire" \
		"$repo/steamapps/common/Jade Empire"; do
		if [ -f "$d/chitin.key" ]; then
			game="$d"
			break
		fi
	done
	[ -n "$game" ] || fail "Jade Empire was not found in Steam's usual folders.
Run this again with your game folder, for example:
  ./install.sh ~/Games/jade-gog/app"
fi
[ -f "$game/chitin.key" ] || fail "$game is not a Jade Empire game folder (it has no chitin.key)."
game="$(cd "$game" && pwd)"
echo "Game folder: $game"

# The programs the build needs.
missing=
for p in odin cc curl ar; do
	command -v "$p" > /dev/null 2>&1 || missing="$missing $p"
done
[ -z "$missing" ] || fail "These programs are missing:$missing
Install them first (README.md, \"What you need\")."
if command -v pkg-config > /dev/null 2>&1; then
	for l in sdl3 libavcodec libavformat libavutil libswscale libswresample; do
		pkg-config --exists "$l" || missing="$missing $l"
	done
	[ -z "$missing" ] || fail "These libraries are missing:$missing
Install them, with their development files, from your distribution's packages."
fi

sha() { sha256sum "$1" | cut -d' ' -f1; }

# Each step's output goes to the log, which is shown when the step fails.
log="$repo/port/build/install.log"
mkdir -p port/build
: > "$log"
step() {
	echo "$1"
	shift
	"$@" >> "$log" 2>&1 || fail "That step failed. The end of $log:
$(tail -n 20 "$log")"
}

# The exe to build from.
exe=
if [ -f "$game/JadeEmpire.unpacked.exe" ] && [ "$(sha "$game/JadeEmpire.unpacked.exe")" = "$STEAM_UNPACKED" ]; then
	exe="$game/JadeEmpire.unpacked.exe"
	echo "Found the unpacked Steam exe."
elif [ -f "$game/JadeEmpire.exe" ]; then
	case "$(sha "$game/JadeEmpire.exe")" in
	"$GOG")
		exe="$game/JadeEmpire.exe"
		echo "Found the GOG exe."
		;;
	"$STEAM_PACKED")
		echo "Found the Steam exe. It is packed, so it is unpacked into JadeEmpire.unpacked.exe beside it."
		command -v python3 > /dev/null 2>&1 || fail "Python 3 is needed to unpack the Steam exe. Install it, then run this again."
		venv=port/build/venv
		if ! "$venv/bin/python" -c "import pefile, unicorn" > /dev/null 2>&1; then
			rm -rf "$venv"
			python3 -m venv "$venv" || fail "Could not make a Python virtual environment. On Debian or Ubuntu, install python3-venv."
			step "Installing pefile and unicorn for Python into $venv..." \
				"$venv/bin/pip" install --quiet --disable-pip-version-check pefile unicorn
		fi
		step "Unpacking..." "$venv/bin/python" tools/unpack_pec2.py "$game/JadeEmpire.exe" "$game/JadeEmpire.unpacked.exe"
		[ "$(sha "$game/JadeEmpire.unpacked.exe")" = "$STEAM_UNPACKED" ] || fail "Unpacking gave an unexpected result. Please report this."
		exe="$game/JadeEmpire.unpacked.exe"
		;;
	*)
		fail "$game/JadeEmpire.exe is not a version this port supports.
It works with Jade Empire: Special Edition from Steam or GOG only."
		;;
	esac
else
	fail "$game has no JadeEmpire.exe."
fi

# Build.
step "Building the recompiler (the first time takes a few minutes)..." tools/build.sh x86rec
step "Translating the game's code (about 10 seconds)..." port/build/x86rec "$exe" re/ghidra_funcs.txt port/src/rec
step "Building the game (about a minute)..." port/build.sh
cp port/jade "$game/jade"

echo
echo "Done. To play, run:"
echo "  \"$game/jade\""
