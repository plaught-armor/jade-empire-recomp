"""Prints the build ID that online peers compare (docs/hle.md §11).

usage: build_id.py

The ID is 16 hex digits of a sha256 over the Odin compiler's version and every file under src (the recompiled code in src/rec included),
in path order. Line endings are hashed as LF, so a CRLF checkout or a
src/rec generated on Windows gives the same ID as on Linux. Builds with the
same ID run the game identically whatever -microarch, linker or machine made
them, on Linux or Windows: the x87 and libm math is bit-exact
(docs/recompiler.md §8) and no game state reads the host OS's libm, so a
Linux and a Windows peer play together.
"""

import hashlib
import os
import subprocess
import sys

def main():
    if len(sys.argv) != 1:
        sys.exit("usage: build_id.py")
    here = os.path.dirname(os.path.abspath(__file__))
    version = subprocess.run(["odin", "version"], capture_output=True, text=True, check=True).stdout.strip()
    paths = []
    for root, _, names in os.walk(os.path.join(here, "src")):
        for name in names:
            paths.append(os.path.relpath(os.path.join(root, name), here).replace(os.sep, "/"))
    h = hashlib.sha256(f"{version}\n".encode())
    for path in sorted(paths):
        with open(os.path.join(here, path), "rb") as fp:
            data = fp.read().replace(b"\r\n", b"\n")
        h.update(f"{hashlib.sha256(data).hexdigest()} {path}\n".encode())
    print(h.hexdigest()[:16])


main()
