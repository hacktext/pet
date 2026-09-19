"""Props (bowl, ball) pasted in front of the animal's front paws on the front
still, so a feed / play clip starts and ends with the prop already there.
Spike 2026-09-19: a prop the model makes appear or vanish dissolves into the
green screen and keys as a half-transparent ghost."""
from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image

from petgen.compose import EDGE, EdgeError, on_green, place, segment
from petgen.edges import edge_touches, subject_bbox

PROP_REFS = {"front-bowl": "bowl", "front-ball": "ball"}  # reference stem -> prop
PROP_WIDTH = {"bowl": 0.35, "ball": 0.14}                 # of the animal's height
HEAD_BAND = 0.20   # top share of the animal: the head, and maybe a raised tail
FOOT_BAND = 0.04   # bottom share: the paws, front ones lowest (nearest the camera)
DROP = 0.03        # prop bottom below the paws: it stands in front of them
MARGIN = 8


def _runs(occupied: np.ndarray) -> list[tuple[int, int]]:
    """[start, end) of every run of True in a 1-D bool array."""
    edges = np.flatnonzero(np.diff(np.concatenate(([0], occupied.astype(np.int8), [0]))))
    return list(zip(edges[::2].tolist(), edges[1::2].tolist()))


def _head_x(alpha: np.ndarray, y0: int, y1: int) -> float:
    """Column centre of the head: a front-facing animal's front legs are below
    it. In the top band the head and a raised tail are separate column runs;
    the head is the run above the feet (ragdoll 2026-09-19: its fluffy tail
    was as high as its ears and bigger than its head)."""
    h = y1 - y0
    top = alpha[y0:y0 + max(1, round(HEAD_BAND * h))] > 10
    feet_x = float(np.nonzero(alpha[y1 - max(1, round(FOOT_BAND * h)):y1] > 10)[1].mean())
    s, e = min(_runs(top.any(0)), key=lambda r: abs((r[0] + r[1] - 1) / 2 - feet_x))
    return float(np.nonzero(top[:, s:e])[1].mean()) + s


def prop_box(alpha: np.ndarray, kind: str, prop_w: int, prop_h: int) -> tuple[int, int, int, int]:
    """(left, top, w, h) of the prop on the canvas: under the head, just below
    the paws, shrunk if need be and clamped inside the canvas."""
    _, _, y0, y1 = subject_bbox(alpha)
    h = y1 - y0
    cx = _head_x(alpha, y0, y1)
    w = max(1, round(PROP_WIDTH[kind] * h))
    ph = max(1, round(w * prop_h / prop_w))
    limit = EDGE - 2 * MARGIN
    if w > limit or ph > limit:
        f = limit / max(w, ph)
        w, ph = max(1, int(w * f)), max(1, int(ph * f))
    bottom = min(round(y1 + DROP * h), EDGE - MARGIN)
    top = max(bottom - ph, MARGIN)
    left = min(max(round(cx - w / 2), MARGIN), EDGE - MARGIN - w)
    return left, top, w, ph


def paste(canvas: np.ndarray, prop: Image.Image, box: tuple[int, int, int, int]) -> np.ndarray:
    """The prop over the animal (straight-alpha 'over'); returns a new canvas."""
    left, top, w, h = box
    p = np.asarray(prop.convert("RGBA").resize((w, h), Image.LANCZOS), dtype=np.float32)
    out = canvas.copy()
    region = out[top:top + h, left:left + w]
    pa, ba = p[..., 3:] / 255.0, region[..., 3:] / 255.0
    oa = pa + ba * (1.0 - pa)
    region[..., :3] = (p[..., :3] * pa + region[..., :3] * ba * (1.0 - pa)) / np.maximum(oa, 1e-6)
    region[..., 3:] = oa * 255.0
    return out


def compose_prop(cutout: Path, prop_cutout: Path, kind: str, out: Path) -> Path:
    """The front still with the prop in front of its paws, on exact green. The
    animal is placed exactly as compose() placed it, so only the prop differs."""
    canvas = place(Image.open(cutout))
    prop = Image.open(prop_cutout).convert("RGBA")
    box = prop_box(np.clip(canvas[..., 3], 0, 255).astype(np.uint8), kind, prop.width, prop.height)
    return on_green(paste(canvas, prop, box), out)


def cut_prop(src: Path, out: Path) -> Path:
    """Segment a generated prop photo and crop it to its alpha bounding box."""
    arr = segment(src)
    alpha = arr[..., 3].astype(np.uint8)
    sides = edge_touches(alpha)
    if sides:
        raise EdgeError(sides)
    x0, x1, y0, y1 = subject_bbox(alpha)
    Image.fromarray(np.clip(arr[y0:y1, x0:x1] + 0.5, 0, 255).astype(np.uint8), "RGBA").save(out)
    return out
