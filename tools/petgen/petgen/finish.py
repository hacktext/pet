"""Finish a Kling clip for packaging: key the animal off the green, brighten /
saturate / sharpen only the animal, put it back on exact #00FF00 and encode at
CRF 16 with -tune grain, at a bitrate that keeps the fur (spec 2026-09-12 pet
image quality)."""
from __future__ import annotations

import json
import math
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

from petgen import proc
from petgen.keycheck import alpha_map
from petgen.loopcheck import probe

OUT_EDGE = 960
FPS = 24
TARGET_LUMA = 155.0          # subject mean luma after grading (0..255)
MAX_P95 = 235.0              # never push the brightest 5 % past this
SATURATION = 1.20
GAMMA_MAX = 2.5
USM_RADIUS, USM_AMOUNT, USM_THRESHOLD = 1.5, 1.2, 2
CRF = 16
GREEN = np.array([0.0, 1.0, 0.0], dtype=np.float32)
_W = np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)


def unmix(rgb: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """uint8 RGB over green -> (animal colour 0..1, alpha 0..1 with a trailing axis)."""
    a = alpha_map(rgb).astype(np.float32)[..., None] / 255.0
    px = rgb.astype(np.float32) / 255.0
    fg = (px - GREEN * (1.0 - a)) / np.maximum(a, 1e-3)
    return np.clip(fg, 0.0, 1.0), a


def lift(fg: np.ndarray, gamma: float) -> np.ndarray:
    """Gamma-brighten, then widen saturation around each pixel's own luma."""
    up = np.power(fg, 1.0 / gamma)
    y = (up @ _W)[..., None]
    return np.clip(y + (up - y) * SATURATION, 0.0, 1.0)


def _core_mean(fg: np.ndarray, core: np.ndarray, gamma: float) -> float:
    return float(((lift(fg, gamma) @ _W)[core] * 255.0).mean())


def _output_p95(fg: np.ndarray, a: np.ndarray, core: np.ndarray, gamma: float, sharpen: bool) -> float:
    """95th-percentile subject luma of what actually ships: the unsharp mask
    overshoots bright edges, so when it runs the cap is checked after it."""
    out = lift(fg, gamma)
    if sharpen:
        out = _sharpen(out, a)
    return float(np.percentile((out @ _W)[core] * 255.0, 95))


def _solve(fg: np.ndarray, a: np.ndarray, sharpen: bool) -> float:
    core = a[..., 0] >= 0.999
    if not core.any():
        raise ValueError("no opaque subject to measure")
    g = 1.0
    if _core_mean(fg, core, 1.0) < TARGET_LUMA:
        lo, hi = 1.0, GAMMA_MAX
        for _ in range(30):
            mid = (lo + hi) / 2
            lo, hi = (mid, hi) if _core_mean(fg, core, mid) < TARGET_LUMA else (lo, mid)
        g = hi
    if g > 1.0 and _output_p95(fg, a, core, g, sharpen) > MAX_P95:
        lo, hi = 1.0, g
        for _ in range(20):
            mid = (lo + hi) / 2
            lo, hi = (lo, mid) if _output_p95(fg, a, core, mid, sharpen) > MAX_P95 else (mid, hi)
        g = lo
    return math.floor(g * 1e4) / 1e4


def solve_gamma(rgb: np.ndarray) -> float:
    """The gamma that brings the opaque subject to TARGET_LUMA without the top
    5 % of the graded (sharpened) output passing MAX_P95; 1.0 when it is
    already bright enough."""
    return _solve(*unmix(rgb), sharpen=True)


def calibrate_rgba(rgba: np.ndarray) -> np.ndarray:
    """Exposure-calibrate a segmented cutout (float32 0..255 RGBA) before it is
    composited onto green: same target as the video grade, alpha untouched."""
    fg = rgba[..., :3] / 255.0
    a = rgba[..., 3:] / 255.0
    out = rgba.copy()
    out[..., :3] = lift(fg, _solve(fg, a, sharpen=False)) * 255.0
    return out


def _blur(img01: np.ndarray, radius: float) -> np.ndarray:
    mode = "L" if img01.ndim == 2 else "RGB"
    im = Image.fromarray((np.clip(img01, 0, 1) * 255.0 + 0.5).astype(np.uint8), mode)
    return np.asarray(im.filter(ImageFilter.GaussianBlur(radius)), np.float32) / 255.0


def _sharpen(fg: np.ndarray, a: np.ndarray) -> np.ndarray:
    """Unsharp mask on the animal only. The blur is taken premultiplied (colour
    x alpha, then divided by blurred alpha) so the black 'colour' unmix leaves
    in the background cannot bleed a dark halo into the fur."""
    blurred = _blur(fg * a, USM_RADIUS) / np.maximum(_blur(a[..., 0], USM_RADIUS)[..., None], 1e-3)
    diff = fg - np.clip(blurred, 0.0, 1.0)
    diff[np.abs(diff) * 255.0 < USM_THRESHOLD] = 0.0
    sharp = np.clip(fg + USM_AMOUNT * diff, 0.0, 1.0)
    return fg + (sharp - fg) * a


def grade_frame(rgb: np.ndarray, gamma: float) -> np.ndarray:
    fg, a = unmix(rgb)
    fg = _sharpen(lift(fg, gamma), a)
    out = fg * a + GREEN * (1.0 - a)
    return (np.clip(out, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)


def metrics(rgb: np.ndarray) -> tuple[float, float, float]:
    """HANDOFF section 4's numbers over the subject (every pixel that is not
    strongly green): mean luma, 95th-percentile luma, mean |laplacian|."""
    f = rgb.astype(np.float32)
    r, g, b = f[..., 0], f[..., 1], f[..., 2]
    subj = ~((g > r + 40) & (g > b + 40))
    y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    lap = np.abs(4 * y[1:-1, 1:-1] - y[:-2, 1:-1] - y[2:, 1:-1] - y[1:-1, :-2] - y[1:-1, 2:])
    return float(y[subj].mean()), float(np.percentile(y[subj], 95)), float(lap[subj[1:-1, 1:-1]].mean())


def _scale_args(video: Path) -> list[str]:
    info = probe(video)
    if info["width"] != info["height"]:
        raise ValueError(f"{video.name} is {info['width']}x{info['height']}, not square")
    if info["width"] == OUT_EDGE:
        return []
    return ["-vf", f"scale={OUT_EDGE}:{OUT_EDGE}:flags=area"]


def frame_rgb(video: Path, n: int = 30) -> np.ndarray:
    """Frame n as uint8 RGB at OUT_EDGE x OUT_EDGE."""
    vf = _scale_args(video)
    select = f"select=eq(n\\,{n})"
    vf = ["-vf", f"{select},{vf[1]}"] if vf else ["-vf", select]
    raw = proc.run(["ffmpeg", "-v", "error", "-i", str(video), *vf, "-frames:v", "1",
                   "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], check=True, capture_output=True).stdout
    return np.frombuffer(raw, np.uint8).reshape(OUT_EDGE, OUT_EDGE, 3).copy()


def finish_clip(src: Path, dst: Path, gamma: float) -> int:
    """Grade every frame of src into dst (960x960, 24 fps, libx264 CRF 16).
    Writes via a temp file so a failure never leaves a half clip behind."""
    vf = _scale_args(src)
    tmp = dst.with_name(dst.stem + ".partial.mp4")
    dec = proc.popen(["ffmpeg", "-v", "error", "-i", str(src), *vf, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                     stdout=subprocess.PIPE)
    enc = proc.popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
                     "-s", f"{OUT_EDGE}x{OUT_EDGE}", "-r", str(FPS), "-i", "-",
                     "-c:v", "libx264", "-preset", "slow", "-crf", str(CRF), "-tune", "grain", "-pix_fmt", "yuv420p",
                     "-movflags", "+faststart", str(tmp)], stdin=subprocess.PIPE)
    size = OUT_EDGE * OUT_EDGE * 3
    frames = 0
    try:
        while True:
            buf = dec.stdout.read(size)
            if len(buf) < size:
                break
            rgb = np.frombuffer(buf, np.uint8).reshape(OUT_EDGE, OUT_EDGE, 3)
            enc.stdin.write(grade_frame(rgb, gamma).tobytes())
            frames += 1
    finally:
        enc.stdin.close()
        enc.wait()
        dec.stdout.close()
        dec.wait()
    if dec.returncode or enc.returncode or frames == 0:
        tmp.unlink(missing_ok=True)
        raise RuntimeError(f"finish failed for {src.name}: decoder {dec.returncode}, encoder {enc.returncode}, "
                           f"{frames} frames")
    tmp.replace(dst)
    return frames


def pet_gamma(workdir: Path, override: float | None = None, builtin: float | None = None) -> float:
    """One grade per pet so every action looks alike: --gamma wins, then this
    folder's saved grade.json, then [builtin] -- the grade carried by
    prompts.PETS for a pet solve_gamma cannot reach, because it only ever
    brightens -- else solve it from this folder's stand.mp4 frame 30 and save
    that, so the pet's other actions and a later re-finish reuse it."""
    if override is not None:
        return override
    grade = workdir / "grade.json"
    if grade.exists():
        return float(json.loads(grade.read_text(encoding="utf-8"))["gamma"])
    # Returned, never saved: cmd_finish passes it on every call, so writing it
    # would only let a stale grade.json outlive a later recalibration of PETS.
    if builtin is not None:
        return builtin
    stand = workdir / "stand.mp4"
    if not stand.exists():
        raise FileNotFoundError(f"no {stand.name} in {workdir} to derive the pet's grade from")
    g = solve_gamma(frame_rgb(stand, 30))
    tmp = grade.with_name(grade.name + ".partial")
    tmp.write_text(json.dumps({"gamma": g, "from": "stand.mp4 frame 30"}) + "\n", encoding="utf-8")
    tmp.replace(grade)
    return g
