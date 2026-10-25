#!/bin/sh
# Regenerates port/winlib/lib, the libraries a Windows build links in place
# of Visual Studio's and the Windows SDK's, so building for Windows needs
# only Odin's release (odin.exe and its lld-link), on Windows or on Linux:
#  - import libraries for system DLLs (kernel32.lib, libucrt.lib and the
#    rest), made by llvm-dlltool from the export name lists in def/, which
#    this script reads out of the SDK's import libraries;
#  - jadecrt.lib, the C runtime start-up (crt.c);
#  - the C code: libz.lib (zlib 1.3.1), capstone.lib (capstone 5.0.7, x86,
#    plus tools/capstone/capstone.c), movie.lib (src/win32/movie.c, against
#    the FFmpeg headers in build/ffmpeg-win) and vorbis.lib
#    (src/win32/vorbis.c).
# All C is compiled /Zl /GS-: no default library and no security cookie, as
# nothing but ucrtbase.dll and jadecrt.lib provides the C runtime.
# Run it after changing any of those C files (and commit lib/). Needs
# clang-cl, llvm-lib, llvm-dlltool, llvm-nm and xwin's splat of the Windows
# SDK and CRT in $XWIN (default ~/.local/share/xwin); the
# FFmpeg headers come from build/ffmpeg-win, which build_windows.sh fetches.
set -eu
cd "$(dirname "$0")"
XWIN="${XWIN:-$HOME/.local/share/xwin}"
port="$PWD/.."
dl="$port/build/dl"
obj="$port/build/winlib"
rm -rf "$obj"
mkdir -p "$obj" "$dl" def lib

# The export names an import library holds, a line "dll name [DATA]" each;
# a name with only an __imp_ symbol is data.
exports() {
	llvm-nm "$1" 2>/dev/null | awk '
		/^[^ ].*\.(dll|DLL):$/ { dll = tolower(substr($0, 1, length($0) - 1)); next }
		dll != "" && $2 == "T" { sym[dll, $3] = 1 }
		END {
			for (key in sym) {
				split(key, p, SUBSEP)
				if (p[2] !~ /^__imp_/) print p[1], p[2]
				else if (!((p[1], substr(p[2], 7)) in sym)) print p[1], substr(p[2], 7), "DATA"
			}
		}'
}

# Lines from exports, as def/<name>.def, one DLL.
def() {
	sort -u | awk -v f="def/$1.def" '
		NR == 1 { print "LIBRARY " $1 > f; print "EXPORTS" > f }
		{ print "\t" $2 ($3 != "" ? " " $3 : "") > f }'
}

# The system libraries Odin's packages import, as Odin names them. The C
# runtime is ucrtbase.dll, which every api-ms-win-crt name forwards to.
rm -f def/*.def lib/*
SDK="$XWIN/sdk/lib/um/x86_64"
for l in kernel32 advapi32 bcrypt dnsapi ntdll shell32 ws2_32; do
	exports "$SDK/$l.lib" | def "$l"
done
exports "$XWIN/sdk/lib/ucrt/x86_64/ucrt.lib" | awk '{ $1 = "ucrtbase.dll"; print }' | def libucrt
for d in def/*.def; do
	llvm-dlltool -m i386:x86-64 -d "$d" -l "lib/$(basename "$d" .def).lib"
done

cc() {
	clang-cl --target=x86_64-pc-windows-msvc /O2 /Zl /GS- \
		-imsvc "$XWIN/crt/include" -imsvc "$XWIN/sdk/include/ucrt" \
		-imsvc "$XWIN/sdk/include/um" -imsvc "$XWIN/sdk/include/shared" "$@"
}

cc /W3 /WX /c crt.c "/Fo$obj/crt.obj"
llvm-lib "/out:lib/jadecrt.lib" "$obj/crt.obj"

zlib=1.3.1
if [ ! -f "$dl/zlib-$zlib.tar.gz" ]; then
	curl -sSLf -o "$dl/zlib-$zlib.tar.gz" "https://github.com/madler/zlib/releases/download/v$zlib/zlib-$zlib.tar.gz"
fi
echo "9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23  $dl/zlib-$zlib.tar.gz" | sha256sum -c --quiet
tar -xzf "$dl/zlib-$zlib.tar.gz" -C "$obj"
mkdir "$obj/z"
for f in adler32 compress crc32 deflate inffast inflate inftrees trees uncompr zutil; do
	cc /w /c "$obj/zlib-$zlib/$f.c" "/Fo$obj/z/$f.obj"
done
llvm-lib /out:lib/libz.lib "$obj"/z/*.obj
cp "$obj/zlib-$zlib/LICENSE" lib/LICENSE-zlib.txt

cs=5.0.7
if [ ! -f "$dl/capstone.tar.gz" ]; then
	curl -sSLf -o "$dl/capstone.tar.gz" "https://github.com/capstone-engine/capstone/archive/refs/tags/$cs.tar.gz"
fi
echo "6427a724726d161d1e05fb49fff8cd0064f67836c04ffca3c11d6d859e719caa  $dl/capstone.tar.gz" | sha256sum -c --quiet
tar -xzf "$dl/capstone.tar.gz" -C "$obj"
src="$obj/capstone-$cs"
mkdir "$obj/cs"
for c in "$src"/cs.c "$src"/Mapping.c "$src"/MCInst.c "$src"/MCInstrDesc.c "$src"/MCRegisterInfo.c \
	"$src"/SStream.c "$src"/utils.c "$src"/arch/X86/*.c "$port/../tools/capstone/capstone.c"; do
	cc /w "-I$src/include" -DCAPSTONE_HAS_X86 -DCAPSTONE_USE_SYS_DYN_MEM \
		/c "$c" "/Fo$obj/cs/$(basename "$c" .c).obj"
done
llvm-lib /out:lib/capstone.lib "$obj"/cs/*.obj
cp "$src/LICENSE.TXT" lib/LICENSE-capstone.txt

# Bink movie decoding and stb_vorbis with deterministic sin and cos, as
# build.sh builds them.
cc /std:c17 /W3 /WX "/I$port/build/ffmpeg-win/include" /c "$port/src/win32/movie.c" "/Fo$obj/movie.obj"
llvm-lib /out:lib/movie.lib "$obj/movie.obj"
cc /std:c17 /w /fp:precise -ffp-contract=off "/I$(odin root)/vendor/stb/src" \
	/c "$port/src/win32/vorbis.c" "/Fo$obj/vorbis.obj"
llvm-lib /out:lib/vorbis.lib "$obj/vorbis.obj"
