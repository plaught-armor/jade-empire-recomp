#!/bin/sh
# Build the port: optimized with debug info. Set JE_OPT=none for an
# unoptimized build and JE_GL_DEBUG=true for a glGetError check after every GL
# call (slow: docs/recompiler.md §2); other flags pass through. The code is
# built for this machine's CPU (AVX2/AVX-512 where present); JE_ARCH names
# another -microarch. LLVM fuses no multiply-add unless asked, so the f32
# results stay bit-exact with the guest's (docs/recompiler.md §8).
set -e
cd "$(dirname "$0")"
# Bink movie decoding is C over FFmpeg (src/win32/movie.c, docs/hle.md §4).
mkdir -p build
cc -std=c17 -O2 -g -Wall -Wextra -Werror -c src/win32/movie.c -o build/movie.o
ar rcs build/libmovie.a build/movie.o
# stb_vorbis with deterministic sin and cos (src/win32/vorbis.c): its samples
# are guest state, the same on every OS (docs/hle.md §11). Third-party code,
# so its warnings are off; no FMA, no contraction.
cc -std=c17 -O2 -g -w -ffp-contract=off -fno-fast-math -I"$(odin root)/vendor/stb/src" -c src/win32/vorbis.c -o build/vorbis.o
ar rcs build/libvorbis.a build/vorbis.o
odin build src -out:jade -use-separate-modules -debug -o:"${JE_OPT:-speed}" -microarch:"${JE_ARCH:-native}" -define:GL_DEBUG="${JE_GL_DEBUG:-false}" -define:JE_BUILD_ID="$(python3 build_id.py)" "$@"
