"""Segment the animal off its neutral backdrop and composite it onto exact
#00FF00. Spike lesson: generating straight on green paints green bounce light
onto the fur, which pet_matte then keys as semi-transparent."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

from petgen.edges import edge_touches, subject_bbox

MODEL = "birefnet-general-lite"
EDGE = 1024
FILL = 0.78
KEY = np.array([0, 255, 0], dtype=np.float32)
_sessions: dict = {}


class EdgeError(Exception):
    def __init__(self, sides: list[str]):
        super().__init__(f"subject touches {sides}: the frame cut it off")
        self.sides = sides


@dataclass(frozen=True)
class ComposeResult:
    green: Path
    cutout: Path
    bbox: tuple[int, int, int, int]


def _segment(src: Path) -> np.ndarray:
    from rembg import new_session, remove  # heavy import, only when composing

    if MODEL not in _sessions:
        _sessions[MODEL] = new_session(MODEL)
    # alpha matting re-solves the mask's unknown band as a soft matte: it keeps
    # wispy tail fur the plain segmenter drops (spike: lite+matting beat the
    # full 973 MB model without matting).
    rgba = remove(Image.open(src).convert("RGB"), session=_sessions[MODEL],
                  alpha_matting=True, alpha_matting_foreground_threshold=240,
                  alpha_matting_background_threshold=10, alpha_matting_erode_size=10)
    return np.asarray(rgba, dtype=np.float32)


def compose(src: Path, out_dir: Path, stem: str, calibrate: bool = False) -> ComposeResult:
    arr = _segment(src)
    alpha_u8 = arr[..., 3].astype(np.uint8)
    sides = edge_touches(alpha_u8)
    if sides:
        raise EdgeError(sides)
    x0, x1, y0, y1 = subject_bbox(alpha_u8)
    out_dir.mkdir(parents=True, exist_ok=True)

    region = arr[y0:y1, x0:x1]
    if calibrate:
        from petgen.finish import calibrate_rgba  # same exposure target as the video grade
        region = calibrate_rgba(region)
    cut = Image.fromarray(np.clip(region + 0.5, 0, 255).astype(np.uint8), "RGBA")
    cutout = out_dir / f"{stem}-cutout.png"
    cut.save(cutout)

    scale = FILL * EDGE / max(x1 - x0, y1 - y0)
    cut = cut.resize((round((x1 - x0) * scale), round((y1 - y0) * scale)), Image.LANCZOS)
    canvas = np.zeros((EDGE, EDGE, 4), dtype=np.float32)
    ox, oy = (EDGE - cut.width) // 2, (EDGE - cut.height) // 2
    canvas[oy:oy + cut.height, ox:ox + cut.width] = np.asarray(cut, dtype=np.float32)
    a = canvas[..., 3:] / 255.0
    # Soft fur edges blend into key green, exactly like a real screen edge.
    out = canvas[..., :3] * a + KEY * (1.0 - a)
    green = out_dir / f"{stem}-green.png"
    Image.fromarray(np.clip(out + 0.5, 0, 255).astype(np.uint8), "RGB").save(green)
    return ComposeResult(green, cutout, (x0, x1, y0, y1))
