#!/bin/sh
# Build the recompiler (tools/x86rec) as port/build/x86rec. It decodes with
# capstone 5.0.7, built here from its pinned source tarball (x86 only) into
# port/build/capstone together with the flat-view shim capstone.c.
set -e
cd "$(dirname "$0")/../.."
cs=5.0.7
out=port/build/capstone
if [ ! -f "$out/libcapstone.a" ]; then
	mkdir -p port/build/dl "$out/obj"
	curl -sSLf -o port/build/dl/capstone.tar.gz "https://github.com/capstone-engine/capstone/archive/refs/tags/$cs.tar.gz"
	echo "6427a724726d161d1e05fb49fff8cd0064f67836c04ffca3c11d6d859e719caa  port/build/dl/capstone.tar.gz" | sha256sum -c --quiet
	rm -rf "port/build/dl/capstone-$cs"
	tar -xzf port/build/dl/capstone.tar.gz -C port/build/dl
	src="port/build/dl/capstone-$cs"
	for c in "$src"/cs.c "$src"/Mapping.c "$src"/MCInst.c "$src"/MCInstrDesc.c "$src"/MCRegisterInfo.c \
		"$src"/SStream.c "$src"/utils.c "$src"/arch/X86/*.c tools/x86rec/capstone.c; do
		cc -std=gnu99 -O2 -w -I"$src/include" -DCAPSTONE_HAS_X86 -DCAPSTONE_USE_SYS_DYN_MEM \
			-c "$c" -o "$out/obj/$(basename "$c" .c).o"
	done
	ar rcs "$out/libcapstone.a" "$out"/obj/*.o
fi
odin build tools/x86rec -out:port/build/x86rec -o:speed -microarch:native "$@"
