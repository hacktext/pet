"""pet_matte's chroma key replicated with numpy, and the reference-still gate.

Mirrors native/matte_core/src/chroma_key.cpp with its KeyParams defaults.
Scores are taken at SCORE_EDGE x SCORE_EDGE so numbers compare across sizes.
"""
from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

from petgen.loopcheck import probe

KEY_CB, KEY_CR, INNER_T, OUTER_T = -0.331, -0.419, 0.28, 0.45
SCORE_EDGE = 800
BLOB_CORE_MAX = 200  # for a still (reference image, first / last frame)
# Mid-clip frames are judged loosely: a moving tail motion-blurs into the green
# and keys as a faint ghost, and the competitor's shipped clips do it too
# (measured 2026-09-23: their worst frames are play 665, sleep 995, stand 507).
# What this still catches is the real defect -- a prop dissolving in or out, or
# a tail smearing across half the clip (measured 2529-8072).
FRAME_BLOB_MAX = 1000
FLOATING_REF = 911   # competitor reference frame; context only


def alpha_map(rgb: np.ndarray) -> np.ndarray:
    """uint8 HxWx3 RGB -> uint8 HxW alpha, as pet_matte would key it."""
    f = rgb.astype(np.float32) / 255.0
    r, g, b = f[..., 0], f[..., 1], f[..., 2]
    cb = -0.168736 * r - 0.331264 * g + 0.5 * b
    cr = 0.5 * r - 0.418688 * g - 0.081312 * b
    d = np.sqrt((cb - KEY_CB) ** 2 + (cr - KEY_CR) ** 2)
    a = np.clip((d - INNER_T) / (OUTER_T - INNER_T), 0.0, 1.0)
    return (a * 255.0 + 0.5).astype(np.uint8)


def _shift(m: np.ndarray, dy: int, dx: int) -> np.ndarray:
    """out[y, x] = m[y + dy, x + dx]; zero where that falls outside m."""
    out = np.zeros_like(m)
    h, w = m.shape
    src_y, dst_y = slice(max(dy, 0), h + min(dy, 0)), slice(max(-dy, 0), h + min(-dy, 0))
    src_x, dst_x = slice(max(dx, 0), w + min(dx, 0)), slice(max(-dx, 0), w + min(-dx, 0))
    out[dst_y, dst_x] = m[src_y, src_x]
    return out


def floating_mask(alpha: np.ndarray) -> np.ndarray:
    """Partial-alpha pixels with no opaque pixel on the {-2,0,2}^2 grid around
    them: shadow/spill leftovers, and also wispy fur fringe."""
    partial = (alpha > 0) & (alpha < 255)
    opaque = alpha == 255
    near = np.zeros_like(opaque)
    for dy in (-2, 0, 2):
        for dx in (-2, 0, 2):
            near |= _shift(opaque, dy, dx)
    m = partial & ~near
    m[:2, :] = False
    m[-2:, :] = False
    m[:, :2] = False
    m[:, -2:] = False
    return m


def blob_core_mask(floating: np.ndarray) -> np.ndarray:
    """3x3 erosion of the floating mask: 1-2 px fur fringe disappears,
    shadow and spill blobs keep a core."""
    core = floating.copy()
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            core &= _shift(floating, dy, dx)
    return core


@dataclass(frozen=True)
class Score:
    floating: int
    blob_core: int

    @property
    def passed(self) -> bool:
        return self.blob_core < BLOB_CORE_MAX


def score_rgb(rgb: np.ndarray) -> Score:
    fl = floating_mask(alpha_map(rgb))
    return Score(int(fl.sum()), int(blob_core_mask(fl).sum()))


def score_file(path: Path) -> Score:
    im = Image.open(path).convert("RGB").resize((SCORE_EDGE, SCORE_EDGE), Image.BILINEAR)
    return score_rgb(np.asarray(im))


def frame_scores(video: Path, step: int = 6) -> list[int]:
    """blob_core of every step-th frame, scored exactly like score_file. First
    and last frames are not enough: a prop dissolving mid-clip keys as a ghost
    (spike 2026-09-19)."""
    info = probe(video)
    w, h = info["width"], info["height"]
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(video), "-vf", f"select=not(mod(n\\,{step}))",
                          "-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                         check=True, capture_output=True).stdout
    frames = np.frombuffer(raw, np.uint8).reshape(-1, h, w, 3)
    return [score_rgb(np.asarray(Image.fromarray(f).resize((SCORE_EDGE, SCORE_EDGE), Image.BILINEAR))).blob_core
            for f in frames]
