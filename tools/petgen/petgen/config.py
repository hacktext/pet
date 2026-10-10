"""Where secrets live, and the worker's settings. Never prints a value."""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]


class ConfigError(Exception):
    pass


def secrets_dir() -> Path:
    """$PETGEN_SECRETS on a server where tools/petgen is not inside the repo;
    the repo's secrets/ otherwise."""
    return Path(os.environ.get("PETGEN_SECRETS") or REPO / "secrets")


def read_env(path: Path) -> dict[str, str]:
    kv: dict[str, str] = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            kv[k.strip()] = v.strip()
    return kv


@dataclass(frozen=True)
class Prices:
    """Kling price per unit, in cents (spec 4.5): turns units into cost_cents."""
    image_cents_per_unit: float
    video_cents_per_unit: float

    def cents(self, image_units: float, video_units: float) -> int:
        return round(image_units * self.image_cents_per_unit + video_units * self.video_cents_per_unit)


# Video: HANDOFF 4 puts a 5 s std clip (3 units) at 2.5-3.6 yuan, about 1 yuan a unit.
# Image: a cautious guess. Set both from the real purchase price in worker.env.
DEFAULT_PRICES = Prices(image_cents_per_unit=10.0, video_cents_per_unit=100.0)


@dataclass(frozen=True)
class WorkerConfig:
    key: str
    prices: Prices

    def __repr__(self) -> str:  # never show the key
        return f"WorkerConfig(key=<{len(self.key)} chars>, prices={self.prices})"


def load_worker_config(path: Path | None = None) -> WorkerConfig:
    path = Path(path) if path else secrets_dir() / "worker.env"
    if not path.exists():
        raise ConfigError(f"no {path}: copy secrets/worker.env.example there and fill AIPET_WORKER_KEY")
    kv = read_env(path)
    key = kv.get("AIPET_WORKER_KEY", "")
    if not key or not key.isascii() or " " in key:
        raise ConfigError(f"AIPET_WORKER_KEY in {path.name} is empty or still the template text")
    try:
        prices = Prices(float(kv.get("AIPET_PRICE_IMAGE_UNIT_CENTS", DEFAULT_PRICES.image_cents_per_unit)),
                        float(kv.get("AIPET_PRICE_VIDEO_UNIT_CENTS", DEFAULT_PRICES.video_cents_per_unit)))
    except ValueError:
        raise ConfigError(f"AIPET_PRICE_*_UNIT_CENTS in {path.name} must be numbers") from None
    return WorkerConfig(key, prices)
