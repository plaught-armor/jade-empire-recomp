#!/usr/bin/env python3
"""Client for the port's live control channel (JE_CTL=<dir>, docs/recompiler.md §7).

Usage: jectl.py <dir> <command> [<command> ...]

Each command is sent as one line and its answer printed. Commands run in
order; each waits for its answer (timeout 120 s). Client-side commands:
  png PATH [WIDTH]   screenshot the next frame to PATH as PNG, scaled to WIDTH
                     (default 960); needs PIL.
Everything else goes to the port as is: frame, wait N, shot PATH, key NAME [N],
down NAME, up NAME, move X Y, click X Y [L|M|R], btn L|M|R down|up,
pad NAME [N], axis NAME V, peek ADDR N, poke ADDR HEX, scan TYPE V, next V,
list, set KEY VALUE ([Port] setting, until exit), quit.
"""
import os
import sys
import time

TIMEOUT_S = 120
BATCH_MAX = 48      # lines per batch, appended in one write
POLL_S = 0.004      # seconds between reads of the answer file (a frame is ~33 ms)


def send(d, line):
    """Send one command line, return the answer text after the id."""
    return send_batch(d, [line])[0]


def send_batch(d, lines):
    """Send command lines in one write, so the port runs them in the same
    frame (it reads <dir>/in once per frame); return their answers in order.
    A query that costs a frame per round trip is too slow to react to a foe's
    wind-up. WHY: docs/modding.md §3"""
    assert 0 < len(lines) <= BATCH_MAX, len(lines)
    out = os.path.join(d, "out")
    start = os.path.getsize(out)
    cid = "%d%06d" % (os.getpid(), time.monotonic_ns() // 1000 % 1000000)
    ids = ["%s_%d" % (cid, i) for i in range(len(lines))]
    with open(os.path.join(d, "in"), "a") as f:
        f.write("".join("%s %s\n" % (i, ln) for i, ln in zip(ids, lines)))
    want = {i + " ": k for k, i in enumerate(ids)}
    got = [None] * len(lines)
    deadline = time.monotonic() + TIMEOUT_S
    pos, tail, left = start, "", len(lines)
    while time.monotonic() < deadline:
        with open(out) as f:
            f.seek(pos)
            tail += f.read()
            pos = f.tell()
        done = tail.rfind("\n") + 1
        for ln in tail[:done].splitlines():
            k = want.get(ln[:ln.find(" ") + 1])
            if k is not None and got[k] is None:
                got[k] = ln[len(ids[k]) + 1:]
                left -= 1
        tail = tail[done:]
        if left == 0:
            return got
        time.sleep(POLL_S)
    raise SystemExit("timeout waiting for answers to %r" % lines)


def png(d, path, width):
    from PIL import Image

    ppm = path + ".ppm"
    r = send(d, "shot " + os.path.abspath(ppm))
    if not r.startswith("ok"):
        return r
    im = Image.open(ppm)
    im = im.resize((width, im.height * width // im.width), Image.LANCZOS)
    im.save(path)
    os.remove(ppm)
    return r


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    d = sys.argv[1]
    for cmd in sys.argv[2:]:
        w = cmd.split()
        if w[0] == "png":
            r = png(d, w[1], int(w[2]) if len(w) > 2 else 960)
        else:
            r = send(d, cmd)
        print("%s -> %s" % (cmd, r))
        if r.startswith("err"):
            sys.exit(1)


if __name__ == "__main__":
    main()
