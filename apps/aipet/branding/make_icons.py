"""Every icon of 桌遇 / DeskMeet, from branding/logo.png (the 400 px tile on
its left, the wordmark on its right). Run after the logo changes:

    tools/petgen/.venv/Scripts/python apps/aipet/branding/make_icons.py

Writes (paths from apps/aipet/):
  windows/runner/resources/app_icon.ico   the exe, the taskbar, the installer
  assets/tray.ico, assets/tray.png         the tray (Windows) / menu bar (macOS)
  macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png
  assets/ui/logo-tile.png                  the library's sidebar and sign-in page
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

APP = Path(__file__).resolve().parents[1]
TILE = 400  # the logo's tile is its left 400 x 400 px


def mark() -> Image.Image:
    """The mark alone: black at the logo's darkness, so on white it is the logo
    exactly. Taken from inside the tile's border, cropped to its own box."""
    a = np.asarray(Image.open(APP / "branding" / "logo.png").convert("RGB"))[:TILE, :TILE].astype(float)
    grey = a.mean(axis=2)
    alpha = np.clip(255 - grey, 0, 255)
    alpha[:20, :] = alpha[-20:, :] = alpha[:, :20] = alpha[:, -20:] = 0  # the border line
    alpha[alpha < 6] = 0  # paper noise
    ys, xs = np.nonzero(alpha)
    rgba = np.zeros((*alpha.shape, 4), np.uint8)
    rgba[..., 3] = alpha.astype(np.uint8)
    return Image.fromarray(rgba, "RGBA").crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))


MARK = mark()


def tile(size: int, *, inset: float = 0.0, border: bool = True) -> Image.Image:
    """A white rounded square carrying the mark, like the logo's own tile;
    `inset` leaves that fraction transparent on every side (macOS icons)."""
    s = 4  # draw big, shrink once: smooth corners at 16 px too
    big = size * s
    pad = round(big * inset)
    side = big - 2 * pad
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    radius = round(side * 0.225)
    box = (pad, pad, pad + side - 1, pad + side - 1)
    d.rounded_rectangle(box, radius, fill=(255, 255, 255, 255),
                        outline=(222, 222, 222, 255) if border else None, width=max(1, big // 128) if border else 0)
    # The mark fills 72 % of the logo's tile; at tiny sizes a little more reads better.
    share = 0.72 if size >= 48 else 0.80
    k = side * share / max(MARK.size)  # may enlarge: the logo's mark is under 300 px
    m = MARK.resize((round(MARK.width * k), round(MARK.height * k)), Image.LANCZOS)
    img.alpha_composite(m, (pad + (side - m.width) // 2, pad + (side - m.height) // 2))
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
        # Apple's grid: the tile is 824 of 1024, no border (macOS draws none).
        tile(n, inset=100 / 1024, border=False).save(mac / f"app_icon_{n}.png")
    tile(256, border=False).save(APP / "assets/ui/logo-tile.png")
    print("icons written")


if __name__ == "__main__":
    main()
