#!/usr/bin/env python3
"""Dump every texture the game can load, as NAME.tpc, for upscale_tex.py.
WHY: docs/modding.md §1

Usage:
  dump_tex.py GAMEDIR OUTDIR

Sources, in order: TPCs (type 3017) in the BIFs chitin.key lists, then TPCs
in data/**/*.rim not already dumped (first RIM in sorted path order wins),
then override/*.txb written over the same names (override wins in game).
KEY V1 layout (little endian): u32 bif count, res count, bif table offset,
res table offset at 8; bif entries 12 bytes (u32 size, u32 name offset,
u16 name length, u16 drives); res entries 22 bytes (char resref[16], u16
type, u32 id = bif << 20 | index). BIFF V1: u32 resource count at 8, table
offset at 16; entries 16 bytes (u32 id, offset, size, type).
"""
import glob
import os
import shutil
import struct
import sys

import rim

TPC = 3017


def key_names(key):
    """bif paths and {id: resref} of a chitin.key image."""
    nbif, nres, off_b, off_r = struct.unpack_from("<4I", key, 8)
    bifs = []
    for i in range(nbif):
        _size, noff, nlen, _drv = struct.unpack_from("<IIHH", key, off_b + 12 * i)
        bifs.append(key[noff:noff + nlen].rstrip(b"\0").decode().replace("\\", "/"))
    names = {}
    for i in range(nres):
        ref, _ty, rid = struct.unpack_from("<16sHI", key, off_r + 22 * i)
        names[rid] = ref.rstrip(b"\0").decode("latin-1").lower()
    return bifs, names


def save(out, ref, blob):
    with open(os.path.join(out, ref + ".tpc"), "wb") as f:
        f.write(blob)


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    game, out = sys.argv[1:]
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(game, "chitin.key"), "rb") as f:
        bifs, names = key_names(f.read())
    done = set()
    for bi, path in enumerate(bifs):
        with open(os.path.join(game, path), "rb") as f:
            b = f.read()
        if b[:8] != b"BIFFV1  ":
            raise SystemExit("%s: not a BIFF V1 file" % path)
        n, table = struct.unpack_from("<2I", b, 8)[0], struct.unpack_from("<I", b, 16)[0]
        for j in range(n):
            _rid, off, size, ty = struct.unpack_from("<4I", b, table + 16 * j)
            ref = names.get((bi << 20) | j)
            if ty == TPC and ref and ref not in done:
                save(out, ref, b[off:off + size])
                done.add(ref)
    nbif = len(done)
    for path in sorted(glob.glob(os.path.join(game, "data", "**", "*.rim"), recursive=True)):
        with open(path, "rb") as f:
            data = f.read()
        for ref, ty, off, size in rim.entries(data):
            ref = ref.lower()
            if ty == TPC and ref not in done:
                save(out, ref, data[off:off + size])
                done.add(ref)
    nrim = len(done) - nbif
    txb = sorted(glob.glob(os.path.join(game, "override", "*.txb")))
    for path in txb:
        ref = os.path.basename(path)[:-4].lower()
        shutil.copyfile(path, os.path.join(out, ref + ".tpc"))
        done.add(ref)
    print("%d from BIFs, %d from RIMs, %d override, %d files" % (nbif, nrim, len(txb), len(done)))


if __name__ == "__main__":
    main()
