#!/bin/sh
# Prints the build ID that online peers compare (docs/hle.md §11): a hash of
# every file under src (the recompiled code in src/rec included), the Odin
# compiler's version and the target OS named by $1 (linux or windows). Builds
# with the same ID run the game identically whatever -microarch or machine
# made them: the x87 and libm math is bit-exact (docs/recompiler.md §8).
set -eu
cd "$(dirname "$0")"
{
	echo "${1:?usage: build_id.sh linux|windows}"
	odin version
	find src -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
} | sha256sum | cut -c1-16
