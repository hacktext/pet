import numpy as np
from PIL import Image

from petgen.compose import EDGE, on_green, place
from petgen.edges import subject_bbox
from petgen.prompts import REF_POSE_FOR_ACTION
from petgen.props import PROP_REFS, compose_prop, paste, prop_box


def _animal():
    """1024 canvas alpha: a head block on top of a wider body; height 800."""
    a = np.zeros((EDGE, EDGE), np.uint8)
    a[100:300, 200:401] = 255   # head, columns 200..400 -> centre 300
    a[300:900, 200:800] = 255   # body
    return a


def test_every_prop_reference_is_used_by_an_action():
    assert set(PROP_REFS) <= set(REF_POSE_FOR_ACTION.values())


def test_bowl_sits_under_the_head_in_front_of_the_paws():
    # H = 800: width 0.35*H = 280, height 280*100/200 = 140, bottom 900 + 0.03*H = 924, centred on x = 300
    assert prop_box(_animal(), "bowl", 200, 100) == (160, 784, 280, 140)


def test_ball_is_smaller():
    # width 0.14*800 = 112, square prop -> 112 high, left 300 - 56 = 244, top 924 - 112 = 812
    assert prop_box(_animal(), "ball", 100, 100) == (244, 812, 112, 112)


def test_a_raised_tail_barely_moves_the_prop():
    a = _animal()
    a[120:160, 780:800] = 255   # tail tip inside the top band
    left, _, w, _ = prop_box(a, "bowl", 200, 100)
    assert abs(left + w / 2 - 300) < 15


def test_a_big_raised_tail_does_not_steal_the_prop():
    # ragdoll 2026-09-19: a fluffy tail as high as the ears and bigger than the
    # head in the top band pulled the bowl under the belly.
    a = np.zeros((EDGE, EDGE), np.uint8)
    a[150:350, 200:401] = 255    # head, centre 300
    a[100:500, 560:800] = 255    # tail: taller and wider, reaching above the ears
    a[350:880, 200:800] = 255    # body
    a[880:900, 220:380] = 255    # front paws: the lowest pixels, nearest the camera
    assert prop_box(a, "bowl", 200, 100)[0] == 160   # centred on the head: 300 - 280 / 2


def test_an_oversized_prop_is_shrunk_to_fit_the_canvas():
    left, top, w, h = prop_box(_animal(), "bowl", 10, 1000)   # absurdly tall prop
    assert w >= 1 and h >= 1
    assert left >= 8 and top >= 8 and left + w <= EDGE - 8 and top + h <= EDGE - 8


def test_prop_is_kept_on_the_canvas():
    a = np.zeros((EDGE, EDGE), np.uint8)
    a[710:1010, 0:61] = 255    # H = 300 at the bottom-left corner
    left, top, w, h = prop_box(a, "bowl", 100, 100)
    assert (left, w, h) == (8, 105, 105)
    assert top + h == EDGE - 8


def test_paste_puts_the_prop_in_front_and_keeps_the_rest():
    canvas = np.zeros((20, 20, 4), np.float32)
    canvas[5:15, 5:15] = (200, 150, 100, 255)
    prop = np.zeros((4, 4, 4), np.uint8)
    prop[:, :2] = (255, 0, 0, 255)       # left half opaque red, right half clear
    out = paste(canvas, Image.fromarray(prop, "RGBA"), (8, 8, 4, 4))
    assert (out[8:12, 8:10] == (255, 0, 0, 255)).all()
    assert (out[8:12, 10:12] == (200, 150, 100, 255)).all()
    assert (out[0:5] == 0).all()
    assert (canvas[8:12, 8:10] == (200, 150, 100, 255)).all()   # input untouched


def test_place_scales_to_fill_and_centres():
    # 400x200 -> scale 0.78*1024/400: 799 x 399, offset ((1024-799)//2, (1024-399)//2) = (112, 312)
    canvas = place(Image.new("RGBA", (400, 200), (10, 20, 30, 255)))
    assert canvas.shape == (EDGE, EDGE, 4)
    assert subject_bbox(canvas[..., 3].astype(np.uint8)) == (112, 911, 312, 711)


def test_compose_prop_keeps_the_animal_exactly_and_adds_the_prop(tmp_path):
    cut = np.zeros((500, 300, 4), np.uint8)
    cut[:, :] = (180, 120, 60, 255)
    Image.fromarray(cut, "RGBA").save(tmp_path / "cut.png")
    Image.new("RGBA", (60, 30), (230, 20, 20, 255)).save(tmp_path / "bowl.png")
    out = compose_prop(tmp_path / "cut.png", tmp_path / "bowl.png", "bowl", tmp_path / "g.png")
    got = np.asarray(Image.open(out).convert("RGB")).astype(int)
    plain = np.asarray(Image.open(on_green(place(Image.open(tmp_path / "cut.png")), tmp_path / "p.png"))).astype(int)
    left, top, w, h = prop_box(place(Image.open(tmp_path / "cut.png"))[..., 3].astype(np.uint8), "bowl", 60, 30)
    assert (got[:8, :8] == (0, 255, 0)).all()                                   # background stays exact green
    assert abs(got[top + h // 2, left + w // 2] - (230, 20, 20)).max() <= 2    # the bowl is there
    outside = np.ones((EDGE, EDGE), bool)
    outside[top:top + h, left:left + w] = False
    assert (got[outside] == plain[outside]).all()                              # the animal is untouched
