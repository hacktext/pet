import json
import subprocess

import numpy as np
import pytest

from petgen.finish import (MAX_P95, TARGET_LUMA, calibrate_rgba, finish_clip, frame_rgb, grade_frame, metrics,
                           pet_gamma, solve_gamma)
from petgen.keycheck import alpha_map
from petgen.loopcheck import probe
from petgen.prompts import PETS


def _frame(color, size=200, lo=50, hi=150):
    """Exact-green frame with an opaque square of `color`."""
    f = np.zeros((size, size, 3), np.uint8)
    f[...] = (0, 255, 0)
    f[lo:hi, lo:hi] = color
    return f


def test_green_background_stays_exact_green():
    out = grade_frame(_frame((150, 110, 80)), gamma=1.6)
    assert (out[:30, :30] == [0, 255, 0]).all()
    assert (out[-30:, -30:] == [0, 255, 0]).all()


def test_dark_subject_is_lifted_to_the_target_luma():
    f = _frame((150, 110, 80))
    g = solve_gamma(f)
    assert g > 1.0
    luma, _, _ = metrics(grade_frame(f, g))
    assert abs(luma - TARGET_LUMA) < 4


def test_bright_subject_is_left_alone():
    assert solve_gamma(_frame((235, 225, 210))) == 1.0


def test_highlights_cap_the_lift():
    f = _frame((120, 90, 60))
    f[60:80, 60:140] = (228, 228, 228)  # a bright patch, 16 % of the subject
    g = solve_gamma(f)
    assert g < solve_gamma(_frame((120, 90, 60)))  # the patch held the lift back
    _, p95, _ = metrics(grade_frame(f, g))
    assert p95 <= MAX_P95 + 1


def test_calibrate_rgba_brightens_the_subject_and_keeps_alpha():
    rgba = np.zeros((100, 100, 4), np.float32)
    rgba[20:80, 20:80] = (150, 110, 80, 255)
    out = calibrate_rgba(rgba)
    assert out.shape == rgba.shape
    assert (out[..., 3] == rgba[..., 3]).all()
    y = out[20:80, 20:80, :3] @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    assert abs(float(y.mean()) - TARGET_LUMA) < 4


def test_metrics_ignores_the_green_screen():
    luma, p95, sharp = metrics(_frame((100, 100, 100)))
    assert abs(luma - 100) < 0.5 and abs(p95 - 100) < 0.5
    assert sharp < 4  # a flat square: only its outline has any laplacian (~3.3 here)


def test_finish_clip_downscales_to_960_and_keeps_every_frame(tmp_path):
    src = tmp_path / "src.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-y",
                    "-f", "lavfi", "-i", "color=c=0x00FF00:s=1280x1280:r=24",
                    "-f", "lavfi", "-i", "color=c=0x966E50:s=400x400:r=24",
                    "-filter_complex", "[0:v][1:v]overlay=440:440", "-frames:v", "121",
                    "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", str(src)], check=True)
    dst = tmp_path / "out.mp4"
    assert finish_clip(src, dst, gamma=1.5) == 121
    assert probe(dst) == {"width": 960, "height": 960, "fps": "24/1", "frames": 121}
    rgb = frame_rgb(dst, 30)
    assert (alpha_map(rgb[:60, :60]) == 0).all()   # background still keys out completely
    assert metrics(rgb)[0] > metrics(frame_rgb(src, 30))[0] + 20  # the square got brighter


def test_finish_clip_rejects_a_non_square_source(tmp_path):
    src = tmp_path / "wide.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "color=c=0x00FF00:s=640x360:r=24",
                    "-frames:v", "24", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", str(src)],
                   check=True)
    with pytest.raises(ValueError):
        finish_clip(src, tmp_path / "out.mp4", gamma=1.2)
    assert not (tmp_path / "out.mp4").exists()


def test_pet_gamma_is_solved_once_and_reused(tmp_path):
    stand = tmp_path / "stand.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-y",
                    "-f", "lavfi", "-i", "color=c=0x00FF00:s=480x480:r=24",
                    "-f", "lavfi", "-i", "color=c=0x966E50:s=200x200:r=24",
                    "-filter_complex", "[0:v][1:v]overlay=140:140", "-frames:v", "40",
                    "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", str(stand)], check=True)
    g = pet_gamma(tmp_path)
    assert g > 1.0
    assert (tmp_path / "grade.json").exists()
    stand.unlink()                        # every later action reuses the saved grade
    assert pet_gamma(tmp_path) == g
    assert pet_gamma(tmp_path, override=1.3) == 1.3


def test_builtin_grade_is_used_when_the_solver_would_only_brighten(tmp_path):
    # ragdoll's reference is already bright (subject luma 172) and solve_gamma
    # can only wash it out further, so its grade is hand-set. 0.88 brought its
    # stand from luma 174 to 165.2 (2026-09-23); changing it is a
    # recalibration, and this line is where it gets recorded.
    assert PETS["ragdoll"]["grade"] == 0.88
    assert "grade" not in PETS["gold"]
    g = pet_gamma(tmp_path, builtin=PETS["ragdoll"]["grade"])
    assert g == 0.88
    # Not written out: cmd_finish passes it every time, and a saved copy would
    # outlive a later recalibration.
    assert not (tmp_path / "grade.json").exists()
    assert pet_gamma(tmp_path, override=1.3, builtin=g) == 1.3   # --gamma still wins


def test_a_saved_grade_wins_over_the_builtin_one(tmp_path):
    (tmp_path / "grade.json").write_text(json.dumps({"gamma": 1.05, "from": "hand"}), encoding="utf-8")
    assert pet_gamma(tmp_path, builtin=0.88) == 1.05
