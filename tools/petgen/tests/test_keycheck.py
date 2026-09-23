import numpy as np

from petgen.keycheck import BLOB_CORE_MAX, FRAME_BLOB_MAX, Score, alpha_map, blob_core_mask, floating_mask


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


import subprocess

from petgen.keycheck import frame_scores


def test_frame_scores_catch_a_ghost_in_the_middle_of_a_clip(tmp_path):
    # 13 frames: an opaque red square throughout; frame 6 also carries a
    # half-keyed olive patch (100,160,0 keys to alpha ~115) away from it --
    # the dissolving-bowl ghost of the 2026-09-19 spike.
    frames = np.zeros((13, 240, 240, 3), np.uint8)
    frames[...] = (0, 255, 0)
    frames[:, 80:160, 80:160] = (220, 40, 40)
    frames[6, 10:50, 170:230] = (100, 160, 0)
    video = tmp_path / "ghost.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "240x240", "-r", "24",
                    "-i", "-", "-c:v", "libx264", "-crf", "12", "-pix_fmt", "yuv420p", str(video)],
                   input=frames.tobytes(), check=True)
    scores = frame_scores(video, step=6)
    assert len(scores) == 3                     # frames 0, 6, 12
    assert scores[1] >= FRAME_BLOB_MAX          # a whole translucent object, not a blurred tail
    assert scores[0] < 50 and scores[2] < 50
