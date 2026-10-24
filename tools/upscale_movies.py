#!/usr/bin/env python3
"""Upscale the game's Bink movies with Real-ESRGAN into HD replacements.

Each movies/<name>.bik becomes movies_hd/<name>.mkv: every frame upscaled 4x
by the realesrgan-x4plus model (realesrgan-ncnn-vulkan, on the GPU), scaled
with Lanczos to OUT_W x OUT_H, encoded as 10-bit AV1 (SVT-AV1), with the
original audio as FLAC. The port's BinkOpen plays the .mkv in place of the
.bik when it exists (port/src/win32/bink.odin, docs/hle.md §4).

Frames go through PNG files in chunks of CHUNK, which bounds the scratch
space to one chunk of 4x frames. A movie whose .mkv exists is skipped, so an
interrupted run resumes at the movie it was on.

Usage: upscale_movies.py <game dir> <realesrgan-ncnn-vulkan> [name ...]
"""

import json
import pathlib
import shutil
import subprocess
import sys
import time

# 4x the 640x480 back buffer: the largest render scale (docs/rendering.md §1).
OUT_W, OUT_H = 2560, 1920
CHUNK = 500
MODEL = "realesrgan-x4plus"
ENCODE = ["-c:v", "libsvtav1", "-preset", "5", "-crf", "20",
          "-pix_fmt", "yuv420p10le", "-color_primaries", "bt709",
          "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv"]


def run(cmd, cwd=None):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, cwd=cwd)


def probe(bik):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries",
         "stream=codec_type,width,height,r_frame_rate", "-of", "json", str(bik)],
        check=True, capture_output=True, text=True).stdout
    streams = json.loads(out)["streams"]
    video = [s for s in streams if s["codec_type"] == "video"]
    assert len(video) == 1, f"{bik}: {len(video)} video streams"
    has_audio = any(s["codec_type"] == "audio" for s in streams)
    return video[0]["r_frame_rate"], has_audio


def encode_chunk(src, fps, first, seg):
    run(["ffmpeg", "-v", "error", "-y", "-framerate", fps, "-start_number",
         str(first), "-i", str(src / "%06d.png"),
         "-vf", f"scale={OUT_W}:{OUT_H}:flags=lanczos:out_color_matrix=bt709",
         *ENCODE, str(seg)])


def upscale(bik, out, esr):
    fps, has_audio = probe(bik)
    work = out.parent / ".work" / bik.stem
    if work.exists():
        shutil.rmtree(work)
    frames, up = work / "frames", work / "up"
    frames.mkdir(parents=True)
    run(["ffmpeg", "-v", "error", "-i", str(bik), "-map", "0:v:0",
         "-fps_mode", "passthrough", "-start_number", "0",
         str(frames / "%06d.png")])
    n = len(list(frames.iterdir()))
    assert n > 0, f"{bik}: no frames"
    segs = []
    t0 = time.monotonic()
    for first in range(0, n, CHUNK):
        chunk = work / "chunk"
        chunk.mkdir()
        for k in range(first, min(first + CHUNK, n)):
            (frames / f"{k:06d}.png").rename(chunk / f"{k:06d}.png")
        up.mkdir()
        run([str(esr), "-i", str(chunk), "-o", str(up), "-n", MODEL,
             "-s", "4", "-f", "png"], cwd=esr.parent)  # models/ is found from cwd
        seg = work / f"seg{first // CHUNK:04d}.mkv"
        encode_chunk(up, fps, first, seg)
        segs.append(seg)
        shutil.rmtree(chunk)
        shutil.rmtree(up)
        done = min(first + CHUNK, n)
        rate = done / (time.monotonic() - t0)
        print(f"  {bik.stem}: {done}/{n} frames, {rate:.2f} fps", flush=True)
    listing = work / "segs.txt"
    listing.write_text("".join(f"file '{s}'\n" for s in segs))
    tmp = out.with_suffix(".tmp.mkv")
    cmd = ["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0",
           "-i", str(listing)]
    if has_audio:
        cmd += ["-i", str(bik), "-map", "0:v", "-map", "1:a:0", "-c:a", "flac"]
    run(cmd + ["-c:v", "copy", str(tmp)])
    tmp.rename(out)
    shutil.rmtree(work)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    game = pathlib.Path(sys.argv[1]).resolve()
    esr = pathlib.Path(sys.argv[2]).resolve()
    names = {a.lower() for a in sys.argv[3:]}
    out_dir = game / "movies_hd"
    out_dir.mkdir(exist_ok=True)
    biks = sorted(p for p in (game / "movies").iterdir()
                  if p.suffix.lower() == ".bik"
                  and (not names or p.stem.lower() in names))
    for i, bik in enumerate(biks):
        out = out_dir / (bik.stem + ".mkv")
        if out.exists():
            continue
        print(f"[{i + 1}/{len(biks)}] {bik.name}", flush=True)
        upscale(bik, out, esr)


if __name__ == "__main__":
    main()
