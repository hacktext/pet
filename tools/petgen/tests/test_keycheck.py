import subprocess

import numpy as np

from petgen.keycheck import (BLOB_CORE_MAX, FRAME_BLOB_MAX, Score, alpha_map, blob_core_mask, floating_mask,
                             frame_scores)


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


def _clip(path, frames):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "240x240", "-r", "24",
                    "-i", "-", "-c:v", "libx264", "-crf", "12", "-pix_fmt", "yuv420p", str(path)],
                   input=frames.tobytes(), check=True)
    return path


def _green(n=13):
    frames = np.zeros((n, 240, 240, 3), np.uint8)
    frames[...] = (0, 255, 0)
    frames[:, 80:160, 80:160] = (220, 40, 40)   # the opaque subject
    return frames


def test_frame_scores_catch_a_ghost_in_the_middle_of_a_clip(tmp_path):
    # 13 frames; frame 6 also carries a half-keyed olive patch (100,160,0 keys
    # to alpha ~115) away from the subject -- the dissolving-bowl ghost of the
    # 2026-09-19 spike, a whole translucent object rather than a blurred edge.
    frames = _green()
    frames[6, 10:50, 170:230] = (100, 160, 0)
    scores = frame_scores(_clip(tmp_path / "ghost.mp4", frames), step=6)
    assert len(scores) == 3                     # frames 0, 6, 12
    assert scores[1] >= FRAME_BLOB_MAX
    assert scores[0] < 50 and scores[2] < 50


def test_the_mid_clip_threshold_brackets_a_blurred_tail_and_a_heavier_blob(tmp_path):
    # The calibration of 2026-09-23: mid-clip frames allow what a still may
    # not, because a fast-moving tail motion-blurs into the green and the
    # competitor's own shipped clips score that way too (their worst frames:
    # stand 507, play 665, sleep 995). These two patches bracket the
    # threshold -- 11x11 scores 899, about their worst, and must pass; 12x12
    # scores 1295 and must not -- so moving FRAME_BLOB_MAX in either
    # direction fails here, including back to the still's 200.
    frames = _green()
    frames[6, 20:31, 180:191] = (100, 160, 0)
    tail = frame_scores(_clip(tmp_path / "tail.mp4", frames), step=6)
    frames = _green()
    frames[6, 20:32, 180:192] = (100, 160, 0)
    heavier = frame_scores(_clip(tmp_path / "heavier.mp4", frames), step=6)
    assert tail[1] < FRAME_BLOB_MAX <= heavier[1]
    assert not Score(floating=0, blob_core=tail[1]).passed    # a still would still be rejected
    assert tail[0] < 50 and tail[2] < 50
