"""pet.json and cover.png for a built-in pet folder (spec 4.1)."""
from __future__ import annotations

import json
import shutil
from pathlib import Path

import numpy as np
from PIL import Image

from petgen.prompts import PETS

ACTIONS = ["stand", "walk", "sleep", "feed", "play", "lick_paw", "act_cute"]
COVER_MAX = 512
COVER_PAD = 0.06


def pet_json(pet: str, walk_facing: str = "right") -> dict:
    p = PETS[pet]
    return {"schema": 1, "id": f"builtin-{pet}", "name": p["name"], "species": p["species"],
            "origin": "builtin", "blurb": p["blurb"], "cover": "cover.png", "actions": list(ACTIONS),
            "walkFacing": walk_facing}


def custom_pet_json(pet_id: str, name: str, species: str, actions, walk_facing: str) -> dict:
    """pet.json for a customer's pet (spec 2026-10-10 5.1 step 6)."""
    return {"schema": 1, "id": pet_id, "name": name, "species": species, "origin": "custom", "blurb": "",
            "cover": "cover.png", "actions": list(actions), "walkFacing": walk_facing}


def walk_facing(video: Path) -> str:
    """'left' or 'right': the side the walking animal's head is on -- the
    upper quarter of the keyed subject is mostly head. The client mirrors the
    clip when it walks the other way (spec 2026-09-19 E 3.4)."""
    from petgen.finish import frame_rgb
    from petgen.keycheck import alpha_map
    ys, xs = np.nonzero(alpha_map(frame_rgb(video, 0)) > 128)
    upper = xs[ys < ys.min() + (ys.max() - ys.min()) * 0.25]
    return "left" if upper.mean() < (xs.min() + xs.max()) / 2 else "right"


def chosen_facing(override: str | None, video: Path) -> str:
    """The packaged walkFacing: an explicit choice wins, otherwise the guess
    from the clip (which a raised tail can fool -- packaging prints it so a
    human can catch a wrong one and pass --facing)."""
    return override or walk_facing(video)


def make_cover(cutout: Image.Image) -> Image.Image:
    """Transparent-padded, at most COVER_MAX on its long side. The cutout comes
    from the segmentation (not the green composite), so no key-green fringe."""
    pad = round(max(cutout.size) * COVER_PAD)
    canvas = Image.new("RGBA", (cutout.width + 2 * pad, cutout.height + 2 * pad), (0, 0, 0, 0))
    canvas.paste(cutout, (pad, pad))
    canvas.thumbnail((COVER_MAX, COVER_MAX), Image.LANCZOS)
    return canvas


def write_pet_dir(out: Path, clips: dict[str, Path], cutout: Path, meta: dict) -> Path:
    """A pet folder: <action>.mp4 per clip, cover.png from the cutout, pet.json = meta."""
    out.mkdir(parents=True, exist_ok=True)
    for action, clip in clips.items():
        shutil.copy2(clip, out / f"{action}.mp4")
    make_cover(Image.open(cutout).convert("RGBA")).save(out / "cover.png")
    (out / "pet.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return out
