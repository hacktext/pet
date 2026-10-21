"""Every icon of 桌遇 / DeskMeet, from branding/logo.png (a square tile on its
left, the wordmark on its right). Run after the logo changes:

    tools/petgen/.venv/Scripts/python apps/aipet/branding/make_icons.py

Writes (paths from apps/aipet/):
  windows/runner/resources/app_icon.ico   the exe, the taskbar, the installer
  assets/tray.ico, assets/tray.png         the tray (Windows) / menu bar (macOS)
  macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png
  assets/ui/logo-tile.png                  the library's sidebar and sign-in page

The tile is used as drawn -- its own ground colour, gradients and corner --
less the hairline border around it, which each platform's icon puts back
(Windows, faintly) or leaves out (macOS).
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

APP = Path(__file__).resolve().parents[1]


def _tile_box(logo: Image.Image) -> tuple[int, int]:
    """Side of the tile and its corner radius, measured: the tile is the
    opaque square at the left, the wordmark starts after a transparent gap."""
    alpha = np.asarray(logo)[..., 3] > 0
    cols = alpha.any(axis=0)
    gap = int(np.argmax(~cols[1:])) + 1  # first transparent column after the tile
    side = gap
    top_row = np.nonzero(alpha[0, :side])[0]
    radius = int(top_row.min()) if len(top_row) else 0
    return side, radius


def _art() -> tuple[Image.Image, float, tuple[int, int, int]]:
    """The tile's pixels with the border painted over in its ground colour;
    with its corner radius as a fraction of its side, and that colour."""
    logo = Image.open(APP / "branding" / "logo.png").convert("RGBA")
    side, radius = _tile_box(logo)
    tile = logo.crop((0, 0, side, side))
    a = np.asarray(tile).astype(int)
    ground = tuple(int(v) for v in np.median(a[side // 2, 3:12, :3], axis=0))  # just inside the left edge
    inset = 3  # the border is a 1-2 px ring
    inner = Image.new("L", (side, side), 0)
    ImageDraw.Draw(inner).rounded_rectangle((inset, inset, side - 1 - inset, side - 1 - inset),
                                            max(0, radius - inset), fill=255)
    out = Image.new("RGBA", (side, side), (*ground, 255))
    out.paste(tile, (0, 0), inner)
    return out, radius / side, ground


ART, RADIUS, GROUND = _art()


def tile(size: int, *, inset: float = 0.0, border: bool = True, radius: float | None = None) -> Image.Image:
    """The tile at [size] px; `inset` leaves that fraction transparent on
    every side (macOS icons); `radius` overrides the logo's own corner. A faint
    border keeps a cream tile visible on a white Windows desktop or menu."""
    s = 4  # draw big, shrink once: smooth corners at 16 px too
    big = size * s
    pad = round(big * inset)
    side = big - 2 * pad
    shape = Image.new("L", (big, big), 0)
    box = (pad, pad, pad + side - 1, pad + side - 1)
    r = round(side * (RADIUS if radius is None else radius))
    ImageDraw.Draw(shape).rounded_rectangle(box, r, fill=255)
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    img.paste(ART.resize((side, side), Image.LANCZOS), (pad, pad), shape.crop(box).resize((side, side)))
    if border:
        ImageDraw.Draw(img).rounded_rectangle(box, r, outline=(214, 196, 182, 255), width=max(1, big // 128))
    return img.resize((size, size), Image.LANCZOS)


def main() -> None:
    ico = [tile(n) for n in (256, 128, 64, 48, 32, 24, 16)]
    ico[0].save(APP / "windows/runner/resources/app_icon.ico", sizes=[(i.width, i.height) for i in ico],
                append_images=ico[1:])
    tray = [tile(n) for n in (48, 32, 24, 20, 16)]
    tray[0].save(APP / "assets/tray.ico", sizes=[(i.width, i.height) for i in tray], append_images=tray[1:])
    tile(44, border=False).save(APP / "assets/tray.png")
    mac = APP / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for n in (16, 32, 64, 128, 256, 512, 1024):
        # Apple's grid: the tile is 824 of 1024 with Apple's own corner (about
        # 22 %; the logo's is tighter and looks square in the Dock), no border.
        tile(n, inset=100 / 1024, border=False, radius=0.2237).save(mac / f"app_icon_{n}.png")
    tile(256, border=False).save(APP / "assets/ui/logo-tile.png")
    print(f"icons written (tile {ART.width} px, corner {RADIUS:.3f}, ground #{'%02X%02X%02X' % GROUND})")


if __name__ == "__main__":
    main()
