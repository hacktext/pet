import numpy as np

from petgen.keycheck import BLOB_CORE_MAX, Score, alpha_map, blob_core_mask, floating_mask


def rgb(color, h=4, w=4):
    return np.full((h, w, 3), color, dtype=np.uint8)


def test_pure_green_is_fully_transparent():
    assert (alpha_map(rgb((0, 255, 0))) == 0).all()


def test_red_is_fully_opaque():
    assert (alpha_map(rgb((255, 0, 0))) == 255).all()


def test_greenish_grey_is_partial():
    a = int(alpha_map(rgb((60, 150, 60)))[0, 0])
    assert 0 < a < 255


def test_isolated_blob_floats_and_keeps_a_core():
    a = np.zeros((40, 40), np.uint8)
    a[10:15, 10:15] = 128
    fl = floating_mask(a)
    assert fl.sum() == 25
    assert blob_core_mask(fl).sum() == 9


def test_thin_fringe_line_floats_but_has_no_core():
    a = np.zeros((40, 40), np.uint8)
    a[20, 5:25] = 128
    fl = floating_mask(a)
    assert fl.sum() == 20
    assert blob_core_mask(fl).sum() == 0


def test_partial_pixel_next_to_opaque_is_not_floating():
    a = np.zeros((40, 40), np.uint8)
    a[30:36, 30:36] = 255
    a[30, 28] = 128
    assert not floating_mask(a)[30, 28]


def test_pass_threshold_is_strict():
    assert Score(floating=5000, blob_core=BLOB_CORE_MAX - 1).passed
    assert not Score(floating=0, blob_core=BLOB_CORE_MAX).passed
