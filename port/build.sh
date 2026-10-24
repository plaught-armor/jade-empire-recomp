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
odin build src -out:jade -use-separate-modules -debug -o:"${JE_OPT:-speed}" -microarch:"${JE_ARCH:-native}" -define:GL_DEBUG="${JE_GL_DEBUG:-false}" -define:JE_BUILD_ID="$(./build_id.sh linux)" "$@"
