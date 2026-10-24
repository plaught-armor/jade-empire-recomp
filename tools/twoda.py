"""Read Jade Empire 2DA tables, binary (2DA V2.b) or text (2DA V2.0). WHY: docs/modding.md §1

The base tables sit in GAME_RIMS as type 2017 (binary); patched copies in
override/ are text. The binary layout is checked as it is read
(every cell offset inside the string pool, the pool ending the file), so a
layout guess that is wrong fails loudly instead of yielding shifted cells.

Usage:
  twoda.py dump FILE [COLUMN...]   rows as tab-separated text ("" cells shown as ****)
  twoda.py style GAMEDIR STYLE      attack rows of a combat style (GetCurrentStyle value)
"""
import os
import struct
import sys
from collections import namedtuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rim  # noqa: E402

# miniglobal: the global tables; globalunload: each style's AS (attack anims,
# ranges, damage) and MV (moves) tables. No 2DA is in chitin.key.
GAME_RIMS = ("miniglobal-a.rim", "globalunload-a.rim")
TYPE_2DA = 2017
BINARY_MAGIC = b"2DA V2.b\n"
TEXT_MAGIC = b"2DA V2.0"
EMPTY = "****"
STYLE_COLUMNS = ("label", "anim", "minrange", "maxrange", "unblockable", "hdamage")
MAX_FIELDS = 65536  # bound on header / row-label scans

Table = namedtuple("Table", "columns labels rows")  # rows: list of lists of str


def _tab_list(d, pos, count):
    """count tab-terminated strings from pos (count None: until a NUL byte).
    Returns (strings, position after the last)."""
    out = []
    for _ in range(MAX_FIELDS):
        if count is None and d[pos] == 0:
            return out, pos + 1
        if count is not None and len(out) == count:
            return out, pos
        end = d.index(b"\t", pos)
        out.append(d[pos:end].decode("latin-1"))
        pos = end + 1
    raise AssertionError("more than %d fields" % MAX_FIELDS)


def parse_binary(d):
    assert d.startswith(BINARY_MAGIC), d[:9]
    cols, pos = _tab_list(d, len(BINARY_MAGIC), None)
    (nrows,) = struct.unpack_from("<I", d, pos)
    labels, pos = _tab_list(d, pos + 4, nrows)
    ncells = nrows * len(cols)
    offs = struct.unpack_from("<%dH" % ncells, d, pos)
    pos += 2 * ncells
    (pool_size,) = struct.unpack_from("<H", d, pos)
    pool = d[pos + 2:]
    assert len(pool) == pool_size, (len(pool), pool_size)
    rows = []
    for r in range(nrows):
        row = []
        for c in range(len(cols)):
            o = offs[r * len(cols) + c]
            assert o < pool_size, (r, c, o, pool_size)
            row.append(pool[o:pool.index(b"\0", o)].decode("latin-1"))
        rows.append(row)
    return Table(cols, labels, rows)


def parse_text(d):
    assert d.startswith(TEXT_MAGIC), d[:8]
    lines = [ln for ln in d.decode("latin-1").splitlines()[1:] if ln.strip()]
    if lines and lines[0].lstrip().startswith("DEFAULT:"):
        lines = lines[1:]
    cols = lines[0].split()
    labels, rows = [], []
    for ln in lines[1:]:
        f = ln.split()
        assert len(f) == len(cols) + 1, (len(f), len(cols), ln[:60])
        labels.append(f[0])
        rows.append(["" if v == EMPTY else v for v in f[1:]])
    return Table(cols, labels, rows)


def parse(d):
    return parse_binary(d) if d.startswith(BINARY_MAGIC) else parse_text(d)


def load(path):
    with open(path, "rb") as f:
        return parse(f.read())


def game_table(game, resref):
    """The table resref as the engine sees it: override/<resref>.2da if
    present (any case), else the binary copy in one of GAME_RIMS."""
    want = resref.lower() + ".2da"
    over = os.path.join(game, "override")
    for f in os.listdir(over):
        if f.lower() == want:
            return load(os.path.join(over, f))
    for rim_name in GAME_RIMS:
        with open(os.path.join(game, "data", rim_name), "rb") as f:
            data = f.read()
        for ref, ty, off, size in rim.entries(data):
            if ty == TYPE_2DA and ref.lower() == resref.lower():
                return parse(data[off:off + size])
    raise SystemExit("no 2DA %s in override/ or %s" % (resref, ", ".join(GAME_RIMS)))


def style_attacks(game, style):
    """The attack rows (AS table records) of combat style `style`, the value
    GetCurrentStyle returns: a stylesuperlist row, whose styledata column
    names a styledata row, whose animsound2da column names the AS table.
    Rows with no anim are dropped. WHY: docs/modding.md §5"""
    sup = records(game_table(game, "stylesuperlist"))
    assert 0 <= style < len(sup), (style, len(sup))
    data_row = sup[style]["styledata"]
    if not data_row:
        raise SystemExit("style %d (%s) has no styledata row" % (style, sup[style]["label"]))
    sd = records(game_table(game, "styledata"))
    as_name = sd[int(data_row)]["animsound2da"]
    return [r for r in records(game_table(game, as_name)) if r.get("anim")]


def records(t):
    """Each row as a dict keyed by lower-case column name, plus "_row"."""
    keys = [c.lower() for c in t.columns]
    return [dict(zip(keys, row), _row=lab) for lab, row in zip(t.labels, t.rows)]


def main(argv):
    if len(argv) == 4 and argv[1] == "style":
        for r in style_attacks(argv[2], int(argv[3])):
            print("\t".join(r.get(k) or EMPTY for k in STYLE_COLUMNS))
        return
    if len(argv) < 3 or argv[1] != "dump":
        raise SystemExit(__doc__)
    t = load(argv[2])
    want = [c.lower() for c in argv[3:]]
    idx = [i for i, c in enumerate(t.columns) if not want or c.lower() in want]
    missing = set(want) - {t.columns[i].lower() for i in idx}
    if missing:
        raise SystemExit("no column %s in %s" % (", ".join(sorted(missing)), argv[2]))
    print("\t".join(["row"] + [t.columns[i] for i in idx]))
    for lab, row in zip(t.labels, t.rows):
        print("\t".join([lab] + [row[i] or EMPTY for i in idx]))


if __name__ == "__main__":
    main(sys.argv)
