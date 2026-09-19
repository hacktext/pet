"""pet.json and cover.png for a built-in pet folder (spec 4.1)."""
from __future__ import annotations

from PIL import Image

from petgen.prompts import PETS

ACTIONS = ["stand", "walk", "sleep", "feed", "play", "lick_paw", "act_cute"]
COVER_MAX = 512
COVER_PAD = 0.06


def pet_json(pet: str) -> dict:
    p = PETS[pet]
    return {"schema": 1, "id": f"builtin-{pet}", "name": p["name"], "species": p["species"],
            "origin": "builtin", "blurb": p["blurb"], "cover": "cover.png", "actions": list(ACTIONS)}


def make_cover(cutout: Image.Image) -> Image.Image:
    """Transparent-padded, at most COVER_MAX on its long side. The cutout comes
    from the segmentation (not the green composite), so no key-green fringe."""
    pad = round(max(cutout.size) * COVER_PAD)
    canvas = Image.new("RGBA", (cutout.width + 2 * pad, cutout.height + 2 * pad), (0, 0, 0, 0))
    canvas.paste(cutout, (pad, pad))
    canvas.thumbnail((COVER_MAX, COVER_MAX), Image.LANCZOS)
    return canvas
