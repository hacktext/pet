"""Did the frame cut the subject off? Judged on the segmentation alpha --
a colour heuristic reads any mid-grey backdrop as foreground (spike lesson)."""
from __future__ import annotations

import numpy as np


def subject_bbox(alpha: np.ndarray, threshold: int = 10) -> tuple[int, int, int, int]:
    ys, xs = np.nonzero(alpha > threshold)
    if len(xs) == 0:
        raise ValueError("segmentation found no subject")
    return int(xs.min()), int(xs.max()) + 1, int(ys.min()), int(ys.max()) + 1


def edge_touches(alpha: np.ndarray, *, threshold: int = 10, margin: int = 2) -> list[str]:
    x0, x1, y0, y1 = subject_bbox(alpha, threshold)
    h, w = alpha.shape
    hits = [("left", x0 <= margin), ("top", y0 <= margin),
            ("right", x1 >= w - margin), ("bottom", y1 >= h - margin)]
    return [side for side, hit in hits if hit]
