import numpy as np
import pytest

from petgen.edges import edge_touches, subject_bbox


def alpha_with(y0, y1, x0, x1, h=100, w=100):
    a = np.zeros((h, w), np.uint8)
    a[y0:y1, x0:x1] = 255
    return a


def test_bbox_is_half_open():
    assert subject_bbox(alpha_with(10, 20, 30, 40)) == (30, 40, 10, 20)


def test_centered_subject_touches_nothing():
    assert edge_touches(alpha_with(10, 90, 10, 90)) == []


def test_subject_on_left_edge():
    assert edge_touches(alpha_with(10, 90, 0, 50)) == ["left"]


def test_margin_counts_as_touching():
    assert edge_touches(alpha_with(10, 90, 2, 50), margin=2) == ["left"]
    assert edge_touches(alpha_with(10, 90, 3, 50), margin=2) == []


def test_bottom_right_corner():
    assert edge_touches(alpha_with(50, 100, 50, 100)) == ["right", "bottom"]


def test_faint_pixels_below_threshold_are_ignored():
    a = alpha_with(40, 60, 40, 60)
    a[0, :] = 5
    assert edge_touches(a) == []


def test_empty_alpha_raises():
    with pytest.raises(ValueError):
        edge_touches(np.zeros((10, 10), np.uint8))
