#!/bin/sh
# Builds the port, then runs it with the whole session logged to
# logs/play-<timestamp>.log (stdout and stderr). F12 in game writes a mark
# line and the frame as logs/play-<timestamp>/mark_NN_frame_NNNNN.ppm.
# JE_STICK_LOG=1 logs the left stick, facing and movement (native/stick_log.odin).
# Usage: ./play.sh [extra env, e.g. JE_FULLSCREEN=1 ./play.sh]
set -eu
cd "$(dirname "$0")"
root="$(cd .. && pwd)"
game="$root/steamapps/common/Jade Empire"
exe="$root/unpacked/JadeEmpire.exe"
# A full build takes about 45 s, so skip it when nothing changed since the
# last one.
if [ ! -x jade ] || [ -n "$(find src build.sh -newer jade -print -quit)" ]; then
	echo "building (about 45 s)..."
	./build.sh > build.log 2>&1 || { grep "Error:" -A3 build.log; echo "build failed, see port/build.log"; exit 1; }
fi
stamp="$(date +%Y%m%d-%H%M%S)"
mkdir -p "logs/play-$stamp"
log="$PWD/logs/play-$stamp.log"
echo "logging to $log"
JE_STICK_LOG=1 JE_MARK_DIR="$PWD/logs/play-$stamp" ./jade "$game" "$exe" 2>&1 | tee "$log"
