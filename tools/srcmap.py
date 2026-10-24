"""Map source-file assert strings -> referencing functions -> address ranges."""
import sys, re, struct, bisect, collections, pefile
exe, funcs = sys.argv[1:3]
pe = pefile.PE(exe); img = pe.get_memory_mapped_image(); base = 0x400000
text = img[0x1000:0x2e1000]; data = img[0x2e1000:0x495000]
fs = sorted(int(l.split()[0], 16) for l in open(funcs))
strs = {}
for m in re.finditer(rb"[ -~]{4,200}?\.(cpp|h|inl)\x00", data, re.I):
    s = m.group()[:-1].decode()
    # take the trailing path component only
    name = re.split(r"[\\/]", s)[-1].lower()
    if re.fullmatch(r"[\w.\-]+\.(cpp|h|inl)", name):
        strs[0x6e1000 + m.start()] = name
by_file = collections.defaultdict(set)
for va, name in strs.items():
    pat = struct.pack("<I", va)
    i = text.find(pat)
    for _ in range(10000):
        if i < 0: break
        ref = 0x401000 + i
        j = bisect.bisect_right(fs, ref) - 1
        if j >= 0: by_file[name].add(fs[j])
        i = text.find(pat, i + 1)
rows = []
for name, fset in by_file.items():
    if name.endswith(".cpp"):
        rows.append((min(fset), max(fset), len(fset), name))
rows.sort()
for lo, hi, n, name in rows: print(f"{lo:#x} {hi:#x} {n:4d} {name}")
print("cpp files", len(rows), "headers", sum(1 for k in by_file if not k.endswith('.cpp')))
