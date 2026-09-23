import subprocess

import numpy as np
from PIL import Image

from petgen.package import COVER_MAX, make_cover, pet_json, walk_facing


def test_pet_json_matches_spec_schema():
    j = pet_json("ragdoll", "left")
    assert j == {
        "schema": 1, "id": "builtin-ragdoll", "name": "布偶猫", "species": "cat",
        "origin": "builtin", "blurb": "蓝眼睛的小仙女，安静又粘人", "cover": "cover.png",
        "actions": ["stand", "walk", "sleep", "feed", "play", "lick_paw", "act_cute"],
        "walkFacing": "left",
    }


def test_cover_is_bounded_and_keeps_a_transparent_margin():
    cut = Image.new("RGBA", (1200, 600), (200, 120, 60, 255))
    cover = make_cover(cut)
    assert max(cover.size) == COVER_MAX
    assert cover.mode == "RGBA"
    assert cover.getpixel((0, 0))[3] == 0                         # margin is transparent
    assert cover.getpixel((cover.width // 2, cover.height // 2))[3] == 255


def test_small_cutout_is_not_upscaled_past_its_padding():
    cover = make_cover(Image.new("RGBA", (100, 50), (0, 0, 0, 255)))
    assert max(cover.size) <= COVER_MAX and max(cover.size) >= 100


def test_walk_facing_finds_the_side_the_head_is_on(tmp_path):
    for head_left, want in [(True, "left"), (False, "right")]:
        f = np.zeros((24, 240, 240, 3), np.uint8)
        f[...] = (0, 255, 0)
        f[:, 120:200, 40:200] = (200, 150, 100)                      # body
        cols = slice(40, 90) if head_left else slice(150, 200)
        f[:, 60:120, cols] = (200, 150, 100)                         # head, above one end of the body
        v = tmp_path / f"walk-{want}.mp4"
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "240x240",
                        "-r", "24", "-i", "-", "-c:v", "libx264", "-crf", "12", "-pix_fmt", "yuv420p", str(v)],
                       input=f.tobytes(), check=True)
        assert walk_facing(v) == want
