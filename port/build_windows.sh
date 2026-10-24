#!/bin/sh
# Cross-builds the port for 64-bit Windows on Linux: build/win/jade.exe plus
# the DLLs it needs beside it (SDL3, FFmpeg) and play.bat, all of it also
# zipped as build/jade-win.zip. Needs clang-cl, llvm-lib, zip,
# lld-link and the Windows SDK and CRT splatted by xwin into
# $XWIN (default ~/.local/share/xwin; `xwin --accept-license splat --output
# ~/.local/share/xwin`). The code targets x86-64-v3 (AVX2) unless JE_ARCH
# names another -microarch, so one exe runs on any recent PC. Online peers
# need the same build ID (build_id.py, docs/hle.md §11). Other flags pass
# through to odin, as in build.sh.
set -eu
cd "$(dirname "$0")"
XWIN="${XWIN:-$HOME/.local/share/xwin}"
mkdir -p build/win build/dl

# FFmpeg 9.0 shared LGPL build (import libraries, headers, DLLs).
if [ ! -d build/ffmpeg-win ]; then
	name=ffmpeg-n9.0-latest-win64-lgpl-shared-9.0
	curl -sSLf -o build/dl/ffmpeg.zip "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/$name.zip"
	rm -rf "build/dl/$name"
	unzip -q -d build/dl build/dl/ffmpeg.zip
	mkdir build/ffmpeg-win
	cp -r "build/dl/$name/bin" "build/dl/$name/lib" "build/dl/$name/include" "build/dl/$name/LICENSE.txt" build/ffmpeg-win/
fi

# SDL3 at the version Odin's vendor:sdl3 binds. Odin ships SDL3.lib and
# SDL3.dll as git-lfs pointers, so the build uses a shadow ODIN_ROOT whose
# vendor/sdl3 is a copy holding the real files; everything else links back
# to the installed Odin.
sdl=3.4.2
if [ ! -d build/sdl3-win ]; then
	curl -sSLf -o build/dl/sdl3.zip "https://github.com/libsdl-org/SDL/releases/download/release-$sdl/SDL3-devel-$sdl-VC.zip"
	rm -rf "build/dl/SDL3-$sdl"
	unzip -q -d build/dl build/dl/sdl3.zip
	mkdir build/sdl3-win
	cp "build/dl/SDL3-$sdl/lib/x64/SDL3.dll" "build/dl/SDL3-$sdl/lib/x64/SDL3.lib" "build/dl/SDL3-$sdl/LICENSE.txt" build/sdl3-win/
fi

# zlib (src/win32/net_save.odin). Odin's vendor/zlib/libz.lib is built with
# MSVC link-time code generation (/GL), which lld-link cannot read, so it is
# built here from source, static CRT (/MT) like Odin's. The binding uses only
# compress2, uncompress and compressBound, the same in every 1.2/1.3.
zlib=1.3.1
if [ ! -f build/zlib-win/libz.lib ]; then
	curl -sSLf -o build/dl/zlib.tar.gz "https://github.com/madler/zlib/releases/download/v$zlib/zlib-$zlib.tar.gz"
	rm -rf "build/dl/zlib-$zlib" build/zlib-win
	tar -xzf build/dl/zlib.tar.gz -C build/dl
	mkdir -p build/zlib-win/obj
	for f in adler32 compress crc32 deflate inffast inflate inftrees trees uncompr zutil; do
		clang-cl --target=x86_64-pc-windows-msvc /O2 /MT /w \
			-imsvc "$XWIN/crt/include" -imsvc "$XWIN/sdk/include/ucrt" \
			-imsvc "$XWIN/sdk/include/um" -imsvc "$XWIN/sdk/include/shared" \
			/c "build/dl/zlib-$zlib/$f.c" "/Fobuild/zlib-win/obj/$f.obj"
	done
	llvm-lib /out:build/zlib-win/libz.lib build/zlib-win/obj/*.obj
fi

odin_sys="$(odin root)"
root=build/odin-win
rm -rf "$root"
mkdir -p "$root/vendor"
for d in base core shared; do
	ln -s "$odin_sys/$d" "$root/$d"
done
for d in "$odin_sys"/vendor/*; do
	case "$(basename "$d")" in sdl3|zlib) ;; *) ln -s "$d" "$root/vendor/" ;; esac
done
cp -r "$odin_sys/vendor/sdl3" "$root/vendor/sdl3"
cp build/sdl3-win/SDL3.dll build/sdl3-win/SDL3.lib "$root/vendor/sdl3/"
cp -r "$odin_sys/vendor/zlib" "$root/vendor/zlib"
cp build/zlib-win/libz.lib "$root/vendor/zlib/"

# Bink movie decoding (src/win32/movie.c), static CRT (/MT) like Odin's.
clang-cl --target=x86_64-pc-windows-msvc /std:c17 /O2 /W3 /WX /MT \
	-imsvc "$XWIN/crt/include" -imsvc "$XWIN/sdk/include/ucrt" \
	-imsvc "$XWIN/sdk/include/um" -imsvc "$XWIN/sdk/include/shared" \
	/Ibuild/ffmpeg-win/include /c src/win32/movie.c /Fobuild/win/movie.obj
llvm-lib /out:build/win/movie.lib build/win/movie.obj
# stb_vorbis with deterministic sin and cos (src/win32/vorbis.c, build.sh).
clang-cl --target=x86_64-pc-windows-msvc /std:c17 /O2 /w /MT /fp:precise -ffp-contract=off \
	-imsvc "$XWIN/crt/include" -imsvc "$XWIN/sdk/include/ucrt" \
	-imsvc "$XWIN/sdk/include/um" -imsvc "$XWIN/sdk/include/shared" \
	"/I$odin_sys/vendor/stb/src" /c src/win32/vorbis.c /Fobuild/win/vorbis.obj
llvm-lib /out:build/win/vorbis.lib build/win/vorbis.obj

# Odin's -windows-sdk-root passes /winsysroot, which wants the MSVC folder
# layout; xwin's splat layout needs the library paths named. With a large
# open-file limit (the default 1048576 in some shells) the Windows-target
# build stalls single-threaded and eats tens of GB, so cap it.
ulimit -n 1024
ODIN_ROOT="$PWD/$root" odin build src -out:build/win/jade.exe -target:windows_amd64 \
	-windows-sdk-root:"$XWIN" -linker:lld -use-separate-modules \
	-o:"${JE_OPT:-speed}" -microarch:"${JE_ARCH:-x86-64-v3}" \
	-define:GL_DEBUG="${JE_GL_DEBUG:-false}" \
	-define:JE_BUILD_ID="$(python3 build_id.py)" \
	-extra-linker-flags:"/libpath:$XWIN/crt/lib/x86_64 /libpath:$XWIN/sdk/lib/um/x86_64 /libpath:$XWIN/sdk/lib/ucrt/x86_64" \
	"$@"

# Runtime DLLs and their licences beside the exe.
cp build/sdl3-win/SDL3.dll build/win/
for d in avcodec-63 avformat-63 avutil-61 swresample-7 swscale-10; do
	cp "build/ffmpeg-win/bin/$d.dll" build/win/
done
cp build/sdl3-win/LICENSE.txt build/win/LICENSE-SDL3.txt
cp build/ffmpeg-win/LICENSE.txt build/win/LICENSE-FFmpeg.txt
sed 's/\r*$/\r/' play.bat > build/win/play.bat

# build/jade-win.zip: what a Windows PC needs, without jade.pdb. The game
# files and the unpacked JadeEmpire.exe are never part of it.
rm -f build/jade-win.zip
(cd build/win && zip -q -X ../jade-win.zip jade.exe play.bat SDL3.dll \
	avcodec-63.dll avformat-63.dll avutil-61.dll swresample-7.dll swscale-10.dll \
	LICENSE-SDL3.txt LICENSE-FFmpeg.txt)
