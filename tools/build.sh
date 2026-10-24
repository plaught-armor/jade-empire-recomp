#!/bin/sh
# Builds the Odin tools into port/build: the recompiler (x86rec), the
# analysis tools and the game data tools. The ones that disassemble use
# capstone 5.0.7, built here from its pinned source tarball (x86 only) into
# port/build/capstone, plus the flat-view shim tools/capstone/capstone.c,
# rebuilt every run.
# Usage: tools/build.sh [tool...]   (all when none given)
set -e
cd "$(dirname "$0")/.."
cs=5.0.7
out=port/build/capstone
src="port/build/dl/capstone-$cs"
cc_cs() {
	cc -std=gnu99 -O2 -w -I"$src/include" -DCAPSTONE_HAS_X86 -DCAPSTONE_USE_SYS_DYN_MEM \
		-c "$1" -o "$out/obj/$(basename "$1" .c).o"
}
if [ ! -f "$out/libcapstone.a" ] || [ ! -d "$src/include" ]; then
	mkdir -p port/build/dl "$out/obj"
	curl -sSLf -o port/build/dl/capstone.tar.gz "https://github.com/capstone-engine/capstone/archive/refs/tags/$cs.tar.gz"
	echo "6427a724726d161d1e05fb49fff8cd0064f67836c04ffca3c11d6d859e719caa  port/build/dl/capstone.tar.gz" | sha256sum -c --quiet
	rm -rf "$src"
	tar -xzf port/build/dl/capstone.tar.gz -C port/build/dl
	for c in "$src"/cs.c "$src"/Mapping.c "$src"/MCInst.c "$src"/MCInstrDesc.c "$src"/MCRegisterInfo.c \
		"$src"/SStream.c "$src"/utils.c "$src"/arch/X86/*.c; do
		cc_cs "$c"
	done
fi
cc_cs tools/capstone/capstone.c
rm -f "$out/libcapstone.a"
ar rcs "$out/libcapstone.a" "$out"/obj/*.o
tools="${*:-x86rec inventory srcmap devcalls funcnames cmdtable untpf rim twoda ncs jectl dump_tex jeplay}"
for t in $tools; do
	odin build "tools/$t" -out:"port/build/$t" -o:speed -microarch:native
done
