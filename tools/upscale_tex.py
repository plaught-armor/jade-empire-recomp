# Upscales Jade Empire textures (.tpc dumps, 128-byte header) x4 and writes
# .txb files for the port's textures_hd/ overlay. The result's mips are two
# new ones (x4, x2), then the original's mip chain byte for byte, so the
# texture looks as before from a distance.
# Colour textures (DXT1/DXT5) go through a spandrel model, back-projected once
# (the bicubic x4 of what the model's box /4 misses is added back), so colours
# and structure stay the original's and the model only adds detail. Masks and
# effect sprites (the model draws texture into them), and any texture whose
# raw model output has a box /4 under MIN_PSNR dB of the original (it changed
# what the texture shows), get a plain bicubic x4 instead. Alpha always gets
# a bicubic x4 clipped to the original alpha's range.
# One-byte (format 9) textures are 8-bit grey in Xbox swizzled (Morton) order
# and get a bicubic x4. Normal maps (TXI isbumpmap) are not images: they are
# 32-bit BGRA, swizzled, with the format byte still 12, and get a bicubic x4
# of the vectors, direction and length interpolated apart (lengths under 1 are
# authored, they darken DOT3 lighting).
# A flipbook (TXI numx x numy cells: water, effects, UI strips) is stored as
# one texture per frame, each with its own mip chain and padded to 128 bytes;
# each frame is upscaled on its own.
# Skipped, so the game keeps the original: format 2 and 4 (lightmaps, cube
# maps, a 32-bit UI screen), lightmaps and 3D textures (TXI keys), and any
# texture whose size is not the chain its header and TXI describe.
# usage: upscale_tex.py MODEL OUTDIR FILE.tpc...
import io, os, re, struct, sys, time
import numpy as np, torch
from PIL import Image
from spandrel import ModelLoader

FOURCC = {10: b"DXT1", 12: b"DXT5"}
PIXFMT = {10: "DXT1", 12: "DXT5"}
dev = torch.device("cuda")
model = ModelLoader().load_from_file(sys.argv[1]).eval().to(dev)
OUT = sys.argv[2]
TILE, PAD = 256, 16
MIN_PSNR = 28
BGRA = 32 # level kind of a normal map; the others are the format byte

def dds_decode(d, w, h, fmt):
    n = level_bytes(w, h, fmt)
    hdr = struct.pack("<4sIIIIIII44sII4s20sI16s", b"DDS ", 124, 0x1007, h, w, n, 0, 1, b"", 32, 4, FOURCC[fmt], b"", 0x1000, b"")
    return np.asarray(Image.open(io.BytesIO(hdr + d[:n])).convert("RGBA"), np.float32) / 255

def dds_encode(a, fmt):
    b = io.BytesIO()
    Image.fromarray(a, "RGBA").save(b, "DDS", pixel_format=PIXFMT[fmt])
    d = b.getvalue()
    assert d[:4] == b"DDS " and d[84:88] == FOURCC[fmt]
    return d[128:]

# p pixels of padding round an NxCxHxW tensor: the opposite edge (textures
# tile unless clamped) or the edge repeated, at any size (torch's circular
# mode needs p <= the side).
def edge_pad(t, p, wrap):
    for dim in (2, 3):
        n = t.shape[dim]
        i = torch.arange(-p, n + p, device=t.device)
        t = t.index_select(dim, i % n if wrap else i.clamp(0, n - 1))
    return t

# x4 of an HxWx3 float image.
def run(x, wrap):
    t = edge_pad(torch.from_numpy(x).permute(2, 0, 1)[None].to(dev), PAD, wrap)
    h, w = x.shape[:2]
    y = torch.empty(1, 3, 4 * h, 4 * w, device=dev)
    with torch.no_grad():
        for ty in range(0, h, TILE):
            for tx in range(0, w, TILE):
                th, tw = min(TILE, h - ty), min(TILE, w - tx)
                o = model(t[:, :, ty:ty + th + 2 * PAD, tx:tx + tw + 2 * PAD])
                y[:, :, 4 * ty:4 * (ty + th), 4 * tx:4 * (tx + tw)] = o[:, :, 4 * PAD:4 * (PAD + th), 4 * PAD:4 * (PAD + tw)]
    return y[0].clamp(0, 1).permute(1, 2, 0).cpu().numpy()

def half(a):
    return a.reshape(a.shape[0] // 2, 2, a.shape[1] // 2, 2, -1).mean((1, 3))

def box4(a):
    return a.reshape(a.shape[0] // 4, 4, a.shape[1] // 4, 4, -1).mean((1, 3))

def psnr(a, b):
    return 10 * np.log10(1 / max(np.mean((a - b) ** 2), 1e-10))

SKIP_TXI = (b"islightmap", b"m_bis3dtexture")

def smooth_name(n):
    return "mask" in n or n.startswith("fx_") or "_fx" in n

def u8(a):
    return (a * 255 + 0.5).astype(np.uint8)

# Swizzled index of each (y, x) of a w x h power-of-two level: x and y bits
# interleaved from bit 0, x first, the longer side's spare bits on top.
def morton(w, h):
    ys, xs = np.mgrid[0:h, 0:w]
    idx = np.zeros((h, w), np.int64)
    bit, sx, sy = 0, 1, 1
    while sx < w or sy < h:
        if sx < w: idx |= ((xs & sx) > 0).astype(np.int64) << bit; bit += 1; sx <<= 1
        if sy < h: idx |= ((ys & sy) > 0).astype(np.int64) << bit; bit += 1; sy <<= 1
    return idx

def level_bytes(w, h, kind):
    if kind in FOURCC: return max(1, (w + 3) // 4) * max(1, (h + 3) // 4) * (8 if kind == 10 else 16)
    return w * h * (4 if kind == BGRA else 1)

def chain_bytes(w, h, mips, kind):
    return sum(level_bytes(max(1, w >> i), max(1, h >> i), kind) for i in range(mips))

def txi_int(tail, key, dflt):
    m = re.search(key + rb"\s+(\d+)", tail)
    return int(m[1]) if m else dflt

# Bicubic x4 of an HxWxC float image (padded as run() pads), not clamped.
def bicubic(x, wrap):
    p = 4
    t = edge_pad(torch.from_numpy(np.ascontiguousarray(x, np.float32)).permute(2, 0, 1)[None].to(dev), p, wrap)
    y = torch.nn.functional.interpolate(t, scale_factor=4, mode="bicubic", align_corners=False)
    return y[0, :, 4 * p:-4 * p, 4 * p:-4 * p].permute(1, 2, 0).cpu().numpy()

# x4 of an HxWx3 or HxWx1 image in 0..1: the model back-projected once, or
# bicubic for masks and effects and where the model changed the image.
def x4(x, wrap, name):
    if smooth_name(name.lower()): return bicubic(x, wrap).clip(0, 1)
    sr = run(x, wrap) if x.shape[2] == 3 else run(np.repeat(x, 3, 2), wrap).mean(2, keepdims=True)
    back = psnr(box4(sr), x)
    if back < MIN_PSNR:
        print("bicubic", name, "%.1f dB" % back, flush=True)
        return bicubic(x, wrap).clip(0, 1)
    return (sr + bicubic(x - box4(sr), wrap)).clip(0, 1)

# BGRA of a normal level: interpolated direction at interpolated length.
def normal_bgra(y):
    v, ln = y[:, :, :3], y[:, :, 3:4]
    n = v / np.maximum(np.linalg.norm(v, axis=2, keepdims=True), 1e-6) * ln
    rgb = np.clip(n * 0.5 + 0.5, 0, 1)
    return np.concatenate([rgb[:, :, ::-1], np.clip(y[:, :, 4:], 0, 1)], 2)

def swizzle(a):
    h, w, c = a.shape
    out = np.empty((h * w, c), np.uint8)
    out[morton(w, h).ravel()] = u8(a).reshape(-1, c)
    return out.tobytes()

def deswizzle(fr, w, h, c):
    return np.frombuffer(fr[:w * h * c], np.uint8).reshape(-1, c)[morton(w, h)].astype(np.float32) / 255

# The two new levels (x4, x2) of one frame, as stored bytes.
def normal_levels(fr, w, h, fmt, wrap, name):
    x = deswizzle(fr, w, h, 4)
    v = x[:, :, 2::-1] * 2 - 1
    y = bicubic(np.concatenate([v, np.linalg.norm(v, axis=2, keepdims=True), x[:, :, 3:]], 2), wrap)
    return swizzle(normal_bgra(y)) + swizzle(normal_bgra(half(y)))

def grey_levels(fr, w, h, fmt, wrap, name):
    y = bicubic(deswizzle(fr, w, h, 1), wrap).clip(0, 1)
    return swizzle(y) + swizzle(half(y))

def colour_levels(fr, w, h, fmt, wrap, name):
    x = dds_decode(fr, w, h, fmt)
    rgb = x4(x[:, :, :3], wrap, name)
    if (x[:, :, 3] < 1).any():
        # Alpha is a mask, not a photo: the model and bicubic ringing pushed
        # a bark's 240 edge frame down to 159, lines along every UV wrap.
        a = bicubic(x[:, :, 3:], wrap).clip(x[:, :, 3].min(), x[:, :, 3].max())
        if fmt == 10: a = (a >= 0.5).astype(np.float32)
    else:
        a = np.ones(rgb.shape[:2] + (1,), np.float32)
    y = np.concatenate([rgb, a], 2)
    y1 = half(y)
    if fmt == 10: y1[:, :, 3] = y1[:, :, 3] >= 0.5
    return dds_encode(u8(y), fmt) + dds_encode(u8(y1), fmt)

def write(d, name, w, h, fmt, mips, body, tail):
    hdr = bytearray(d[:128])
    struct.pack_into("<I", hdr, 0, len(body))
    struct.pack_into("<HHBB", hdr, 8, w, h, fmt, mips)
    open(os.path.join(OUT, name + ".txb"), "wb").write(bytes(hdr) + body + tail)

# Writes the .txb for path; returns why it was skipped, or None.
def upscale(path):
    d = open(path, "rb").read()
    sz, _alpha, w, h, fmt, mips = struct.unpack_from("<IfHHBB", d, 0)
    name = os.path.basename(path)[:-4]
    data, low = d[128:128 + sz], d[128 + sz:].lower()
    if fmt not in (9, 10, 12): return "format %d" % fmt
    for k in SKIP_TXI:
        if k in low: return k.decode()
    bump = b"isbumpmap" in low
    kind = BGRA if bump else fmt
    levels = normal_levels if bump else grey_levels if fmt == 9 else colour_levels
    nx, ny = txi_int(low, b"numx", 1), txi_int(low, b"numy", 1)
    fw, fh, n = w // nx, h // ny, nx * ny
    pad = 128 if n > 1 else 1
    chain = chain_bytes(fw, fh, mips, kind)
    stride = -(-chain // pad) * pad
    if sz != stride * n: return "size %d, chain %d x %d" % (sz, stride, n)
    wrap = b"clamp" not in low
    body = b""
    for k in range(n):
        fr = data[k * stride:k * stride + chain]
        f = levels(fr, fw, fh, fmt, wrap, name) + fr
        body += f + bytes(-len(f) % pad)
    write(d, name, 4 * w, 4 * h, fmt, mips + 2, body, d[128 + sz:])
    return None

os.makedirs(OUT, exist_ok=True)
t0 = time.time()
skipped = 0
for i, p in enumerate(sys.argv[3:]):
    why = upscale(p)
    if why:
        skipped += 1
        print("skip", os.path.basename(p), why, flush=True)
    if i % 50 == 0: print(i, os.path.basename(p), "%.0fs" % (time.time() - t0), flush=True)
print("done %.0fs, %d skipped" % (time.time() - t0, skipped))
