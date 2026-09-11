from PIL import Image

from petgen.package import COVER_MAX, make_cover, pet_json


def test_pet_json_matches_spec_schema():
    j = pet_json("ragdoll")
    assert j == {
        "schema": 1, "id": "builtin-ragdoll", "name": "布偶猫", "species": "cat",
        "origin": "builtin", "blurb": "蓝眼睛的小仙女，安静又粘人", "cover": "cover.png",
        "actions": ["stand", "walk", "sleep", "lick_paw", "act_cute"],
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
