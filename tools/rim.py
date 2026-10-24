#!/usr/bin/env python3
"""List and extract Jade Empire RIM archives. WHY: docs/modding.md §1

Usage:
  rim.py list FILE.rim [SUBSTRING]   resref, extension, size of each entry
  rim.py get FILE.rim OUTDIR NAME... write NAME (resref.ext) to OUTDIR

Layout (little endian): "RIM V1.0", u32 0, u32 entry count, u32 entry table
offset; each entry is 32 bytes: char resref[16], u16 type, u16 0, u32 index,
u32 data offset, u32 data size. Data is stored uncompressed.
A module folder data/<module>/ holds a010.rim (scripts, dialogs, templates)
and a010-a.rim (area geometry and textures); a file in override/ with the
same resref.ext replaces the RIM entry.
"""
import os
import struct
import sys

MAGIC = b"RIM V1.0"
ENTRY = 32
ENTRIES_MAX = 1 << 16
# Resource type id -> extension, named from each type's file magic in the
# shipped RIMs (Jade Empire's ids differ from KotOR's). Others print as numbers.
EXT = {
    2002: "mdl", 2010: "ncs", 2017: "2da", 2026: "cre", 2029: "dlg", 2031: "trg", 2043: "pla",
    2053: "pwk", 3000: "lyt", 3001: "vis", 3012: "qst", 3013: "sto", 3015: "hex",
    3016: "mdx", 3017: "tpc", 3022: "fsm", 3023: "scn",
}


def entries(data):
    """[(resref, type, offset, size)] of a RIM image."""
    if data[:8] != MAGIC:
        raise SystemExit("not a RIM V1.0 file")
    n, table = struct.unpack_from("<II", data, 12)
    if n > ENTRIES_MAX or table + n * ENTRY > len(data):
        raise SystemExit("entry table out of range: %d at %#x" % (n, table))
    out = []
    for i in range(n):
        e = table + i * ENTRY
        ref = data[e:e + 16].split(b"\0")[0].decode("latin-1")
        ty, _, _, off, size = struct.unpack_from("<HHIII", data, e + 16)
        if off + size > len(data):
            raise SystemExit("%s data out of range" % ref)
        out.append((ref, ty, off, size))
    return out


def name(ref, ty):
    return "%s.%s" % (ref, EXT.get(ty, str(ty)))


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    with open(sys.argv[2], "rb") as f:
        data = f.read()
    table = entries(data)
    if sys.argv[1] == "list" and len(sys.argv) <= 4:
        sub = sys.argv[3] if len(sys.argv) == 4 else ""
        for ref, ty, _, size in table:
            if sub in ref:
                print("%-24s %8d" % (name(ref, ty), size))
    elif sys.argv[1] == "get" and len(sys.argv) >= 5:
        want = set(sys.argv[4:])
        for ref, ty, off, size in table:
            if name(ref, ty) in want:
                with open(os.path.join(sys.argv[3], name(ref, ty)), "wb") as f:
                    f.write(data[off:off + size])
                want.discard(name(ref, ty))
        if want:
            raise SystemExit("not found: %s" % " ".join(sorted(want)))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
